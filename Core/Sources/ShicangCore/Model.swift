import Foundation

public enum Source: String, Codable, Sendable {
    case wechat, x, xhs, web
    case clip       // 从剪贴板收藏的一段内容（纯文字或带格式），不是链接
}

/// 一段行内文字（带样式）。样式字段只在为真时出现，保持 JSON 简洁。
public struct Inline: Codable, Sendable, Hashable {
    public var text: String
    public var bold: Bool?
    public var italic: Bool?
    public var code: Bool?
    public var strike: Bool?
    public var link: String?

    public init(_ text: String, bold: Bool = false, italic: Bool = false, code: Bool = false, strike: Bool = false, link: String? = nil) {
        self.text = text
        self.bold = bold ? true : nil
        self.italic = italic ? true : nil
        self.code = code ? true : nil
        self.strike = strike ? true : nil
        self.link = link
    }

    func sameStyle(_ o: Inline) -> Bool {
        bold == o.bold && italic == o.italic && code == o.code && strike == o.strike && link == o.link
    }
}

public struct ImageRef: Codable, Sendable {
    public var url: String          // 远端原图地址
    public var file: String?        // 本地相对路径 images/01.jpg（下载成功才有）
    public var width: Int?
    public var height: Int?
    public var alt: String?
    public init(url: String, file: String? = nil, width: Int? = nil, height: Int? = nil, alt: String? = nil) {
        self.url = url; self.file = file; self.width = width; self.height = height; self.alt = alt
    }
}

/// 视频：只存链接（点开原文播放，不下载不处理）
public struct VideoRef: Codable, Sendable {
    public var pageURL: String       // 打开原文播放
    public var streamURL: String?    // 已知的直链（X mp4），仅供 App 内播放尝试；可能失效
    public var cover: ImageRef?
    public var durationSec: Double?
}

/// 引用推 / 卡片 / 公众号内链
public struct EmbedRef: Codable, Sendable {
    public var url: String
    public var title: String?
    public var author: String?
    public var text: String?
}

public struct Block: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case heading, paragraph, quote, listItem = "list_item", code, table, image, video, embed, divider
    }
    public var type: Kind
    public var level: Int?
    public var ordered: Bool?
    public var depth: Int?
    public var inlines: [Inline]?
    public var text: String?
    public var language: String?
    public var rows: [[String]]?
    public var header: Bool?
    public var image: ImageRef?
    public var video: VideoRef?
    public var embed: EmbedRef?

    public init(type: Kind) { self.type = type }

    public static func heading(_ level: Int, _ inl: [Inline]) -> Block { var b = Block(type: .heading); b.level = level; b.inlines = inl; return b }
    public static func paragraph(_ inl: [Inline]) -> Block { var b = Block(type: .paragraph); b.inlines = inl; return b }
    public static func quote(_ inl: [Inline]) -> Block { var b = Block(type: .quote); b.inlines = inl; return b }
    public static func listItem(ordered: Bool, depth: Int, _ inl: [Inline]) -> Block { var b = Block(type: .listItem); b.ordered = ordered; b.depth = depth; b.inlines = inl; return b }
    public static func code(_ text: String, language: String? = nil) -> Block { var b = Block(type: .code); b.text = text; b.language = language; return b }
    public static func table(_ rows: [[String]], header: Bool) -> Block { var b = Block(type: .table); b.rows = rows; b.header = header; return b }
    public static func image(_ img: ImageRef) -> Block { var b = Block(type: .image); b.image = img; return b }
    public static func video(_ v: VideoRef) -> Block { var b = Block(type: .video); b.video = v; return b }
    public static func embed(_ e: EmbedRef) -> Block { var b = Block(type: .embed); b.embed = e; return b }
    public static var divider: Block { Block(type: .divider) }

    /// 纯文本（用于统计/搜索/分类）
    public var plainText: String {
        switch type {
        case .heading, .paragraph, .quote, .listItem: return (inlines ?? []).map(\.text).joined()
        case .code: return text ?? ""
        case .table: return (rows ?? []).map { $0.joined(separator: " ") }.joined(separator: "\n")
        case .embed: return [embed?.author, embed?.title, embed?.text].compactMap { $0 }.joined(separator: " ")
        case .image: return image?.alt ?? ""
        case .video, .divider: return ""
        }
    }
}

public struct ArticleStats: Codable, Sendable {
    public var chars: Int
    public var images: Int
    public var imagesSaved: Int
    public var videos: Int
}

public struct Article: Codable, Sendable {
    public var schema: Int = 1
    public var id: String                 // canonicalId 的哈希，也是文件夹名
    public var canonicalId: String
    public var aliases: [String]          // 其他去重键（如公众号短链）
    public var source: Source
    public var url: String                // 规范原文链接
    public var capturedURL: String        // 用户收藏时的原始链接
    public var title: String
    public var author: String?
    public var authorHandle: String?
    public var authorURL: String?
    public var publishedAt: Date?
    public var capturedAt: Date
    public var cover: ImageRef?
    public var summary: String?           // 平台自带摘要（非 AI）
    public var blocks: [Block]
    public var extractor: String
    public var stats: ArticleStats
    public var imageReferer: String?      // 补抓缺图时要带的 Referer

    public var plainText: String { blocks.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n") }

    /// 标题就是正文第一段的开头（推文标题取自首行；有些网页正文自带同名标题）→ 渲染时不再重复显示标题
    public var titleRepeatsInBody: Bool {
        guard let first = blocks.first, first.type == .paragraph || first.type == .heading else { return false }
        func norm(_ s: String) -> String { s.filter { !$0.isWhitespace } }
        var t = norm(title)
        if t.hasSuffix("…") { t.removeLast() }
        return !t.isEmpty && norm(first.plainText).hasPrefix(t)
    }

    public var missingImages: Int { stats.images - stats.imagesSaved }

    /// X 长文的题图：页面上显示在标题下方，属于正文的一部分（公众号的 cover 是分享缩略图，不显示）
    public var heroCover: ImageRef? {
        guard source == .x, let c = cover, !blocks.contains(where: { $0.image?.url == c.url }) else { return nil }
        return c
    }

    public mutating func recomputeStats() {
        let imgs = blocks.compactMap(\.image)
        stats = ArticleStats(
            chars: plainText.filter { !$0.isWhitespace }.count,
            images: imgs.count,
            imagesSaved: imgs.filter { $0.file != nil }.count,
            videos: blocks.filter { $0.type == .video }.count)
    }
}

public enum ExtractError: Error, CustomStringConvertible {
    case unsupported(String)
    case http(Int, String)
    case gate(String)          // 质量闸门：登录墙/验证页/已删除/正文过短…
    case parse(String)

    public var description: String {
        switch self {
        case .unsupported(let s): return "不支持：\(s)"
        case .http(let c, let u): return "HTTP \(c)：\(u)"
        case .gate(let s): return "质量闸门：\(s)"
        case .parse(let s): return "解析失败：\(s)"
        }
    }
}

/// 提取结果：文章 + 原始快照（写进 source.*.gz）
public struct Extraction: Sendable {
    public var article: Article
    public var rawSnapshots: [(name: String, data: Data)]
    public var imageReferer: String?
}
