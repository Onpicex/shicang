import Foundation
import SwiftSoup

/// 公众号兜底：隐藏浏览器（移动 UA、无登录态）渲染后取整页 HTML，交给同一套解析
@MainActor
public struct WeChatWebExtractor {
    public static let version = "wechat-webview@0.1"
    public init() {}

    public func extract(_ t: CaptureTarget) async throws -> Extraction {
        let b = HiddenBrowser(userAgent: UA.iPhoneSafari)
        defer { b.close() }
        try await b.load(t.url)
        _ = await b.waitFor("document.querySelector('#js_content') && document.querySelector('#js_content').innerText.length > 0", timeout: 8)
        let html = await b.html
        var ex = try WeChatExtractor().parse(html: html, raw: Data(html.utf8), target: t)
        ex.article.extractor = Self.version
        return ex
    }
}

/// X 兜底：fxtwitter 不可用时，用不登录的隐藏浏览器打开推文页，只取主推（不取评论区）
@MainActor
public struct XWebExtractor {
    public static let version = "x-webview@0.2"
    public init() {}

    public func extract(_ t: CaptureTarget) async throws -> Extraction {
        guard let m = t.url.path.range(of: #"/status/(\d+)"#, options: .regularExpression),
              let statusID = t.url.path[m].split(separator: "/").last.map(String.init) else { throw ExtractError.parse("链接里没有推文编号") }
        let b = HiddenBrowser(userAgent: UA.macSafari)
        defer { b.close() }
        try await b.load(t.url)
        _ = await b.waitFor(Self.ready(statusID), timeout: 15)
        guard let r = try await b.js(Self.script(statusID)) as? [String: Any] else { throw ExtractError.parse("X 网页无返回") }
        if (r["found"] as? Bool) != true {
            let body = r["body"] as? String ?? ""
            let articles = r["articles"] as? Int ?? 0
            if body.contains("doesn’t exist") || body.contains("doesn't exist") || body.contains("不存在") || body.contains("已被删除") {
                throw ExtractError.gate("推文不存在或已删除（X 网页）")
            }
            if articles > 0 { throw ExtractError.gate("X 网页上找不到这条推文（页面结构可能改了）") }
            if body.contains("受保护") || body.contains("protected") { throw ExtractError.gate("推文受保护（X 网页）") }
            // 一条都没渲染出来、页面只剩登录提示，才算登录墙（未登录页本身到处都有「登录」按钮）
            if body.contains("Sign in") || body.contains("登录") { throw ExtractError.gate("X 网页没渲染出推文（可能要求登录，拾藏不登录 X）") }
            throw ExtractError.gate("X 网页没渲染出推文")
        }
        let finalURL = URL(string: r["url"] as? String ?? "") ?? t.url
        var blocks: [Block] = []
        if let html = r["html"] as? String, !html.isEmpty {
            let doc = try SwiftSoup.parseBodyFragment(html, finalURL.absoluteString)
            let builder = HTMLBlockBuilder(baseURL: finalURL) { el in
                let v = (try? el.attr("src")) ?? ""
                return v.contains("pbs.twimg.com/media") ? XExtractor.origImage(v) : nil
            }
            blocks = try builder.build(doc.body()!)
        }
        var cover: ImageRef?
        if let c = r["cover"] as? String, !c.isEmpty { cover = ImageRef(url: XExtractor.origImage(c)) }
        let existing = Set(blocks.compactMap { $0.image?.url })
        for p in (r["photos"] as? [String] ?? []) where !existing.contains(XExtractor.origImage(p)) {
            blocks.append(.image(ImageRef(url: XExtractor.origImage(p))))
        }
        if (r["video"] as? Bool) == true {
            blocks.append(.video(VideoRef(pageURL: t.url.absoluteString, streamURL: nil,
                                          cover: (r["poster"] as? String).flatMap { $0.isEmpty ? nil : ImageRef(url: $0) }, durationSec: nil)))
        }
        let author = (r["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let handle = (r["handle"] as? String).flatMap { $0.isEmpty ? nil : ($0.hasPrefix("@") ? $0 : "@" + $0) }
        var title = (r["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            let first = blocks.first { $0.type == .paragraph }?.plainText ?? ""
            let line = first.split(separator: "\n").first.map(String.init) ?? first
            title = line.count > 60 ? String(line.prefix(60)) + "…" : line
            if title.isEmpty { title = "\(handle ?? "X") 的推文" }
        }
        let canonical = t.key
        var art = Article(
            id: Capture.hash(canonical), canonicalId: canonical, aliases: [], source: .x,
            url: t.url.absoluteString, capturedURL: t.capturedURL, title: title, author: author, authorHandle: handle,
            authorURL: handle.map { "https://x.com/" + $0.dropFirst() }, publishedAt: (r["time"] as? String).flatMap(Coders.parseDate),
            capturedAt: Date(), cover: cover, summary: nil, blocks: blocks, extractor: Self.version,
            stats: ArticleStats(chars: 0, images: 0, imagesSaved: 0, videos: 0))
        art.recomputeStats()
        if art.stats.chars == 0 && art.stats.images == 0 && art.stats.videos == 0 { throw ExtractError.gate("推文内容为空（X 网页）") }
        let html = await b.html
        return Extraction(article: art, rawSnapshots: [("source.html", Data(html.utf8))], imageReferer: nil)
    }

    /// 两套页面结构都认：2026-11 起未登录页是 xds/base-ui（无 data-testid），旧版是 data-testid
    static let textSel = #"[data-article-part="body"], [data-testid="twitterArticleRichTextView"], [data-testid="longformRichTextComponent"], [data-testid="tweetText"], div[dir="auto"][lang], img[src*="pbs.twimg.com/media/"], video"#

    static func ready(_ id: String) -> String {
        """
        (() => { const a = [...document.querySelectorAll('article')].find(a => a.querySelector('a[href$="/status/\(id)"]'));
                 return a && a.querySelector('\(textSel)'); })()
        """
    }

    /// 主推＝含本条 status 链接、且实际显示的那个 article（新版页面同一条会渲染两份）
    static func script(_ id: String) -> String {
        """
        const body = document.body ? document.body.innerText.slice(0, 3000) : '';
        const arts = [...document.querySelectorAll('article')];
        const isMain = a => !!a.querySelector('a[href$="/status/\(id)"]');
        const art = arts.find(a => isMain(a) && a.getBoundingClientRect().width > 0) || arts.find(isMain);
        if (!art) return {found: false, body, url: location.href, articles: arts.length};
        const q = s => art.querySelector(s);
        const abody = q('[data-article-part="body"]') || q('[data-testid="twitterArticleRichTextView"]') || q('[data-testid="longformRichTextComponent"]');
        const textEl = abody || q('[data-testid="tweetText"]') || q('div[dir="auto"][lang]');
        // pre-wrap 里的换行是字面 \\n：先换成 <br>，否则转块时被当空白折叠
        let html = '';
        if (textEl) {
          const w = document.createTreeWalker(textEl, NodeFilter.SHOW_TEXT);
          const ts = []; while (w.nextNode()) ts.push(w.currentNode);
          for (const t of ts) {
            if (!t.nodeValue.includes('\\n') || !t.parentElement) continue;
            const ws = getComputedStyle(t.parentElement).whiteSpace;
            if (!/^(pre|break-spaces)/.test(ws)) continue;
            const f = document.createDocumentFragment();
            t.nodeValue.split('\\n').forEach((p, i) => { if (i) f.appendChild(document.createElement('br')); if (p) f.appendChild(document.createTextNode(p)); });
            t.replaceWith(f);
          }
          const c = textEl.cloneNode(true);
          c.querySelectorAll('style, script, svg, button').forEach(e => e.remove());
          // t.co 短链：显示文字是完整地址（没被截成 …）时还原成真实地址
          c.querySelectorAll('a[href^="https://t.co/"]').forEach(a => {
            const tx = a.textContent.trim();
            if (tx.endsWith('…') || tx.endsWith('...')) return;
            if (/^https?:\\/\\/\\S+$/i.test(tx)) a.setAttribute('href', tx);
            else if (/^[\\w.-]+\\.[a-z]{2,}(\\/\\S*)?$/i.test(tx)) a.setAttribute('href', 'https://' + tx);
          });
          html = c.outerHTML;
        }
        const titleEl = q('[data-article-part="title"]') || document.querySelector('[data-testid="twitter-article-title"]');
        const coverEl = q('[data-article-part="cover"] img');
        const inBody = e => abody && abody.contains(e);
        const photos = [...art.querySelectorAll('[data-testid="tweetPhoto"] img, img[src*="pbs.twimg.com/media/"]')]
          .filter(i => !inBody(i) && i !== coverEl && !(textEl && textEl.contains(i))).map(i => i.src);
        const video = q('video, [data-testid="videoPlayer"]');
        const thumb = q('img[src*="video_thumb"]');
        let time = '';
        const te = q('time'); if (te) time = te.getAttribute('datetime') || '';
        if (!time) {
          const sc = [...art.querySelectorAll('script')].map(s => s.textContent).find(t => t.includes('formatFullTimestamp')) || '';
          const m = sc.match(/"timestamp":(\\d+)/); if (m) time = new Date(Number(m[1])).toISOString();
        }
        let name = '', handle = '';
        const un = q('[data-testid="User-Name"]');
        if (un) { const ls = un.innerText.split('\\n'); name = ls[0] || ''; handle = ls.find(l => l.startsWith('@')) || ''; }
        else {
          const av = q('[data-post-avatar] a'); const href = av ? av.getAttribute('href') : '';
          if (href) {
            handle = href.replace(/^\\//, '');
            const links = [...art.querySelectorAll('a[href="' + href + '"]')];
            for (const l of links) { const d = l.querySelector('[dir="auto"]'); if (d && d.innerText.trim()) { name = d.innerText.trim(); break; } }
          }
        }
        return {found: !!(textEl || photos.length || video || thumb), body, url: location.href, articles: arts.length,
                isArticle: !!abody, name, handle, time, title: titleEl ? titleEl.innerText : '', html,
                cover: coverEl ? coverEl.src : '', photos: [...new Set(photos)],
                video: !!(video || thumb), poster: video && video.getAttribute('poster') ? video.getAttribute('poster') : (thumb ? thumb.src : '')};
        """
    }
}

/// 通用网页兜底：不跑 JS，直接取 HTML，挑正文最多的容器
public struct WebPlainExtractor: Sendable {
    public static let version = "web-plain@0.2"
    public init() {}

    public func extract(_ t: CaptureTarget) async throws -> Extraction {
        let (data, resp) = try await HTTP.get(t.url, ua: UA.macSafari, headers: ["Accept": "text/html,application/xhtml+xml"])
        guard resp.statusCode == 200 else { throw ExtractError.http(resp.statusCode, t.url.absoluteString) }
        let finalURL = resp.url ?? t.url
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw ExtractError.parse("无法解码网页") }
        let doc = try SwiftSoup.parse(html, finalURL.absoluteString)
        try doc.select("script, style, noscript, nav, footer, header, aside, form, iframe, .comments, #comments, .sidebar, #sidebar").remove()
        let candidates = try doc.select("article, main, [role=main], .post-content, .entry-content, .article-content, .post, #content, .content").array()
        let body = doc.body()
        let root = try (candidates.max { try $0.text().count < $1.text().count } ?? body)
        guard let root else { throw ExtractError.parse("没有 body") }
        let builder = HTMLBlockBuilder(baseURL: finalURL) { el in
            // 占位/装饰小图（1×1 透明 gif、导航小图标）不算正文图
            let w = Int((try? el.attr("width")) ?? ""), h = Int((try? el.attr("height")) ?? "")
            if let w, w < 40 { return nil }
            if let h, h < 40 { return nil }
            if let w, let h, h < 60, w > h * 6 { return nil }                       // 页头横幅
            if el.hasAttr("usemap") || el.hasAttr("ismap") { return nil }            // 导航热区图
            for a in ["data-src", "data-original", "src"] {
                if let v = try? el.attr(a), !v.isEmpty, !v.hasPrefix("data:") { return v }
            }
            return nil
        }
        let blocks = try builder.build(root)
        func meta(_ sel: String) -> String? { (try? doc.select(sel).first()?.attr("content")).flatMap { $0.isEmpty ? nil : $0 } }
        let site = meta("meta[property=og:site_name]")
        let title = WebExtractor.stripSiteSuffix(meta("meta[property=og:title]") ?? (try? doc.title()) ?? "", site: site)
        let canonical = t.key
        var art = Article(
            id: Capture.hash(canonical), canonicalId: canonical, aliases: [], source: .web,
            url: t.url.absoluteString, capturedURL: t.capturedURL, title: title,
            author: meta("meta[name=author]") ?? site, authorHandle: nil, authorURL: nil,
            publishedAt: meta("meta[property=article:published_time]").flatMap(Coders.parseDate), capturedAt: Date(),
            cover: nil, summary: meta("meta[name=description]") ?? meta("meta[property=og:description]"),
            blocks: blocks, extractor: Self.version, stats: ArticleStats(chars: 0, images: 0, imagesSaved: 0, videos: 0))
        art.recomputeStats()
        if art.stats.chars < 100 { throw ExtractError.gate("正文过短（\(art.stats.chars) 字）") }
        return Extraction(article: art, rawSnapshots: [("source.html", data)], imageReferer: finalURL.absoluteString)
    }
}

// MARK: - 调度：主通道 → 兜底通道

public struct ExtractFailure: Error, CustomStringConvertible, Sendable {
    public var message: String
    public var transient: Bool       // 暂时性（网络、限流、超时、验证页）→ 自动重试
    public var description: String { message }
}

public enum Extractors {
    /// 按平台跑主通道，失败（且不是「确定性失败」如已删除）再跑兜底
    public static func run(_ t: CaptureTarget, timeout: Double = 90) async throws -> Extraction {
        do {
            return try await withTimeout(timeout) { try await primaryThenFallback(t) }
        } catch let e as ExtractFailure {
            throw httpHint(e, t)
        } catch {
            throw httpHint(classify(error), t)
        }
    }

    /// 你复制的是 http 链接、按 https 没抓到 → 先说清楚可能的原因（不允许 http 连接，见 NetPolicy）
    static func httpHint(_ f: ExtractFailure, _ t: CaptureTarget) -> ExtractFailure {
        guard t.source == .web, let u = URL(string: t.capturedURL), u.scheme?.lowercased() == "http" else { return f }
        return ExtractFailure(message: "这个网站可能不支持 https（原链接是 http，已禁止 http 连接）：\(f.message)", transient: f.transient)
    }

    static func primaryThenFallback(_ t: CaptureTarget) async throws -> Extraction {
        switch t.source {
        case .x:
            do { return try await XExtractor().extract(t) } catch {
                if case ExtractError.gate = error { throw error }        // 已删除/受保护：网页也看不到
                do { return try await XWebExtractor().extract(t) } catch let e2 { throw combine(primary: error, fallback: e2) }
            }
        case .wechat:
            do { return try await WeChatExtractor().extract(t) } catch {
                if case ExtractError.gate(let why) = error, !why.contains("验证") { throw error }   // 已删除/违规/迁移
                do { return try await WeChatWebExtractor().extract(t) } catch let e2 { throw combine(primary: error, fallback: e2) }
            }
        case .web:
            do { return try await WebExtractor().extract(t) } catch {
                do { return try await WebPlainExtractor().extract(t) } catch let e2 { throw combine(primary: error, fallback: e2) }
            }
        case .xhs:
            throw ExtractError.unsupported("小红书暂不做")
        case .clip:
            throw ExtractError.unsupported("剪藏没有原文可抓")
        }
    }

    /// 两个通道都失败：主通道原因在前；只要任一通道是暂时性就算暂时性（值得自动重试）
    static func combine(primary: Error, fallback: Error) -> ExtractFailure {
        let a = classify(primary), b = classify(fallback)
        let msg = a.message == b.message ? a.message : "\(a.message)；兜底：\(b.message)"
        return ExtractFailure(message: msg, transient: a.transient || b.transient)
    }

    public static func classify(_ error: Error) -> ExtractFailure {
        if let f = error as? ExtractFailure { return f }
        if let e = error as? ExtractError {
            switch e {
            case .unsupported(let s): return ExtractFailure(message: s, transient: false)
            case .gate(let s): return ExtractFailure(message: s, transient: s.contains("验证") || s.contains("没渲染出"))
            case .parse(let s): return ExtractFailure(message: "解析失败：\(s)", transient: false)
            case .http(let code, _):
                let transient = code == 0 || code == 403 || code == 408 || code == 429 || code >= 500
                return ExtractFailure(message: "网站返回 HTTP \(code)", transient: transient)
            }
        }
        if error is TimeoutError { return ExtractFailure(message: "处理超时", transient: true) }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return ExtractFailure(message: "网络错误：\(ns.localizedDescription)", transient: true)
        }
        return ExtractFailure(message: ns.localizedDescription, transient: true)
    }
}

public struct TimeoutError: Error {}

public func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await op() }
        g.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); throw TimeoutError() }
        defer { g.cancelAll() }
        return try await g.next()!
    }
}
