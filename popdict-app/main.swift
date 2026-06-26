import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os.log

// ============================================================
// popdict —— 划词翻译 / 解释 / 截图解释 菜单栏小程序
// 选中文字 → 选区旁冒泡「🌐 翻译」「💡 解释」→ 点击 → MiMo → 同处显示结果
//   翻译:含中文 → 英文;其它 → 简体中文
//   解释:用简体中文把概念/代码讲明白,MiMo 流式逐字输出(打字机)
//   截图解释:⌃⌥E / 菜单「📷 截图解释」框选屏幕 → MiMo 多模态看图讲解(可追问)
// ============================================================

// MARK: - 路径 / 配置目录(最先初始化,保证日志可写)

let kConfigDir = (("~/.config/popdict" as NSString).expandingTildeInPath)
let kLogPath = kConfigDir + "/popdict.log"
let kKeyPath = kConfigDir + "/mimo_key"          // 原 deepseek_key,已全量切到 MiMo

// MARK: - 模型后端(小米 MiMo,OpenAI 兼容)

let kAPIBase = "https://api.xiaomimimo.com/v1"
let kChatPath = "/chat/completions"              // 完整地址 = kAPIBase + kChatPath
let kModel = "mimo-v2.5"                          // 多模态:同时管文字翻译/解释与看图
let kMaxTokens = 4096

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

// AppKit(左下原点)↔ Quartz(左上原点)翻转的基准高度:主屏的高度。
// 主屏 = AppKit 原点 (0,0) 所在那块(也是 Quartz 原点所在屏)。
// 注意:不能用「所有屏幕并集」高度,也不能用 NSScreen.main(那是焦点屏);多屏不等高时
// 用并集高度会让两块屏的截图都整体偏移。CGWindowListCreateImage 的坐标系正是以主屏左上为原点。
func primaryScreenHeight() -> CGFloat {
    return (NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.screens.first)?.frame.height ?? 0
}

// MARK: - 取选中文字(AX 优先,失败再模拟 Cmd+C)

func selectedTextViaAX() -> String? {
    let systemWide = AXUIElementCreateSystemWide()
    var focused: AnyObject?
    guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
    let axElement = element as! AXUIElement
    var selected: AnyObject?
    guard AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
          let text = selected as? String, !text.isEmpty else { return nil }
    return text
}

// 取选中文字 + 选区屏幕范围(Quartz 左上原点坐标)。bounds 用于把浮窗定位到选区右侧;取不到则 bounds=nil。
func selectedTextAndBoundsViaAX() -> (text: String, bounds: CGRect?)? {
    let systemWide = AXUIElementCreateSystemWide()
    var focused: AnyObject?
    guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
    let axElement = element as! AXUIElement
    var selected: AnyObject?
    guard AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
          let text = selected as? String, !text.isEmpty else { return nil }
    return (text, boundsForSelection(axElement))
}

// 取选区屏幕矩形(Quartz 左上原点)。多套方法兜底以覆盖更多 App:
//   1) kAXSelectedTextRange + kAXBoundsForRange(原生 Cocoa 文本视图)
//   2) AXSelectedTextMarkerRange + AXBoundsForTextMarkerRange(WebKit/Safari、部分 Electron)
//   3) 焦点元素自身的 kAXFrame(粗略:整个输入框,作最后兜底)
func boundsForSelection(_ el: AXUIElement) -> CGRect? {
    func rectFromValue(_ v: AnyObject?) -> CGRect? {
        guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        return rect
    }
    // 方法 1:range → bounds
    var rangeVal: AnyObject?
    let rErr = AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeVal)
    if rErr == .success, let rangeVal = rangeVal, CFGetTypeID(rangeVal) == AXValueGetTypeID() {
        var bv: AnyObject?
        let bErr = AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, rangeVal, &bv)
        if let r = rectFromValue(bv) { return r }
        logLine("    m1 bounds-for-range err=\(bErr.rawValue)")
    } else {
        logLine("    m1 selected-range err=\(rErr.rawValue)")
    }
    // 方法 2:WebKit text marker range → bounds
    var mr: AnyObject?
    let mErr = AXUIElementCopyAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, &mr)
    if mErr == .success, let mr = mr {
        var bv: AnyObject?
        let bErr = AXUIElementCopyParameterizedAttributeValue(el, "AXBoundsForTextMarkerRange" as CFString, mr, &bv)
        if let r = rectFromValue(bv) { return r }
        logLine("    m2 marker-bounds err=\(bErr.rawValue)")
    } else {
        logLine("    m2 marker-range err=\(mErr.rawValue)")
    }
    // 方法 3:焦点元素整体 frame(粗略兜底)
    var fv: AnyObject?
    if AXUIElementCopyAttributeValue(el, "AXFrame" as CFString, &fv) == .success, let r = rectFromValue(fv) {
        logLine("    m3 element-frame used")
        return r
    }
    logLine("    bounds: all methods failed")
    return nil
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

// MARK: - 翻译(MiMo)

func translate(_ text: String, completion: @escaping (String?, String?) -> Void) {
    guard let apiKey = readAPIKey() else {
        completion(nil, "没找到 API Key。请把 MiMo Key 写进:\n\(kKeyPath)")
        return
    }
    let target = hasChinese(text) ? "English" : "Simplified Chinese"
    let sys = "You are a professional translation engine. Translate the user's text into \(target). Output ONLY the translation itself — no explanations, no quotes, no extra words."

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
            DispatchQueue.main.async { completion(nil, "MiMo 出错(HTTP \(http.statusCode)),请检查 Key 或余额") }
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

// MARK: - 解释 / 追问(MiMo 流式 / SSE)

// 解释用的 system prompt(自适应:代码拆解、概念大白话;短则短答长则分点)
let kExplainSystem = """
你是一个善于把复杂概念和代码讲清楚的助手。请用简体中文解释用户给出的内容,帮他真正理解。
- 如果是代码:先说它整体在做什么,再逐步拆解关键逻辑,点出涉及的语法、库或设计意图,必要时给一句类比或小例子。
- 如果是术语或概念:用大白话讲清它是什么、为什么重要、怎么用。
- 如果是图片:先一句说清这张图整体是什么(截图/图表/报错/界面/照片/文档…),再解读其中关键信息。报错或代码截图就定位问题并给排查/解决方向;图表就读出趋势与要点;界面或流程就说清它在干什么。
- 内容简短就简短回答(几句话点透),内容复杂就分点详解。
- 直接开始,不要寒暄,不要复述原文。可以用 markdown(## 小标题、**加粗**、`代码`、- 列表、```代码块```)让层次清晰。
- 后续若有追问,延续上下文回答。
"""

// 通用流式对话:messages 为完整消息数组(含 system);逐字回吐(打字机)。
// 返回可取消的 Task;无 key 等同步错误时回调 onError 并返回 nil。
@discardableResult
func chatStream(_ messages: [[String: Any]],
                onDelta: @escaping (String) -> Void,
                onDone: @escaping (String) -> Void,
                onError: @escaping (String) -> Void) -> Task<Void, Never>? {
    guard let apiKey = readAPIKey() else {
        onError("没找到 API Key。请把 MiMo Key 写进:\n\(kKeyPath)")
        return nil
    }
    let body: [String: Any] = [
        "model": kModel,
        "messages": messages,
        "temperature": 0.5,
        "max_completion_tokens": kMaxTokens,
        "thinking": ["type": "disabled"],
        "stream": true
    ]
    guard let url = URL(string: kAPIBase + kChatPath),
          let data = try? JSONSerialization.data(withJSONObject: body) else {
        onError("请求构造失败"); return nil
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    req.httpBody = data
    req.timeoutInterval = 60

    return Task {
        var accum = ""
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                await MainActor.run { onError("MiMo 出错(HTTP \(http.statusCode)),请检查 Key 或余额") }
                return
            }
            for try await line in bytes.lines {
                if Task.isCancelled { return }
                guard line.hasPrefix("data:") else { continue }     // 跳过空行 / `: keep-alive` 心跳
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let d = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let first = choices.first,
                      let delta = first["delta"] as? [String: Any],
                      let piece = delta["content"] as? String, !piece.isEmpty else { continue }
                accum += piece
                let snapshot = piece
                await MainActor.run { onDelta(snapshot) }
            }
            if Task.isCancelled { return }
            let full = accum
            await MainActor.run {
                if full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onError("MiMo 没有返回内容")
                } else {
                    onDone(full)
                }
            }
        } catch {
            if Task.isCancelled { return }
            let msg = error.localizedDescription
            await MainActor.run { onError("网络错误:\(msg)") }
        }
    }
}

// MARK: - 冒泡/译文浮窗

// 可成为 key 的浮窗:让用户能在结果里拖选译文 + ⌘C
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// 可拖动的毛玻璃背板:背景空白处可拖动窗口(文字区仍能选中、按钮/输入框各自处理事件)
final class DraggableBlurView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }
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

    // 会话(解释 + 追问)状态
    private var convo: [(role: String, content: String)] = []   // 不含 system;首条 user 为原文
    private var attachedImageDataURL: String?                    // 截图解释:本轮会话附带的图(base64 data URL),整段会话期间保留、每轮重发
    private var convoTextView: NSTextView?                       // 整段对话的 transcript
    private var convoScroll: NSScrollView?
    private var askField: NSTextField?                           // 底部追问输入框
    private var convoTask: Task<Void, Never>?
    private var convoTimer: Timer?
    private var assistantStart = 0                               // 当前 assistant 流式段在 transcript 的起点
    private var assistantAccum = ""
    private var turnStartLoc = 0                                 // 本轮(含追问气泡)在 transcript 的起点,失败可整轮回滚
    private var generation = 0                                   // 递增令牌:关闭/新划词时 +1,作废在途的非流式回调(翻译)
    private var uiTestMode = false                               // POPDICT_UITEST:自测模式(程序化驱动 + 截图 + 长高日志)
    private let convoFont = NSFont.systemFont(ofSize: 14)
    private let convoW: CGFloat = 460
    private let convoPad: CGFloat = 18
    private let inputBarH: CGFloat = 46
    private let transcriptBottomGap: CGFloat = 14   // transcript 与底部输入栏分割线之间的留白

    var isVisible: Bool { panel != nil }
    func frame() -> NSRect? { panel?.frame }
    // 追问输入法正在合成(点候选词等):外部点击不应关闭会话
    var isComposingText: Bool { (askField?.currentEditor() as? NSTextView)?.hasMarkedText() ?? false }

    func dismiss() {
        guard let p = panel else { return }
        generation += 1
        stopConversation()
        panel = nil; body = nil; pendingText = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = self.dismissDur
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }

    func showButton(text: String, selectionBounds: CGRect? = nil, fallbackPoint: NSPoint) {
        generation += 1
        stopConversation()
        pendingText = text
        let h: CGFloat = 32, bw: CGFloat = 74, sep: CGFloat = 1
        let w: CGFloat = bw * 2 + sep
        let rect = buttonRect(w: w, h: h, selectionBounds: selectionBounds, fallbackPoint: fallbackPoint)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        let tBtn = HoverButton(frame: NSRect(x: 0, y: 0, width: bw, height: h))
        tBtn.labelText = "🌐 翻译"
        tBtn.target = self
        tBtn.action = #selector(onTranslateClicked)
        container.addSubview(tBtn)

        let line = NSView(frame: NSRect(x: bw, y: 6, width: sep, height: h - 12))
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        container.addSubview(line)

        let eBtn = HoverButton(frame: NSRect(x: bw + sep, y: 0, width: bw, height: h))
        eBtn.labelText = "💡 解释"
        eBtn.target = self
        eBtn.action = #selector(onExplainClicked)
        container.addSubview(eBtn)

        present(content: container, rect: rect)
    }

    // 首次显示淡入;已有面板则改尺寸 + 内容 crossfade。
    // animateFrame=false 时直接定尺寸不做帧动画(用于会话浮窗:避免动画期间 container autoresize 累积放大)。
    private func present(content newBody: NSView, rect: NSRect, animateFrame: Bool = true) {
        if let p = panel, let blur = p.contentView {
            if !animateFrame { p.setFrame(rect, display: true) }   // 立即定尺寸,blur 同步到位
            newBody.frame = NSRect(origin: .zero, size: rect.size)
            newBody.alphaValue = 0
            blur.addSubview(newBody)
            let old = body
            body = newBody
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = self.switchDur
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                if animateFrame { p.animator().setFrame(rect, display: true) }
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
        let gen = generation
        showMessage("翻译中…", isError: false)
        translate(text) { [weak self] result, errMsg in
            guard let self = self, gen == self.generation else { return }   // 浮窗已被关闭/换词:丢弃结果
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

    // MARK: 解释 / 追问(会话浮窗)

    @objc private func onExplainClicked() {
        guard let text = pendingText else { return }
        beginConversation(firstUserText: text)
    }

    // UI 自测入口(仅 POPDICT_UITEST 时调用):程序化冒按钮 → 解释 → 追问,验证整链路 + 截图 + 长高日志。
    // (注:真实鼠标/键盘合成事件无法投递给 nonactivating 后台浮窗——只有真人指针下的点击才会到达,故这里走程序化。)
    func runDemoExplain() {
        uiTestMode = true
        let q = "用中文详细解释 Python 的装饰器(decorator):是什么、@ 语法糖的原理、不带参数和带参数的装饰器分别怎么写、以及 functools.wraps 的作用。请分小节、配多个代码例子。"
        let p = NSScreen.main.map { NSPoint(x: $0.frame.midX - 100, y: $0.frame.midY + 220) } ?? NSEvent.mouseLocation
        showButton(text: q, selectionBounds: nil, fallbackPoint: p)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.onExplainClicked() }
    }

    // App 把自己的浮窗内容渲染成 PNG(不需要屏幕录制权限),用于真实渲染自测
    private func capturePanel(to path: String) {
        // 1) 整个面板(含输入栏)
        if let cv = panel?.contentView, let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
            cv.cacheDisplay(in: cv.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path)); logLine("UITEST captured \(path)")
            }
        }
        // 2) 完整 transcript(不受滚动裁剪,验证真实视图里全部 markdown)
        if let tv = convoTextView {
            tv.drawsBackground = true
            tv.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1)
            if let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds) {
                tv.cacheDisplay(in: tv.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "_full.png")))
                }
            }
            tv.drawsBackground = false
        }
    }

    // 搭建会话浮窗骨架(transcript 滚动区 + 底部追问输入栏),present 并启动长高定时器。
    // 由 beginConversation(文字解释)与 beginImageConversation(截图解释)共用。
    private func installConversationPanel(at origin: NSPoint) {
        let textW = convoW - convoPad * 2
        let visibleH: CGFloat = 22
        let panelH = convoPad + visibleH + transcriptBottomGap + inputBarH
        let container = NSView(frame: NSRect(x: 0, y: 0, width: convoW, height: panelH))
        container.autoresizingMask = [.width, .height]   // present 用 animateFrame:false 直接定尺寸,不会被动画放大

        // transcript(可选中、滚动);底部留出输入栏 + 留白,顶部留内边距
        let scroll = NSScrollView(frame: NSRect(x: convoPad, y: inputBarH + transcriptBottomGap, width: textW, height: visibleH))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        let tv = makeTranscriptView(width: textW)
        scroll.documentView = tv
        container.addSubview(scroll)
        convoScroll = scroll
        convoTextView = tv

        // 底部输入栏(常驻;解释期间禁用)
        container.addSubview(makeInputBar(width: convoW))

        assistantStart = 0
        assistantAccum = ""
        turnStartLoc = 0

        var rect = NSRect(x: origin.x, y: origin.y, width: convoW, height: panelH)
        rect = clampToScreen(rect)
        present(content: container, rect: rect, animateFrame: false)   // 会话切换:直接定尺寸,不做帧动画
        startConvoTimer()             // 立即启动生长(不依赖 completionHandler,后者在本类浮窗下不可靠)
    }

    // 建会话浮窗:transcript 滚动区 + 底部追问输入栏(解释时禁用),发起第一轮解释
    private func beginConversation(firstUserText: String, at fixedOrigin: NSPoint? = nil) {
        stopConversation()
        attachedImageDataURL = nil
        convo = [(role: "user", content: firstUserText)]
        let panelH = convoPad + 22 + transcriptBottomGap + inputBarH
        // 顶边对齐:从按钮切到会话时保持「顶边」不动(会话向下生长,顶边贴着选区上沿)
        let origin: NSPoint
        if let fo = fixedOrigin { origin = fo }
        else if let pf = panel?.frame { origin = NSPoint(x: pf.minX, y: pf.maxY - panelH) }
        else { origin = NSEvent.mouseLocation }
        installConversationPanel(at: origin)
        sendTurn()
    }

    // 截图解释:把图存为会话首条 user(每轮重发),顶部放缩略图 + 指令气泡,然后流式解释。
    // 与文字解释共用同一套会话浮窗 + 追问 + 回滚逻辑。
    func beginImageConversation(image: NSImage, instruction: String = "请解释这张图片的内容。", at fixedOrigin: NSPoint? = nil) {
        generation += 1
        stopConversation()
        guard let dataURL = RegionCapture.encodeToDataURL(image) else {
            showMessage("图片编码失败,请重试", isError: true)
            return
        }
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
        // 顶部:缩略图 + 指令气泡(在 sendTurn 之前插入,流式答案接其后)
        if let tv = convoTextView, let storage = tv.textStorage {
            storage.append(thumbnailString(image, maxW: convoW - convoPad * 2))
            storage.append(NSAttributedString(string: instruction + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: MD.bodyStyle()]))
        }
        sendTurn()
        growConversation(force: true)
    }

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

    // 用自定义 CodeBlockLayoutManager 建可选中、可竖向自适应的 NSTextView(代码块满宽圆角底由它绘制)
    private func makeRenderingTextView(width textW: CGFloat) -> NSTextView {
        let storage = NSTextStorage()
        let lm = CodeBlockLayoutManager()
        storage.addLayoutManager(lm)
        let container = NSTextContainer(size: NSSize(width: textW, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        lm.addTextContainer(container)
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: textW, height: 22), textContainer: container)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.maxSize = NSSize(width: textW, height: .greatestFiniteMagnitude)
        tv.autoresizingMask = [.width]
        return tv
    }

    private func makeTranscriptView(width textW: CGFloat) -> NSTextView {
        let tv = makeRenderingTextView(width: textW)
        tv.minSize = NSSize(width: textW, height: 0)
        tv.typingAttributes = [.font: convoFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: MD.bodyStyle()]
        return tv
    }

    // 底部输入栏:顶部分隔线 + 原生圆角输入框(回车发送)+「复制」
    private func makeInputBar(width w: CGFloat) -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: w, height: inputBarH))
        bar.autoresizingMask = [.width, .maxYMargin]    // 固定在底部

        let line = NSView(frame: NSRect(x: 0, y: inputBarH - 1, width: w, height: 1))
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        line.autoresizingMask = [.width, .minYMargin]
        bar.addSubview(line)

        let cbW: CGFloat = 54, fieldH: CGFloat = 24
        let fieldW = w - convoPad * 2 - cbW - 8
        let field = NSTextField(frame: NSRect(x: convoPad, y: (inputBarH - fieldH) / 2 - 0.5, width: fieldW, height: fieldH))
        field.bezelStyle = .roundedBezel
        field.placeholderString = "正在生成…"
        field.isEnabled = false
        field.font = NSFont.systemFont(ofSize: 13)
        field.focusRingType = .none
        field.target = self
        field.action = #selector(onAskSubmit)
        field.autoresizingMask = [.width]
        (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false   // 仅回车发送,失焦不触发
        bar.addSubview(field)
        askField = field

        let cb = HoverButton(frame: NSRect(x: w - convoPad - cbW, y: (inputBarH - 24) / 2, width: cbW, height: 24))
        cb.labelText = "复制"
        cb.target = self
        cb.action = #selector(onCopyClicked)
        cb.autoresizingMask = [.minXMargin]
        bar.addSubview(cb)
        copyButton = cb
        return bar
    }

    // 用当前 convo 发起一轮流式;在 transcript 末尾接续 assistant 段
    private func sendTurn() {
        assistantStart = convoTextView?.textStorage?.length ?? 0
        assistantAccum = ""
        setInputEnabled(false, placeholder: "正在生成…")
        let gen = generation   // 令牌:关窗/换会话(generation+1)后,旧流式回调一律作废,防止污染新会话
        var messages: [[String: Any]] = [["role": "system", "content": kExplainSystem]]
        for (i, m) in convo.enumerated() {
            if i == 0, m.role == "user", let dataURL = attachedImageDataURL {
                // 截图解释:首条 user = 指令文字 + 图片块(每轮重发,确保追问仍带图上下文)
                let content: [[String: Any]] = [
                    ["type": "text", "text": m.content],
                    ["type": "image_url", "image_url": ["url": dataURL]]
                ]
                messages.append(["role": "user", "content": content])
            } else {
                messages.append(["role": m.role, "content": m.content])
            }
        }
        convoTask = chatStream(messages,
            onDelta: { [weak self] piece in guard let self = self, gen == self.generation else { return }; self.convoAppendDelta(piece) },
            onDone:  { [weak self] full  in guard let self = self, gen == self.generation else { return }; self.finishTurn(full) },
            onError: { [weak self] msg   in guard let self = self, gen == self.generation else { return }; self.convoError(msg) })
    }

    // 逐字追加(流式途中纯文本,避免半截 markdown 错乱);长高交给定时器节流
    private func convoAppendDelta(_ delta: String) {
        guard let tv = convoTextView, panel != nil else { return }
        assistantAccum += delta
        tv.textStorage?.append(NSAttributedString(string: delta, attributes: [
            .font: convoFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: MD.bodyStyle()]))
        scrollTranscriptToBottom()
    }

    // 一轮完成:把刚流式的纯文本段替换为 markdown 重渲染,记入上下文,开放追问输入
    private func finishTurn(_ full: String) {
        convoTimer?.invalidate(); convoTimer = nil
        convoTask = nil
        guard convoTextView != nil else { return }   // 会话已被关闭:忽略迟到的完成回调
        let text = full.trimmingCharacters(in: .whitespacesAndNewlines)
        convo.append((role: "assistant", content: text))
        lastResult = text
        if let tv = convoTextView, let storage = tv.textStorage {
            let len = max(0, storage.length - assistantStart)
            let rendered = MD.render(text, width: convoW - convoPad * 2, baseFont: convoFont, textColor: .labelColor)
            storage.replaceCharacters(in: NSRange(location: assistantStart, length: len), with: rendered)
        }
        setInputEnabled(true, placeholder: "继续追问…(回车发送)")
        focusAskField()
        growConversation(force: true)
        scrollTranscript(toLocation: turnStartLoc)   // 一轮完成后回到本轮开头(从头读)

        if uiTestMode {
            let asst = convo.filter { $0.role == "assistant" }.count
            if asst == 1 {
                // 程序化发一条追问,验证输入框提交 → 上下文延续 → 第二轮
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self = self, let f = self.askField, f.isEnabled else { return }
                    f.stringValue = "为什么带参数的装饰器要写成三层嵌套函数?简短说。"
                    self.onAskSubmit()
                }
            } else {
                uiTestMode = false
                let users = convo.filter { $0.role == "user" }.count
                logLine("UITEST multiturn: users=\(users) assistants=\(asst)")   // 应 users=2 assistants=2(上下文已延续)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.capturePanel(to: "\(NSHomeDirectory())/popdict_multiturn.png")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
                }
            }
        }
    }

    private func convoError(_ msg: String) {
        convoTimer?.invalidate(); convoTimer = nil
        convoTask = nil
        guard convoTextView != nil else { return }   // 会话已被关闭:忽略迟到的错误回调
        let hasAssistant = convo.contains { $0.role == "assistant" }
        // 首轮失败(无论流式是否已吐出半截)→ 回退普通错误浮窗,保留原文上下文不破坏
        if !hasAssistant {
            stopConversation()
            showMessage(msg, isError: true)
            return
        }
        // 追问失败:撤掉这轮 user 上下文 + transcript 里本轮气泡和半截回答(整轮回滚),附红字提示,允许重试
        if convo.count > 1, convo.last?.role == "user" { convo.removeLast() }
        if let tv = convoTextView, let storage = tv.textStorage {
            let len = max(0, storage.length - turnStartLoc)
            if len > 0 { storage.deleteCharacters(in: NSRange(location: turnStartLoc, length: len)) }
            storage.append(NSAttributedString(string: "\n⚠️ \(msg)\n", attributes: [
                .font: convoFont, .foregroundColor: NSColor.systemRed, .paragraphStyle: MD.bodyStyle()]))
        }
        setInputEnabled(true, placeholder: "继续追问…(回车发送)")
        focusAskField()
        growConversation(force: true)
        scrollTranscriptToBottom()
    }

    // 回车发送追问
    @objc private func onAskSubmit() {
        guard let field = askField, field.isEnabled, let tv = convoTextView else { return }
        let q = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if uiTestMode { logLine("onAskSubmit FIRED q=\(q)") }
        field.stringValue = ""
        turnStartLoc = tv.textStorage?.length ?? 0   // 本轮起点(含追问气泡),失败整轮回滚
        appendUserBubble(q, to: tv)
        convo.append((role: "user", content: q))
        startConvoTimer()
        sendTurn()
    }

    // transcript 里追加一条「你的追问」气泡:与上一轮明显拉开 + accent 标签 + 浅 accent 圆角底,
    // 让用户追问和 AI 回答一眼能分清、轮次之间界限清晰。
    private func appendUserBubble(_ q: String, to tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let m = NSMutableAttributedString()
        // MD.render 去掉了 AI 回答尾部换行,先补一个换行,避免「你的追问」挤到上一行末尾
        m.append(NSAttributedString(string: "\n", attributes: [.font: convoFont, .paragraphStyle: MD.bodyStyle()]))
        let pLabel = NSMutableParagraphStyle()
        pLabel.firstLineHeadIndent = 12; pLabel.headIndent = 12; pLabel.tailIndent = -12
        pLabel.lineSpacing = 3
        pLabel.paragraphSpacingBefore = 24   // 与上一轮 AI 回答明显拉开(轮次分隔)
        pLabel.paragraphSpacing = 3
        m.append(NSAttributedString(string: "你的追问\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.controlAccentColor,
            .paragraphStyle: pLabel, MD.userMsgKey: true]))
        let pBody = NSMutableParagraphStyle()
        pBody.firstLineHeadIndent = 12; pBody.headIndent = 12; pBody.tailIndent = -12
        pBody.lineSpacing = 3
        pBody.paragraphSpacing = 22          // 问题与下面 AI 回答拉开
        m.append(NSAttributedString(string: q + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: pBody, MD.userMsgKey: true]))
        storage.append(m)
    }

    private func setInputEnabled(_ enabled: Bool, placeholder: String) {
        askField?.isEnabled = enabled
        askField?.placeholderString = placeholder
    }

    // 仅在用户已停留在本浮窗(已是 key window)时才自动聚焦输入框;
    // 否则不抢键盘焦点,避免打断用户在原 App 里的输入(点击输入框本身即可获得焦点)。
    private func focusAskField() {
        guard let p = panel, p.isKeyWindow, let field = askField else { return }
        p.makeFirstResponder(field)
    }

    private func startConvoTimer() {
        convoTimer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.growConversation(force: false) }
        RunLoop.main.add(t, forMode: .common)
        convoTimer = t
    }

    // 按真实内容高度平滑长高:顶边跟随当前窗口位置(拖到哪长到哪,不抢回原位),
    // 高度被"当前顶边到屏底的可用空间"限制 → 顶边稳定不抖、贴底自动转内部滚动。底部输入栏高度始终预留。
    private func growConversation(force: Bool) {
        guard let p = panel, let tv = convoTextView,
              let tc = tv.textContainer, let lm = tv.layoutManager else { return }
        lm.ensureLayout(for: tc)
        let contentH = max(22, ceil(lm.usedRect(for: tc).height))
        let cur = p.frame
        let vf = screenFor(cur).visibleFrame
        let top = cur.maxY                                  // 当前顶边(用户拖动后跟随)
        let availBelow = top - vf.minY - 6                  // 顶边到屏底可用空间
        let cap = min(availBelow, vf.height * 0.82)        // 用到屏幕 82% 高度,长解释也尽量一屏显示更多
        let maxContentH = max(60, cap - convoPad - inputBarH - transcriptBottomGap)
        let visibleH = min(contentH, maxContentH)
        let panelH = convoPad + visibleH + transcriptBottomGap + inputBarH
        if !force && abs(panelH - cur.height) < 1 { return }
        if uiTestMode { logLine("GROW h=\(Int(panelH)) content=\(Int(contentH)) force=\(force)") }
        var rect = NSRect(x: cur.origin.x, y: top - panelH, width: convoW, height: panelH)
        // 垂直方向已被 availBelow 限制不会越界(顶边稳定);仅水平兜底
        if rect.maxX > vf.maxX { rect.origin.x = vf.maxX - rect.width - 6 }
        if rect.minX < vf.minX { rect.origin.x = vf.minX + 6 }
        if force {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                p.animator().setFrame(rect, display: true)
            })
        } else {
            p.setFrame(rect, display: true)   // 流式增长:50ms 节流本身够平滑,非动画避免每帧动画相互打断
        }
        scrollTranscriptToBottom()
    }

    private func screenFor(_ rect: NSRect) -> NSScreen {
        NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) })
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func scrollTranscriptToBottom() {
        guard let tv = convoTextView else { return }
        tv.scrollRangeToVisible(NSRange(location: tv.textStorage?.length ?? 0, length: 0))
    }

    // 把某字符位置滚到可视区顶部(一轮结束后从本轮开头开始读)
    private func scrollTranscript(toLocation loc: Int) {
        guard let tv = convoTextView, let lm = tv.layoutManager, let tc = tv.textContainer,
              let scroll = convoScroll, let storage = tv.textStorage else { return }
        let safe = min(max(0, loc), storage.length)
        let gr = lm.glyphRange(forCharacterRange: NSRange(location: safe, length: 0), actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: gr, in: tc)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY - 2)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // 彻底结束会话:取消网络、停定时器、清状态(失焦关闭 / 新划词 / 新会话时)
    private func stopConversation() {
        convoTask?.cancel(); convoTask = nil
        convoTimer?.invalidate(); convoTimer = nil
        convoTextView = nil
        convoScroll = nil
        askField = nil
        convo = []
        attachedImageDataURL = nil
        assistantStart = 0
        assistantAccum = ""
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

        // 译文按 markdown 渲染;其它(翻译中/错误)纯文本
        let attr = markdown
            ? MD.render(message, width: textW, baseFont: font, textColor: textColor)
            : NSAttributedString(string: message, attributes: [.font: font, .foregroundColor: textColor])

        // 测真实高度,超过上限就用滚动条(应对超长译文 + 换行)
        let contentH = max(20, measuredTextHeight(attr, width: textW))
        let screenH = screenFor(NSRect(x: origin.x, y: origin.y, width: w, height: 1)).visibleFrame.height
        let maxContentH = min(440, screenH - 140)
        let visibleH = min(contentH, maxContentH)
        let panelH = pad + visibleH + bottomInset

        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: panelH))
        let scroll = NSScrollView(frame: NSRect(x: pad, y: bottomInset, width: textW, height: visibleH))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = contentH > maxContentH
        scroll.autohidesScrollers = true

        let tv = makeRenderingTextView(width: textW)
        tv.textColor = textColor
        tv.minSize = NSSize(width: textW, height: visibleH)
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
        p.becomesKeyOnlyIfNeeded = true        // 输入框点击才取焦点;翻译/解释浮窗不抢焦点
        p.isMovableByWindowBackground = true   // 拖背景空白处即可移动窗口
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.animationBehavior = .none

        // 毛玻璃背板:.menu 材质 + behindWindow 实时模糊;圆角靠父 layer 裁切,阴影交给系统
        let blur = DraggableBlurView(frame: NSRect(origin: .zero, size: rect.size))
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

    // 把浮窗(及随后展开的会话,按 convoW 宽度预留)定位到选区右侧、顶边对齐选区上沿;
    // 右侧放不下则放左侧;都放不下则夹紧到屏内。取不到选区坐标时回退到鼠标位置。
    private func buttonRect(w: CGFloat, h: CGFloat, selectionBounds: CGRect?, fallbackPoint: NSPoint) -> NSRect {
        guard let sel = selectionBounds else {
            // 无选区坐标:放到鼠标右侧、与鼠标大致同高(右侧弹出的近似,而非下方)
            let vf = screenFor(NSRect(x: fallbackPoint.x, y: fallbackPoint.y, width: 1, height: 1)).visibleFrame
            var x = fallbackPoint.x + 14
            if x + convoW > vf.maxX - 6 { x = max(vf.minX + 6, fallbackPoint.x - 14 - convoW) }
            if x < vf.minX + 6 { x = vf.minX + 6 }
            var y = fallbackPoint.y - h
            if y + h > vf.maxY - 6 { y = vf.maxY - 6 - h }
            if y < vf.minY + 6 { y = vf.minY + 6 }
            return NSRect(x: x, y: y, width: w, height: h)
        }
        // sel:Quartz 屏幕坐标(左上原点)→ AppKit(左下原点,以主屏高度翻转)
        let primaryH = primaryScreenHeight()
        let selAK = CGRect(x: sel.minX, y: primaryH - sel.maxY, width: sel.width, height: sel.height)
        let selTop = selAK.maxY          // 选区上沿(AppKit)
        let gap: CGFloat = 12
        let vf = screenFor(selAK).visibleFrame
        // 水平:按会话宽度 convoW 判断能否放右侧
        var x = selAK.maxX + gap
        if x + convoW > vf.maxX - 6 {
            let leftX = selAK.minX - gap - convoW
            x = leftX >= vf.minX + 6 ? leftX : max(vf.minX + 6, vf.maxX - convoW - 6)
        }
        if x < vf.minX + 6 { x = vf.minX + 6 }
        // 垂直:浮窗顶边对齐选区上沿(会话向下生长);夹紧到屏内
        var y = selTop - h
        if y + h > vf.maxY - 6 { y = vf.maxY - 6 - h }
        if y < vf.minY + 6 { y = vf.minY + 6 }
        return NSRect(x: x, y: y, width: w, height: h)
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
var gFetchInFlight = false         // 取词互斥(仅在主线程读写):同一时刻只跑一个,避免剪贴板并发竞态

func handleMouseUpAt(dist: CGFloat) {
    logLine("tap mouseUp dist=\(String(format: "%.1f", dist))")
    if dist < kDragThreshold { return }
    if gFetchInFlight { logLine("  skip: fetch in flight"); return }   // 上一次取词还没完,丢弃这次
    gFetchInFlight = true
    // 取词放后台线程,避免 usleep 阻塞主 runloop 导致 tap 超时被禁用
    DispatchQueue.global(qos: .userInitiated).async {
        usleep(50_000)
        let axResult = selectedTextAndBoundsViaAX()
        logLine("  AX=\(axResult?.text ?? "nil") bounds=\(axResult?.bounds.map { "\(Int($0.maxX)),\(Int($0.minY))" } ?? "nil")")
        let text = axResult?.text ?? selectedTextViaCopy()
        logLine("  final=\(text ?? "nil")")
        let bounds = axResult?.bounds
        DispatchQueue.main.async {
            gFetchInFlight = false
            guard let text = text else { return }
            gAppDelegate?.popup.showButton(text: text, selectionBounds: bounds, fallbackPoint: NSEvent.mouseLocation)
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
                } else if ad.popup.isComposingText {
                    gDownInsidePopup = true        // 输入法候选窗在浮窗外:点候选词不关、不当作新划词
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

// MARK: - 全局热键(Carbon)

// 注册一个系统级热键(默认 ⌃⌥E),按下时在主线程触发回调(截图解释)。
// 用 Carbon RegisterEventHotKey:系统级、稳定、能消费按键、无需额外权限。
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handlerInstalled = false
    private static var actions: [UInt32: () -> Void] = [:]   // C 回调不能捕获上下文,按 id 查表

    @discardableResult
    init?(keyCode: UInt32, modifiers: UInt32, id: UInt32, action: @escaping () -> Void) {
        HotKey.actions[id] = action
        if !HotKey.handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
                var hkID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                HotKey.actions[hkID.id]?()
                return noErr
            }, 1, &spec, nil, nil)
            HotKey.handlerInstalled = true
        }
        let hkID = EventHotKeyID(signature: OSType(0x504f5044), id: id)   // 'POPD'
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { logLine("HOTKEY register failed status=\(status)"); return nil }
        logLine("HOTKEY registered id=\(id) keyCode=\(keyCode)")
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    let popup = PopupController()
    var statusItem: NSStatusItem?
    var hotKey: HotKey?
    var activeCapture: RegionCapture?      // 截图期间强持有 RegionCapture,避免遮罩提前释放

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureConfigDir()
        logLine("=== launch AX_TRUSTED=\(AXIsProcessTrusted()) configDir=\(FileManager.default.fileExists(atPath: kConfigDir)) ===")
        gAppDelegate = self
        setupMainMenu()

        // UI 截图自测:启动即演示一次解释浮窗(不建事件 tap / 不请求权限),便于截屏验证真实渲染
        if ProcessInfo.processInfo.environment["POPDICT_UITEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.popup.runDemoExplain() }
            return
        }

        setupStatusItem()

        // 全局热键 ⌃⌥E 触发截图解释(与划词监听互不依赖)
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_E),
                        modifiers: UInt32(controlKey | optionKey),
                        id: 1) { [weak self] in
            DispatchQueue.main.async { self?.onScreenshotExplain() }
        }

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
        menu.addItem(NSMenuItem(title: "popdict 划词翻译 / 截图解释", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let axOK = AXIsProcessTrusted()
        menu.addItem(NSMenuItem(title: axOK ? "✓ 辅助功能:已授权" : "⚠️ 辅助功能:未授权(点下面去开)",
                                action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: readAPIKey() == nil ? "⚠️ 未填 API Key" : "✓ 已配置 API Key",
                                action: nil, keyEquivalent: ""))
        let scrOK = RegionCapture.hasScreenRecordingPermission()
        menu.addItem(NSMenuItem(title: scrOK ? "✓ 屏幕录制:已授权" : "⚠️ 屏幕录制:未授权(截图解释需要)",
                                action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "📷 截图解释  ⌃⌥E", action: #selector(onScreenshotExplain), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "辅助功能权限设置…", action: #selector(openAXSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "屏幕录制权限设置…", action: #selector(openScreenRecordingSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重新检查权限", action: #selector(recheck), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        return menu
    }

    // accessory App 不显示菜单栏,但有了 mainMenu 后 ⌘C/⌘V/⌘X/⌘A/撤销 的 key equivalent 才能在追问框生效
    func setupMainMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        editItem.submenu = edit
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(NSMenuItem.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = mainMenu
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

    // 截图解释:无屏幕录制权限先引导,否则弹框选遮罩,截完交给图片会话浮窗
    @objc func onScreenshotExplain() {
        if !RegionCapture.hasScreenRecordingPermission() {
            let granted = RegionCapture.requestScreenRecordingPermission()
            let a = NSAlert()
            NSApp.activate(ignoringOtherApps: true)
            if granted {
                // 用户刚在系统弹窗里授权:本进程通常要重开 App 才真正生效
                a.messageText = "屏幕录制权限已授予"
                a.informativeText = "权限已开启。首次授予后通常需要重新打开 popdict 才会真正生效,然后再用 ⌃⌥E 截图解释。"
                a.addButton(withTitle: "好的")
                a.runModal()
            } else {
                // 之前已被拒绝(系统不再弹窗)或刚拒绝:引导去设置手动打开
                a.messageText = "需要「屏幕录制」权限"
                a.informativeText = "截图解释要用到屏幕录制权限。请在 系统设置 → 隐私与安全性 → 屏幕录制 里打开 popdict。\n\n注意:首次授予后通常需要重新打开 popdict 才会生效。"
                a.addButton(withTitle: "打开设置")
                a.addButton(withTitle: "取消")
                if a.runModal() == .alertFirstButtonReturn { openScreenRecordingSettings() }
            }
            refreshMenu()
            return
        }
        let rc = RegionCapture()
        activeCapture = rc
        rc.capture { [weak self] image in
            self?.activeCapture = nil
            guard let self = self, let image = image else { return }
            self.popup.beginImageConversation(image: image)
        }
    }

    @objc func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
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
