import Foundation

/// 列表用的文章摘要。文章本身的字段来自 article.json，AI 结果来自 ai.json，已读/星标/手动分类来自 state.json；
/// categoryId / tags / needsReview 是按当前分类表算出来的「实际显示值」。
public struct ArticleSummary: Sendable, Identifiable, Hashable, Codable {
    public var id: String
    public var canonicalId: String
    public var aliases: [String]
    public var source: Source
    public var url: String
    public var title: String
    public var author: String?
    public var authorHandle: String?
    public var site: String?               // 网站域名（去掉 www.）
    public var capturedAt: Date
    public var publishedAt: Date?
    public var chars: Int
    public var images: Int
    public var imagesSaved: Int
    public var videos: Int
    public var excerpt: String
    public var digest: String?             // 平台自带摘要（公众号 digest 等）
    public var coverFile: String?          // 相对文章目录
    public var ai: AIResult?
    public var state = ArticleState()
    public var categoryId: String?         // nil＝还没分类
    public var tags: [String] = []
    public var needsReview = false         // AI 拿不准且用户还没确认
    public var highlights: [String]?       // 「我的摘录」（highlights.json）
    public var extractor: String?          // 解析器版本（老缓存里没有＝未知）
    public var folder: URL = URL(fileURLWithPath: "/")

    enum CodingKeys: String, CodingKey {
        case id, canonicalId, aliases, source, url, title, author, authorHandle, site, capturedAt, publishedAt
        case chars, images, imagesSaved, videos, excerpt, digest, coverFile, ai, state, categoryId, tags, needsReview, highlights, extractor
    }

    public var missingImages: Int { images - imagesSaved }
    public var isRead: Bool { state.isRead }
    public var isStarred: Bool { state.isStarred }
    /// 卡片上的两行摘要：有 AI 摘要用 AI 的
    public var cardSummary: String { ai.map { $0.summary.replacingOccurrences(of: "\n", with: " ") } ?? excerpt }

    init(_ a: Article, folder: URL) {
        id = a.id; canonicalId = a.canonicalId; aliases = a.aliases; source = a.source; url = a.url
        title = a.title.isEmpty ? "（无标题）" : a.title
        author = a.author; authorHandle = a.authorHandle
        if let h = URL(string: a.url)?.host?.lowercased() { site = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h }
        capturedAt = a.capturedAt; publishedAt = a.publishedAt
        chars = a.stats.chars; images = a.stats.images; imagesSaved = a.stats.imagesSaved; videos = a.stats.videos
        let d = a.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        digest = (d ?? "").isEmpty ? nil : String(d!.prefix(400))
        let text = digest ?? a.plainText
        excerpt = String(text.replacingOccurrences(of: "\n", with: " ").prefix(140))
        coverFile = a.cover?.file ?? a.blocks.lazy.compactMap { $0.image?.file ?? $0.video?.cover?.file }.first
        extractor = a.extractor
        self.folder = folder
    }
}

public struct SearchHit: Sendable, Hashable {
    public var id: String
    public var snippet: String?
}

public struct TagCount: Sendable, Hashable {
    public var tag: String
    public var count: Int
}

/// 文件库索引：内存里一份列表，本机 SQLite（<local>/index.sqlite）存列表缓存和全文索引。
/// 启动时先从 SQLite 读（不用解析全部 article.json），再按文件修改时间增量刷新。
public actor LibraryIndex {
    public let paths: Paths
    let deviceId: String

    struct Sig: Equatable {
        var art: Double, ai: Double, state: Double
        var copies: String
        var ex: Double = 0                 // highlights.json（含冲突副本时为 -1，下次必重读）
        var string: String { "\(art)|\(ai)|\(state)|\(copies)|\(ex)" }
        init(art: Double, ai: Double, state: Double, copies: String, ex: Double = 0) {
            self.art = art; self.ai = ai; self.state = state; self.copies = copies; self.ex = ex
        }
        init?(_ s: String) {
            let p = s.split(separator: "|", omittingEmptySubsequences: false)
            guard p.count == 4 || p.count == 5, let a = Double(p[0]), let b = Double(p[1]), let c = Double(p[2]) else { return nil }
            art = a; ai = b; state = c; copies = String(p[3])
            ex = p.count == 5 ? Double(p[4]) ?? 0 : 0
        }
    }
    struct Entry { var summary: ArticleSummary; var sig: Sig }

    private var store: SearchStore?
    private var entries: [String: Entry] = [:]
    private var aliasMap: [String: String] = [:]     // 去重键/别名 → id
    public private(set) var taxonomy = Taxonomy()
    private var taxSig: String?

    public init(paths: Paths, deviceId: String = "") {
        self.paths = paths
        self.deviceId = deviceId
        try? FileManager.default.createDirectory(at: paths.local, withIntermediateDirectories: true)
        let st = try? SearchStore(url: paths.local.appendingPathComponent("index.sqlite"))
        store = st
        var es: [String: Entry] = [:]
        var am: [String: String] = [:]
        let dec = JSONDecoder()
        for row in st?.loadAll() ?? [] {
            guard let sig = Sig(row.sig), var s = try? dec.decode(ArticleSummary.self, from: row.summary) else { continue }
            s.folder = paths.folder(for: row.id)
            es[row.id] = Entry(summary: s, sig: sig)
            for k in [s.canonicalId] + s.aliases { am[k] = row.id }
        }
        entries = es
        aliasMap = am
    }

    public var all: [ArticleSummary] { entries.values.map(\.summary).sorted { $0.capturedAt > $1.capturedAt } }
    public var count: Int { entries.count }
    public var hasSearchIndex: Bool { store != nil }

    public func summary(_ id: String) -> ArticleSummary? { entries[id]?.summary }

    /// 收藏时查重：文件夹存在（不需要先下载 article.json）或别名命中
    public func lookup(key: String) -> String? {
        let id = Capture.hash(key)
        if entries[id] != nil || FileManager.default.fileExists(atPath: paths.folder(for: id).path) { return id }
        return aliasMap[key]
    }

    public func title(_ id: String) -> String { entries[id]?.summary.title ?? "（同步中）" }

    // MARK: 刷新

    /// 扫描 Library/*/*/：article.json / ai.json / state.json 任一变化就更新这一篇；分类表变了全部重算。返回是否有变化
    @discardableResult
    public func refresh() -> Bool {
        var changed = reloadTaxonomyIfNeeded()
        let fm = FileManager.default
        var seen = Set<String>()
        store?.begin()
        defer { store?.commit() }
        let prefixes = (try? fm.contentsOfDirectory(atPath: paths.library.path)) ?? []
        for p in prefixes where p.count == 2 {
            let pdir = paths.library.appendingPathComponent(p)
            for id in (try? fm.contentsOfDirectory(atPath: pdir.path)) ?? [] where Inbox.isHashName(id) {
                switch scan(id, dir: pdir.appendingPathComponent(id)) {
                case .missing: continue
                case .unchanged: seen.insert(id)
                case .changed: seen.insert(id); changed = true
                }
            }
        }
        for id in entries.keys where !seen.contains(id) { drop(id); changed = true }
        return changed
    }

    /// 重新读一篇（合并了别名、补抓了图、写了 ai.json 之后）
    public func reload(_ id: String) {
        _ = scan(id, dir: paths.folder(for: id), force: true)
    }

    public func add(_ art: Article) { reload(art.id) }

    enum ScanResult { case missing, unchanged, changed }

    private static func mtime(_ u: URL) -> Double? {
        (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date)?.timeIntervalSince1970
    }

    private func scan(_ id: String, dir: URL, force: Bool = false) -> ScanResult {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for n in ["article.json", AIStore.fileName, StateStore.fileName, HighlightStore.fileName] where names.contains(".\(n).icloud") {
            try? fm.startDownloadingUbiquitousItem(at: dir.appendingPathComponent(n))      // iCloud 占位文件：先触发下载
        }
        let file = dir.appendingPathComponent("article.json")
        guard names.contains("article.json"), let artM = Self.mtime(file) else { return .missing }
        let aiM = names.contains(AIStore.fileName) ? Self.mtime(dir.appendingPathComponent(AIStore.fileName)) ?? 0 : 0
        let stateFile = dir.appendingPathComponent(StateStore.fileName)
        let copies = names.filter { ConflictCopies.isCopy($0, base: "state", ext: "json") }.sorted()
        let hlFile = dir.appendingPathComponent(HighlightStore.fileName)
        let hlCopies = names.contains { ConflictCopies.isCopy($0, base: "highlights", ext: "json") }
        let exM = hlCopies ? -1 : (names.contains(HighlightStore.fileName) ? Self.mtime(hlFile) ?? 0 : 0)
        var sig = Sig(art: artM, ai: aiM, state: names.contains(StateStore.fileName) ? Self.mtime(stateFile) ?? 0 : 0,
                      copies: copies.joined(separator: ","), ex: exM)
        let old = entries[id]
        if !force, let old, old.sig == sig { return .unchanged }

        var s: ArticleSummary
        var body: String?
        if force || old == nil || old!.sig.art != sig.art {
            guard let d = try? Data(contentsOf: file), let art = try? Coders.decoder.decode(Article.self, from: d) else {
                return old == nil ? .missing : .unchanged
            }
            s = ArticleSummary(art, folder: dir)
            body = art.plainText
        } else {
            s = old!.summary
        }
        s.ai = (force || old == nil || old!.sig.ai != sig.ai) ? (aiM > 0 ? AIStore.load(dir: dir) : nil) : old!.summary.ai
        if force || old == nil || old!.sig.state != sig.state || old!.sig.copies != sig.copies {
            s.state = StateStore.load(dir: dir, names: names)
            if !copies.isEmpty { sig.state = Self.mtime(stateFile) ?? 0; sig.copies = "" }     // 冲突副本已合并删除
        } else {
            s.state = old!.summary.state
        }
        if force || old == nil || old!.sig.ex != sig.ex || sig.ex < 0 {
            let hs = (exM != 0) ? HighlightStore.load(dir: dir, names: names).map(\.text) : []
            s.highlights = hs.isEmpty ? nil : hs
            if hlCopies { sig.ex = Self.mtime(hlFile) ?? 0 }        // 冲突副本已合并删除
        } else {
            s.highlights = old!.summary.highlights
        }
        // 正文没变时 body 为 nil，写索引时沿用库里存的正文；摘录进 summary 列
        put(s, sig: sig, body: body)
        return .changed
    }

    private func resolved(_ s0: ArticleSummary) -> ArticleSummary {
        var s = s0
        s.categoryId = taxonomy.effectiveCategory(ai: s.ai, state: s.state)
        s.tags = taxonomy.effectiveTags(ai: s.ai, state: s.state)
        s.needsReview = (s.ai?.lowConfidence ?? false) && s.state.userCategory == nil
        return s
    }

    private func doc(_ s: ArticleSummary, body: String?) -> SearchDoc {
        SearchDoc(
            title: s.title,
            author: [s.author, s.authorHandle, s.site].compactMap { $0 }.joined(separator: " "),
            tags: s.tags.joined(separator: " "),
            summary: [s.ai?.summary, s.ai?.keyPoints.joined(separator: "\n"), s.digest, s.highlights?.joined(separator: "\n")]
                .compactMap { $0 }.joined(separator: "\n"),
            body: body)
    }

    private func put(_ s0: ArticleSummary, sig: Sig, body: String?) {
        let s = resolved(s0)
        if let old = entries[s.id] { for k in [old.summary.canonicalId] + old.summary.aliases where aliasMap[k] == s.id { aliasMap[k] = nil } }
        entries[s.id] = Entry(summary: s, sig: sig)
        for k in [s.canonicalId] + s.aliases { aliasMap[k] = s.id }
        if let store, let data = try? JSONEncoder().encode(s) {
            try? store.upsert(id: s.id, sig: sig.string, summary: data, doc: doc(s, body: body))
        }
    }

    private func drop(_ id: String) {
        guard let e = entries.removeValue(forKey: id) else { return }
        for k in [e.summary.canonicalId] + e.summary.aliases where aliasMap[k] == id { aliasMap[k] = nil }
        store?.delete(id)
    }

    /// 删除＝移到废纸篓（iCloud 文件夹里删除会同步到所有设备；废纸篓里还能找回）
    public func trash(_ id: String) throws {
        let dir = paths.folder(for: id)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.trashItem(at: dir, resultingItemURL: nil) }
        drop(id)
    }

    // MARK: 分类表

    /// Config 里的文件变了（本机改的或别的设备同步来的）：重读并重算每篇的实际分类/标签
    private func reloadTaxonomyIfNeeded() -> Bool {
        let sig = TaxonomyStore.signature(paths)
        guard sig != taxSig else { return false }
        let t = TaxonomyStore.load(paths)
        taxSig = TaxonomyStore.signature(paths)        // load 可能写了默认表/合并了冲突
        guard t != taxonomy else { return false }
        taxonomy = t
        return resolveAll()
    }

    @discardableResult
    private func resolveAll() -> Bool {
        var changed = false
        store?.begin()
        defer { store?.commit() }
        for e in entries.values {
            let r = resolved(e.summary)
            guard r.categoryId != e.summary.categoryId || r.tags != e.summary.tags || r.needsReview != e.summary.needsReview else { continue }
            put(e.summary, sig: e.sig, body: nil)
            changed = true
        }
        return changed
    }

    private func taxonomyChanged() {
        taxSig = TaxonomyStore.signature(paths)
        resolveAll()
    }

    /// 读一遍分类表（设置页打开时用，顺便接住别的设备的修改）
    public func currentTaxonomy() -> Taxonomy {
        if reloadTaxonomyIfNeeded() {}
        return taxonomy
    }

    public enum TaxonomyError: Error, CustomStringConvertible {
        case emptyName, duplicate(String), protected, badTarget
        public var description: String {
            switch self {
            case .emptyName: return "名称不能为空"
            case .duplicate(let n): return "已经有叫「\(n)」的分类了"
            case .protected: return "「其他」不能删除"
            case .badTarget: return "要并入的分类不存在"
            }
        }
    }

    private func cleanName(_ n: String) -> String { n.trimmingCharacters(in: .whitespacesAndNewlines) }

    @discardableResult
    public func addCategory(name: String, note: String?) throws -> String {
        _ = reloadTaxonomyIfNeeded()
        let n = cleanName(name)
        guard !n.isEmpty else { throw TaxonomyError.emptyName }
        guard !taxonomy.active.contains(where: { $0.name == n }) else { throw TaxonomyError.duplicate(n) }
        var cats = taxonomy.categories
        let id = TaxonomyStore.newCategoryId()
        let c = Category(id: id, name: n, note: cleanNote(note), updatedAt: Date())
        if let i = cats.firstIndex(where: { $0.id == Taxonomy.otherId }) { cats.insert(c, at: i) } else { cats.append(c) }   // 「其他」始终在最后
        try saveCategories(cats)
        return id
    }

    private func cleanNote(_ n: String?) -> String? {
        let t = n?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    public func updateCategory(_ id: String, name: String, note: String?) throws {
        _ = reloadTaxonomyIfNeeded()
        let n = cleanName(name)
        guard !n.isEmpty else { throw TaxonomyError.emptyName }
        guard !taxonomy.active.contains(where: { $0.name == n && $0.id != id }) else { throw TaxonomyError.duplicate(n) }
        var cats = taxonomy.categories
        guard let i = cats.firstIndex(where: { $0.id == id }) else { return }
        let oldName = cats[i].name
        cats[i].name = n
        cats[i].note = cleanNote(note)
        cats[i].updatedAt = Date()
        try saveCategories(cats)
        if oldName != n {      // 纠正样例里的分类名跟着改
            var fixes = taxonomy.corrections
            for j in fixes.indices {
                if fixes[j].to == oldName { fixes[j].to = n }
                if fixes[j].from == oldName { fixes[j].from = n }
            }
            try? saveCorrections(fixes)
        }
    }

    public func reorderCategories(_ ids: [String]) throws {
        _ = reloadTaxonomyIfNeeded()
        var cats = taxonomy.categories
        let pos = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        cats.sort { (pos[$0.id] ?? Int.max) < (pos[$1.id] ?? Int.max) }
        let now = Date()
        for i in cats.indices where ids.contains(cats[i].id) { cats[i].updatedAt = now }
        try saveCategories(cats)
    }

    /// 删除分类：标记停用并指定并入哪个分类（已归在这类的文章、AI 结果都跟着走，不用改文件）
    public func deleteCategory(_ id: String, mergeInto target: String) throws {
        _ = reloadTaxonomyIfNeeded()
        guard id != Taxonomy.otherId else { throw TaxonomyError.protected }
        guard target != id, taxonomy.category(target)?.isActive == true else { throw TaxonomyError.badTarget }
        var cats = taxonomy.categories
        guard let i = cats.firstIndex(where: { $0.id == id }) else { return }
        cats[i].retired = true
        cats[i].mergedInto = target
        cats[i].updatedAt = Date()
        try saveCategories(cats)
    }

    private func saveCategories(_ cats: [Category]) throws {
        try TaxonomyStore.save(categories: cats, paths)
        taxonomy.categories = cats
        taxonomyChanged()
    }

    private func saveCorrections(_ c: [Correction]) throws {
        try TaxonomyStore.save(corrections: c, paths)
        taxonomy.corrections = Array(c.suffix(50))
        taxSig = TaxonomyStore.signature(paths)
    }

    /// 标签改名/合并（新名已存在＝合并）
    public func renameTag(_ old: String, to new: String) throws {
        _ = reloadTaxonomyIfNeeded()
        let o = old.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !o.isEmpty else { return }
        guard !n.isEmpty else { throw TaxonomyError.emptyName }
        guard o != n else { return }
        var a = taxonomy.tagAliases
        for k in a.keys where k.lowercased() == n.lowercased() { a[k] = nil }        // 防止改回去时成环
        for (k, v) in a where v.lowercased() == o.lowercased() { a[k] = n }          // 以前并到旧名的，也指向新名
        a[o] = n          // 只改大小写也走这里：canonicalTag 先查精确写法
        try saveAliases(a)
    }

    public func deleteTag(_ t: String) throws {
        _ = reloadTaxonomyIfNeeded()
        let o = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !o.isEmpty else { return }
        var a = taxonomy.tagAliases
        for (k, v) in a where v.lowercased() == o.lowercased() { a[k] = "" }
        a[o] = ""
        try saveAliases(a)
    }

    private func saveAliases(_ a: [String: String]) throws {
        try TaxonomyStore.save(tagAliases: a, paths)
        taxonomy.tagAliases = a
        taxonomyChanged()
    }

    // MARK: 已读 / 星标 / 手动分类 / 手动标签（写 state.json，每个字段带时间，多设备按字段合并）

    private func mutateState(_ id: String, _ f: (inout ArticleState) -> Void) {
        let dir = paths.folder(for: id)
        guard var e = entries[id], FileManager.default.fileExists(atPath: dir.path),
              let st = try? StateStore.update(dir: dir, f) else { return }
        e.summary.state = st
        e.sig.state = Self.mtime(dir.appendingPathComponent(StateStore.fileName)) ?? e.sig.state
        e.sig.copies = ""
        put(e.summary, sig: e.sig, body: nil)
    }

    public func setRead(_ ids: [String], _ v: Bool) {
        let dev = deviceId
        for id in ids where entries[id] != nil && entries[id]!.summary.isRead != v {
            mutateState(id) { $0.read = Stamped(v, device: dev) }
        }
    }

    public func setStarred(_ id: String, _ v: Bool) {
        let dev = deviceId
        mutateState(id) { $0.starred = Stamped(v, device: dev) }
    }

    /// 手动改分类（nil＝恢复跟随 AI）。和 AI 给的不一样就记成纠正样例，下次分类时告诉 AI
    public func setCategory(_ id: String, _ cat: String?) {
        guard let e = entries[id] else { return }
        let dev = deviceId
        mutateState(id) { $0.category = Stamped(cat, device: dev) }
        guard let cat, let to = taxonomy.name(cat) else { return }
        let aiCat = e.summary.ai.flatMap { taxonomy.resolve($0.categoryId) ?? taxonomy.idForName($0.categoryName) }
        var fixes = taxonomy.corrections.filter { $0.title != e.summary.title }      // 同一篇改了又改，只留最后一次
        if let aiCat, aiCat == taxonomy.resolve(cat) {
            if fixes.count != taxonomy.corrections.count { try? saveCorrections(fixes) }
            return
        }
        fixes.append(Correction(title: e.summary.title, from: e.summary.ai?.categoryName, to: to, at: Date()))
        try? saveCorrections(fixes)
    }

    /// 「待确认」里点确认：把 AI 给的分类定下来
    public func confirmCategory(_ id: String) {
        guard let e = entries[id], let c = e.summary.categoryId else { return }
        let dev = deviceId
        mutateState(id) { $0.category = Stamped(c, device: dev) }
    }

    /// 手动编辑标签（nil＝恢复 AI 标签）
    public func setTags(_ id: String, _ tags: [String]?) {
        let dev = deviceId
        let clean: [String]? = tags.map { list in
            var seen = Set<String>()
            return list.compactMap { t -> String? in
                var x = t.trimmingCharacters(in: .whitespacesAndNewlines)
                while x.hasPrefix("#") { x.removeFirst() }
                x = x.trimmingCharacters(in: .whitespaces)
                guard !x.isEmpty, x.count <= 24, seen.insert(x.lowercased()).inserted else { return nil }
                return x
            }
        }
        mutateState(id) { $0.tags = Stamped(clean, device: dev) }
    }

    // MARK: 查询

    public func tagCounts() -> [TagCount] {
        var n: [String: Int] = [:]
        for e in entries.values { for t in e.summary.tags { n[t, default: 0] += 1 } }
        return n.map { TagCount(tag: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }

    public func topTags(_ limit: Int) -> [String] { Array(tagCounts().prefix(limit).map(\.tag)) }

    /// 全文搜索：标题/作者/标签/摘要/正文。返回按相关度排序的结果，前 snippets 条带正文片段
    public func search(_ raw: String, snippets: Int = 100) -> [SearchHit] {
        guard let q = SearchText.query(raw) else { return [] }
        guard let store else {       // 索引打不开：退回内存里的子串匹配
            let terms = q.terms
            return all.filter { s in
                let hay = SearchText.normalize([s.title, s.author ?? "", s.tags.joined(separator: " "), s.cardSummary].joined(separator: "\n"))
                return terms.allSatisfy { hay.contains($0) }
            }.map { SearchHit(id: $0.id, snippet: nil) }
        }
        let ids = store.search(q).filter { entries[$0] != nil }
        return ids.enumerated().map { i, id in
            SearchHit(id: id, snippet: i < snippets ? store.body(id).flatMap { SearchText.snippet($0, terms: q.terms) } : nil)
        }
    }
}
