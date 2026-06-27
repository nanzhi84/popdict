# 浮窗聊天气泡重做 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`).

**Goal:** 把对话/翻译浮窗重做成 macOS 原生聊天气泡（用户右、AI 左），喇叭改为 SF Symbol 真按钮（点一下读、再点停），逐句高亮保留。

**Architecture:** 对话区由"单 NSTextView + LayoutManager 画满宽底"改为"翻转文档视图里手动堆叠的 `BubbleView` 子视图"（与代码库手动 frame 范式一致）。每个气泡含一个 SF Symbol 喇叭 `NSButton` 和一个复用 `CodeBlockLayoutManager` 的可选中 `NSTextView`（保留代码块圆角底）。气泡宽度按内容 hug、按角色靠左/右、有最大宽上限。

**Tech Stack:** Swift 5 mode / AppKit / AVFoundation / NaturalLanguage；`swiftc`（`build.sh` 显式文件列表）。SF Symbol 需 macOS 11+（目标 12.0）。

## Global Constraints

- macOS 12.0 起步；UTF-8；面向用户文案简体中文。
- 手动 frame 布局为主；气泡列用"翻转视图 + 手动堆叠"。
- 复用 `Speaker`（`Speech.swift`）、`MD.render`/`MD.bodyStyle()`/`CodeBlockLayoutManager`（`Markdown.swift`）、`HoverButton`、`present`/面板/输入栏/缩放/取词。
- 编译自检命令：
  ```bash
  cd popdict-app && swiftc main.swift Markdown.swift Screenshot.swift Config.swift Settings.swift Speech.swift Bubble.swift \
    -target arm64-apple-macos12.0 -swift-version 5 \
    -framework AppKit -framework ApplicationServices -framework Carbon \
    -framework AVFoundation -framework NaturalLanguage -O -o /tmp/popdict_check && echo BUILD_OK
  ```
- 零新增编译警告。

---

### Task 1: `Bubble.swift` — IconButton + BubbleView + 翻转列视图

**Files:**
- Create: `popdict-app/Bubble.swift`
- Modify: `popdict-app/build.sh:24`（`SRCS` 末尾加 `Bubble.swift`）

**Interfaces:**
- Produces:
  - `enum BubbleRole { case user, ai }`
  - `final class IconButton: NSButton`（SF Symbol + hover 透明度）；`var symbolName: String`、`var tint: NSColor`
  - `final class FlippedColumn: NSView`（`isFlipped == true`）
  - `final class BubbleView: NSView`，`init(role:speakId:onSpeak:)`，方法 `setPlainText(_:baseFont:)`、`appendDelta(_:baseFont:)`、`setMarkdown(_:width:baseFont:)`、`setError(_:baseFont:)`、`plainString() -> String`、`setPlaying(_:)`、`@discardableResult func layout(inColumnWidth:) -> CGFloat`、属性 `role`、`speakId`、`textView`

- [ ] **Step 1: 创建 `popdict-app/Bubble.swift`**

```swift
import AppKit

enum BubbleRole { case user, ai }

// 小图标按钮:SF Symbol + hover 提亮(给气泡喇叭用)
final class IconButton: NSButton {
    private var trackingRef: NSTrackingArea?
    private var hovering = false { didSet { alphaValue = hovering ? 1.0 : 0.72 } }
    var tint: NSColor = .secondaryLabelColor { didSet { contentTintColor = tint } }
    var symbolName: String = "speaker.wave.2.fill" {
        didSet {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .semibold)
            image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
        }
    }
    override init(frame f: NSRect) {
        super.init(frame: f)
        isBordered = false; bezelStyle = .regularSquare; imagePosition = .imageOnly
        title = ""; focusRingType = .none; wantsLayer = true
        alphaValue = 0.72
        symbolName = "speaker.wave.2.fill"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t); trackingRef = t
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
}

// 翻转坐标的列容器:y 向下增长,气泡按聊天顺序从上往下排
final class FlippedColumn: NSView {
    override var isFlipped: Bool { true }
}

// 一条消息气泡:圆角底 + 喇叭按钮 + 可选中文本(保留代码块底)
final class BubbleView: NSView {
    let role: BubbleRole
    let speakId: String
    let textView: NSTextView
    private let speakButton = IconButton(frame: .zero)
    private var onSpeak: ((BubbleView) -> Void)?

    private let pad: CGFloat = 12
    private let radius: CGFloat = 13
    private let btn: CGFloat = 18
    private let btnGap: CGFloat = 5

    init(role: BubbleRole, speakId: String, onSpeak: @escaping (BubbleView) -> Void) {
        self.role = role; self.speakId = speakId; self.onSpeak = onSpeak
        let storage = NSTextStorage()
        let lm = CodeBlockLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 10, height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        textView = NSTextView(frame: .zero, textContainer: tc)
        textView.isEditable = false; textView.isSelectable = true
        textView.drawsBackground = false; textView.textContainerInset = .zero
        textView.isHorizontallyResizable = false; textView.isVerticallyResizable = true
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.backgroundColor = fillColor.cgColor
        addSubview(textView)
        speakButton.tint = (role == .user) ? NSColor.white : NSColor.secondaryLabelColor
        speakButton.target = self
        speakButton.action = #selector(speakTapped)
        addSubview(speakButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var fillColor: NSColor {
        role == .user ? NSColor.controlAccentColor
                      : NSColor.secondaryLabelColor.withAlphaComponent(0.13)
    }
    private var fg: NSColor { role == .user ? .white : .labelColor }

    @objc private func speakTapped() { onSpeak?(self) }

    func setPlaying(_ playing: Bool) {
        speakButton.symbolName = playing ? "stop.fill" : "speaker.wave.2.fill"
        speakButton.tint = playing
            ? (role == .user ? .white : .controlAccentColor)
            : (role == .user ? .white : .secondaryLabelColor)
    }

    func setPlainText(_ s: String, baseFont: NSFont) {
        textView.textStorage?.setAttributedString(NSAttributedString(string: s, attributes: [
            .font: baseFont, .foregroundColor: fg, .paragraphStyle: MD.bodyStyle()]))
    }
    func appendDelta(_ s: String, baseFont: NSFont) {
        textView.textStorage?.append(NSAttributedString(string: s, attributes: [
            .font: baseFont, .foregroundColor: fg, .paragraphStyle: MD.bodyStyle()]))
    }
    func setMarkdown(_ s: String, width: CGFloat, baseFont: NSFont) {
        textView.textStorage?.setAttributedString(MD.render(s, width: width, baseFont: baseFont, textColor: fg))
    }
    func setError(_ s: String, baseFont: NSFont) {
        textView.textStorage?.setAttributedString(NSAttributedString(string: s, attributes: [
            .font: baseFont, .foregroundColor: NSColor.systemRed, .paragraphStyle: MD.bodyStyle()]))
    }
    func plainString() -> String { textView.string }

    // 在给定列宽下测量并定位内部子视图,设置并返回自身高度(x 由列管理器后续设定)
    @discardableResult
    func layout(inColumnWidth columnWidth: CGFloat) -> CGFloat {
        let maxFraction: CGFloat = role == .user ? 0.80 : 0.88
        let maxTextW = max(40, columnWidth * maxFraction - pad * 2)
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return frame.height }
        // 先按最大宽排,量出内容真实宽(hug)
        tc.size = NSSize(width: maxTextW, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let textW = min(maxTextW, ceil(lm.usedRect(for: tc).width))
        // 再按 hug 宽排一次,量最终高度
        tc.size = NSSize(width: textW, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let textH = ceil(lm.usedRect(for: tc).height)
        let bubbleW = textW + pad * 2
        let bubbleH = pad + textH + btnGap + btn + pad
        setFrameSize(NSSize(width: bubbleW, height: bubbleH))   // 非翻转:内部自有坐标(原点左下)
        // 喇叭在顶行(ai 左、user 右),文本在其下
        let topY = bubbleH - pad - btn
        speakButton.frame = NSRect(x: role == .ai ? pad : bubbleW - pad - btn, y: topY, width: btn, height: btn)
        textView.frame = NSRect(x: pad, y: pad, width: textW, height: textH)
        return bubbleH
    }
}
```

- [ ] **Step 2: build.sh 登记 Bubble.swift**

把 `popdict-app/build.sh:24`：
```bash
SRCS="main.swift Markdown.swift Screenshot.swift Config.swift Settings.swift Speech.swift"
```
改为：
```bash
SRCS="main.swift Markdown.swift Screenshot.swift Config.swift Settings.swift Speech.swift Bubble.swift"
```

- [ ] **Step 3: 编译自检**

Run: Global Constraints 编译自检命令。
Expected: `BUILD_OK`，0 警告（BubbleView 暂无人用，应能独立编译）。

- [ ] **Step 4: 提交**

```bash
git add popdict-app/Bubble.swift popdict-app/build.sh
git commit -m "feat(ui): 加 BubbleView 气泡组件(SF Symbol 喇叭真按钮 + 翻转列)"
```

---

### Task 2: Speaker 增加"播放结束"回调（让气泡图标复位）

**Files:**
- Modify: `popdict-app/Speech.swift`

**Interfaces:**
- Produces: `var Speaker.onPlaybackEnded: (() -> Void)?`（didFinish/didCancel 时在主线程调用）

- [ ] **Step 1: 加回调属性**

在 `Speaker` 的属性区（`private var activeSpeakId: String?` 之后）新增：
```swift
    // 朗读自然结束/被取消时回调(控制器据此把气泡图标复位)
    var onPlaybackEnded: (() -> Void)?
```

- [ ] **Step 2: didFinish/didCancel 里触发**

把：
```swift
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        clearHighlight(); activeSpeakId = nil
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        clearHighlight(); activeSpeakId = nil
    }
```
改为：
```swift
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        clearHighlight(); activeSpeakId = nil; onPlaybackEnded?()
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        clearHighlight(); activeSpeakId = nil; onPlaybackEnded?()
    }
```

- [ ] **Step 3: 编译自检 + 提交**

Run: 编译自检命令 → `BUILD_OK`。
```bash
git add popdict-app/Speech.swift
git commit -m "feat(tts): Speaker 加 onPlaybackEnded 回调(供气泡图标复位)"
```

---

### Task 3: 对话面板改为气泡列（核心）

**Files:**
- Modify: `popdict-app/main.swift`：属性区、`installConversationPanel`、`convoAppendDelta`、`finishTurn`、`appendUserBubble`、`convoError`、`stopConversation`、滚动辅助、新增气泡相关方法。

**Interfaces:**
- Consumes: `BubbleView`/`BubbleRole`/`FlippedColumn`（Task 1）、`Speaker.shared`/`onPlaybackEnded`（Task 2）
- Produces（控制器内部）：`bubbleColumn: FlippedColumn?`、`currentAIBubble: BubbleView?`、`playingBubble: BubbleView?`、`bubbleIdSeq`、`makeBubble(role:) -> BubbleView`、`addBubble(_:)`、`relayoutBubbles()`、`onBubbleSpeak(_:)`

- [ ] **Step 1: 新增气泡状态属性**

在属性区（`private var speakIdSeq = 0` 这一带，Task 旧物稍后在 Task 5 删；此处先加新物）新增：
```swift
    private weak var bubbleColumn: FlippedColumn?     // 对话/译文气泡列(scroll 的 documentView)
    private weak var currentAIBubble: BubbleView?     // 当前流式中的 AI 气泡
    private weak var playingBubble: BubbleView?       // 当前朗读中的气泡(切换时复位图标)
    private var bubbleIdSeq = 0
```

- [ ] **Step 2: 气泡工具方法 + 朗读接线**

在 `measuredTextHeight` 之前新增（与首版朗读工具同区；首版那几个方法 Task 5 删）：
```swift
    private func nextBubbleId() -> String { bubbleIdSeq += 1; return "b\(bubbleIdSeq)" }

    private func makeBubble(role: BubbleRole) -> BubbleView {
        return BubbleView(role: role, speakId: nextBubbleId()) { [weak self] b in self?.onBubbleSpeak(b) }
    }
    private func addBubble(_ b: BubbleView) {
        bubbleColumn?.addSubview(b)
        relayoutBubbles()
    }
    // 重排气泡列:逐个量高、按角色靠左/右、从上往下堆叠,设 documentView 高度
    private func relayoutBubbles() {
        guard let col = bubbleColumn, let scroll = convoScroll else { return }
        let colW = scroll.contentView.bounds.width
        let gap: CGFloat = 10, sidePad: CGFloat = 14, topPad: CGFloat = 12
        // 按加入顺序(subviews 顺序)排列
        let bubbles = col.subviews.compactMap { $0 as? BubbleView }
        var y = topPad
        for b in bubbles {
            let h = b.layout(inColumnWidth: colW - sidePad * 2)
            let x = b.role == .ai ? sidePad : colW - sidePad - b.frame.width
            b.setFrameOrigin(NSPoint(x: x, y: y))
            y += h + gap
        }
        let totalH = max(scroll.contentView.bounds.height, y + topPad)
        col.setFrameSize(NSSize(width: colW, height: totalH))
    }

    // 点气泡喇叭:点正在读的=停;否则切过去读
    @objc private func onBubbleSpeak(_ bubble: BubbleView) {
        if Speaker.shared.isSpeaking(bubble.speakId) { Speaker.shared.stop(); return }
        playingBubble?.setPlaying(false)
        let len = bubble.textView.textStorage?.length ?? 0
        Speaker.shared.speak(bubble.plainString(), in: bubble.textView,
                             bodyRange: NSRange(location: 0, length: len), speakId: bubble.speakId)
        playingBubble = bubble
        bubble.setPlaying(true)
    }
```

- [ ] **Step 3: `installConversationPanel` 用气泡列替换单 textview**

把 `installConversationPanel`（约 622 行）里建 transcript 的那段：
```swift
        let tv = makeTranscriptView(width: textW)
        scroll.documentView = tv
        container.addSubview(scroll)
        convoScroll = scroll
        convoTextView = tv
```
改为：
```swift
        let col = FlippedColumn(frame: NSRect(x: 0, y: 0, width: textW, height: scrollH))
        col.autoresizingMask = [.width]
        scroll.documentView = col
        container.addSubview(scroll)
        convoScroll = scroll
        bubbleColumn = col
        // 朗读自然结束 → 复位当前气泡图标
        Speaker.shared.onPlaybackEnded = { [weak self] in
            self?.playingBubble?.setPlaying(false); self?.playingBubble = nil
        }
```
（`convoTextView` 不再用于对话；其声明保留给"翻译中/报错"单文本路径，对话路径不再赋值。`makeTranscriptView` 若仅此处用则 Task 5 评估删除。）

- [ ] **Step 4: `convoAppendDelta` / `finishTurn` 改为操作 AI 气泡**

把 `convoAppendDelta`（约 828 行）：
```swift
    private func convoAppendDelta(_ delta: String) {
        guard let tv = convoTextView, panel != nil else { return }
        assistantAccum += delta
        tv.textStorage?.append(NSAttributedString(string: delta, attributes: [
            .font: convoFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: MD.bodyStyle()]))
        scrollTranscriptToBottom()
    }
```
改为：
```swift
    private func convoAppendDelta(_ delta: String) {
        guard let bubble = currentAIBubble, panel != nil else { return }
        assistantAccum += delta
        bubble.appendDelta(delta, baseFont: convoFont)
        relayoutBubbles()
        scrollTranscriptToBottom()
    }
```

把 `finishTurn`（约 838 行）里替换渲染的整段：
```swift
        if let tv = convoTextView, let storage = tv.textStorage {
            let len = max(0, storage.length - assistantStart)
            let rendered = MD.render(text, width: (panel?.frame.width ?? convoW) - convoPad * 2, baseFont: convoFont, textColor: .labelColor)
            let id = nextSpeakId()
            let combined = NSMutableAttributedString()
            combined.append(speakerPrefix(id: id))
            let bodyStart = combined.length
            combined.append(rendered)
            combined.addAttribute(MD.speakIdKey, value: id,
                                  range: NSRange(location: bodyStart, length: combined.length - bodyStart))
            storage.replaceCharacters(in: NSRange(location: assistantStart, length: len), with: combined)
        }
```
改为：
```swift
        if let bubble = currentAIBubble {
            let w = bubble.role == .ai ? (panel?.frame.width ?? convoW) * 0.88 - convoPad * 2
                                       : (panel?.frame.width ?? convoW) - convoPad * 2
            bubble.setMarkdown(text, width: max(80, w), baseFont: convoFont)
            relayoutBubbles()
        }
```
（`assistantStart`/`assistantAccum` 不再用于裁剪单 textview，可保留为空操作或 Task 5 清理；本步不删以缩小改动面。）

- [ ] **Step 5: `sendTurn` 起一轮时新建 AI 气泡**

在 `sendTurn`（约 802 行）开头 `assistantStart = ...` 之后、`setInputEnabled(false, ...)` 附近，新增创建空 AI 气泡：
```swift
        let ai = makeBubble(role: .ai)
        currentAIBubble = ai
        addBubble(ai)
```
（放在真正发请求 `chatStream` 之前即可。）

- [ ] **Step 6: `appendUserBubble` 改为加用户气泡**

把 `appendUserBubble(_:to:)`（约 916 行）整体替换为：
```swift
    private func appendUserBubble(_ q: String, to tv: NSTextView) {
        let b = makeBubble(role: .user)
        b.setPlainText(q, baseFont: NSFont.systemFont(ofSize: 14, weight: .medium))
        addBubble(b)
    }
```
（保留签名以减少改 `onAskSubmit` 的调用处；`tv` 参数不再使用。）

- [ ] **Step 7: `convoError` 追问失败移除半截气泡 + 错误气泡**

把 `convoError`（约 872 行）里"追问失败回滚"那段：
```swift
        if convo.count > 1, convo.last?.role == "user" { convo.removeLast() }
        if let tv = convoTextView, let storage = tv.textStorage {
            let len = max(0, storage.length - turnStartLoc)
            if len > 0 { storage.deleteCharacters(in: NSRange(location: turnStartLoc, length: len)) }
            storage.append(NSAttributedString(string: "\n⚠️ \(msg)\n", attributes: [
                .font: convoFont, .foregroundColor: NSColor.systemRed, .paragraphStyle: MD.bodyStyle()]))
        }
```
改为：
```swift
        if convo.count > 1, convo.last?.role == "user" { convo.removeLast() }
        // 移除本轮半截 AI 气泡,改插错误气泡
        if let ai = currentAIBubble { ai.removeFromSuperview(); currentAIBubble = nil }
        let err = makeBubble(role: .ai)
        err.setError("⚠️ \(msg)", baseFont: convoFont)
        addBubble(err)
```
（首轮失败分支不变,仍 `stopConversation()` + `showMessage(错误)`。）

- [ ] **Step 8: 滚动辅助适配气泡列 + stopConversation 清状态**

把 `scrollTranscriptToBottom`（约 969 行）：
```swift
    private func scrollTranscriptToBottom() {
        guard let tv = convoTextView else { return }
        tv.scrollRangeToVisible(NSRange(location: tv.textStorage?.length ?? 0, length: 0))
    }
```
改为：
```swift
    private func scrollTranscriptToBottom() {
        guard let col = bubbleColumn, let scroll = convoScroll else { return }
        let maxY = max(0, col.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
```

把 `scrollTranscript(toLocation:)` 的调用点（`finishTurn` 里 `scrollTranscript(toLocation: turnStartLoc)`）改为滚到当前 AI 气泡顶部：
```swift
        if let ai = currentAIBubble, let scroll = convoScroll {
            let y = max(0, ai.frame.minY - 8)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
```
（替换 `finishTurn` 里那一行 `scrollTranscript(toLocation: turnStartLoc)`；`scrollTranscript(toLocation:)` 函数本体若无其它调用,Task 5 删。）

在 `stopConversation()`（约 956 行）里 `convoTextView = nil` 一带新增：
```swift
        bubbleColumn = nil
        currentAIBubble = nil
        playingBubble = nil
        Speaker.shared.onPlaybackEnded = nil
```

- [ ] **Step 9: 窗口缩放时重排气泡**

在 `windowDidEndLiveResize`（约 1066 行,`PopupController` 已实现该 NSWindowDelegate 方法）函数体末尾新增：
```swift
        relayoutBubbles()
```

- [ ] **Step 10: 编译自检**

Run: 编译自检命令。
Expected: `BUILD_OK`（首版的 `speakerPrefix`/`speakSegment` 等此时仍在但暂时无人用于对话；翻译路径 Task 4 改完后 Task 5 统一删）。若报"未使用变量 tv/assistantStart"等警告，记录待 Task 5 清理；本步要求 0 *错误*。

- [ ] **Step 11: 提交**

```bash
git add popdict-app/main.swift
git commit -m "feat(ui): 对话面板改为聊天气泡列(流式/追问/错误/缩放/朗读真按钮)"
```

---

### Task 4: 翻译面板气泡化

**Files:**
- Modify: `popdict-app/main.swift` `showMessage`（最终译文分支约 988-1016 行）

**Interfaces:**
- Consumes: `makeBubble`/`addBubble`/`relayoutBubbles`/`FlippedColumn`（Task 3）

- [ ] **Step 1: 最终译文分支改用气泡列**

把 `showMessage` 里"构造 attr + 放进单 textview"的逻辑，在 `showCopy && markdown && original != nil` 时改为气泡列。具体：在创建 `scroll` 后，最终译文分支不再 `scroll.documentView = tv`，而是：
```swift
        if showCopy, markdown, let original = original {
            let col = FlippedColumn(frame: NSRect(x: 0, y: 0, width: textW, height: visibleH))
            col.autoresizingMask = [.width]
            scroll.documentView = col
            bubbleColumn = col
            convoScroll = scroll
            Speaker.shared.onPlaybackEnded = { [weak self] in
                self?.playingBubble?.setPlaying(false); self?.playingBubble = nil
            }
            let ob = makeBubble(role: .user); ob.setPlainText(original, baseFont: NSFont.systemFont(ofSize: 14, weight: .medium)); addBubble(ob)
            let tb = makeBubble(role: .ai); tb.setMarkdown(message, width: max(80, textW * 0.88 - 24), baseFont: font); addBubble(tb)
        } else {
            let tv = makeRenderingTextView(width: textW)
            tv.textColor = textColor
            tv.minSize = NSSize(width: textW, height: visibleH)
            tv.textStorage?.setAttributedString(attr)
            scroll.documentView = tv
        }
```
为此需要：
1. 删掉/改造原本无条件创建 `attr` 与 `tv` 并 `scroll.documentView = tv` 的代码，使其落入上面的 `else` 分支（"翻译中/报错"和非原文情形仍走 `else`，`attr` 仍按原逻辑构造）。
2. 把原先构造 `attr` 的"原文+译文双段 + speakerPrefix"块删除，`attr` 只保留：
```swift
        let attr: NSAttributedString = markdown
            ? MD.render(message, width: textW, baseFont: font, textColor: textColor)
            : NSAttributedString(string: message, attributes: [.font: font, .foregroundColor: textColor])
```
（`attr` 仅供 `else` 分支用；气泡分支自渲染。）

- [ ] **Step 2: 编译自检**

Run: 编译自检命令。
Expected: `BUILD_OK`。

- [ ] **Step 3: 提交**

```bash
git add popdict-app/main.swift
git commit -m "feat(ui): 翻译面板改为原文/译文气泡"
```

---

### Task 5: 删除首版文本链接朗读机制 + 收尾构建 + 手测

**Files:**
- Modify: `popdict-app/main.swift`（删 `speakerPrefix`/`markSpeakBody`/`speakSegment`/`sectionLabel`/`speakIdSeq`/`nextSpeakId`/`clickedOnLink` 扩展/`makeRenderingTextView` 的 delegate&linkTextAttributes；清理 `makeTranscriptView`/`scrollTranscript(toLocation:)`/`assistantStart`/`assistantAccum` 等确认无用者）
- Modify: `popdict-app/Markdown.swift`（删 `MD.speakIdKey`）

- [ ] **Step 1: 删除 main.swift 中的文本链接机制**

逐一删除（确认 Task 3/4 后已无引用）：
- `speakerPrefix(id:extra:)`、`markSpeakBody(_:range:id:)`、`speakSegment(id:in:)`、`sectionLabel(_:)`
- `private var speakIdSeq = 0`、`nextSpeakId()`
- 文件末尾 `extension PopupController: NSTextViewDelegate { ... clickedOnLink ... }` 整段
- `makeRenderingTextView` 里新增的 `tv.delegate = self`、`tv.linkTextAttributes = [...]` 三行
- 若 `makeTranscriptView`、`scrollTranscript(toLocation:)` 已无调用 → 一并删

- [ ] **Step 2: 删 MD.speakIdKey**

删除 `Markdown.swift` 的：
```swift
    // 朗读段落标记:Speaker 据此扫描出某段正文的字符范围(取文字 + 逐句高亮定位)
    static let speakIdKey = NSAttributedString.Key("popdictSpeakId")
```

- [ ] **Step 3: 用编译器找残留引用**

Run: 编译自检命令。
Expected: 若仍引用已删符号会报错；据报错把残留改掉，直到 `BUILD_OK` 且 0 警告。

- [ ] **Step 4: 全量打包构建**

Run:
```bash
cd popdict-app && bash build.sh 2>&1 | tail -8
```
Expected: 走到 `==> 5/5 完成`，universal（x86_64+arm64）+ 签名 + dmg，无报错。

- [ ] **Step 5: 提交**

```bash
git add popdict-app/main.swift popdict-app/Markdown.swift
git commit -m "refactor(tts): 移除首版文本链接朗读机制(被气泡真按钮取代)"
```

- [ ] **Step 6: 替换安装到 /Applications 供手测**

```bash
killall popdict 2>/dev/null; sleep 1
rm -rf /Applications/popdict.app && ditto popdict-app/popdict.app /Applications/popdict.app
open /Applications/popdict.app
```

- [ ] **Step 7: 手测清单（用户桌面）**

1. 解释/翻译面板呈**左右气泡**、留白与字重清爽、像 macOS 原生。
2. 喇叭是 SF Symbol 图标按钮；**点一下读、再点一下停**；hover 提亮；朗读中图标变 `stop.fill`。
3. 逐句高亮跟随；切到另一气泡时上一个停止并复位图标。
4. 流式回答进 AI 气泡；追问进右侧用户气泡；首轮/追问失败回滚正常。
5. 关窗/换词/新追问停止朗读。
6. 缩放窗口气泡重排正常。
7. 翻译面板：原文（右）/译文（左）两气泡，各自喇叭可读。

---

## Self-Review

**1. Spec coverage：**
- 气泡组件 + SF Symbol 真按钮 → Task 1 ✓
- 稳定 toggle → Task 3 `onBubbleSpeak`（真按钮 + isSpeaking 判定）✓
- 播放结束图标复位 → Task 2 `onPlaybackEnded` + Task 3 联动 ✓
- 对话区气泡列(流式/追问/错误/滚动/缩放) → Task 3 ✓
- 翻译面板气泡化 → Task 4 ✓
- 逐句高亮(每气泡独立 textview) → Task 3 `onBubbleSpeak` 传该气泡 textview + 全范围 ✓
- 删除首版文本链接机制 + MD.speakIdKey → Task 5 ✓
- 生命周期停止/清状态 → Task 3 Step 8 + 保留首版 Speaker.stop 调用 ✓
- build.sh 登记 Bubble.swift → Task 1 ✓

**2. Placeholder scan：** 无 TBD/TODO；像素数值为初值,实现后真机微调(非占位)。✓

**3. Type consistency：**
- `BubbleView(role:speakId:onSpeak:)`、`setPlainText(_:baseFont:)`、`appendDelta(_:baseFont:)`、`setMarkdown(_:width:baseFont:)`、`setError(_:baseFont:)`、`setPlaying(_:)`、`plainString()`、`layout(inColumnWidth:)`、`role`/`speakId`/`textView` 在 Task 1 定义,Task 3/4 一致使用 ✓
- `Speaker.onPlaybackEnded`(Task 2)、`Speaker.shared.speak(_:in:bodyRange:speakId:)`/`stop()`/`isSpeaking(_:)`(沿用) ✓
- `makeBubble`/`addBubble`/`relayoutBubbles`/`onBubbleSpeak`/`bubbleColumn`/`currentAIBubble`/`playingBubble`(Task 3) 一致 ✓
