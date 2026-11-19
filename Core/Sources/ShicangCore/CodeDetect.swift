import Foundation

/// 认出「被排成引用框 / 普通文字的代码」。
/// 不少公众号排版工具把 Markdown 代码块转成引用框，还顺手把直引号换成弯引号、把 `--` 换成破折号、缩进换成 &nbsp;，
/// 原样存下来就是灰色比例字体、缩进全丢、长命令折行后像好几行。这里逐行判断，**有把握是代码才改**：
/// 至少一行明确像代码（命令、JSON、路径、赋值…），像代码的连续几行合成代码块，夹在中间的中文说明拆成普通段落。
public enum CodeDetect {
    public enum Segment: Equatable, Sendable {
        case code(String, language: String?)
        case prose([String])
    }

    enum Kind: Equatable { case strong, weak, prose, neutral }

    /// 一段多行文字 → 代码 / 文字分段。完全不像代码返回 nil（保持原样）
    public static func segments(_ text: String) -> [Segment]? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\u{00a0}", with: " ") }
        let kinds = lines.map(classify)
        guard kinds.contains(.strong) else { return nil }

        // 连续的非文字行是一组候选；组里有一行明确像代码才算代码，否则并回文字
        var out: [Segment] = []
        var prose: [String] = []
        func flushProse() {
            let ls = prose.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !ls.isEmpty {
                if case .prose(let prev)? = out.last { out[out.count - 1] = .prose(prev + ls) } else { out.append(.prose(ls)) }
            }
            prose = []
        }
        var i = 0
        while i < lines.count {
            if kinds[i] == .prose { prose.append(lines[i]); i += 1; continue }
            var j = i
            while j < lines.count, kinds[j] != .prose { j += 1 }
            let run = Array(lines[i..<j]), rk = Array(kinds[i..<j])
            if rk.contains(.strong), let code = codeText(run) {
                flushProse()
                out.append(.code(code, language: guessLanguage(code)))
            } else {
                prose += run
            }
            i = j
        }
        flushProse()
        if out.count == 1, case .prose = out[0] { return nil }
        return out.contains(where: { if case .code = $0 { return true } else { return false } }) ? out : nil
    }

    /// 一组代码行 → 代码块文字：去掉首尾空行和公共缩进，修回被美化的标点
    static func codeText(_ run: [String]) -> String? {
        var ls = run.map { String($0.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed()) }
        while let f = ls.first, f.isEmpty { ls.removeFirst() }
        while let l = ls.last, l.isEmpty { ls.removeLast() }
        guard !ls.isEmpty else { return nil }
        let indent = ls.filter { !$0.isEmpty }.map { $0.prefix(while: { $0 == " " }).count }.min() ?? 0
        if indent > 0 { ls = ls.map { $0.isEmpty ? $0 : String($0.dropFirst(indent)) } }
        return ls.map(fixPunctuation).joined(separator: "\n")
    }

    // MARK: 逐行判断

    static func classify(_ line: String) -> Kind {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .neutral }
        let n = fixPunctuation(t)
        if isCommentLine(n) { return .neutral }
        let c = stripTrailingComment(n)
        let hasTrailingComment = c.count < n.count
        let cjk = cjkCount(removingQuoted(c))
        let nonSpace = c.filter { !$0.isWhitespace }.count
        if cjk >= 3 && Double(cjk) / Double(max(nonSpace, 1)) >= 0.15 { return .prose }
        if isEnglishSentence(c) { return .prose }
        if isStrong(c, trailingComment: hasTrailingComment) { return .strong }
        if cjk <= 2 && isWeak(c, indented: line.hasPrefix("  ") || line.hasPrefix("\t")) { return .weak }
        return .prose
    }

    static let commands: Set<String> = [
        "sudo", "brew", "curl", "wget", "ssh", "ssh-copy-id", "ssh-keygen", "ssh-add", "scp", "sftp", "rsync", "git", "gh",
        "npm", "npx", "pnpm", "yarn", "bun", "deno", "node", "pip", "pip3", "pipx", "python", "python3", "uv", "uvx", "conda",
        "docker", "docker-compose", "podman", "kubectl", "helm", "terraform", "systemctl", "journalctl", "service",
        "apt", "apt-get", "yum", "dnf", "pacman", "apk", "snap", "cd", "ls", "cat", "echo", "printf", "export", "source",
        "chmod", "chown", "mkdir", "rm", "rmdir", "cp", "mv", "ln", "touch", "sed", "awk", "grep", "rg", "find", "xargs",
        "tar", "unzip", "zip", "gzip", "make", "cmake", "go", "cargo", "rustup", "swift", "xcodebuild", "xcrun", "launchctl",
        "defaults", "open", "pbcopy", "pbpaste", "killall", "kill", "pkill", "ps", "top", "htop", "df", "du", "free", "uname",
        "whoami", "ping", "dig", "nslookup", "nc", "netstat", "ss", "lsof", "ufw", "iptables", "crontab", "nano", "vim", "vi",
        "code", "tailscale", "openssl", "gpg", "base64", "jq", "yq", "env", "set", "unset", "alias", "which", "history",
        "mas", "softwareupdate", "diskutil", "hdiutil", "codesign", "spctl", "xattr", "plutil", "nginx", "certbot", "pm2",
        "wrangler", "vercel", "firebase", "aws", "gcloud", "az", "claude", "codex", "ollama", "mysql", "psql", "redis-cli",
        "sqlite3", "mongo", "ffmpeg", "yt-dlp", "java", "javac", "mvn", "gradle", "ruby", "gem", "bundle", "php", "composer",
        "powershell", "pwsh", "choco", "winget", "scoop", "reg", "setx", "ipconfig",
    ]
    static let systemDirs = ["/etc/", "/usr/", "/var/", "/opt/", "/home/", "/lib/", "/tmp/", "/bin/", "/sbin/", "/root/", "/dev/", "/proc/", "/Users/", "/Library/", "/Applications/", "/System/"]

    static func isStrong(_ c: String, trailingComment: Bool) -> Bool {
        let tokens = c.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = tokens.first else { return false }
        if c.range(of: #"^[\[\]{}(),;]+$"#, options: .regularExpression) != nil { return true }               // { } ], });
        if c.range(of: #"^"[^"]+"\s*:"#, options: .regularExpression) != nil { return true }                 // "key": …
        if c.hasPrefix("$ ") && c.count > 2 { return true }                                                  // $ 提示符
        if c.hasSuffix("{") && c.contains(where: \.isLetter) { return true }
        if c.hasSuffix(";") && (c.contains("(") || c.contains("=")) { return true }
        if c.range(of: #"^<[A-Za-z/!?][^>]*>"#, options: .regularExpression) != nil && c.hasSuffix(">") { return true }   // 标签
        if c.range(of: #"^(export\s+)?[A-Z_][A-Z0-9_]*=\S"#, options: .regularExpression) != nil { return true }  // ENV=1
        if c.range(of: #"^[A-Za-z_][\w.]*\(.*\);?$"#, options: .regularExpression) != nil { return true }    // f(x)
        if c.range(of: #"^(import|from|def|class|function|const|let|var|func|package|fn|use|return)\s+\S+.*[(={:;'"]"#, options: .regularExpression) != nil { return true }
        if c.range(of: #"^from\s+[\w.]+\s+import\s"#, options: .regularExpression) != nil { return true }
        if c.range(of: #"^#include\s*[<"]"#, options: .regularExpression) != nil { return true }
        let cmd = first == "sudo" && tokens.count > 1 ? tokens[1] : first
        let isWord = cmd.range(of: #"^[a-z][a-z0-9._+-]*$"#, options: .regularExpression) != nil
        if commands.contains(cmd) && tokens.count >= 2 { return true }
        if cmd.hasPrefix("./") || cmd.hasPrefix("~/") || cmd.hasPrefix("../") { return true }
        if isWord {
            if tokens.dropFirst().contains(where: { $0.range(of: #"^--?[A-Za-z][\w-]*(=.*)?$"#, options: .regularExpression) != nil }) { return true }   // 带参数
            if trailingComment { return true }                                                               // cmd  # 说明
        }
        for op in [" | ", " && ", " || ", "2>&1", " > /", " >> ", "$(", " 2>/dev/null"] where c.contains(op) { return true }
        if tokens.contains(where: { t in t.hasPrefix("~/") || t.hasPrefix("./") || systemDirs.contains(where: { t.hasPrefix($0) }) }) { return true }
        return false
    }

    /// 单看不像代码、挨着代码就算：ssh 配置的「Port 52222」、YAML 的「key: value」、缩进行、短命令
    static func isWeak(_ c: String, indented: Bool) -> Bool {
        let tokens = c.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let last = c.last, !tokens.isEmpty else { return false }
        if "。！？.!?".contains(last) && !c.hasSuffix("...") { return false }
        if indented && tokens.count <= 8 { return true }
        guard tokens.count <= 4 else { return false }
        return tokens[0].range(of: #"^[A-Za-z_@-][\w.@/-]*:?$"#, options: .regularExpression) != nil
    }

    static func isEnglishSentence(_ c: String) -> Bool {
        let tokens = c.split(separator: " ")
        guard tokens.count >= 5 else { return false }
        if c.contains(where: { "{}[]<>=|$`;\\~".contains($0) }) { return false }
        let words = tokens.filter { $0.range(of: #"^[("“]?[A-Za-z][A-Za-z'’-]*[,.;:!?)"”]*$"#, options: .regularExpression) != nil }
        guard Double(words.count) / Double(tokens.count) >= 0.85 else { return false }
        return c.first?.isUppercase == true || ".!?:".contains(c.last!)
    }

    static func isCommentLine(_ n: String) -> Bool {
        n == "#" || n == "//" || n.hasPrefix("# ") || n.hasPrefix("// ")
    }

    /// 行尾注释（`cmd  # 说明`、`code  // note`）去掉；引号里的 # 不算
    static func stripTrailingComment(_ s: String) -> String {
        guard let r = commentRange(s) else { return s }
        return String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    /// 行尾注释从哪里开始：前面是空白、不在引号里的 `#` 或 `//`（后面跟空格或行尾）
    static func commentRange(_ s: String, markers: [String] = ["#", "//"]) -> Range<String.Index>? {
        var quote: Character? = nil
        var prev: Character = " "
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if let q = quote { if ch == q && prev != "\\" { quote = nil } }
            else if ch == "\"" || ch == "'" { quote = ch }
            else if prev.isWhitespace, i != s.startIndex {
                for m in markers where s[i...].hasPrefix(m) {
                    let after = s.index(i, offsetBy: m.count)
                    if after == s.endIndex || s[after] == " " { return i..<s.endIndex }
                }
            }
            prev = ch
            i = s.index(after: i)
        }
        return nil
    }

    static func removingQuoted(_ s: String) -> String {
        s.replacingOccurrences(of: #""[^"]*"|'[^']*'"#, with: "\"\"", options: .regularExpression)
    }

    static func cjkCount(_ s: String) -> Int {
        s.unicodeScalars.filter { u in
            let v = u.value
            return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x3000...0x303F).contains(v)
                || (0xFF00...0xFFEF).contains(v) || (0x3040...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v)
        }.count
    }

    /// 排版工具「美化」过的标点改回来：弯引号 → 直引号，空格后的破折号 → --，省略号 → ...
    public static func fixPunctuation(_ s: String) -> String {
        guard s.contains(where: { "“”‘’—–…".contains($0) }) else { return s }
        var t = s.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'").replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "…", with: "...")
        t = t.replacingOccurrences(of: #"(^|\s)[—–](?=[A-Za-z])"#, with: "$1--", options: .regularExpression)
        return t
    }

    static func guessLanguage(_ code: String) -> String? {
        let ls = code.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = ls.first else { return nil }
        if (first.hasPrefix("{") || first.hasPrefix("[")),
           let d = code.data(using: .utf8), (try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])) != nil { return "json" }
        if first.hasPrefix("{") || first.hasPrefix("[") {
            if ls.filter({ $0.range(of: #"^"[^"]+"\s*:"#, options: .regularExpression) != nil }).count * 3 >= ls.count { return "json" }
        }
        let body = ls.filter { !isCommentLine($0) }
        guard !body.isEmpty else { return nil }
        let shell = body.filter { l in
            let c = stripTrailingComment(l)
            let toks = c.split(separator: " ").map(String.init)
            guard let f = toks.first else { return false }
            let cmd = f == "sudo" && toks.count > 1 ? toks[1] : f
            return commands.contains(cmd) || c.hasPrefix("$ ") || cmd.hasPrefix("./") || [" | ", " && ", "2>&1"].contains(where: c.contains)
        }
        return shell.count * 2 > body.count ? "bash" : nil
    }
}
