import Foundation

// ============================================================
// 配置模型:一组用户可自管理的 OpenAI 兼容厂商,选一个为「当前使用」。
// 持久化到 ~/.config/popdict/config.json;首次自动迁移旧 mimo_key。
// ============================================================

// 一个 OpenAI 兼容厂商。name 用户自定义、作唯一标识;baseURL 含 /v1。
struct Provider: Codable, Equatable {
    var name: String
    var baseURL: String
    var apiKey: String
    var model: String
    var vision: Bool   // 是否支持看图(任意 OpenAI 兼容厂商无法自动判定,人工勾)

    var chatURL: String {
        baseURL.hasSuffix("/") ? baseURL + "chat/completions" : baseURL + "/chat/completions"
    }
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

    @discardableResult
    func save() -> Bool {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(Stored(active: activeName, providers: providers)) else { return false }
        do { try data.write(to: URL(fileURLWithPath: path), options: .atomic); return true }
        catch { logLine("config save failed: \(error.localizedDescription)"); return false }
    }

    // 落盘失败时回滚内存,保证内存与文件一致(避免「界面显示已保存、实际丢了」)
    @discardableResult
    func setProviders(_ ps: [Provider], active: String) -> Bool {
        let oldP = providers, oldA = activeName
        providers = ps
        activeName = active
        if save() { return true }
        providers = oldP; activeName = oldA
        return false
    }
}
