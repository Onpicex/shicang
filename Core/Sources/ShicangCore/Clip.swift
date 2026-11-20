import Foundation
import SwiftSoup

// MARK: 剪藏：剪贴板里的一段内容（不是链接）直接存成一篇

/// 剪贴板快照（界面层从 NSPasteboard 读出来交给 Core）
public struct ClipInput: Sendable, Equatable {
    public var text: String           // 纯文字
    public var html: String?          // 带格式的版本（浏览器、大多数编辑器复制时会给）
    public var sourceURL: String?     // 来源网页（Chrome 系浏览器、Safari 网页归档会给）
    public var title: String?         // 用户在确认窗里填的标题
    public init(text: String, html: String? = nil, sourceURL: String? = nil, title: String? = nil) {
        self.text = text; self.html = html; self.sourceURL = sourceURL; self.title = title
    }
}

public enum Clip {
    public static let extractorHTML = "clip-html@1"
    public static let extractorText = "clip-text@1"
    /// 链接旁边的文字超过这么多字才记成「我的摘录」（短的分享文案只抓链接）
    public static let highlightMin = 100

    /// 剪贴板/分享的文字该按「链接」处理（抓原文）还是按「一段内容」剪藏：
    /// 写了 http(s):// 的链接＝链接（旁边的大段文字记成摘录）；没写协议的裸域名（正文里顺带提到 github.com）只有整段基本就是它时才算
    public static func looksLikeLink(_ text: String) -> Bool {
        let links = Capture.webLinks(in: text)
        if links.contains(where: { $0.explicit }) { return true }
        guard let m = links.first else { return false }
        let rest = (text as NSString).replacingCharacters(in: m.range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.count <= 10
    }

    /// 去重键：同一段文字（空白差异不算）只存一次
    public static func key(_ input: ClipInput) -> String { "clip:" + Capture.hash(normalized(plainText(input))) }
    public static func id(_ input: ClipInput) -> String { Capture.hash(key(input)) }

    static func normalized(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// 纯文字：优先剪贴板给的；没有就从 HTML 里取
    public static func plainText(_ input: ClipInput) -> String {
        let t = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        guard let h = input.html, let doc = try? SwiftSoup.parseBodyFragment(h), let body = doc.body() else { return "" }
        return ((try? body.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func sourceURL(_ input: ClipInput) -> URL? {
        guard let s = input.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines), let u = URL(string: s),
              ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil else { return nil }
        return u
    }

    /// 建议标题：第一行（太长就取到第一个句号，再不行截 40 字）
    public static func suggestedTitle(_ input: ClipInput) -> String {
        if let h = input.html, let t = firstHeading(h) { return t }
        let text = plainText(input)
        let first = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let line = first.trimmingCharacters(in: CharacterSet(charactersIn: "#>*-• \t"))
        if line.count <= 40 { return line }
        if let r = line.firstIndex(where: { "。！？!?；;".contains($0) }), line.distance(from: line.startIndex, to: r) < 40, line.distance(from: line.startIndex, to: r) >= 6 {
            return String(line[...r])
        }
        return String(line.prefix(36)) + "…"
    }

    /// HTML 开头就是标题（复制了整篇时常见）：用它
    static func firstHeading(_ html: String) -> String? {
        guard let doc = try? SwiftSoup.parseBodyFragment(html), let body = doc.body(),
              let h = try? body.select("h1, h2").first() else { return nil }
        let t = ((try? h.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 80 else { return nil }
        // 必须在正文最前面（前面的文字不超过 20 字），否则只是中间的小节标题
        let all = ((try? body.text()) ?? "")
        guard let r = all.range(of: t), all.distance(from: all.startIndex, to: r.lowerBound) <= 20 else { return nil }
        return t
    }

    /// 确认窗里显示的预览
    public struct Preview: Sendable, Equatable {
        public var title: String
        public var lines: [String]        // 前几行
        public var chars: Int
        public var images: Int
        public var host: String?
        public var rich: Bool             // 会保留格式（HTML 可用）
    }

    public static func preview(_ input: ClipInput, maxLines: Int = 6) -> Preview {
        let ex = build(input, capturedAt: Date())
        let lines = ex.article.blocks.filter { $0.type != .image }.compactMap { b -> String? in
            let t = b.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }.flatMap { $0.split(separator: "\n").map(String.init) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return Preview(title: ex.article.title, lines: Array(lines.prefix(maxLines)), chars: ex.article.stats.chars,
                       images: ex.article.stats.images, host: sourceURL(input)?.host, rich: ex.article.extractor == extractorHTML)
    }

    /// 剪贴板内容 → 一篇文章。有 HTML 且转出来的文字和纯文字对得上就保留格式和图片，否则按纯文字分段
    public static func build(_ input: ClipInput, capturedAt: Date) -> Extraction {
        let text = plainText(input)
        let src = sourceURL(input)
        var blocks: [Block] = []
        var extractor = extractorText
        if let html = input.html, !html.isEmpty {
            if isCodeHTML(html), !text.isEmpty {
                blocks = [.code(text)]                 // 代码编辑器复制的：原样存成代码块
            } else if let b = htmlBlocks(html, base: src), accept(b, text: text) {
                blocks = b
                extractor = extractorHTML
            }
        }
        if blocks.isEmpty { blocks = textBlocks(text) }
        let k = key(input)
        let title = AIConfig.clean(input.title) ?? suggestedTitle(input)
        var art = Article(id: Capture.hash(k), canonicalId: k, aliases: [], source: .clip,
                          url: src?.absoluteString ?? "", capturedURL: src?.absoluteString ?? "",
                          title: title.isEmpty ? "剪藏" : title,
                          author: nil, authorHandle: nil, authorURL: nil, publishedAt: nil, capturedAt: capturedAt, cover: nil, summary: nil,
                          blocks: blocks, extractor: extractor, stats: ArticleStats(chars: 0, images: 0, imagesSaved: 0, videos: 0))
        art.recomputeStats()
        var raw: [(String, Data)] = [("source.txt", Data(text.utf8))]
        if let h = input.html, !h.isEmpty { raw.append(("source.html", Data(h.utf8))) }
        return Extraction(article: art, rawSnapshots: raw, imageReferer: src?.absoluteString)
    }

    static func htmlBlocks(_ html: String, base: URL?) -> [Block]? {
        guard let doc = try? SwiftSoup.parseBodyFragment(html, base?.absoluteString ?? ""), let body = doc.body() else { return nil }
        let builder = HTMLBlockBuilder(baseURL: base) { el in
            for a in ["data-src", "data-original", "src"] {
                if let v = try? el.attr(a), !v.isEmpty, !v.hasPrefix("data:") { return v }
            }
            return nil
        }
        builder.skipSelectors = ["meta", "link", "title"]
        guard let blocks = try? builder.build(body) else { return nil }
        // 解析不出绝对地址的图片（相对路径又没有来源页、本机文件）存不下来，去掉
        return blocks.filter { b in
            guard let img = b.image else { return true }
            guard let u = URL(string: img.url), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return false }
            return true
        }
    }

    /// 代码编辑器（VS Code、Xcode 等）复制出来的 HTML：一行一个 div、靠 white-space:pre 保留缩进，没有段落/标题/列表/图片
    static func isCodeHTML(_ html: String) -> Bool {
        let lower = html.lowercased()
        guard lower.contains("white-space: pre") || lower.contains("white-space:pre") else { return false }
        guard let doc = try? SwiftSoup.parseBodyFragment(html), let body = doc.body() else { return false }
        return (try? body.select("p, h1, h2, h3, h4, li, img, blockquote").isEmpty()) ?? false
    }

    /// HTML 转出来的文字要和纯文字基本一致（防止 HTML 里只有一部分、或混进了隐藏内容）
    static func accept(_ blocks: [Block], text: String) -> Bool {
        let got = blocks.map(\.plainText).joined().filter { !$0.isWhitespace }.count
        let hasImage = blocks.contains { $0.image != nil }
        if got == 0 { return hasImage && text.isEmpty }
        let want = text.filter { !$0.isWhitespace }.count
        if want == 0 { return true }
        let r = Double(got) / Double(want)
        return r >= 0.6 && r <= 1.5
    }

    /// 纯文字分段：空行分段，段内换行保留；``` 围栏当代码块
    static func textBlocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var cur: [String] = []
        var lastWasCode = false
        func flush() {
            while let l = cur.last, l.trimmingCharacters(in: .whitespaces).isEmpty { cur.removeLast() }
            defer { cur = [] }
            guard !cur.isEmpty else { return }
            // 像代码的段落改成代码块；空行隔开的两段代码（函数之间常见）合成一块
            guard let segs = CodeDetect.segments(cur.joined(separator: "\n")) else {
                out.append(.paragraph([Inline(cur.joined(separator: "\n"))])); lastWasCode = false
                return
            }
            for (k, seg) in segs.enumerated() {
                switch seg {
                case .code(let text, let lang):
                    if k == 0, lastWasCode, var prev = out.popLast() {
                        prev.text = (prev.text ?? "") + "\n\n" + text
                        prev.language = prev.language ?? lang
                        out.append(prev)
                    } else { out.append(.code(text, language: lang)) }
                    lastWasCode = true
                case .prose(let lines):
                    out.append(.paragraph([Inline(lines.joined(separator: "\n"))])); lastWasCode = false
                }
            }
        }
        // 作者自己写的 ``` 围栏 → 代码块（语言取围栏后的词）；没闭合就当普通文字
        var fence: (marker: String, lang: String?, lines: [String])?
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            let t = String(line.replacingOccurrences(of: "\t", with: "    ").reversed().drop(while: { $0 == " " }).reversed())
            let trimmed = t.trimmingCharacters(in: .whitespaces)
            if var f = fence {
                if trimmed.hasPrefix(f.marker), trimmed.allSatisfy({ $0 == f.marker.first }) {
                    if f.lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                        out.append(.code(f.lines.joined(separator: "\n"), language: f.lang))
                    }
                    lastWasCode = false; fence = nil
                } else { f.lines.append(t); fence = f }
                continue
            }
            if let m = trimmed.range(of: #"^(`{3,}|~{3,})\s*[A-Za-z0-9_+#.-]*$"#, options: .regularExpression), m.lowerBound == trimmed.startIndex {
                flush()
                let marker = String(trimmed.prefix { $0 == trimmed.first })
                let lang = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces).lowercased()
                fence = (marker, lang.isEmpty ? nil : lang, [])
                continue
            }
            if trimmed.isEmpty { flush() } else { cur.append(t) }
        }
        if let f = fence {                      // 没闭合：围栏行连同后面的内容按普通文字处理
            cur.append(f.marker + (f.lang ?? ""))
            for l in f.lines { if l.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { cur.append(l) } }
        }
        flush()
        return out
    }
}

// MARK: 链接＋大段文字：文字记成「我的摘录」

extension Capture {
    /// 分享文字里除了链接之外的部分；够长（≥ Clip.highlightMin 字）才算摘录
    public static func highlight(in text: String) -> String? {
        let links = webLinks(in: text)
        guard let m = links.first(where: { $0.explicit }) ?? links.first else { return nil }
        let s = (text as NSString).replacingCharacters(in: m.range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count >= Clip.highlightMin ? String(s.prefix(20000)) : nil
    }
}

/// 一条「我的摘录」
public struct Highlight: Codable, Sendable, Hashable {
    public var text: String
    public var at: Date
    public var device: String?
    public init(text: String, at: Date = Date(), device: String? = nil) { self.text = text; self.at = at; self.device = device }
}

/// 文章目录里的 highlights.json（随 iCloud 同步；冲突副本合并后删掉）
public enum HighlightStore {
    public static let fileName = "highlights.json"
    struct File: Codable { var schema = 1; var items: [Highlight] }

    static func decode(_ d: Data) -> [Highlight]? { (try? Coders.decoder.decode(File.self, from: d))?.items }

    public static func load(dir: URL, names: [String]? = nil, resolve: Bool = true) -> [Highlight] {
        let file = dir.appendingPathComponent(fileName)
        var items = (try? Data(contentsOf: file)).flatMap(decode) ?? []
        guard resolve else { return items }
        let copies = ConflictCopies.find(in: dir, base: "highlights", ext: "json", names: names)
        let versions = ConflictCopies.unresolvedVersions(of: file)
        guard !copies.isEmpty || !versions.isEmpty else { return items }
        for u in copies { items = merge(items, (try? Data(contentsOf: u)).flatMap(decode) ?? []) }
        for v in versions { items = merge(items, decode(v.data) ?? []) }
        if (try? write(items, dir: dir)) != nil {
            for u in copies { try? FileManager.default.removeItem(at: u) }
            ConflictCopies.markResolved(file, versions.map(\.version))
        }
        return items
    }

    static func merge(_ a: [Highlight], _ b: [Highlight]) -> [Highlight] {
        var out = a
        for h in b where !out.contains(where: { Clip.normalized($0.text) == Clip.normalized(h.text) }) { out.append(h) }
        return out.sorted { $0.at < $1.at }
    }

    static func write(_ items: [Highlight], dir: URL) throws {
        try Coders.encoder.encode(File(items: items)).write(to: dir.appendingPathComponent(fileName), options: .atomic)
    }

    /// 追加一条（同样的文字已有就不重复记）。返回是否真的加了
    @discardableResult
    public static func append(_ text: String, dir: URL, device: String?, at: Date = Date()) throws -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, FileManager.default.fileExists(atPath: dir.path) else { return false }
        let items = load(dir: dir)
        if items.contains(where: { Clip.normalized($0.text) == Clip.normalized(t) }) { return false }
        try write(merge(items, [Highlight(text: t, at: at, device: device)]), dir: dir)
        return true
    }
}
