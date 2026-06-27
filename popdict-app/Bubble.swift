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
        let tc = NSTextContainer(size: NSSize(width: 10, height: CGFloat.greatestFiniteMagnitude))
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
