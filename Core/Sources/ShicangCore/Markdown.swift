import Foundation

public enum Markdown {
    // MARK: 行内工具

    static func longestRun(of ch: Character, in s: String) -> Int {
        var best = 0, cur = 0
        for c in s { if c == ch { cur += 1; best = max(best, cur) } else { cur = 0 } }
        return best
    }

    public static func mergeInlines(_ xs: [Inline]) -> [Inline] {
        var out: [Inline] = []
        for x in xs where !x.text.isEmpty {
            if var last = out.last, last.sameStyle(x) {
                last.text += x.text
                out[out.count - 1] = last
            } else { out.append(x) }
        }
        return out
    }

    /// 去掉首尾空白（含换行），段内换行两侧的空格也去掉
    public static func trimInlines(_ xs: [Inline]) -> [Inline] {
        var a = xs
        while let f = a.first {
            let t = String(f.text.drop { $0 == " " || $0 == "\n" })
            if t.isEmpty { a.removeFirst() } else { a[0].text = t; break }
        }
        while let l = a.last {
            var t = l.text
            while let c = t.last, c == " " || c == "\n" { t.removeLast() }
            if t.isEmpty { a.removeLast() } else { a[a.count - 1].text = t; break }
        }
        for i in a.indices {
            a[i].text = a[i].text.replacingOccurrences(of: " \n", with: "\n").replacingOccurrences(of: "\n ", with: "\n")
            while a[i].text.contains("\n\n\n") { a[i].text = a[i].text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        }
        return a
    }

    /// 按空行拆段（推文用）
    public static func splitParagraphs(_ xs: [Inline]) -> [[Inline]] {
        var paras: [[Inline]] = [[]]
        for x in xs {
            let pieces = x.text.components(separatedBy: "\n\n")
            for (i, p) in pieces.enumerated() {
                if i > 0 { paras.append([]) }
                var y = x; y.text = p
                if !p.isEmpty { paras[paras.count - 1].append(y) }
            }
        }
        return paras.map { trimInlines($0) }.filter { !$0.isEmpty }
    }

    public static func parseTable(_ md: String) -> [[String]]? {
        let lines = md.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count >= 2, lines.allSatisfy({ $0.hasPrefix("|") }) else { return nil }
        var rows: [[String]] = []
        for (i, l) in lines.enumerated() {
            var cells = l.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.first == "" { cells.removeFirst() }
            if cells.last == "" { cells.removeLast() }
            if i == 1 && cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }
            rows.append(cells)
        }
        return rows
    }

    // MARK: 渲染

    static func inlineMD(_ xs: [Inline]) -> String {
        xs.map { x -> String in
            var t = x.text
            if t.isEmpty { return "" }
            if x.code == true {
                t = "`\(t.replacingOccurrences(of: "`", with: "'"))`"
            } else {
                t = escape(t, linkify: x.link == nil)
            }
            // 样式标记不能包住首尾空白
            let lead = String(t.prefix { $0 == " " || $0 == "\n" })
            let trail = String(t.reversed().prefix { $0 == " " || $0 == "\n" }.reversed())
            var core = String(t.dropFirst(lead.count).dropLast(trail.count))
            if core.isEmpty { return t }
            if x.strike == true { core = "~~\(core)~~" }
            if x.italic == true { core = "*\(core)*" }
            if x.bold == true { core = "**\(core)**" }
            if let l = x.link {
                if x.text == l || x.text == l.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "") {
                    core = "<\(l)>"
                } else {
                    core = "[\(core)](\(l.replacingOccurrences(of: ")", with: "%29")))"
                }
            }
            return lead + core + trail
        }.joined().replacingOccurrences(of: "\n", with: "  \n")
    }

    static let urlRE = try! NSRegularExpression(pattern: #"https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+"#)

    /// 裸链接 → <url>，其余文字做最小转义（保持 .md 原文可读）
    static func escape(_ s: String, linkify: Bool = true) -> String {
        guard linkify else { return escapePlain(s) }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in urlRE.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            var r = m.range
            var url = ns.substring(with: r)
            while let c = url.last, ".,;:!?)]'".contains(c) { url.removeLast(); r.length -= 1 }
            out += escapePlain(ns.substring(with: NSRange(location: last, length: r.location - last)))
            out += "<\(url)>"
            last = r.location + r.length
        }
        out += escapePlain(ns.substring(from: last))
        return out
    }

    static func escapePlain(_ s: String) -> String {
        let chars = Array(s)
        let hasLinkish = s.contains("](")
        var out = ""
        for (i, c) in chars.enumerated() {
            let prev = i > 0 ? chars[i - 1] : " "
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            switch c {
            case "*", "`": out += "\\\(c)"
            case "_": out += (prev.isLetter || prev.isNumber) && (next.isLetter || next.isNumber) ? "_" : "\\_"
            case "[": out += hasLinkish ? "\\[" : "["
            case "<": out += (next.isLetter || "/!?".contains(next)) ? "\\<" : "<"
            case "\\": out += (next.isPunctuation || next.isSymbol) ? "\\\\" : "\\"
            default: out.append(c)
            }
        }
        return out
    }

    static let orderedMarkerRE = try! NSRegularExpression(pattern: #"^(\d{1,9})([.)])(?=\s|$)"#)

    /// 行首会被 Markdown 误读成标题/列表/引用/分隔线/代码围栏的字符，加反斜杠
    static func escapeLineStart(_ line: String) -> String {
        let lead = String(line.prefix { $0 == " " })
        let rest = String(line.dropFirst(lead.count))
        guard let f = rest.first else { return line }
        let next = rest.dropFirst().first
        let allSame = rest.trimmingCharacters(in: .whitespaces).allSatisfy { $0 == f || $0 == " " }
        switch f {
        case "#":
            let afterHashes = rest.drop { $0 == "#" }
            if afterHashes.isEmpty || afterHashes.first == " " { return lead + "\\" + rest }
        case ">":
            return lead + "\\" + rest
        case "-", "+":
            if next == nil || next == " " || (allSame && rest.count >= 3) { return lead + "\\" + rest }
        case "=":
            if allSame { return lead + "\\" + rest }
        case "~":
            if rest.hasPrefix("~~~") { return lead + "\\" + rest }
        case "0"..."9":
            let ns = rest as NSString
            if let m = orderedMarkerRE.firstMatch(in: rest, range: NSRange(location: 0, length: ns.length)) {
                let r = m.range(at: 2)
                return lead + ns.substring(to: r.location) + "\\" + ns.substring(from: r.location)
            }
        default: break
        }
        return line
    }

    /// 多行行内文字（`  \n` 分行）逐行转义行首
    static func safeLines(_ md: String) -> String {
        md.components(separatedBy: "  \n").map(escapeLineStart).joined(separator: "  \n")
    }

    public static func render(_ a: Article) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "Asia/Shanghai")
        var fm: [String] = ["---"]
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        fm.append("title: \(q(a.title))")
        fm.append("source: \(a.source.rawValue)")
        if let au = a.author { fm.append("author: \(q(au))") }
        if let h = a.authorHandle { fm.append("author_handle: \(q(h))") }
        fm.append("url: \(q(a.url))")
        if let p = a.publishedAt { fm.append("published: \(iso.string(from: p))") }
        fm.append("captured: \(iso.string(from: a.capturedAt))")
        fm.append("canonical_id: \(q(a.canonicalId))")
        fm.append("extractor: \(a.extractor)")
        fm.append("---")

        // 标题就是正文第一行（推文、部分网页）时不再重复写一级标题
        var out = fm.joined(separator: "\n") + "\n\n" + (a.titleRepeatsInBody ? "" : "# \(escapePlain(a.title))\n\n")
        if let c = a.heroCover { out += "![](\(c.file ?? c.url))\n\n" }
        var listCounter: [Int: Int] = [:]
        var prevWasList = false
        for b in a.blocks {
            let isList = b.type == .listItem
            if !isList { listCounter = [:] }
            if prevWasList && !isList { out += "\n" }
            switch b.type {
            case .heading:
                // 标题本身就是粗体，去掉多余的 ** 包裹
                let hx = (b.inlines ?? []).map { x -> Inline in var y = x; y.bold = false; return y }
                out += String(repeating: "#", count: b.level ?? 2) + " " + inlineMD(Markdown.mergeInlines(hx)).replacingOccurrences(of: "  \n", with: " ") + "\n\n"
            case .paragraph:
                out += safeLines(inlineMD(b.inlines ?? [])) + "\n\n"
            case .quote:
                out += inlineMD(b.inlines ?? []).components(separatedBy: "  \n").map { "> " + escapeLineStart($0) }.joined(separator: "\n") + "\n\n"
            case .listItem:
                let d = b.depth ?? 0
                for k in listCounter.keys where k > d { listCounter[k] = nil }
                let n = (listCounter[d] ?? 0) + 1
                listCounter[d] = n
                let marker = b.ordered == true ? "\(n). " : "- "
                out += String(repeating: "    ", count: d) + marker + safeLines(inlineMD(b.inlines ?? [])).replacingOccurrences(of: "  \n", with: "  \n" + String(repeating: "    ", count: d + 1)) + "\n"
            case .code:
                // 代码里本身有 ``` 时围栏要更长，否则会被提前截断
                let text = b.text ?? ""
                let fence = String(repeating: "`", count: max(3, Markdown.longestRun(of: "`", in: text) + 1))
                out += "\(fence)\(b.language ?? "")\n\(text)\n\(fence)\n\n"
            case .table:
                let rows = b.rows ?? []
                let cols = rows.map(\.count).max() ?? 0
                func row(_ r: [String]) -> String {
                    let cells = (0..<cols).map { i in i < r.count ? r[i].replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") : "" }
                    return "| " + cells.joined(separator: " | ") + " |"
                }
                if let first = rows.first {
                    out += row(b.header == true ? first : Array(repeating: "", count: cols)) + "\n"
                    out += "|" + String(repeating: " --- |", count: cols) + "\n"
                    for r in (b.header == true ? Array(rows.dropFirst()) : rows) { out += row(r) + "\n" }
                    out += "\n"
                }
            case .image:
                let img = b.image!
                out += "![\(img.alt ?? "")](\(img.file ?? img.url))\n\n"
            case .video:
                let v = b.video!
                let page = v.pageURL.isEmpty ? a.url : v.pageURL
                if let c = v.cover { out += "[![▶ 视频](\(c.file ?? c.url))](\(page))\n\n" }
                out += "▶ [视频：点开原文播放](\(page))\n\n"
            case .embed:
                let e = b.embed!
                var lines: [String] = []
                if let au = e.author { lines.append("**\(escape(au))**") }
                if let t = e.title { lines.append(escape(t)) }
                if let t = e.text { lines += escape(t).components(separatedBy: "\n") }
                lines.append("[\(e.url)](\(e.url))")
                out += lines.map { "> " + $0 }.joined(separator: "\n") + "\n\n"
            case .divider:
                out += "---\n\n"
            }
            prevWasList = isList
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
