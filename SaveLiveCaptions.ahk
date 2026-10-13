; ============================================================
; SaveLiveCaptions.ahk —— 极简版 Windows 实时字幕保存工具
;
; 灵感来源：https://github.com/LiveCaptionsHelper/SaveLiveCaptions
; 原理：通过 UI Automation 找到 LiveCaptionsDesktopWindow 窗口，
;       读取其中 CaptionsScrollViewer 控件的 Name 属性
;       （字幕全文就藏在这个属性里），轮询后写文件。
;
; 逻辑：
;   1. 每 1 秒读一次字幕全文（保留字幕自带的换行，只压缩横向空格）；
;   2. 跟上次读到的求差值（单词为单位）：纯追加走字符串前缀快路径；
;      否则按单词做贪心子序列匹配，只取匹配不上的新词/改词。
;      例如上次 AA BB CC EE、这次 BB CD EE FF → 只取 CD FF
;      （AA 滚出去了，BB/EE 是公共部分，CC→CD 是改词用改后的，FF 新增）；
;   3. 有改词时文件同步：在文件尾定位到最后一个旧词（锚点），
;      原地截断后重写改词后的内容，而不是把新旧都追加
;      （原地改，Notepad++ 监视不断；失败则退回追加，数据不丢）；
;   3. 有新增就往当前行后面追加；字幕自带的换行会保留（字幕里断行，文件里也断行）；
;      没遇到断句标点（。！？.!? 共 6 个）就一直追加到同一行；
;      增量里有几个标点就断几次行，每段在标点处收行，
;      剩下的另起一行（新行行首去空格，带时间戳）；
;      SILENCE_SEC 秒没变化先欠着一次换行（不立刻写），
;      等新内容到了再看：开头是断句标点就接到当前行写完再断，
;      否则先换行再写；新行带时间戳；
;   4. 把这次读到的存成“上次”，供下次比较。
; 不去重，不判稳，字幕上新出现什么就存什么。
;
; 用法：双击运行即可。启动后自动等待 Live Captions 出现并 hook，
;       字幕存到「文档\captions\日期_时间_captions.txt」。
; 窗口第一行：记录文件名（黑色，悬停下划线+手型光标，点击打开），
;             没 hook 前是空行，不可点；
; 窗口第二行：三种状态都在这里——
;             没出现：“等待 Live Captions 出现…”（黑色）；
;             出现了没字幕：“已连接，等待字幕出现…”（黑色）；
;             有字幕：“已保存 XX 段 · 抓取 xxx 字符”（灰色）；
; 再加一个关闭按钮，关闭时把最后一点新增也写进去。
;
; 需要：AutoHotkey v2（https://www.autohotkey.com/）
;       同目录下的 UIA.ahk（Descolada，MIT 协议）
; 想做成单文件 exe：用 AHK 自带的 Ahk2Exe 编译本脚本即可，
;       UIA 库会被一起打包进去，exe 拿到哪台机器都能跑。
; ============================================================
#Requires AutoHotkey v2.0
#SingleInstance Force
#Include UIA.ahk

; ---------------- 配置（只改这里） ----------------
POLL_MS      := 1000                    ; 每隔这么多毫秒读一次字幕
WATCH_MS     := 2000                    ; 等待 Live Captions 出现的检查间隔
SILENCE_SEC  := 3                       ; 全文这么多秒没变化就强制换行
SAVE_DIR     := A_MyDocuments "\captions"
LC_CLASS     := "ahk_class LiveCaptionsDesktopWindow"

; ---------------- 全局状态 ----------------
global sv := 0            ; CaptionsScrollViewer 的 UIA 元素
global hooked := false
global saveFile := ""
global fileName := ""
global savedCount := 0
global lastText := ""     ; 上次读到的字幕全文
global unchanged := 0     ; 全文连续几轮没变（判 3 秒静默）
global lineOpen := false  ; 文件当前行是否还没换行
global pendingBreak := false  ; 静默够久，欠着一次换行（等新内容到了再决定怎么断）
global lastChars := 0     ; 上轮抓到的字符数（显示用）
global writeQueue := ""  ; 待写入文件的内容队列（文件被占用时暂存，不丢数据）
global statusCtl := 0, fileCtl := 0
global fileShown := false  ; 第一行当前是不是文件名（可点状态）
global hoverOn := false    ; 鼠标是否悬停在文件名上

; ---------------- 窗口 ----------------
; 第一行：文件名（黑色，悬停下划线+手型光标，点击打开）；没文件时空着
; 第二行：三种状态指示（等待提示黑色，计数灰色）
g := Gui("+AlwaysOnTop -MaximizeBox", "实时字幕保存")
g.SetFont("s10", "Microsoft YaHei")
statusCtl := g.Add("Text", "x14 y12 w292", "")
statusCtl.OnEvent("Click", (*) => OpenSaveFile())
fileCtl   := g.Add("Text", "x14 y36 w292", "等待 Live Captions 出现…")
btn := g.Add("Button", "x14 y62 w292 h30", "关闭")
btn.OnEvent("Click", (*) => DoExit())
g.OnEvent("Close", (*) => DoExit())
g.Show("w320 h106")

; 文件名悬停时显示手型光标+下划线（常驻下划线会跟文件名里的下划线重叠）
hHand := DllCall("LoadCursor", "Ptr", 0, "Ptr", 32649, "Ptr")
OnMessage(0x20, WM_SETCURSOR)

WM_SETCURSOR(wParam, *) {
    global statusCtl, hHand, fileShown
    if (fileShown && wParam = statusCtl.Hwnd) {
        DllCall("SetCursor", "Ptr", hHand)
        return true
    }
}

SetTimer(HoverCheck, 200)

HoverCheck() {
    global statusCtl, fileShown, hoverOn
    try {
        MouseGetPos(,,, &ctrlHwnd)
    } catch {
        return  ; 极少数情况下取不到鼠标位置，跳过本轮
    }
    over := fileShown && ctrlHwnd = statusCtl.Hwnd
    if (over != hoverOn) {
        hoverOn := over
        try statusCtl.SetFont(over ? "s10 underline" : "s10", "Microsoft YaHei")
    }
}

SetTimer(WatchTimer, WATCH_MS)
WatchTimer()  ; 立刻跑一次，不等第一个 2 秒（否则第二行颜色/状态会闪一下）

; ---------------- 等待出现 / 守护连接 ----------------
; 三种状态的指示都在第二行：没出现 / 出现了没字幕 / 有字幕（统计）
WatchTimer() {
    global hooked, sv, LC_CLASS
    hwnd := WinExist(LC_CLASS)
    if (!hooked) {
        if (!hwnd) {
            SetLine2("等待 Live Captions 出现…")
            return
        }
        try {
            el := UIA.ElementFromWindow("ahk_class LiveCaptionsDesktopWindow")
            sv := el.FindElement({AutomationId: "CaptionsScrollViewer"})
            HookOK()
        } catch {
            SetLine2("已连接，等待字幕出现…")
        }
        return
    }
    if (!hwnd) {
        ; Live Captions 被关了：断开，继续等它回来
        Unhook("等待 Live Captions 出现…")
    }
}

HookOK() {
    global hooked, saveFile, fileName, savedCount, lastText, unchanged, lineOpen, pendingBreak, POLL_MS, statusCtl, fileShown
    DirCreate(SAVE_DIR)
    fileName := FormatTime(, "yyyy-MM-dd_HH-mm-ss") "_captions.txt"
    saveFile := SAVE_DIR "\" fileName
    TryWriteFile("")  ; 建空文件（被占用就多试几次，不行等第一段内容时再建）
    hooked := true
    savedCount := 0
    lastText := ""
    unchanged := 0
    lineOpen := false
    pendingBreak := false
    statusCtl.Text := fileName
    fileShown := true  ; 第一行现在是文件名，可点（悬停下划线+手型）
    RefreshStats()
    SetTimer(PollTimer, POLL_MS)
}

Unhook(line2msg := "") {
    global hooked, lastText, unchanged, lineOpen, pendingBreak
    hooked := false
    lastText := ""
    unchanged := 0
    lineOpen := false
    pendingBreak := false
    SetTimer(PollTimer, 0)
    if (line2msg != "")
        SetLine2(line2msg)
}

; 第二行状态指示；gray=true 灰色（计数），false 黑色（连接提示）
SetLine2(msg, gray := false) {
    global fileCtl
    fileCtl.SetFont(gray ? "s10 c808080" : "s10 c000000")
    fileCtl.Text := msg
}

; ---------------- 轮询：读一次，跟上次差值写入，更新上次 ----------------
; 没断句标点就一直往同一行后面追加；静默够久或遇到断句标点就换行。
PollTimer() {
    global sv, lastText, unchanged, lineOpen, pendingBreak, saveFile, lastChars, SILENCE_SEC, POLL_MS
    if (!hooked)
        return
    try {
        text := NormalizeText(sv.Name)
    } catch {
        Unhook("连接中断，等待 Live Captions 重新出现…")
        return
    }
    lastChars := StrLen(text)
    if (text = "") {
        ; 已连接但没字幕：第二行显示等待提示（黑色），不清计数
        SetLine2("已连接，等待字幕出现…")
        FlushWrites()  ; 没新内容，但把欠着的刷了
        return
    }
    RefreshStats()
    if (text = lastText) {
        unchanged++
    } else {
        diff := WordDiffIncrement(lastText, text)
        if (Trim(diff.inc) != "")
            ApplyDiff(diff)  ; 有改词则文件同步，无改词则追加（含欠着的静默换行）
        unchanged := 0
        lastText := text
    }
    ; 静默够久：先欠着，不立刻换行（等新内容到了再决定怎么断）
    if (unchanged = SILENCE_SEC * 1000 // POLL_MS && lineOpen) {
        pendingBreak := true
    }
    FlushWrites()  ; 队列刷盘（文件被占用就下轮再试）
}

; 整理字幕文本：保留字幕自带的换行（分行），其余空白压缩
NormalizeText(s) {
    s := RegExReplace(s, "\r\n?", "`n")  ; 统一换行符
    s := RegExReplace(s, "[ \t]+", " ")   ; 横向空白压缩，不碰换行
    s := RegExReplace(s, " *\n *", "`n")  ; 换行符前后不留空格
    s := RegExReplace(s, "\n{2,}", "`n")  ; 连续空行压成一个
    return Trim(s, " `t`r`n")
}

; text 相对于 lastText 的差值（单词为单位），返回 {inc, isRevision, anchor, syncText}。
; text 相对于 lastText 的差值（单词为单位），返回 {inc, isRevision, anchor, syncText}。
; inc: 新词/改词（带原始分隔符），追加用；
; isRevision: 是否有改词（需要文件同步）；anchor: 锚点词（最后一个旧词）；
; syncText: 从第一个新词起的原文（含分隔符），同步时写入。
; 例如上次 AA BB CC EE、这次 BB CD EE FF → inc=" CD FF"，isRevision=true，
; anchor="BB"，syncText=" CD EE FF"。
WordDiffIncrement(lastText, text) {
    result := {inc: "", isRevision: false, anchor: "", syncText: ""}
    if (lastText = "")
        return result
    lt := StrLen(lastText)
    if (SubStr(text, 1, lt) = lastText) {
        ; 纯追加快路径
        result.inc := SubStr(text, lt + 1)
        return result
    }
    ; 分词（记位置，用于还原分隔符）
    prevWords := []
    p := 1
    while (RegExMatch(lastText, "\S+", &m, p)) {
        prevWords.Push(m[0])
        p := m.Pos + StrLen(m[0])
    }
    currWords := []  ; {w, pos, len}
    p := 1
    while (RegExMatch(text, "\S+", &m, p)) {
        currWords.Push({w: m[0], pos: m.Pos, len: StrLen(m[0])})
        p := m.Pos + StrLen(m[0])
    }
    if (currWords.Length = 0)
        return result
    ; prev 单词 -> 位置表（处理重复词）
    posMap := Map()
    for j, w in prevWords {
        if (!posMap.Has(w))
            posMap.Set(w, [])
        posMap.Get(w).Push(j)
    }
    ; 贪心子序列匹配：curr 的词按顺序在 prev 里找，找到算旧词，找不到算新词/改词
    isNew := []
    prevMatched := []
    Loop prevWords.Length
        prevMatched.Push(false)
    prevIdx := 1
    for i, cw in currWords {
        found := false
        if (posMap.Has(cw.w)) {
            for _, pj in posMap.Get(cw.w) {
                if (pj >= prevIdx) {
                    found := true
                    prevMatched[pj] := true
                    prevIdx := pj + 1
                    break
                }
            }
        }
        isNew.Push(!found)
    }
    ; 拼 inc（只取新词，带原始分隔符）
    inc := ""
    prevEnd := 0
    for i, cw in currWords {
        if (isNew[i]) {
            sep := SubStr(text, prevEnd + 1, cw.pos - prevEnd - 1)
            inc .= sep . cw.w
        }
        prevEnd := cw.pos + cw.len - 1
    }
    result.inc := inc
    ; 第一个新词
    firstNew := 0
    for i, nw in isNew {
        if (nw) {
            firstNew := i
            break
        }
    }
    if (firstNew = 0)
        return result
    ; 检测改词：有没匹配上的 prev 词，且不在头部滚动区
    firstMatched := 0
    for j, mt in prevMatched {
        if (mt) {
            firstMatched := j
            break
        }
    }
    for j, mt in prevMatched {
        if (!mt && j > firstMatched) {
            result.isRevision := true
            break
        }
    }
    if (result.isRevision && firstNew > 1) {
        result.anchor := currWords[firstNew - 1].w
        pw := currWords[firstNew - 1]
        result.syncText := SubStr(text, pw.pos + pw.len)
    }
    return result
}

; 应用 diff：有改词就尝试文件同步（定位锚点、截断重写），失败则退回追加。
; 欠着的静默换行在这里统一处理（同步截断之后、写入之前，避免冲突）。
ApplyDiff(diff) {
    global pendingBreak, lineOpen
    synced := false
    if (diff.isRevision && diff.anchor != "" && diff.syncText != "") {
        synced := SyncFileRewrite(diff.anchor, diff.syncText)
        ; 成功时文件已截断到锚点词尾，lineOpen=true
    }
    writeText := synced ? diff.syncText : diff.inc
    ; 欠着一次静默换行：看新内容开头是不是断句标点
    if (pendingBreak && lineOpen) {
        pendingBreak := false
        if (!InStr("。！？.!?", SubStr(LTrim(writeText), 1, 1))) {
            ; 开头不是标点：先换行，再写新内容
            QueueWrite("`r`n")
            lineOpen := false
        }
        ; 开头是标点：直接接到当前行，标点处自然收行
    }
    AppendToLine(writeText)  ; 原样追加，空格用字幕自带的，不自己加
}

; 文件同步：在文件尾找到 anchor，把它之后的内容替换为 syncText。
; 成功返回 true；失败返回 false（调用方退回追加，数据不丢）。
; 原地截断+重写（文件本身不替换，Notepad++ 的文件监视不会断）。
SyncFileRewrite(anchor, syncText) {
    global saveFile, lineOpen, writeQueue
    FlushWrites()
    if (writeQueue != "")
        return false
    try {
        content := FileRead(saveFile, "UTF-8")
    } catch {
        return false
    }
    if (SubStr(content, 1, 1) = Chr(0xFEFF))
        content := SubStr(content, 2)  ; 去 BOM，写回时统一加
    truncPos := FindAnchorEnd(content, anchor)
    if (truncPos = 0)
        return false
    truncated := SubStr(content, 1, truncPos)
    if (!TruncateFileInPlace(truncated))
        return false
    lineOpen := true  ; 截断到词尾，行开着，调用方接着 AppendToLine(syncText)
    return true
}

; 在 content 中找 anchor 的最后一个完整单词匹配（忽略词尾标点），
; 返回该词尾的字符位置（1-based），找不到返回 0。
FindAnchorEnd(content, anchor) {
    anchorNorm := RegExReplace(anchor, "[.,!?;:，。！？]+$")
    if (anchorNorm = "")
        return 0
    lastEnd := 0
    p := 1
    while (RegExMatch(content, "\S+", &m, p)) {
        wNorm := RegExReplace(m[0], "[.,!?;:，。！？]+$")
        if (wNorm = anchorNorm) {
            lastEnd := m.Pos + StrLen(m[0]) - 1
        }
        p := m.Pos + StrLen(m[0])
    }
    return lastEnd
}

; 原地截断文件并写入新内容（"w" 模式是截断原文件，不是删除重建，
; 文件本身不变，Notepad++ 监视不断），带重试。
; 注意：这是有风险的操作——如果在截断和写完之间崩溃，尾部会丢；
; 但按调用方的流程，失败会退回追加，极端情况下顶多丢几个词。
TruncateFileInPlace(content) {
    global saveFile
    loop 8 {
        try {
            f := FileOpen(saveFile, "w", "UTF-8-RAW")
            f.Write(Chr(0xFEFF))  ; BOM（文件原本就是 FileAppend UTF-8 创建的，带 BOM）
            f.Write(content)
            f.Close()
            return true
        } catch {
            Sleep(200)
        }
    }
    return false
}

; 追加到当前行尾。先按字幕自带的换行切分（字幕里断行，文件里也断行），
; 再按断句标点切分：增量里有几个标点就断几次行。
; 新起一行时行首去空格；往旧行后面追加时原样保留字幕自带的空格。
AppendToLine(inc) {
    global saveFile, savedCount, lineOpen
    chunks := StrSplit(inc, "`n")
    last := chunks.Length
    for i, chunk in chunks {
        if (Trim(chunk) != "")
            AppendChunk(chunk)
        ; 字幕自带的换行：强制断行（最后一段之后除外）；
        ; 注意断行不能放在 continue 之后，否则空段会吞掉换行
        if (i < last && lineOpen) {
            QueueWrite("`r`n")
            lineOpen := false
        }
    }
    RefreshStats()
}

AppendChunk(chunk) {
    global saveFile, savedCount, lineOpen
    rest := chunk
    while (rest != "") {
        head := rest
        found := false
        if (RegExMatch(rest, "^(.*?[。！？.!?])(.*)$", &m)) {
            head := m[1]  ; 非贪婪，先切出第一个标点及之前
            rest := m[2]
            found := true
        } else {
            rest := ""
        }
        if (Trim(head) = "")
            continue  ; 纯空白段跳过
        if (lineOpen)
            QueueWrite(head)  ; 原样追加，空格用字幕自带的
        else {
            QueueWrite("[" FormatTime(, "HH:mm:ss") "] " LTrim(head))
            lineOpen := true
        }
        savedCount++
        if (found) {
            QueueWrite("`r`n")
            lineOpen := false
        }
    }
}

; 第二行：三种状态都在这里指示（没出现 / 出现了没字幕 / 有字幕时显示统计）
; 计数是灰色，连接提示是黑色（见 SetLine2）
RefreshStats() {
    global savedCount, lastChars
    SetLine2("已保存 " savedCount " 段 · 抓取 " lastChars " 字符", true)
}

; 点击第一行的文件名，直接打开记录文件（没文件时不可点）
OpenSaveFile() {
    global saveFile, fileShown
    if (!fileShown || saveFile = "")
        return
    try Run('"' saveFile '"')
}

; ---------------- 杂项 ----------------

; ---------------- 写文件：排队 + 重试 ----------------
; Notepad++ 开着文件时会偶发 Error 32（共享冲突）。
; 所有写文件走 QueueWrite 排队，FlushWrites 刷盘；
; 刷不进去就留着下轮再试，不弹框、不丢数据。
QueueWrite(s) {
    global writeQueue
    writeQueue .= s
}

; 带重试的单次写入，返回是否成功
TryWriteFile(content) {
    global saveFile
    loop 8 {
        try {
            FileAppend(content, saveFile, "UTF-8")
            return true
        } catch {
            Sleep(200)
        }
    }
    return false
}

FlushWrites() {
    global writeQueue
    if (writeQueue = "")
        return
    if (TryWriteFile(writeQueue))
        writeQueue := ""
    ; 失败就留着，下轮再试
}

; 退出前把最后一点新增也写进去，并收行
DoExit() {
    global sv, lastText, lineOpen, saveFile, writeQueue
    try {
        text := NormalizeText(sv.Name)
        if (text != lastText) {
            diff := WordDiffIncrement(lastText, text)
            if (Trim(diff.inc) != "")
                ApplyDiff(diff)
        }
        if (lineOpen) {
            QueueWrite("`r`n")
            lineOpen := false
        }
    }
    ; 退出前尽量把队列刷盘（写不进去也不弹框，顶多丢最后一点）
    loop 5 {
        FlushWrites()
        if (writeQueue = "")
            break
    }
    ExitApp()
}
