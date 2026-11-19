import Foundation

/// 阅读视图：文章 → 一页 HTML。图片用相对路径 images/xx（由 App 的 shicang-reader:// 处理器从文章目录读），
/// CSP 禁止一切外部加载：阅读时不连任何网站（不泄露阅读行为、不被追踪）。
public enum ReaderHTML {
    public static func render(_ a: Article, ai: AIResult? = nil, highlights: [Highlight] = []) -> String {
        var body = ""
        var listStack: [Bool] = []          // 打开着的列表：ordered?
        func closeLists(to depth: Int) {
            while listStack.count > depth { body += listStack.removeLast() ? "</ol>\n" : "</ul>\n" }
        }

        for b in a.blocks {
            if b.type != .listItem { closeLists(to: 0) }
            switch b.type {
            case .heading:
                let l = min(max((b.level ?? 2) + 1, 2), 6)     // 文章标题占 h1，正文标题从 h2 起
                body += "<h\(l)>\(inline(b.inlines))</h\(l)>\n"
            case .paragraph:
                body += "<p>\(inline(b.inlines))</p>\n"
            case .quote:
                body += "<blockquote><p>\(inline(b.inlines))</p></blockquote>\n"
            case .listItem:
                let depth = max(b.depth ?? 0, 0) + 1
                let ordered = b.ordered ?? false
                closeLists(to: depth)
                if listStack.count == depth && listStack.last != ordered { closeLists(to: depth - 1) }
                while listStack.count < depth { listStack.append(ordered); body += ordered ? "<ol>\n" : "<ul>\n" }
                body += "<li>\(inline(b.inlines))</li>\n"
            case .code:
                body += codeCard(b.text ?? "", language: b.language)
            case .table:
                let rows = b.rows ?? []
                guard !rows.isEmpty else { continue }
                body += "<div class=\"table\"><table>\n"
                for (i, r) in rows.enumerated() {
                    let tag = (i == 0 && (b.header ?? false)) ? "th" : "td"
                    body += "<tr>" + r.map { "<\(tag)>\(esc($0))</\(tag)>" }.joined() + "</tr>\n"
                }
                body += "</table></div>\n"
            case .image:
                guard let img = b.image else { continue }
                body += figure(img)
            case .video:
                guard let v = b.video else { continue }
                let cover = v.cover?.file.map { "<img src=\"\(attr($0))\" alt=\"\">" } ?? "<div class=\"noposter\"></div>"
                body += "<a class=\"video\" href=\"\(attr(v.pageURL))\">\(cover)<span class=\"play\">▶ 在原网页播放</span></a>\n"
            case .embed:
                guard let e = b.embed else { continue }
                var inner = ""
                if let au = e.author, !au.isEmpty { inner += "<div class=\"eauthor\">\(esc(au))</div>" }
                if let t = e.title, !t.isEmpty { inner += "<div class=\"etitle\">\(esc(t))</div>" }
                if let t = e.text, !t.isEmpty { inner += "<div class=\"etext\">\(esc(t).replacingOccurrences(of: "\n", with: "<br>"))</div>" }
                body += "<a class=\"embed\" href=\"\(attr(e.url))\">\(inner.isEmpty ? esc(e.url) : inner)</a>\n"
            case .divider:
                body += "<hr>\n"
            }
        }
        closeLists(to: 0)

        var meta: [String] = [sourceName(a.source)]
        if let au = a.author, !au.isEmpty {          // 只显示 @账号；公众号的 gh_ 内部编号留在数据里不展示
            var s = esc(au)
            if let h = a.authorHandle, h.hasPrefix("@"), h != au { s += " <span class=\"dim\">\(esc(h))</span>" }
            meta.append(s)
        }
        if let p = a.publishedAt { meta.append(dateString(p)) }
        let header = """
        <header>
        \(a.titleRepeatsInBody ? "" : "<h1>\(esc(a.title))</h1>")
        <div class="meta">\(meta.joined(separator: " · "))</div>
        <div class="meta">\(origin(a))收藏于 \(dateString(a.capturedAt))\(a.missingImages > 0 ? " · <span class=\"warn\">\(a.missingImages) 张图未下载</span>" : "")</div>
        </header>
        """
        return """
        <!doctype html>
        <html lang="zh-CN"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src shicang-reader: data:; style-src 'unsafe-inline'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(a.title))</title>
        <style>\(css)</style></head>
        <body><article>
        \(header)
        \(ai.map(aiCard) ?? "")\(highlightsCard(highlights))\(a.heroCover.map(figure) ?? "")\(body)</article></body></html>
        """
    }

    /// 「原文 ↗」：剪藏没有来源页时不显示；有来源页时显示「来自 域名 ↗」
    static func origin(_ a: Article) -> String {
        guard let u = URL(string: a.url), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return "" }
        if a.source == .clip { return "来自 <a href=\"\(attr(a.url))\">\(esc(u.host ?? a.url)) ↗</a> · " }
        return "<a href=\"\(attr(a.url))\">原文 ↗</a> · "
    }

    /// 我的摘录：收藏链接时一起带来的大段文字
    static func highlightsCard(_ hs: [Highlight]) -> String {
        let items = hs.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !items.isEmpty else { return "" }
        var h = "<section class=\"hl\"><div class=\"ailabel\">我的摘录</div>\n"
        for t in items {
            let paras = t.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            h += "<blockquote>" + paras.map { "<p>\(esc($0))</p>" }.joined() + "</blockquote>\n"
        }
        return h + "</section>\n"
    }

    /// AI 摘要卡：三句话摘要 + 要点
    static func aiCard(_ r: AIResult) -> String {
        let s = r.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let points = r.keyPoints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !s.isEmpty || !points.isEmpty else { return "" }
        var h = "<section class=\"ai\"><div class=\"ailabel\">AI 摘要</div>\n"
        if !s.isEmpty { h += "<p>\(esc(s))</p>\n" }
        if !points.isEmpty { h += "<ul>" + points.map { "<li>\(esc($0))</li>" }.joined() + "</ul>\n" }
        return h + "</section>\n"
    }

    static func figure(_ img: ImageRef) -> String {
        let alt = img.alt.map(attr) ?? ""
        guard let f = img.file else {
            return "<div class=\"missing\">图片未下载（稍后自动补抓）· <a href=\"\(attr(img.url))\">打开原图 ↗</a></div>\n"
        }
        return "<figure><img src=\"\(attr(f))\" alt=\"\(alt)\" loading=\"lazy\"></figure>\n"
    }

    static func inline(_ xs: [Inline]?) -> String {
        var out = ""
        for x in xs ?? [] {
            var s = esc(x.text).replacingOccurrences(of: "\n", with: "<br>")
            if x.code == true { s = "<code>\(s)</code>" }
            if x.bold == true { s = "<strong>\(s)</strong>" }
            if x.italic == true { s = "<em>\(s)</em>" }
            if x.strike == true { s = "<del>\(s)</del>" }
            if let l = x.link, let u = URL(string: l), ["http", "https", "mailto"].contains(u.scheme?.lowercased() ?? "") {
                s = "<a href=\"\(attr(l))\">\(s)</a>"
            }
            out += s
        }
        return out
    }

    /// 代码卡片：顶栏写语言和「复制」，等宽字体；每行一个块，长行折回时缩进两格（一眼看出是同一行），注释变淡。
    /// 阅读器关了 JS，「复制」是个 shicang-copy: 链接（代码原文百分号编码在里面），点了由 App 写剪贴板
    public static let copyScheme = "shicang-copy"
    static func codeCard(_ text: String, language: String?) -> String {
        let lang = language.flatMap { $0.isEmpty ? nil : $0 }
        let href = copyScheme + ":" + (text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        let hashComments = lang.map { ["bash", "sh", "shell", "zsh", "console", "python", "py", "yaml", "yml", "toml", "ruby", "rb", "conf", "ini", "dockerfile", "makefile", "r", "perl"].contains($0) } ?? true
        let slashComments = lang.map { ["js", "javascript", "ts", "typescript", "jsx", "tsx", "swift", "go", "c", "cpp", "c++", "java", "kotlin", "kt", "rust", "rs", "cs", "csharp", "php", "scala", "dart", "jsonc", "json5"].contains($0) } ?? true
        let markers = (hashComments ? ["#"] : []) + (slashComments ? ["//"] : [])
        var h = "<figure class=\"code\"><div class=\"codebar\"><span>\(esc(lang ?? "代码"))</span><a class=\"copy\" href=\"\(attr(href))\">复制</a></div><pre><code>"
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if markers.contains(where: { t == $0 || t.hasPrefix($0 + " ") }) {
                h += "<span class=\"ln cm\">\(esc(line))</span>"
            } else if !markers.isEmpty, let r = CodeDetect.commentRange(line, markers: markers) {
                h += "<span class=\"ln\">\(esc(String(line[..<r.lowerBound])))<span class=\"cm\">\(esc(String(line[r])))</span></span>"
            } else {
                h += "<span class=\"ln\">\(line.isEmpty ? " " : esc(line))</span>"
            }
        }
        return h + "</code></pre></figure>\n"
    }

    static func esc(_ s: String) -> String {
        var o = ""
        o.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            default: o.append(c)
            }
        }
        return o
    }

    static func attr(_ s: String) -> String { esc(s).replacingOccurrences(of: "\"", with: "&quot;") }

    static func sourceName(_ s: Source) -> String {
        switch s { case .x: return "X"; case .wechat: return "公众号"; case .xhs: return "小红书"; case .web: return "网页"; case .clip: return "剪藏" }
    }

    static func dateString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    static let css = """
    :root { --bg: #fbfaf7; --fg: #1d1d1f; --dim: #6e6e73; --line: #e5e3dc; --card: #f2f0ea; --link: #0a64c2; --warn: #b25000; }
    @media (prefers-color-scheme: dark) { :root { --bg: #1c1c1e; --fg: #e8e6e1; --dim: #98989d; --line: #3a3a3c; --card: #2a2a2c; --link: #5aa7ff; --warn: #ff9f43; } }
    html { background: var(--bg); }
    body { margin: 0; color: var(--fg); background: var(--bg); font: 17px/1.75 -apple-system, "PingFang SC", "Helvetica Neue", sans-serif; -webkit-font-smoothing: antialiased; }
    article { max-width: 720px; margin: 0 auto; padding: 32px 28px 80px; }
    header { margin-bottom: 28px; padding-bottom: 16px; border-bottom: 1px solid var(--line); }
    h1 { font-size: 28px; line-height: 1.35; margin: 0 0 12px; }
    h2 { font-size: 22px; margin: 1.6em 0 .6em; } h3 { font-size: 19px; margin: 1.4em 0 .5em; } h4, h5, h6 { font-size: 17px; margin: 1.2em 0 .4em; }
    .meta { color: var(--dim); font-size: 14px; line-height: 1.6; } .dim { color: var(--dim); } .warn { color: var(--warn); }
    p { margin: 0 0 1em; } a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
    blockquote { margin: 0 0 1em; padding: 2px 0 2px 16px; border-left: 3px solid var(--line); color: var(--dim); }
    blockquote p { margin: 0; }
    ul, ol { margin: 0 0 1em; padding-left: 1.6em; } li { margin: .2em 0; } li > ul, li > ol { margin: 0; }
    code { font: 14.5px/1.5 ui-monospace, "SF Mono", Menlo, monospace; background: var(--card); padding: 1px 5px; border-radius: 4px; }
    pre { background: var(--card); padding: 14px 16px; border-radius: 8px; overflow-x: auto; margin: 0 0 1em; }
    pre code { background: none; padding: 0; white-space: pre; }
    figure.code { margin: 0 0 1.1em; text-align: left; background: var(--card); border-radius: 8px; overflow: hidden; }
    .codebar { display: flex; justify-content: space-between; align-items: baseline; padding: 6px 14px 0 16px; font: 12px/1.6 -apple-system, sans-serif; color: var(--dim); letter-spacing: .02em; }
    .codebar .copy { font-size: 12px; } .codebar .copy:hover { text-decoration: none; opacity: .75; }
    figure.code pre { background: none; margin: 0; padding: 4px 16px 12px; border-radius: 0; overflow-x: visible; }
    figure.code code { font: 13.5px/1.6 ui-monospace, "SF Mono", Menlo, monospace; }
    .ln { display: block; white-space: pre-wrap; overflow-wrap: anywhere; padding-left: 2ch; text-indent: -2ch; }
    .cm { color: var(--dim); }
    figure { margin: 1.2em 0; text-align: center; } img { max-width: 100%; height: auto; border-radius: 6px; }
    .missing { margin: 1em 0; padding: 14px; border: 1px dashed var(--line); border-radius: 8px; color: var(--dim); font-size: 14px; text-align: center; }
    .video { display: block; position: relative; margin: 1.2em 0; border-radius: 8px; overflow: hidden; background: var(--card); }
    .video img { display: block; width: 100%; border-radius: 0; } .noposter { height: 180px; }
    .play { position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%); background: rgba(0,0,0,.65); color: #fff; padding: 8px 16px; border-radius: 20px; font-size: 15px; }
    .embed { display: block; margin: 1em 0; padding: 12px 14px; border: 1px solid var(--line); border-radius: 10px; color: var(--fg); }
    .eauthor { font-weight: 600; font-size: 14px; } .etitle { font-weight: 600; } .etext { color: var(--dim); font-size: 15px; }
    .table { overflow-x: auto; margin: 0 0 1em; } table { border-collapse: collapse; font-size: 15px; }
    th, td { border: 1px solid var(--line); padding: 6px 10px; text-align: left; vertical-align: top; } th { background: var(--card); }
    hr { border: 0; border-top: 1px solid var(--line); margin: 2em 0; }
    .ai { background: var(--card); border-radius: 10px; padding: 12px 18px 4px; margin: -8px 0 28px; font-size: 15.5px; line-height: 1.7; }
    .ai p { margin: 0 0 .6em; } .ai ul { margin: 0 0 .8em; } .ai li { margin: .15em 0; }
    .hl { border-left: 3px solid var(--link); padding: 2px 0 2px 16px; margin: -8px 0 28px; }
    .hl blockquote { border: 0; padding: 0; margin: 0 0 .8em; color: var(--fg); font-size: 15.5px; line-height: 1.7; }
    .hl blockquote p { margin: 0 0 .4em; }
    .ailabel { font-size: 12px; font-weight: 600; color: var(--dim); letter-spacing: .06em; margin-bottom: 4px; }
    """
}
