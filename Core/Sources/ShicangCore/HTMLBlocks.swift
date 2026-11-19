import Foundation
import SwiftSoup

/// HTML（公众号 #js_content / Readability 输出）→ 结构化正文块
public final class HTMLBlockBuilder {
    public typealias ImageURL = (Element) -> String?

    private(set) var blocks: [Block] = []
    private var inlines: [Inline] = []
    // 粗/斜体按 CSS 层叠：最近一个设置过的祖先说了算（<strong> 里套 style="font-weight:400" 就不粗）
    private var weight: [Bool] = [], slant: [Bool] = []
    private var code = 0, strike = 0
    private var link: [String] = []
    private var quoteDepth = 0
    private var listStack: [Bool] = []          // ordered?
    private var inListItem = false
    private var liLevel = 0                     // 当前 li 所在的列表层级
    private let imageURL: ImageURL
    private let baseURL: URL?
    public var skipSelectors: [String] = []

    public init(baseURL: URL?, imageURL: @escaping ImageURL) {
        self.baseURL = baseURL
        self.imageURL = imageURL
    }

    public func build(_ root: Element) throws -> [Block] {
        blocks = []; inlines = []
        for sel in skipSelectors { try root.select(sel).remove() }
        for child in root.getChildNodes() { try walk(child) }
        flush()
        return Self.mergeQuotes(blocks)
    }

    // MARK: 遍历

    private static let blockTags: Set<String> = ["p", "section", "div", "figure", "figcaption", "article", "header", "footer",
                                                 "center", "main", "aside", "nav", "dl", "dt", "dd", "address", "details", "summary"]
    private static let skipTags: Set<String> = ["script", "style", "noscript", "head", "button", "mp-style-type", "template", "svg", "input", "select", "textarea"]

    private func walk(_ node: Node) throws {
        if let t = node as? TextNode {
            appendText(Self.collapse(t.getWholeText()))
            return
        }
        guard let el = node as? Element else { return }
        let tag = el.tagName().lowercased()
        if Self.skipTags.contains(tag) { return }
        if Self.isHidden(el) { return }

        let style = Self.styleMap(el)
        var pw = 0, ps = 0
        if tag == "strong" || tag == "b" { weight.append(true); pw += 1 }
        if tag == "em" || tag == "i" { slant.append(true); ps += 1 }
        if let w = style["font-weight"].flatMap(Self.isBold) { weight.append(w); pw += 1 }
        if let f = style["font-style"] { slant.append(f.hasPrefix("italic") || f.hasPrefix("oblique")); ps += 1 }
        defer { weight.removeLast(pw); slant.removeLast(ps) }

        switch tag {
        case "br":
            appendText("\n")
        case "img":
            if let u = imageURL(el), let abs = resolve(u), !abs.hasPrefix("data:") {
                flush()
                let dw = try el.attr("data-w"), ww = try el.attr("width"), hh = try el.attr("height")
                let w = Int(dw) ?? Int(ww)
                let ratio = Double(try el.attr("data-ratio"))
                let h = (w != nil && ratio != nil) ? Int(Double(w!) * ratio!) : Int(hh)
                let alt = try el.attr("alt")
                blocks.append(.image(ImageRef(url: abs, width: w, height: h, alt: alt.isEmpty ? nil : alt)))
            }
        case "strong", "b", "em", "i":
            try children(el)
        case "s", "del", "strike":
            strike += 1; try children(el); strike -= 1
        case "code", "kbd", "tt":
            code += 1; try children(el); code -= 1
        case "a":
            let href = try el.attr("href")
            // 页内锚点（脚注 #f1n、目录跳转）离开原页面就没意义：只留文字
            if let abs = resolve(href), abs.hasPrefix("http"), !isSamePageAnchor(href, abs) { link.append(abs); try children(el); link.removeLast() }
            else { try children(el) }
        case "h1", "h2", "h3", "h4", "h5", "h6":
            flush()
            try children(el)
            let inl = takeInlines()
            if !inl.isEmpty { blocks.append(.heading(Int(String(tag.last!))!, inl)) }
        case "blockquote":
            // 排版工具把代码块转成了引用框（公众号常见）→ 认出来改回代码块，夹在中间的说明拆成段落
            if quoteDepth == 0, let segs = try codeInQuote(el) {
                flush()
                for seg in segs {
                    switch seg {
                    case .code(let text, let lang): blocks.append(.code(text, language: lang))
                    case .prose(let lines): blocks.append(.paragraph([Inline(lines.joined(separator: "\n"))]))
                    }
                }
                return
            }
            flush(); quoteDepth += 1; try children(el); flush(); quoteDepth -= 1
        case "ul", "ol":
            flush(); listStack.append(tag == "ol"); try children(el); flush(); listStack.removeLast()
        case "li":
            flush()
            let was = (inListItem, liLevel)
            inListItem = true; liLevel = listStack.count
            try children(el); flush()
            (inListItem, liLevel) = was
        case "pre":
            flush()
            let txt = try preText(el)
            if !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(.code(txt, language: try Self.preLanguage(el))) }
        case "table":
            flush()
            _ = try table(el)
        case "hr":
            flush(); blocks.append(.divider)
        case "iframe", "video", "mpvoice", "mp-common-videosnap", "mpvideosnap":
            flush()
            let src = (try? el.attr("data-src")).flatMap { $0.isEmpty ? nil : $0 } ?? (try? el.attr("src")) ?? ""
            blocks.append(.video(VideoRef(pageURL: resolve(src) ?? "", streamURL: nil, cover: nil, durationSec: nil)))
        default:
            if Self.blockTags.contains(tag) {
                // li 里的块级子元素（公众号常见 <li><strong>…</strong><section>…</section></li>）只换行，不拆成新条目
                if inListItem && listStack.count == liLevel && quoteDepth == 0 {
                    softBreak(); try children(el); softBreak()
                } else {
                    flush(); try children(el); flush()
                }
            } else {
                try children(el)   // span 等行内元素
            }
        }
    }

    private func children(_ el: Element) throws { for c in el.getChildNodes() { try walk(c) } }

    private static func styleMap(_ el: Element) -> [String: String] {
        guard let raw = try? el.attr("style"), !raw.isEmpty else { return [:] }
        var m: [String: String] = [:]
        for decl in raw.split(separator: ";") {
            let kv = decl.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            m[kv[0].trimmingCharacters(in: .whitespaces).lowercased()] = kv[1].replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces).lowercased()
        }
        return m
    }

    private static func isBold(_ v: String) -> Bool? {
        switch v {
        case "bold", "bolder": return true
        case "normal", "lighter": return false
        default: return Int(v).map { $0 >= 600 }
        }
    }

    private static func isHidden(_ el: Element) -> Bool {
        let style = ((try? el.attr("style")) ?? "").replacingOccurrences(of: " ", with: "").lowercased()
        return style.contains("display:none")
    }

    private func isSamePageAnchor(_ href: String, _ abs: String) -> Bool {
        let h = href.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { return true }
        guard let base = baseURL, let u = URL(string: abs), u.fragment != nil else { return false }
        func strip(_ x: URL) -> String {
            var c = URLComponents(url: x, resolvingAgainstBaseURL: false); c?.fragment = nil
            return (c?.string ?? x.absoluteString).replacingOccurrences(of: "http://", with: "https://")
        }
        return strip(u) == strip(base)
    }

    private func resolve(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        if t.hasPrefix("//") { return "https:" + t }
        if let base = baseURL, let u = URL(string: t, relativeTo: base) { return u.absoluteString }
        return t
    }

    // MARK: 行内缓冲

    private static func collapse(_ s: String) -> String {
        var out = ""
        var lastSpace = false
        for ch in s {
            if ch.isWhitespace && ch != "\u{00a0}" || ch == "\u{200b}" || ch == "\u{feff}" {
                if !lastSpace && ch != "\u{200b}" && ch != "\u{feff}" { out.append(" "); lastSpace = true }
            } else {
                out.append(ch == "\u{00a0}" ? " " : ch); lastSpace = false
            }
        }
        return out
    }

    private func appendText(_ s: String) {
        if s.isEmpty { return }
        inlines.append(Inline(s, bold: weight.last ?? false, italic: slant.last ?? false, code: code > 0, strike: strike > 0, link: link.last))
    }

    private func softBreak() {
        guard let last = inlines.last, !last.text.hasSuffix("\n") else { return }
        appendText("\n")
    }

    private func takeInlines() -> [Inline] {
        let inl = Markdown.trimInlines(Markdown.mergeInlines(inlines))
        inlines = []
        return inl
    }

    private func flush() {
        let inl = takeInlines()
        if inl.isEmpty { return }
        if inListItem, let ordered = listStack.last {
            blocks.append(.listItem(ordered: ordered, depth: max(0, listStack.count - 1), inl))
        } else {
            // 空行分段（<br><br>、推文里的空行）：拆成独立段落，别在一段里堆硬换行
            for part in Self.splitOnBlankLines(inl) {
                blocks.append(quoteDepth > 0 ? .quote(part) : .paragraph(part))
            }
        }
    }

    /// 按「连续两个及以上换行（中间只夹空白）」拆段；换行可以跨 inline（<br> 和文字样式不同时）
    static func splitOnBlankLines(_ xs: [Inline]) -> [[Inline]] {
        var out: [[Inline]] = [], cur: [Inline] = []
        var newlines = 0
        for x in xs {
            var buf = ""
            func emit() { if !buf.isEmpty { var y = x; y.text = buf; cur.append(y); buf = "" } }
            for ch in x.text {
                if ch == "\n" { newlines += 1; continue }
                if newlines > 0 && (ch == " " || ch == "\t" || ch == "\u{00a0}") { continue }
                if newlines >= 2 { emit(); out.append(cur); cur = [] }
                else if newlines == 1 { buf += "\n" }
                newlines = 0
                buf.append(ch)
            }
            emit()
        }
        out.append(cur)
        return out.map { Markdown.trimInlines(Markdown.mergeInlines($0)) }.filter { !$0.isEmpty }
    }

    // MARK: pre / table

    private func preText(_ el: Element) throws -> String {
        // 公众号代码块：<pre><code>一行</code><code>一行</code></pre>，行号在 ul.code-snippet__line-index
        try el.select("ul.code-snippet__line-index").remove()
        let codes = el.children().filter { $0.tagName().lowercased() == "code" }
        if codes.count > 1 {
            return try codes.map { try rawText($0) }.joined(separator: "\n")
        }
        return try rawText(el)
    }

    /// 引用框里只有文字（没有图片、列表、表格、标题、嵌套引用、pre）时，按原始换行和缩进判断是不是代码
    private func codeInQuote(_ el: Element) throws -> [CodeDetect.Segment]? {
        let structural = "img, video, iframe, table, pre, ul, ol, h1, h2, h3, h4, h5, h6, hr, mpvoice, mp-common-videosnap, mpvideosnap"
        if try !el.select(structural).isEmpty() || el.select("blockquote").count > 1 { return nil }
        return CodeDetect.segments(try quoteText(el))
    }

    /// 引用框的文字，按浏览器显示的样子取：源码里的换行/连续空格算一个空格、行首普通空格不显示，
    /// 只有 <br>/块级元素换行，&nbsp; 原样保留（公众号用「&nbsp; &nbsp; 」排缩进）
    private func quoteText(_ el: Element) throws -> String {
        var s = ""
        func rec(_ n: Node) throws {
            if let t = n as? TextNode {
                var lastSpace = s.last == " " || s.last == "\n" || s.isEmpty
                for ch in t.getWholeText() {
                    if ch == "\u{200b}" || ch == "\u{feff}" { continue }
                    if ch.isWhitespace && ch != "\u{00a0}" {
                        if !lastSpace { s.append(" "); lastSpace = true }
                    } else { s.append(ch); lastSpace = false }
                }
                return
            }
            guard let e = n as? Element else { return }
            let tag = e.tagName().lowercased()
            if Self.skipTags.contains(tag) || Self.isHidden(e) { return }
            if tag == "br" { s += "\n"; return }
            let isBlock = Self.blockTags.contains(tag) || tag == "li"
            if isBlock && !s.isEmpty && !s.hasSuffix("\n") { s += "\n" }
            for c in e.getChildNodes() { try rec(c) }
            if isBlock && !s.hasSuffix("\n") { s += "\n" }
        }
        try rec(el)
        return s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")).replacingOccurrences(of: "\u{00a0}", with: " ") }
            .joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// 代码块的语言：<pre data-lang="bash">（公众号）、class="language-xx" / "lang-xx"（常见高亮库），也看里面的 <code>
    static func preLanguage(_ el: Element) throws -> String? {
        for e in [el] + el.children().filter({ $0.tagName().lowercased() == "code" }) {
            let dl = try e.attr("data-lang").trimmingCharacters(in: .whitespaces).lowercased()
            if !dl.isEmpty, dl.count <= 20 { return dl }
            for c in try e.classNames() {
                for p in ["language-", "lang-"] where c.lowercased().hasPrefix(p) && c.count > p.count && c.count <= p.count + 20 {
                    return String(c.dropFirst(p.count)).lowercased()
                }
            }
        }
        return nil
    }

    private func rawText(_ el: Element) throws -> String {
        var s = ""
        func rec(_ n: Node) throws {
            if let t = n as? TextNode { s += t.getWholeText(); return }
            guard let e = n as? Element else { return }
            let tag = e.tagName().lowercased()
            if Self.skipTags.contains(tag) || Self.isHidden(e) { return }
            if tag == "br" { s += "\n"; return }
            let isBlock = Self.blockTags.contains(tag) || tag == "li"
            if isBlock && !s.isEmpty && !s.hasSuffix("\n") { s += "\n" }
            for c in e.getChildNodes() { try rec(c) }
            if isBlock && !s.hasSuffix("\n") { s += "\n" }
        }
        try rec(el)
        return s.replacingOccurrences(of: "\u{00a0}", with: " ").trimmingCharacters(in: .newlines)
    }

    private func table(_ el: Element) throws -> Block? {
        let rows = Self.directRows(el)
        let cellsByRow = rows.map { $0.children().filter { ["td", "th"].contains($0.tagName().lowercased()) } }
        // 排版表（老网站整页用 table 布局，如 paulgraham.com）：按普通块遍历单元格，否则整篇文章会被塞进一个格子
        if try Self.isLayoutTable(el, cellsByRow) {
            for cells in cellsByRow { for c in cells { flush(); try children(c); flush() } }
            return nil
        }
        var out: [[String]] = []
        var header = false
        for (i, cells) in cellsByRow.enumerated() {
            if i == 0 { header = cells.contains { $0.tagName().lowercased() == "th" } || rows[i].parent()?.tagName().lowercased() == "thead" }
            let texts = try cells.map { Self.collapse(try $0.text()).trimmingCharacters(in: .whitespaces) }
            if !texts.allSatisfy({ $0.isEmpty }) { out.append(texts) }
        }
        // 单元格内图片单独成块（排在表格后面），避免丢图
        let imgs = try el.select("img").array().compactMap { img -> Block? in
            guard let u = imageURL(img), let abs = resolve(u) else { return nil }
            return .image(ImageRef(url: abs))
        }
        if out.isEmpty { blocks += imgs; return nil }
        blocks.append(.table(out, header: header))
        blocks += imgs
        return nil
    }

    /// 只取本表自己的行（不含嵌套表里的行，否则嵌套内容会算两遍）
    static func directRows(_ table: Element) -> [Element] {
        var rows: [Element] = []
        for c in table.children() {
            let t = c.tagName().lowercased()
            if t == "tr" { rows.append(c) }
            else if ["tbody", "thead", "tfoot"].contains(t) { rows += c.children().filter { $0.tagName().lowercased() == "tr" } }
        }
        return rows
    }

    static func isLayoutTable(_ el: Element, _ cellsByRow: [[Element]]) throws -> Bool {
        if try el.select("table").count > 1 { return true }                  // 套着别的表
        let cols = cellsByRow.map(\.count).max() ?? 0
        guard cols <= 3 else { return false }
        for cells in cellsByRow {
            for c in cells {
                if try c.select("p, br + br, h1, h2, h3, ul, ol, blockquote").count > 0 { return true }   // 格子里有段落结构
                if try c.text().count > 300 { return true }
            }
        }
        return false
    }

    /// 相邻的引用块合并成一个多行引用
    static func mergeQuotes(_ bs: [Block]) -> [Block] {
        var out: [Block] = []
        for b in bs {
            if b.type == .quote, let last = out.last, last.type == .quote {
                var merged = last
                merged.inlines = (last.inlines ?? []) + [Inline("\n")] + (b.inlines ?? [])
                out[out.count - 1] = merged
            } else { out.append(b) }
        }
        return out
    }
}
