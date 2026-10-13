# 实时字幕保存（AHK 极简版）

灵感来源：[SaveLiveCaptions](https://github.com/LiveCaptionsHelper/SaveLiveCaptions)（MIT）。
原版是 Python + tkinter，界面是个奇怪的悬浮圆点/方块仪表盘，而且必须先开好 Live Captions 才能启动。
这个版本按“启动即自动 hook、窗口只显示文件名和状态”的思路，用 AutoHotkey v2 重写，
逻辑只剩几步。

## 原理

和原版一样，走 Windows UI Automation：

1. 找到类名为 `LiveCaptionsDesktopWindow` 的窗口（就是系统实时字幕那条）；
2. 在它的后代元素里找 `AutomationId = "CaptionsScrollViewer"` 的控件；
3. 读这个控件的 `Name` 属性——字幕全文就藏在这里；
4. 每 1 秒读一次。

AHK 这边用的 UIA 库是 Descolada 的 [UIA-v2](https://github.com/Descolada/UIA-v2)，
AHK v2 社区的事实标准 UIA 封装（MIT 协议，已随附 `UIA.ahk`）。

## 保存逻辑

1. 每 1 秒读一次字幕全文（保留字幕自带的换行，只压缩横向多余空格）；
2. 跟上次读到的求差值（单词为单位）：纯追加走字符串前缀快路径；
   否则按单词做贪心子序列匹配，只取匹配不上的新词/改词
   （例：上次 AA BB CC EE、这次 BB CD EE FF → 只取 CD FF）；
3. 有改词时文件同步：在文件尾定位到最后一个旧词（锚点），原地截断后重写
   改词后的内容，而不是新旧并存（原地改，Notepad++ 监视不断；
   失败则退回追加）；
4. 有新增就往当前行后面追加；字幕自带的换行会保留（字幕里断行，文件里也断行）；
   没遇到断句标点（。！？.!? 共 6 个）就一直追加到同一行；
   增量里有几个标点就断几次行，每段在标点处收行，
   剩下的另起一行（新行行首去空格，带时间戳）；
5. 全文 3 秒没变化先欠着一次换行（`SILENCE_SEC` 可调），不立刻写；
   等新内容到了再看：开头是断句标点就接到当前行写完再断，
   否则先换行再写，新行带 `[HH:MM:SS]` 时间戳；
6. 把这次读到的存成“上次”，供下轮比较。

不去重，不判稳，不清洗。字幕上新出现什么就存什么，重复的也存。
比较的对象只是当前窗口里这点文字（几 KB），不是历史记录，所以越跑越久也不会变慢。

写文件是排队+重试的：Notepad++ 之类开着文件时偶发共享冲突（Error 32），
撞上了就多试几次，实在写不进去先暂存内存、下轮再刷，不弹框、不丢数据。

注意：Live Captions 自己只保留最近一段字幕，脚本启动前说过的话拿不到，只能存它显示出来的。

## 用法

1. 双击 `SaveLiveCaptions.exe`（release 里下载；或者装
   [AutoHotkey v2](https://www.autohotkey.com/) 后双击 `SaveLiveCaptions.ahk` 跑源码）；
2. 小窗口显示“等待 Live Captions 出现…”——去系统设置里打开实时字幕
   （`Win+Ctrl+L`），脚本会自动 hook 并开始保存；
3. 窗口第一行是记录文件名（黑色，悬停显示下划线+手型光标，点击直接打开文件），
   没 hook 前第一行是空的，不可点；
4. 窗口第二行是状态指示，三种状态都在这里：
   没出现显示“等待 Live Captions 出现…”（黑色）；
   出现了没字幕显示“已连接，等待字幕出现…”（黑色）；
   有字幕显示“已保存 XX 段 · 抓取 xxx 字符”（灰色）；
5. 没 hook 上时第三行有个“打开实时字幕”按钮（直接启动系统
   `%windir%\System32\LiveCaptions.exe`），
   旁边是“启动时自动打开”复选框，勾上后下次启动自动打开字幕；
   选项存在程序旁边的 `LiveCaptionsSaver.ini` 里；
6. 字幕存到 `文档\captions\YYYY-MM-DD_HH-MM-SS_captions.txt`；
7. 点右上角 ✕ 退出，退出时把最后一点新增也写进去。

Live Captions 中途被关掉再打开，脚本会自动断开并重新 hook，不用重启。
窗口第二行实时显示“抓取 N 字符”，确认脚本一直在读到字幕。

## 打包成单文件 exe（可选）

AHK v2 自带 `Ahk2Exe`（开始菜单 → AutoHotkey → Compile）：

- Source 选 `SaveLiveCaptions.ahk`，Base 选 `AutoHotkey64.exe`；
- Custom Icon 选 `captions.ico`；压缩选 `(none)`（不加壳，避免杀毒误报）；
- 点 Convert。`UIA.ahk` 是 `#Include` 进去的，会被一起打包，
  生成的 exe 拿到任何 Win10/11 机器双击就能跑，不用再装 AHK。

## 文件

- `SaveLiveCaptions.ahk` —— 主脚本，全部逻辑+配置都在这一个文件里（配置在文件头）
- `UIA.ahk` —— Descolada 的 UIA 库（© 2023 Descolada，MIT License）
- `captions.ico` —— 程序图标（Material Symbols closed_caption，Apache 2.0）
- `README.md` —— 本文件
- `LICENSE` —— MIT

## 许可证

本脚本 MIT。第三方：`UIA.ahk` © 2023 Descolada（MIT）；
思路来源 SaveLiveCaptions（MIT）；
图标来自 Google Material Symbols（Apache 2.0）。
