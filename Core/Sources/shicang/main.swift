import Foundation
import AppKit
import ShicangCore

// 命令行测试工具（App 用同一套 ShicangCore）：
//   shicang run --root DIR <链接或分享文字>...   完整流程：入队 → 认领 → 抓取 → 写入 DIR（隔离的测试根目录）
//   shicang ingest --root DIR                    只处理 DIR/Inbox 和 --extra 目录里的外来文件（模拟快捷指令）
//   shicang extract <链接>                       只抓取，Markdown 打到标准输出
//   shicang xweb|wxweb|plain [--md] <链接>       只跑某个兜底通道（X 网页 / 公众号 WKWebView / 通用网页不跑 JS）
//   shicang render <article.json> [-o out.html]  阅读视图 HTML
//   shicang classify --root DIR [--use-app-key] [--model M] [--force] [id...]   AI 分类（不给 id＝所有还没分类的）
//   shicang search --root DIR <关键词...>        全文搜索
//   shicang list --root DIR                      列出文件库（分类/标签/摘要）
//   shicang reparse --root DIR                   解析规则升级后，用原始快照在本机重新解析老文章（公众号）
//   shicang clip --root DIR [--title T] [--html FILE] [--url 来源] [--text-file F] [文字...]   剪藏一段内容（不是链接）
//   shicang ai-test [--use-app-key] [--provider P] [--base URL] [--model M] [--key-env 变量名] [--list-models]   测试 AI 平台
//   --use-app-key：只读地使用 App 正式设置里的平台和密钥（不复制、不打印）
//   --provider/--base/--model/--key-env：临时换平台（密钥只从环境变量读，不出现在命令行里）；classify 也认

let args = Array(CommandLine.arguments.dropFirst())

func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func opts(_ name: String) -> [String] {
    var out: [String] = []
    for (i, a) in args.enumerated() where a == name && i + 1 < args.count { out.append(args[i + 1]) }
    return out
}

func positional() -> [String] {
    var out: [String] = []
    var skip = false
    for a in args.dropFirst() {
        if skip { skip = false; continue }
        if ["--root", "-o", "--extra", "--workers", "--idx", "--len", "--model", "--title", "--html", "--url", "--text-file",
            "--provider", "--base", "--key-env"].contains(a) { skip = true; continue }
        if a.hasPrefix("--") { continue }          // --md / --dump 等开关
        out.append(a)
    }
    return out
}

func testPaths() -> Paths {
    guard let r = opt("--root") else {
        FileHandle.standardError.write("必须给 --root（测试不碰真实 iCloud 目录）\n".data(using: .utf8)!)
        exit(2)
    }
    let root = URL(fileURLWithPath: r, isDirectory: true)
    return Paths(root: root.appendingPathComponent("iCloud", isDirectory: true),
                 local: root.appendingPathComponent("local", isDirectory: true),
                 extraInboxes: opts("--extra").map { URL(fileURLWithPath: $0, isDirectory: true) })
}

final class Printer: @unchecked Sendable {
    let t0 = Date()
    let lock = NSLock()
    func say(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        print(String(format: "[%5.1fs] ", Date().timeIntervalSince(t0)) + s)
        fflush(stdout)
    }
}

/// 命令行的 AI 设置：--use-app-key 读 App 正式设置，--provider 等参数临时覆盖
func cliSecrets() -> Secrets? {
    let override = ["--provider", "--base", "--model", "--key-env"].contains { opt($0) != nil }
    guard args.contains("--use-app-key") || override else { return nil }
    var s = args.contains("--use-app-key") ? SecretStore.load(Paths.standard()) : Secrets()
    if let p = opt("--provider") {
        guard AIPreset.all.contains(where: { $0.id == p }) else {
            FileHandle.standardError.write("不认识的平台 \(p)；可选：\(AIPreset.all.map(\.id).joined(separator: " "))\n".data(using: .utf8)!)
            exit(2)
        }
        s.activeProvider = p
    }
    let id = s.activeProvider
    if let b = opt("--base") { s.providers[id, default: AIProviderSettings()].baseURL = b }
    if let m = opt("--model") {
        let chain = m.split(separator: ",").map(String.init)
        s.providers[id, default: AIProviderSettings()].model = chain.first
        s.providers[id, default: AIProviderSettings()].fallbacks = Array(chain.dropFirst())
    }
    if let k = opt("--key-env") { s.providers[id, default: AIProviderSettings()].apiKey = ProcessInfo.processInfo.environment[k] }
    return s
}

func secretsProvider() -> (@Sendable () -> Secrets)? {
    guard let s = cliSecrets() else { return nil }
    return { s }
}

func makeProcessor() -> Processor {
    let paths = testPaths()
    let device = DeviceInfo.load(local: paths.local)
    return Processor(paths: paths, device: device, secrets: secretsProvider())
}

func runPipeline(inputs: [String]) async {
    let p = makeProcessor()
    if let w = opt("--workers").flatMap(Int.init) { await p.setWorkers(w) }
    let out = Printer()
    await p.setHandler { e in
        switch e {
        case .queued(let i): out.say("📥 入队 \(i.source.rawValue) \(i.url)")
        case .started(let i): out.say("⚙️  开始 \(i.url)")
        case .saved(let s, let fails):
            out.say("✅ \(s.source.rawValue) | \(s.title) | 字 \(s.chars) | 图 \(s.imagesSaved)/\(s.images) | 视频 \(s.videos)\(fails > 0 ? " | 缺图 \(fails)" : "") | \(s.folder.path)")
        case .merged(let id, let t): out.say("🔁 已存在（合并）\(id) \(t)")
        case .failed(let i):
            out.say("❌ \(i.url) | \(i.lastError ?? "?") | \(i.nextRetryAt != nil ? "会自动重试" : "不自动重试")")
        case .changed: break
        case .classified(_, let t, let c, let m, let sec, let low):
            out.say(String(format: "🏷  %@ → %@%@（%@，%.1fs）", t, c, low ? "（待确认）" : "", m, sec))
        case .classifyFailed(_, let m): out.say("⚠️  分类失败：\(m)")
        case .classifyStatus: break
        case .reparsed(let id, let t, let note): out.say("♻️  重新解析 \(id) \(t)：\(note)")
        }
    }
    do { try await p.start() } catch { out.say("启动失败：\(error)"); return }
    for input in inputs {
        let t = Date()
        let r = await p.enqueue(input, via: "cli")
        out.say(String(format: "入队返回（%.0f ms）：%@", Date().timeIntervalSince(t) * 1000, r.message))
    }
    // 等队列清空（失败且等待自动重试的不等）
    let deadline = Date().addingTimeInterval(Double(max(inputs.count, 1)) * 150)
    while Date() < deadline {
        try? await Task.sleep(nanoseconds: 500_000_000)
        let q = await p.queue()
        let busy = q.contains { $0.running || $0.item.status == .pending }
        if !busy, await p.isIdle { break }
    }
    let q = await p.queue()
    let all = await p.index.all
    out.say("完成：文件库 \(all.count) 篇，收件箱剩 \(q.count) 条（失败 \(q.filter { $0.item.status == .failed }.count)）")
}

@MainActor
func runExtract() async {
    for input in positional() {
        do {
            let t = try Capture.classify(input)
            let ex = try await Extractors.run(t)
            print(Markdown.render(ex.article))
            let s = ex.article.stats
            FileHandle.standardError.write("✅ \(ex.article.extractor) | 字 \(s.chars) | 图 \(s.images) | 视频 \(s.videos)\n".data(using: .utf8)!)
        } catch {
            FileHandle.standardError.write("❌ \(input) | \(Extractors.classify(error))\n".data(using: .utf8)!)
        }
    }
}

/// 单独跑某个兜底通道：xweb（X 网页）/ wxweb（公众号 WKWebView）/ plain（通用网页不跑 JS）
@MainActor
func runChannel(_ name: String) async {
    for input in positional() {
        let t0 = Date()
        do {
            let t = try Capture.classify(input)
            let ex: Extraction
            switch name {
            case "xweb": ex = try await XWebExtractor().extract(t)
            case "wxweb": ex = try await WeChatWebExtractor().extract(t)
            default: ex = try await WebPlainExtractor().extract(t)
            }
            if args.contains("--md") { print(Markdown.render(ex.article)) }
            let a = ex.article, s = a.stats
            print(String(format: "✅ %@ | %@ | 作者 %@ | 字 %d | 图 %d | 视频 %d | %.1fs", a.extractor, a.title, a.author ?? "-", s.chars, s.images, s.videos, Date().timeIntervalSince(t0)))
        } catch {
            print(String(format: "❌ %@ | %@ | %.1fs", input, Extractors.classify(error).message, Date().timeIntervalSince(t0)))
        }
    }
}

/// X 改版排查：列出页面上第一个 article 里的 data-testid（选择器失效时先跑这个）
@MainActor
func runXProbe() async {
    for input in positional() {
        guard let url = Capture.firstURL(in: input) else { continue }
        let b = HiddenBrowser(userAgent: UA.macSafari)
        let t0 = Date()
        do { try await b.load(url) } catch { print("load 失败：\(error)") }
        print(String(format: "load 用时 %.1fs", Date().timeIntervalSince(t0)))
        for i in 0..<12 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let r = try? await b.js("""
            const a = document.querySelector('article');
            return {n: document.querySelectorAll('article').length,
                    ids: a ? [...new Set([...a.querySelectorAll('[data-testid]')].map(e => e.dataset.testid))].join(',') : '',
                    atid: a ? (a.getAttribute('data-testid') || '') : '',
                    tt: document.querySelectorAll('[data-testid="tweetText"]').length};
            """) as? [String: Any]
            print("t+\(i + 1)s", r ?? [:])
            if let n = r?["n"] as? Int, n > 0, i >= 3 { break }
        }
        if let r = try? await b.js("""
        const out = [];
        document.querySelectorAll('article').forEach((a, i) => {
          const st = [...a.querySelectorAll('a[href*="/status/"]')].map(x => x.getAttribute('href')).filter((v, j, arr) => arr.indexOf(v) === j).slice(0, 4);
          const langs = [...a.querySelectorAll('div[dir="auto"][lang]')].map(d => d.innerText.length);
          const imgs = [...a.querySelectorAll('img')].map(m => (m.getAttribute('src') || '').replace('https://pbs.twimg.com/', '').slice(0, 50)).filter(s => !s.startsWith('profile_images'));
          const vids = a.querySelectorAll('video').length;
          out.push(`#${i} status=${st.join(' ')} lang=${langs.join('/')} imgs=${imgs.length}:${imgs.slice(0, 3).join(' ')} video=${vids} text=${a.innerText.length}`);
        });
        const h = [...document.querySelectorAll('h1,h2')].map(x => x.tagName + ':' + x.innerText.slice(0, 40)).slice(0, 5);
        return out.join('\\n') + '\\nheadings: ' + h.join(' | ') + '\\nbodyText=' + document.body.innerText.length + '\\nlocation=' + location.href;
        """) as? String { print(r) }
        if args.contains("--dump"), let html = try? await b.js("""
        const a = document.querySelector('article'); if (!a) return '';
        const c = a.cloneNode(true);
        c.querySelectorAll('svg,path,script').forEach(e => e.remove());
        return c.outerHTML.replace(/ (class|id|style|srcset|sizes)="[^"]*"/g, '').slice(0, 5000);
        """) as? String { print("---- article[0] ----\n" + html) }
        b.close()
    }
}

func runRender() {
    guard let f = positional().first, let d = try? Data(contentsOf: URL(fileURLWithPath: f)),
          let art = try? Coders.decoder.decode(Article.self, from: d) else { print("读不了 article.json"); return }
    let dir = URL(fileURLWithPath: f).deletingLastPathComponent()
    let html = ReaderHTML.render(art, ai: AIStore.load(dir: dir), highlights: HighlightStore.load(dir: dir, resolve: false))
    if let o = opt("-o") { try? html.write(toFile: o, atomically: true, encoding: .utf8); print("写入 \(o)") } else { print(html) }
}

func catName(_ t: Taxonomy, _ id: String?) -> String { id.flatMap { t.name($0) } ?? "未分类" }

func runClassify() async {
    let p = makeProcessor()
    let out = Printer()
    try? testPaths().ensure()
    await p.index.refresh()
    let all = await p.index.all
    var ids = positional()
    if ids.isEmpty { ids = all.filter { args.contains("--force") || $0.ai == nil }.map(\.id) }
    let tax = await p.index.taxonomy
    out.say("分类 \(ids.count) 篇；分类表 \(tax.active.map(\.name).joined(separator: "、"))")
    var ok = 0
    for id in ids {
        let t0 = Date()
        let title = await p.index.title(id)
        switch await p.classifier.classifyNow(id) {
        case .success(let r):
            ok += 1
            out.say(String(format: "🏷  %@ | %@ | 置信 %.2f%@ | %@ | %.1fs", String(title.prefix(40)), r.categoryName, r.confidence,
                           r.lowConfidence ? "（待确认）" : "", r.model, Date().timeIntervalSince(t0)))
            print("     标签：\(r.tags.joined(separator: "、"))")
            print("     摘要：\(r.summary)")
            for k in r.keyPoints { print("       · \(k)") }
        case .failure(let e):
            out.say("❌ \(title.prefix(40)) | \(e)")
        }
    }
    out.say("完成 \(ok)/\(ids.count)")
}

func runClip() async {
    let p = makeProcessor()
    try? testPaths().ensure()
    await p.index.refresh()
    var text = positional().joined(separator: " ")
    if let f = opt("--text-file"), let t = try? String(contentsOfFile: f, encoding: .utf8) { text = t }
    let html = opt("--html").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
    let input = ClipInput(text: text, html: html, sourceURL: opt("--url"), title: opt("--title"))
    let pv = Clip.preview(input)
    print("预览：《\(pv.title)》\(pv.chars) 字 · \(pv.images) 张图\(pv.host.map { " · 来自 \($0)" } ?? "")\(pv.rich ? " · 保留格式" : " · 纯文字")")
    for l in pv.lines { print("  │ \(l.prefix(60))") }
    let r = await p.saveClip(input, via: "cli")
    print(r.message)
    if case .clipped(let id, _) = r { print("  \(testPaths().folder(for: id).path)") }
}

func runAITest() async {
    let s = cliSecrets() ?? Secrets()
    let c = s.active
    print("平台：\(c.preset.name)  端点：\(c.endpoint?.absoluteString ?? "（没填地址）")  模型：\(c.modelChain.joined(separator: " → "))  密钥：\(c.hasKey ? "已设置" : "未设置")")
    if args.contains("--list-models") {
        guard let client = AIClient(config: c, timeout: 30) else { print("❌ \(c.missing ?? "设置不完整")"); return }
        do { let ms = try await client.listModels(); print("模型 \(ms.count) 个："); for m in ms { print("  \(m)") } }
        catch { print("❌ 拉取模型列表失败：\(error)") }
        return
    }
    let tax = opt("--root").map { _ in TaxonomyStore.load(testPaths()) } ?? Taxonomy()
    switch await AITester.run(c, taxonomy: tax) {
    case .success(let m): print("✅ \(m)")
    case .failure(let e): print("❌ \(e)")
    }
}

func runSearch() async {
    let p = makeProcessor()
    await p.index.refresh()
    let q = positional().joined(separator: " ")
    let t0 = Date()
    let hits = await p.index.search(q)
    let ms = Date().timeIntervalSince(t0) * 1000
    print(String(format: "「%@」→ %d 篇（%.1f ms）%@", q, hits.count, ms, SearchText.query(q).map { "  MATCH \($0.match)" } ?? ""))
    for h in hits {
        let title = await p.index.title(h.id)
        print("  \(h.id)  \(title)")
        if let s = h.snippet { print("      \(s)") }
    }
}

func runList() async {
    let p = makeProcessor()
    await p.index.refresh()
    let tax = await p.index.taxonomy
    for s in await p.index.all {
        print("\(s.id)  [\(catName(tax, s.categoryId))\(s.needsReview ? "·待确认" : "")]\(s.isStarred ? " ★" : "")\(s.isRead ? "" : " ●")  \(s.title)")
        if !s.tags.isEmpty { print("      #\(s.tags.joined(separator: " #"))") }
    }
}

/// shicang reparse：解析器版本过旧的文章用原始快照重新解析（不联网）
func runReparse() async {
    let p = makeProcessor()
    let out = Printer()
    await p.setHandler { e in if case .reparsed(let id, let t, let note) = e { out.say("♻️  \(id) \(t)：\(note)") } }
    await p.index.refresh()
    let n = await p.reparseOutdated()
    out.say("重新解析了 \(n) 篇")
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

Task { @MainActor in
    switch args.first {
    case "run": await runPipeline(inputs: positional())
    case "ingest": await runPipeline(inputs: [])
    case "reparse": await runReparse()
    case "extract": await runExtract()
    case "xweb", "wxweb", "plain": await runChannel(args[0])
    case "render": runRender()
    case "xprobe": await runXProbe()
    case "classify": await runClassify()
    case "search": await runSearch()
    case "list": await runList()
    case "clip": await runClip()
    case "ai-test": await runAITest()
    default: print("用法：shicang run|ingest|extract|xweb|render|classify|clip|ai-test|reparse …（见源码顶部注释）")
    }
    exit(0)
}
RunLoop.main.run()
