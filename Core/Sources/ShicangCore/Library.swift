import Foundation

/// 写文件库：先在本机暂存目录写完整个文件夹，再一次 rename 进 iCloud 的 Library（别的设备不会看到半成品）
public struct LibraryWriter: Sendable {
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public enum Outcome: Sendable {
        case saved(Article, imageFailures: [String])
        case merged(id: String, title: String)      // 目录已存在（别的设备/别的短链已存过）：只合并别名
    }

    public func save(_ ex: Extraction) async throws -> Outcome {
        var art = ex.article
        art.imageReferer = ex.imageReferer
        let final = paths.folder(for: art.id)
        if FileManager.default.fileExists(atPath: final.path) { return try merge(into: final, art) }

        let stage = paths.staging.appendingPathComponent("\(art.id)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }

        let failures = await ImageFetcher.fetchAll(&art, into: stage, referer: ex.imageReferer)
        try Self.writeFiles(art, to: stage)
        for (name, data) in ex.rawSnapshots {
            try Gzip.compress(data).write(to: stage.appendingPathComponent(name + ".gz"), options: .atomic)
        }
        try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: stage, to: final)
        } catch {
            if fm.fileExists(atPath: final.path) { return try merge(into: final, art) }   // 刚好被别的设备抢先
            throw error
        }
        return .saved(art, imageFailures: failures)
    }

    static func writeFiles(_ art: Article, to dir: URL) throws {
        try Coders.encoder.encode(art).write(to: dir.appendingPathComponent("article.json"), options: .atomic)
        try Markdown.render(art).write(to: dir.appendingPathComponent("article.md"), atomically: true, encoding: .utf8)
    }

    func merge(into dir: URL, _ new: Article) throws -> Outcome {
        let file = dir.appendingPathComponent("article.json")
        guard let data = try? Data(contentsOf: file), var old = try? Coders.decoder.decode(Article.self, from: data) else {
            return .merged(id: new.id, title: new.title)     // 还没同步下来：文件夹在就算已存在
        }
        let extra = ([new.canonicalId] + new.aliases).filter { $0 != old.canonicalId && !old.aliases.contains($0) }
        if !extra.isEmpty {
            old.aliases += extra
            try Coders.encoder.encode(old).write(to: file, options: .atomic)
        }
        return .merged(id: old.id, title: old.title)
    }

    /// 补抓缺图：只下载 file == nil 的，成功的写回 article.json / article.md
    public func repairImages(id: String) async -> (fixed: Int, missing: Int)? {
        let dir = paths.folder(for: id)
        let file = dir.appendingPathComponent("article.json")
        guard let data = try? Data(contentsOf: file), var art = try? Coders.decoder.decode(Article.self, from: data) else { return nil }
        let before = art.stats.imagesSaved
        guard art.missingImages > 0 else { return (0, 0) }
        _ = await ImageFetcher.fetchAll(&art, into: dir, referer: art.imageReferer)
        let fixed = art.stats.imagesSaved - before
        if fixed > 0 { try? Self.writeFiles(art, to: dir) }
        return (fixed, art.missingImages)
    }
}

/// 缺图补抓计划（本机文件，不同步）：10 分钟、1 小时、6 小时、24 小时后各试一次，之后放弃
public struct ImageRetryPlan: Codable, Sendable {
    public struct Entry: Codable, Sendable { public var attempts: Int; public var next: Date }
    public var entries: [String: Entry] = [:]
    static let delays: [TimeInterval] = [600, 3600, 6 * 3600, 24 * 3600]

    public static func load(_ url: URL) -> ImageRetryPlan {
        (try? Data(contentsOf: url)).flatMap { try? Coders.decoder.decode(ImageRetryPlan.self, from: $0) } ?? ImageRetryPlan()
    }
    public func save(_ url: URL) { try? Coders.encoder.encode(self).write(to: url, options: .atomic) }

    public mutating func schedule(_ id: String) {
        if entries[id] == nil { entries[id] = Entry(attempts: 0, next: Date().addingTimeInterval(Self.delays[0])) }
    }
    public func due(_ now: Date = Date()) -> [String] { entries.filter { $0.value.next <= now }.map(\.key) }
    public mutating func record(_ id: String, stillMissing: Bool) {
        guard stillMissing, var e = entries[id] else { entries[id] = nil; return }
        e.attempts += 1
        if e.attempts >= Self.delays.count { entries[id] = nil; return }
        e.next = Date().addingTimeInterval(Self.delays[e.attempts])
        entries[id] = e
    }
}
