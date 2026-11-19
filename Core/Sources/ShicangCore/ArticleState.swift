import Foundation

/// 带修改时间的字段：两台设备各改各的，合并时每个字段取时间新的那份
public struct Stamped<T: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    public var value: T
    public var at: Date
    public var device: String?

    public init(_ value: T, at: Date = Date(), device: String? = nil) {
        self.value = value; self.at = at; self.device = device
    }

    /// 时间新的赢；时间相同按设备 id 定一个确定的赢家（两台设备合并结果一致）
    static func newer(_ a: Stamped?, _ b: Stamped?) -> Stamped? {
        guard let a else { return b }
        guard let b else { return a }
        if a.at != b.at { return a.at > b.at ? a : b }
        return (a.device ?? "") >= (b.device ?? "") ? a : b
    }
}

/// 每篇文章的 state.json：已读/星标/手动分类/手动标签。article.json 只写一次，用户的改动都在这里。
public struct ArticleState: Codable, Sendable, Hashable {
    public var schema: Int = 1
    public var read: Stamped<Bool>?
    public var starred: Stamped<Bool>?
    /// 手动指定的分类 id；value 为 nil＝恢复跟随 AI（也要带时间，别的设备才知道这是更新的决定）
    public var category: Stamped<String?>?
    /// 手动编辑后的完整标签列表；value 为 nil＝恢复 AI 标签
    public var tags: Stamped<[String]?>?

    public init() {}

    public var isRead: Bool { read?.value ?? false }
    public var isStarred: Bool { starred?.value ?? false }
    public var userCategory: String? { category?.value ?? nil }
    public var userTags: [String]? { tags?.value ?? nil }
    public var isEmpty: Bool { read == nil && starred == nil && category == nil && tags == nil }

    public func merged(with o: ArticleState) -> ArticleState {
        var r = ArticleState()
        r.read = Stamped.newer(read, o.read)
        r.starred = Stamped.newer(starred, o.starred)
        r.category = Stamped.newer(category, o.category)
        r.tags = Stamped.newer(tags, o.tags)
        return r
    }
}

/// iCloud 冲突副本：两台设备同时改同一个文件时，会多出「state 2.json」这样的文件
public enum ConflictCopies {
    /// base = "state"、ext = "json" → 认「state 2.json」「state (1).json」「state 的副本.json」「state copy.json」
    public static func isCopy(_ name: String, base: String, ext: String) -> Bool {
        guard name != "\(base).\(ext)", name.hasPrefix(base + " "), name.hasSuffix("." + ext) else { return false }
        let mid = name.dropFirst(base.count + 1).dropLast(ext.count + 1)
        guard !mid.isEmpty else { return false }
        if mid.allSatisfy(\.isNumber) { return true }
        if mid.hasPrefix("("), mid.hasSuffix(")"), mid.dropFirst().dropLast().allSatisfy(\.isNumber) { return true }
        return mid.contains("副本") || mid.lowercased().contains("copy") || mid.contains("conflict")
    }

    public static func find(in dir: URL, base: String, ext: String, names: [String]? = nil) -> [URL] {
        let all = names ?? ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        return all.filter { isCopy($0, base: base, ext: ext) }.sorted().map { dir.appendingPathComponent($0) }
    }

    /// 系统登记的「未解决冲突版本」（NSFileVersion），读出来交给调用方合并，然后标记已解决并删掉
    public static func unresolvedVersions(of file: URL) -> [(data: Data, version: NSFileVersion)] {
        guard FileManager.default.fileExists(atPath: file.path),
              let vs = NSFileVersion.unresolvedConflictVersionsOfItem(at: file), !vs.isEmpty else { return [] }
        return vs.compactMap { v in (try? Data(contentsOf: v.url)).map { ($0, v) } }
    }

    public static func markResolved(_ file: URL, _ versions: [NSFileVersion]) {
        guard !versions.isEmpty else { return }
        for v in versions { v.isResolved = true }
        try? NSFileVersion.removeOtherVersionsOfItem(at: file)
    }
}

public enum StateStore {
    public static let fileName = "state.json"

    static func decode(_ d: Data) -> ArticleState? { try? Coders.decoder.decode(ArticleState.self, from: d) }

    /// 读 state.json；有冲突副本时一并合并、写回、删掉副本（resolve = false 时只读不改）
    public static func load(dir: URL, names: [String]? = nil, resolve: Bool = true) -> ArticleState {
        let file = dir.appendingPathComponent(fileName)
        var state = (try? Data(contentsOf: file)).flatMap(decode) ?? ArticleState()
        guard resolve else { return state }
        let copies = ConflictCopies.find(in: dir, base: "state", ext: "json", names: names)
        let versions = ConflictCopies.unresolvedVersions(of: file)
        guard !copies.isEmpty || !versions.isEmpty else { return state }
        for c in copies { if let s = (try? Data(contentsOf: c)).flatMap(decode) { state = state.merged(with: s) } }
        for v in versions { if let s = decode(v.data) { state = state.merged(with: s) } }
        do {
            try write(state, dir: dir)
            for c in copies { try? FileManager.default.removeItem(at: c) }
            ConflictCopies.markResolved(file, versions.map(\.version))
        } catch {}
        return state
    }

    public static func write(_ s: ArticleState, dir: URL) throws {
        try Coders.encoder.encode(s).write(to: dir.appendingPathComponent(fileName), options: .atomic)
    }

    /// 改一个字段：先读（含合并冲突），改完原子写回
    @discardableResult
    public static func update(dir: URL, _ mutate: (inout ArticleState) -> Void) throws -> ArticleState {
        var s = load(dir: dir)
        mutate(&s)
        try write(s, dir: dir)
        return s
    }
}
