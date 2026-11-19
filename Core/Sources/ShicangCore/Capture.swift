import Foundation
import CryptoKit

/// 收藏入口：从分享文字里抠链接 → 判平台 → 规范化 → 去重键
public struct CaptureTarget: Sendable {
    public var source: Source
    public var url: URL                 // 规范化后的链接
    public var capturedURL: String
    public var key: String              // 抓取前就能算出的去重键（公众号短链抓取后会再得到 biz/mid/idx 键）
    public var tweetID: String?
}

public enum Capture {
    /// 文字里的网页链接：优先写了 http(s):// 的；都没写才用 example.com 这种裸域名
    public static func firstURL(in text: String) -> URL? {
        let all = webLinks(in: text)
        return (all.first { $0.explicit } ?? all.first)?.url
    }

    /// 所有 http(s) 链接，explicit＝原文里写了 http:// 或 https://（不是系统从裸域名猜出来的）
    static func webLinks(in text: String) -> [(url: URL, range: NSRange, explicit: Bool)] {
        let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let ns = text as NSString
        return (det?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []).compactMap { m in
            guard let u = m.url, let s = u.scheme?.lowercased(), s == "http" || s == "https" else { return nil }
            let raw = ns.substring(with: m.range).lowercased()
            return (u, m.range, raw.hasPrefix("http://") || raw.hasPrefix("https://"))
        }
    }

    public static func classify(_ input: String) throws -> CaptureTarget {
        guard let original = firstURL(in: input) else { throw ExtractError.unsupported("没找到链接") }
        let raw = NetPolicy.secure(original)       // 不允许 http：http:// 链接一律按 https 抓（去重键也随之统一）
        let host = (raw.host ?? "").lowercased()
        let xHosts = ["x.com", "twitter.com", "mobile.twitter.com", "mobile.x.com", "www.x.com", "www.twitter.com",
                      "fxtwitter.com", "fixupx.com", "vxtwitter.com", "fixvx.com"]
        if xHosts.contains(host) {
            let parts = raw.pathComponents.filter { $0 != "/" }
            if let i = parts.firstIndex(of: "status"), i + 1 < parts.count, parts[i + 1].allSatisfy(\.isNumber) {
                let id = parts[i + 1]
                let user = i > 0 ? parts[i - 1] : "i"
                return CaptureTarget(source: .x, url: URL(string: "https://x.com/\(user)/status/\(id)")!,
                                     capturedURL: original.absoluteString, key: "x:\(id)", tweetID: id)
            }
            throw ExtractError.unsupported("X 链接里没有 status id：\(original.absoluteString)")
        }
        if host == "mp.weixin.qq.com" {
            var c = URLComponents(url: raw, resolvingAgainstBaseURL: false)!
            c.fragment = nil
            if raw.path.hasPrefix("/s/") {           // 短链 /s/<code>
                c.query = nil
                let code = String(raw.path.dropFirst(3))
                return CaptureTarget(source: .wechat, url: c.url!, capturedURL: original.absoluteString, key: "wechat:s/\(code)")
            }
            let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            if let biz = q["__biz"], let mid = q["mid"], let idx = q["idx"] {
                c.queryItems = ["__biz", "mid", "idx", "sn"].compactMap { k in q[k].map { URLQueryItem(name: k, value: $0) } }
                return CaptureTarget(source: .wechat, url: c.url!, capturedURL: original.absoluteString, key: "wechat:\(biz):\(mid):\(idx)")
            }
            return CaptureTarget(source: .wechat, url: raw, capturedURL: original.absoluteString, key: "wechat:url:\(raw.absoluteString)")
        }
        if host.hasSuffix("xiaohongshu.com") || host.hasSuffix("xhslink.com") || host.hasSuffix("xhslink.cn") {
            throw ExtractError.unsupported("暂不支持小红书")
        }
        // 通用网页：去掉 utm_* / fragment
        var c = URLComponents(url: raw, resolvingAgainstBaseURL: false)!
        c.fragment = nil
        c.host = c.host?.lowercased()
        let items = (c.queryItems ?? []).filter { !$0.name.lowercased().hasPrefix("utm_") && !["spm", "from", "share_source"].contains($0.name) }
        c.queryItems = items.isEmpty ? nil : items
        return CaptureTarget(source: .web, url: c.url!, capturedURL: original.absoluteString, key: "web:\(c.url!.absoluteString)")
    }

    /// 文件夹名 = 去重键 SHA256 前 16 位十六进制
    public static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
