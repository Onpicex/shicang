import Foundation

/// 一级分类。id 稳定（改名不影响已分类的文章），删除＝标记 retired 并指定并入哪个分类。
public struct Category: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var note: String?          // 给 AI 看的边界说明（可空）
    public var retired: Bool?
    public var mergedInto: String?
    public var updatedAt: Date

    public init(id: String, name: String, note: String? = nil, updatedAt: Date = Date(timeIntervalSince1970: 0)) {
        self.id = id; self.name = name; self.note = note; self.updatedAt = updatedAt
    }
    public var isActive: Bool { retired != true }
}

/// 手动改分类的记录：下次分类时作为样例告诉 AI
public struct Correction: Codable, Sendable, Hashable {
    public var title: String
    public var from: String?          // AI 原来给的分类名
    public var to: String             // 用户改成的分类名
    public var at: Date
}

/// Config/ 下三份文件：categories.json（分类表）、tags.json（标签改名/合并表）、corrections.json（手动纠正样例）
public struct Taxonomy: Sendable, Equatable {
    public var categories: [Category]
    public var tagAliases: [String: String]     // 旧名/同义词 → 现名（"" 表示删除这个标签）
    public var corrections: [Correction]

    public static let otherId = "other"

    /// 初版 10 类（P0 定的，设置里可改）
    public static let defaultCategories: [Category] = [
        Category(id: "ai", name: "AI 与大模型", note: "大模型、提示词、AI 产品与 Agent、AI 行业动态"),
        Category(id: "dev", name: "编程与开发", note: "编程语言、框架、开源项目、架构、开发工具"),
        Category(id: "tools", name: "网络与效率工具", note: "软件技巧、效率工具、代理/网络/SSH、自动化"),
        Category(id: "crypto", name: "加密货币与区块链", note: "币、链上数据、DeFi、交易所、Meme"),
        Category(id: "invest", name: "投资理财", note: "股票、基金、宏观经济、财报、交易策略与指标（加密货币除外）"),
        Category(id: "tech", name: "科技产品与行业", note: "硬件、手机电脑、科技公司动态（不以 AI 为主）"),
        Category(id: "biz", name: "商业与创业", note: "公司经营、产品、营销、创业故事"),
        Category(id: "growth", name: "思维与个人成长", note: "认知、学习方法、写作、职业发展"),
        Category(id: "life", name: "生活与健康", note: "健康、饮食、运动、家庭、旅行"),
        Category(id: otherId, name: "其他", note: nil),
    ]

    public init(categories: [Category] = Taxonomy.defaultCategories, tagAliases: [String: String] = [:], corrections: [Correction] = []) {
        self.categories = categories; self.tagAliases = tagAliases; self.corrections = corrections
    }

    public var active: [Category] { categories.filter(\.isActive) }

    public func category(_ id: String?) -> Category? { id.flatMap { i in categories.first { $0.id == i } } }

    /// 跟着 mergedInto 走到一个还在用的分类；找不到返回 nil
    public func resolve(_ id: String?) -> String? {
        var cur = id
        for _ in 0..<12 {
            guard let c = category(cur) else { return nil }
            if c.isActive { return c.id }
            cur = c.mergedInto ?? Self.otherId
        }
        return nil
    }

    public func idForName(_ name: String?) -> String? {
        guard let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return nil }
        return resolve((categories.first { $0.name == n && $0.isActive } ?? categories.first { $0.name == n })?.id)
    }

    public func name(_ id: String?) -> String? { category(resolve(id))?.name }

    /// 一篇文章实际显示的分类：手动指定 > AI；都没有＝未分类
    public func effectiveCategory(ai: AIResult?, state: ArticleState) -> String? {
        if let u = state.userCategory, let r = resolve(u) { return r }
        guard let ai else { return nil }
        return resolve(ai.categoryId) ?? idForName(ai.categoryName) ?? Self.otherId
    }

    /// 标签现名（沿着改名表走；返回 nil 表示这个标签被删了）
    public func canonicalTag(_ t: String) -> String? {
        var cur = t.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<12 {
            guard let next = alias(for: cur) else { break }
            if next.isEmpty { return nil }
            if next == cur { break }
            cur = next
        }
        return cur.isEmpty ? nil : cur
    }

    private func alias(for t: String) -> String? {
        if let v = tagAliases[t] { return v }
        let l = t.lowercased()
        return tagAliases.first { $0.key.lowercased() == l }?.value
    }

    /// 改名/合并后去重（不区分大小写，保留第一次出现的写法）
    public func canonicalTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for t in tags {
            guard let c = canonicalTag(t) else { continue }
            if seen.insert(c.lowercased()).inserted { out.append(c) }
        }
        return out
    }

    public func effectiveTags(ai: AIResult?, state: ArticleState) -> [String] {
        canonicalTags(state.userTags ?? ai?.tags ?? [])
    }
}

public enum TaxonomyStore {
    static func categoriesURL(_ p: Paths) -> URL { p.config.appendingPathComponent("categories.json") }
    static func tagsURL(_ p: Paths) -> URL { p.config.appendingPathComponent("tags.json") }
    static func correctionsURL(_ p: Paths) -> URL { p.config.appendingPathComponent("corrections.json") }

    struct CategoryFile: Codable { var schema = 1; var updatedAt: Date; var categories: [Category] }
    struct TagFile: Codable { var schema = 1; var updatedAt: Date; var aliases: [String: String] }
    struct CorrectionFile: Codable { var schema = 1; var corrections: [Correction] }

    /// 三个文件的修改时间（变了才重读）
    public static func signature(_ p: Paths) -> String {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: p.config.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().map { n -> String in
            let m = (try? fm.attributesOfItem(atPath: p.config.appendingPathComponent(n).path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(n)@\(m)"
        }.joined(separator: "|")
    }

    /// 读配置；分类表不存在就写入初版。iCloud 冲突副本按 id 合并（每个分类取 updatedAt 新的）
    public static func load(_ p: Paths) -> Taxonomy {
        let fm = FileManager.default
        let dec = Coders.decoder
        var t = Taxonomy()

        let cURL = categoriesURL(p)
        let cCopies = ConflictCopies.find(in: p.config, base: "categories", ext: "json")
        let cVersions = ConflictCopies.unresolvedVersions(of: cURL)
        var files: [CategoryFile] = []
        if let d = try? Data(contentsOf: cURL), let f = try? dec.decode(CategoryFile.self, from: d) { files.append(f) }
        for c in cCopies { if let d = try? Data(contentsOf: c), let f = try? dec.decode(CategoryFile.self, from: d) { files.append(f) } }
        for v in cVersions { if let f = try? dec.decode(CategoryFile.self, from: v.data) { files.append(f) } }
        if files.isEmpty {
            let placeholder = p.config.appendingPathComponent(".categories.json.icloud")
            if fm.fileExists(atPath: placeholder.path) {
                try? fm.startDownloadingUbiquitousItem(at: cURL)      // 别的设备建过，还没下载：先用默认，不写
            } else {
                try? save(categories: t.categories, p)
            }
        } else {
            let merged = mergeCategoryFiles(files)
            t.categories = merged
            if files.count > 1 {
                try? save(categories: merged, p)
                for c in cCopies { try? fm.removeItem(at: c) }
                ConflictCopies.markResolved(cURL, cVersions.map(\.version))
            }
        }

        let tURL = tagsURL(p)
        let tCopies = ConflictCopies.find(in: p.config, base: "tags", ext: "json")
        var tagFiles: [TagFile] = []
        if let d = try? Data(contentsOf: tURL), let f = try? dec.decode(TagFile.self, from: d) { tagFiles.append(f) }
        for c in tCopies { if let d = try? Data(contentsOf: c), let f = try? dec.decode(TagFile.self, from: d) { tagFiles.append(f) } }
        for f in tagFiles.sorted(by: { $0.updatedAt < $1.updatedAt }) { t.tagAliases.merge(f.aliases) { _, new in new } }
        if !tCopies.isEmpty {
            try? save(tagAliases: t.tagAliases, p)
            for c in tCopies { try? fm.removeItem(at: c) }
        }

        if let d = try? Data(contentsOf: correctionsURL(p)), let f = try? dec.decode(CorrectionFile.self, from: d) {
            t.corrections = f.corrections
        }
        return t
    }

    static func mergeCategoryFiles(_ files: [CategoryFile]) -> [Category] {
        let newest = files.max { $0.updatedAt < $1.updatedAt }!
        var byId: [String: Category] = [:]
        for f in files {
            for c in f.categories {
                if let old = byId[c.id], old.updatedAt >= c.updatedAt { continue }
                byId[c.id] = c
            }
        }
        var order = newest.categories.map(\.id)
        for f in files { for c in f.categories where !order.contains(c.id) { order.append(c.id) } }
        return order.compactMap { byId[$0] }
    }

    public static func save(categories: [Category], _ p: Paths) throws {
        try FileManager.default.createDirectory(at: p.config, withIntermediateDirectories: true)
        try Coders.encoder.encode(CategoryFile(updatedAt: Date(), categories: categories)).write(to: categoriesURL(p), options: .atomic)
    }

    public static func save(tagAliases: [String: String], _ p: Paths) throws {
        try FileManager.default.createDirectory(at: p.config, withIntermediateDirectories: true)
        try Coders.encoder.encode(TagFile(updatedAt: Date(), aliases: tagAliases)).write(to: tagsURL(p), options: .atomic)
    }

    public static func save(corrections: [Correction], _ p: Paths) throws {
        try FileManager.default.createDirectory(at: p.config, withIntermediateDirectories: true)
        try Coders.encoder.encode(CorrectionFile(corrections: Array(corrections.suffix(50)))).write(to: correctionsURL(p), options: .atomic)
    }

    public static func newCategoryId() -> String { "c" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(7) }
}
