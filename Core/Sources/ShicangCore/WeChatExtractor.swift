import Foundation
import SwiftSoup

/// 公众号：URLSession（移动 UA）+ SwiftSoup 解析 #js_content；短文/图片消息读页面脚本里的数据
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
        let doc = try SwiftSoup.parse(html, t.url.absoluteString)
        func meta(_ p: String) -> String? { (try? doc.select("meta[property=\(p)]").first()?.attr("content")).flatMap { $0.isEmpty ? nil : $0 } }
        let blocks: [Block]
        var title = "", nickname: String?, authorVar: String?, ct: Double?, desc: String?, coverURL: String?, handle: String?
        var biz: String?, mid: String?, idx: String?, sn: String?
        if let content = try doc.select("#js_content").first() {
            let builder = HTMLBlockBuilder(baseURL: t.url) { el in
                for a in ["data-src", "data-original", "src"] {
                    if let v = try? el.attr(a), !v.isEmpty, !v.hasPrefix("data:") { return Self.originalImage(v) }
                }
                return nil
            }
            builder.skipSelectors = ["mp-common-profile", ".js_uneditable.custom_select_card", "#js_pc_qr_code"]
            blocks = try builder.build(content)
            title = Self.jsVar(html, "msg_title").map(Self.htmlDecode) ?? meta("og:title") ?? ""
            nickname = Self.jsVar(html, "nickname").map(Self.htmlDecode)
            authorVar = Self.jsVar(html, "author").map(Self.htmlDecode)
            ct = Self.jsVar(html, "ct").flatMap(Double.init)
            biz = Self.jsVar(html, "biz"); mid = Self.jsVar(html, "mid"); idx = Self.jsVar(html, "idx")
            sn = Self.jsVarStrict(html, "sn") ?? Self.queryValue(meta("og:url"), "sn")
            desc = Self.jsVar(html, "msg_desc").map(Self.htmlDecode)
            coverURL = Self.jsVar(html, "msg_cdn_url")
            handle = Self.jsVar(html, "user_name")
        } else {
            // 短文 / 图片消息：没有 #js_content，正文在脚本数据里；元数据是 window.xxx = '' || '值' 和 key: '值' 的写法
            let showType = Self.jsVar(html, "item_show_type") ?? Self.windowVar(html, "item_show_type") ?? "0"
            guard !["5", "7"].contains(showType), let post = Self.postBlocks(html) else {
                try gate(html)
                throw ExtractError.gate("页面里没有找到正文（\(Self.kindName(showType))，item_show_type=\(showType)，暂不支持）")
            }
            blocks = post
            title = Self.windowVar(html, "msg_title") ?? meta("og:title") ?? Self.objField(html, "title") ?? ""
            nickname = Self.windowVar(html, "nickname") ?? Self.objField(html, "nick_name")
            authorVar = Self.objField(html, "author")
            ct = Self.windowVar(html, "ct").flatMap(Double.init)
            biz = Self.windowVar(html, "biz"); mid = Self.windowVar(html, "mid"); idx = Self.windowVar(html, "idx")
            sn = [Self.windowVar(html, "sn"), Self.objField(html, "sn")].compactMap { $0 }.first(where: Self.isHexID)
                ?? Self.queryValue(meta("og:url"), "sn")
            desc = Self.objField(html, "desc")
            coverURL = Self.windowVar(html, "msg_cdn_url")
            handle = Self.objField(html, "user_name")
        }

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
            author: authorName.isEmpty ? nil : authorName, authorHandle: handle, authorURL: nil,
            publishedAt: ct.map { Date(timeIntervalSince1970: $0) }, capturedAt: Date(),
            cover: coverURL.map { ImageRef(url: $0) }, summary: desc, blocks: blocks, extractor: Self.version,
            stats: ArticleStats(chars: 0, images: 0, imagesSaved: 0, videos: 0))
        art.recomputeStats()
        if art.stats.chars < 30 && art.stats.images == 0 { throw ExtractError.gate("正文过短（\(art.stats.chars) 字），疑似空壳") }
        return Extraction(article: art, rawSnapshots: [("source.html", raw)], imageReferer: Self.referer)
    }

    /// 找不到正文时：环境异常 / 已删除 / 违规 → 给出具体原因
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
        guard let v = jsVar(html, name), isHexID(v) else { return nil }
        return v
    }

    static func isHexID(_ v: String) -> Bool { v.range(of: "^[0-9a-f]{16,64}$", options: .regularExpression) != nil }

    static func queryValue(_ url: String?, _ key: String) -> String? {
        guard let url, let c = URLComponents(string: url) else { return nil }
        return c.queryItems?.first { $0.name == key }?.value
    }

    /// JS 字面量里的值：先解 JS 转义（\x26 → &），再解一次 HTML 实体（&lt; → <）
    static func htmlDecode(_ s: String) -> String { entityDecode(jsUnescape(s)) }

    /// HTML 实体，一遍解完（&amp;lt; → &lt;，不会连解两层）
    static func entityDecode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let re = try! NSRegularExpression(pattern: "&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});")
        let named: [String: String] = ["quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": " ", "amp": "&"]
        let ns = s as NSString
        var out = "", last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            var rep: String?
            if name.hasPrefix("#") {
                let hex = name.dropFirst().first.map { $0 == "x" || $0 == "X" } ?? false
                let code = UInt32(hex ? String(name.dropFirst(2)) : String(name.dropFirst()), radix: hex ? 16 : 10)
                rep = code.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else { rep = named[name] }
            out += rep ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// JS 字符串转义：\xHH \uHHHH \u{H…} \n \t \' \\ 等
    static func jsUnescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        let a = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        func hex(_ from: Int, _ n: Int) -> UInt32? {
            guard from + n <= a.count else { return nil }
            return UInt32(String(String.UnicodeScalarView(a[from..<from + n])), radix: 16)
        }
        var i = 0
        while i < a.count {
            guard a[i] == "\\", i + 1 < a.count else { out.append(a[i]); i += 1; continue }
            let n = a[i + 1]
            switch n {
            case "n": out.append("\n"); i += 2
            case "r": out.append("\r"); i += 2
            case "t": out.append("\t"); i += 2
            case "\n": i += 2                                    // 续行
            case "x":
                if let v = hex(i + 2, 2), let u = Unicode.Scalar(v) { out.append(u); i += 4 } else { out.append(n); i += 2 }
            case "u":
                if i + 2 < a.count, a[i + 2] == "{", let close = a[(i + 3)...].firstIndex(of: "}"),
                   let v = hex(i + 3, close - i - 3), let u = Unicode.Scalar(v) {
                    out.append(u); i = close + 1
                } else if var v = hex(i + 2, 4) {
                    i += 6
                    // 代理对 \uD83D\uDE00
                    if (0xD800...0xDBFF).contains(v), i + 1 < a.count, a[i] == "\\", a[i + 1] == "u", let lo = hex(i + 2, 4), (0xDC00...0xDFFF).contains(lo) {
                        v = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00); i += 6
                    }
                    if let u = Unicode.Scalar(v) { out.append(u) }
                } else { out.append(n); i += 2 }
            default: out.append(n); i += 2                       // \' \" \\ \/ 等
            }
        }
        return String(out)
    }

    // MARK: 短文 / 图片消息

    static func kindName(_ showType: String) -> String {
        switch showType {
        case "0": return "普通文章"
        case "5": return "视频消息"
        case "7": return "音频消息"
        case "8": return "图片消息"
        case "10": return "短文"
        default: return "未知类型"
        }
    }

    /// 文字在 text_page_info.content_noencode（JS 转义＋一层 HTML 实体），图片在 picture_page_info_list
    static func postBlocks(_ html: String) -> [Block]? {
        guard html.contains("text_page_info") || html.contains("picture_page_info_list") else { return nil }
        var blocks = postText(html).map(Clip.textBlocks) ?? []
        blocks += postImages(html).map { .image(ImageRef(url: $0)) }
        return blocks.isEmpty ? nil : blocks
    }

    static func postText(_ html: String) -> String? {
        let u = html.unicodeScalars
        var heads = matchEnds(html, "(?<![\\w$.])content_noencode\\s*:\\s*")
        // 页面里有两份：优先 text_page_info 里那份
        if let a = html.range(of: "text_page_info")?.lowerBound, let i = heads.firstIndex(where: { $0 > a }) {
            heads.insert(heads.remove(at: i), at: 0)
        }
        for h in heads {
            guard let lit = readLiteral(u, h) else { continue }
            let v = htmlDecode(lit.raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { return v }
        }
        return nil
    }

    /// picture_page_info_list: [ { cdn_url: '…', … }, … ]：先认 cdn_url，没有再收方括号里所有 qpic 图
    static func postImages(_ html: String) -> [String] {
        guard let r = html.range(of: "picture_page_info_list") else { return [] }
        let u = html.unicodeScalars
        var p = r.upperBound
        while p < u.endIndex, u[p] == ":" || u[p].properties.isWhitespace { p = u.index(after: p) }
        guard p < u.endIndex, u[p] == "[" else { return [] }
        let start = p
        var depth = 0
        var end: String.Index?
        while p < u.endIndex {
            let c = u[p]
            if c == "'" || c == "\"", let lit = readLiteral(u, p) { p = lit.end; continue }
            if c == "[" { depth += 1 } else if c == "]" { depth -= 1; if depth == 0 { end = u.index(after: p); break } }
            p = u.index(after: p)
        }
        guard let end else { return [] }
        let region = String(String.UnicodeScalarView(u[start..<end]))
        let ru = region.unicodeScalars
        var urls = matchEnds(region, "(?<![\\w$.])cdn_url\\s*:\\s*").compactMap { readLiteral(ru, $0).map { htmlDecode($0.raw) } }
        if urls.isEmpty {
            urls = matchEnds(region, "['\"](?=(?:https?:)?//mmbiz\\.qpic\\.cn/)").compactMap {
                readLiteral(ru, ru.index(before: $0)).map { htmlDecode($0.raw) }
            }
        }
        var seen = Set<String>()
        return urls.filter { !$0.isEmpty }.map(originalImage).filter { seen.insert($0).inserted }
    }

    /// window.name = '' || '值'（也认 window.a = window.b = '值'）：第一个非空字面量
    static func windowVar(_ html: String, _ name: String) -> String? {
        let u = html.unicodeScalars
        for head in matchEnds(html, "(?<![\\w$.])window\\.\(name)\\s*=(?!=)\\s*(?:window\\.[\\w$]+\\s*=(?!=)\\s*)*") {
            guard var lit = readLiteral(u, head) else { continue }
            while true {
                let v = htmlDecode(lit.raw)
                if !v.isEmpty { return v.count > 2000 ? nil : v }
                var p = skipSpaces(u, lit.end)
                guard p < u.endIndex, u[p] == "|" else { return nil }
                p = u.index(after: p)
                guard p < u.endIndex, u[p] == "|" else { return nil }
                guard let next = readLiteral(u, skipSpaces(u, u.index(after: p))) else { return nil }
                lit = next
            }
        }
        return nil
    }

    /// 页面数据对象里的 name: '值'（第一个后面跟字面量的）；空串当没有
    static func objField(_ html: String, _ name: String) -> String? {
        let u = html.unicodeScalars
        for head in matchEnds(html, "(?<![\\w$.])\(name)\\s*:\\s*") {
            guard let lit = readLiteral(u, head) else { continue }
            let v = htmlDecode(lit.raw)
            return v.isEmpty || v.count > 2000 ? nil : v
        }
        return nil
    }

    static func matchEnds(_ s: String, _ pattern: String) -> [String.Index] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s)?.upperBound }
    }

    /// 从 p 读一个 JS 字符串字面量（' 或 "，跳过反斜杠转义，不跨行）：引号里的原文＋字面量后的位置
    static func readLiteral(_ u: String.UnicodeScalarView, _ p0: String.Index) -> (raw: String, end: String.Index)? {
        guard p0 < u.endIndex, u[p0] == "'" || u[p0] == "\"" else { return nil }
        let q = u[p0]
        var p = u.index(after: p0)
        let start = p
        while p < u.endIndex {
            let c = u[p]
            if c == "\\" {
                p = u.index(after: p)
                if p < u.endIndex { p = u.index(after: p) }
            } else if c == q {
                return (String(String.UnicodeScalarView(u[start..<p])), u.index(after: p))
            } else if c == "\n" {
                return nil
            } else { p = u.index(after: p) }
        }
        return nil
    }

    static func skipSpaces(_ u: String.UnicodeScalarView, _ p0: String.Index) -> String.Index {
        var p = p0
        while p < u.endIndex, u[p].properties.isWhitespace { p = u.index(after: p) }
        return p
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
