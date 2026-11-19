import Foundation

/// X：只用 fxtwitter 公共 API（设计上完全不登录 X）
public struct XExtractor: Sendable {
    public static let version = "x-fxtwitter@0.1"
    public init() {}

    public func extract(_ t: CaptureTarget) async throws -> Extraction {
        guard let id = t.tweetID else { throw ExtractError.unsupported("无 tweet id") }
        // /2/thread 同时返回主推 + 作者自己的连续回复；失败退回 /2/status
        var raw: Data
        var root: JSON
        do {
            (raw, _) = try await HTTP.get(URL(string: "https://api.fxtwitter.com/2/thread/\(id)")!, ua: UA.app)
            root = try JSON.parse(raw)
            if root["code"].int != 200 { throw ExtractError.http(root["code"].int ?? 0, "fxtwitter thread") }
        } catch {
            (raw, _) = try await HTTP.get(URL(string: "https://api.fxtwitter.com/2/status/\(id)")!, ua: UA.app)
            root = try JSON.parse(raw)
        }
        let code = root["code"].int ?? 0
        guard code == 200, !root["status"].isNull else {
            if code == 404 { throw ExtractError.gate("推文不存在或已删除（fxtwitter 404）") }
            if code == 401 || code == 403 { throw ExtractError.gate("推文受保护/需登录才能看（fxtwitter \(code)），拾藏不登录 X") }
            throw ExtractError.http(code, "fxtwitter status \(id)")
        }
        let main = root["status"]
        let author = main["author"]
        let handle = author["screen_name"].string ?? ""
        var thread = root["thread"].array.filter { $0["author"]["screen_name"].string == handle }
        if thread.isEmpty { thread = [main] }
        // 只保留主推及之后的作者连续回复（之前的作者推若存在也保留，按时间序）
        var blocks: [Block] = []
        var title = ""
        var cover: ImageRef?

        for (i, tw) in thread.enumerated() {
            if i > 0 { blocks.append(.divider) }
            if !tw["article"].isNull {
                let art = tw["article"]
                if title.isEmpty { title = art["title"].string ?? "" }
                if let c = art["cover_media"]["media_info"]["original_img_url"].string { cover = ImageRef(url: Self.origImage(c)) }
                blocks += draftBlocks(art)
            } else {
                blocks += tweetBlocks(tw, selfHandle: handle)
            }
        }
        if title.isEmpty {
            let firstText = thread.first.map { tweetText($0, selfHandle: handle).map(\.text).joined() } ?? ""
            let line = firstText.split(separator: "\n").first.map(String.init) ?? firstText
            title = line.count > 60 ? String(line.prefix(60)) + "…" : line
            if title.isEmpty { title = "@\(handle) 的推文" }
        }
        let published = main["created_timestamp"].double.map { Date(timeIntervalSince1970: $0) }
        let canonical = "x:\(main["id"].string ?? id)"
        var art = Article(
            id: Capture.hash(canonical), canonicalId: canonical, aliases: [], source: .x,
            url: "https://x.com/\(handle)/status/\(main["id"].string ?? id)", capturedURL: t.capturedURL,
            title: title, author: author["name"].string, authorHandle: handle.isEmpty ? nil : "@\(handle)",
            authorURL: handle.isEmpty ? nil : "https://x.com/\(handle)", publishedAt: published, capturedAt: Date(),
            cover: cover, summary: nil, blocks: blocks, extractor: Self.version,
            stats: ArticleStats(chars: 0, images: 0, imagesSaved: 0, videos: 0))
        art.recomputeStats()
        if art.stats.chars == 0 && art.stats.images == 0 && art.stats.videos == 0 { throw ExtractError.gate("推文内容为空") }
        return Extraction(article: art, rawSnapshots: [("source.json", raw)], imageReferer: nil)
    }

    /// pbs.twimg.com 不带参数时只给 1200 宽，补 name=orig 拿原图
    static func origImage(_ u: String) -> String {
        guard u.contains("pbs.twimg.com/media/") else { return u }
        if u.contains("name=") { return u.replacingOccurrences(of: #"name=[a-z0-9x]+"#, with: "name=orig", options: .regularExpression) }
        return u + (u.contains("?") ? "&" : "?") + "name=orig"
    }

    // MARK: 普通推文

    /// raw_text + facets：t.co 换成真实链接，去掉媒体占位链接
    func tweetText(_ tw: JSON, selfHandle: String) -> [Inline] {
        var text = tw["raw_text"]["text"].string ?? tw["text"].string ?? ""
        let facets = tw["raw_text"]["facets"].array
        // 自回复开头的 "@自己 " 去掉
        let prefix = "@\(selfHandle) "
        while !selfHandle.isEmpty && text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        var out: [Inline] = []
        var rest = Substring(text)
        for f in facets {
            guard let orig = f["original"].string, !orig.isEmpty, let r = rest.range(of: orig) else { continue }
            let type = f["type"].string ?? ""
            if type != "url" && type != "media" { continue }
            out.append(Inline(String(rest[..<r.lowerBound])))
            if type == "url" {
                let rep = f["replacement"].string ?? orig
                out.append(Inline(rep, link: rep))
            }
            rest = rest[r.upperBound...]
        }
        out.append(Inline(String(rest)))
        return Markdown.mergeInlines(out.map { var x = $0; x.text = x.text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">"); return x })
    }

    func tweetBlocks(_ tw: JSON, selfHandle: String) -> [Block] {
        var blocks: [Block] = []
        // 按空行分段，段内单换行保留
        let inl = tweetText(tw, selfHandle: selfHandle)
        blocks += Markdown.splitParagraphs(inl).map { Block.paragraph($0) }
        let url = tw["url"].string ?? ""
        for m in tw["media"]["all"].array {
            let type = m["type"].string ?? ""
            if type == "photo" {
                blocks.append(.image(ImageRef(url: Self.origImage(m["url"].string ?? ""), width: m["width"].int, height: m["height"].int, alt: m["altText"].string)))
            } else if type == "video" || type == "gif" {
                let best = m["variants"].array
                    .filter { ($0["content_type"].string ?? "").contains("mp4") }
                    .max { ($0["bitrate"].int ?? 0) < ($1["bitrate"].int ?? 0) }
                let stream = best?["url"].string ?? m["url"].string
                let thumb = m["thumbnail_url"].string.map { ImageRef(url: $0) }
                blocks.append(.video(VideoRef(pageURL: url, streamURL: stream, cover: thumb, durationSec: m["duration"].double)))
            }
        }
        let q = tw["quote"]
        if !q.isNull {
            let qt = tweetText(q, selfHandle: "").map(\.text).joined()
            blocks.append(.embed(EmbedRef(url: q["url"].string ?? "", title: nil,
                                          author: "\(q["author"]["name"].string ?? "") @\(q["author"]["screen_name"].string ?? "")",
                                          text: qt)))
        }
        return blocks
    }

    // MARK: X 长文（Draft.js 内容块）

    func draftBlocks(_ art: JSON) -> [Block] {
        let content = art["content"]
        var entities: [String: JSON] = [:]
        switch content["entityMap"] {
        case .array(let list): for e in list { if let k = e["key"].string { entities[k] = e["value"] } }
        case .object(let o): entities = o
        default: break
        }
        var media: [String: JSON] = [:]
        for m in art["media_entities"].array { if let k = m["media_id"].string { media[k] = m["media_info"] } }

        let draft = content["blocks"].array
        let headerTypes = draft.compactMap { $0["type"].string }.filter { $0.hasPrefix("header-") }
        let minHeader = headerTypes.map(Self.headerRank).min() ?? 1

        var out: [Block] = []
        for b in draft {
            let type = b["type"].string ?? "unstyled"
            let text = b["text"].string ?? ""
            let depth = b["depth"].int ?? 0
            if type == "atomic" {
                for er in b["entityRanges"].array {
                    guard let key = er["key"].string, let ent = entities[key] else { continue }
                    out += atomicBlocks(ent, media: media)
                }
                continue
            }
            let inl = styledInlines(text: text, styles: b["inlineStyleRanges"].array, ranges: b["entityRanges"].array, entities: entities)
            switch type {
            case let h where h.hasPrefix("header-"):
                out.append(.heading(min(6, Self.headerRank(h) - minHeader + 2), inl))
            case "blockquote": out.append(.quote(inl))
            case "ordered-list-item": out.append(.listItem(ordered: true, depth: depth, inl))
            case "unordered-list-item": out.append(.listItem(ordered: false, depth: depth, inl))
            case "code-block": out.append(.code(text))
            default:
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.paragraph(inl)) }
            }
        }
        return out
    }

    static func headerRank(_ t: String) -> Int {
        switch t { case "header-one": return 1; case "header-two": return 2; case "header-three": return 3
        case "header-four": return 4; case "header-five": return 5; default: return 6 }
    }

    func atomicBlocks(_ ent: JSON, media: [String: JSON]) -> [Block] {
        let type = ent["type"].string ?? ""
        let data = ent["data"]
        switch type {
        case "MEDIA":
            return data["mediaItems"].array.compactMap { item in
                guard let mid = item["mediaId"].string, let info = media[mid] else { return nil }
                let tn = info["__typename"].string ?? ""
                if tn == "ApiImage" {
                    return .image(ImageRef(url: Self.origImage(info["original_img_url"].string ?? ""), width: info["original_img_width"].int, height: info["original_img_height"].int))
                }
                // 视频/GIF：只记封面 + 能找到的直链
                let cover = info["preview_image"]["original_img_url"].string.map { ImageRef(url: $0) }
                let stream = info["variants"].array.filter { ($0["content_type"].string ?? "").contains("mp4") }
                    .max { ($0["bit_rate"].int ?? $0["bitrate"].int ?? 0) < ($1["bit_rate"].int ?? $1["bitrate"].int ?? 0) }?["url"].string
                return .video(VideoRef(pageURL: "", streamURL: stream, cover: cover, durationSec: nil))
            }
        case "MARKDOWN":
            let md = data["markdown"].string ?? ""
            if let rows = Markdown.parseTable(md) { return [.table(rows, header: true)] }
            return [.code(md, language: "markdown")]
        case "TWEET":
            let tid = data["tweetId"].string ?? data["id"].string ?? ""
            return [.embed(EmbedRef(url: "https://x.com/i/status/\(tid)", title: "引用推文", author: nil, text: nil))]
        case "DIVIDER":
            return [.divider]
        case "LINK":
            let u = data["url"].string ?? ""
            return u.isEmpty ? [] : [.embed(EmbedRef(url: u, title: nil, author: nil, text: nil))]
        default:
            return [.paragraph([Inline("[未识别的长文元素：\(type)]")])]
        }
    }

    /// Draft.js 的 offset/length 是 JS 字符串下标（UTF-16 码元）
    func styledInlines(text: String, styles: [JSON], ranges: [JSON], entities: [String: JSON]) -> [Inline] {
        let u = Array(text.utf16)
        guard !u.isEmpty else { return [] }
        var bold = [Bool](repeating: false, count: u.count)
        var italic = bold, strike = bold, code = bold
        var link = [String?](repeating: nil, count: u.count)
        func apply(_ off: Int, _ len: Int, _ f: (Int) -> Void) {
            let lo = max(0, off), hi = min(u.count, off + len)
            if lo < hi { for i in lo..<hi { f(i) } }
        }
        for s in styles {
            let off = s["offset"].int ?? 0, len = s["length"].int ?? 0
            switch s["style"].string ?? "" {
            case "Bold", "BOLD": apply(off, len) { bold[$0] = true }
            case "Italic", "ITALIC": apply(off, len) { italic[$0] = true }
            case "Strikethrough", "STRIKETHROUGH": apply(off, len) { strike[$0] = true }
            case "Code", "CODE": apply(off, len) { code[$0] = true }
            default: break
            }
        }
        for r in ranges {
            guard let key = r["key"].string, let e = entities[key], e["type"].string == "LINK", let url = e["data"]["url"].string else { continue }
            apply(r["offset"].int ?? 0, r["length"].int ?? 0) { link[$0] = url }
        }
        var out: [Inline] = []
        var start = 0
        for i in 1...u.count {
            if i == u.count || bold[i] != bold[start] || italic[i] != italic[start] || strike[i] != strike[start] || code[i] != code[start] || link[i] != link[start] {
                let s = String(decoding: u[start..<i], as: UTF16.self)
                out.append(Inline(s, bold: bold[start], italic: italic[start], code: code[start], strike: strike[start], link: link[start]))
                start = i
            }
        }
        return out
    }
}
