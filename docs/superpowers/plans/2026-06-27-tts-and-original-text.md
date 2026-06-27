# 语音朗读 + 显示划词原文 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 popdict 加"每段文字点喇叭朗读（系统离线语音 + 逐句高亮）"，并把最初划入的原文显示在翻译面板和解释面板里。

**Architecture:** 喇叭统一用"可点击文本链接（`popdict-speak://<id>`）"插在每段开头，点击经 `NSTextViewDelegate.clickedOnLink` 路由到 `Speaker`（封装 `AVSpeechSynthesizer`）。每段正文叠一个隐藏标记属性 `MD.speakIdKey`，朗读时按 id 扫描出正文范围 → 取文字 + 定位逐句高亮。原文显示：解释面板补写 transcript、翻译面板在结果分支渲染"原文+译文"双段。

**Tech Stack:** Swift 5 / AppKit / AVFoundation（`AVSpeechSynthesizer`）/ NaturalLanguage（`NLLanguageRecognizer`）；手写 `swiftc` 构建（`popdict-app/build.sh`，显式文件列表）。

## Global Constraints

- 最低系统：macOS 12.0（`build.sh` 的 `MIN_OS=12.0`）。`AVSpeechSynthesizer`、`willSpeakRangeOfSpeechString`、`NLLanguageRecognizer` 均 ≥ macOS 10.15，满足。
- 一律 UTF-8；面向用户的文案用简体中文。
- 构建用显式文件列表：`build.sh` 第 24 行 `SRCS=...`，新增源文件必须登记，并按需补 `-framework`。
- 所有相关 UI 代码集中在 `popdict-app/main.swift` 的 `PopupController`；Markdown 属性键在 `popdict-app/Markdown.swift` 的 `MD` 命名空间。
- 朗读引擎：系统离线 `AVSpeechSynthesizer`（不联网、不接云端 TTS）。
- 喇叭机制：文本链接 scheme 固定为 `popdict-speak://<id>`，`id` 由自增计数器产出（形如 `seg1`、`seg2`，URL 安全）。
- 隐藏标记属性键名：`MD.speakIdKey`（`NSAttributedString.Key("popdictSpeakId")`）。
- 编译自检命令（单架构，不打包/不签名）：
  ```bash
  cd popdict-app && swiftc main.swift Markdown.swift Screenshot.swift Config.swift Settings.swift Speech.swift \
    -target arm64-apple-macos12.0 -swift-version 5 \
    -framework AppKit -framework ApplicationServices -framework Carbon \
    -framework AVFoundation -framework NaturalLanguage -O -o /tmp/popdict_check && echo BUILD_OK
  ```

---

### Task 1: TTS 引擎 `Speech.swift` + `MD.speakIdKey` + build.sh 接框架

**Files:**
- Create: `popdict-app/Speech.swift`
- Modify: `popdict-app/Markdown.swift:15`（在 `userMsgKey` 后加 `speakIdKey`）
- Modify: `popdict-app/build.sh:24-26`（`SRCS` 加 `Speech.swift`，两条 `swiftc` 补两个 framework）
- Test: 临时文件 `$CLAUDE_JOB_DIR/tmp/test_speak.swift`（编译+运行验证 `voiceLanguage(for:)`，不提交）

**Interfaces:**
- Produces:
  - `MD.speakIdKey: NSAttributedString.Key`
  - `final class Speaker: NSObject, AVSpeechSynthesizerDelegate`，单例 `Speaker.shared`
  - `static func Speaker.voiceLanguage(for text: String) -> String`
  - `func Speaker.speak(_ text: String, in textView: NSTextView, bodyRange: NSRange, speakId: String)`
  - `func Speaker.stop()`
  - `func Speaker.isSpeaking(_ speakId: String) -> Bool`

- [ ] **Step 1: 写失败测试（语言判别纯函数）**

创建 `$CLAUDE_JOB_DIR/tmp/test_speak.swift`：

```swift
import Foundation

assert(Speaker.voiceLanguage(for: "hello world, this is a short english sentence") == "en-US", "应判英文")
assert(Speaker.voiceLanguage(for: "这是一段用于测试的简体中文文本内容") == "zh-CN", "应判中文")
print("voiceLanguage OK")
```

- [ ] **Step 2: 运行测试，确认失败**

Run:
```bash
cd popdict-app && swiftc Speech.swift "$CLAUDE_JOB_DIR/tmp/test_speak.swift" \
  -framework AppKit -framework AVFoundation -framework NaturalLanguage -o /tmp/ttstest 2>&1 | head
```
Expected: 编译失败，`error: cannot find 'Speaker' in scope`（`Speech.swift` 尚未创建）。

- [ ] **Step 3: 创建 `popdict-app/Speech.swift`**

```swift
import AppKit
import AVFoundation
import NaturalLanguage

// 系统离线语音朗读 + 逐句高亮。
// 朗读对象由调用方给出:某个 NSTextView 里 bodyRange 这段连续正文(由 MD.speakIdKey 标定)。
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    private let synth = AVSpeechSynthesizer()
    private weak var activeTextView: NSTextView?
    private var activeBodyRange = NSRange(location: 0, length: 0)
    private var lastHighlight: NSRange?
    private var activeSpeakId: String?
    private let highlightColor = NSColor.controlAccentColor.withAlphaComponent(0.28)

    override init() {
        super.init()
        synth.delegate = self
    }

    // 当前是否正在朗读这个 id(用于「点同一段=停止」的切换判断)
    func isSpeaking(_ speakId: String) -> Bool {
        return synth.isSpeaking && activeSpeakId == speakId
    }

    // 选嗓音语言:中文→zh-CN,英文→en-US,其它按识别结果,识别不出→系统当前语言
    static func voiceLanguage(for text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage else {
            return AVSpeechSynthesisVoice.currentLanguageCode()
        }
        switch lang {
        case .simplifiedChinese, .traditionalChinese: return "zh-CN"
        case .english: return "en-US"
        default: return lang.rawValue
        }
    }

    // 朗读 textView 中 bodyRange 这段;若正在读的就是同一段 → 停止(切换)
    func speak(_ text: String, in textView: NSTextView, bodyRange: NSRange, speakId: String) {
        if isSpeaking(speakId) { stop(); return }
        stop()   // 停掉上一段并清掉旧高亮

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        activeTextView = textView
        activeBodyRange = bodyRange
        activeSpeakId = speakId

        let utter = AVSpeechUtterance(string: text)
        utter.voice = AVSpeechSynthesisVoice(language: Speaker.voiceLanguage(for: text))
        synth.speak(utter)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        clearHighlight()
        activeSpeakId = nil
        activeTextView = nil
    }

    private func clearHighlight() {
        defer { lastHighlight = nil }
        guard let tv = activeTextView, let storage = tv.textStorage, let r = lastHighlight,
              NSMaxRange(r) <= storage.length else { return }
        storage.removeAttribute(.backgroundColor, range: r)
    }

    // MARK: AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        guard let tv = activeTextView, let storage = tv.textStorage else { return }
        clearHighlight()
        let loc = activeBodyRange.location + characterRange.location
        guard characterRange.length > 0, loc >= 0,
              loc + characterRange.length <= storage.length else { return }
        let r = NSRange(location: loc, length: characterRange.length)
        storage.addAttribute(.backgroundColor, value: highlightColor, range: r)
        lastHighlight = r
        tv.scrollRangeToVisible(r)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        clearHighlight(); activeSpeakId = nil
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        clearHighlight(); activeSpeakId = nil
    }
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run:
```bash
cd popdict-app && swiftc Speech.swift "$CLAUDE_JOB_DIR/tmp/test_speak.swift" \
  -framework AppKit -framework AVFoundation -framework NaturalLanguage -o /tmp/ttstest && /tmp/ttstest
```
Expected: 打印 `voiceLanguage OK`（无 assert 失败）。

- [ ] **Step 5: 加 `MD.speakIdKey`**

在 `popdict-app/Markdown.swift` 第 15 行 `static let userMsgKey = ...` 之后新增一行：

```swift
    // 朗读段落标记:Speaker 据此扫描出某段正文的字符范围(取文字 + 逐句高亮定位)
    static let speakIdKey = NSAttributedString.Key("popdictSpeakId")
```

- [ ] **Step 6: 改 `build.sh` 接入新文件与框架**

把 `popdict-app/build.sh` 第 24 行：
```bash
SRCS="main.swift Markdown.swift Screenshot.swift Config.swift Settings.swift"
```
改为：
```bash
SRCS="main.swift Markdown.swift Screenshot.swift Config.swift Settings.swift Speech.swift"
```

把第 25-26 行两条 `swiftc` 命令里的：
```
-framework AppKit -framework ApplicationServices -framework Carbon -O
```
都改为：
```
-framework AppKit -framework ApplicationServices -framework Carbon -framework AVFoundation -framework NaturalLanguage -O
```

- [ ] **Step 7: 整体编译自检**

Run（用 Global Constraints 里的编译自检命令）：
```bash
cd popdict-app && swiftc main.swift Markdown.swift Screenshot.swift Config.swift Settings.swift Speech.swift \
  -target arm64-apple-macos12.0 -swift-version 5 \
  -framework AppKit -framework ApplicationServices -framework Carbon \
  -framework AVFoundation -framework NaturalLanguage -O -o /tmp/popdict_check && echo BUILD_OK
```
Expected: `BUILD_OK`（`Speaker` 此时还没人调用，但全工程应编译通过）。

- [ ] **Step 8: 提交**

```bash
git add popdict-app/Speech.swift popdict-app/Markdown.swift popdict-app/build.sh
git commit -m "feat(tts): 加 Speaker 离线语音引擎(含逐句高亮) + MD.speakIdKey + build 接框架"
```

---

### Task 2: 链接点击路由 + textview 配置 + 🔊/标记工具函数

**Files:**
- Modify: `popdict-app/main.swift`（`PopupController` 内：新增属性与工具方法；`makeRenderingTextView` 配置 delegate/链接样式；文件末尾加 `NSTextViewDelegate` 扩展）

**Interfaces:**
- Consumes: `MD.speakIdKey`、`Speaker.shared.speak(...)`（Task 1）
- Produces（供 Task 3/4/5 使用）：
  - `private func nextSpeakId() -> String`
  - `private func speakerPrefix(id: String, extra: [NSAttributedString.Key: Any]) -> NSAttributedString`
  - `private func markSpeakBody(_ storage: NSTextStorage, range: NSRange, id: String)`
  - `private func speakSegment(id: String, in textView: NSTextView)`
  - `extension PopupController: NSTextViewDelegate`（实现 `clickedOnLink`）

- [ ] **Step 1: 加自增 id 计数器属性**

在 `PopupController` 属性区（紧接 `private var generation = 0` 那一带，约 458 行后）新增：

```swift
    private var speakIdSeq = 0   // 朗读段落 id 自增计数器(产出 seg1/seg2…,URL 安全)
```

- [ ] **Step 2: 加工具方法（id 生成 / 🔊 前缀 / 正文标记 / 朗读某段）**

在 `PopupController` 内（建议放在 `measuredTextHeight` 方法附近，约 970 行处）新增：

```swift
    // MARK: 朗读:🔊 链接 + 正文标记 + 点击朗读

    private func nextSpeakId() -> String { speakIdSeq += 1; return "seg\(speakIdSeq)" }

    // 生成「🔊 」可点击前缀(链接到 speakId);extra 用于让前缀并入所在段的段落样式/气泡背景
    private func speakerPrefix(id: String, extra: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [
            .link: URL(string: "popdict-speak://" + id) as Any,
            .font: convoFont,
            .toolTip: "朗读这一段"
        ]
        for (k, v) in extra { attrs[k] = v }
        return NSAttributedString(string: "🔊 ", attributes: attrs)
    }

    // 给某段正文范围打 speakId 标记(供朗读时按 id 扫描定位)
    private func markSpeakBody(_ storage: NSTextStorage, range: NSRange, id: String) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.addAttribute(MD.speakIdKey, value: id, range: range)
    }

    // 按 id 扫描出该段连续正文范围 → 取文字交给 Speaker 朗读
    private func speakSegment(id: String, in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        var found: NSRange?
        storage.enumerateAttribute(MD.speakIdKey,
                                   in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let v = value as? String, v == id {
                found = found.map { NSUnionRange($0, range) } ?? range
            }
        }
        guard let body = found else { return }
        let text = storage.attributedSubstring(from: body).string
        Speaker.shared.speak(text, in: textView, bodyRange: body, speakId: id)
    }
```

- [ ] **Step 3: 配置 `makeRenderingTextView`（delegate + 链接样式）**

在 `makeRenderingTextView`（约 718 行）`return tv` 之前追加：

```swift
        tv.delegate = self
        // 让 🔊 链接看起来是普通图标(去蓝色去下划线),悬停显示手型
        tv.linkTextAttributes = [
            .foregroundColor: NSColor.labelColor,
            .cursor: NSCursor.pointingHand
        ]
```

- [ ] **Step 4: 文件末尾加 `NSTextViewDelegate` 扩展**

在 `main.swift` 末尾追加：

```swift
extension PopupController: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let s: String
        if let u = link as? URL { s = u.absoluteString }
        else if let str = link as? String { s = str }
        else { return false }
        let scheme = "popdict-speak://"
        guard s.hasPrefix(scheme) else { return false }
        speakSegment(id: String(s.dropFirst(scheme.count)), in: textView)
        return true
    }
}
```

- [ ] **Step 5: 编译自检**

Run: Global Constraints 的编译自检命令。
Expected: `BUILD_OK`（工具就绪，但还没有地方插入 🔊，下一任务接入）。

- [ ] **Step 6: 提交**

```bash
git add popdict-app/main.swift
git commit -m "feat(tts): 链接点击路由 + textview delegate/链接样式 + 🔊 工具函数"
```

---

### Task 3: 解释面板显示原文 + 原文/指令的 🔊（功能二·解释 + 功能一·原文段）

**Files:**
- Modify: `popdict-app/main.swift` `beginConversation`（约 657-670 行）
- Modify: `popdict-app/main.swift` `beginImageConversation` 的指令插入处（约 692-698 行）

**Interfaces:**
- Consumes: `nextSpeakId()`、`speakerPrefix(...)`、`markSpeakBody(...)`（Task 2）

- [ ] **Step 1: `beginConversation` 补写原文到 transcript（带 🔊）**

把 `beginConversation`（约 657 行）里：
```swift
        installConversationPanel(at: origin)
        sendTurn()
```
改为：
```swift
        installConversationPanel(at: origin)
        // 顶部显示最初划入的原文(带 🔊),流式答案接其后
        if let tv = convoTextView, let storage = tv.textStorage {
            let id = nextSpeakId()
            storage.append(speakerPrefix(id: id))
            let start = storage.length
            storage.append(NSAttributedString(string: firstUserText + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: MD.bodyStyle()]))
            markSpeakBody(storage, range: NSRange(location: start, length: storage.length - start), id: id)
        }
        sendTurn()
```
（说明：原文在 `sendTurn` 之前插入；`sendTurn` 内 `assistantStart = textStorage.length` 会自动落在原文之后，不冲突。）

- [ ] **Step 2: `beginImageConversation` 给指令气泡也加 🔊**

把 `beginImageConversation`（约 692-698 行）里：
```swift
        if let tv = convoTextView, let storage = tv.textStorage {
            storage.append(thumbnailString(image, maxW: savedPopupSize().width - convoPad * 2))
            storage.append(NSAttributedString(string: instruction + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: MD.bodyStyle()]))
        }
```
改为：
```swift
        if let tv = convoTextView, let storage = tv.textStorage {
            storage.append(thumbnailString(image, maxW: savedPopupSize().width - convoPad * 2))
            let id = nextSpeakId()
            storage.append(speakerPrefix(id: id))
            let start = storage.length
            storage.append(NSAttributedString(string: instruction + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: MD.bodyStyle()]))
            markSpeakBody(storage, range: NSRange(location: start, length: storage.length - start), id: id)
        }
```

- [ ] **Step 3: 编译自检**

Run: Global Constraints 的编译自检命令。
Expected: `BUILD_OK`。

- [ ] **Step 4: 提交**

```bash
git add popdict-app/main.swift
git commit -m "feat(ui): 解释面板显示最初划入的原文(带 🔊),截图解释指令也加 🔊"
```

---

### Task 4: AI 回答 + 追问每段加 🔊（功能一·对话面板）

**Files:**
- Modify: `popdict-app/main.swift` `finishTurn`（约 816-829 行的渲染替换处）
- Modify: `popdict-app/main.swift` `appendUserBubble`（约 890-913 行）

**Interfaces:**
- Consumes: `nextSpeakId()`、`speakerPrefix(...)`、`MD.speakIdKey`（Task 1/2）

- [ ] **Step 1: `finishTurn` 给 AI 回答加 🔊 + 标记正文**

把 `finishTurn`（约 822-826 行）里：
```swift
        if let tv = convoTextView, let storage = tv.textStorage {
            let len = max(0, storage.length - assistantStart)
            let rendered = MD.render(text, width: (panel?.frame.width ?? convoW) - convoPad * 2, baseFont: convoFont, textColor: .labelColor)
            storage.replaceCharacters(in: NSRange(location: assistantStart, length: len), with: rendered)
        }
```
改为：
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

- [ ] **Step 2: `appendUserBubble` 给追问加 🔊 + 标记正文**

把 `appendUserBubble`（约 904-912 行）里：
```swift
        let pBody = NSMutableParagraphStyle()
        pBody.firstLineHeadIndent = 12; pBody.headIndent = 12; pBody.tailIndent = -12
        pBody.lineSpacing = 3
        pBody.paragraphSpacing = 22          // 问题与下面 AI 回答拉开
        m.append(NSAttributedString(string: q + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: pBody, MD.userMsgKey: true]))
        storage.append(m)
```
改为：
```swift
        let pBody = NSMutableParagraphStyle()
        pBody.firstLineHeadIndent = 12; pBody.headIndent = 12; pBody.tailIndent = -12
        pBody.lineSpacing = 3
        pBody.paragraphSpacing = 22          // 问题与下面 AI 回答拉开
        let id = nextSpeakId()
        // 🔊 前缀并入气泡:带气泡段落样式 + userMsgKey + 同字重,否则会破坏圆角底与缩进
        m.append(speakerPrefix(id: id, extra: [
            .paragraphStyle: pBody, MD.userMsgKey: true,
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold)]))
        let qStart = m.length
        m.append(NSAttributedString(string: q + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: pBody, MD.userMsgKey: true]))
        m.addAttribute(MD.speakIdKey, value: id, range: NSRange(location: qStart, length: m.length - qStart))
        storage.append(m)
```

- [ ] **Step 3: 编译自检**

Run: Global Constraints 的编译自检命令。
Expected: `BUILD_OK`。

- [ ] **Step 4: 提交**

```bash
git add popdict-app/main.swift
git commit -m "feat(tts): 对话面板 AI 回答与追问每段加 🔊"
```

---

### Task 5: 翻译面板显示原文 + 原文/译文双 🔊（功能二·翻译 + 功能一·译文段）

**Files:**
- Modify: `popdict-app/main.swift` `showMessage`（约 972-990 行：加 `original` 参数 + 构造 `attr`）
- Modify: `popdict-app/main.swift` `onTranslateClicked`（约 561 行：传 `original: text`）

**Interfaces:**
- Consumes: `nextSpeakId()`、`speakerPrefix(...)`、`MD.speakIdKey`、`MD.render(...)`、`MD.bodyStyle()`

- [ ] **Step 1: `showMessage` 增加 `original` 参数**

把方法签名（约 972 行）：
```swift
    private func showMessage(_ message: String, isError: Bool, showCopy: Bool = false, markdown: Bool = false) {
```
改为：
```swift
    private func showMessage(_ message: String, isError: Bool, showCopy: Bool = false, markdown: Bool = false, original: String? = nil) {
```

- [ ] **Step 2: 在 `showMessage` 里把"仅译文"改成"原文+译文双段"**

把构造 `attr` 的那段（约 987-990 行）：
```swift
        // 译文按 markdown 渲染;其它(翻译中/错误)纯文本
        let attr = markdown
            ? MD.render(message, width: textW, baseFont: font, textColor: textColor)
            : NSAttributedString(string: message, attributes: [.font: font, .foregroundColor: textColor])
```
改为：
```swift
        // 最终译文(showCopy+markdown+有原文):渲染「原文 + 译文」双段,各带 🔊;否则保持原逻辑
        let attr: NSAttributedString
        if showCopy, markdown, let original = original {
            let m = NSMutableAttributedString()
            // 原文段
            let oid = nextSpeakId()
            m.append(sectionLabel("原文"))
            m.append(speakerPrefix(id: oid))
            let oStart = m.length
            m.append(NSAttributedString(string: original + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: MD.bodyStyle()]))
            m.addAttribute(MD.speakIdKey, value: oid, range: NSRange(location: oStart, length: m.length - oStart))
            // 段间留白
            m.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: MD.bodyStyle()]))
            // 译文段
            let tid = nextSpeakId()
            m.append(sectionLabel("译文"))
            m.append(speakerPrefix(id: tid))
            let tStart = m.length
            m.append(MD.render(message, width: textW, baseFont: font, textColor: textColor))
            m.addAttribute(MD.speakIdKey, value: tid, range: NSRange(location: tStart, length: m.length - tStart))
            attr = m
        } else {
            attr = markdown
                ? MD.render(message, width: textW, baseFont: font, textColor: textColor)
                : NSAttributedString(string: message, attributes: [.font: font, .foregroundColor: textColor])
        }
```

- [ ] **Step 3: 加 `sectionLabel` 工具方法**

在 `PopupController` 内（紧接 Task 2 的朗读工具方法之后）新增：

```swift
    // 翻译面板的小节标签(「原文」「译文」),accent 小字
    private func sectionLabel(_ s: String) -> NSAttributedString {
        let p = NSMutableParagraphStyle(); p.paragraphSpacing = 2
        return NSAttributedString(string: s + "  ", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.controlAccentColor,
            .paragraphStyle: p])
    }
```

- [ ] **Step 4: `onTranslateClicked` 传入原文**

把 `onTranslateClicked`（约 561 行）成功分支：
```swift
                self.showMessage(result ?? "(空)", isError: false, showCopy: true, markdown: true)
```
改为：
```swift
                self.showMessage(result ?? "(空)", isError: false, showCopy: true, markdown: true, original: text)
```
（`text` 即方法开头 `guard let text = pendingText` 捕获的原文。）

- [ ] **Step 5: 编译自检**

Run: Global Constraints 的编译自检命令。
Expected: `BUILD_OK`。

- [ ] **Step 6: 提交**

```bash
git add popdict-app/main.swift
git commit -m "feat(ui): 翻译面板显示原文 + 原文/译文双 🔊"
```

---

### Task 6: 生命周期停止朗读 + 全量构建 + 手测清单

**Files:**
- Modify: `popdict-app/main.swift` `stopConversation`（约 949 行）、`onAskSubmit`（约 876 行）、`showMessage`（约 972 行开头）

**Interfaces:**
- Consumes: `Speaker.shared.stop()`

- [ ] **Step 1: 关窗/换会话时停止朗读**

在 `stopConversation()`（约 949 行）函数体第一行 `convoTask?.cancel(); convoTask = nil` 之前加：
```swift
        Speaker.shared.stop()
```

- [ ] **Step 2: 重建翻译面板内容前停止朗读**

在 `showMessage(...)`（约 972 行）函数体最前面（`lastResult = ...` 之前）加：
```swift
        Speaker.shared.stop()
```

- [ ] **Step 3: 发起新一轮追问前停止朗读**

在 `onAskSubmit()`（约 876 行）里 `field.stringValue = ""` 之前加：
```swift
        Speaker.shared.stop()
```

- [ ] **Step 4: 编译自检**

Run: Global Constraints 的编译自检命令。
Expected: `BUILD_OK`。

- [ ] **Step 5: 全量打包构建（验证 build.sh 改对了）**

Run:
```bash
cd popdict-app && bash build.sh 2>&1 | tail -20
```
Expected: 走到 `==> 5/5 完成`，产出 `popdict.app` 与 `popdict.dmg`，无编译/签名错误。

- [ ] **Step 6: 提交**

```bash
git add popdict-app/main.swift
git commit -m "feat(tts): 关窗/换会话/重建面板/新追问时停止朗读"
```

- [ ] **Step 7: 手测清单（需 GUI 会话 + 已配置 API Key + 已授辅助功能权限，由用户在桌面执行）**

把新打包的 `popdict.app` 装好运行，逐项确认：

1. 划词 → 点「🌐 翻译」→ 结果面板**同时显示原文与译文**，各自前面有 🔊。
2. 点原文的 🔊 → 用**英文嗓**朗读英文原文；朗读时**逐句高亮**跟随；再点同一个 🔊 → 停止。
3. 点译文的 🔊 → 用**中文嗓**朗读译文。
4. 划词 → 点「💡 解释」→ transcript **顶部显示最初划入的原文**（带 🔊），下面是 AI 回答（带 🔊）。
5. 追问一句 → 追问气泡带 🔊，圆角底/缩进正常未被破坏；AI 新回答也带 🔊。
6. 朗读途中关闭面板 / 划新词 / 发新追问 → 朗读立即停止、高亮清除。
7. ⌃⌥E 截图解释 → 指令气泡带 🔊 且可朗读。
8. **重点回归**：确认 🔊 链接"首次单击即触发朗读"（本面板是 nonactivating 后台浮窗）。若首次点击只是激活窗口、不触发朗读，则按下方"风险退路"改用 mouseDown 命中判断。

**风险退路（仅当 Step 7.8 失败时启用）：** 自定义 `NSTextView` 子类重写 `mouseDown(with:)`，用 `characterIndexForInsertion(at:)` 命中点击位置的 `.link` 属性，命中 `popdict-speak://` 前缀就直接调 `speakSegment` 并 `return`（不调 super，避免落为选区/激活）；`makeRenderingTextView` 改用该子类。

---

## Self-Review

**1. Spec coverage：**
- 系统离线 TTS → Task 1（`Speaker` + `AVSpeechSynthesizer`）✓
- 每段开头 🔊（原文/AI 回答/追问/译文/截图指令）→ Task 3/4/5 ✓
- 逐句高亮 → Task 1（`willSpeakRangeOfSpeechString` + 背景色）✓
- 文本链接机制 + `clickedOnLink` 路由 → Task 2 ✓
- `MD.speakIdKey` 段落定位 → Task 1（键）+ Task 2（扫描）✓
- 解释面板显示原文 → Task 3 ✓
- 翻译面板显示原文 → Task 5 ✓
- 生命周期停止 → Task 6 ✓
- build.sh 接框架/文件 → Task 1 ✓
- nonactivating 链接点击风险 → Task 6 手测 Step 7.8 + 风险退路 ✓

**2. Placeholder scan：** 无 TBD/TODO；每个代码步骤均给出完整可粘贴代码。✓

**3. Type consistency：**
- `nextSpeakId() -> String`、`speakerPrefix(id:extra:) -> NSAttributedString`、`markSpeakBody(_:range:id:)`、`speakSegment(id:in:)`、`sectionLabel(_:)`、`Speaker.shared.speak(_:in:bodyRange:speakId:)`、`Speaker.shared.stop()`、`Speaker.voiceLanguage(for:)` 全文一致。
- `MD.speakIdKey` 在 Task 1 定义，Task 2/3/4/5 使用，键名 `"popdictSpeakId"` 一致。
- 链接 scheme `popdict-speak://` 在 `speakerPrefix`（产）与 `clickedOnLink`（消）一致。✓
