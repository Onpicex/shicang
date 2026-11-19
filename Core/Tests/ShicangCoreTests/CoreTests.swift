import Foundation
import Testing
import SwiftSoup
@testable import ShicangCore

/// 每个测试一个独立临时根目录（绝不碰真实 iCloud/Application Support）
func tempPaths(_ tag: String = #function) throws -> (Paths, URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("shicang-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let p = Paths(root: base.appendingPathComponent("iCloud"), local: base.appendingPathComponent("local"),
                  extraInboxes: [base.appendingPathComponent("shortcuts/拾藏Inbox")])
    try p.ensure()
    p.ensureExtraInboxes()
    return (p, base)
}

@Suite struct CaptureTests {
    @Test func classifyIsIdempotent() throws {
        for s in ["看看这个 https://x.com/someone/status/1900000000000000001?s=20 很好",
                  "https://mp.weixin.qq.com/s/AbCdEfGhIjKlMnOpQrStUv",
                  "https://www.paulgraham.com/greatwork.html"] {
            let a = try Capture.classify(s)
            let b = try Capture.classify(a.url.absoluteString)
            #expect(a.key == b.key)
            #expect(a.source == b.source)
        }
    }

    @Test func xVariantsShareKey() throws {
        let a = try Capture.classify("https://twitter.com/someone/status/1900000000000000001")
        let b = try Capture.classify("https://fxtwitter.com/someone/status/1900000000000000001?s=46")
        #expect(a.key == b.key)
        #expect(a.source == .x)
    }

    @Test func hashIs16Hex() {
        let h = Capture.hash("x:123")
        #expect(h.count == 16)
        #expect(Inbox.isHashName(h))
    }

    @Test func noLinkRejected() {
        #expect(throws: (any Error).self) { try Capture.classify("没有链接的一段话") }
    }
}

@Suite struct MarkdownTests {
    @Test(arguments: [
        ("# 不是标题", "\\# 不是标题"),
        ("#话题标签", "#话题标签"),
        ("- 不是列表", "\\- 不是列表"),
        ("-负数", "-负数"),
        ("1. 不是有序列表", "1\\. 不是有序列表"),
        ("2026.11.19 是日期", "2026.11.19 是日期"),
        ("3) 选项", "3\\) 选项"),
        ("> 不是引用", "\\> 不是引用"),
        ("---", "\\---"),
        ("===", "\\==="),
        ("普通一行", "普通一行"),
    ])
    func escapeLineStart(_ input: String, _ expected: String) {
        #expect(Markdown.escapeLineStart(input) == expected)
    }

    @Test func tweetTitleNotRepeated() {
        var a = sampleArticle()
        a.title = "这是推文的第一行，写得很长很长…"
        a.blocks = [.paragraph([Inline("这是推文的第一行，写得很长很长很长很长\n第二行")])]
        #expect(a.titleRepeatsInBody)
        let md = Markdown.render(a)
        #expect(!md.contains("\n# 这是推文"))
    }

    @Test func distinctTitleKept() {
        var a = sampleArticle()
        a.title = "独立标题"
        a.blocks = [.paragraph([Inline("正文开头和标题无关")])]
        #expect(!a.titleRepeatsInBody)
        #expect(Markdown.render(a).contains("# 独立标题"))
    }

    @Test func paragraphLineStartsEscaped() {
        var a = sampleArticle()
        a.blocks = [.paragraph([Inline("第一行\n1. 被误读\n# 也被误读")])]
        let md = Markdown.render(a)
        #expect(md.contains("1\\. 被误读"))
        #expect(md.contains("\\# 也被误读"))
    }
}

@Suite struct HTMLBlockTests {
    @Test func samePageFootnoteIsPlainText() throws {
        let base = URL(string: "https://www.paulgraham.com/greatwork.html")!
        let html = ##"<p>Some claim<a href="#f1n"><font color=#999999>[1]</font></a> and <a href="https://www.paulgraham.com/greatwork.html#f2n">[2]</a> and <a href="https://example.com/x">real</a>.</p>"##
        let doc = try SwiftSoup.parseBodyFragment(html, base.absoluteString)
        let blocks = try HTMLBlockBuilder(baseURL: base) { _ in nil }.build(doc.body()!)
        let links = blocks.flatMap { $0.inlines ?? [] }.compactMap(\.link)
        #expect(links == ["https://example.com/x"])
        let md = Markdown.inlineMD(blocks[0].inlines ?? [])
        #expect(!md.contains("#f1n"))
        #expect(md.contains("[1]"))
    }
}

@Suite struct TableTests {
    @Test func layoutTableIsFlattenedNotDoubled() throws {
        let long = String(repeating: "Lorem ipsum dolor sit amet. ", count: 20)
        let html = "<table><tr><td></td><td><table><tr><td>July 2023<br><br>\(long)<br><br>Second para.</td></tr></table></td></tr></table>"
        let doc = try SwiftSoup.parseBodyFragment(html)
        let blocks = try HTMLBlockBuilder(baseURL: nil) { _ in nil }.build(doc.body()!)
        #expect(!blocks.contains { $0.type == .table })
        #expect(blocks.map(\.plainText) == ["July 2023", long.trimmingCharacters(in: .whitespaces), "Second para."])
    }

    @Test func dataTableKept() throws {
        let html = "<table><thead><tr><th>名称</th><th>价格</th></tr></thead><tbody><tr><td>A</td><td>1</td></tr><tr><td>B</td><td>2</td></tr></tbody></table>"
        let doc = try SwiftSoup.parseBodyFragment(html)
        let blocks = try HTMLBlockBuilder(baseURL: nil) { _ in nil }.build(doc.body()!)
        #expect(blocks.count == 1)
        #expect(blocks.first?.rows == [["名称", "价格"], ["A", "1"], ["B", "2"]])
        #expect(blocks.first?.header == true)
    }
}

@Suite struct ParagraphSplitTests {
    @Test func blankLinesBecomeParagraphs() throws {
        let html = "<div>第一段<br><br>第二段<b>加粗</b><br>同段换行<br> <br><br>第三段</div>"
        let doc = try SwiftSoup.parseBodyFragment(html)
        let blocks = try HTMLBlockBuilder(baseURL: nil) { _ in nil }.build(doc.body()!)
        #expect(blocks.map(\.plainText) == ["第一段", "第二段加粗\n同段换行", "第三段"])
        #expect(blocks[1].inlines?.contains { $0.bold == true && $0.text == "加粗" } == true)
    }

    @Test func breakAcrossStyledInlines() {
        let parts = HTMLBlockBuilder.splitOnBlankLines([Inline("前文\n"), Inline("\n后文", bold: true)])
        #expect(parts.count == 2)
        #expect(parts[1].first?.bold == true)
    }
}

@Suite struct InboxTests {
    @Test func parseShortcutJSON() {
        let d = #"{"url":"https://x.com/a/status/1","share_text":"分享文字","device":"iPhone","captured_at":"2026-11-19 16:20:05"}"#.data(using: .utf8)!
        let f = Inbox.parseForeign(d, ext: "json")
        #expect(f?.device == "iPhone")
        #expect(f?.text.contains("https://x.com/a/status/1") == true)
        #expect(f?.capturedAt != nil)
    }

    @Test func parseWebloc() throws {
        let pl = try PropertyListSerialization.data(fromPropertyList: ["URL": "https://example.com/a"], format: .xml, options: 0)
        #expect(Inbox.parseForeign(pl, ext: "webloc")?.text == "https://example.com/a")
    }

    @Test func parseWindowsURLAndText() {
        #expect(Inbox.parseForeign("[InternetShortcut]\r\nURL=https://example.com/b\r\n".data(using: .utf8)!, ext: "url")?.text == "https://example.com/b")
        #expect(Inbox.parseForeign("  看这个 https://example.com/c  ".data(using: .utf8)!, ext: "txt")?.text == "看这个 https://example.com/c")
        #expect(Inbox.parseForeign("   ".data(using: .utf8)!, ext: "txt") == nil)
    }

    @Test func claimsBetweenDevices() throws {
        let (p, base) = try tempPaths()
        defer { try? FileManager.default.removeItem(at: base) }
        let mac = Inbox(paths: p, device: DeviceInfo(id: "mac", name: "Mac"))
        let mini = Inbox(paths: p, device: DeviceInfo(id: "mini", name: "Mac mini"))
        let id = Capture.hash("web:https://example.com/")
        #expect(mac.claim(id))
        #expect(!mini.claim(id))
        #expect(mini.claimedByOther(id)?.deviceName == "Mac")
        mac.release(id)
        #expect(mini.claim(id))
        // 过期认领可被接手
        let expired = Claim(device: "mini", deviceName: "Mac mini", expiresAt: Date().addingTimeInterval(-1))
        try Coders.encoder.encode(expired).write(to: mini.claimURL(id))
        #expect(mac.claim(id))
    }

    @Test func shareTextOnlyWhenDifferent() throws {
        let (p, base) = try tempPaths()
        defer { try? FileManager.default.removeItem(at: base) }
        let inbox = Inbox(paths: p, device: DeviceInfo(id: "d", name: "Mac"))
        let t = try Capture.classify("https://example.com/a")
        #expect(inbox.makeItem(t, shareText: "https://example.com/a", via: "cli").shareText == nil)
        #expect(inbox.makeItem(t, shareText: "好文 https://example.com/a", via: "cli").shareText == "好文 https://example.com/a")
    }
}

@Suite struct ProcessorTests {
    @Test func enqueueDedupAndReject() async throws {
        let (p, base) = try tempPaths()
        defer { try? FileManager.default.removeItem(at: base) }
        let proc = Processor(paths: p, device: DeviceInfo(id: "d", name: "Mac"))
        await proc.setPaused(true)                       // 只测入队，不联网
        try await proc.start()

        let t0 = Date()
        let r1 = await proc.enqueue("看看 https://www.paulgraham.com/greatwork.html", via: "cli")
        #expect(Date().timeIntervalSince(t0) < 1)
        guard case .queued(let item) = r1 else { Issue.record("应入队：\(r1.message)"); return }
        #expect(item.shareText == "看看 https://www.paulgraham.com/greatwork.html")

        let r2 = await proc.enqueue("https://www.paulgraham.com/greatwork.html", via: "hotkey")
        guard case .alreadyQueued = r2 else { Issue.record("应已在队列：\(r2.message)"); return }

        let r3 = await proc.enqueue("纯文字没有链接", via: "hotkey")
        guard case .rejected = r3 else { Issue.record("应拒绝"); return }

        // 文件库里已有（文件夹存在即算，不必等 article.json 同步下来）
        let t = try Capture.classify("https://sspai.com/post/73145")
        try FileManager.default.createDirectory(at: p.folder(for: Capture.hash(t.key)), withIntermediateDirectories: true)
        let r4 = await proc.enqueue("https://sspai.com/post/73145", via: "hotkey")
        guard case .exists = r4 else { Issue.record("应已存在：\(r4.message)"); return }
    }

    @Test func foreignFilesIngested() async throws {
        let (p, base) = try tempPaths()
        defer { try? FileManager.default.removeItem(at: base) }
        let shortcutDir = p.extraInboxes[0]
        try #"{"url":"https://example.com/post/1","device":"iPhone"}"#.write(to: shortcutDir.appendingPathComponent("20261119-162005.json"), atomically: true, encoding: .utf8)
        try "随便一段没有链接的话".write(to: shortcutDir.appendingPathComponent("junk.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: shortcutDir.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        let proc = Processor(paths: p, device: DeviceInfo(id: "d", name: "Mac"))
        await proc.setPaused(true)                       // 暂停只停处理，外来文件照收
        try await proc.start()
        for _ in 0..<40 where !(await proc.isIdle) { try await Task.sleep(nanoseconds: 50_000_000) }
        let q = await proc.queue()
        #expect(q.count == 1)
        #expect(q.first?.item.device == "iPhone")
        #expect(q.first?.item.via == "shortcut")
        // 没有链接的一段文字：手机上点了分享就算确认，直接剪藏；只有一个字的当垃圾
        let left = try FileManager.default.contentsOfDirectory(atPath: shortcutDir.path).sorted()
        #expect(left == ["x.txt.unrecognized"])
        let clips = await proc.index.all.filter { $0.source == .clip }
        #expect(clips.count == 1 && clips.first?.title == "随便一段没有链接的话")
    }
}

@Suite struct OutputTests {
    @Test func readerEscapesAndBlocksRemote() {
        var a = sampleArticle()
        a.title = "<script>alert(1)</script>"
        a.blocks = [.paragraph([Inline("x<y & z", link: "javascript:alert(1)")]), .image(ImageRef(url: "https://example.com/i.jpg"))]
        let html = ReaderHTML.render(a)
        #expect(!html.contains("<script>alert"))
        #expect(!html.contains("javascript:"))
        #expect(html.contains("x&lt;y &amp; z"))
        #expect(html.contains("default-src 'none'"))
        #expect(html.contains("图片未下载"))
    }

    @Test func secretsFileIsPrivate() throws {
        let (p, base) = try tempPaths()
        defer { try? FileManager.default.removeItem(at: base) }
        let key = "sk-test-\(UUID().uuidString)"
        try SecretStore.save(Secrets(crsBaseURL: "https://relay.example", crsAPIKey: key), p)
        let attrs = try FileManager.default.attributesOfItem(atPath: SecretStore.url(p).path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: p.local.path)
        #expect((dirAttrs[.posixPermissions] as? Int) == 0o700)
        let loaded = SecretStore.load(p)
        #expect(loaded.crsAPIKey == key)
        #expect(!String(describing: loaded).contains(key))
        #expect(!"\(loaded)".contains(key))
        // 再存一次（覆盖）权限不变
        try SecretStore.save(Secrets(crsBaseURL: nil, crsAPIKey: key + "2"), p)
        #expect((try FileManager.default.attributesOfItem(atPath: SecretStore.url(p).path)[.posixPermissions] as? Int) == 0o600)
    }

    @Test func imageRetryPlanBacksOff() {
        var plan = ImageRetryPlan()
        plan.schedule("a")
        #expect(plan.due().isEmpty)
        #expect(plan.due(Date().addingTimeInterval(601)) == ["a"])
        for _ in 0..<3 { plan.record("a", stillMissing: true) }
        #expect(plan.entries["a"] != nil)
        plan.record("a", stillMissing: true)
        #expect(plan.entries["a"] == nil)
    }
}

func sampleArticle() -> Article {
    Article(id: "0000000000000000", canonicalId: "web:https://example.com/", aliases: [], source: .web,
            url: "https://example.com/", capturedURL: "https://example.com/", title: "标题", author: nil, authorHandle: nil,
            authorURL: nil, publishedAt: nil, capturedAt: Date(), cover: nil, summary: nil, blocks: [],
            extractor: "test", stats: ArticleStats(chars: 0, images: 0, imagesSaved: 0, videos: 0))
}

@Suite struct WebTitleTests {
    @Test func stripsSiteSuffixOnlyWhenItIsTheSite() {
        #expect(WebExtractor.stripSiteSuffix("派早报：iPod touch 宣布停产 - 少数派", site: "少数派") == "派早报：iPod touch 宣布停产")
        #expect(WebExtractor.stripSiteSuffix("派早报 - 少数派", site: "少数派 - 高品质数字消费指南") == "派早报")
        #expect(WebExtractor.stripSiteSuffix("A - B", site: "C") == "A - B")
        #expect(WebExtractor.stripSiteSuffix("How to Do Great Work", site: nil) == "How to Do Great Work")
    }
}

@Suite struct CanonicalTests {
    func t(_ s: String) throws -> CaptureTarget { try Capture.classify(s) }

    @Test func wikipediaRedirectUsesCanonical() throws {
        let orig = try t("https://en.wikipedia.org/wiki/Hotkey")
        let c = WebExtractor.canonicalTarget(orig, declared: "https://en.wikipedia.org/wiki/Keyboard_shortcut", final: orig.url)
        #expect(c.url.absoluteString == "https://en.wikipedia.org/wiki/Keyboard_shortcut")
        #expect(c.key != orig.key)
        #expect(c.capturedURL == orig.capturedURL)
    }

    @Test func homepageCanonicalIgnored() throws {
        let orig = try t("https://blog.example.com/2026/11/post")
        let c = WebExtractor.canonicalTarget(orig, declared: "https://blog.example.com/", final: orig.url)
        #expect(c.key == orig.key)
    }

    @Test func crossSiteCanonicalIgnoredButRedirectKept() throws {
        let orig = try t("https://example.com/a")
        let c1 = WebExtractor.canonicalTarget(orig, declared: "https://evil.example.net/x", final: orig.url)
        #expect(c1.key == orig.key)
        let c2 = WebExtractor.canonicalTarget(orig, declared: nil, final: URL(string: "https://www.example.com/articles/a")!)
        #expect(c2.url.host == "www.example.com")
    }

    @Test func relativeAndWwwCanonical() throws {
        let orig = try t("https://www.example.com/p?id=3&utm_source=x")
        let c = WebExtractor.canonicalTarget(orig, declared: "/posts/3", final: orig.url)
        #expect(c.url.absoluteString == "https://www.example.com/posts/3")
    }
}
