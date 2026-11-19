import Foundation

/// 一个平台的设置（地址/模型留空＝用预设默认值；密钥只存在本机 secrets.json）
public struct AIProviderSettings: Codable, Sendable, Equatable {
    public var baseURL: String?
    public var model: String?
    public var fallbacks: [String]?
    public var apiKey: String?
    public init(baseURL: String? = nil, model: String? = nil, fallbacks: [String]? = nil, apiKey: String? = nil) {
        self.baseURL = baseURL; self.model = model; self.fallbacks = fallbacks; self.apiKey = apiKey
    }
}

/// 本机密钥与 AI 平台设置：~/Library/Application Support/拾藏/secrets.json（目录 700、文件 600、原子写）。
/// 有意不用钥匙串（免签名证书、换机直接拷文件）；不进 iCloud、不进日志、不进导出/备份。
/// 同时只用一个平台（activeProvider）；每个平台的设置分开记，切回去不用重填。
public struct Secrets: Sendable, Equatable {
    public var activeProvider: String
    public var providers: [String: AIProviderSettings]

    public init(activeProvider: String = AIPreset.defaultId, providers: [String: AIProviderSettings] = [:]) {
        self.activeProvider = activeProvider; self.providers = providers
    }

    /// 旧版（P1b）写法：只有 CRS
    public init(crsBaseURL: String?, crsAPIKey: String?) {
        self.init(activeProvider: "crs", providers: ["crs": AIProviderSettings(baseURL: crsBaseURL, apiKey: crsAPIKey)])
    }

    public func config(for id: String) -> AIConfig {
        let p = providers[id] ?? AIProviderSettings()
        return AIConfig(preset: AIPreset.find(id), baseURL: p.baseURL, model: p.model, fallbacks: p.fallbacks, apiKey: p.apiKey)
    }
    /// 当前生效的平台设置
    public var active: AIConfig { config(for: activeProvider) }
    public var hasKey: Bool { active.hasKey }
    /// 能开始分类（需要密钥的平台填了密钥；「其他」平台密钥可不填）
    public var isReady: Bool { active.isReady }

    // 旧字段的读写（命令行和旧测试用）
    public var crsBaseURL: String? {
        get { providers["crs"]?.baseURL }
        set { providers["crs", default: AIProviderSettings()].baseURL = newValue }
    }
    public var crsAPIKey: String? {
        get { providers["crs"]?.apiKey }
        set { providers["crs", default: AIProviderSettings()].apiKey = newValue }
    }
}

extension Secrets: Codable {
    enum CodingKeys: String, CodingKey { case schema, activeProvider, providers, crsBaseURL, crsAPIKey }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = (try? c.decodeIfPresent([String: AIProviderSettings].self, forKey: .providers)) ?? [:]
        // 早期版本的旧文件：{crsBaseURL, crsAPIKey}，当时只有 CRS 一个平台
        let oldBase = (try? c.decodeIfPresent(String.self, forKey: .crsBaseURL)) ?? nil
        let oldKey = (try? c.decodeIfPresent(String.self, forKey: .crsAPIKey)) ?? nil
        let legacy = oldBase != nil || oldKey != nil
        activeProvider = ((try? c.decodeIfPresent(String.self, forKey: .activeProvider)) ?? nil) ?? (legacy ? "crs" : AIPreset.defaultId)
        if legacy {
            var p = providers["crs"] ?? AIProviderSettings()
            if p.baseURL == nil { p.baseURL = oldBase }
            if p.apiKey == nil { p.apiKey = oldKey }
            providers["crs"] = p
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(2, forKey: .schema)
        try c.encode(activeProvider, forKey: .activeProvider)
        try c.encode(providers, forKey: .providers)
    }
}

extension Secrets: CustomStringConvertible, CustomDebugStringConvertible {
    /// 打日志/调试输出时永远不显示密钥
    public var description: String {
        let a = active
        return "Secrets(平台: \(a.preset.name), 地址: \(AIConfig.clean(a.baseURL) ?? "默认"), 模型: \(a.effectiveModel), 密钥: \(a.hasKey ? "已设置" : "未设置"))"
    }
    public var debugDescription: String { description }
}

extension AIProviderSettings: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "AIProviderSettings(地址: \(baseURL ?? "默认"), 模型: \(model ?? "默认"), 密钥: \(AIConfig.clean(apiKey) == nil ? "未设置" : "已设置"))"
    }
    public var debugDescription: String { description }
}

extension AIConfig: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "AIConfig(\(preset.id), 地址: \(endpoint?.absoluteString ?? "-"), 模型: \(modelChain.joined(separator: "→")), 密钥: \(hasKey ? "已设置" : "未设置"))"
    }
    public var debugDescription: String { description }
}

public enum SecretStore {
    public static func url(_ paths: Paths) -> URL { paths.local.appendingPathComponent("secrets.json") }

    public static func load(_ paths: Paths) -> Secrets {
        guard let d = try? Data(contentsOf: url(paths)) else { return Secrets() }
        return (try? JSONDecoder().decode(Secrets.self, from: d)) ?? Secrets()
    }

    /// 先在同目录建 0600 临时文件写好，再 rename 覆盖：任何时刻都不存在权限更宽的副本
    public static func save(_ s: Secrets, _ paths: Paths) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.local, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.local.path)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(s)
        let tmp = paths.local.appendingPathComponent(".secrets-\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let ok = data.withUnsafeBytes { buf in write(fd, buf.baseAddress, buf.count) == buf.count }
        fsync(fd); close(fd)
        guard ok else { unlink(tmp.path); throw CocoaError(.fileWriteUnknown) }
        guard rename(tmp.path, url(paths).path) == 0 else { unlink(tmp.path); throw CocoaError(.fileWriteUnknown) }
    }
}
