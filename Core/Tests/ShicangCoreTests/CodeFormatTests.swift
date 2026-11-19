import Foundation
import Testing
import SwiftSoup
@testable import ShicangCore

/// 公众号排版工具把代码块排成引用框（灰字、比例字体、&nbsp; 缩进、弯引号、—cask）→ 认回代码块
@Suite struct CodeFormatTests {
    /// 仿公众号的引用框：每行一个 <span leaf>，行间 <span leaf><br/></span>；多段就多个 <p>
    static func quote(_ paras: [[String]]) -> String {
        let ps = paras.map { lines in
            "<p style=\"margin: 0.5em 0px\">" + lines.map { "<span leaf=\"\">\($0)</span>" }.joined(separator: "<span leaf=\"\"><br  /></span>") + "</p>"
        }
        return "<blockquote style=\"border-left: 3px solid rgb(245, 160, 96);color: rgb(102, 102, 102);\">\(ps.joined())</blockquote>"
    }
    static func blocks(_ html: String) throws -> [Block] {
        let doc = try SwiftSoup.parseBodyFragment(html)
        return try HTMLBlockBuilder(baseURL: nil) { _ in nil }.build(doc.body()!)
    }
    static func summary(_ bs: [Block]) -> [String] {
        bs.map { b in
            switch b.type {
            case .code: return "code[\(b.language ?? "-")] " + (b.text ?? "")
            default: return "\(b.type.rawValue) " + b.plainText
            }
        }
    }

    @Test func commandsInQuoteBecomeCode() throws {
        let html = Self.quote([["brew install —cask tailscale", "或 App Store 搜索 Tailscale 安装"]])
            + Self.quote([["curl -fsSL https://tailscale.com/install.sh | sh", "sudo tailscale up", "复制输出的 URL，浏览器用同一个 Google 账号登录"]])
        #expect(Self.summary(try Self.blocks(html)) == [
            "code[bash] brew install --cask tailscale",
            "paragraph 或 App Store 搜索 Tailscale 安装",
            "code[bash] curl -fsSL https://tailscale.com/install.sh | sh\nsudo tailscale up",
            "paragraph 复制输出的 URL，浏览器用同一个 Google 账号登录",
        ])
    }

    @Test func jsonKeepsIndentAndStraightQuotes() throws {
        let lines = ["{", "&nbsp; “tagOwners”: {", "&nbsp; &nbsp; “tag:server”: [“autogroup:owner”]", "&nbsp; },",
                     "&nbsp; “acls”: [", "&nbsp; &nbsp; {", "&nbsp; &nbsp; &nbsp; “ip”: [“*”]", "&nbsp; &nbsp; }", "&nbsp; ]", "}"]
        let bs = try Self.blocks(Self.quote([lines]))
        #expect(bs.count == 1)
        let b = try #require(bs.first)
        #expect(b.type == .code && b.language == "json")
        let text = b.text ?? ""
        #expect(text.contains("\n  \"tagOwners\": {\n    \"tag:server\": [\"autogroup:owner\"]\n  },"))
        #expect(text.contains("\n      \"ip\": [\"*\"]\n"))
        #expect(!text.contains("“") && !text.contains("\u{00a0}"))
        #expect((try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil)
    }

    /// 中文说明、命令、说明、命令交替（两个 <p>）→ 拆成段落和代码块
    @Test func proseBetweenCommandsIsSplitOut() throws {
        let html = Self.quote([
            ["Ubuntu 22.04+（有 socket 激活机制）",
             "sudo sed -i ‘s/^Port 22/Port 52222/‘ /etc/ssh/sshd_config",
             "sudo systemctl daemon-reload &amp;&amp; sudo systemctl restart ssh.socket sshd"],
            ["立刻用新端口验证，确认能进再断开旧连接", "ssh -p 52222 ubuntu@100.x.x.x “echo ok”"],
        ])
        #expect(Self.summary(try Self.blocks(html)) == [
            "paragraph Ubuntu 22.04+（有 socket 激活机制）",
            "code[bash] sudo sed -i 's/^Port 22/Port 52222/' /etc/ssh/sshd_config\nsudo systemctl daemon-reload && sudo systemctl restart ssh.socket sshd",
            "paragraph 立刻用新端口验证，确认能进再断开旧连接",
            "code[bash] ssh -p 52222 ubuntu@100.x.x.x \"echo ok\"",
        ])
    }

    @Test func sshConfigKeepsIndent() throws {
        let html = Self.quote([["Host vm-名字", "&nbsp; &nbsp; HostName 100.x.x.x", "&nbsp; &nbsp; User ubuntu",
                                "&nbsp; &nbsp; Port 52222", "&nbsp; &nbsp; IdentityFile ~/.ssh/id_ed25519"]])
        #expect(Self.summary(try Self.blocks(html)) == [
            "code[-] Host vm-名字\n    HostName 100.x.x.x\n    User ubuntu\n    Port 52222\n    IdentityFile ~/.ssh/id_ed25519",
        ])
    }

    /// 真正的引用不动：中文说明、带箭头的示意图、英文名言、提到命令名的中文句子、带图片的引用
    @Test func realQuotesStayQuotes() throws {
        let cases = [
            Self.quote([["以下是写给 AI 的操作步骤。把这篇文章交给你的 Claude Code，它可以直接帮你把整套东西配好。"]]),
            Self.quote([["本地主机（Mac）→ 所有服务器 &nbsp; ✅", "服务器 → 本地主机 &nbsp; &nbsp; &nbsp; ❌", "服务器 → 服务器 &nbsp; &nbsp; &nbsp; ❌"]]),
            Self.quote([["The best way to predict the future is to invent it.", "— Alan Kay"]]),
            Self.quote([["记得先用 git status 看一眼，再决定要不要提交。"]]),
            "<blockquote><p>sudo tailscale up</p><p><img src=\"https://example.com/a.png\"></p></blockquote>",
        ]
        for html in cases {
            let bs = try Self.blocks(html)
            #expect(!bs.contains { $0.type == .code }, "误判成代码：\(Self.summary(bs))")
            #expect(bs.contains { $0.type == .quote })
        }
    }

    @Test func segmentsRules() {
        #expect(CodeDetect.segments("这是一段普通的中文。\n第二行也是。") == nil)
        #expect(CodeDetect.segments("Just some English text that reads like a sentence.\nAnother one here, too.") == nil)
        #expect(CodeDetect.segments("Port 52222\nUser ubuntu") == nil)                     // 只有「弱」行不算
        #expect(CodeDetect.segments("$ ls -la\n$ cd ~/repos") == [.code("$ ls -la\n$ cd ~/repos", language: "bash")])
        #expect(CodeDetect.segments("tailscale status   # 查看设备") == [.code("tailscale status   # 查看设备", language: "bash")])
    }

    @Test func fixPunctuation() {
        #expect(CodeDetect.fixPunctuation("brew install —cask x") == "brew install --cask x")
        #expect(CodeDetect.fixPunctuation("ssh “echo ok” ‘a’") == "ssh \"echo ok\" 'a'")
        #expect(CodeDetect.fixPunctuation("等等…") == "等等...")
        #expect(CodeDetect.fixPunctuation("网络层——认证层") == "网络层——认证层")           // 中文破折号不动
    }

    @Test func preLanguageFromClassOrDataAttr() throws {
        let bs = try Self.blocks("<pre><code class=\"hljs language-Swift\">let a = 1</code></pre><pre data-lang=\"python\">print(1)</pre><pre>plain</pre>")
        #expect(bs.map(\.language) == ["swift", "python", nil])
    }

    @Test func markdownFenceLongerThanBackticksInside() {
        var art = Article(id: "x", canonicalId: "x", aliases: [], source: .clip, url: "", capturedURL: "", title: "t",
                          author: nil, authorHandle: nil, authorURL: nil, publishedAt: nil, capturedAt: Date(), cover: nil,
                          summary: nil, blocks: [.code("echo ```\necho ok", language: "bash")], extractor: "t",
                          stats: ArticleStats(chars: 0, images: 0, imagesSaved: 0, videos: 0))
        art.recomputeStats()
        let md = Markdown.render(art)
        #expect(md.contains("````bash\necho ```\necho ok\n````"))
    }

    @Test func plainTextClipDetectsCode() {
        let bs = Clip.textBlocks("安装步骤如下：\nbrew install --cask tailscale\nsudo tailscale up\n装好以后用同一个账号登录。\n\n第二段只是文字。")
        #expect(Self.summary(bs) == [
            "paragraph 安装步骤如下：",
            "code[bash] brew install --cask tailscale\nsudo tailscale up",
            "paragraph 装好以后用同一个账号登录。",
            "paragraph 第二段只是文字。",
        ])
        // 空行隔开的两段代码合成一块
        let two = Clip.textBlocks("func a() {\n    return 1\n}\n\nfunc b() {\n    return 2\n}")
        #expect(two.count == 1 && two[0].type == .code)
        #expect(two[0].text == "func a() {\n    return 1\n}\n\nfunc b() {\n    return 2\n}")
    }

    /// 阅读器代码卡片：「复制」链接带原文；注释变淡；HTML 转义
    @Test func readerCodeCard() throws {
        let code = "tailscale status   # 查看设备\n# 整行注释\necho \"<b>&\""
        let h = ReaderHTML.codeCard(code, language: "bash")
        #expect(h.contains("<span>bash</span>"))
        #expect(h.contains("<span class=\"cm\"># 查看设备</span>"))
        #expect(h.contains("<span class=\"ln cm\"># 整行注释</span>"))
        #expect(h.contains("echo \"&lt;b&gt;&amp;\""))
        let href = try #require(h.range(of: #"href="([^"]+)""#, options: .regularExpression).map { String(h[$0].dropFirst(6).dropLast()) })
        let url = try #require(URL(string: href))
        #expect(url.scheme == ReaderHTML.copyScheme)
        #expect(String(url.absoluteString.dropFirst(ReaderHTML.copyScheme.count + 1)).removingPercentEncoding == code)
        // JSON 里的 # 不是注释；没语言时标「代码」
        #expect(!ReaderHTML.codeCard("{\"u\": \"a #b\"}", language: "json").contains("class=\"cm\""))
        #expect(ReaderHTML.codeCard("x", language: nil).contains("<span>代码</span>"))
    }
}

@Suite struct ReparseTests {
    static let html = """
    <html><head><meta property="og:title" content="og"></head><body>
    <script>var biz = "MzAwTest"; var mid = "2650000001"; var idx = "1"; var msg_title = "SSH 测试"; var nickname = "测试号";</script>
    <div id="js_content"><p>开头一段文字，交代背景，说明为什么要这样配置远程连接。</p>
    <p><img data-src="https://mmbiz.qpic.cn/mmbiz_png/abc/640?wx_fmt=png"></p>
    \(CodeFormatTests.quote([["brew install —cask tailscale", "或 App Store 搜索 Tailscale 安装"]]))
    <p>结尾一段。</p></div></body></html>
    """

    /// 模拟老版解析存下的文章：引用块、图片已下载、收藏时间和别名是原来的
    static func makeOld(in dir: URL, imageURL: String? = nil) throws -> Article {
        let t = try Capture.classify("https://mp.weixin.qq.com/s/AbCdEf123")
        var art = try WeChatExtractor().parse(html: html, raw: Data(html.utf8), target: t).article
        art.extractor = "wechat-html@0.1"
        art.capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        art.aliases = ["wechat-short:AbCdEf123"]
        art.blocks = art.blocks.flatMap { b -> [Block] in
            if b.type == .code { return [.quote([Inline("brew install —cask tailscale\n或 App Store 搜索 Tailscale 安装")])] }
            if b.type == .paragraph && b.plainText.hasPrefix("或 App Store") { return [] }
            if var img = b.image { img.file = "images/01.png"; img.width = 640; if let u = imageURL { img.url = u }; return [.image(img)] }
            return [b]
        }
        art.recomputeStats()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try LibraryWriter.writeFiles(art, to: dir)
        try Gzip.compress(Data(html.utf8)).write(to: dir.appendingPathComponent("source.html.gz"))
        return art
    }

    @Test func reparseKeepsImagesAndMetadata() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shicang-reparse-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = try Self.makeOld(in: dir)
        #expect(!old.blocks.contains { $0.type == .code })

        let r = Reparser.reparse(dir: dir)
        guard case .updated = r else { Issue.record("没有更新：\(r)"); return }
        let new = try Coders.decoder.decode(Article.self, from: Data(contentsOf: dir.appendingPathComponent("article.json")))
        #expect(new.extractor == WeChatExtractor.version)
        #expect(new.id == old.id && new.capturedAt == old.capturedAt && new.aliases == old.aliases && new.title == old.title)
        #expect(new.blocks.contains { $0.type == .code && $0.text == "brew install --cask tailscale" && $0.language == "bash" })
        let img = try #require(new.blocks.compactMap(\.image).first)
        #expect(img.file == "images/01.png" && img.width == 640)
        #expect(new.stats.imagesSaved == 1)
        let md = try String(contentsOf: dir.appendingPathComponent("article.md"), encoding: .utf8)
        #expect(md.contains("```bash\nbrew install --cask tailscale\n```"))
        #expect(Reparser.reparse(dir: dir) == .current)
    }

    @Test func reparseSkipsWhenImagesDiffer() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shicang-reparse-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try Self.makeOld(in: dir, imageURL: "https://mmbiz.qpic.cn/other/0")
        let before = try Data(contentsOf: dir.appendingPathComponent("article.json"))
        #expect(Reparser.reparse(dir: dir) == .skipped("图片列表和原来对不上"))
        #expect(try Data(contentsOf: dir.appendingPathComponent("article.json")) == before)
    }

    @Test func processorReparsesOutdatedOnce() async throws {
        let (paths, base) = try tempPaths()
        defer { try? FileManager.default.removeItem(at: base) }
        let t = try Capture.classify("https://mp.weixin.qq.com/s/AbCdEf123")
        let id = try WeChatExtractor().parse(html: Self.html, raw: Data(), target: t).article.id
        _ = try Self.makeOld(in: paths.folder(for: id))
        let p = Processor(paths: paths, device: DeviceInfo.load(local: paths.local))
        await p.index.refresh()
        #expect(await p.index.summary(id)?.extractor == "wechat-html@0.1")
        #expect(await p.reparseOutdated() == 1)
        #expect(await p.index.summary(id)?.extractor == WeChatExtractor.version)
        #expect(await p.reparseOutdated() == 0)
    }

    @Test func gzipRoundTripAndSystemGzip() throws {
        let d = Data("拾藏 gzip 测试 ".utf8) + Data((0..<5000).map { UInt8($0 % 251) })
        #expect(Gzip.decompress(try Gzip.compress(d)) == d)
        var bad = try Gzip.compress(d)
        bad[bad.count - 6] ^= 0xff
        #expect(Gzip.decompress(bad) == nil)
        // 系统 gzip 带文件名字段（FNAME）
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shicang-gz-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("a.txt")
        try d.write(to: f)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        proc.arguments = ["-k", f.path]
        try proc.run(); proc.waitUntilExit()
        #expect(Gzip.decompress(try Data(contentsOf: dir.appendingPathComponent("a.txt.gz"))) == d)
    }
}
