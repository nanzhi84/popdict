# MiMo 接入 + 截图解释 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 popdict 原生 App 的模型后端从 DeepSeek 换成小米 MiMo(OpenAI 兼容),并新增「自带框选截图 → 发给 `mimo-v2.5` 多模态解释 → 可带图追问」。

**Architecture:** 单菜单栏 App。模型调用集中到几个常量;消息内容放宽到支持「文字块 + 图片块(base64 data URL)」;新增独立组件 `RegionCapture`(全屏遮罩框选 + `CGWindowListCreateImage` 捕获 + PNG/base64 编码);Carbon 全局热键 ⌃⌥E 与菜单项触发截图,截完复用现有会话浮窗(加缩略图)。

**Tech Stack:** Swift 5、AppKit、ApplicationServices、Carbon.HIToolbox(热键)、CoreGraphics(截图)、`swiftc` 直接编译(无 Xcode 工程、无单元测试框架)。

## Global Constraints

- 只改 `popdict-app/`(`main.swift`、新增 `Screenshot.swift`、`build.sh`)与 `README.md`;**不动** PopClip 扩展和 `popdict.lua`。
- `MIN_OS = 12.0`(universal:arm64 + x86_64);截图只能用 macOS 12 可用的 API(`CGWindowListCreateImage`/`CGDisplayCreateImage`,不用 14+ 的 ScreenCaptureKit)。
- Endpoint `https://api.xiaomimimo.com/v1/chat/completions`;模型 `mimo-v2.5`;Key 文件 `~/.config/popdict/mimo_key`(不读旧 `deepseek_key`)。
- 每个请求体带 `"thinking": {"type": "disabled"}` 和 `"max_completion_tokens": 4096`。
- 图片输入用 `{"type":"image_url","image_url":{"url":"data:image/png;base64,<B64>"}}`;最长边 > 2048px 等比缩小。
- 测试循环 = `bash popdict-app/build.sh` 编译通过无新警告(弃用 API 警告除外) + `POPDICT_UITEST` 自测 + 手动冒烟。
- 提交信息结尾附 `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` 与 `Claude-Session: …`。

---

### Task 1: 模型后端切到 MiMo(含看图 prompt)

**Files:**
- Modify: `popdict-app/main.swift`(常量 `kKeyPath` line 16;`readAPIKey` 60-64;`kExplainSystem` 245-252;`translate` 192-240;`chatStream` 256-321;`buildMenu` 的 API Key 文案 1190-1191)

**Interfaces:**
- Produces:全局常量 `kAPIBase: String`、`kChatPath: String`、`kModel: String`、`kMaxTokens: Int`;`kKeyPath` 指向 `mimo_key`;`translate`/`chatStream` 行为对外不变(只换后端)。

- [ ] **Step 1: 加集中常量,改 key 路径**

在 `main.swift` 顶部配置区(line 14-16 附近)把 `kKeyPath` 改名,并新增模型常量:

```swift
let kConfigDir = (("~/.config/popdict" as NSString).expandingTildeInPath)
let kLogPath = kConfigDir + "/popdict.log"
let kKeyPath = kConfigDir + "/mimo_key"          // 原 deepseek_key

// MiMo(OpenAI 兼容)
let kAPIBase = "https://api.xiaomimimo.com/v1"
let kChatPath = "/chat/completions"
let kModel = "mimo-v2.5"
let kMaxTokens = 4096
```

- [ ] **Step 2: 扩展看图 prompt**

把 `kExplainSystem`(245-252)末尾补一条图片分支(其余不动):

```swift
let kExplainSystem = """
你是一个善于把复杂概念和代码讲清楚的助手。请用简体中文解释用户给出的内容,帮他真正理解。
- 如果是代码:先说它整体在做什么,再逐步拆解关键逻辑,点出涉及的语法、库或设计意图,必要时给一句类比或小例子。
- 如果是术语或概念:用大白话讲清它是什么、为什么重要、怎么用。
- 如果是图片:先一句说清这张图整体是什么(截图/图表/报错/界面/照片/文档…),再解读其中关键信息。报错或代码截图就定位问题并给排查/解决方向;图表就读出趋势与要点;界面或流程就说清它在干什么。
- 内容简短就简短回答(几句话点透),内容复杂就分点详解。
- 直接开始,不要寒暄,不要复述原文。可以用 markdown(## 小标题、**加粗**、`代码`、- 列表、```代码块```)让层次清晰。
- 后续若有追问,延续上下文回答。
"""
```

- [ ] **Step 3: `translate` 改用 MiMo**

`translate`(192-240)里替换 body 与 url 构造、错误文案。把:

```swift
    let body: [String: Any] = [
        "model": "deepseek-chat",
        "messages": [...],
        "temperature": 0.3,
        "stream": false
    ]
    guard let url = URL(string: "https://api.deepseek.com/chat/completions"),
```

改为:

```swift
    let body: [String: Any] = [
        "model": kModel,
        "messages": [
            ["role": "system", "content": sys],
            ["role": "user", "content": text]
        ],
        "temperature": 0.3,
        "max_completion_tokens": kMaxTokens,
        "thinking": ["type": "disabled"],
        "stream": false
    ]
    guard let url = URL(string: kAPIBase + kChatPath),
```

并把无 key 提示 `"…请把 DeepSeek Key 写进:\n\(kKeyPath)"` 改 `"…请把 MiMo Key 写进:\n\(kKeyPath)"`;HTTP 非 200 文案 `"DeepSeek 出错(HTTP \(http.statusCode)),请检查 Key 或余额"` → `"MiMo 出错(HTTP \(http.statusCode)),请检查 Key 或余额"`。

- [ ] **Step 4: `chatStream` 改用 MiMo**

`chatStream`(256-321)body 同样替换:`"model": "deepseek-chat"` → `"model": kModel`,加 `"max_completion_tokens": kMaxTokens` 与 `"thinking": ["type": "disabled"]`;url 改 `kAPIBase + kChatPath`;无 key 与 HTTP 非 200 文案同 Step 3 改成 MiMo。**本任务暂不改 `messages` 参数类型**(下个任务再放宽),保持 `[[String: String]]`。

- [ ] **Step 5: 菜单文案**

`buildMenu`(1190-1191)`readAPIKey() == nil ? "⚠️ 未填 API Key" : "✓ 已配置 API Key"` 文案保留即可(已是中性);无需改。确认 `kKeyPath` 已指向 `mimo_key`。

- [ ] **Step 6: 编译**

Run: `cd popdict-app && bash build.sh`
Expected: `==> 5/5 完成`,无报错;无新增警告。

- [ ] **Step 7: 提交**

```bash
git add popdict-app/main.swift
git commit -m "feat: 模型后端从 DeepSeek 切换到小米 MiMo(mimo-v2.5)"
```

---

### Task 2: 消息支持「文字 + 图片」多模态

**Files:**
- Modify: `popdict-app/main.swift`(`chatStream` 签名 256-264;`sendTurn` 675-685;`PopupController` 新增字段;`stopConversation` 876-885;`beginConversation` 568-608 顶部)

**Interfaces:**
- Consumes:Task 1 的 `kModel`/`kAPIBase`。
- Produces:`chatStream(_ messages: [[String: Any]], …)`(content 可为 String 或内容块数组);`PopupController.attachedImageDataURL: String?`;`sendTurn()` 在首条 user 带图时构造多模态 content。

- [ ] **Step 1: 放宽 `chatStream` 的 messages 类型**

把 `chatStream` 签名(257)的 `_ messages: [[String: String]]` 改为 `_ messages: [[String: Any]]`。body 里 `"messages": messages`(265-270 那段)不变——`JSONSerialization` 接受 `[String: Any]`。其余 SSE 解析逻辑完全不动。

- [ ] **Step 2: 给 `PopupController` 加附带图字段**

在会话状态区(401-417 附近)新增:

```swift
    private var attachedImageDataURL: String?   // 本轮会话附带的图(base64 data URL),整段会话期间保留
```

- [ ] **Step 3: `sendTurn` 构造多模态首条 user**

把 `sendTurn`(675-685)中构造 messages 的循环改为:

```swift
    private func sendTurn() {
        assistantStart = convoTextView?.textStorage?.length ?? 0
        assistantAccum = ""
        setInputEnabled(false, placeholder: "正在生成…")
        var messages: [[String: Any]] = [["role": "system", "content": kExplainSystem]]
        for (i, m) in convo.enumerated() {
            if i == 0, m.role == "user", let dataURL = attachedImageDataURL {
                messages.append([
                    "role": "user",
                    "content": [
                        ["type": "text", "text": m.content],
                        ["type": "image_url", "image_url": ["url": dataURL]]
                    ]
                ])
            } else {
                messages.append(["role": m.role, "content": m.content])
            }
        }
        convoTask = chatStream(messages,
            onDelta: { [weak self] piece in self?.convoAppendDelta(piece) },
            onDone:  { [weak self] full  in self?.finishTurn(full) },
            onError: { [weak self] msg   in self?.convoError(msg) })
    }
```

- [ ] **Step 4: 清理时一并清掉附带图**

`stopConversation`(876-885)末尾追加 `attachedImageDataURL = nil`。`beginConversation`(568)开头 `stopConversation()` 之后已会清空;为显式起见在 `beginConversation` 里 `convo = [...]` 前加 `attachedImageDataURL = nil`(文字解释不带图)。

- [ ] **Step 5: 编译**

Run: `cd popdict-app && bash build.sh`
Expected: 编译通过;文字翻译/解释行为不变(content 仍以 String 传)。

- [ ] **Step 6: 提交**

```bash
git add popdict-app/main.swift
git commit -m "feat: chatStream 消息支持文字+图片多模态内容块"
```

---

### Task 3: 框选截图遮罩 + 捕获 + 编码(`Screenshot.swift`)

**Files:**
- Create: `popdict-app/Screenshot.swift`
- Modify: `popdict-app/build.sh`(`SRCS` 加文件;链接 `-framework Carbon`——Carbon 留给 Task 5,但框架本任务先加好不影响)

**Interfaces:**
- Produces:
  - `final class RegionCapture` 带实例方法 `func capture(completion: @escaping (NSImage?) -> Void)`。
  - 静态 `static func encodeToDataURL(_ image: NSImage) -> String?`(PNG base64 data URL,最长边 ≤ 2048)。
  - 静态权限助手 `static func hasScreenRecordingPermission() -> Bool`、`static func requestScreenRecordingPermission()`。

- [ ] **Step 1: 写 `Screenshot.swift`**

Create `popdict-app/Screenshot.swift`:

```swift
import AppKit
import CoreGraphics

// 可成为 key 的无边框遮罩窗口(为了收 Esc 键)
private final class CaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

// 全屏遮罩:拖动框选,压暗选区外,显示尺寸;Esc 取消,松手确认。
private final class SelectionView: NSView {
    var onFinish: ((NSRect?) -> Void)?   // 选区(本视图坐标);nil = 取消
    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let s = startPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(x: min(s.x, p.x), y: min(s.y, p.y),
                             width: abs(p.x - s.x), height: abs(p.y - s.y))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        let r = currentRect
        if r.width > 8 && r.height > 8 { onFinish?(r) } else { onFinish?(nil) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) }   // Esc
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        guard currentRect.width > 0, currentRect.height > 0 else { return }
        // 选区内挖空(显示真实画面)
        NSColor.clear.set()
        currentRect.fill(using: .copy)
        // 边框
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: currentRect); path.lineWidth = 1.5; path.stroke()
        // 尺寸标签
        let label = "\(Int(currentRect.width)) × \(Int(currentRect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white]
        let size = (label as NSString).size(withAttributes: attrs)
        var lx = currentRect.minX
        var ly = currentRect.maxY + 4
        if ly + size.height > bounds.maxY { ly = currentRect.minY - size.height - 4 }
        let bg = NSRect(x: lx - 4, y: ly - 2, width: size.width + 8, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 3, yRadius: 3).fill()
        (label as NSString).draw(at: NSPoint(x: lx, y: ly), withAttributes: attrs)
    }
}

final class RegionCapture {
    private var window: CaptureWindow?

    // 所有屏幕并集(AppKit 坐标)
    private static func unionFrame() -> NSRect {
        NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
    }

    func capture(completion: @escaping (NSImage?) -> Void) {
        let union = RegionCapture.unionFrame()
        let win = CaptureWindow(contentRect: union, styleMask: .borderless,
                                backing: .buffered, defer: false)
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = false
        let view = SelectionView(frame: NSRect(origin: .zero, size: union.size))
        win.contentView = view
        window = win

        view.onFinish = { [weak self] localRect in
            guard let self = self, let win = self.window else { completion(nil); return }
            guard let localRect = localRect else {
                win.orderOut(nil); self.window = nil; completion(nil); return
            }
            // 本视图坐标 → AppKit 全局 → Quartz 全局(左上原点)
            let globalAK = NSRect(x: union.minX + localRect.minX,
                                  y: union.minY + localRect.minY,
                                  width: localRect.width, height: localRect.height)
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            let quartz = CGRect(x: globalAK.minX, y: primaryH - globalAK.maxY,
                                width: globalAK.width, height: globalAK.height)
            let winID = CGWindowID(win.windowNumber)
            // 截遮罩窗口「下方」的真实画面(压暗层不会进图)
            let cg = CGWindowListCreateImage(quartz, .optionOnScreenBelowWindow, winID,
                                             [.bestResolution, .boundsIgnoreFraming])
            win.orderOut(nil); self.window = nil
            guard let cg = cg else { completion(nil); return }
            let img = NSImage(cgImage: cg, size: NSSize(width: quartz.width, height: quartz.height))
            completion(img)
        }

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)
    }

    // NSImage → 缩放(最长边≤2048)→ PNG → base64 data URL
    static func encodeToDataURL(_ image: NSImage) -> String? {
        guard var cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let maxSide = 2048
        let w = cg.width, h = cg.height
        if max(w, h) > maxSide {
            let scale = CGFloat(maxSide) / CGFloat(max(w, h))
            let nw = Int(CGFloat(w) * scale), nh = Int(CGFloat(h) * scale)
            if let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
                if let scaled = ctx.makeImage() { cg = scaled }
            }
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + data.base64EncodedString()
    }

    static func hasScreenRecordingPermission() -> Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult static func requestScreenRecordingPermission() -> Bool { CGRequestScreenCaptureAccess() }
}
```

- [ ] **Step 2: build.sh 纳入新文件 + Carbon 框架**

`popdict-app/build.sh` 第 24 行 `SRCS="main.swift Markdown.swift"` → `SRCS="main.swift Markdown.swift Screenshot.swift"`。两条 `swiftc` 命令(25-26)末尾各加 `-framework Carbon`(为 Task 5 的热键预备,现在加不影响编译)。

- [ ] **Step 3: 编译**

Run: `cd popdict-app && bash build.sh`
Expected: 编译通过(`CGWindowListCreateImage`/`CGDisplayCreateImage` 可能有 deprecation 警告,允许)。

- [ ] **Step 4: 提交**

```bash
git add popdict-app/Screenshot.swift popdict-app/build.sh
git commit -m "feat: 新增框选截图组件 RegionCapture(遮罩+捕获+base64编码)"
```

---

### Task 4: 图片会话入口 + 缩略图(复用会话浮窗)

**Files:**
- Modify: `popdict-app/main.swift`(抽 `installConversationPanel`;`beginConversation` 复用;新增 `beginImageConversation`、`thumbnailString`)

**Interfaces:**
- Consumes:Task 2 的 `attachedImageDataURL`/`sendTurn`;Task 3 的 `RegionCapture.encodeToDataURL`。
- Produces:`PopupController.beginImageConversation(image: NSImage, instruction: String, at fixedOrigin: NSPoint?)`。

- [ ] **Step 1: 抽公共面板搭建**

把 `beginConversation`(568-608)中「建 container/scroll/tv/inputBar、置 assistant 计数、present、startConvoTimer」的部分抽成私有方法:

```swift
    // 搭建会话浮窗骨架(transcript 滚动区 + 底部输入栏),present 并启动长高定时器
    private func installConversationPanel(at origin: NSPoint) {
        let textW = convoW - convoPad * 2
        let visibleH: CGFloat = 22
        let panelH = convoPad + visibleH + transcriptBottomGap + inputBarH
        let container = NSView(frame: NSRect(x: 0, y: 0, width: convoW, height: panelH))
        container.autoresizingMask = [.width, .height]
        let scroll = NSScrollView(frame: NSRect(x: convoPad, y: inputBarH + transcriptBottomGap, width: textW, height: visibleH))
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        let tv = makeTranscriptView(width: textW)
        scroll.documentView = tv
        container.addSubview(scroll)
        convoScroll = scroll; convoTextView = tv
        container.addSubview(makeInputBar(width: convoW))
        assistantStart = 0; assistantAccum = ""; turnStartLoc = 0
        var rect = NSRect(x: origin.x, y: origin.y, width: convoW, height: panelH)
        rect = clampToScreen(rect)
        present(content: container, rect: rect, animateFrame: false)
        startConvoTimer()
    }
```

`beginConversation` 改为:

```swift
    private func beginConversation(firstUserText: String, at fixedOrigin: NSPoint? = nil) {
        stopConversation()
        attachedImageDataURL = nil
        convo = [(role: "user", content: firstUserText)]
        let panelH = convoPad + 22 + transcriptBottomGap + inputBarH
        let origin: NSPoint
        if let fo = fixedOrigin { origin = fo }
        else if let pf = panel?.frame { origin = NSPoint(x: pf.minX, y: pf.maxY - panelH) }
        else { origin = NSEvent.mouseLocation }
        installConversationPanel(at: origin)
        sendTurn()
    }
```

- [ ] **Step 2: 缩略图富文本**

新增私有方法(放在 `appendUserBubble` 附近):

```swift
    // 把图缩放后做成行内附件(贴合浮窗内宽,高度上限 240),返回带尾随换行的富文本
    private func thumbnailString(_ image: NSImage, maxW: CGFloat) -> NSAttributedString {
        let iw = max(1, image.size.width), ih = max(1, image.size.height)
        var dw = min(maxW, iw)
        var dh = dw * ih / iw
        let maxH: CGFloat = 240
        if dh > maxH { dh = maxH; dw = dh * iw / ih }
        let att = NSTextAttachment()
        att.image = image
        att.bounds = CGRect(x: 0, y: 0, width: dw, height: dh)
        let m = NSMutableAttributedString(attributedString: NSAttributedString(attachment: att))
        m.append(NSAttributedString(string: "\n", attributes: [.font: convoFont, .paragraphStyle: MD.bodyStyle()]))
        return m
    }
```

- [ ] **Step 3: `beginImageConversation`**

新增(放在 `beginConversation` 之后):

```swift
    // 截图解释:把图存为会话首条 user(每轮重发),顶部放缩略图 + 指令气泡,然后流式解释
    func beginImageConversation(image: NSImage, instruction: String = "请解释这张图片的内容。", at fixedOrigin: NSPoint? = nil) {
        guard let dataURL = RegionCapture.encodeToDataURL(image) else {
            showMessage("图片编码失败,请重试", isError: true); return
        }
        generation += 1
        stopConversation()
        attachedImageDataURL = dataURL
        convo = [(role: "user", content: instruction)]
        let panelH = convoPad + 22 + transcriptBottomGap + inputBarH
        let origin: NSPoint
        if let fo = fixedOrigin { origin = fo }
        else {
            let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            origin = NSPoint(x: vf.midX - convoW / 2, y: vf.maxY - 80 - panelH)
        }
        installConversationPanel(at: origin)
        // 顶部:缩略图 + 指令气泡
        if let tv = convoTextView, let storage = tv.textStorage {
            storage.append(thumbnailString(image, maxW: convoW - convoPad * 2))
            storage.append(NSAttributedString(string: instruction + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: MD.bodyStyle()]))
        }
        sendTurn()   // sendTurn 内部把 assistantStart 设到当前末尾,流式答案接在缩略图+指令之后
        growConversation(force: true)
    }
```

- [ ] **Step 4: 编译**

Run: `cd popdict-app && bash build.sh`
Expected: 编译通过。

- [ ] **Step 5: 提交**

```bash
git add popdict-app/main.swift
git commit -m "feat: 图片会话入口 beginImageConversation(复用会话浮窗+缩略图)"
```

---

### Task 5: 触发(Carbon 热键 ⌃⌥E + 菜单)与权限 UI

**Files:**
- Modify: `popdict-app/main.swift`(`import Carbon.HIToolbox`;新增 `HotKey` 类;`AppDelegate` 注册热键、菜单项、`onScreenshotExplain`、权限菜单与设置入口)

**Interfaces:**
- Consumes:Task 3 `RegionCapture`(`capture`/`hasScreenRecordingPermission`/`requestScreenRecordingPermission`);Task 4 `beginImageConversation`。
- Produces:全局热键 ⌃⌥E → 截图解释;菜单项「📷 截图解释 (⌃⌥E)」「屏幕录制」状态 + 设置入口。

- [ ] **Step 1: 引入 Carbon + HotKey 类**

`main.swift` 顶部加 `import Carbon.HIToolbox`。在「全局鼠标事件 tap」区域附近(文件末尾的全局区)新增:

```swift
// MARK: - 全局热键(Carbon)

final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handlerInstalled = false
    private static var actions: [UInt32: () -> Void] = [:]
    private let id: UInt32

    init?(keyCode: UInt32, modifiers: UInt32, id: UInt32, action: @escaping () -> Void) {
        self.id = id
        HotKey.actions[id] = action
        if !HotKey.handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
                var hkID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                HotKey.actions[hkID.id]?()
                return noErr
            }, 1, &spec, nil, nil)
            HotKey.handlerInstalled = true
        }
        let hkID = EventHotKeyID(signature: OSType(0x504f5044), id: id)   // 'POPD'
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { logLine("HOTKEY register failed status=\(status)"); return nil }
        logLine("HOTKEY registered ⌃⌥E id=\(id)")
    }
}
```

- [ ] **Step 2: AppDelegate 持有热键并注册**

`AppDelegate` 加属性 `var hotKey: HotKey?`。在 `applicationDidFinishLaunching` 里 `setupStatusItem()` 之后注册(kVK_ANSI_E = 0x0E,控制+option = controlKey|optionKey):

```swift
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_E),
                        modifiers: UInt32(controlKey | optionKey),
                        id: 1) { [weak self] in
            DispatchQueue.main.async { self?.onScreenshotExplain() }
        }
```

- [ ] **Step 3: 截图解释入口(含权限闸)**

`AppDelegate` 新增:

```swift
    @objc func onScreenshotExplain() {
        if !RegionCapture.hasScreenRecordingPermission() {
            RegionCapture.requestScreenRecordingPermission()
            let a = NSAlert()
            a.messageText = "需要「屏幕录制」权限"
            a.informativeText = "截图解释要用到屏幕录制权限。请在 系统设置 → 隐私与安全性 → 屏幕录制 里打开 popdict。\n\n注意:首次授予后通常需要重新打开 popdict 才生效。"
            a.addButton(withTitle: "打开设置")
            a.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn { openScreenRecordingSettings() }
            return
        }
        let rc = RegionCapture()
        rc.capture { [weak self] image in
            guard let self = self, let image = image else { return }
            self.popup.beginImageConversation(image: image)
        }
        // 持有 rc 直到回调:用关联保留
        objc_setAssociatedObject(self, &Self.rcKey, rc, .OBJC_ASSOCIATION_RETAIN)
    }
    private static var rcKey: UInt8 = 0

    @objc func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
```

> 说明:`rc` 用关联对象保留,回调结束后下次再点会被新的覆盖,避免被提前释放导致遮罩窗口消失。

- [ ] **Step 4: 菜单加入口与权限状态**

`buildMenu`(1183-1198)在「重新检查权限」之前插入截图入口,在两条权限状态行里补屏幕录制:

```swift
        // (在 API Key 状态行之后、第一个 separator 之前补)
        let scrOK = RegionCapture.hasScreenRecordingPermission()
        menu.addItem(NSMenuItem(title: scrOK ? "✓ 屏幕录制:已授权" : "⚠️ 屏幕录制:未授权(截图解释需要)",
                                action: nil, keyEquivalent: ""))
```

并在「辅助功能权限设置…」一组里加:

```swift
        let shot = NSMenuItem(title: "📷 截图解释", action: #selector(onScreenshotExplain), keyEquivalent: "")
        menu.addItem(shot)
        menu.addItem(NSMenuItem(title: "屏幕录制权限设置…", action: #selector(openScreenRecordingSettings), keyEquivalent: ""))
```

(放在 `menu.addItem(NSMenuItem(title: "辅助功能权限设置…"…))` 之后、`重新检查权限` 之前。)

- [ ] **Step 5: 编译**

Run: `cd popdict-app && bash build.sh`
Expected: 编译通过。

- [ ] **Step 6: 手动冒烟(本机,需 mimo_key + 屏幕录制权限)**

1. `echo '你的MiMo-key' > ~/.config/popdict/mimo_key`
2. 打开新编译的 `popdict.app`,授予辅助功能 + 屏幕录制(首次授屏幕录制后重开 App)。
3. 选中文字 → 「🌐 翻译」「💡 解释」仍正常(MiMo)。
4. 按 ⌃⌥E 或菜单「📷 截图解释」→ 框选一块屏幕 → 浮窗出缩略图 + 流式图解;追问一句仍结合该图回答;框选时 Esc 可取消。

- [ ] **Step 7: 提交**

```bash
git add popdict-app/main.swift
git commit -m "feat: ⌃⌥E 全局热键 + 菜单触发截图解释,加屏幕录制权限引导"
```

---

### Task 6: 文档更新 + UITEST 自测 + 全量验证

**Files:**
- Modify: `README.md`;`popdict-app/build.sh`(dmg 安装说明文案);`popdict-app/main.swift`(可选:`POPDICT_UITEST` 增加图片会话自测分支)

**Interfaces:**
- Consumes:全部前序任务。

- [ ] **Step 1: README 改写**

`README.md` 把 DeepSeek 相关改成 MiMo:标题/简介保留「翻译/解释」,新增「截图解释」一段;Key 配置改为 `~/.config/popdict/mimo_key` 与 MiMo 申请地址 `https://platform.xiaomimimo.com/`;新增「截图解释」用法(⌃⌥E 或菜单「📷 截图解释」→ 框选 → 解释 → 可追问)与「屏幕录制」权限说明(首授需重开 App);「工作原理」补一句截图链路;「隐私」改为「发送给 MiMo 官方接口」。

- [ ] **Step 2: build.sh 安装说明**

`build.sh` 的 dmg `安装说明.txt`(65-84):把「填 API Key」段改成 MiMo:
```
mkdir -p ~/.config/popdict && echo 'your-mimo-key' > ~/.config/popdict/mimo_key
```
并加一段:截图解释需「屏幕录制」权限(系统设置 → 隐私与安全性 → 屏幕录制,首授后重开),触发方式 ⌃⌥E 或菜单「📷 截图解释」。

- [ ] **Step 3:(可选)UITEST 图片会话自测分支**

若要 headless 验证多模态构造与缩略图渲染(不依赖真截图/真权限):在 `runDemoExplain` 附近加一个 `POPDICT_UITEST=image` 分支,读一张本地测试 PNG(如 `~/popdict_test.png`,无则跳过)调 `popup.beginImageConversation(image:)`,渲染 PNG + 记日志。无合适测试图时本步可跳过,改由 Step 4 手测覆盖。

- [ ] **Step 4: 全量编译 + 冒烟矩阵**

Run: `cd popdict-app && bash build.sh`
Expected: universal(arm64 + x86_64)编译通过,无新警告(弃用 API 警告除外)。
手动按 spec「验证」节 1-5 逐条过:翻译、解释流式、截图解释、Esc 取消、无权限引导。

- [ ] **Step 5: 提交**

```bash
git add README.md popdict-app/build.sh popdict-app/main.swift
git commit -m "docs: README/安装说明改为 MiMo + 截图解释;UITEST 图片自测"
```

- [ ] **Step 6: 多代理对抗审查**

按上一个功能的惯例(spec「实现记录」提到的「一轮多代理对抗审查」),用 Workflow 起多个审查代理分维度找问题(并发/坐标翻转/权限时序/内存保留/多屏/弃用 API/错误回滚/MiMo 协议假定),逐条对抗验证为真后修复,再编译过。修复各自小提交。

---

## Self-Review

**1. Spec coverage:**
- A 后端切 MiMo → Task 1 ✓
- B 多模态消息 → Task 2 ✓
- C 框选截图 → Task 3 ✓
- D 屏幕录制权限 → Task 3(助手)+ Task 5(菜单/闸)✓
- E 触发 + 图片会话 + 缩略图 → Task 4 + Task 5 ✓
- F 看图 prompt → Task 1 Step 2 ✓
- 文档/验证/对抗审查 → Task 6 ✓
- 全部 spec 章节均有对应任务,无遗漏。

**2. Placeholder scan:** Task 6 Step 3 标「可选」并给了明确触发条件与降级(无测试图则跳过、由手测覆盖),非占位。其余步骤均有完整代码/命令。

**3. Type consistency:**
- `chatStream(_ messages: [[String: Any]], …)`(Task 2)与 `sendTurn` 构造的 `[[String: Any]]`(Task 2 Step 3)一致。
- `RegionCapture.encodeToDataURL(_:)`/`capture(completion:)`/`hasScreenRecordingPermission()`/`requestScreenRecordingPermission()`(Task 3 定义)与 Task 4/5 调用一致。
- `beginImageConversation(image:instruction:at:)`(Task 4 定义)与 Task 5 调用 `beginImageConversation(image:)`(用默认参数)一致。
- `installConversationPanel(at:)`、`thumbnailString(_:maxW:)`、`attachedImageDataURL` 命名前后一致。
- `HotKey(keyCode:modifiers:id:action:)` 定义与注册调用一致。
- 无悬空引用。
