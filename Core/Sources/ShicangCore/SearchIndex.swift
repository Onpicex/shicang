import Foundation
import SQLite3

// MARK: 切词

/// 中文全文检索的切词（方案 §3.6：trigram 搜不到 2 字词，所以改成单字 + 相邻二字）。
/// 中日韩连续段 → 每个字 + 每对相邻二字；字母数字 → 小写整词。入库和查询用同一套，切完交给 FTS5 unicode61 按空格分。
public enum SearchText {
    /// 全角转半角、大写转小写（入库和查询两边都做）
    public static func normalize(_ s: String) -> String { s.precomposedStringWithCompatibilityMapping.lowercased() }

    enum Segment: Equatable { case cjk([Unicode.Scalar]), word(String) }

    static func isCJK(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3005, 0x3007, 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF, 0x20000...0x323AF:
            return true
        default:
            return false
        }
    }

    static func isWordChar(_ u: Unicode.Scalar) -> Bool {
        let p = u.properties
        return p.isAlphabetic || p.numericType != nil || p.generalCategory == .nonspacingMark
    }

    /// 已经 normalize 过的文字 → 段落（中文段 / 英文数字词）
    static func segments(_ s: String) -> [Segment] {
        var out: [Segment] = []
        var cjk: [Unicode.Scalar] = []
        var word = String.UnicodeScalarView()
        func flush() {
            if !cjk.isEmpty { out.append(.cjk(cjk)); cjk.removeAll() }
            if !word.isEmpty { out.append(.word(String(word))); word = String.UnicodeScalarView() }
        }
        for u in s.unicodeScalars {
            if isCJK(u) {
                if !word.isEmpty { out.append(.word(String(word))); word = String.UnicodeScalarView() }
                cjk.append(u)
            } else if isWordChar(u) {
                if !cjk.isEmpty { out.append(.cjk(cjk)); cjk.removeAll() }
                word.append(u)
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    /// 入库用：去重后的词表（FTS 用 detail=column，不记位置，重复词没有意义）
    public static func indexTokens(_ text: String) -> String {
        var seen = Set<String>()
        var out: [String] = []
        func add(_ t: String) { if seen.insert(t).inserted { out.append(t) } }
        for seg in segments(normalize(text)) {
            switch seg {
            case .cjk(let cs):
                for c in cs { add(String(c)) }
                if cs.count > 1 { for i in 0..<(cs.count - 1) { add(String(String.UnicodeScalarView([cs[i], cs[i + 1]]))) } }
            case .word(let w):
                add(w)
            }
        }
        return out.joined(separator: " ")
    }

    /// 查询：FTS5 表达式（全部 AND）+ 原词（再用子串核对，保证「黄仁勋」是连着的三个字）
    public struct Query: Sendable, Equatable {
        public var match: String
        public var terms: [String]
    }

    public static func query(_ raw: String) -> Query? {
        let words = normalize(raw).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var clauses: [String] = []
        var terms: [String] = []
        for (wi, w) in words.enumerated() {
            let segs = segments(w)
            guard !segs.isEmpty else { continue }
            terms.append(trimPunct(w))
            for (si, seg) in segs.enumerated() {
                switch seg {
                case .cjk(let cs):
                    if cs.count == 1 { clauses.append(quote(String(cs[0]))) }
                    else { for i in 0..<(cs.count - 1) { clauses.append(quote(String(String.UnicodeScalarView([cs[i], cs[i + 1]])))) } }
                case .word(let s):
                    let last = wi == words.count - 1 && si == segs.count - 1    // 最后一个英文词按前缀（边打边搜）
                    clauses.append(quote(s) + (last ? "*" : ""))
                }
            }
        }
        guard !clauses.isEmpty else { return nil }
        return Query(match: clauses.joined(separator: " AND "), terms: terms.filter { !$0.isEmpty })
    }

    static func quote(_ t: String) -> String { "\"" + t.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    /// 去掉词两头的标点（用户可能连引号一起粘进来）
    static func trimPunct(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        guard let a = scalars.firstIndex(where: { isCJK($0) || isWordChar($0) }),
              let b = scalars.lastIndex(where: { isCJK($0) || isWordChar($0) }) else { return "" }
        return String(String.UnicodeScalarView(scalars[a...b]))
    }

    /// 结果里的上下文片段：第一个命中词前后各取一段
    /// 命中词前留一小段（卡片只显示两行，命中词要落在第一行里）
    public static func snippet(_ body: String, terms: [String], lead: Int = 12, tail: Int = 72) -> String? {
        for t in terms where !t.isEmpty {
            guard let r = body.range(of: t, options: [.caseInsensitive, .widthInsensitive]) else { continue }
            let start = body.index(r.lowerBound, offsetBy: -lead, limitedBy: body.startIndex) ?? body.startIndex
            let end = body.index(r.upperBound, offsetBy: tail, limitedBy: body.endIndex) ?? body.endIndex
            let s = body[start..<end].replacingOccurrences(of: "\n", with: " ")
            return (start > body.startIndex ? "…" : "") + s + (end < body.endIndex ? "…" : "")
        }
        return nil
    }
}

// MARK: SQLite 小封装（只给本文件和 LibraryIndex 用）

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct SQLiteError: Error, CustomStringConvertible {
    let message: String
    var description: String { "SQLite：\(message)" }
}

final class SQLiteDB {
    private(set) var db: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let m = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open 失败"
            sqlite3_close(db)
            throw SQLiteError(message: m)
        }
        sqlite3_busy_timeout(db, 3000)
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "exec 失败"
            sqlite3_free(err)
            throw SQLiteError(message: m)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(db)))
        }
        return Statement(st)
    }

    var userVersion: Int {
        get { (try? prepare("PRAGMA user_version").first { $0.int(0) }) ?? 0 }
        set { try? exec("PRAGMA user_version = \(newValue)") }
    }
}

final class Statement {
    let st: OpaquePointer
    init(_ st: OpaquePointer) { self.st = st }
    deinit { sqlite3_finalize(st) }

    @discardableResult
    func bind(_ values: [Any?]) -> Statement {
        sqlite3_reset(st)
        sqlite3_clear_bindings(st)
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case nil: sqlite3_bind_null(st, idx)
            case let s as String: sqlite3_bind_text(st, idx, s, -1, SQLITE_TRANSIENT)
            case let n as Int: sqlite3_bind_int64(st, idx, Int64(n))
            case let n as Int64: sqlite3_bind_int64(st, idx, n)
            case let d as Double: sqlite3_bind_double(st, idx, d)
            case let d as Data: _ = d.withUnsafeBytes { sqlite3_bind_blob(st, idx, $0.baseAddress, Int32(d.count), SQLITE_TRANSIENT) }
            default: sqlite3_bind_null(st, idx)
            }
        }
        return self
    }

    func run() throws {
        let rc = sqlite3_step(st)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(sqlite3_db_handle(st))))
        }
    }

    func rows<T>(_ map: (Statement) -> T?) -> [T] {
        var out: [T] = []
        while sqlite3_step(st) == SQLITE_ROW { if let v = map(self) { out.append(v) } }
        return out
    }

    func first<T>(_ map: (Statement) -> T?) -> T? {
        sqlite3_step(st) == SQLITE_ROW ? map(self) : nil
    }

    func text(_ i: Int32) -> String? { sqlite3_column_text(st, i).map { String(cString: $0) } }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(st, i)) }
    func data(_ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(st, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(st, i)))
    }
}

// MARK: 本机索引（<local>/index.sqlite，可随时删掉重建）

/// 一篇进全文索引的内容
struct SearchDoc {
    var title: String
    var author: String      // 作者 + @账号 + 网站域名
    var tags: String
    var summary: String     // AI 摘要 + 要点 + 平台摘要
    var body: String?       // nil = 正文没变，沿用库里的
}

/// 列表缓存 + 全文索引。docs 存每篇的签名（三个文件的修改时间）和列表摘要 JSON，启动时不用再解析全部 article.json；
/// fts 是 FTS5 表（预先切好词）。只在 LibraryIndex 这个 actor 里用。
final class SearchStore {
    static let schemaVersion = 1
    let db: SQLiteDB

    init(url: URL) throws {
        db = try SQLiteDB(path: url.path)
        try db.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
        if db.userVersion != Self.schemaVersion {
            try db.exec("DROP TABLE IF EXISTS docs; DROP TABLE IF EXISTS fts;")
            try db.exec("""
            CREATE TABLE docs(rowid INTEGER PRIMARY KEY, id TEXT UNIQUE NOT NULL, sig TEXT NOT NULL,
                              summary BLOB NOT NULL, body TEXT NOT NULL DEFAULT '', hay TEXT NOT NULL DEFAULT '');
            CREATE VIRTUAL TABLE fts USING fts5(title, author, tags, summary, body,
                              tokenize = 'unicode61 remove_diacritics 2', detail = column);
            """)
            db.userVersion = Self.schemaVersion
        }
    }

    func loadAll() -> [(id: String, sig: String, summary: Data)] {
        guard let st = try? db.prepare("SELECT id, sig, summary FROM docs") else { return [] }
        return st.rows { r in
            guard let id = r.text(0), let sig = r.text(1), let d = r.data(2) else { return nil }
            return (id, sig, d)
        }
    }

    func body(_ id: String) -> String? {
        try? db.prepare("SELECT body FROM docs WHERE id = ?").bind([id]).first { $0.text(0) }
    }

    func upsert(id: String, sig: String, summary: Data, doc: SearchDoc) throws {
        let body = doc.body ?? self.body(id) ?? ""
        let hay = SearchText.normalize([doc.title, doc.author, doc.tags, doc.summary, body].joined(separator: "\n"))
        let rowid = try db.prepare("SELECT rowid FROM docs WHERE id = ?").bind([id]).first { $0.int(0) }
        if let rowid {
            try db.prepare("UPDATE docs SET sig = ?, summary = ?, body = ?, hay = ? WHERE rowid = ?").bind([sig, summary, body, hay, rowid]).run()
            try db.prepare("DELETE FROM fts WHERE rowid = ?").bind([rowid]).run()
            try insertFTS(rowid, doc, body)
        } else {
            try db.prepare("INSERT INTO docs(id, sig, summary, body, hay) VALUES(?, ?, ?, ?, ?)").bind([id, sig, summary, body, hay]).run()
            try insertFTS(Int(sqlite3_last_insert_rowid(db.db)), doc, body)
        }
    }

    private func insertFTS(_ rowid: Int, _ d: SearchDoc, _ body: String) throws {
        try db.prepare("INSERT INTO fts(rowid, title, author, tags, summary, body) VALUES(?, ?, ?, ?, ?, ?)")
            .bind([rowid, SearchText.indexTokens(d.title), SearchText.indexTokens(d.author), SearchText.indexTokens(d.tags),
                   SearchText.indexTokens(d.summary), SearchText.indexTokens(body)]).run()
    }

    func delete(_ id: String) {
        guard let rowid = try? db.prepare("SELECT rowid FROM docs WHERE id = ?").bind([id]).first({ $0.int(0) }) else { return }
        try? db.prepare("DELETE FROM fts WHERE rowid = ?").bind([rowid]).run()
        try? db.prepare("DELETE FROM docs WHERE rowid = ?").bind([rowid]).run()
    }

    /// 批量写包在一个事务里（单条写失败已经各自吞掉，这里只管提交）
    func begin() { try? db.exec("BEGIN") }
    func commit() { if (try? db.exec("COMMIT")) == nil { try? db.exec("ROLLBACK") } }

    /// 返回按相关度排好的 id。标题命中权重最高，其次标签、摘要、作者、正文
    func search(_ q: SearchText.Query, limit: Int = 500) -> [String] {
        var sql = """
        SELECT d.id FROM fts JOIN docs d ON d.rowid = fts.rowid
        WHERE fts MATCH ?
        """
        for _ in q.terms { sql += " AND instr(d.hay, ?) > 0" }
        sql += " ORDER BY bm25(fts, 10.0, 3.0, 6.0, 4.0, 1.0) LIMIT \(limit)"
        guard let st = try? db.prepare(sql) else { return [] }
        st.bind([q.match] + q.terms)
        return st.rows { $0.text(0) }
    }
}
