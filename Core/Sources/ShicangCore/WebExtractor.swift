import Foundation
import AppKit
import WebKit
import SwiftSoup

/// 隐藏 WKWebView（挂在离屏窗口上，避免 JS 被节流）。无登录态：nonPersistent 数据存储。
@MainActor
public final class HiddenBrowser: NSObject, WKNavigationDelegate {
    let window: NSWindow
    public let webView: WKWebView
    private var navCont: CheckedContinuation<Void, Error>?
    private var httpBlocked = false

    /// 页面里的 http 子资源（图片、脚本、框架、ws）一律拦掉。系统 ATS 默认放行本机回环，网页能借此探本机端口，所以另加规则。
    /// WebKit 的 url-filter 只认正则的一个子集，**不支持 `|`**（`^(http|ws)://` 会编译失败），所以一个协议一条
    static let noHTTPJSON = #"[{"trigger":{"url-filter":"^http://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ws://"},"action":{"type":"block"}}]"#
    private static var noHTTPTask: Task<WKContentRuleList, Error>?

    /// 编译一次、大家共用；同时来的几次收藏等同一个结果。失败了下次再编
    static func noHTTP() async throws -> WKContentRuleList {
        let t: Task<WKContentRuleList, Error>
        if let running = noHTTPTask { t = running } else {
            t = Task { @MainActor in
                guard let store = WKContentRuleListStore.default() else { throw ExtractError.parse("系统规则库不可用") }
                guard let list = try await store.compileContentRuleList(forIdentifier: "shicang-no-http", encodedContentRuleList: noHTTPJSON) else {
                    throw ExtractError.parse("规则编译没有结果")
                }
                return list
            }
            noHTTPTask = t
        }
        do { return try await t.value } catch {
            if noHTTPTask == t { noHTTPTask = nil }
            throw error
        }
    }

    public init(userAgent: String) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 2000), configuration: cfg)
        webView.customUserAgent = userAgent
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 2000),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.isReleasedWhenClosed = false
        super.init()
        webView.navigationDelegate = self
        window.orderBack(nil)
    }

    /// 装上拦 http 的规则；装不上就不加载任何网页
    func blockHTTP() async throws {
        guard !httpBlocked else { return }
        let rules: WKContentRuleList
        do { rules = try await Self.noHTTP() } catch {
            throw ExtractError.parse("拦截 http 的规则没装上，不加载网页（\(Self.reason(error))）")
        }
        webView.configuration.userContentController.add(rules)
        httpBlocked = true
    }

    /// 加载页面。到时间还没触发 didFinish（常见：统计脚本、慢资源拖着）就停止加载、按「已加载」继续，由后续的正文检查决定成败
    public func load(_ url: URL, timeout: Double = 25) async throws {
        try await blockHTTP()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            navCont = c
            webView.load(URLRequest(url: NetPolicy.secure(url), timeoutInterval: timeout))   // 不允许 http
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, let cont = self.navCont else { return }
                self.navCont = nil
                self.webView.stopLoading()
                cont.resume()
            }
        }
    }

    /// 轮询直到 JS 条件为真（SPA 渲染需要时间）
    public func waitFor(_ condition: String, timeout: Double = 12, interval: Double = 0.5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let ok = try? await js("return !!(\(condition));") as? Bool, ok { return true }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return false
    }

    public var html: String {
        get async { (try? await js("return document.documentElement.outerHTML;") as? String) ?? "" }
    }

    static func reason(_ error: Error) -> String {
        if case ExtractError.parse(let s) = error { return s }
        let e = error as NSError
        return (e.userInfo["NSHelpAnchor"] as? String) ?? "\(e.domain) \(e.code)"
    }

    /// 跳转引起的取消（-999）、策略中断（WebKit 102）不算失败
    private func ignorable(_ error: Error) -> Bool {
        let e = error as NSError
        return (e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled) || (e.domain == "WebKitErrorDomain" && e.code == 102)
    }

    public func js(_ code: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(code, arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    public func close() { window.orderOut(nil); window.contentView = nil }

    /// 不允许 http：页面要跳到 http 的，主页面改走 https 重新加载，子框架直接拦掉
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let u = navigationAction.request.url, u.scheme?.lowercased() == "http" else { return .allow }
        if navigationAction.targetFrame?.isMainFrame ?? true {
            var r = navigationAction.request
            r.url = NetPolicy.secure(u)
            webView.load(r)
        }
        return .cancel
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { navCont?.resume(); navCont = nil }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if ignorable(error) { return }
        navCont?.resume(throwing: error); navCont = nil
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if ignorable(error) { return }
        navCont?.resume(throwing: error); navCont = nil
    }
}

/// 通用网页：WKWebView 渲染 + Readability.js 抽正文 → HTMLBlockBuilder
@MainActor
public struct WebExtractor {
    public static let version = "web-readability@0.2"
    public init() {}

    static let readability: String? = {
        guard let u = Bundle.module.url(forResource: "Readability", withExtension: "js") else { return nil }
        return try? String(contentsOf: u, encoding: .utf8)
    }()

    public func extract(_ t: CaptureTarget, settle: Double = 2.0) async throws -> Extraction {
        let b = HiddenBrowser(userAgent: UA.macSafari)
        defer { b.close() }
        try await b.load(t.url)
        try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))   // 等懒加载
        guard let lib = Self.readability else { throw ExtractError.parse("缺 Readability.js") }
        let code = lib + """
        ;
        const doc = document.cloneNode(true);
        // Readability 先按 <br><br> 切段、后才把 <font> 换成 <span>；<font> 不算行内元素会把段落截断
        // （Paul Graham 的脚注 [1] 被切成单独一段）→ 先换掉
        doc.querySelectorAll('font').forEach(f => { const s = doc.createElement('span'); while (f.firstChild) s.appendChild(f.firstChild); f.replaceWith(s); });
        const canon = (document.querySelector('link[rel="canonical"]') || {}).href || (document.querySelector('meta[property="og:url"]') || {}).content || "";
        const r = new Readability(doc, {keepClasses: false}).parse();
        return r ? {title: r.title || document.title, byline: r.byline || "", content: r.content || "", siteName: r.siteName || "",
                    published: r.publishedTime || "", excerpt: r.excerpt || "", len: r.length || 0,
                    finalURL: location.href, canonical: canon, html: document.documentElement.outerHTML} : {finalURL: location.href, canonical: canon, html: document.documentElement.outerHTML};
        """
        guard let res = try await b.js(code) as? [String: Any] else { throw ExtractError.parse("Readability 无返回") }
        let finalURL = URL(string: res["finalURL"] as? String ?? "") ?? t.url
        guard let content = res["content"] as? String, !content.isEmpty else { throw ExtractError.gate("Readability 没找到正文") }
        let doc = try SwiftSoup.parseBodyFragment(content, finalURL.absoluteString)
        let builder = HTMLBlockBuilder(baseURL: finalURL) { el in
            for a in ["data-src", "data-original", "src"] {
                if let v = try? el.attr(a), !v.isEmpty, !v.hasPrefix("data:") { return v }
            }
            return nil
        }
        let blocks = try builder.build(doc.body()!)
        // 同一篇文章的不同地址（跳转、Wikipedia 重定向页、带追踪参数）→ 用页面声明的规范地址去重，原地址记成别名
        let ct = Self.canonicalTarget(t, declared: res["canonical"] as? String, final: finalURL)
        let canonical = ct.key
        let published = (res["published"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        var art = Article(
            id: Capture.hash(canonical), canonicalId: canonical, aliases: ct.key == t.key ? [] : [t.key], source: .web,
            url: ct.url.absoluteString, capturedURL: t.capturedURL,
            title: Self.stripSiteSuffix(res["title"] as? String ?? "", site: res["siteName"] as? String),
            author: [(res["byline"] as? String), (res["siteName"] as? String)].compactMap { ($0?.isEmpty ?? true) ? nil : $0 }.joined(separator: " · "),
            authorHandle: nil, authorURL: nil, publishedAt: published, capturedAt: Date(), cover: nil,
            summary: res["excerpt"] as? String, blocks: blocks, extractor: Self.version,
            stats: ArticleStats(chars: 0, images: 0, imagesSaved: 0, videos: 0))
        art.recomputeStats()
        if art.stats.chars < 100 { throw ExtractError.gate("正文过短（\(art.stats.chars) 字）") }
        let html = (res["html"] as? String ?? "").data(using: .utf8) ?? Data()
        return Extraction(article: art, rawSnapshots: [("source.html", html)], imageReferer: finalURL.absoluteString)
    }

    /// 规范地址：优先页面 <link rel=canonical>/og:url（必须同站、不能是首页——不少站把所有页的 canonical 都写成首页），
    /// 其次跳转后的最终地址（同样不能落到首页）；判出来是 X/公众号等别的平台就不认。
    nonisolated static func canonicalTarget(_ t: CaptureTarget, declared: String?, final: URL) -> CaptureTarget {
        func site(_ u: URL) -> String {
            var h = (u.host ?? "").lowercased()
            for p in ["www.", "m.", "mobile."] where h.hasPrefix(p) { h.removeFirst(p.count) }
            return h
        }
        func isRoot(_ u: URL) -> Bool { u.path.isEmpty || u.path == "/" }
        func target(_ s: String?) -> CaptureTarget? {
            guard let s, let u = URL(string: s, relativeTo: final)?.absoluteURL, ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
                  let c = try? Capture.classify(u.absoluteString), c.source == .web else { return nil }
            return c
        }
        let rootOK = isRoot(t.url)
        if let c = target(declared), site(c.url) == site(final), rootOK || !isRoot(c.url) {
            return CaptureTarget(source: .web, url: c.url, capturedURL: t.capturedURL, key: c.key)
        }
        if let c = target(final.absoluteString), rootOK || !isRoot(c.url) {
            return CaptureTarget(source: .web, url: c.url, capturedURL: t.capturedURL, key: c.key)
        }
        return t
    }

    /// 「标题 - 少数派」「标题 | 站名」→「标题」（只在后缀正好是站名时去掉）
    nonisolated static func stripSiteSuffix(_ title: String, site: String?) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let full = site?.trimmingCharacters(in: .whitespacesAndNewlines), !full.isEmpty else { return t }
        let seps = [" - ", " | ", " – ", " — ", " _ ", "｜", " · "]
        // 站名本身也可能带口号：「少数派 - 高品质数字消费指南」→ 也认「少数派」
        var names = [full]
        for sep in seps { if let head = full.components(separatedBy: sep).first, head != full, !head.isEmpty { names.append(head) } }
        for name in names {
            for sep in seps where t.hasSuffix(sep + name) {
                let core = String(t.dropLast(sep.count + name.count)).trimmingCharacters(in: .whitespaces)
                if !core.isEmpty { return core }
            }
        }
        return t
    }
}
