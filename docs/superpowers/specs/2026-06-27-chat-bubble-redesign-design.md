# 浮窗聊天气泡重做 + 朗读真按钮(稳定 toggle) — 设计

日期：2026-06-27
范围：popdict（macOS 原生划词翻译，Swift）
关联前序：[2026-06-27-tts-and-original-text-design.md](2026-06-27-tts-and-original-text-design.md)（朗读 + 原文显示的首版，本次在其基础上重做 UI）

## 背景与目标

首版朗读功能已落地（原文显示、🔊 emoji 文本链接、逐句高亮）。用户实测后两点反馈：

1. **朗读要稳定 toggle**：点一下读、再点一下停。现状 🔊 是"emoji 当文本链接"，命中区域小、不像控件，再点容易点空、停不下来。
2. **浮窗太丑，要 macOS 原生高级/清晰/丝滑**。用户已选定视觉方向：**聊天气泡**（原文/追问靠右气泡，AI 回答靠左气泡）。

结论：把对话区从"单个 NSTextView + 自定义 LayoutManager 画满宽底"重做为**气泡子视图竖向堆叠**；🔊 改为真正的 SF Symbol NSButton。翻译面板同样气泡化，风格统一。

## 现状（代码事实）

- 对话 transcript 是**单个 NSTextView**：`makeTranscriptView`→`makeRenderingTextView`（约 718/745 行）创建，放进 `installConversationPanel`（约 622 行）的 `NSScrollView`。
- `CodeBlockLayoutManager`（`Markdown.swift:390`）在 `drawBackground` 里给标记段落画**满宽**圆角底：`codeBlockKey`（灰）、`userMsgKey`（accent）。矩形是 `x:3, width: 容器宽-6`，不左右分边、不按内容收宽——做不出真气泡。
- 流式：`convoAppendDelta`（约 828 行）往单 textview 追加纯文本；`finishTurn`（约 838 行）用 `MD.render` 把流式段替换为 markdown 并挂 🔊+speakId；`appendUserBubble`（约 916 行）追加"你的追问"段；`convoError`（约 872 行）整轮回滚。
- 首版加的"🔊 文本链接 + speakId 扫描"机制：`speakerPrefix`/`markSpeakBody`/`speakSegment`（约 980-1010 行）、`extension PopupController: NSTextViewDelegate { clickedOnLink }`（文件末尾）、`makeRenderingTextView` 里设的 `delegate`/`linkTextAttributes`、`MD.speakIdKey`。
- 语音引擎 `Speech.swift` 的 `Speaker`：`speak(_:in:bodyRange:speakId:)`、`stop()`、`isSpeaking(_:)`、`voiceLanguage(for:)`、逐句高亮委托。**保留复用**。
- 周边（不动）：`NSPanel`/`DraggableBlurView` 毛玻璃背板、`present` 淡入/crossfade、AX 取词、底部输入栏 `makeInputBar`、右下 `ResizeGripView` 缩放、`generation` 令牌与 `stopConversation`、`HoverButton`、`chatStream`、截图解释 `beginImageConversation`、翻译 `translate`。
- 代码库整体用**手动 frame 布局**（NSRect + autoresizingMask），不用 Auto Layout。
- 工具链 Swift 6.3.2；`build.sh` 显式文件列表 + `-swift-version 5`；已链 `AVFoundation NaturalLanguage`；SF Symbol `NSImage(systemSymbolName:)` 需 macOS 11+（目标 12.0，满足）。

## 已确认决策

- 视觉方向：聊天气泡（用户气泡靠右 accent；AI 气泡靠左中性灰）。
- 🔊：SF Symbol 真按钮（`speaker.wave.2.fill` ↔ 朗读中 `stop.fill`），hover 高亮，点一下读/再点停。
- 逐句高亮：保留。
- 翻译面板：一并气泡化（原文右、译文左），共用气泡组件。

## 总体方案

### 1. 新组件 `BubbleView`（新文件 `Bubble.swift`）

一个圆角容器代表一条消息。

- `enum BubbleRole { case user, ai }`
- 子视图：
  - `speakButton: NSButton`（SF Symbol 图标按钮，无边框、`imagePosition: .imageOnly`、`bezelStyle: .regularSquare`、`isBordered = false`，约 16pt；默认 `speaker.wave.2.fill`，朗读中 `stop.fill`；contentTintColor 跟随气泡前景色）。
  - `textView: NSTextView`（复用 `makeRenderingTextView` 同款配置：可选中、不可编辑、透明底、竖向自适应；不再需要 link delegate）。
- 外观：`wantsLayer`，圆角 ~12，内边距 ~12；
  - `.user`：填 `controlAccentColor`，文字白色，喇叭 tint 白色（带透明度）。
  - `.ai`：填中性底（`NSColor.windowBackgroundColor` 或 `quaternaryLabelColor` 叠加，在毛玻璃上呈浅灰），文字 `labelColor`，喇叭 tint `secondaryLabelColor`。
- 内部布局（Auto Layout，仅气泡内部用约束；详见 §3 关于布局范式的说明）：喇叭按钮置于气泡**首行前缘**（user 在 trailing 顶角、ai 在 leading 顶角的小角标），文本视图与之不重叠。具体角标位置与内边距在真机微调。
- 朗读状态 API：
  - `setPlaying(_ playing: Bool)`：切换 SF Symbol 图标 + tint（朗读中用 accent 高亮 stop.fill）。
- 内容 API：
  - `setPlainText(_:)`：用于 user 气泡与流式中的 ai 气泡（纯文本）。
  - `appendDelta(_:)`：流式逐字追加到 ai 气泡。
  - `setMarkdown(_:width:)`：一轮完成后把 ai 气泡内容重渲染为 markdown（调用 `MD.render`，宽度 = 气泡文本可用宽）。
- 朗读接线：`speakButton.action` 调 `PopupController.onBubbleSpeak(_:)`，由控制器拿到该气泡的 `textView` + 全文范围调用 `Speaker.shared.speak(text, in: textView, bodyRange: 全范围, speakId: 气泡唯一 id)`；`Speaker` 的逐句高亮直接作用在该气泡 textview 上。
  - 控制器维护 `id → BubbleView` 映射，`Speaker` 状态变化（didFinish/didCancel/被切换）时回调控制器把对应气泡 `setPlaying(false)`，当前播放气泡 `setPlaying(true)`。

> 因每个气泡独立 textview，朗读"段落"= 该气泡全文，**不再需要** speakId 跨大文本扫描；首版的 `speakerPrefix`/`markSpeakBody`/`speakSegment`/`clickedOnLink`/`MD.speakIdKey` 全部移除（见 §6）。

### 2. 对话区容器 `BubbleStackView`（在 `Bubble.swift` 或 `installConversationPanel` 内组装）

- `NSScrollView.documentView` = 一个竖向 `NSStackView`（`orientation: .vertical`，`spacing: 10`，`alignment: .leading`），其每个 arrangedSubview 是一个**行容器**：行容器宽度 = 列宽，内部把 `BubbleView` 用约束钉在 leading（ai）或 trailing（user），并约束 `BubbleView.width <= 列宽 * maxFraction`（user≈0.78、ai≈0.85），内容少则按内容收窄（气泡 hug 文本）。
- 滚动、宽度自适应：scrollview `autoresizingMask=[.width,.height]`；stackview 宽度跟随 clip 视图宽 → 改窗宽时气泡重排。高度由 Auto Layout 自动得出，**去掉**首版/现状对单 textview 的手动长高处理。

### 3. 布局范式说明（局部引入 Auto Layout）

代码库其余部分是手动 frame；本次**仅在对话/翻译的气泡列内部**使用 Auto Layout（NSStackView + 约束），因为可变长聊天列用约束远比手动 y 偏移健壮。`NSScrollView`、`NSPanel`、输入栏、缩放握把等仍是手动 frame，与气泡列通过 `scrollView.documentView` 边界隔离，互不干扰。

### 4. 流式 / 出错 / 滚动

- `sendTurn`：新建一个空的 `.ai` 气泡加入 stack，记 `currentAIBubble` 引用。
- `convoAppendDelta`：`currentAIBubble?.appendDelta(piece)`，滚到底。
- `finishTurn`：`currentAIBubble?.setMarkdown(text, width:)`，记 `lastResult=text`，开放追问输入；滚回本轮起点（本轮 = 该用户气泡 + ai 气泡的顶部）。
- `appendUserBubble(q)`：新建 `.user` 气泡（纯文本 q）加入 stack。
- `convoError`：
  - 首轮失败（无 assistant 内容）→ `stopConversation()` + 回退 `showMessage(错误)`（与现状一致）。
  - 追问失败 → 移除本轮刚加的 user 气泡 + 半截 ai 气泡，插入一条**错误提示气泡**（红字、ai 侧、无喇叭），允许重试。
- 滚动：保留"流式滚到底""一轮完成滚回本轮顶部"的体验，用 stack 内对应行的 frame 计算可见区。

### 5. 翻译面板（`showMessage` 最终译文分支）

- 最终译文（`showCopy && markdown && original != nil`）：在结果滚动区放一个小气泡 stack——`.user` 原文气泡（右）+ `.ai` 译文气泡（左，markdown 渲染），各带喇叭。底部"复制"按钮 + 缩放握把保留。
- "翻译中…"/报错：保持现有轻量单文本路径不变（`makeRenderingTextView`），不气泡、不挂喇叭。
- `onTranslateClicked` 成功分支仍传 `original: text`。

### 6. 移除首版的文本链接朗读机制（清理）

替换为真按钮后，以下首版新增物成为死代码，**删除**以保持整洁：
- `main.swift`：`speakerPrefix`、`markSpeakBody`、`speakSegment`、`sectionLabel`（若翻译气泡改用 BubbleView 不再需要小节标签则一并删）、`extension PopupController: NSTextViewDelegate`（`clickedOnLink`）、`makeRenderingTextView` 里新增的 `delegate`/`linkTextAttributes`、`speakIdSeq`/`nextSpeakId`。
- `Markdown.swift`：`MD.speakIdKey`。
- 保留：`Speech.swift` 全部、`Speaker.shared.stop()` 在 `stopConversation`/`showMessage`/`onAskSubmit` 的调用、版本号 v1.1 标记。

### 7. 生命周期 / 停止

- 维持首版：`stopConversation`、`showMessage` 开头、`onAskSubmit` 调 `Speaker.shared.stop()`；并在切换播放气泡时把上一个气泡 `setPlaying(false)`。
- `stopConversation` 还需清空 `id → BubbleView` 映射与 `currentAIBubble`。

## 改动清单

- 新增 `popdict-app/Bubble.swift`：`BubbleRole`、`BubbleView`、构造气泡行容器的辅助。
- `popdict-app/build.sh`：`SRCS` 加 `Bubble.swift`（框架已齐）。
- `popdict-app/main.swift`：
  - `installConversationPanel`：transcript 由单 textview 改为 `NSStackView` 文档视图。
  - `convoAppendDelta`/`finishTurn`/`appendUserBubble`/`convoError`：改为操作气泡。
  - 新增 `currentAIBubble`、`bubbleById: [String: BubbleView]`、`bubbleIdSeq`、`onBubbleSpeak(_:)`、播放态联动。
  - `showMessage` 最终译文分支：改用气泡 stack。
  - 删除 §6 列出的文本链接机制。
  - `stopConversation`：清气泡状态。
  - `capturePanel`（UITEST）：part 2 原本截 `convoTextView`，改截 stack 文档视图或移除该 part（dev 辅助，降级即可）。
- `popdict-app/Markdown.swift`：删 `MD.speakIdKey`。

## 已知风险 / 实现时验证

1. **气泡 hug 文本宽度**：短气泡按内容收窄、长气泡到 max 宽换行——Auto Layout 约束需 textview 提供合理 intrinsic 宽。实现时确认换行宽 = max 宽、内容窄时收窄；真机微调。
2. **markdown 在受限宽 ai 气泡内**：表格/代码块可能偏窄，`MD.render` 的 width 传气泡文本可用宽；超宽块允许横向不溢出（必要时气泡内代码块单独处理，先按现有渲染观察）。
3. **流式逐字 + Auto Layout 重排性能**：高频 append 触发布局；如卡顿，沿用"节流"思路（积攒后定时刷新）。
4. **毛玻璃上的气泡配色**：accent/灰底在 vibrancy 上的对比与质感需真机看；备选半透明度可调。
5. **缩放/换宽时气泡重排**：确认 ResizeGrip 改窗宽后 stack 宽跟随、气泡 reflow 正常。
6. **UITEST**：`capturePanel` 与 `runDemoExplain` 仍可跑（截图目标换成 stack）。

## 验证方式

- 编译门禁：单架构 `swiftc` 0 警告；`build.sh` universal 打包通过。
- 真机手测（用户桌面）：
  1. 翻译/解释面板呈左右气泡、留白与字重清爽、像 macOS 原生。
  2. 喇叭是图标按钮；点一下读、**再点一下停**；hover 有反馈；朗读中图标变 stop。
  3. 逐句高亮跟随；切到另一气泡时上一个停止并复位图标。
  4. 流式回答进 AI 气泡；追问进右气泡；错误回滚正常。
  5. 关窗/换词/新追问停止朗读。
  6. 缩放窗口气泡重排正常。

## 不做（YAGNI）

- 不接云端 TTS、不做语速/嗓音设置面板。
- 不做气泡尾巴小三角（tail）等过度拟物；圆角矩形即可，保持克制。
- 不做消息时间戳、头像。
- 不重写翻译的"翻译中/报错"轻量路径。
