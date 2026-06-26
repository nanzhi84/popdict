import AppKit

// ============================================================
// 设置窗口:管理一组 OpenAI 兼容厂商(增删 / 自定义 / 当前使用),保存到 config.json。
// ============================================================

private func fixedField(_ w: CGFloat, secure: Bool = false) -> NSTextField {
    let f: NSTextField = secure ? NSSecureTextField() : NSTextField()
    f.font = .systemFont(ofSize: 12)
    f.translatesAutoresizingMaskIntoConstraints = false
    f.widthAnchor.constraint(equalToConstant: w).isActive = true
    return f
}

private func rowLabel(_ s: String) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = .systemFont(ofSize: 11); l.alignment = .right
    l.translatesAutoresizingMaskIntoConstraints = false
    l.widthAnchor.constraint(equalToConstant: 64).isActive = true
    return l
}

private func labeledRow(_ label: String, _ field: NSView) -> NSStackView {
    let r = NSStackView(views: [rowLabel(label), field])
    r.orientation = .horizontal; r.spacing = 8; r.alignment = .centerY
    return r
}

// 一张厂商卡片(可编辑)
final class ProviderCardView: NSView {
    let nameField = fixedField(220)
    let baseField = fixedField(360)
    let keyField = fixedField(360, secure: true)
    let modelField = fixedField(220)
    let visionCheck = NSButton(checkboxWithTitle: "支持看图", target: nil, action: nil)
    let activeRadio = NSButton(radioButtonWithTitle: "当前使用", target: nil, action: nil)
    let deleteButton = NSButton(title: "删除", target: nil, action: nil)
    var onActivate: (() -> Void)?
    var onDelete: (() -> Void)?

    init(provider: Provider) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.5, alpha: 0.08).cgColor
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false

        nameField.stringValue = provider.name
        baseField.stringValue = provider.baseURL
        keyField.stringValue = provider.apiKey
        modelField.stringValue = provider.model
        baseField.placeholderString = "https://…/v1"
        modelField.placeholderString = "model 名"
        visionCheck.state = provider.vision ? .on : .off

        activeRadio.target = self; activeRadio.action = #selector(activate)
        deleteButton.target = self; deleteButton.action = #selector(del)
        deleteButton.bezelStyle = .rounded; deleteButton.controlSize = .small

        let spacer = NSView(); spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: 250).isActive = true
        let top = NSStackView(views: [activeRadio, spacer, deleteButton])
        top.orientation = .horizontal; top.spacing = 8; top.alignment = .centerY

        let stack = NSStackView(views: [top,
                                        labeledRow("名字", nameField),
                                        labeledRow("Base URL", baseField),
                                        labeledRow("API Key", keyField),
                                        labeledRow("模型", modelField),
                                        labeledRow("", visionCheck)])
        stack.orientation = .vertical; stack.spacing = 6; stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func activate() { onActivate?() }
    @objc private func del() { onDelete?() }

    func setActive(_ on: Bool) { activeRadio.state = on ? .on : .off }
    var isActive: Bool { activeRadio.state == .on }
    func toProvider() -> Provider {
        Provider(name: nameField.stringValue.trimmingCharacters(in: .whitespaces),
                 baseURL: baseField.stringValue.trimmingCharacters(in: .whitespaces),
                 apiKey: keyField.stringValue.trimmingCharacters(in: .whitespaces),
                 model: modelField.stringValue.trimmingCharacters(in: .whitespaces),
                 vision: visionCheck.state == .on)
    }
}

final class SettingsController: NSObject {
    private var window: NSWindow?
    private let cardsStack = NSStackView()
    private var cards: [ProviderCardView] = []

    func show() {
        if window == nil { build() }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }

    private func build() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 500),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "popdict 设置"
        win.isReleasedWhenClosed = false

        let intro = NSTextField(labelWithString: "管理 OpenAI 兼容厂商。选一个为「当前使用」;截图解释需勾「支持看图」。")
        intro.font = .systemFont(ofSize: 11); intro.textColor = .secondaryLabelColor

        cardsStack.orientation = .vertical; cardsStack.spacing = 10; cardsStack.alignment = .leading
        cardsStack.translatesAutoresizingMaskIntoConstraints = false
        let clip = NSView(); clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(cardsStack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.documentView = clip
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let addBtn = NSButton(title: "+ 添加厂商", target: self, action: #selector(addProvider)); addBtn.bezelStyle = .rounded
        let saveBtn = NSButton(title: "保存", target: self, action: #selector(save)); saveBtn.bezelStyle = .rounded; saveBtn.keyEquivalent = "\r"
        let closeBtn = NSButton(title: "关闭", target: self, action: #selector(closeWin)); closeBtn.bezelStyle = .rounded
        let bspacer = NSView(); bspacer.translatesAutoresizingMaskIntoConstraints = false
        let bottom = NSStackView(views: [addBtn, bspacer, closeBtn, saveBtn]); bottom.orientation = .horizontal; bottom.spacing = 8

        let root = NSStackView(views: [intro, scroll, bottom]); root.orientation = .vertical; root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        let cv = NSView(); cv.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: cv.topAnchor),
            root.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            cardsStack.topAnchor.constraint(equalTo: clip.topAnchor),
            cardsStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            cardsStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            cardsStack.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            clip.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -2),
        ])
        win.contentView = cv
        window = win
    }

    private func reload() {
        cards.forEach { $0.removeFromSuperview() }
        cards = []
        for p in AppConfig.shared.providers {
            let card = makeCard(p, active: p.name == AppConfig.shared.activeName)
            cards.append(card); cardsStack.addArrangedSubview(card)
        }
        if cards.first(where: { $0.isActive }) == nil { cards.first?.setActive(true) }
        updateDeleteEnabled()
    }

    private func makeCard(_ p: Provider, active: Bool) -> ProviderCardView {
        let card = ProviderCardView(provider: p)
        card.setActive(active)
        card.onActivate = { [weak self, weak card] in self?.cards.forEach { $0.setActive($0 === card) } }
        card.onDelete = { [weak self, weak card] in
            guard let self = self, let card = card, self.cards.count > 1 else { return }
            let wasActive = card.isActive
            card.removeFromSuperview()
            self.cards.removeAll { $0 === card }
            if wasActive { self.cards.first?.setActive(true) }
            self.updateDeleteEnabled()
        }
        return card
    }

    private func updateDeleteEnabled() { cards.forEach { $0.deleteButton.isEnabled = cards.count > 1 } }

    @objc private func addProvider() {
        let card = makeCard(Provider(name: "新厂商", baseURL: "https://", apiKey: "", model: "", vision: false), active: false)
        cards.append(card)
        cardsStack.addArrangedSubview(card)
        updateDeleteEnabled()
    }

    @objc private func save() {
        let ps = cards.map { $0.toProvider() }
        if ps.contains(where: { $0.name.isEmpty }) { alert("每个厂商都要有名字"); return }
        if Set(ps.map { $0.name }).count != ps.count { alert("厂商名字不能重复"); return }
        let activeName = cards.first(where: { $0.isActive })?.toProvider().name ?? ps.first!.name
        AppConfig.shared.setProviders(ps, active: activeName)
        gAppDelegate?.refreshMenu()
        window?.close()
    }

    private func alert(_ msg: String) {
        let a = NSAlert(); a.messageText = msg; a.addButton(withTitle: "好的"); a.runModal()
    }

    @objc private func closeWin() { window?.close() }
}
