# 语音朗读 + 显示划词原文 — 设计

日期：2026-06-27
范围：popdict（macOS 原生划词翻译，Swift）

## 背景与目标

用户提出两个需求：

1. **语音朗读**：原文、译文、解释（含追问）每一段文字旁都能点喇叭朗读，自己选择读哪一段。主要诉求是朗读英文原文。
2. **显示最初划入的原文**：当前翻译面板只显示译文、解释面板只显示 LLM 回答与追问，最初划入的词/句没有显示（只有图片解释显示了指令）。希望把原文显示出来。

## 现状（代码事实）

全部相关代码在 `popdict-app/main.swift` 的 `PopupController`（单文件，约 1488 行），辅以 `Markdown.swift`（`MD` 渲染器）、`Config.swift`、`Screenshot.swift`、`Settings.swift`。

- `pendingText` 存的是**纯划词原文**；翻译与解释都直接使用它，未包裹 prompt。
- 解释模式 `beginConversation(firstUserText:)`（约 657 行）把原文存入 `convo[0]`，但**没有**把它写进 transcript；截图解释 `beginImageConversation`（674 行）在 692–697 行把指令写进了面板，所以图片那条能显示。这是"解释模式原文不显示"的直接根因。
- 翻译模式 `showMessage(_:isError:showCopy:markdown:)`（约 972 行）是通用渲染函数，"翻译中…"、报错、最终译文都走它；最终译文走 `showCopy: true, markdown: true` 分支，结构上没有原文块。
- 两个面板的正文都是 `NSTextView`（`makeRenderingTextView` 创建，718 行；transcript 版 `makeTranscriptView` 738 行）。
- 全项目无任何 TTS 代码。
- 现有 `MD` 自定义属性键：`MD.userMsgKey`（追问气泡背景）、`MD.codeBlockKey`（代码块圆角底）。
- 现有按钮组件 `HoverButton`（356–409 行）。

## 已确认的产品决策

- 朗读引擎：**系统离线语音**（`AVSpeechSynthesizer`），离线、免费、即点即读。
- 对话面板喇叭位置：**每段开头一个 🔊**（原文、每条 AI 回答、每条追问）。
- 朗读细节：**逐句高亮**当前正在朗读的句子。

## 总体方案

### 1. 统一机制：用"文本链接"做喇叭

不在 `NSTextView` 上叠浮动按钮（会随滚动/缩放错位），而是把 🔊 作为**可点击的文本链接**插在每段开头：

- 链接值用自定义 scheme，如 `popdict-speak://<id>`（`id` 为该段分配的短标识）。
- `PopupController` 实现 `NSTextViewDelegate.textView(_:clickedOnLink:at:)`，拦截该 scheme → 触发朗读，返回 `true`（已处理）。
- 通过 `tv.linkTextAttributes` 把链接样式设为"无下划线、正常颜色"，让 🔊 看起来是普通图标而非蓝色链接。
- `makeRenderingTextView` 统一设 `tv.delegate = self`，两个面板复用同一回调。

翻译面板与对话面板因此共用同一套喇叭机制，逐句高亮也统一。

### 2. 段落定位：隐藏标记属性 `MD.speakIdKey`

- 在 `Markdown.swift` 的 `MD` 命名空间新增 `static let speakIdKey = NSAttributedString.Key("speakId")`。
- 插入每段正文时，对**正文字符范围**叠加 `speakIdKey = <id>`（🔊 链接字符本身不加，避免被算进正文/高亮）。
- 朗读时用 `enumerateAttribute(speakIdKey:)` 在当前 `textStorage` 扫描出该 id 对应的连续字符范围 → 得到：(a) 要朗读的文字 `storage.attributedSubstring(from: range).string`，(b) 高亮区间。
- 该范围**动态扫描**，不怕 markdown 重渲染（`finishTurn` 的 `replaceCharacters`）或后续追问 append 造成的位移：标记是叠加属性，只要该范围未被再次整体替换即长期有效；assistant 段在 `finishTurn` 替换为 markdown **之后**再叠加标记。

### 3. TTS 引擎：新文件 `Speech.swift`

- `final class Speaker: NSObject, AVSpeechSynthesizerDelegate`，单例 `Speaker.shared`，持有一个 `AVSpeechSynthesizer`。
- 语言判别：用 `NaturalLanguage` 的 `NLLanguageRecognizer` 取主导语言；中文 → `zh-CN` 嗓音，英文 → `en-US` 嗓音，其余按识别结果回退；用 `AVSpeechSynthesisVoice(language:)` 取最佳匹配。
- API（示意）：`func speak(_ text: String, in textView: NSTextView, bodyRange: NSRange, speakId: String)`。
  - **播放/停止切换**：若当前正在朗读的 `speakId` 与传入相同 → `stop()`（停止并清高亮）；否则停掉旧的、开始新的。
- 逐句高亮：实现 `speechSynthesizer(_:willSpeakRangeOfSpeechString:utterance:)`。`willSpeakRange` 是相对 utterance 字符串的范围；utterance 字符串即 `bodyRange` 子串，故 textView 范围 = `bodyRange.location + willSpeakRange.location`，长度 `willSpeakRange.length`。用临时背景色属性（淡 `controlAccentColor`）描出；每次回调前清除上一段高亮。
- 清理：`stop()` 清除最后一次高亮（在 textView 仍有效时移除临时 `.backgroundColor`）。`didFinish`/`didCancel` 委托里清高亮、复位状态。
- 弱引用当前 `textView`，避免面板销毁后悬挂。

### 4. 功能二：显示最初划入的原文

- **解释面板**：`beginConversation` 在 `installConversationPanel` 之后、`sendTurn` 之前，参照 692–697 把 `firstUserText` 写进 transcript，并在该段开头挂 🔊 链接、对正文叠 `speakIdKey`。
- **翻译面板**：`showMessage` 最终译文分支（`showCopy && markdown`）里，把渲染内容从"仅译文"改为：
  - `🔊 原文`（小号"原文"标签 + 原文，稍暗样式）
  - 分隔
  - `🔊 译文`（小号"译文"标签 + markdown 译文）
  - 两段都在同一个结果 `NSTextView` 内，各带 `speakIdKey`。
  - "翻译中…"/报错分支不变（不显示原文、不挂喇叭）。
  - 原文经新增参数传入：给 `showMessage` 增加 `original: String? = nil`，`onTranslateClicked` 在成功分支传入 `text`（即 `pendingText`）。

### 5. 功能一：每段都有喇叭

- 对话面板三处插 🔊：
  - 原文：见 §4（`beginConversation`）。
  - AI 回答：`finishTurn` 把流式纯文本替换为 markdown 后，在该段前插 🔊、对 rendered 范围叠 `speakIdKey`。
  - 追问：`appendUserBubble` 在"你的追问"气泡正文前插 🔊、叠 `speakIdKey`。
- 翻译面板：原文、译文各一个 🔊（见 §4）。

### 6. 生命周期与停止

- `stopConversation()`、`dismiss()` 中调用 `Speaker.shared.stop()`，关窗/换词/新会话时立即停止朗读并清高亮。
- `generation` 自增的时机（关窗、新划词、新会话）天然界定"应停止朗读"的时刻。

## 改动清单

- 新增 `popdict-app/Speech.swift`：`Speaker` 类（引擎 + 语言判别 + 高亮委托）。
- `popdict-app/Markdown.swift`：新增 `MD.speakIdKey`；可加一个小工具构造"🔊 链接前缀"富文本（也可放在 main.swift）。
- `popdict-app/main.swift`：
  - `PopupController` 符合 `NSTextViewDelegate`，实现 `clickedOnLink`。
  - `makeRenderingTextView` 设 `delegate` 与 `linkTextAttributes`。
  - `beginConversation` 补原文显示 + 🔊。
  - `finishTurn`、`appendUserBubble` 各插 🔊 + 叠 `speakIdKey`。
  - `showMessage` 增 `original` 参数，最终译文分支渲染原文+译文双段 + 双 🔊。
  - `onTranslateClicked` 成功分支传 `original: text`。
  - `stopConversation`、`dismiss` 调 `Speaker.shared.stop()`。
- `popdict-app/build.sh`：编译用**显式文件列表**（第 24 行 `SRCS="main.swift Markdown.swift Screenshot.swift Config.swift Settings.swift"`），且只链了 `AppKit ApplicationServices Carbon`。需：
  - 把 `Speech.swift` 加进 `SRCS`；
  - 给两条 `swiftc` 命令补 `-framework AVFoundation -framework NaturalLanguage`。
  - 开发期快速编译校验可只跑单架构：`swiftc $SRCS -target arm64-apple-macos12.0 -framework AppKit -framework ApplicationServices -framework Carbon -framework AVFoundation -framework NaturalLanguage -o /tmp/popdict_check`（不打包、不签名、不出 dmg）。

## 已知风险 / 实现时需验证

1. **nonactivating 后台浮窗的链接点击**：面板是 `nonactivating`（不抢焦点）。需真机验证 `NSTextView` 的 `clickedOnLink` 在首次点击即触发。若标准回调不灵，退路：对 🔊 字符在 `mouseDown` 时做命中判断（命中即朗读），参照 `HoverButton` 的自定义点击思路。
2. **逐句高亮的字符映射**：`willSpeakRange` 与 `bodyRange` 子串需 1:1 对齐；附件（图片/代码块占位 `U+FFFC`）计 1 字符，范围仍对齐，可接受朗读时跳过/读错附件占位符。
3. **朗读中 transcript 变动**：朗读时若发起新一轮（append/replace），可能移动高亮范围；通过"新轮次前 `Speaker.stop()`"规避。
4. **嗓音可用性**：某些系统可能缺少高质量中/英嗓音，`AVSpeechSynthesisVoice(language:)` 回退到默认嗓音即可，不阻断功能。

## 验证方式

- 复用现有 `POPDICT_UITEST` 自测路径（程序化驱动解释/追问 + 截图）确认原文显示、🔊 出现、布局不破。
- 真机手测：英文原文点 🔊 用英文嗓朗读、中文译文用中文嗓；逐句高亮跟随；再点同段停止；切段切换；关窗停止。
- 翻译面板：原文与译文都显示、各自 🔊 可读。

## 不做（YAGNI）

- 不接云端 TTS、不做语速/嗓音设置面板（先用系统默认；后续可加）。
- 不做全局快捷键朗读、不做自动朗读。
- 不重构两个面板为统一 transcript（保留现有经过调校的布局，降低风险）。
