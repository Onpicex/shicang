import Foundation

/// AI 分类结果，存在文章文件夹的 ai.json（article.json 只写一次，AI 结果单独放，重新分类只覆盖这个文件）
public struct AIResult: Codable, Sendable, Hashable {
    public var schema: Int = 1
    public var categoryId: String
    public var categoryName: String
    public var confidence: Double
    public var tags: [String]
    public var summary: String
    public var keyPoints: [String]
    public var model: String
    public var at: Date
    public var device: String?

    public static let reviewThreshold = 0.6
    public var lowConfidence: Bool { confidence < Self.reviewThreshold }
}

public enum AIStore {
    public static let fileName = "ai.json"
    public static func load(dir: URL) -> AIResult? {
        (try? Data(contentsOf: dir.appendingPathComponent(fileName))).flatMap { try? Coders.decoder.decode(AIResult.self, from: $0) }
    }
    public static func write(_ r: AIResult, dir: URL) throws {
        try Coders.encoder.encode(r).write(to: dir.appendingPathComponent(fileName), options: .atomic)
    }
}

/// 本机偏好（不同步）
public struct Prefs: Codable, Sendable, Equatable {
    public var classifyEnabled: Bool = true
    public init() {}

    static func url(_ p: Paths) -> URL { p.local.appendingPathComponent("prefs.json") }
    public static func load(_ p: Paths) -> Prefs {
        (try? Data(contentsOf: url(p))).flatMap { try? JSONDecoder().decode(Prefs.self, from: $0) } ?? Prefs()
    }
    public func save(_ p: Paths) { try? JSONEncoder().encode(self).write(to: Self.url(p), options: .atomic) }
}

// MARK: 提示词与解析（纯函数，单测覆盖）

public enum ClassifyPrompt {
    public static let bodyLimit = 3000

    public struct Built: Sendable {
        public var system: String
        public var user: String
        public var schemaJSON: Data
        /// 不支持 json_schema 的平台：附在系统提示词后面的 JSON 格式说明
        public var formatHint: String
    }

    static let formatHint = """
    输出格式：只输出一个 JSON 对象，不要任何解释、不要代码块，字段如下：
    {"category": "上面列表里的一个分类名", "confidence": 0 到 1 的数字, "tags": ["标签1", "标签2"], "summary": "三句话摘要", "key_points": ["要点1", "要点2"]}
    """

    public static func build(_ a: Article, taxonomy t: Taxonomy, existingTags: [String]) -> Built {
        let cats = t.active
        let catLines = cats.map { c in "  - \(c.name)" + ((c.note ?? "").isEmpty ? "" : "：\(c.note!)") }.joined(separator: "\n")
        let tagText = existingTags.isEmpty ? "暂无" : existingTags.joined(separator: "、")
        var system = """
        你是个人文章收藏库的整理助手。读一篇收藏的文章，输出它的分类、标签和摘要。

        - category：从下面的固定列表里选最贴切的一个，实在都不贴切才选「其他」：
        \(catLines)
        - confidence：0 到 1，表示你对这个分类有多确定。文章跨两个类、难以取舍时给 0.6 以下。
        - tags：3 到 8 个，描述内容主题（不要写来源、平台或「摘录」「内容过短」这类对收藏本身的描述）。优先复用已有标签（\(tagText)），意思相同就用已有的写法；新标签用简短名词，专有名词保留原文大小写。
        - summary：正好 3 句中文，说清这篇讲了什么、核心结论或方法、适合什么时候回看。
        - key_points：3 到 5 条要点，每条一句。
        只依据给出的正文，不要补充正文里没有的信息。
        """
        let fixes = t.corrections.suffix(8).filter { c in cats.contains { $0.name == c.to } }
        if !fixes.isEmpty {
            system += "\n\n用户以前手动改过这些文章的分类，体现了他的归类习惯，遇到相似文章按这个习惯来：\n"
            system += fixes.map { c in "- 《\(c.title.prefix(40))》→ \(c.to)" + (c.from.map { "（原先归在「\($0)」）" } ?? "") }.joined(separator: "\n")
        }
        var body = a.blocks.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n")
        if body.count > bodyLimit { body = String(body.prefix(bodyLimit)) }
        let user = "来源：\(sourceLabel(a.source))\n标题：\(a.title)\n作者：\(a.author ?? "")\n\n正文（前 \(bodyLimit) 字）：\n\(body)"
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "category": ["type": "string", "enum": cats.map(\.name)],
                "confidence": ["type": "number"],
                "tags": ["type": "array", "items": ["type": "string"]],
                "summary": ["type": "string"],
                "key_points": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["category", "confidence", "tags", "summary", "key_points"],
            "additionalProperties": false,
        ]
        let schemaJSON = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data()
        return Built(system: system, user: user, schemaJSON: schemaJSON, formatHint: formatHint)
    }

    static func sourceLabel(_ s: Source) -> String {
        switch s {
        case .x: return "X（推特）"
        case .wechat: return "微信公众号"
        case .xhs: return "小红书"
        case .web: return "网页"
        case .clip: return "用户复制下来的一段内容（可能只是片段）"
        }
    }

    /// 宽松解码：不同平台/模型的输出风格不一（数字写成字符串、数组写成一段话），能认就认；只有分类必须有
    struct Raw: Decodable {
        var category: String
        var confidence: Double
        var tags: [String]
        var summary: String
        var key_points: [String]

        enum K: String, CodingKey { case category, confidence, tags, summary, key_points, keyPoints }

        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            category = try c.decode(String.self, forKey: .category).trimmingCharacters(in: .whitespacesAndNewlines)
            if let v = try? c.decode(Double.self, forKey: .confidence) { confidence = v }
            else if let s = try? c.decode(String.self, forKey: .confidence), let v = Double(s.trimmingCharacters(in: .whitespaces)) { confidence = v }
            else { confidence = 0.5 }
            if confidence > 1.5, confidence <= 100 { confidence /= 100 }     // 有的模型给 85 表示 85%（1～1.5 当超了一点，后面截到 1）
            tags = Self.list(c, .tags, split: ",，、;；#")
            summary = (try? c.decode(String.self, forKey: .summary)) ?? ((try? c.decode([String].self, forKey: .summary))?.joined() ?? "")
            let kp = Self.list(c, .key_points, split: "\n")
            key_points = kp.isEmpty ? Self.list(c, .keyPoints, split: "\n") : kp
        }

        static func list(_ c: KeyedDecodingContainer<K>, _ k: K, split: String) -> [String] {
            if let a = try? c.decode([String].self, forKey: k) { return a }
            if let s = try? c.decode(String.self, forKey: k) {
                return s.split(whereSeparator: { split.contains($0) }).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            return []
        }
    }

    /// 从模型输出里取出 JSON 对象：去掉推理模型的 <think> 段、代码块和前后的说明文字
    static func extractJSON(_ text: String) -> String {
        var s = text
        for (open, close) in [("<think>", "</think>"), ("<thinking>", "</thinking>")] {
            while let a = s.range(of: open) {
                if let b = s.range(of: close, range: a.upperBound..<s.endIndex) { s.removeSubrange(a.lowerBound..<b.upperBound) }
                else { s.removeSubrange(a.lowerBound..<s.endIndex) }
            }
        }
        if let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b { return String(s[a...b]) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 模型输出 → 结果。分类名映射回 id；标签按改名表归一、对齐已有写法、去重、最多 8 个
    public static func parse(_ text: String, taxonomy t: Taxonomy, existingTags: [String], model: String, device: String?) throws -> AIResult {
        let s = extractJSON(text)
        guard let d = s.data(using: .utf8), let raw = try? JSONDecoder().decode(Raw.self, from: d), !raw.category.isEmpty else {
            throw AIError.badResponse("不是约定的 JSON：\(text.prefix(80))")
        }
        let catId = t.idForName(raw.category) ?? t.idForName(raw.category.trimmingCharacters(in: CharacterSet(charactersIn: "「」\"'《》"))) ?? Taxonomy.otherId
        return AIResult(
            categoryId: catId,
            categoryName: t.name(catId) ?? raw.category,
            confidence: min(max(raw.confidence, 0), 1),
            tags: normalizeTags(raw.tags, taxonomy: t, existing: existingTags),
            summary: raw.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: raw.key_points.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            model: model, at: Date(), device: device)
    }

    /// 描述收藏本身而不是内容的词，不当标签
    static let metaTags: Set<String> = ["剪藏", "剪贴板", "剪贴板摘录", "摘录", "内容过短", "待补充", "片段", "收藏", "网页", "文章"]

    public static func normalizeTags(_ tags: [String], taxonomy t: Taxonomy, existing: [String]) -> [String] {
        var byLower: [String: String] = [:]
        for e in existing { byLower[e.lowercased()] = byLower[e.lowercased()] ?? e }
        var seen = Set<String>()
        var out: [String] = []
        for var x in tags {
            x = x.trimmingCharacters(in: .whitespacesAndNewlines)
            while x.hasPrefix("#") { x.removeFirst() }
            x = x.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !x.isEmpty, x.count <= 24, !Self.metaTags.contains(x), let c = t.canonicalTag(x) else { continue }
            let final = byLower[c.lowercased()] ?? c
            if seen.insert(final.lowercased()).inserted { out.append(final) }
            if out.count == 8 { break }
        }
        return out
    }
}

// MARK: 分类队列

public struct ClassifyStatus: Sendable, Equatable {
    /// badKey＝要用户改设置才能继续（密钥无效、地址/模型不对、余额不足），具体原因在 message
    public enum Phase: Sendable, Equatable { case idle, disabled, noKey, badKey, running, waiting }
    public var phase: Phase = .idle
    public var pending = 0
    public var current: String?           // 正在分类的标题
    public var retryAt: Date?
    public var message: String?           // 最近一次错误（不含密钥）
    public var done = 0                   // 本次启动以来分好的篇数
    public var lastModel: String?
    public var platform: String?          // 当前平台名（界面显示「连不上 DeepSeek」之类）
    public init() {}
}

/// 分类器：一次一篇。只用设置里选定的一个平台：主模型 → 同平台备用模型依次试；平台不可用就退避排队（文章已经存好，不受影响），绝不自动换平台
public actor Classifier {
    let paths: Paths
    let index: LibraryIndex
    let device: DeviceInfo
    let secretsProvider: @Sendable () -> Secrets
    /// 命令行 --model 用：覆盖设置里的模型链
    public var modelOverride: [String]?

    private var queue: [String] = []
    private var forced = Set<String>()
    private var failCounts: [String: Int]
    private var backoffLevel = 0
    private var badKey = false
    private var running = false
    private var enabled: Bool
    private var status = ClassifyStatus()
    private var handler: (@Sendable (ProcessorEvent) -> Void)?
    private var wakeTask: Task<Void, Never>?
    static let backoff: [TimeInterval] = [60, 300, 900, 1800, 3600]
    static let maxFailures = 3
    /// 别的设备存的文章：收藏 3 分钟后还没有 ai.json 才接手（处理设备会在存好后立刻分类）
    static let adoptAfter: TimeInterval = 180

    private var failURL: URL { paths.local.appendingPathComponent("classify-failures.json") }

    public init(paths: Paths, index: LibraryIndex, device: DeviceInfo, secrets: (@Sendable () -> Secrets)? = nil) {
        self.paths = paths
        self.index = index
        self.device = device
        let p = paths
        secretsProvider = secrets ?? { SecretStore.load(p) }
        enabled = Prefs.load(paths).classifyEnabled
        failCounts = (try? Data(contentsOf: paths.local.appendingPathComponent("classify-failures.json")))
            .flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
    }

    public func setHandler(_ h: @escaping @Sendable (ProcessorEvent) -> Void) { handler = h }
    public func setModels(_ m: [String]) { modelOverride = m.isEmpty ? nil : m }
    public var currentStatus: ClassifyStatus { status }
    public var isEnabled: Bool { enabled }

    public func setEnabled(_ v: Bool) {
        enabled = v
        var p = Prefs.load(paths); p.classifyEnabled = v; p.save(paths)
        if v { Task { await self.scan() } } else { publish() }
    }

    /// 设置里改了平台/密钥/地址/模型：清掉「要改设置」和退避，马上再试
    public func secretsChanged() {
        badKey = false
        backoffLevel = 0
        status.retryAt = nil
        status.message = nil
        kick()
    }

    /// 新存的文章（本机处理的）：排到最前面
    public func enqueue(_ ids: [String], force: Bool = false) {
        for id in ids.reversed() {
            queue.removeAll { $0 == id }
            queue.insert(id, at: 0)
            if force { forced.insert(id); failCounts[id] = nil }
        }
        if force { saveFailures() }
        kick()
    }

    /// 定时扫一遍：还没有 AI 结果的都排上（新的在前）
    public func scan() async {
        let all = await index.all
        let now = Date()
        let missing = all.filter { s in
            s.ai == nil && (failCounts[s.id] ?? 0) < Self.maxFailures && !queue.contains(s.id)
                && now.timeIntervalSince(s.capturedAt) > Self.adoptAfter
        }
        queue += missing.map(\.id)
        kick()
    }

    /// 全部重新分类（设置里的按钮）；返回排进去的篇数
    public func reclassifyAll() async -> Int {
        let ids = await index.all.map(\.id)
        queue = ids
        forced = Set(ids)
        failCounts = [:]
        saveFailures()
        backoffLevel = 0
        status.retryAt = nil
        kick()
        return ids.count
    }

    public func kick() {
        guard !running else { publish(); return }
        running = true
        Task { await self.loop() }
    }

    private func publish() {
        status.pending = queue.count
        if !enabled { status.phase = .disabled }
        else if badKey { status.phase = .badKey }
        handler?(.classifyStatus(status))
    }

    private func loop() async {
        defer { running = false; publish() }
        while true {
            guard enabled else { status.phase = .disabled; return }
            let secrets = secretsProvider()
            status.platform = secrets.active.preset.name
            guard let client = AIClient(secrets: secrets) else { status.phase = .noKey; status.message = secrets.active.missing; return }
            if badKey { status.phase = .badKey; return }
            if let r = status.retryAt, r > Date() {
                status.phase = .waiting
                scheduleWake(r)
                return
            }
            status.retryAt = nil
            guard let id = queue.first else { status.phase = .idle; status.current = nil; return }
            let summary = await index.summary(id)
            if summary == nil && !FileManager.default.fileExists(atPath: paths.folder(for: id).path) {   // 删掉了
                queue.removeFirst(); forced.remove(id); continue
            }
            if let s = summary, s.ai != nil, !forced.contains(id) { queue.removeFirst(); continue }    // 别的设备已经分好

            status.phase = .running
            status.current = summary?.title ?? id
            publish()
            let t0 = Date()
            switch await classifyOne(id, client: client) {
            case .done(let r):
                queue.removeAll { $0 == id }
                forced.remove(id)
                if failCounts.removeValue(forKey: id) != nil { saveFailures() }
                backoffLevel = 0
                status.done += 1
                status.lastModel = r.model
                status.message = nil
                handler?(.classified(id: id, title: summary?.title ?? id, category: r.categoryName,
                                     model: r.model, seconds: Date().timeIntervalSince(t0), lowConfidence: r.lowConfidence))
            case .gone:
                queue.removeAll { $0 == id }
                forced.remove(id)
            case .transient(let msg):
                let delay = Self.backoff[min(backoffLevel, Self.backoff.count - 1)]
                backoffLevel += 1
                status.retryAt = Date().addingTimeInterval(delay)
                status.message = msg
                handler?(.classifyFailed(id: id, message: "\(msg)；\(Int(delay / 60)) 分钟后再试"))
            case .badKey(let msg):
                badKey = true
                status.message = msg
                handler?(.classifyFailed(id: nil, message: msg))
            case .failed(let msg):
                queue.removeAll { $0 == id }
                forced.remove(id)
                failCounts[id, default: 0] += 1
                saveFailures()
                status.message = msg
                handler?(.classifyFailed(id: id, message: "\(msg)（第 \(failCounts[id]!) 次）"))
            }
        }
    }

    private func scheduleWake(_ at: Date) {
        wakeTask?.cancel()
        wakeTask = Task {
            try? await Task.sleep(for: .seconds(max(1, at.timeIntervalSinceNow)))
            if !Task.isCancelled { self.kick() }
        }
    }

    private func saveFailures() { try? JSONEncoder().encode(failCounts).write(to: failURL, options: .atomic) }

    enum Outcome { case done(AIResult), gone, transient(String), badKey(String), failed(String) }

    private func classifyOne(_ id: String, client: AIClient) async -> Outcome {
        let dir = paths.folder(for: id)
        guard let d = await FileIO.read(dir.appendingPathComponent("article.json"), timeout: 20) else {
            return FileManager.default.fileExists(atPath: dir.path) ? .transient("article.json 还没同步下来") : .gone
        }
        guard let art = try? Coders.decoder.decode(Article.self, from: d) else { return .failed("article.json 解析失败") }
        let tax = await index.taxonomy
        let tags = await index.topTags(80)
        let prompt = ClassifyPrompt.build(art, taxonomy: tax, existingTags: tags)
        var lastError: AIError = .config("没填模型")
        var sawTransient = false
        let name = client.platformName
        for model in modelOverride ?? client.config.modelChain {
            do {
                let reply = try await client.call(model: model, system: prompt.system, user: prompt.user, schemaJSON: prompt.schemaJSON,
                                                  schemaName: "classification", formatHint: prompt.formatHint)
                let r = try ClassifyPrompt.parse(reply.text, taxonomy: tax, existingTags: tags, model: reply.model, device: device.name)
                guard FileManager.default.fileExists(atPath: dir.path) else { return .gone }
                do { try AIStore.write(r, dir: dir) } catch { return .transient("写 ai.json 失败：\(error.localizedDescription)") }
                await index.reload(id)
                return .done(r)
            } catch let e as AIError {
                switch e {
                case .unauthorized(let m): return .badKey("\(name) 密钥无效（\(m)）")
                case .config(let m): return .badKey("\(name) \(model)：\(m)")
                case .unreachable(let m): return .transient("连不上 \(name)（\(m)）")
                default:
                    lastError = e
                    if e.transient { sawTransient = true }
                }
            } catch {
                lastError = .badResponse(error.localizedDescription)
            }
        }
        return sawTransient ? .transient("\(name)：\(lastError.description)") : .failed("\(name)：\(lastError.description)")
    }

    /// 命令行用：同步分类一篇，不进队列
    public func classifyNow(_ id: String) async -> Result<AIResult, AIError> {
        let s = secretsProvider()
        guard let client = AIClient(secrets: s) else { return .failure(.config(s.active.missing ?? "设置不完整")) }
        switch await classifyOne(id, client: client) {
        case .done(let r): return .success(r)
        case .gone: return .failure(.badResponse("文章不存在"))
        case .transient(let m), .failed(let m): return .failure(.badResponse(m))
        case .badKey(let m): return .failure(.unauthorized(m))
        }
    }
}
