import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ShicangCore

enum SidebarItem: Hashable {
    case all, unread, starred, review, processing, failed
    case uncategorized
    case category(String)
    case source(Source)
    case tag(String)
}

enum SettingsTab: Hashable { case general, ai, taxonomy }

/// 界面状态 + 收藏入口。处理逻辑全在 ShicangCore.Processor（和命令行工具同一套）。
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let paths: Paths
    let device: DeviceInfo
    let processor: Processor
    let hud = HUDController()
    let clipConfirm = ClipConfirmController()
    let aiDraft = AIDraft()

    var articles: [ArticleSummary] = []
    var queue: [QueueEntry] = []
    var sidebar: SidebarItem? = .all
    /// 中栏选中的文章（⌘ 点按、⇧ 点按、⌘A 可以选多篇）
    var selection = Set<ArticleSummary.ID>() {
        didSet { if selection != oldValue { ListSelectionSync.schedule() } }     // 屏幕外的行 SwiftUI 不管，见 ListSelectionSync
    }
    var search = ""
    var searchHits: [SearchHit]?                 // nil＝没在搜；有值＝按相关度排好的结果
    var clipboardOffer = false
    var startError: String?
    var aiReady = false                          // 当前平台设置完整（地址、模型、需要的话密钥）
    var aiProvider = AIPreset.defaultId
    var aiPlatform = ""
    var aiModel = ""
    var taxonomy = Taxonomy()
    var tagCounts: [TagCount] = []
    var classifyStatus = ClassifyStatus()
    var classifyEnabled = true
    var settingsTab: SettingsTab = .general
    /// 在当前侧栏视图里刚改过的文章：即使不再符合筛选（标了已读、改了分类）也先留在列表里，换视图再消失
    var sticky = Set<String>()

    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var reloadPending = false
    @ObservationIgnored private var handledChangeCount = -1      // 已探测过的剪贴板版本（不重复问）
    @ObservationIgnored private var capturedChangeCount = -1     // 已经收藏过的剪贴板版本（探测结果晚到也不再出横幅）
    /// 测试指令 /pbset 改剪贴板前存的原内容（只在内存里，/pbrestore 写回）
    @ObservationIgnored var debugSavedPasteboard: [[(NSPasteboard.PasteboardType, Data)]]?

    /// 测试模式：环境变量 SHICANG_TEST_ROOT 指向隔离目录（不碰真实 iCloud），同时打开调试 URL
    let testRoot: URL? = ProcessInfo.processInfo.environment["SHICANG_TEST_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    /// 测试模式 + SHICANG_TEST_USE_APP_KEY=1：测试目录里没填的密钥只读地借正式设置的（不复制到测试目录）
    let useAppKey: Bool
    @ObservationIgnored var openSettingsAction: (() -> Void)?

    init() {
        if let r = testRoot {
            paths = Paths(root: r.appendingPathComponent("iCloud", isDirectory: true),
                          local: r.appendingPathComponent("local", isDirectory: true),
                          extraInboxes: [r.appendingPathComponent("shortcuts/拾藏Inbox", isDirectory: true)])
        } else {
            paths = Paths.standard()
        }
        device = DeviceInfo.load(local: paths.local)
        useAppKey = testRoot != nil && ProcessInfo.processInfo.environment["SHICANG_TEST_USE_APP_KEY"] == "1"
        var provider: (@Sendable () -> Secrets)?
        if useAppKey {
            let p = paths, std = Paths.standard()
            provider = { AppModel.mergedSecrets(test: p, std: std) }
        }
        processor = Processor(paths: paths, device: device, secrets: provider)
        classifyEnabled = Prefs.load(paths).classifyEnabled
        AppLog.shared.configure(paths.logs)
        if testRoot != nil { AppLog.shared.say("测试模式：数据目录 \(paths.root.path)\(useAppKey ? "（借用正式密钥）" : "")") }
        clipConfirm.onSave = { d in AppModel.shared.confirmClip(d) }
    }

    // MARK: 启动

    func start() {
        guard startTask == nil else { return }
        refreshAIState()
        let proc = processor
        startTask = Task {
            await proc.setHandler { e in Task { @MainActor in AppModel.shared.handle(e) } }
            do {
                try await proc.start()
            } catch {
                startError = "打不开数据文件夹：\(error.localizedDescription)"
                AppLog.shared.say("启动失败 \(error)")
                return
            }
            await reload()
            let dirs = [paths.inbox, paths.library] + paths.extraInboxes
            let w = DirectoryWatcher(dirs) { _ in Task { await proc.tick() } }
            AppLog.shared.say("监听目录 \(w.start() ? "已开始" : "失败")：\(dirs.map(\.lastPathComponent).joined(separator: ", "))")
            watcher = w
            AppLog.shared.say("处理器已启动：文件库 \(articles.count) 篇，收件箱 \(queue.count) 条")
            // 解析规则升级（如公众号里被排成引用框的代码）：老文章用原始快照在本机重新解析一遍
            Task { await proc.reparseOutdated() }
        }
        // 兜底定时器：同步下来的文章、到期的重试和补图（目录监听漏掉时也能跟上）
        tickTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await proc.tick()
            }
        }
    }

    private func handle(_ e: ProcessorEvent) {
        switch e {
        case .queued(let i): AppLog.shared.say("入队 [\(i.via)] \(i.url)")
        case .started(let i): AppLog.shared.say("开始 \(i.url)")
        case .saved(let s, let fails):
            AppLog.shared.say("保存 \(s.id) \(s.source.rawValue) 字\(s.chars) 图\(s.imagesSaved)/\(s.images) 视频\(s.videos)\(fails > 0 ? " 缺图\(fails)" : "") | \(s.title)")
        case .merged(let id, let t): AppLog.shared.say("合并到已有 \(id) | \(t)")
        case .failed(let i): AppLog.shared.say("失败 \(i.url) | \(i.lastError ?? "?") | \(i.nextRetryAt != nil ? "会自动重试" : "需手动重试")")
        case .changed: break
        case .classified(let id, let t, let c, let m, let sec, let low):
            AppLog.shared.say(String(format: "分类 %@ → %@%@（%@，%.1fs）| %@", id, c, low ? "·待确认" : "", m, sec, t))
        case .classifyFailed(let id, let msg):
            AppLog.shared.say("分类失败 \(id ?? "-") | \(msg)")
        case .classifyStatus(let st):
            classifyStatus = st
            return
        case .reparsed(let id, let t, let note): AppLog.shared.say("重新解析 \(id) \(note) | \(t)")
        }
        scheduleReload()
    }

    func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            reloadPending = false
            await reload()
        }
    }

    func reload() async {
        let idx = processor.index
        articles = await idx.all
        queue = await processor.queue()
        taxonomy = await idx.currentTaxonomy()
        tagCounts = await idx.tagCounts()
        classifyStatus = await processor.classifier.currentStatus
        let ids = Set(articles.map(\.id))
        if !selection.isSubset(of: ids) { selection.formIntersection(ids) }
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { await runSearch() }
        pruneMultiSelection()
    }

    /// 只选了一篇时就是这一篇（阅读区显示它）；没选或选了多篇时为 nil
    var selectedArticle: ArticleSummary.ID? {
        get { selection.count == 1 ? selection.first : nil }
        set { selection = newValue.map { [$0] } ?? [] }
    }

    /// 选中的文章，按中栏列表的顺序（不在当前列表里的排在后面）
    var selectedIds: [String] { ordered(selection) }

    func ordered(_ ids: Set<String>) -> [String] {
        let shown = filteredArticles.map(\.id).filter(ids.contains)
        let rest = articles.map(\.id).filter { ids.contains($0) && !shown.contains($0) }
        return shown + rest
    }

    func selectAll() { selection = Set(filteredArticles.map(\.id)) }

    /// 多选时只保留当前列表里看得见的（换视图、搜索收窄后，看不见的文章不应被批量操作带上）。
    /// 只选一篇时照旧：换视图后阅读区还停在那一篇
    private func pruneMultiSelection() {
        guard selection.count > 1 else { return }
        let keep = selection.intersection(filteredArticles.map(\.id))
        if keep != selection { selection = keep }
    }

    // MARK: 搜索

    /// 由界面在输入停顿后调用（.task(id: search) 自带防抖：新输入会取消旧任务）
    func runSearch() async {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchHits = nil; return }
        let hits = await processor.index.search(q)
        guard q == search.trimmingCharacters(in: .whitespacesAndNewlines) else { return }    // 等结果期间又改了
        searchHits = hits
        pruneMultiSelection()
    }

    var searchTerms: [String] { SearchText.query(search)?.terms ?? [] }

    func snippet(_ id: String) -> String? { searchHits?.first { $0.id == id }?.snippet ?? nil }

    // MARK: 派生列表

    var processing: [QueueEntry] { queue.filter { $0.running || $0.item.status == .pending } }
    var failed: [QueueEntry] { queue.filter { !$0.running && $0.item.status == .failed } }

    func selectSidebar(_ s: SidebarItem?) {
        guard s != sidebar else { return }
        sidebar = s
        sticky = []
        pruneMultiSelection()
    }

    /// 跳到某一篇（必要时先切到「全部」）。要等列表把新行画出来再选：同一帧里插入并选中，
    /// macOS 的 List 会把这一行的高度卡在一行（只剩标题），之后内容变了也不恢复。
    func reveal(_ id: String) {
        selectSidebar(.all)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            selectedArticle = id
        }
    }

    func matches(_ a: ArticleSummary, _ item: SidebarItem) -> Bool {
        switch item {
        case .all, .processing, .failed: return true
        case .unread: return !a.isRead
        case .starred: return a.isStarred
        case .review: return a.needsReview
        case .uncategorized: return a.categoryId == nil
        case .category(let c): return a.categoryId == c
        case .source(let s): return a.source == s
        case .tag(let t): return a.tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame }
        }
    }

    func count(_ item: SidebarItem) -> Int { articles.reduce(0) { $0 + (matches($1, item) ? 1 : 0) } }

    /// 中栏列表：先按侧栏筛，再按搜索（有搜索时按相关度排，否则按收藏时间新→旧）
    var filteredArticles: [ArticleSummary] {
        let item = sidebar ?? .all
        let pass: (ArticleSummary) -> Bool = { self.matches($0, item) || self.sticky.contains($0.id) }
        guard let hits = searchHits, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return articles.filter(pass) }
        let byId = Dictionary(articles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return hits.compactMap { byId[$0.id] }.filter(pass)
    }

    var sourcesPresent: [(Source, Int)] {
        let order: [Source] = [.x, .wechat, .web, .clip, .xhs]
        return order.compactMap { s in let n = count(.source(s)); return n > 0 ? (s, n) : nil }
    }

    func categoryName(_ id: String?) -> String? { taxonomy.name(id) }

    func title(_ item: SidebarItem) -> String {
        switch item {
        case .all: return "全部"
        case .unread: return "未读"
        case .starred: return "星标"
        case .review: return "待确认"
        case .processing: return "处理中"
        case .failed: return "失败"
        case .uncategorized: return "未分类"
        case .category(let c): return taxonomy.name(c) ?? "分类"
        case .source(let s): return sourceName(s)
        case .tag(let t): return "#\(t)"
        }
    }

    func openSettings(_ tab: SettingsTab) {
        settingsTab = tab
        openSettingsAction?()
    }

    func summary(_ id: String?) -> ArticleSummary? {
        guard let id else { return nil }
        return articles.first { $0.id == id }
    }

    // MARK: 收藏入口

    /// 所有入口最终都到这里。入队只做判平台、查重、写一个小文件（≤1 秒），抓取在后台。
    func capture(_ text: String, via: String, showHUD: Bool = true) async {
        await startTask?.value
        let t0 = Date()
        let r = await processor.enqueue(text, via: via)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        AppLog.shared.say("收藏[\(via)] 入队用时 \(ms)ms → \(r.message)")
        if showHUD { hud.show(r) }
        if case .exists(let id, _) = r, via != "hotkey" {    // 重复收藏：跳到那篇（快捷键在别的 App 里按，不抢焦点）
            reveal(id)
        }
        scheduleReload()
    }

    /// 快捷键 / 菜单 / 横幅「收藏」：这时才读剪贴板（P0 实测读剪贴板不弹授权）。链接→抓原文；一段文字/图文→弹小窗确认后剪藏
    func captureClipboard(via: String) {
        let pb = NSPasteboard.general
        handledChangeCount = pb.changeCount
        capturedChangeCount = pb.changeCount
        clipboardOffer = false
        let c = PasteboardContent.read(pb)
        AppLog.shared.say("收藏[\(via)] 剪贴板 \(c.logLine)")
        route(c, via: via)
    }

    /// 链接（或链接＋一段话）→ 收藏原文；其余有字或有图的 → 剪藏确认窗
    func route(_ c: PasteboardContent, via: String) {
        let t = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, Clip.looksLikeLink(t) {
            Task { await capture(c.text, via: via) }
            return
        }
        let input = ClipInput(text: c.text, html: c.html, sourceURL: c.sourceURL)
        let hasText = !t.isEmpty || !Clip.plainText(input).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImage = c.html?.range(of: "<img", options: .caseInsensitive) != nil
        guard hasText || hasImage else {
            AppLog.shared.say("收藏[\(via)] 剪贴板里没有文字或链接")
            hud.show(.rejected("剪贴板里没有文字或链接"))
            return
        }
        Task { await offerClip(input, via: via) }
    }

    /// 剪藏第一步：查重，没存过就弹确认窗（标题可改，回车保存、Esc 取消）
    func offerClip(_ input: ClipInput, via: String) async {
        await startTask?.value
        if let id = await processor.index.lookup(key: Clip.key(input)) {
            AppLog.shared.say("剪藏[\(via)] 这段已经存过 \(id)")
            hud.show(.exists(id: id, title: summary(id)?.title ?? ""))
            if via != "hotkey" { reveal(id) }
            return
        }
        let pv = await Task.detached { Clip.preview(input) }.value
        clipConfirm.show(input: input, preview: pv, via: via)
    }

    /// 剪藏第二步：用户点了保存
    func confirmClip(_ d: ClipDraft) {
        var input = d.input
        let t = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
        input.title = t.isEmpty ? nil : t
        let via = d.via
        if d.preview.images > 0 {
            hud.show(title: "正在剪藏…", detail: "下载 \(d.preview.images) 张图片", symbol: "arrow.down.circle", tint: .blue)
        }
        Task {
            let t0 = Date()
            let r = await processor.saveClip(input, via: via)
            AppLog.shared.say("剪藏[\(via)] 用时 \(Int(Date().timeIntervalSince(t0) * 1000))ms → \(r.message)")
            hud.show(r)
            await reload()
            switch r {
            case .clipped(let id, _), .exists(let id, _):
                if NSApp.isActive { reveal(id) }
            default: break
            }
        }
    }

    func cancelClip() { clipConfirm.cancel() }

    /// 切回拾藏时：只「探测」剪贴板里像不像链接（不读内容），像就出横幅问一句
    func checkClipboardOffer() {
        let cc = NSPasteboard.general.changeCount
        guard cc != handledChangeCount, cc != capturedChangeCount else { return }
        handledChangeCount = cc
        Task {
            let yes = await Self.clipboardLooksLikeLink()
            guard NSPasteboard.general.changeCount == cc, cc != capturedChangeCount else { return }
            clipboardOffer = yes
            if yes { AppLog.shared.say("剪贴板探测到链接 → 显示横幅") }
        }
    }

    /// 系统的「模式探测」：只告诉我们像不像链接，不读出内容，也不会触发粘贴授权提示
    nonisolated private static func clipboardLooksLikeLink() async -> Bool {
        let pb = NSPasteboard.general
        guard let found = try? await pb.detectedPatterns(for: [\.probableWebURL, \.links]) else { return false }
        return found.contains(\NSPasteboard.DetectedValues.probableWebURL) || found.contains(\NSPasteboard.DetectedValues.links)
    }

    func acceptClipboardOffer() { captureClipboard(via: "clipboard") }

    /// 阅读器代码块的「复制」。这一版剪贴板是自己写的，记下来，切回拾藏时不出「收藏」横幅；日志只记行数
    func copyCode(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        handledChangeCount = pb.changeCount
        capturedChangeCount = pb.changeCount
        clipboardOffer = false
        hud.show(title: "已复制代码", detail: "\(text.components(separatedBy: "\n").count) 行", symbol: "doc.on.doc.fill", tint: .green)
    }
    func dismissClipboardOffer() { clipboardOffer = false }

    /// 拖进窗口：网页链接、.webloc/.url/.txt 文件、选中的文字（带格式的走剪藏）
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for p in providers {
            if p.canLoadObject(ofClass: URL.self) {
                accepted = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in await AppModel.shared.captureDropped(url) }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.html.identifier) {
                accepted = true
                _ = p.loadDataRepresentation(forTypeIdentifier: UTType.html.identifier) { data, _ in
                    guard let data, let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) else { return }
                    Task { @MainActor in AppModel.shared.route(PasteboardContent(text: "", html: html), via: "drop") }
                }
            } else if p.canLoadObject(ofClass: String.self) {
                accepted = true
                _ = p.loadObject(ofClass: String.self) { s, _ in
                    guard let s else { return }
                    Task { @MainActor in AppModel.shared.route(PasteboardContent(text: s), via: "drop") }
                }
            }
        }
        return accepted
    }

    func captureDropped(_ url: URL) async {
        guard url.isFileURL else { await capture(url.absoluteString, via: "drop"); return }
        guard let data = await FileIO.read(url, timeout: 5),
              let f = Inbox.parseForeign(data, ext: url.pathExtension.lowercased()) else {
            hud.show(.rejected("这个文件里没找到链接"))
            return
        }
        await capture(f.text, via: "drop")
    }

    /// shicang://save?url=<链接> 或 shicang://save?text=<分享文字>
    func handleOpenURL(_ u: URL) {
        guard u.scheme?.lowercased() == "shicang" else { return }
        let c = URLComponents(url: u, resolvingAgainstBaseURL: false)
        let q = Dictionary((c?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let action = (u.host ?? "").lowercased()
        AppLog.shared.say("URL Scheme \(action)")
        switch action {
        case "save":
            let text = q["url"].flatMap { $0.isEmpty ? nil : $0 } ?? q["text"] ?? ""
            Task { await capture(text, via: "scheme") }
        case "debug":
            handleDebug(u, q)
        default:
            hud.show(.rejected("不认识的指令：\(action)"))
        }
    }

    // MARK: 条目操作

    func retry(_ id: String) { Task { await processor.retry(id) } }
    func removeQueued(_ id: String) { Task { await processor.removeItem(id) } }

    func trash(_ id: String) { trash(ids: [id]) }

    /// 移到废纸篓（一篇或多篇）。多篇时做完给个回执；有失败的报失败篇数和第一条原因
    func trash(ids: [String]) {
        guard !ids.isEmpty else { return }
        Task {
            var done = 0
            var firstError: String?
            for id in ids {
                do {
                    try await processor.trash(id)
                    done += 1
                    selection.remove(id)
                    sticky.remove(id)
                } catch {
                    if firstError == nil { firstError = error.localizedDescription }
                }
            }
            AppLog.shared.say(ids.count == 1 ? "移到废纸篓 \(ids[0])\(done == 1 ? "" : " 失败")" : "移到废纸篓 \(done)/\(ids.count) 篇")
            if let firstError {
                hud.show(title: ids.count == 1 ? "删除失败" : "\(ids.count - done) 篇删除失败", detail: firstError, symbol: "xmark.octagon.fill", tint: .red)
            } else if ids.count > 1 {
                hud.show(title: "已移到废纸篓", detail: "\(done) 篇，可以从废纸篓找回", symbol: "trash.fill", tint: .secondary)
            }
            await reload()
        }
    }

    /// 拷贝原文链接（多篇一行一个）。没有原文链接的剪藏跳过。这一版剪贴板是自己写的，切回拾藏时不出「收藏」横幅
    func copyLinks(_ ids: [String]) {
        let links = ids.compactMap { summary($0)?.url }.filter(Self.isWebLink)
        guard !links.isEmpty else {
            hud.show(title: "没有可拷贝的链接", detail: ids.count == 1 ? "这篇剪藏没有原文链接" : "选中的都是没有原文链接的剪藏",
                     symbol: "link.badge.plus", tint: .orange)
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(links.joined(separator: "\n"), forType: .string)
        handledChangeCount = pb.changeCount
        capturedChangeCount = pb.changeCount
        clipboardOffer = false
        let skipped = ids.count - links.count
        hud.show(title: links.count == 1 ? "已拷贝链接" : "已拷贝 \(links.count) 个链接",
                 detail: skipped > 0 ? "\(skipped) 篇剪藏没有原文链接，已跳过" : nil, symbol: "link", tint: .green)
    }

    nonisolated static func isWebLink(_ s: String) -> Bool {
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), u.host?.isEmpty == false else { return false }
        return scheme == "https" || scheme == "http"
    }

    func repairImages(_ id: String) {
        Task {
            hud.show(title: "正在补抓图片…", detail: nil, symbol: "arrow.down.circle", tint: .blue)
            guard let r = await processor.repairImagesNow(id) else { return }
            hud.show(title: r.missing == 0 ? "图片已补齐" : "补到 \(r.fixed) 张", detail: r.missing > 0 ? "还缺 \(r.missing) 张，稍后自动再试" : nil,
                     symbol: r.missing == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill", tint: r.missing == 0 ? .green : .orange)
            await reload()
        }
    }

    // MARK: 已读 / 星标 / 分类 / 标签（写 state.json，按字段合并多设备）

    private func mutate(_ id: String, _ f: @escaping @Sendable (LibraryIndex) async -> Void) {
        sticky.insert(id)
        let idx = processor.index
        Task {
            await f(idx)
            await reload()
        }
    }

    func setRead(_ id: String, _ v: Bool) { mutate(id) { await $0.setRead([id], v) } }
    func toggleStar(_ s: ArticleSummary) { let v = !s.isStarred; mutate(s.id) { await $0.setStarred(s.id, v) } }
    func toggleRead(_ s: ArticleSummary) { setRead(s.id, !s.isRead) }

    /// 选中一篇停留片刻＝读过（由阅读区的 .task 调）
    func autoMarkRead(_ id: String) {
        guard let s = summary(id), !s.isRead else { return }
        setRead(id, true)
    }

    func markAllRead(_ ids: [String]) { setRead(ids: ids, true) }

    // MARK: 批量（多选）：一次改完再刷新一次列表；改过的文章先留在当前视图里

    private func mutateMany(_ ids: [String], _ f: @escaping @Sendable (LibraryIndex, [String]) async -> Void) {
        guard !ids.isEmpty else { return }
        sticky.formUnion(ids)
        let idx = processor.index
        Task {
            await f(idx, ids)
            await reload()
        }
    }

    func setRead(ids: [String], _ v: Bool) {
        let todo = ids.filter { summary($0).map { $0.isRead != v } ?? false }
        if ids.count > 1 { AppLog.shared.say("批量标为\(v ? "已读" : "未读") \(todo.count) 篇") }
        mutateMany(todo) { await $0.setRead($1, v) }
    }

    func setStarred(ids: [String], _ v: Bool) {
        let todo = ids.filter { summary($0).map { $0.isStarred != v } ?? false }
        if ids.count > 1 { AppLog.shared.say("批量\(v ? "加星标" : "取消星标") \(todo.count) 篇") }
        mutateMany(todo) { idx, list in for id in list { await idx.setStarred(id, v) } }
    }

    /// cat = nil：恢复跟随 AI
    func setCategory(ids: [String], _ cat: String?) {
        guard ids.count > 1 else { if let id = ids.first { setCategory(id, cat) }; return }
        AppLog.shared.say("批量手动分类 \(ids.count) 篇 → \(cat.flatMap { taxonomy.name($0) } ?? "跟随 AI")")
        mutateMany(ids) { idx, list in for id in list { await idx.setCategory(id, cat) } }
    }

    func confirmCategory(ids: [String]) {
        let todo = ids.filter { summary($0)?.needsReview == true }
        if ids.count > 1 { AppLog.shared.say("批量确认分类 \(todo.count) 篇") }
        mutateMany(todo) { idx, list in for id in list { await idx.confirmCategory(id) } }
    }

    func reclassify(ids: [String]) {
        guard !ids.isEmpty else { return }
        let c = processor.classifier
        AppLog.shared.say(ids.count == 1 ? "重新分类 \(ids[0])" : "批量重新分类 \(ids.count) 篇")
        Task { await c.enqueue(ids, force: true) }
    }

    /// cat = nil：恢复跟随 AI
    func setCategory(_ id: String, _ cat: String?) {
        AppLog.shared.say("手动分类 \(id) → \(cat.flatMap { taxonomy.name($0) } ?? "跟随 AI")")
        mutate(id) { await $0.setCategory(id, cat) }
    }

    func confirmCategory(_ id: String) { mutate(id) { await $0.confirmCategory(id) } }

    func setTags(_ id: String, _ tags: [String]?) { mutate(id) { await $0.setTags(id, tags) } }

    func addTag(_ s: ArticleSummary, _ t: String) {
        let x = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !x.isEmpty, !s.tags.contains(where: { $0.caseInsensitiveCompare(x) == .orderedSame }) else { return }
        setTags(s.id, s.tags + [x])
    }

    func removeTag(_ s: ArticleSummary, _ t: String) { setTags(s.id, s.tags.filter { $0 != t }) }

    func reclassify(_ id: String) { reclassify(ids: [id]) }

    func reclassifyAll() {
        let c = processor.classifier
        Task {
            let n = await c.reclassifyAll()
            AppLog.shared.say("全部重新分类：排进 \(n) 篇")
        }
    }

    func setClassifyEnabled(_ v: Bool) {
        classifyEnabled = v
        let c = processor.classifier
        AppLog.shared.say("自动分类 \(v ? "打开" : "关闭（仅保存不分类）")")
        Task { await c.setEnabled(v) }
    }

    // MARK: 分类表 / 标签管理（写 iCloud/拾藏/Config，所有设备共用）

    func addCategory(name: String, note: String?) async throws {
        try await processor.index.addCategory(name: name, note: note)
        AppLog.shared.say("新增分类 \(name)")
        await reload()
    }

    func updateCategory(_ id: String, name: String, note: String?) async throws {
        try await processor.index.updateCategory(id, name: name, note: note)
        AppLog.shared.say("修改分类 \(id) → \(name)")
        await reload()
    }

    func moveCategory(_ id: String, by delta: Int) async throws {
        var ids = taxonomy.active.map(\.id)
        guard let i = ids.firstIndex(of: id) else { return }
        let j = i + delta
        // 「其他」固定在最后
        guard j >= 0, j < ids.count, ids[i] != Taxonomy.otherId, ids[j] != Taxonomy.otherId else { return }
        ids.swapAt(i, j)
        try await processor.index.reorderCategories(ids)
        await reload()
    }

    func deleteCategory(_ id: String, into target: String) async throws {
        try await processor.index.deleteCategory(id, mergeInto: target)
        AppLog.shared.say("删除分类 \(id)，文章并入 \(target)")
        if sidebar == .category(id) { selectSidebar(.category(target)) }
        await reload()
    }

    func renameTag(_ old: String, to new: String) async throws {
        try await processor.index.renameTag(old, to: new)
        AppLog.shared.say("标签改名 \(old) → \(new)")
        if sidebar == .tag(old) { selectSidebar(.tag(new)) }
        await reload()
    }

    func deleteTag(_ t: String) async throws {
        try await processor.index.deleteTag(t)
        AppLog.shared.say("删除标签 \(t)")
        if sidebar == .tag(t) { selectSidebar(.all) }
        await reload()
    }

    func openOriginal(_ s: ArticleSummary) {
        if let u = URL(string: s.url) { NSWorkspace.shared.open(u) }
    }

    func reveal(_ s: ArticleSummary) {
        NSWorkspace.shared.activateFileViewerSelecting([s.folder])
    }

    func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([paths.root])
    }

}
