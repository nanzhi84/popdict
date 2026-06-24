import AppKit
import ApplicationServices
import os.log

// ============================================================
// popdict —— 划词翻译菜单栏小程序
// 选中文字 → 选区旁冒泡「🌐 翻译」按钮 → 点击 → DeepSeek 翻译 → 同处显示译文
// 方向:含中文 → 英文;其它 → 简体中文
// ============================================================

// MARK: - 路径 / 配置目录(最先初始化,保证日志可写)

let kConfigDir = (("~/.config/popdict" as NSString).expandingTildeInPath)
let kLogPath = kConfigDir + "/popdict.log"
let kKeyPath = kConfigDir + "/deepseek_key"

@discardableResult
func ensureConfigDir() -> Bool {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: kConfigDir, withIntermediateDirectories: true, attributes: nil)
    if !fm.fileExists(atPath: kLogPath) {
        fm.createFile(atPath: kLogPath, contents: nil)
    }
    return fm.fileExists(atPath: kConfigDir)
}

// 全局首次访问即建目录(Swift 全局 let 惰性且线程安全)
let _bootstrap: Bool = ensureConfigDir()

// MARK: - 日志(自愈 + NSLog 兜底)

let kLog = OSLog(subsystem: "com.yoryon.popdict", category: "popdict")

func tsNow() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

func logLine(_ s: String) {
    _ = _bootstrap
    let line = "[\(tsNow())] " + s + "\n"
    os_log("%{public}@", log: kLog, type: .info, s)   // Console.app 兜底,文件写不出也能看
    guard let data = line.data(using: .utf8) else { return }
    if let fh = FileHandle(forWritingAtPath: kLogPath) {
        fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
    } else {
        ensureConfigDir()
        if let fh = FileHandle(forWritingAtPath: kLogPath) {
            fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
        } else {
            try? line.write(toFile: kLogPath, atomically: false, encoding: .utf8)
        }
    }
}

// MARK: - API Key / 语言判断

func readAPIKey() -> String? {
    guard let raw = try? String(contentsOfFile: kKeyPath, encoding: .utf8) else { return nil }
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return key.isEmpty ? nil : key
}

func hasChinese(_ s: String) -> Bool {
    for scalar in s.unicodeScalars {
        if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF { return true }
    }
    return false
}

// MARK: - 取选中文字(AX 优先,失败再模拟 Cmd+C)

func selectedTextViaAX() -> String? {
    let systemWide = AXUIElementCreateSystemWide()
    var focused: AnyObject?
    guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let element = focused else { return nil }
    let axElement = element as! AXUIElement
    var selected: AnyObject?
    guard AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
          let text = selected as? String, !text.isEmpty else { return nil }
    return text
}

// 全类型快照 + 完整恢复,避免污染用户剪贴板;轮询 changeCount 而非死等
func selectedTextViaCopy() -> String? {
    let pb = NSPasteboard.general
    let oldChange = pb.changeCount

    // 1. 全类型快照(尽量保留富文本/图片/文件等)
    var snapshot: [NSPasteboardItem] = []
    if let items = pb.pasteboardItems {
        for item in items {
            let copy = NSPasteboardItem()
            for type in item.types {
                if let d = item.data(forType: type) {
                    copy.setData(d, forType: type)
                }
            }
            snapshot.append(copy)
        }
    }

    // 2. 模拟 Cmd+C
    let src = CGEventSource(stateID: .combinedSessionState)
    let keyC: CGKeyCode = 0x08
    let down = CGEvent(keyboardEventSource: src, virtualKey: keyC, keyDown: true); down?.flags = .maskCommand
    let up = CGEvent(keyboardEventSource: src, virtualKey: keyC, keyDown: false); up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)

    // 3. 轮询等待剪贴板变化(最多 ~700ms),变化后再读
    var copied: String? = nil
    for _ in 0..<35 {
        usleep(20_000)
        if pb.changeCount != oldChange {
            copied = pb.string(forType: .string)
            break
        }
    }

    // 4. 恢复用户原剪贴板
    if pb.changeCount != oldChange {
        pb.clearContents()
        if !snapshot.isEmpty { pb.writeObjects(snapshot) }
    }

    if let t = copied, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t }
    return nil
}

// MARK: - 翻译(DeepSeek)

func translate(_ text: String, completion: @escaping (String?, String?) -> Void) {
    guard let apiKey = readAPIKey() else {
        completion(nil, "没找到 API Key。请把 DeepSeek Key 写进:\n\(kKeyPath)")
        return
    }
    let target = hasChinese(text) ? "English" : "Simplified Chinese"
    let sys = "You are a professional translation engine. Translate the user's text into \(target). Output ONLY the translation itself — no explanations, no quotes, no extra words."

    let body: [String: Any] = [
        "model": "deepseek-chat",
        "messages": [
            ["role": "system", "content": sys],
            ["role": "user", "content": text]
        ],
        "temperature": 0.3,
        "stream": false
    ]
    guard let url = URL(string: "https://api.deepseek.com/chat/completions"),
          let data = try? JSONSerialization.data(withJSONObject: body) else {
        completion(nil, "请求构造失败"); return
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.httpBody = data
    req.timeoutInterval = 30

    URLSession.shared.dataTask(with: req) { respData, resp, err in
        if let err = err {
            DispatchQueue.main.async { completion(nil, "网络错误:\(err.localizedDescription)") }
            return
        }
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            DispatchQueue.main.async { completion(nil, "DeepSeek 出错(HTTP \(http.statusCode)),请检查 Key 或余额") }
            return
        }
        guard let respData = respData,
              let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            DispatchQueue.main.async { completion(nil, "返回解析失败") }
            return
        }
        DispatchQueue.main.async { completion(content.trimmingCharacters(in: .whitespacesAndNewlines), nil) }
    }.resume()
}

// MARK: - 冒泡/译文浮窗

// 可成为 key 的浮窗:让用户能在结果里拖选译文 + ⌘C
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// 悬浮按钮:无边框,hover/按下时浮起高亮(系统菜单项的交互语言)
final class HoverButton: NSButton {
    private var trackingAreaRef: NSTrackingArea?
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressing = false { didSet { needsDisplay = true } }
    var labelText = "🌐 翻译"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        wantsLayer = true
        focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressing = false }
    override func mouseDown(with event: NSEvent) { pressing = true }
    override func mouseDragged(with event: NSEvent) {
        pressing = bounds.contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressing = false
        if inside, let action = action, let target = target {
            NSApp.sendAction(action, to: target, from: self)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        if pressing || hovering {
            let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 6, yRadius: 6)
            NSColor.selectedContentBackgroundColor.withAlphaComponent(pressing ? 0.45 : 0.20).setFill()
            bg.fill()
        }
        let color = (hovering || pressing) ? NSColor.labelColor : NSColor.secondaryLabelColor
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: para
        ]
        let s = labelText as NSString
        let size = s.size(withAttributes: attrs)
        let r = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: bounds.width, height: size.height)
        s.draw(in: r, withAttributes: attrs)
    }
}

final class PopupController {
    private var panel: NSPanel?
    private var body: NSView?
    private var pendingText: String?
    private var lastResult: String?
    private weak var copyButton: HoverButton?
    private let appearDur: TimeInterval = 0.14
    private let dismissDur: TimeInterval = 0.10
    private let switchDur: TimeInterval = 0.16

    var isVisible: Bool { panel != nil }
    func frame() -> NSRect? { panel?.frame }

    func dismiss() {
        guard let p = panel else { return }
        panel = nil; body = nil; pendingText = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = self.dismissDur
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }

    func showButton(at point: NSPoint, text: String) {
        pendingText = text
        let w: CGFloat = 96, h: CGFloat = 32
        let rect = placedRect(near: point, w: w, h: h)
        let btn = HoverButton(frame: NSRect(x: 0, y: 0, width: w, height: h))
        btn.target = self
        btn.action = #selector(onTranslateClicked)
        present(content: btn, rect: rect)
    }

    // 首次显示淡入;已有面板则平滑改尺寸 + 内容 crossfade
    private func present(content newBody: NSView, rect: NSRect) {
        if let p = panel, let blur = p.contentView {
            newBody.frame = NSRect(origin: .zero, size: rect.size)
            newBody.alphaValue = 0
            blur.addSubview(newBody)
            let old = body
            body = newBody
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = self.switchDur
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                p.animator().setFrame(rect, display: true)
                old?.animator().alphaValue = 0
                newBody.animator().alphaValue = 1
            }, completionHandler: { old?.removeFromSuperview() })
        } else {
            let p = makePanel(rect)
            newBody.frame = NSRect(origin: .zero, size: rect.size)
            p.contentView?.addSubview(newBody)
            body = newBody
            panel = p
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = self.appearDur
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().alphaValue = 1
            })
        }
    }

    @objc private func onTranslateClicked() {
        guard let text = pendingText else { return }
        showMessage("翻译中…", isError: false)
        translate(text) { [weak self] result, errMsg in
            guard let self = self else { return }
            if let errMsg = errMsg {
                self.showMessage(errMsg, isError: true)
            } else {
                self.showMessage(result ?? "(空)", isError: false, showCopy: true, markdown: true)
            }
        }
    }

    @objc private func onCopyClicked() {
        guard let s = lastResult else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        copyButton?.labelText = "已复制 ✓"
        copyButton?.needsDisplay = true
        let btn = copyButton
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            btn?.labelText = "复制"
            btn?.needsDisplay = true
        }
    }

    // 真实测量换行后文本高度(对富文本同样准确)
    private func measuredTextHeight(_ attr: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: attr)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let lm = NSLayoutManager()
        lm.addTextContainer(container)
        storage.addLayoutManager(lm)
        lm.ensureLayout(for: container)
        return ceil(lm.usedRect(for: container).height)
    }

    // 把简单 markdown(粗体/斜体/等宽代码/链接)渲染成富文本;字号统一为 baseFont 并保留粗斜等 traits
    private func attributedMarkdown(_ s: String, baseFont: NSFont, color: NSColor) -> NSAttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let base = try? NSAttributedString(markdown: s, options: opts) else {
            return NSAttributedString(string: s, attributes: [.font: baseFont, .foregroundColor: color])
        }
        let attr = NSMutableAttributedString(attributedString: base)
        let full = NSRange(location: 0, length: attr.length)
        attr.addAttribute(.foregroundColor, value: color, range: full)
        attr.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            let f = (value as? NSFont) ?? baseFont
            let resized = NSFont(descriptor: f.fontDescriptor, size: baseFont.pointSize) ?? baseFont
            attr.addAttribute(.font, value: resized, range: range)
        }
        return attr
    }

    private func showMessage(_ message: String, isError: Bool, showCopy: Bool = false, markdown: Bool = false) {
        lastResult = showCopy ? message : nil
        copyButton = nil
        let origin = panel?.frame.origin ?? NSEvent.mouseLocation

        let w: CGFloat = 420
        let pad: CGFloat = 14
        let footerH: CGFloat = 36
        let bottomInset: CGFloat = showCopy ? footerH : pad
        let textW = w - pad * 2
        let font = NSFont.systemFont(ofSize: 14)
        let textColor = isError ? NSColor.systemRed : NSColor.labelColor

        // 译文按简单 markdown 渲染;其它(翻译中/错误)纯文本
        let attr = markdown
            ? attributedMarkdown(message, baseFont: font, color: textColor)
            : NSAttributedString(string: message, attributes: [.font: font, .foregroundColor: textColor])

        // 测真实高度,超过上限就用滚动条(应对超长译文 + 换行)
        let contentH = max(20, measuredTextHeight(attr, width: textW))
        let screenH = NSScreen.main?.visibleFrame.height ?? 800
        let maxContentH = min(440, screenH - 140)
        let visibleH = min(contentH, maxContentH)
        let panelH = pad + visibleH + bottomInset

        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: panelH))
        let scroll = NSScrollView(frame: NSRect(x: pad, y: bottomInset, width: textW, height: visibleH))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = contentH > maxContentH
        scroll.autohidesScrollers = true

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: textW, height: contentH))
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textColor = textColor
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = NSSize(width: textW, height: visibleH)
        tv.maxSize = NSSize(width: textW, height: .greatestFiniteMagnitude)
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: textW, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textStorage?.setAttributedString(attr)
        scroll.documentView = tv
        container.addSubview(scroll)

        // 译文结果:底部加分隔线 + 「复制」按钮
        if showCopy {
            let line = NSView(frame: NSRect(x: pad, y: footerH, width: textW, height: 1))
            line.wantsLayer = true
            line.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
            container.addSubview(line)
            let cbW: CGFloat = 70, cbH: CGFloat = 24
            let cb = HoverButton(frame: NSRect(x: w - pad - cbW, y: (footerH - cbH) / 2, width: cbW, height: cbH))
            cb.labelText = "复制"
            cb.target = self
            cb.action = #selector(onCopyClicked)
            container.addSubview(cb)
            copyButton = cb
        }

        var rect = NSRect(x: origin.x, y: origin.y, width: w, height: panelH)
        rect = clampToScreen(rect)
        present(content: container, rect: rect)
        tv.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private func makePanel(_ rect: NSRect) -> NSPanel {
        let p = KeyablePanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.animationBehavior = .none

        // 毛玻璃背板:.menu 材质 + behindWindow 实时模糊;圆角靠父 layer 裁切,阴影交给系统
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: rect.size))
        blur.material = .menu
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 9
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        blur.autoresizingMask = [.width, .height]
        p.contentView = blur
        return p
    }

    private func placedRect(near point: NSPoint, w: CGFloat, h: CGFloat) -> NSRect {
        var rect = NSRect(x: point.x + 8, y: point.y - h - 8, width: w, height: h)
        rect = clampToScreen(rect)
        return rect
    }

    private func clampToScreen(_ rect: NSRect) -> NSRect {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) })
                ?? NSScreen.main else { return rect }
        let vf = screen.visibleFrame
        var r = rect
        if r.maxX > vf.maxX { r.origin.x = vf.maxX - r.width - 6 }
        if r.minX < vf.minX { r.origin.x = vf.minX + 6 }
        if r.maxY > vf.maxY { r.origin.y = vf.maxY - r.height - 6 }
        if r.minY < vf.minY { r.origin.y = vf.minY + 6 }
        return r
    }
}

// MARK: - 全局鼠标事件 tap(CGEventTap)+ 自愈 + 授权后重建

var gDownLoc: CGPoint = .zero
var gDownInsidePopup = false
var gEventTap: CFMachPort?
var gRunLoopSource: CFRunLoopSource?
var gTapPollTimer: Timer?
weak var gAppDelegate: AppDelegate?

let kDragThreshold: CGFloat = 12   // 提高门槛,过滤点选/微抖动误触

func handleMouseUpAt(dist: CGFloat) {
    logLine("tap mouseUp dist=\(String(format: "%.1f", dist))")
    if dist < kDragThreshold { return }
    // 取词放后台线程,避免 usleep 阻塞主 runloop 导致 tap 超时被禁用
    DispatchQueue.global(qos: .userInitiated).async {
        usleep(50_000)
        let ax = selectedTextViaAX()
        logLine("  AX=\(ax ?? "nil")")
        let text = ax ?? selectedTextViaCopy()
        logLine("  final=\(text ?? "nil")")
        guard let text = text else { return }
        DispatchQueue.main.async {
            gAppDelegate?.popup.showButton(at: NSEvent.mouseLocation, text: text)
        }
    }
}

let gEventCallback: CGEventTapCallBack = { _, type, event, _ in
    // tap 被系统自动禁用时立即重新启用(自愈)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = gEventTap { CGEvent.tapEnable(tap: t, enable: true) }
        logLine("TAP_RE_ENABLED type=\(type.rawValue)")
        return Unmanaged.passUnretained(event)
    }

    let loc = event.location
    if type == .leftMouseDown {
        gDownLoc = loc
        DispatchQueue.main.async {
            gDownInsidePopup = false
            if let ad = gAppDelegate, ad.popup.isVisible, let f = ad.popup.frame() {
                if f.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) {
                    gDownInsidePopup = true        // 点在浮窗内:让用户选字/点按钮,不关、不当作新划词
                } else {
                    ad.popup.dismiss()             // 点在浮窗外:失焦关闭
                }
            }
        }
    } else if type == .leftMouseUp {
        let dx = loc.x - gDownLoc.x
        let dy = loc.y - gDownLoc.y
        let dist = (dx*dx + dy*dy).squareRoot()
        DispatchQueue.main.async {
            if gDownInsidePopup { gDownInsidePopup = false; return }  // 在浮窗里的拖选,不触发新气泡
            handleMouseUpAt(dist: dist)
        }
    }
    return Unmanaged.passUnretained(event)
}

@discardableResult
func setupEventTap() -> Bool {
    if let tap = gEventTap {                       // 已建过,确保启用
        CGEvent.tapEnable(tap: tap, enable: true)
        let ok = CGEvent.tapIsEnabled(tap: tap)
        logLine("EVENT_TAP_REENABLE enabled=\(ok)")
        return ok
    }
    let mask = (UInt64(1) << CGEventType.leftMouseDown.rawValue) | (UInt64(1) << CGEventType.leftMouseUp.rawValue)
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: CGEventMask(mask),
        callback: gEventCallback,
        userInfo: nil) else {
        logLine("EVENT_TAP_CREATE_FAILED trusted=\(AXIsProcessTrusted())")
        return false
    }
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    gEventTap = tap
    gRunLoopSource = src
    // listen-only tap 在无权限时 tapCreate 不返回 nil,但 tapIsEnabled 为 false
    let enabled = CGEvent.tapIsEnabled(tap: tap)
    logLine("EVENT_TAP_CREATED enabled=\(enabled) trusted=\(AXIsProcessTrusted())")
    return enabled
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    let popup = PopupController()
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureConfigDir()
        logLine("=== launch AX_TRUSTED=\(AXIsProcessTrusted()) configDir=\(FileManager.default.fileExists(atPath: kConfigDir)) ===")
        gAppDelegate = self
        setupStatusItem()

        if AXIsProcessTrusted() {
            setupEventTap()
        } else {
            requestAccessibility()          // 弹一次系统授权提示
            startWaitingForAccessibility()  // 轮询,授权后自动建 tap
        }
    }

    func startWaitingForAccessibility() {
        logLine("waiting for accessibility…")
        gTapPollTimer?.invalidate()
        gTapPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            if AXIsProcessTrusted() {
                let ok = setupEventTap()
                logLine("accessibility granted, tap setup ok=\(ok)")
                if ok {
                    t.invalidate()
                    gTapPollTimer = nil
                }
                self?.refreshMenu()
            }
        }
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "popdict 划词翻译", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let axOK = AXIsProcessTrusted()
        menu.addItem(NSMenuItem(title: axOK ? "✓ 辅助功能:已授权" : "⚠️ 辅助功能:未授权(点下面去开)",
                                action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: readAPIKey() == nil ? "⚠️ 未填 API Key" : "✓ 已配置 API Key",
                                action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "辅助功能权限设置…", action: #selector(openAXSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重新检查权限", action: #selector(recheck), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        return menu
    }

    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🌐"
        item.menu = buildMenu()
        statusItem = item
    }

    func refreshMenu() {
        statusItem?.menu = buildMenu()
    }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    @objc func openAXSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func recheck() {
        logLine("manual recheck AX_TRUSTED=\(AXIsProcessTrusted())")
        if AXIsProcessTrusted() {
            setupEventTap()
            gTapPollTimer?.invalidate(); gTapPollTimer = nil
        } else if gTapPollTimer == nil {
            requestAccessibility()
            startWaitingForAccessibility()
        }
        refreshMenu()
    }

    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - 启动

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
