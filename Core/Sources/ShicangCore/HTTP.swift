import Foundation

public enum UA {
    public static let iPhoneSafari = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
    public static let iPhoneWeChat = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.50(0x18003237) NetType/WIFI Language/zh_CN"
    public static let macSafari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
    public static let app = "Shicang/0.1"
}

/// 网络规则：**不允许 http 连接，没有例外**（本机 localhost 也不行）。
/// App 里还有系统 ATS 兜底（Info.plist 不开任何例外）；但 ATS 默认放行回环 http，命令行版又没有 ATS，所以全靠这里拦。
public enum NetPolicy {
    /// 只允许 https
    public static func allowed(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
    }

    /// http → https；显式写的 :80 一并去掉
    public static func secure(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http", var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.scheme = "https"
        if c.port == 80 { c.port = nil }
        return c.url ?? url
    }

    /// 发请求前的总闸：升级不了的（ftp:// 等）直接报错
    static func checked(_ url: URL) throws -> URL {
        let u = secure(url)
        guard allowed(u) else { throw ExtractError.unsupported("只允许 https 连接：\(url.absoluteString)") }
        return u
    }

    static let redirectGuard = RedirectGuard()
}

/// 跳转到 http 的一律改成 https 再跟；改不了的就不跟，按原响应返回
final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let u = request.url else { completionHandler(nil); return }
        let s = NetPolicy.secure(u)
        guard NetPolicy.allowed(s) else { completionHandler(nil); return }
        var r = request
        r.url = s
        completionHandler(r)
    }
}

public enum HTTP {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral   // 无 cookie、无缓存：任何请求都不带登录态
        cfg.timeoutIntervalForRequest = 30
        cfg.httpCookieAcceptPolicy = .never
        return URLSession(configuration: cfg, delegate: NetPolicy.redirectGuard, delegateQueue: nil)
    }()

    /// GET。http 地址自动换成 https（回环除外），跳转同样处理
    public static func get(_ url: URL, ua: String, headers: [String: String] = [:], retries: Int = 2) async throws -> (Data, HTTPURLResponse) {
        let url = try NetPolicy.checked(url)
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        var lastError: Error = ExtractError.http(0, url.absoluteString)
        for attempt in 0...retries {
            do {
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw ExtractError.http(0, url.absoluteString) }
                if (500...599).contains(http.statusCode) || http.statusCode == 429 {
                    lastError = ExtractError.http(http.statusCode, url.absoluteString)
                } else {
                    return (data, http)
                }
            } catch { lastError = error }
            if attempt < retries { try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 800_000_000) }
        }
        throw lastError
    }
}
