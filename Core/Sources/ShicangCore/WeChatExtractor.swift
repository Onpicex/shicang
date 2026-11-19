import Foundation
import SwiftSoup

/// 公众号：URLSession（移动 UA）+ SwiftSoup 解析 #js_content
public struct WeChatExtractor: Sendable {
    public static let version = "wechat-html@0.2"     // 0.2：引用框里的代码认回代码块（老文章启动时用快照重新解析）
    public static let referer = "https://mp.weixin.qq.com/"
    public init() {}

    public func extract(_ t: CaptureTarget) async throws -> Extraction {
        let (data, resp) = try await HTTP.get(t.url, ua: UA.iPhoneSafari)
        guard resp.statusCode == 200 else { throw ExtractError.http(resp.statusCode, t.url.absoluteString) }
        guard let html = String(data: data, encoding: .utf8) else { throw ExtractError.parse("不是 UTF-8") }
        return try parse(html: html, raw: data, target: t)
    }

    public func parse(html: String, raw: Data, target t: CaptureTarget) throws -> Extraction {
        try gate(html)
        let showType = Self.jsVar(html, "item_show_type") ?? "0"
        let doc = try SwiftSoup.parse(html, t.url.absoluteString)
        guard let content = try doc.select("#js_content").first() else {
            throw ExtractError.gate("页面里没有正文区（item_show_type=\(showType)，可能是图片/视频/短文消息，P1 再支持）")
        }
        let builder = HTMLBlockBuilder(baseURL: t.url) { el in
            for a in ["data-src", "data-original", "src"] {
                if let v = try? el.attr(a), !v.isEmpty, !v.hasPrefix("data:") { return Self.originalImage(v) }
            }
            return nil
        }
        builder.skipSelectors = ["mp-common-profile", ".js_uneditable.custom_select_card", "#js_pc_qr_code"]
        let blocks = try builder.build(content)

        func meta(_ p: String) -> String? { try? doc.select("meta[property=\(p)]").first()?.attr("content") }
        let title = Self.jsVar(html, "msg_title").map(Self.htmlDecode) ?? meta("og:title") ?? ""
        let nickname = Self.jsVar(html, "nickname").map(Self.htmlDecode)
        let authorVar = Self.jsVar(html, "author").map(Self.htmlDecode)
        let ct = Self.jsVar(html, "ct").flatMap(Double.init)
        let biz = Self.jsVar(html, "biz"), mid = Self.jsVar(html, "mid"), idx = Self.jsVar(html, "idx")
        let sn = Self.jsVarStrict(html, "sn") ?? Self.queryValue(meta("og:url"), "sn")
        let desc = Self.jsVar(html, "msg_desc").map(Self.htmlDecode)
        let coverURL = Self.jsVar(html, "msg_cdn_url")

        var canonical = t.key
        var aliases: [String] = []
        var url = t.url.absoluteString
        if let biz, let mid, let idx, !biz.isEmpty, !mid.isEmpty {
            canonical = "wechat:\(biz):\(mid):\(idx)"
            if t.key != canonical { aliases.append(t.key) }
            var c = URLComponents(string: "https://mp.weixin.qq.com/s")!
            c.queryItems = [URLQueryItem(name: "__biz", value: biz), URLQueryItem(name: "mid", value: mid), URLQueryItem(name: "idx", value: idx)]
                + (sn.map { [URLQueryItem(name: "sn", value: $0)] } ?? [])
            url = c.url!.absoluteString
        }
        var authorName = nickname ?? ""
        if let a = authorVar, !a.isEmpty, a != nickname { authorName = "\(nickname ?? "")（作者 \(a)）" }

        var art = Article(
            id: Capture.hash(canonical), canonicalId: canonical, aliases: aliases, source: .wechat,
            url: url, capturedURL: t.capturedURL, title: title,
            author: authorName.isEmpty ? nil : authorName, authorHandle: Self.jsVar(html, "user_name"), authorURL: nil,
            publishedAt: ct.map { Date(timeIntervalSince1970: $0) }, capturedAt: Date(),
            cover: coverURL.map { ImageRef(url: $0) }, summary: desc, blocks: blocks, extractor: Self.version,
            stats: ArticleStats(chars: 0, images: 0, imagesSaved: 0, videos: 0))
        art.recomputeStats()
        if art.stats.chars < 30 && art.stats.images == 0 { throw ExtractError.gate("正文过短（\(art.stats.chars) 字），疑似空壳") }
        return Extraction(article: art, rawSnapshots: [("source.html", raw)], imageReferer: Self.referer)
    }

    /// 环境异常 / 已删除 / 违规 → 失败，不存空壳
    func gate(_ html: String) throws {
        let hasContent = html.contains("id=\"js_content\"")
        let checks: [(String, String)] = [
            ("环境异常", "微信要求验证（环境异常）"), ("完成验证后即可继续访问", "微信要求验证"),
            ("该内容已被发布者删除", "原文已被发布者删除"), ("此内容因违规无法查看", "原文因违规无法查看"),
            ("此内容被投诉且经审核涉嫌侵权", "原文因侵权投诉无法查看"), ("该公众号已迁移", "公众号已迁移"),
            ("参数错误", "链接参数错误"),
        ]
        if !hasContent {
            for (k, why) in checks where html.contains(k) { throw ExtractError.gate(why) }
        }
    }

    // MARK: 工具

    /// var xxx = "..." / '...' / htmlDecode("...")；取第一个字面量
    static func jsVar(_ html: String, _ name: String) -> String? {
        let pattern = "var\\s+\(name)\\s*=\\s*(?:htmlDecode\\()?\\s*([\"'])(.*?)\\1"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(m.range(at: 2), in: html) else { return nil }
        let v = String(html[r])
        return v.count > 2000 ? nil : v
    }

    /// 只接受 var sn = "十六进制"（页面里还有个同名的压缩 JS 对象）
    static func jsVarStrict(_ html: String, _ name: String) -> String? {
        guard let v = jsVar(html, name), v.range(of: "^[0-9a-f]{16,64}$", options: .regularExpression) != nil else { return nil }
        return v
    }

    static func queryValue(_ url: String?, _ key: String) -> String? {
        guard let url, let c = URLComponents(string: url) else { return nil }
        return c.queryItems?.first { $0.name == key }?.value
    }

    static func htmlDecode(_ s: String) -> String {
        var out = s
        let map = ["&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&amp;": "&"]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        // \x26 这类 JS 转义
        if out.contains("\\x") {
            let re = try! NSRegularExpression(pattern: "\\\\x([0-9a-fA-F]{2})")
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1))
                result += String(UnicodeScalar(UInt8(hex, radix: 16)!))
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out
    }

    /// mmbiz.qpic.cn/.../640?wx_fmt=png → /0（原图）
    static func originalImage(_ s: String) -> String {
        guard var c = URLComponents(string: s.hasPrefix("//") ? "https:" + s : s), let host = c.host, host.contains("qpic.cn") else { return s }
        var parts = c.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if let last = parts.last, Int(last) != nil { parts[parts.count - 1] = "0" }
        c.path = parts.joined(separator: "/")
        if c.scheme == "http" { c.scheme = "https" }
        return c.url?.absoluteString ?? s
    }
}
