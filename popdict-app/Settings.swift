import AppKit

// ============================================================
// 设置窗口:顶部下拉选择厂商(含「+ 新增厂商…」),下面是该厂商的设置表单。
// 「设为当前使用」单独一个按钮;下拉里当前生效的厂商前缀「●」。保存写入 config.json。
// ============================================================

final class SettingsController: NSObject {
    private var window: NSWindow?
    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nameField = NSTextField()
    private let baseField = NSTextField()
    private let keyField = NSSecureTextField()
    private let modelField = NSTextField()
    private let visionCheck = NSButton(checkboxWithTitle: "支持看图(截图解释需要)", target: nil, action: nil)
    private let activeButton = NSButton(title: "设为当前使用", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除此厂商", target: nil, action: nil)

    private var working: [Provider] = []
    private var activeIndex = 0
    private var selected = 0
    private let newItemTag = 9999

    func show() {
        if window == nil { build() }
        working = AppConfig.shared.providers
        if working.isEmpty { working = AppConfig.presets() }
        activeIndex = working.firstIndex { $0.name == AppConfig.shared.activeName } ?? 0
        selected = activeIndex
        rebuildPopup()
        loadForm()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }

    private func build() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 380),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "popdict 设置"
        win.isReleasedWhenClosed = false

        providerPopup.target = self; providerPopup.action = #selector(popupChanged)
        providerPopup.translatesAutoresizingMaskIntoConstraints = false
        providerPopup.widthAnchor.constraint(equalToConstant: 190).isActive = true
        activeButton.target = self; activeButton.action = #selector(setActive); activeButton.bezelStyle = .rounded
        deleteButton.target = self; deleteButton.action = #selector(deleteCurrent); deleteButton.bezelStyle = .rounded; deleteButton.controlSize = .small

        let topRow = NSStackView(views: [plainLabel("厂商"), providerPopup, activeButton])
        topRow.orientation = .horizontal; topRow.spacing = 10; topRow.alignment = .centerY

        for f in [nameField, baseField, keyField, modelField] {
            f.font = .systemFont(ofSize: 12); f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 320).isActive = true
        }
        baseField.placeholderString = "https://…/v1"
        modelField.placeholderString = "model 名"

        let form = NSStackView(views: [
            fieldRow("名字", nameField), fieldRow("Base URL", baseField),
            fieldRow("API Key", keyField), fieldRow("模型", modelField), indentRow(visionCheck),
        ])
        form.orientation = .vertical; form.spacing = 8; form.alignment = .leading

        let deleteRow = NSStackView(views: [hSpacer(), deleteButton]); deleteRow.orientation = .horizontal

        let sep = NSBox(); sep.boxType = .separator; sep.translatesAutoresizingMaskIntoConstraints = false
        let saveBtn = NSButton(title: "保存", target: self, action: #selector(save)); saveBtn.bezelStyle = .rounded; saveBtn.keyEquivalent = "\r"
        let closeBtn = NSButton(title: "关闭", target: self, action: #selector(closeWin)); closeBtn.bezelStyle = .rounded
        let bottom = NSStackView(views: [hSpacer(), closeBtn, saveBtn]); bottom.orientation = .horizontal; bottom.spacing = 8

        let vGap = NSView(); vGap.translatesAutoresizingMaskIntoConstraints = false
        vGap.setContentHuggingPriority(.defaultLow, for: .vertical)

        let root = NSStackView(views: [topRow, form, deleteRow, vGap, sep, bottom])
        root.orientation = .vertical; root.spacing = 14; root.alignment = .leading
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        let cv = NSView(); cv.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: cv.topAnchor),
            root.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            sep.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            bottom.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
        ])
        win.contentView = cv
        window = win
    }

    // MARK: helpers
    private func plainLabel(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.font = .systemFont(ofSize: 12); return l }
    private func hSpacer() -> NSView { let v = NSView(); v.setContentHuggingPriority(.defaultLow, for: .horizontal); v.translatesAutoresizingMaskIntoConstraints = false; return v }
    private func fieldRow(_ t: String, _ field: NSView) -> NSStackView {
        let l = NSTextField(labelWithString: t); l.font = .systemFont(ofSize: 11); l.alignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false; l.widthAnchor.constraint(equalToConstant: 66).isActive = true
        let r = NSStackView(views: [l, field]); r.orientation = .horizontal; r.spacing = 8; r.alignment = .centerY; return r
    }
    private func indentRow(_ v: NSView) -> NSStackView {
        let pad = NSView(); pad.translatesAutoresizingMaskIntoConstraints = false; pad.widthAnchor.constraint(equalToConstant: 74).isActive = true
        let r = NSStackView(views: [pad, v]); r.orientation = .horizontal; r.spacing = 0; r.alignment = .centerY; return r
    }

    private func rebuildPopup() {
        let menu = NSMenu()
        for (i, p) in working.enumerated() {
            let title = (i == activeIndex ? "● " : "") + (p.name.isEmpty ? "(未命名)" : p.name)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.tag = i
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let add = NSMenuItem(title: "+ 新增厂商…", action: nil, keyEquivalent: ""); add.tag = newItemTag
        menu.addItem(add)
        providerPopup.menu = menu
        providerPopup.selectItem(at: max(0, min(selected, working.count - 1)))
    }

    private func loadForm() {
        guard selected >= 0, selected < working.count else { return }
        let p = working[selected]
        nameField.stringValue = p.name
        baseField.stringValue = p.baseURL
        keyField.stringValue = p.apiKey
        modelField.stringValue = p.model
        visionCheck.state = p.vision ? .on : .off
        deleteButton.isEnabled = working.count > 1
        updateActiveButton()
    }

    private func flushForm() {
        guard selected >= 0, selected < working.count else { return }
        working[selected] = Provider(
            name: nameField.stringValue.trimmingCharacters(in: .whitespaces),
            baseURL: baseField.stringValue.trimmingCharacters(in: .whitespaces),
            apiKey: keyField.stringValue.trimmingCharacters(in: .whitespaces),
            model: modelField.stringValue.trimmingCharacters(in: .whitespaces),
            vision: visionCheck.state == .on)
    }

    private func updateActiveButton() {
        if selected == activeIndex { activeButton.title = "✓ 当前使用中"; activeButton.isEnabled = false }
        else { activeButton.title = "设为当前使用"; activeButton.isEnabled = true }
    }

    @objc private func popupChanged() {
        let tag = providerPopup.selectedItem?.tag ?? 0
        flushForm()
        if tag == newItemTag {
            working.append(Provider(name: "新厂商", baseURL: "https://", apiKey: "", model: "", vision: false))
            selected = working.count - 1
        } else {
            selected = tag
        }
        rebuildPopup()   // 名字可能被改过,刷新下拉文字与 ● 标记
        loadForm()
    }

    @objc private func setActive() {
        flushForm()
        activeIndex = selected
        rebuildPopup()
        updateActiveButton()
    }

    @objc private func deleteCurrent() {
        guard working.count > 1 else { return }
        flushForm()
        working.remove(at: selected)
        if activeIndex == selected { activeIndex = 0 }
        else if activeIndex > selected { activeIndex -= 1 }
        selected = min(selected, working.count - 1)
        rebuildPopup()
        loadForm()
    }

    @objc private func save() {
        flushForm()
        if working.contains(where: { $0.name.isEmpty }) { alert("每个厂商都要有名字"); return }
        if Set(working.map { $0.name }).count != working.count { alert("厂商名字不能重复"); return }
        let activeName = working[max(0, min(activeIndex, working.count - 1))].name
        if !AppConfig.shared.setProviders(working, active: activeName) {
            alert("保存失败:无法写入配置文件(~/.config/popdict)。请检查磁盘空间或目录权限。"); return
        }
        gAppDelegate?.refreshMenu()
        window?.close()
    }

    private func alert(_ msg: String) { let a = NSAlert(); a.messageText = msg; a.addButton(withTitle: "好的"); a.runModal() }
    @objc private func closeWin() { window?.close() }
}
