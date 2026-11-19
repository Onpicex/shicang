import Foundation

// MARK: 平台预设

/// 两种接口协议：Anthropic Messages（CRS、Claude 官方）和 OpenAI Chat Completions（其余几乎所有平台都兼容）
public enum AIProtocol: String, Codable, Sendable { case anthropic, openai }

/// OpenAI 兼容接口的 JSON 输出方式：先试 json_schema，不支持就退到 json_object，再不行只靠提示词
enum JSONMode: Int, Sendable { case schema = 0, object = 1, prompt = 2 }

/// 常见平台的默认地址和推荐模型。同时只用一个平台：不可用就排队退避，绝不自动换平台（换平台可能把文章发给你没打算用的服务）。
/// 模型名 2026-11 核对过官方文档；各家改名频繁，设置里可改、可「拉取模型列表」、可「测试」。
public struct AIPreset: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let proto: AIProtocol
    public let baseURL: String
    public let model: String
    public let suggestions: [String]      // 设置里模型下拉的备选
    public let fallbacks: [String]        // 同平台备用模型的默认值（主模型暂时不可用时依次试）
    public let needsKey: Bool
    public let keyHint: String
    public let note: String               // 设置里显示的一句说明
    let bareHostPath: String              // 只填了 host 时补的路径
    let jsonMode: JSONMode
    let tokenField: String                // max_tokens / max_completion_tokens
    let extraJSON: String?                // 额外请求字段（关掉深度思考等）；被拒（400）时自动去掉重试

    public static func == (a: AIPreset, b: AIPreset) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }

    init(_ id: String, _ name: String, _ proto: AIProtocol, base: String, model: String, suggestions: [String] = [], fallbacks: [String] = [],
         needsKey: Bool = true, keyHint: String, note: String = "", bareHostPath: String = "/v1/chat/completions",
         jsonMode: JSONMode = .schema, tokenField: String = "max_tokens", extraJSON: String? = nil) {
        self.id = id; self.name = name; self.proto = proto; self.baseURL = base; self.model = model
        self.suggestions = suggestions; self.fallbacks = fallbacks; self.needsKey = needsKey; self.keyHint = keyHint; self.note = note
        self.bareHostPath = bareHostPath; self.jsonMode = jsonMode; self.tokenField = tokenField; self.extraJSON = extraJSON
    }

    public static let defaultId = "anthropic"
    public static let customId = "custom"

    public static let all: [AIPreset] = [
        AIPreset("anthropic", "Anthropic（Claude 官方）", .anthropic, base: "https://api.anthropic.com", model: "claude-opus-5-5",
                 suggestions: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"],
                 fallbacks: ["claude-sonnet-5-5", "claude-haiku-5-5"],
                 keyHint: "console.anthropic.com 里创建的 sk-ant-… 密钥", bareHostPath: "/v1/messages"),
        AIPreset("crs", "CRS 中继（自建）", .anthropic, base: "", model: "claude-opus-5-5",
                 suggestions: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"],
                 fallbacks: ["claude-sonnet-5-5", "claude-haiku-5-5"],
                 keyHint: "中继后台创建的 API Key", note: "Claude 模型，经你自己部署的 Claude Relay Service；地址填到 /api，如 https://relay.example.com/api",
                 bareHostPath: "/api/v1/messages"),
        AIPreset("openai", "OpenAI", .openai, base: "https://api.openai.com/v1", model: "gpt-5.5",
                 suggestions: ["gpt-5.5", "gpt-6.1-terra", "gpt-5.4-mini"],
                 keyHint: "platform.openai.com 里创建的 sk-… 密钥",
                 tokenField: "max_completion_tokens", extraJSON: #"{"reasoning_effort":"low"}"#),
        AIPreset("gemini", "Google Gemini", .openai, base: "https://generativelanguage.googleapis.com/v1beta/openai", model: "gemini-3.8-flash",
                 suggestions: ["gemini-3.8-flash", "gemini-3.6-flash"],
                 keyHint: "Google AI Studio 里创建的密钥", note: "用 Gemini 的 OpenAI 兼容接口",
                 extraJSON: #"{"reasoning_effort":"low"}"#),
        AIPreset("deepseek", "DeepSeek", .openai, base: "https://api.deepseek.com/v1", model: "deepseek-v4-flash",
                 suggestions: ["deepseek-v4-flash", "deepseek-v4-pro"],
                 keyHint: "platform.deepseek.com 里创建的密钥", jsonMode: .object,
                 extraJSON: #"{"thinking":{"type":"disabled"}}"#),
        AIPreset("kimi", "Kimi（月之暗面）", .openai, base: "https://api.moonshot.cn/v1", model: "kimi-k3.1-pro",
                 suggestions: ["kimi-k3.1-pro", "kimi-k3.1-pro-highspeed", "kimi-k2.6"],
                 keyHint: "platform.moonshot.cn 里创建的密钥", jsonMode: .object),
        AIPreset("qwen", "通义千问（阿里云百炼）", .openai, base: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus",
                 suggestions: ["qwen-plus", "qwen3.7-plus", "qwen4-max"],
                 keyHint: "百炼控制台里创建的 sk-… 密钥", jsonMode: .object),
        AIPreset("zhipu", "智谱 GLM", .openai, base: "https://open.bigmodel.cn/api/paas/v4", model: "glm-5.3",
                 suggestions: ["glm-5.3", "glm-4.7-flash"],
                 keyHint: "open.bigmodel.cn 里创建的密钥", note: "glm-4.7-flash 免费", bareHostPath: "/api/paas/v4/chat/completions",
                 jsonMode: .object, extraJSON: #"{"thinking":{"type":"disabled"}}"#),
        AIPreset("doubao", "豆包（火山方舟）", .openai, base: "https://ark.cn-beijing.volces.com/api/v3", model: "doubao-seed-2-1-turbo-260628",
                 suggestions: ["doubao-seed-2-1-turbo-260628", "doubao-seed-2-1-pro-260915", "doubao-seed-evolving"],
                 keyHint: "方舟控制台的 API Key", note: "模型也可以填接入点 ep-…", bareHostPath: "/api/v3/chat/completions",
                 jsonMode: .object, extraJSON: #"{"thinking":{"type":"disabled"}}"#),
        AIPreset("openrouter", "OpenRouter", .openai, base: "https://openrouter.ai/api/v1", model: "google/gemini-3.8-flash",
                 suggestions: ["google/gemini-3.8-flash", "deepseek/deepseek-v4-flash"],
                 keyHint: "openrouter.ai 里创建的 sk-or-… 密钥", note: "模型 ID 以 OpenRouter 模型页为准"),
        AIPreset("siliconflow", "硅基流动", .openai, base: "https://api.siliconflow.cn/v1", model: "deepseek-ai/DeepSeek-V4-Flash",
                 suggestions: ["deepseek-ai/DeepSeek-V4-Flash", "Qwen/Qwen3-8B"],
                 keyHint: "cloud.siliconflow.cn 里创建的密钥", note: "模型名要写全「厂商/模型」", jsonMode: .object),
        AIPreset("custom", "其他（OpenAI 兼容）", .openai, base: "", model: "",
                 needsKey: false, keyHint: "平台要求才填", note: "填平台给的 Base URL（通常以 /v1 结尾）和模型 ID"),
    ]

    public static func find(_ id: String?) -> AIPreset { all.first { $0.id == id } ?? all.first { $0.id == defaultId }! }

    /// 地址宽松：只填 host[:port]、填到 /v1（或 /api、/v4）、填完整端点都行
    public func endpoint(_ base: String?) -> URL? {
        var b = (base ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if b.isEmpty { b = baseURL }
        if b.isEmpty { return nil }
        if !b.contains("://") { b = "https://" + b }     // 只填了 host：一律 https
        while b.hasSuffix("/") { b.removeLast() }
        guard let u = URL(string: b), u.host != nil else { return nil }
        switch proto {
        case .anthropic:
            if b.hasSuffix("/v1/messages") || b.hasSuffix("/messages") { return u }
            if b.hasSuffix("/v1") { return URL(string: b + "/messages") }
            if b.hasSuffix("/api") || b.hasSuffix("/anthropic") { return URL(string: b + "/v1/messages") }
            return u.path.isEmpty ? URL(string: b + bareHostPath) : URL(string: b + "/v1/messages")
        case .openai:
            if b.hasSuffix("/chat/completions") { return u }
            if u.path.isEmpty { return URL(string: b + bareHostPath) }
            return URL(string: b + "/chat/completions")     // …/v1、…/v3、…/v4、…/compatible-mode/v1、…/openai
        }
    }

    /// 模型列表接口（拉取模型列表用）
    func modelsURL(_ endpoint: URL) -> URL? {
        var s = endpoint.absoluteString
        for suf in ["/chat/completions", "/messages"] where s.hasSuffix(suf) { s.removeLast(suf.count); break }
        return URL(string: s + "/models")
    }
}

// MARK: 生效配置

/// 一个平台的完整设置（地址/模型留空＝用预设默认值）
public struct AIConfig: Sendable, Equatable {
    public var preset: AIPreset
    public var baseURL: String?
    public var model: String?
    public var fallbacks: [String]?       // nil＝预设默认；[]＝不要备用
    public var apiKey: String?

    public init(preset: AIPreset, baseURL: String? = nil, model: String? = nil, fallbacks: [String]? = nil, apiKey: String? = nil) {
        self.preset = preset; self.baseURL = baseURL; self.model = model; self.fallbacks = fallbacks; self.apiKey = apiKey
    }

    public static func clean(_ s: String?) -> String? {
        let v = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
    public var key: String? { Self.clean(apiKey) }
    public var effectiveModel: String { Self.clean(model) ?? preset.model }
    public var effectiveFallbacks: [String] {
        (fallbacks ?? preset.fallbacks).compactMap { Self.clean($0) }.filter { $0 != effectiveModel }
    }
    /// 依次尝试的模型（主模型在前）
    public var modelChain: [String] { effectiveModel.isEmpty ? [] : [effectiveModel] + effectiveFallbacks }
    public var endpoint: URL? { preset.endpoint(baseURL) }
    public var hasKey: Bool { key != nil }
    public static let httpBanned = "地址要用 https://（已禁止 http 连接，本机 localhost 也不例外）"
    /// 能不能开始分类：地址、模型齐了，需要密钥的平台填了密钥
    public var isReady: Bool {
        guard let u = endpoint, NetPolicy.allowed(u) else { return false }
        return !effectiveModel.isEmpty && (!preset.needsKey || hasKey)
    }
    /// 缺什么（给界面）
    public var missing: String? {
        guard let u = endpoint else { return "没填地址" }
        if !NetPolicy.allowed(u) { return Self.httpBanned }
        if effectiveModel.isEmpty { return "没填模型" }
        if preset.needsKey && !hasKey { return "未设置密钥" }
        return nil
    }
}

// MARK: 错误

public enum AIError: Error, CustomStringConvertible, Sendable {
    case unauthorized(String)     // 401/403：密钥不对，停下等用户改
    case config(String)           // 地址/模型不对（404、首次请求就 400）：停下等用户改
    case unreachable(String)      // 连不上：换模型也一样，直接退避
    case http(Int, String)
    case timeout
    case badResponse(String)      // 不是 JSON、被截断、拒答

    public var description: String {
        switch self {
        case .unauthorized(let m): return "密钥无效：\(m)"
        case .config(let m): return "设置有误：\(m)"
        case .unreachable(let m): return "连不上：\(m)"
        case .http(let c, let m): return "服务返回 \(c)：\(m)"
        case .timeout: return "请求超时"
        case .badResponse(let m): return "返回内容不对：\(m)"
        }
    }

    /// 暂时性的（换个模型或过一会儿再试可能就好）
    var transient: Bool {
        switch self {
        case .timeout, .unreachable: return true
        case .http(let c, _): return [408, 409, 425, 429, 500, 502, 503, 504, 529].contains(c)
        default: return false
        }
    }
}

@available(*, deprecated, renamed: "AIError")
public typealias CRSError = AIError

// MARK: 客户端

/// 同一个 (端点, 模型) 试出来能用的 JSON 方式/额外字段，记在内存里，下次直接用
final class AIProbeCache: @unchecked Sendable {
    static let shared = AIProbeCache()
    struct Entry { var mode: JSONMode; var dropExtra: Bool; var verified: Bool; var inlineSystem = false }
    private var m: [String: Entry] = [:]
    private let lock = NSLock()
    func get(_ k: String) -> Entry? { lock.lock(); defer { lock.unlock() }; return m[k] }
    func set(_ k: String, _ e: Entry) { lock.lock(); m[k] = e; lock.unlock() }
    func reset() { lock.lock(); m = [:]; lock.unlock() }
}

public struct AIClient: Sendable {
    public let config: AIConfig
    public let endpoint: URL
    let session: URLSession

    public init?(config: AIConfig, timeout: TimeInterval = 90) {
        guard config.isReady, let u = config.endpoint else { return nil }
        self.config = config
        endpoint = u
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 30
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        if let extra = Self.testProtocolClasses { cfg.protocolClasses = extra + (cfg.protocolClasses ?? []) }
        session = URLSession(configuration: cfg, delegate: NetPolicy.redirectGuard, delegateQueue: nil)   // 跳到 http 的改 https
    }

    /// 单测注入假服务器（只拦测试用的域名）
    nonisolated(unsafe) static var testProtocolClasses: [AnyClass]?

    public init?(secrets: Secrets, timeout: TimeInterval = 90) { self.init(config: secrets.active, timeout: timeout) }

    public var platformName: String { config.preset.name }

    public struct Reply: Sendable {
        public var text: String
        public var model: String
        public var inputTokens: Int
        public var outputTokens: Int
        public var jsonMode: String       // schema / object / prompt（OpenAI 兼容）或 schema（Anthropic）
    }

    /// 一次结构化输出请求。formatHint：不支持 json_schema 时附在系统提示词后面的 JSON 格式说明
    public func call(model: String, system: String, user: String, schemaJSON: Data, schemaName: String = "result",
                     formatHint: String = "", maxTokens: Int = 2000) async throws -> Reply {
        switch config.preset.proto {
        case .anthropic: return try await callAnthropic(model: model, system: system, user: user, schemaJSON: schemaJSON, maxTokens: maxTokens)
        case .openai: return try await callOpenAI(model: model, system: system, user: user, schemaJSON: schemaJSON,
                                                  schemaName: schemaName, formatHint: formatHint)
        }
    }

    private func callAnthropic(model: String, system: String, user: String, schemaJSON: Data, maxTokens: Int) async throws -> Reply {
        guard let schema = try? JSONSerialization.jsonObject(with: schemaJSON) else { throw AIError.badResponse("schema 无效") }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema]],
            "messages": [["role": "user", "content": user]],
        ]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        if let k = config.key { req.setValue(k, forHTTPHeaderField: "x-api-key") }
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(req)
        struct Resp: Decodable {
            struct Block: Decodable { var type: String; var text: String? }
            struct Usage: Decodable { var input_tokens: Int?; var output_tokens: Int? }
            var content: [Block]?
            var stop_reason: String?
            var model: String?
            var usage: Usage?
        }
        guard let r = try? JSONDecoder().decode(Resp.self, from: data) else { throw AIError.badResponse("不是 Messages 格式") }
        if r.stop_reason == "refusal" { throw AIError.badResponse("模型拒答") }
        if r.stop_reason == "max_tokens" { throw AIError.badResponse("输出被截断") }
        let text = (r.content ?? []).filter { $0.type == "text" }.compactMap(\.text).joined()
        return Reply(text: text, model: r.model ?? model, inputTokens: r.usage?.input_tokens ?? 0,
                     outputTokens: r.usage?.output_tokens ?? 0, jsonMode: "schema")
    }

    private func callOpenAI(model: String, system: String, user: String, schemaJSON: Data, schemaName: String, formatHint: String) async throws -> Reply {
        guard let schema = try? JSONSerialization.jsonObject(with: schemaJSON) else { throw AIError.badResponse("schema 无效") }
        let p = config.preset
        let cacheKey = endpoint.absoluteString + "|" + model
        let extra = p.extraJSON.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        var state = AIProbeCache.shared.get(cacheKey) ?? .init(mode: p.jsonMode, dropExtra: extra == nil, verified: false)
        while true {
            var sys = system
            if !formatHint.isEmpty { sys += "\n\n" + formatHint }      // 总是附上：有的服务收下 response_format 却不执行
            // 有的中转站会把 system 换成自己的提示词：那就把指令放进用户消息
            let messages: [[String: Any]] = state.inlineSystem
                ? [["role": "user", "content": sys + "\n\n———— 以下是要处理的内容 ————\n\n" + user]]
                : [["role": "system", "content": sys], ["role": "user", "content": user]]
            var body: [String: Any] = [
                "model": model,
                "messages": messages,
                p.tokenField: 8000,      // 留足余量：有的模型带推理，推理也算输出 token
                "stream": false,
            ]
            switch state.mode {
            case .schema: body["response_format"] = ["type": "json_schema", "json_schema": ["name": schemaName, "strict": true, "schema": schema]]
            case .object: body["response_format"] = ["type": "json_object"]
            case .prompt: break
            }
            if !state.dropExtra, let extra { for (k, v) in extra { body[k] = v } }
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            if let k = config.key { req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization") }
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            if p.id == "openrouter" { req.setValue("Shicang", forHTTPHeaderField: "X-Title") }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let data: Data
            do {
                data = try await send(req)
            } catch AIError.http(let code, let msg) where code == 400 || code == 422 {
                // 参数不被接受：先去掉额外字段，再逐级降 JSON 方式；都试过还不行才报错
                if !state.dropExtra { state.dropExtra = true; continue }
                if state.mode != .prompt { state.mode = JSONMode(rawValue: state.mode.rawValue + 1)!; continue }
                if !state.verified { throw AIError.config("请求被拒（\(code)）：\(msg)") }
                throw AIError.http(code, msg)
            }
            struct Resp: Decodable {
                struct Msg: Decodable { var content: String?; var refusal: String? }
                struct Choice: Decodable { var message: Msg?; var finish_reason: String? }
                struct Usage: Decodable { var prompt_tokens: Int?; var completion_tokens: Int? }
                var choices: [Choice]?
                var model: String?
                var usage: Usage?
            }
            guard let r = try? JSONDecoder().decode(Resp.self, from: data), let c = r.choices?.first else {
                throw AIError.badResponse("不是 Chat Completions 格式：\(Self.errorMessage(data).prefix(80))")
            }
            if let ref = c.message?.refusal, !ref.isEmpty { throw AIError.badResponse("模型拒答") }
            if c.finish_reason == "length" { throw AIError.badResponse("输出被截断") }
            if c.finish_reason == "content_filter" || c.finish_reason == "sensitive" { throw AIError.badResponse("被平台内容审核拦下") }
            let content = c.message?.content ?? ""
            if !Self.containsJSONObject(content), !state.inlineSystem {
                state.inlineSystem = true          // 回的不是 JSON：多半是 system 被换掉了，指令挪进用户消息再试一次
                continue
            }
            state.verified = true
            AIProbeCache.shared.set(cacheKey, state)
            let modeName = ["schema", "object", "prompt"][state.mode.rawValue]
            return Reply(text: content, model: r.model ?? model, inputTokens: r.usage?.prompt_tokens ?? 0,
                         outputTokens: r.usage?.completion_tokens ?? 0, jsonMode: modeName + (state.inlineSystem ? "+inline" : ""))
        }
    }

    /// 发请求 + 统一错误映射
    private func send(_ req: URLRequest) async throws -> Data {
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch let e as URLError {
            switch e.code {
            case .timedOut: throw AIError.timeout
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet, .networkConnectionLost,
                 .secureConnectionFailed, .badServerResponse:
                throw AIError.unreachable(e.localizedDescription)
            case .appTransportSecurityRequiresSecureConnection:
                throw AIError.config(AIConfig.httpBanned)
            default: throw AIError.unreachable("\(e.code.rawValue) \(e.localizedDescription)")
            }
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = Self.errorMessage(data)
            switch status {
            case 401, 403: throw AIError.unauthorized("\(status) \(msg)")
            case 404: throw AIError.config("地址或模型名不对（404）\(msg.isEmpty ? "" : "：\(msg)")")
            case 402: throw AIError.config("账户余额不足（402）\(msg.isEmpty ? "" : "：\(msg)")")
            default: throw AIError.http(status, msg)
            }
        }
        return data
    }

    /// 拉取平台的模型列表（GET …/models；OpenAI 兼容和 Anthropic 官方都有）
    public func listModels() async throws -> [String] {
        guard let u = config.preset.modelsURL(endpoint) else { throw AIError.config("地址不对") }
        var req = URLRequest(url: u)
        if let k = config.key {
            if config.preset.proto == .anthropic { req.setValue(k, forHTTPHeaderField: "x-api-key") }
            else { req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization") }
        }
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let data = try await send(req)
        struct Resp: Decodable { struct M: Decodable { var id: String }; var data: [M]?; var models: [M]? }
        guard let r = try? JSONDecoder().decode(Resp.self, from: data) else { throw AIError.badResponse("模型列表格式不认识") }
        return Array(Set((r.data ?? r.models ?? []).map(\.id))).sorted()
    }

    static func containsJSONObject(_ text: String) -> Bool {
        guard let d = ClassifyPrompt.extractJSON(text).data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: d)) is [String: Any]
    }

    static func errorMessage(_ d: Data) -> String {
        if let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let e = o["error"] as? [String: Any], let m = e["message"] as? String { return String(m.prefix(200)) }
            if let e = o["error"] as? String { return String(e.prefix(200)) }
            if let m = o["message"] as? String { return String(m.prefix(200)) }
        }
        return String((String(data: d, encoding: .utf8) ?? "").prefix(200))
    }
}

// MARK: 测试连接

public enum AITester {
    /// 用设置里的平台/模型真跑一次分类（固定的小样例文章、当前分类表），确认密钥、模型、JSON 输出都通
    public static func run(_ config: AIConfig, taxonomy: Taxonomy, timeout: TimeInterval = 60) async -> Result<String, AIError> {
        guard let client = AIClient(config: config, timeout: timeout) else { return .failure(.config(config.missing ?? "设置不完整")) }
        let art = Article(id: "test", canonicalId: "test", aliases: [], source: .web, url: "https://example.com/test", capturedURL: "",
                          title: "用 SQLite 全文索引给笔记应用做中文搜索",
                          author: nil, authorHandle: nil, authorURL: nil, publishedAt: nil, capturedAt: Date(), cover: nil, summary: nil,
                          blocks: [.paragraph([Inline("SQLite 自带的 FTS5 默认按空格分词，对中文几乎没用。本文把正文预先切成单字和相邻二字，存进 FTS5，查询时同样切分后用 AND 连接，2 字和 3 字以上的词都能命中，几千篇文章的库每次查询不到 1 毫秒。文末给出了建表语句和排序权重的设置。")])],
                          extractor: "test", stats: ArticleStats(chars: 120, images: 0, imagesSaved: 0, videos: 0))
        let prompt = ClassifyPrompt.build(art, taxonomy: taxonomy, existingTags: [])
        let t0 = Date()
        do {
            let reply = try await client.call(model: config.effectiveModel, system: prompt.system, user: prompt.user,
                                              schemaJSON: prompt.schemaJSON, schemaName: "classification", formatHint: prompt.formatHint)
            let r = try ClassifyPrompt.parse(reply.text, taxonomy: taxonomy, existingTags: [], model: reply.model, device: nil)
            let inline = reply.jsonMode.hasSuffix("+inline")
            let base = inline ? String(reply.jsonMode.dropLast(7)) : reply.jsonMode
            let mode = (["schema": "结构化输出", "object": "JSON 模式", "prompt": "提示词约束"][base] ?? base) + (inline ? "（平台不认系统提示词，已改放进用户消息）" : "")
            return .success(String(format: "可用：%@ · %.1f 秒 · %@ · 样例分到「%@」", reply.model, Date().timeIntervalSince(t0), mode, r.categoryName))
        } catch let e as AIError {
            return .failure(e)
        } catch {
            return .failure(.badResponse(error.localizedDescription))
        }
    }
}
