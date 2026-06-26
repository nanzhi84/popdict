# 厂商设置 GUI + 可缩放记忆浮窗 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 popdict 加(#3)一个可自管理 OpenAI 兼容厂商列表的设置 GUI(后端按「当前厂商」走),与(#1)出结果浮窗的自由缩放 + 记住固定尺寸。

**Architecture:** 新增 `Config.swift`(Provider + AppConfig 单例,config.json 读写/预置/迁移)与 `Settings.swift`(厂商卡片增删的设置窗口);`main.swift` 后端改读当前厂商、加看图门禁与「设置…」菜单;`PopupController` 给结果浮窗加 `.resizable` + 右下角拖拽握把 + UserDefaults 记忆尺寸,并移除原自动长高改为内容滚动。

**Tech Stack:** Swift 5、AppKit、Foundation(Codable)、swiftc 直接编译(无 Xcode、无单元测试框架)。

## Global Constraints

- 只改 `popdict-app/`(`main.swift`、新增 `Config.swift`、`Settings.swift`、`build.sh`)与 `README.md`;不动 PopClip / `popdict.lua`。
- `MIN_OS=12.0`,universal(arm64+x86_64)。
- 配置文件 `~/.config/popdict/config.json`;预置 `DeepSeek`(`https://api.deepseek.com/v1`,`deepseek-chat`,vision=false)与 `MiMo`(`https://api.xiaomimimo.com/v1`,`mimo-v2.5`,vision=true)。
- 请求体始终发 `thinking:{type:disabled}` 与 `max_completion_tokens`(未知字段 OpenAI 兼容服务普遍忽略)。
- 浮窗最小尺寸约 300×180,默认 460×380;记忆尺寸存 `UserDefaults` 键 `popupSize`。
- 测试循环 = `bash build.sh` 编译无新警告 + Config 离线脚本验证 + 手动冒烟。
- 提交信息结尾附 `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` 与 `Claude-Session: …`。

---

### Task 1: 配置模型 `Config.swift`

**Files:**
- Create: `popdict-app/Config.swift`
- Modify: `popdict-app/build.sh`(SRCS 加 `Config.swift`)

**Interfaces:**
- Produces:`struct Provider: Codable { name, baseURL, apiKey, model: String; vision: Bool }`;`final class AppConfig`(`shared`、`providers: [Provider]`、`activeName: String`、`active: Provider?`、`load()`、`save()`、`setProviders(_:active:)`、静态 `presets()`)。
- Consumes:`kConfigDir`、`kKeyPath`、`logLine`(main.swift 全局)。

- [ ] **Step 1: 写 `Config.swift`**

```swift
import Foundation

// 一个 OpenAI 兼容厂商。name 用户自定义、作唯一标识;baseURL 含 /v1。
struct Provider: Codable, Equatable {
    var name: String
    var baseURL: String
    var apiKey: String
    var model: String
    var vision: Bool
    var chatURL: String { baseURL.hasSuffix("/") ? baseURL + "chat/completions" : baseURL + "/chat/completions" }
}

final class AppConfig {
    static let shared = AppConfig()
    private(set) var providers: [Provider] = []
    private(set) var activeName: String = ""
    private var path: String { kConfigDir + "/config.json" }

    // 当前厂商:按名字找;找不到回退第一条(永不为 nil,只要至少一条)
    var active: Provider? { providers.first { $0.name == activeName } ?? providers.first }

    private struct Stored: Codable { var active: String; var providers: [Provider] }

    static func presets() -> [Provider] {
        [ Provider(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", apiKey: "", model: "deepseek-chat", vision: false),
          Provider(name: "MiMo", baseURL: "https://api.xiaomimimo.com/v1", apiKey: "", model: "mimo-v2.5", vision: true) ]
    }

    // 启动调用一次。无文件/损坏 → 预置 + 迁移旧 mimo_key,并落盘
    func load() {
        if let data = FileManager.default.contents(atPath: path),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           !stored.providers.isEmpty {
            providers = stored.providers
            activeName = stored.active
            return
        }
        var ps = AppConfig.presets()
        if let raw = try? String(contentsOfFile: kKeyPath, encoding: .utf8) {   // 迁移旧 mimo_key
            let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty, let i = ps.firstIndex(where: { $0.name == "MiMo" }) { ps[i].apiKey = k }
        }
        providers = ps
        activeName = "MiMo"
        save()
        logLine("config initialized (providers=\(providers.count) active=\(activeName))")
    }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(Stored(active: activeName, providers: providers)) else { return }
        do { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
        catch { logLine("config save failed: \(error.localizedDescription)") }
    }

    func setProviders(_ ps: [Provider], active: String) {
        providers = ps
        activeName = active
        save()
    }
}
```

- [ ] **Step 2: build.sh 纳入**

`popdict-app/build.sh` 的 `SRCS="main.swift Markdown.swift Screenshot.swift"` → `SRCS="main.swift Markdown.swift Screenshot.swift Config.swift"`(两条 swiftc 行通过 `$SRCS` 自动带上)。

- [ ] **Step 3: 启动时 load()**

`main.swift` `applicationDidFinishLaunching` 开头(`ensureConfigDir()` 之后)加 `AppConfig.shared.load()`。

- [ ] **Step 4: 编译**

Run: `cd popdict-app && swiftc main.swift Markdown.swift Screenshot.swift Config.swift -target arm64-apple-macos12.0 -swift-version 5 -framework AppKit -framework ApplicationServices -framework Carbon -o /tmp/pd_t1`
Expected: 产物生成,无错误。

- [ ] **Step 5: 离线验证迁移 + 往返**(独立脚本)

写 `/tmp/cfgtest/main.swift`(与 Config.swift 一起编译,提供 stub 全局):

```swift
import Foundation
var kConfigDir = "/tmp/cfgtest_dir"
var kKeyPath = kConfigDir + "/mimo_key"
func logLine(_ s: String) { print("[log]", s) }

try? FileManager.default.removeItem(atPath: kConfigDir)
try? FileManager.default.createDirectory(atPath: kConfigDir, withIntermediateDirectories: true)
try! "sk-OLDMIMOKEY".write(toFile: kKeyPath, atomically: true, encoding: .utf8)

let c = AppConfig.shared
c.load()
assert(c.providers.count == 2, "应预置 2 条")
assert(c.active?.name == "MiMo", "默认 MiMo")
assert(c.active?.apiKey == "sk-OLDMIMOKEY", "应迁移旧 key")
assert(c.active?.chatURL == "https://api.xiaomimimo.com/v1/chat/completions", "chatURL 拼接")
// 改一条 + 切 active,落盘再读
var ps = c.providers
ps.append(Provider(name: "本地", baseURL: "http://localhost:1234/v1", apiKey: "x", model: "m", vision: false))
c.setProviders(ps, active: "本地")
// 用一个新进程般的「干净」单例不可得;直接重新解码文件验证
let data = FileManager.default.contents(atPath: kConfigDir + "/config.json")!
let s = String(data: data, encoding: .utf8)!
assert(s.contains("\"active\" : \"本地\""), "active 落盘")
assert(s.contains("本地"), "新厂商落盘")
print("ALL OK")
```

Run: `swiftc popdict-app/Config.swift /tmp/cfgtest/main.swift -o /tmp/cfgtest/run && /tmp/cfgtest/run`
Expected: `ALL OK`(stub 的 `kConfigDir`/`kKeyPath` 为 `var` 以覆盖 Config.swift 里对全局的引用——若编译报重复定义,把 Config.swift 里对全局的依赖保持 `let` 不在此文件定义即可,stub 文件提供这些 `let`)。

- [ ] **Step 6: 提交**

```bash
git add popdict-app/Config.swift popdict-app/build.sh popdict-app/main.swift
git commit -m "feat: 配置模型 AppConfig(config.json 厂商列表 + 旧 mimo_key 迁移)"
```

---

### Task 2: 后端改读当前厂商

**Files:**
- Modify: `popdict-app/main.swift`(`translate`、`chatStream`、`readAPIKey`;删除 `kAPIBase`/`kChatPath`/`kModel` 常量)

**Interfaces:**
- Consumes:Task 1 `AppConfig.shared.active`(`Provider`:`chatURL`/`model`/`apiKey`/`name`)。

- [ ] **Step 1: readAPIKey 改读当前厂商**

把 `readAPIKey()`(原读文件)改为:

```swift
func readAPIKey() -> String? {
    guard let k = AppConfig.shared.active?.apiKey, !k.isEmpty else { return nil }
    return k
}
```

- [ ] **Step 2: 删除后端硬编码常量**

删掉 `let kAPIBase = …`、`let kChatPath = …`、`let kModel = …` 三行(`kMaxTokens` 保留;`kKeyPath` 保留给迁移)。

- [ ] **Step 3: translate 改用当前厂商**

`translate` 顶部与 body/url 改为:

```swift
func translate(_ text: String, completion: @escaping (String?, String?) -> Void) {
    guard let prov = AppConfig.shared.active, !prov.apiKey.isEmpty else {
        completion(nil, "没配置 API Key。请点菜单栏 🌐 →「设置…」填入当前厂商的 Key")
        return
    }
    let target = hasChinese(text) ? "English" : "Simplified Chinese"
    let sys = "You are a professional translation engine. Translate the user's text into \(target). Output ONLY the translation itself — no explanations, no quotes, no extra words."
    let body: [String: Any] = [
        "model": prov.model,
        "messages": [["role": "system", "content": sys], ["role": "user", "content": text]],
        "temperature": 0.3, "max_completion_tokens": kMaxTokens,
        "thinking": ["type": "disabled"], "stream": false
    ]
    guard let url = URL(string: prov.chatURL),
          let data = try? JSONSerialization.data(withJSONObject: body) else {
        completion(nil, "请求构造失败"); return
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(prov.apiKey)", forHTTPHeaderField: "Authorization")
    req.httpBody = data
    req.timeoutInterval = 30
    URLSession.shared.dataTask(with: req) { respData, resp, err in
        if let err = err { DispatchQueue.main.async { completion(nil, "网络错误:\(err.localizedDescription)") }; return }
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            DispatchQueue.main.async { completion(nil, "\(prov.name) 出错(HTTP \(http.statusCode)),请检查 Key 或余额") }; return
        }
        guard let respData = respData,
              let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]], let first = choices.first,
              let msg = first["message"] as? [String: Any], let content = msg["content"] as? String else {
            DispatchQueue.main.async { completion(nil, "返回解析失败") }; return
        }
        DispatchQueue.main.async { completion(content.trimmingCharacters(in: .whitespacesAndNewlines), nil) }
    }.resume()
}
```

- [ ] **Step 4: chatStream 改用当前厂商**

`chatStream` 顶部:把无 key 检查与 body/url 改为:

```swift
    guard let prov = AppConfig.shared.active, !prov.apiKey.isEmpty else {
        onError("没配置 API Key。请点菜单栏 🌐 →「设置…」填入当前厂商的 Key"); return nil
    }
    let body: [String: Any] = [
        "model": prov.model, "messages": messages, "temperature": 0.5,
        "max_completion_tokens": kMaxTokens, "thinking": ["type": "disabled"], "stream": true
    ]
    guard let url = URL(string: prov.chatURL),
          let data = try? JSONSerialization.data(withJSONObject: body) else { onError("请求构造失败"); return nil }
```

并把 `req.setValue("Bearer \(apiKey)"...)` 改为 `req.setValue("Bearer \(prov.apiKey)"...)`;HTTP 非 200 文案 `"\(prov.name) 出错(HTTP \(http.statusCode))…"`;空内容文案 `"\(prov.name) 没有返回内容"`。

- [ ] **Step 5: 编译**

Run: `cd popdict-app && bash build.sh 2>&1 | tail -3`
Expected: `5/5 完成`,无错误/新警告。

- [ ] **Step 6: 提交**

```bash
git add popdict-app/main.swift
git commit -m "feat: 翻译/解释后端改读当前厂商(base_url/model/key)"
```

---

### Task 3: 设置窗口 `Settings.swift`

**Files:**
- Create: `popdict-app/Settings.swift`
- Modify: `popdict-app/build.sh`(SRCS 加 `Settings.swift`)

**Interfaces:**
- Consumes:Task 1 `AppConfig`、`Provider`;`gAppDelegate?.refreshMenu()`(main.swift 全局)。
- Produces:`final class SettingsController { func show() }`(AppDelegate 持有一例)。

- [ ] **Step 1: 写 `Settings.swift`**

```swift
import AppKit

// 一张厂商卡片(可编辑)。用 NSStackView 竖排若干行。
final class ProviderCardView: NSView {
    let nameField = NSTextField()
    let baseField = NSTextField()
    let keyField = NSSecureTextField()
    let modelField = NSTextField()
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
        visionCheck.state = provider.vision ? .on : .off
        [nameField, baseField, modelField].forEach { $0.font = .systemFont(ofSize: 12) }
        keyField.font = .systemFont(ofSize: 12)
        baseField.placeholderString = "https://…/v1"
        modelField.placeholderString = "model 名"

        activeRadio.target = self; activeRadio.action = #selector(activate)
        deleteButton.target = self; deleteButton.action = #selector(del)
        deleteButton.bezelStyle = .rounded; deleteButton.controlSize = .small

        func row(_ label: String, _ field: NSView) -> NSStackView {
            let l = NSTextField(labelWithString: label); l.font = .systemFont(ofSize: 11); l.alignment = .right
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: 64).isActive = true
            field.translatesAutoresizingMaskIntoConstraints = false
            let r = NSStackView(views: [l, field]); r.orientation = .horizontal; r.spacing = 8
            r.alignment = .firstBaseline
            return r
        }
        let top = NSStackView(views: [activeRadio, NSView(), deleteButton])
        top.orientation = .horizontal; top.distribution = .fill
        let last = NSStackView(views: [row("模型", modelField), visionCheck])
        last.orientation = .horizontal; last.spacing = 16

        let stack = NSStackView(views: [top, row("名字", nameField), row("Base URL", baseField),
                                        row("API Key", keyField), last])
        stack.orientation = .vertical; stack.spacing = 6; stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
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
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "popdict 设置"
        win.isReleasedWhenClosed = false

        let intro = NSTextField(labelWithString: "管理 OpenAI 兼容厂商。选一个为「当前使用」;截图解释需勾「支持看图」。")
        intro.font = .systemFont(ofSize: 11); intro.textColor = .secondaryLabelColor

        cardsStack.orientation = .vertical; cardsStack.spacing = 10; cardsStack.alignment = .leading
        cardsStack.translatesAutoresizingMaskIntoConstraints = false
        let clip = NSView(); clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(cardsStack)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.documentView = clip
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let addBtn = NSButton(title: "+ 添加厂商", target: self, action: #selector(addProvider)); addBtn.bezelStyle = .rounded
        let saveBtn = NSButton(title: "保存", target: self, action: #selector(save)); saveBtn.bezelStyle = .rounded; saveBtn.keyEquivalent = "\r"
        let closeBtn = NSButton(title: "关闭", target: self, action: #selector(closeWin)); closeBtn.bezelStyle = .rounded
        let bottom = NSStackView(views: [addBtn, NSView(), closeBtn, saveBtn]); bottom.orientation = .horizontal

        let root = NSStackView(views: [intro, scroll, bottom]); root.orientation = .vertical; root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        let cv = NSView(); cv.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: cv.topAnchor), root.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: cv.leadingAnchor), root.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            cardsStack.topAnchor.constraint(equalTo: clip.topAnchor), cardsStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            cardsStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor), cardsStack.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            clip.widthAnchor.constraint(equalTo: scroll.widthAnchor),
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
            card.widthAnchor.constraint(equalTo: cardsStack.widthAnchor).isActive = true
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
            card.removeFromSuperview(); self.cards.removeAll { $0 === card }
            if wasActive { self.cards.first?.setActive(true) }
            self.updateDeleteEnabled()
        }
        return card
    }

    private func updateDeleteEnabled() { cards.forEach { $0.deleteButton.isEnabled = cards.count > 1 } }

    @objc private func addProvider() {
        let card = makeCard(Provider(name: "新厂商", baseURL: "https://", apiKey: "", model: "", vision: false), active: false)
        cards.append(card); cardsStack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: cardsStack.widthAnchor).isActive = true
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
```

- [ ] **Step 2: build.sh 纳入**

`SRCS="… Config.swift"` → `SRCS="… Config.swift Settings.swift"`。

- [ ] **Step 3: 编译**

Run: `cd popdict-app && bash build.sh 2>&1 | tail -3`
Expected: `5/5 完成`,无错误。(未接菜单前先确保编译过。)

- [ ] **Step 4: 提交**

```bash
git add popdict-app/Settings.swift popdict-app/build.sh
git commit -m "feat: 设置窗口 SettingsController(厂商卡片增删/当前使用/保存)"
```

---

### Task 4: 看图门禁 + 菜单「设置…」/状态

**Files:**
- Modify: `popdict-app/main.swift`(`AppDelegate`:`settings` 属性、`openSettings`、`buildMenu`、`onScreenshotExplain`)

**Interfaces:**
- Consumes:Task 3 `SettingsController`;Task 1 `AppConfig.shared.active`。

- [ ] **Step 1: AppDelegate 持有设置控制器 + 打开**

`AppDelegate` 加属性 `let settings = SettingsController()`,并新增:

```swift
    @objc func openSettings() { settings.show() }
```

- [ ] **Step 2: 看图门禁**

`onScreenshotExplain()` 最前面(屏幕录制检查之前)加:

```swift
        guard AppConfig.shared.active?.vision == true else {
            let a = NSAlert()
            a.messageText = "当前厂商不支持看图"
            a.informativeText = "当前使用的「\(AppConfig.shared.active?.name ?? "?")」没有勾选「支持看图」。请点菜单栏 🌐 →「设置…」,切换到一个支持看图的厂商(如 MiMo)。"
            a.addButton(withTitle: "打开设置"); a.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn { openSettings() }
            return
        }
```

- [ ] **Step 3: 菜单状态行 + 设置项 + 截图灰掉**

`buildMenu()` 改动:把 API Key 状态行换成反映当前厂商,并给截图项加 enabled 判定、加「设置…」项:

```swift
        let act = AppConfig.shared.active
        let keyOK = !(act?.apiKey.isEmpty ?? true)
        menu.addItem(NSMenuItem(title: keyOK ? "✓ 当前:\(act?.name ?? "?")(已配置 Key)" : "⚠️ 当前:\(act?.name ?? "未设置")(未填 Key)",
                                action: nil, keyEquivalent: ""))
        let scrOK = RegionCapture.hasScreenRecordingPermission()
        menu.addItem(NSMenuItem(title: scrOK ? "✓ 屏幕录制:已授权" : "⚠️ 屏幕录制:未授权(截图解释需要)",
                                action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let shot = NSMenuItem(title: "📷 截图解释  ⌃⌥E", action: #selector(onScreenshotExplain), keyEquivalent: "")
        shot.isEnabled = (act?.vision == true)
        menu.addItem(shot)
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
```

(替换原来「✓ 已配置 API Key」那一行与其后到第一个 separator 之间的对应片段;其余菜单项保持。注意:`isEnabled=false` 需要该菜单未走 autoenable——给 `menu.autoenablesItems = false`。)

在 `buildMenu()` 开头 `let menu = NSMenu()` 后加 `menu.autoenablesItems = false`。

- [ ] **Step 4: 编译 + 手测设置往返**

Run: `cd popdict-app && bash build.sh 2>&1 | tail -3 && open popdict.app`
Expected: 编译过;菜单栏 🌐 出现「设置…」;打开能看到 DeepSeek/MiMo 两卡;切到 DeepSeek 保存后「📷 截图解释」灰掉、⌃⌥E 弹「不支持看图」。

- [ ] **Step 5: 提交**

```bash
git add popdict-app/main.swift
git commit -m "feat: 菜单「设置…」+ 当前厂商状态 + 看图门禁(非看图厂商灰掉截图解释)"
```

---

### Task 5: 浮窗可缩放 + 记忆大小(去自动长高)

**Files:**
- Modify: `popdict-app/main.swift`(`PopupController`:`makePanel`、`installConversationPanel`、`showMessage`、`present`/状态标记、移除 `growConversation`/`convoTimer`/`startConvoTimer`;新增 `ResizeGripView`、记忆尺寸存取、`NSWindowDelegate`)

**Interfaces:**
- Produces:`ResizeGripView`;`PopupController` 记忆尺寸(UserDefaults `popupSize`)。

- [ ] **Step 1: ResizeGripView**

在 `HoverButton` 之后新增:

```swift
// 右下角拖拽握把:拖动改窗口尺寸(左上角不动),松手回调保存
final class ResizeGripView: NSView {
    var onCommit: (() -> Void)?
    private var startMouse: NSPoint = .zero
    private var startFrame: NSRect = .zero
    let minW: CGFloat = 300, minH: CGFloat = 180

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with e: NSEvent) { startMouse = NSEvent.mouseLocation; startFrame = window?.frame ?? .zero }
    override func mouseDragged(with e: NSEvent) {
        guard let win = window else { return }
        let now = NSEvent.mouseLocation
        let newW = max(minW, startFrame.width + (now.x - startMouse.x))
        let newH = max(minH, startFrame.height - (now.y - startMouse.y))   // 向下拖 → 高度增加
        win.setFrame(NSRect(x: startFrame.minX, y: startFrame.maxY - newH, width: newW, height: newH), display: true)
    }
    override func mouseUp(with e: NSEvent) { onCommit?() }
    override func draw(_ r: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.7).setStroke()
        let p = NSBezierPath(); p.lineWidth = 1.2
        for off in stride(from: 4, through: 12, by: 4) {
            p.move(to: NSPoint(x: bounds.maxX - CGFloat(off) - 2, y: bounds.minY + 3))
            p.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + CGFloat(off) + 1))
        }
        p.stroke()
    }
}
```

- [ ] **Step 2: 记忆尺寸存取 + 状态标记 + NSWindowDelegate**

`PopupController` 加属性与方法:

```swift
    private var panelIsResizable = false       // 当前态是否「内容浮窗」(可缩放/记忆)
    private let kPopupSizeKey = "popupSize"
    private let defaultPopupSize = NSSize(width: 460, height: 380)

    private func savedPopupSize() -> NSSize {
        let d = UserDefaults.standard.array(forKey: kPopupSizeKey) as? [CGFloat]
        if let d = d, d.count == 2, d[0] >= 300, d[1] >= 180 { return NSSize(width: d[0], height: d[1]) }
        return defaultPopupSize
    }
    private func savePopupSize(_ s: NSSize) {
        UserDefaults.standard.set([s.width, s.height], forKey: kPopupSizeKey)
    }
    private func addGrip(to container: NSView) {
        let g = ResizeGripView(frame: NSRect(x: container.bounds.width - 18, y: 0, width: 18, height: 18))
        g.autoresizingMask = [.minXMargin, .maxYMargin]   // 固定右下角
        g.onCommit = { [weak self] in guard let self = self, let p = self.panel else { return }; self.savePopupSize(p.frame.size) }
        container.addSubview(g)
    }
```

让 `PopupController` 遵从 `NSWindowDelegate`(类声明加 `, NSWindowDelegate`),并实现:

```swift
    func windowDidEndLiveResize(_ notification: Notification) {
        guard panelIsResizable, let p = panel else { return }
        savePopupSize(p.frame.size)
    }
```

- [ ] **Step 3: makePanel 加 resizable + delegate + minSize**

`makePanel` 里 styleMask 改 `[.borderless, .nonactivatingPanel, .resizable]`;并加:

```swift
        p.minSize = NSSize(width: 300, height: 180)
        p.delegate = self
```

- [ ] **Step 4: 移除自动长高**

删除以下成员与其全部调用:`convoTimer` 属性、`startConvoTimer()`、`growConversation(force:)`。调用处清理:
- `installConversationPanel` 末尾的 `startConvoTimer()` 删除。
- `onAskSubmit` 里的 `startConvoTimer()` 删除。
- `finishTurn` 里的 `growConversation(force: true)` 删除(保留 `scrollTranscript(toLocation: turnStartLoc)`)。
- `convoError` 里的 `growConversation(force: true)` 删除(保留 `scrollTranscriptToBottom()`)。
- `beginImageConversation` 末尾的 `growConversation(force: true)` 删除。
- `stopConversation` 里 `convoTimer?.invalidate(); convoTimer = nil` 删除。
- `finishTurn`/`convoError` 开头的 `convoTimer?.invalidate(); convoTimer = nil` 删除。

- [ ] **Step 5: installConversationPanel 用记忆尺寸 + 握把**

`installConversationPanel(at:)` 改为按记忆尺寸建面板:

```swift
    private func installConversationPanel(at origin: NSPoint) {
        panelIsResizable = true
        let size = savedPopupSize()
        let textW = size.width - convoPad * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        container.autoresizingMask = [.width, .height]
        let scrollH = size.height - (inputBarH + transcriptBottomGap)
        let scroll = NSScrollView(frame: NSRect(x: convoPad, y: inputBarH + transcriptBottomGap, width: textW, height: scrollH))
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        let tv = makeTranscriptView(width: textW)
        scroll.documentView = tv
        container.addSubview(scroll)
        convoScroll = scroll; convoTextView = tv
        container.addSubview(makeInputBar(width: size.width))
        assistantStart = 0; assistantAccum = ""; turnStartLoc = 0
        addGrip(to: container)
        var rect = NSRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
        rect = clampToScreen(rect)
        present(content: container, rect: rect, animateFrame: false)
    }
```

> 说明:`makeTranscriptView`/`makeInputBar` 用 `convoW` 常量处的宽度——把它们的宽度参数改为传入 `size.width`(已是参数化:`makeInputBar(width:)`、`makeTranscriptView(width:)` 收 textW)。`beginConversation`/`beginImageConversation` 里基于 `convoW` 估算 `panelH`/origin 的部分,改用 `savedPopupSize()`。

`beginConversation` 与 `beginImageConversation` 里 `let panelH = convoPad + 22 + transcriptBottomGap + inputBarH` 改为 `let panelH = savedPopupSize().height`;`beginImageConversation` 的居中 origin 用 `savedPopupSize().width` 算 x。

- [ ] **Step 6: showMessage 结果用记忆尺寸 + 握把;瞬时态不记忆**

`showMessage` 改:`showCopy==true`(译文结果)→ 用记忆尺寸 + 握把 + `panelIsResizable=true`;否则(翻译中/错误)→ 保持原自适应小尺寸 + `panelIsResizable=false`、不加握把。在 `showMessage` 开头设 `panelIsResizable = showCopy`;当 `showCopy` 时把 `w`/`panelH` 取 `savedPopupSize()`,`bottomInset` 仍为 footer;滚动区高度 = 记忆高 - pad - footerH;末尾 `if showCopy { addGrip(to: container) }`。`showButton` 开头设 `panelIsResizable = false`。

- [ ] **Step 7: 编译 + 手测缩放记忆**

Run: `cd popdict-app && bash build.sh 2>&1 | tail -3 && open popdict.app`
Expected: 解释/截图解释浮窗为记忆尺寸;拖右下握把可改大小;关掉重开尺寸保持;长内容框内滚动。

- [ ] **Step 8: 提交**

```bash
git add popdict-app/main.swift
git commit -m "feat: 结果浮窗可缩放(握把/.resizable)+ 记住固定尺寸,去自动长高改内容滚动"
```

---

### Task 6: 文档 + 全量验证 + 对抗审查

**Files:**
- Modify: `README.md`;`popdict-app/build.sh`(安装说明)

- [ ] **Step 1: README**

把「配置 API Key」一节改为:打开后点菜单栏 🌐 →「设置…」,在厂商列表里填 Key/选「当前使用」;预置 DeepSeek、MiMo;旧 `mimo_key` 自动迁移。新增「浮窗可缩放」「设置/切换厂商」「DeepSeek 不能看图(截图解释会灰掉)」说明。

- [ ] **Step 2: build.sh 安装说明**

把「填 API Key」段从「echo 到 mimo_key」改为「打开后菜单栏 🌐 →『设置…』里填」,并保留迁移说明。

- [ ] **Step 3: 全量 universal 编译**

Run: `cd popdict-app && bash build.sh 2>&1 | tail -6`
Expected: arm64+x86_64 通过,无新警告。

- [ ] **Step 4: 冒烟矩阵**(按 spec「验证」节 1-4 逐条)

- [ ] **Step 5: 提交**

```bash
git add README.md popdict-app/build.sh
git commit -m "docs: README/安装说明改为设置 GUI 管理厂商 + 浮窗缩放说明"
```

- [ ] **Step 6: 多代理对抗审查**

用 Workflow 起多代理分维度审查(配置读写/迁移竞态、设置保存校验、看图门禁时序、窗口缩放与 autoresize 错位、去自动长高的回归、内存/弱引用、未知 thinking 字段),逐条对抗验证为真后修复,再编译过。

---

## Self-Review

**1. Spec coverage:**
- #3a 配置模型 → Task 1 ✓
- #3b 后端读当前厂商 → Task 2 ✓
- #3c 设置窗口 → Task 3 ✓
- #3d 门禁/菜单 → Task 4 ✓
- #1 缩放+记忆+去长高 → Task 5 ✓
- 迁移 mimo_key → Task 1 load() ✓
- 文档/验证/审查 → Task 6 ✓
- 全部 spec 章节均有对应任务。

**2. Placeholder scan:** 无 TBD/TODO;各步给了完整代码或精确改动位置。Task 5 Step 6 用文字描述 showMessage 的条件改动(非占位:给了具体字段与分支)。

**3. Type consistency:**
- `Provider`(name/baseURL/apiKey/model/vision + chatURL)在 Task 1 定义,Task 2/3/4 一致使用。
- `AppConfig.shared`(providers/activeName/active/load/save/setProviders/presets)前后一致。
- `SettingsController.show()`(Task 3)与 Task 4 `settings.show()` 一致。
- `ResizeGripView`(Task 5)、`savedPopupSize()`/`savePopupSize()`/`panelIsResizable`/`addGrip(to:)` 命名前后一致。
- `gAppDelegate?.refreshMenu()` 为既有全局,Task 3 使用一致。
- 移除的 `growConversation`/`startConvoTimer`/`convoTimer` 在 Task 5 列全调用点,无悬挂引用。
