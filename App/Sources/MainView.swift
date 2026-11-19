import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ShicangCore

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            VStack(spacing: 0) {
                if model.clipboardOffer { ClipboardBanner() }
                if let err = model.startError {
                    Label(err, systemImage: "xmark.octagon.fill").foregroundStyle(.red).padding(10)
                }
                switch model.sidebar ?? .all {
                case .processing: QueueListView(entries: model.processing, emptyText: "没有正在处理的收藏")
                case .failed: QueueListView(entries: model.failed, emptyText: "没有失败的收藏")
                default: ArticleListView()
                }
            }
            .frame(minWidth: 340)
            .navigationSplitViewColumnWidth(min: 340, ideal: 420, max: 620)
        } detail: {
            if model.selection.count > 1 {
                MultiSelectionPane(ids: model.selectedIds)
            } else if let s = model.summary(model.selectedArticle) {
                ReaderPane(summary: s)
            } else {
                ContentUnavailableView("选一篇来读", systemImage: "doc.richtext",
                                       description: Text("复制链接或一段文字后按 ⌥⌘S 收藏；也可以拖进窗口"))
            }
        }
        .navigationTitle("拾藏")
        .searchable(text: $model.search, placement: .toolbar, prompt: "搜索标题、正文、摘要、标签")
        .task(id: model.search) {
            // 输入停顿 150ms 再搜；新输入会取消这次（防抖）
            if !model.search.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            await model.runSearch()
        }
        .onDrop(of: [.url, .fileURL, .html, .plainText], isTargeted: $dropTargeted) { providers in
            model.handleDrop(providers)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.06))
                    .overlay(Label("松手收藏", systemImage: "tray.and.arrow.down").font(.title2.weight(.semibold)))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            model.openSettingsAction = { openSettings() }
            model.checkClipboardOffer()
        }
    }
}

// MARK: 侧栏

private struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var tagsExpanded = true
    @State private var showAllTags = false
    private let tagLimit = 20

    var body: some View {
        List(selection: Binding(get: { model.sidebar }, set: { model.selectSidebar($0) })) {
            Section("收藏") {
                row("全部", "books.vertical", .all, model.articles.count)
                row("未读", "circle.inset.filled", .unread, model.count(.unread))
                row("星标", "star", .starred, model.count(.starred))
                let review = model.count(.review)
                if review > 0 || model.sidebar == .review { row("待确认", "questionmark.circle", .review, review) }
                row("处理中", "arrow.triangle.2.circlepath", .processing, model.processing.count)
                row("失败", "exclamationmark.triangle", .failed, model.failed.count)
            }
            Section("分类") {
                ForEach(model.taxonomy.active) { c in
                    row(c.name, categoryIcon(c.id), .category(c.id), model.count(.category(c.id)))
                        .contextMenu { Button("管理分类…") { model.openSettings(.taxonomy) } }
                }
                let unc = model.count(.uncategorized)
                if unc > 0 || model.sidebar == .uncategorized { row("未分类", "tray", .uncategorized, unc) }
            }
            if !model.sourcesPresent.isEmpty {
                Section("来源") {
                    ForEach(model.sourcesPresent, id: \.0) { s, n in
                        row(sourceName(s), sourceIcon(s), .source(s), n)
                    }
                }
            }
            if !model.tagCounts.isEmpty {
                Section("标签", isExpanded: $tagsExpanded) {
                    ForEach(model.tagCounts.prefix(showAllTags ? 1000 : tagLimit), id: \.tag) { t in
                        row(t.tag, "number", .tag(t.tag), t.count)
                            .contextMenu { Button("管理标签…") { model.openSettings(.taxonomy) } }
                    }
                    if model.tagCounts.count > tagLimit {
                        Button(showAllTags ? "收起" : "全部 \(model.tagCounts.count) 个标签…") { showAllTags.toggle() }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
    }

    private func row(_ title: String, _ icon: String, _ item: SidebarItem, _ n: Int) -> some View {
        Label(title, systemImage: icon).lineLimit(1).badge(n).tag(item)
    }
}

func categoryIcon(_ id: String) -> String {
    ["ai": "sparkles", "dev": "chevron.left.forwardslash.chevron.right", "tools": "wrench.and.screwdriver",
     "crypto": "bitcoinsign.circle", "invest": "chart.line.uptrend.xyaxis", "tech": "desktopcomputer",
     "biz": "briefcase", "growth": "brain.head.profile", "life": "leaf", "other": "ellipsis.circle"][id] ?? "folder"
}

func sourceIcon(_ s: Source) -> String {
    switch s { case .x: return "at"; case .wechat: return "message"; case .xhs: return "book"; case .web: return "globe"; case .clip: return "doc.on.clipboard" }
}

private struct ClipboardBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard").foregroundStyle(Color.accentColor)
            Text("剪贴板里有一个链接，要收藏吗？").font(.callout)
            Spacer()
            Button("收藏") { model.acceptClipboardOffer() }
                .buttonStyle(.borderedProminent).controlSize(.small)
            Button("忽略") { model.dismissClipboardOffer() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.10))
        .accessibilityIdentifier("clipboardBanner")
    }
}

// MARK: 文章列表

/// 中栏列表行身份的「代」。
/// macOS 的 List（底层是 NSOutlineView）往非空列表里插入没显示过的行时，新行停在默认高度 24pt，
/// 只露出一行标题，切到别的页面再切回来才会重新量。显示的列表里一出现新文章，代号加一，
/// 所有行一起换身份（id 带代号），列表按整表换新处理，每一行都重新量高度。
/// 选中值用 .tag 固定为文章 id，不受代号影响。只是从列表里移除的变化不加代号。
@MainActor private final class RowGeneration {
    private var shown: Set<String> = []
    private(set) var value = 0

    func update(_ ids: [String]) -> Int {
        let now = Set(ids)
        if !shown.isEmpty, !now.isSubset(of: shown) { value &+= 1 }
        shown = now
        return value
    }
}

/// 代码改选中值（全选、取消选择、删除后、换视图后只留看得见的）时，macOS 的 List 只更新已经画出来的行：
/// 屏幕外还没画的行，该取消的不取消、该选的不选，表格上的高亮和真正的选中就对不上了，之后 ⇧ 点按还会把这些行带回来。
/// 所以每次选中值或列表变了，等 SwiftUI 把看得见的行改完，再把表格的选中行直接对齐成选中值。
/// 必须等它改完：赶在它前面改表格，它自己记的选中状态就乱了，下一次在表格里点选会被它算成什么都没选。
/// 鼠标、键盘、⌘A 这些由表格自己发起的变化，两边本来就一致，这里不做任何事。
@MainActor enum ListSelectionSync {
    private static var pending = false
    private static var retries = 0
    private static var waits = 0

    /// 选中值一变（AppModel.selection 的 didSet）或列表内容一变（中栏 onChange）就排一次
    static func schedule() {
        guard !pending else { return }
        pending = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            pending = false
            align()
        }
    }

    private static func align() {
        let model = AppModel.shared
        guard let t = articleTable() else { return }
        let ids = model.filteredArticles.map(\.id)
        guard t.numberOfRows == ids.count else {          // 表格还没跟上这次的列表：再等几轮，列表真变了中栏还会再排
            retries += 1
            if retries <= 20 { schedule() } else { retries = 0 }
            return
        }
        retries = 0
        let want = IndexSet(ids.indices.filter { model.selection.contains(ids[$0]) })
        let have = t.selectedRowIndexes
        guard have != want else { waits = 0; return }
        // 看得见的行 SwiftUI 自己会改（通常 25ms 内）；还没改完就再等一轮，最多等 10 轮（窗口被挡住时它可能一直不改）
        if let vis = Range(t.rows(in: t.visibleRect)) {
            let shown = IndexSet(integersIn: vis)
            if have.intersection(shown) != want.intersection(shown), waits < 10 { waits += 1; schedule(); return }
        }
        waits = 0
        t.selectRowIndexes(want, byExtendingSelection: false)
    }

    /// 中栏文章列表＝主窗口（Window id "main"）里唯一允许多选的 NSOutlineView（侧栏、「已选 N 篇」里的标题列表都不能多选）
    static func articleTable() -> NSOutlineView? {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue == "main" }),
              let root = w.contentView?.superview ?? w.contentView else { return nil }
        return find(root)
    }

    private static func find(_ v: NSView) -> NSOutlineView? {
        if let o = v as? NSOutlineView, o.allowsMultipleSelection { return o }
        for s in v.subviews { if let o = find(s) { return o } }
        return nil
    }
}

private struct ArticleListView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingTrash: [String] = []
    @State private var rowGen = RowGeneration()

    var body: some View {
        @Bindable var model = model
        let list = model.filteredArticles
        let terms = model.searchHits == nil ? [] : model.searchTerms
        let gen = rowGen.update(list.map(\.id))
        VStack(spacing: 0) {
            ListHeader(count: list.count, ids: list.map(\.id))
            Divider()
            // 多选：⌘ 点按增减、⇧ 点按连选、⌘A 全选（列表有焦点时）
            List(list, selection: $model.selection) { s in
                ArticleRow(summary: s, categoryName: model.categoryName(s.categoryId),
                           snippet: terms.isEmpty ? nil : model.snippet(s.id), terms: terms)
                    .id("\(s.id)#\(gen)")
                    .tag(s.id)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                // 右键点在选中的行上＝对右栏「已选 N 篇」那一批操作（以选中值为准，不信表格高亮）；点在没选中的行上＝只对那一篇
                let picked = model.ordered(ids.isDisjoint(with: model.selection) ? ids : model.selection)
                if picked.count == 1, let s = model.summary(picked[0]) {
                    menu(s)
                } else if picked.count > 1 {
                    BatchActions(ids: picked, style: .menu) { pendingTrash = picked }
                }
            }
            .onDeleteCommand { pendingTrash = model.selectedIds }
            .onChange(of: list.map(\.id)) { ListSelectionSync.schedule() }
            .overlay {
                if model.articles.isEmpty {
                    ContentUnavailableView("还没有收藏", systemImage: "tray",
                                           description: Text("复制链接或一段文字，按 ⌥⌘S\n也可以拖进窗口"))
                } else if list.isEmpty {
                    if model.searchHits != nil { ContentUnavailableView.search(text: model.search) }
                    else { ContentUnavailableView(emptyText, systemImage: "checkmark.circle") }
                }
            }
        }
        .trashConfirmation($pendingTrash)
    }

    private var emptyText: String {
        switch model.sidebar ?? .all {
        case .unread: return "都读完了"
        case .starred: return "还没有星标的文章"
        case .review: return "没有待确认的分类"
        default: return "这里还没有文章"
        }
    }

    @ViewBuilder private func menu(_ s: ArticleSummary) -> some View {
        Button(s.isRead ? "标为未读" : "标为已读") { model.toggleRead(s) }
        Button(s.isStarred ? "取消星标" : "加星标") { model.toggleStar(s) }
        Menu("分类") {
            ForEach(model.taxonomy.active) { c in
                Button { model.setCategory(s.id, c.id) } label: {
                    if c.id == s.categoryId { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                }
            }
            if s.state.userCategory != nil, s.ai != nil {
                Divider()
                Button("恢复跟随 AI") { model.setCategory(s.id, nil) }
            }
        }
        if s.needsReview { Button("确认分类") { model.confirmCategory(s.id) } }
        Button("重新分类") { model.reclassify(s.id) }.disabled(!model.aiReady || !model.classifyEnabled)
        Divider()
        Button("打开原文") { model.openOriginal(s) }
        Button("在访达中显示") { model.reveal(s) }
        Button("拷贝链接") { model.copyLinks([s.id]) }.disabled(!AppModel.isWebLink(s.url))
        if s.missingImages > 0 { Button("补抓图片（缺 \(s.missingImages) 张）") { model.repairImages(s.id) } }
        Divider()
        Button("移到废纸篓…", role: .destructive) { pendingTrash = [s.id] }
    }
}

extension View {
    /// 「移到废纸篓？」确认（一篇写标题，多篇写篇数）。ids 为空＝不弹
    func trashConfirmation(_ ids: Binding<[String]>) -> some View { modifier(TrashConfirmation(ids: ids)) }
}

private struct TrashConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var ids: [String]

    func body(content: Content) -> some View {
        let n = ids.count
        content.confirmationDialog(n == 1 ? "把「\(model.summary(ids[0])?.title ?? "")」移到废纸篓？" : "把选中的 \(n) 篇移到废纸篓？",
                                   isPresented: Binding(get: { !ids.isEmpty }, set: { if !$0 { ids = [] } })) {
            Button(n == 1 ? "移到废纸篓" : "移到废纸篓（\(n) 篇）", role: .destructive) {
                model.trash(ids: ids)
                ids = []
            }
        } message: {
            Text(n == 1 ? "iCloud 里的这篇也会删除（所有设备）。可以从废纸篓找回。" : "iCloud 里的这 \(n) 篇也会删除（所有设备）。可以从废纸篓找回。")
        }
    }
}

/// 多选时的批量操作：右键菜单（.menu）和右栏「已选 N 篇」面板（.panel）共用一份。
/// 已读/星标按 Mail 的习惯：选中的里只要有一篇未读就是「标为已读」，全读过了才是「标为未读」
private struct BatchActions: View {
    enum Style { case menu, panel }
    @Environment(AppModel.self) private var model
    let ids: [String]
    let style: Style
    let askTrash: () -> Void

    var body: some View {
        let items = ids.compactMap { model.summary($0) }
        let anyUnread = items.contains { !$0.isRead }
        let anyUnstarred = items.contains { !$0.isStarred }
        let review = items.filter(\.needsReview).count
        let links = items.filter { AppModel.isWebLink($0.url) }.count
        let cats = Set(items.map(\.categoryId))
        let aiOff = !model.aiReady || !model.classifyEnabled
        let readBtn = Button { model.setRead(ids: ids, anyUnread) } label: {
            Label(anyUnread ? "标为已读" : "标为未读", systemImage: anyUnread ? "circle" : "circle.inset.filled")
        }
        let starBtn = Button { model.setStarred(ids: ids, anyUnstarred) } label: {
            Label(anyUnstarred ? "加星标" : "取消星标", systemImage: anyUnstarred ? "star" : "star.slash")
        }
        let catMenu = Menu {
            ForEach(model.taxonomy.active) { c in
                Button { model.setCategory(ids: ids, c.id) } label: {
                    if cats == [c.id] { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                }
            }
            if items.contains(where: { $0.state.userCategory != nil && $0.ai != nil }) {
                Divider()
                Button("恢复跟随 AI") { model.setCategory(ids: ids, nil) }
            }
        } label: {
            Label(cats.count == 1 ? "分类：\(cats.first!.flatMap { model.categoryName($0) } ?? "未分类")" : "分类（\(cats.count) 种）",
                  systemImage: "folder")
        }
        let confirmBtn = Button { model.confirmCategory(ids: ids) } label: {
            Label("确认分类（\(review) 篇）", systemImage: "checkmark.circle")
        }
        let reclassifyBtn = Button { model.reclassify(ids: ids) } label: { Label("重新分类", systemImage: "sparkles") }
            .disabled(aiOff)
            .help(aiOff ? "AI 分类没开或没设置好" : "交给 AI 重新分类这 \(ids.count) 篇")
        let copyBtn = Button { model.copyLinks(ids) } label: {
            Label(links == items.count ? "拷贝 \(links) 个链接" : "拷贝 \(links) 个链接（\(items.count - links) 篇剪藏没有）", systemImage: "link")
        }
        .disabled(links == 0)
        let trashBtn = Button(role: .destructive, action: askTrash) { Label("移到废纸篓…", systemImage: "trash") }

        switch style {
        case .menu:
            Text("已选 \(items.count) 篇")
            readBtn
            starBtn
            catMenu
            if review > 0 { confirmBtn }
            reclassifyBtn
            Divider()
            copyBtn
            Divider()
            trashBtn
        case .panel:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) { readBtn; starBtn }
                HStack(spacing: 8) {
                    catMenu.menuStyle(.button).fixedSize()
                    if review > 0 { confirmBtn }
                    reclassifyBtn
                }
                HStack(spacing: 8) { copyBtn; trashBtn }
            }
            .controlSize(.large)
        }
    }
}

/// 中栏顶部：当前视图名 + 篇数 + AI 分类状态 + 「全部标为已读」
private struct ListHeader: View {
    @Environment(AppModel.self) private var model
    let count: Int
    let ids: [String]

    var body: some View {
        HStack(spacing: 8) {
            Text(model.searchHits != nil ? "搜索「\(model.search.trimmingCharacters(in: .whitespaces))」" : model.title(model.sidebar ?? .all))
                .font(.headline).lineLimit(1)
            Text("\(count) 篇").font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            ClassifyBadge()
            Menu {
                Button("全选（⌘A）") { model.selectAll() }.disabled(count == 0)
                Button("取消选择") { model.selection = [] }.disabled(model.selection.isEmpty)
                Divider()
                Button("全部标为已读") { model.markAllRead(ids) }.disabled(count == 0)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("更多")
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }
}

/// AI 分类进度 / 问题（点了去设置）
private struct ClassifyBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let st = model.classifyStatus
        switch st.phase {
        case .running:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(st.pending > 1 ? "AI 分类中 · 还剩 \(st.pending)" : "AI 分类中").font(.caption).foregroundStyle(.secondary)
            }
            .help(st.current.map { "正在分类：\($0)" } ?? "")
        case .waiting:
            Button { model.openSettings(.ai) } label: {
                Label("分类暂停\(st.retryAt.map { "，\(timeString($0)) 再试" } ?? "")", systemImage: "clock.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
            }
            .buttonStyle(.plain).help(st.message ?? "")
        case .badKey:
            Button { model.openSettings(.ai) } label: {
                Label("AI 设置有误", systemImage: "key.slash").font(.caption).foregroundStyle(.red)
            }
            .buttonStyle(.plain).help(st.message ?? "去设置里检查平台、模型和密钥")
        case .noKey:
            if model.count(.uncategorized) > 0 {
                Button { model.openSettings(.ai) } label: {
                    Label("设置 AI 后自动分类", systemImage: "key").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help(st.message ?? "")
            }
        case .disabled, .idle:
            EmptyView()
        }
    }
}

private struct ArticleRow: View {
    let summary: ArticleSummary
    let categoryName: String?
    let snippet: String?
    let terms: [String]
    @Environment(\.backgroundProminence) private var prominence      // 选中行（蓝底）上彩色字看不清，换成白

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(summary.isRead ? Color.clear : Color.accentColor)
                .frame(width: 7, height: 7)
                .padding(.top, 6)
                .accessibilityLabel(summary.isRead ? "" : "未读")
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(highlight(summary.title, terms)).font(.headline).lineLimit(2)
                    if summary.isStarred {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                }
                metaLine.font(.caption).lineLimit(1)
                if let snippet {
                    Text(highlight(snippet, terms)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                } else if !summary.cardSummary.isEmpty {
                    Text(summary.cardSummary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                if summary.missingImages > 0 {
                    Label("缺 \(summary.missingImages) 张图", systemImage: "photo.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            if let f = summary.coverFile {
                Thumbnail(file: summary.folder.appendingPathComponent(f))
            }
        }
        .padding(.vertical, 4)
    }

    private var metaLine: Text {
        var parts = [sourceName(summary.source)]
        if let a = summary.author, !a.isEmpty { parts.append(a) }
        let sep = Text(" · ").foregroundStyle(.secondary)
        var t = Text(parts.joined(separator: " · ")).foregroundStyle(.secondary)
        if let c = categoryName {
            t = Text("\(t)\(sep)\(prominence == .increased ? Text(c).foregroundStyle(.primary) : Text(c).foregroundStyle(.tint))")
            if summary.needsReview { t = Text("\(t)\(Text(" 待确认").foregroundStyle(.orange))") }
        }
        t = Text("\(t)\(sep)\(Text(shortDate(summary.publishedAt ?? summary.capturedAt)).foregroundStyle(.secondary))")
        if summary.videos > 0 { t = Text("\(t)\(sep)\(Text("视频 \(summary.videos)").foregroundStyle(.secondary))") }
        return t
    }
}

/// 把搜索词标出来（不分大小写、全半角）
func highlight(_ s: String, _ terms: [String]) -> AttributedString {
    var a = AttributedString(s)
    for t in terms where !t.isEmpty {
        var from = a.startIndex
        while from < a.endIndex, let r = a[from...].range(of: t, options: [.caseInsensitive, .widthInsensitive]) {
            a[r].backgroundColor = Color.yellow.opacity(0.35)
            from = r.upperBound
        }
    }
    return a
}

/// 列表缩略图：后台按 120px 降采样，缓存在内存
private struct Thumbnail: View {
    let file: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: file) { image = await ThumbCache.shared.image(file) }
    }
}

@MainActor
final class ThumbCache {
    static let shared = ThumbCache()
    private var cache: [URL: NSImage] = [:]

    func image(_ url: URL) async -> NSImage? {
        if let i = cache[url] { return i }
        let cg = await Task.detached { () -> CGImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceThumbnailMaxPixelSize: 120,
                                         kCGImageSourceCreateThumbnailWithTransform: true]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }.value
        guard let cg else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        if cache.count > 400 { cache.removeAll() }
        cache[url] = img
        return img
    }
}

// MARK: 队列（处理中 / 失败）

private struct QueueListView: View {
    @Environment(AppModel.self) private var model
    let entries: [QueueEntry]
    let emptyText: String

    var body: some View {
        List(entries) { e in
            QueueRow(entry: e)
        }
        .overlay {
            if entries.isEmpty { ContentUnavailableView(emptyText, systemImage: "checkmark.circle") }
        }
    }
}

private struct QueueRow: View {
    @Environment(AppModel.self) private var model
    let entry: QueueEntry

    var body: some View {
        let i = entry.item
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if entry.running { ProgressView().controlSize(.small) }
                Text(i.displayTitle).font(.headline).lineLimit(1)
                Spacer()
                Text(status).font(.caption).foregroundStyle(statusColor)
            }
            Text(i.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if let err = i.lastError, !entry.running {
                Text(err).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("\(shortDate(i.capturedAt)) · \(i.device) · \(viaName(i.via))\(i.attempts > 0 ? " · 已试 \(i.attempts) 次" : "")")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if !entry.running {
                    if i.status == .failed { Button("重试") { model.retry(i.id) }.controlSize(.small) }
                    Button("移除") { model.removeQueued(i.id) }.controlSize(.small)
                    Button("打开原文") { if let u = URL(string: i.url) { NSWorkspace.shared.open(u) } }.controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var status: String {
        let i = entry.item
        if entry.running { return "抓取中…" }
        if let who = entry.claimedBy { return "\(who) 正在处理" }
        if i.status == .pending { return "排队中" }
        if let n = i.nextRetryAt { return "\(timeString(n)) 自动重试" }
        return "需要手动重试"
    }

    private var statusColor: Color {
        if entry.running || entry.item.status == .pending { return .blue }
        return entry.item.nextRetryAt != nil ? .orange : .red
    }
}

// MARK: 阅读区

/// 选了多篇时的右栏：篇数、概况、批量操作按钮、选中的标题列表
private struct MultiSelectionPane: View {
    @Environment(AppModel.self) private var model
    let ids: [String]
    @State private var pendingTrash: [String] = []

    var body: some View {
        let items = ids.compactMap { model.summary($0) }
        let unread = items.filter { !$0.isRead }.count
        let starred = items.filter(\.isStarred).count
        let review = items.filter(\.needsReview).count
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "checklist").font(.title).foregroundStyle(.tint)
                Text("已选 \(items.count) 篇").font(.largeTitle.weight(.semibold))
                Spacer()
                Button("取消选择") { model.selection = [] }.buttonStyle(.link)
            }
            Text(([unread > 0 ? "未读 \(unread)" : "都读过了", starred > 0 ? "星标 \(starred)" : nil, review > 0 ? "待确认 \(review)" : nil] as [String?])
                    .compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.secondary)
            BatchActions(ids: ids, style: .panel) { pendingTrash = ids }
            Divider()
            List(items) { s in
                HStack(spacing: 8) {
                    Circle().fill(s.isRead ? Color.clear : Color.accentColor).frame(width: 6, height: 6)
                    Text(s.title).lineLimit(1)
                    if s.isStarred { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                    Spacer(minLength: 8)
                    Text(model.categoryName(s.categoryId) ?? "未分类").font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            Text("⌘ 点按：加选或去掉一篇　⇧ 点按：连续选　⌘A：全选　Delete：移到废纸篓")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                let anyUnstarred = items.contains { !$0.isStarred }
                let anyUnread = unread > 0
                Button { model.setStarred(ids: ids, anyUnstarred) } label: {
                    Label(anyUnstarred ? "星标" : "取消星标", systemImage: anyUnstarred ? "star" : "star.fill")
                }
                .help(anyUnstarred ? "选中的都加星标（⇧⌘L）" : "选中的都取消星标（⇧⌘L）")
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Button { model.setRead(ids: ids, anyUnread) } label: {
                    Label(anyUnread ? "标为已读" : "标为未读", systemImage: anyUnread ? "circle" : "circle.inset.filled")
                }
                .help(anyUnread ? "选中的都标为已读（⇧⌘U）" : "选中的都标为未读（⇧⌘U）")
                .keyboardShortcut("u", modifiers: [.command, .shift])
                Button(role: .destructive) { pendingTrash = ids } label: { Label("删除", systemImage: "trash") }
                    .help("选中的 \(items.count) 篇移到废纸篓")
            }
        }
        .trashConfirmation($pendingTrash)
    }
}

private struct ReaderPane: View {
    @Environment(AppModel.self) private var model
    let summary: ArticleSummary
    @State private var confirmTrash = false

    var body: some View {
        VStack(spacing: 0) {
            ArticleInfoBar(summary: summary)
            Divider()
            ReaderView(summary: summary, paths: model.paths)
                .id(summary.id)
        }
        .task(id: summary.id) {
            // 停留 1.5 秒算读过（快速翻过去的不算）
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { model.autoMarkRead(summary.id) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.toggleStar(summary) } label: {
                    Label(summary.isStarred ? "取消星标" : "星标", systemImage: summary.isStarred ? "star.fill" : "star")
                }
                .help(summary.isStarred ? "取消星标（⇧⌘L）" : "加星标（⇧⌘L）")
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Button { model.toggleRead(summary) } label: {
                    Label(summary.isRead ? "标为未读" : "标为已读", systemImage: summary.isRead ? "circle" : "circle.inset.filled")
                }
                .help(summary.isRead ? "标为未读（⇧⌘U）" : "标为已读（⇧⌘U）")
                .keyboardShortcut("u", modifiers: [.command, .shift])
                Button { model.openOriginal(summary) } label: { Label("原文", systemImage: "safari") }
                    .help("在浏览器里打开原文")
                Button { model.reveal(summary) } label: { Label("在访达中显示", systemImage: "folder") }
                    .help("在访达中显示文章文件夹（含 article.md 和图片）")
                if summary.missingImages > 0 {
                    Button { model.repairImages(summary.id) } label: { Label("补抓图片", systemImage: "photo.badge.arrow.down") }
                        .help("缺 \(summary.missingImages) 张图，现在重试")
                }
                Button(role: .destructive) { confirmTrash = true } label: { Label("删除", systemImage: "trash") }
                    .help("移到废纸篓")
            }
        }
        .trashConfirmation(Binding(get: { confirmTrash ? [summary.id] : [] }, set: { confirmTrash = !$0.isEmpty }))
    }
}

/// 阅读区顶部：分类（可改）+ 待确认 + 标签（可增删）+ AI 信息
private struct ArticleInfoBar: View {
    @Environment(AppModel.self) private var model
    let summary: ArticleSummary
    @State private var addingTag = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            FlowLayout(spacing: 6) {
                categoryMenu
                if summary.needsReview {
                    Button { model.confirmCategory(summary.id) } label: {
                        Label("确认", systemImage: "checkmark.circle")
                    }
                    .controlSize(.small)
                    .help(String(format: "AI 不太确定（置信 %.2f）。分类对就点确认；不对就在左边改", summary.ai?.confidence ?? 0))
                }
                ForEach(summary.tags, id: \.self) { t in TagChip(tag: t, summary: summary) }
                Button { addingTag = true } label: { Label("标签", systemImage: "plus") }
                    .controlSize(.small).buttonStyle(.borderless)
                    .popover(isPresented: $addingTag, arrowEdge: .bottom) { AddTagPopover(summary: summary) }
            }
            Spacer(minLength: 0)
            aiInfo
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private var categoryMenu: some View {
        Menu {
            ForEach(model.taxonomy.active) { c in
                Button { model.setCategory(summary.id, c.id) } label: {
                    if c.id == summary.categoryId { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                }
            }
            Divider()
            if summary.state.userCategory != nil, let ai = summary.ai {
                Button("恢复跟随 AI（\(model.categoryName(ai.categoryId) ?? ai.categoryName)）") { model.setCategory(summary.id, nil) }
            }
            Button(summary.ai == nil ? "现在分类" : "重新分类") { model.reclassify(summary.id) }
                .disabled(!model.aiReady || !model.classifyEnabled)
            Button("管理分类…") { model.openSettings(.taxonomy) }
        } label: {
            Label(model.categoryName(summary.categoryId) ?? "未分类", systemImage: summary.categoryId.map(categoryIcon) ?? "tray")
        }
        .menuStyle(.button).controlSize(.small).fixedSize()
        .help(summary.state.userCategory != nil ? "手动指定的分类" : (summary.ai != nil ? "AI 给的分类" : "还没分类"))
    }

    @ViewBuilder private var aiInfo: some View {
        if let ai = summary.ai {
            Text(shortModel(ai.model))
                .font(.caption).foregroundStyle(.tertiary)
                .help(String(format: "%@ · 置信 %.2f · %@", ai.model, ai.confidence, shortDate(ai.at)))
                .padding(.top, 3)
        } else if model.classifyStatus.current == summary.title, model.classifyStatus.phase == .running {
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("分类中").font(.caption).foregroundStyle(.secondary) }
                .padding(.top, 3)
        }
    }

    private func shortModel(_ m: String) -> String {
        // claude-opus-5-5 → Opus 5.5；别家模型：去掉「厂商/」前缀，太长截断（全名在悬停提示里）
        if m.hasPrefix("claude-") {
            let parts = m.dropFirst(7).split(separator: "-").map(String.init)
            if let name = parts.first {
                let ver = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
                return name.capitalized + (ver.isEmpty ? "" : " " + ver)
            }
        }
        let tail = m.split(separator: "/").last.map(String.init) ?? m
        return tail.count > 24 ? String(tail.prefix(23)) + "…" : tail
    }
}

private struct TagChip: View {
    @Environment(AppModel.self) private var model
    let tag: String
    let summary: ArticleSummary
    @State private var hover = false

    var body: some View {
        HStack(spacing: 3) {
            Button("#\(tag)") { model.selectSidebar(.tag(tag)) }
                .buttonStyle(.plain)
                .help("看所有带 #\(tag) 的文章")
            if hover {
                Button { model.removeTag(summary, tag) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("去掉这个标签")
            }
        }
        .font(.caption)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(.quaternary))
        .onHover { hover = $0 }
    }
}

private struct AddTagPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let summary: ArticleSummary
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("新标签", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { add(text) }
            let sugg = suggestions
            if !sugg.isEmpty {
                Text(text.isEmpty ? "常用标签" : "已有标签").font(.caption).foregroundStyle(.secondary)
                FlowLayout(spacing: 5) {
                    ForEach(sugg, id: \.self) { t in
                        Button("#\(t)") { add(t) }
                            .buttonStyle(.plain).font(.caption)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(.quaternary))
                    }
                }
            }
            if summary.state.userTags != nil, summary.ai != nil {
                Divider()
                Button("恢复 AI 给的标签") { model.setTags(summary.id, nil); dismiss() }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private var suggestions: [String] {
        let have = Set(summary.tags.map { $0.lowercased() })
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        return model.tagCounts.map(\.tag)
            .filter { !have.contains($0.lowercased()) && (q.isEmpty || $0.lowercased().contains(q)) }
            .prefix(12).map { $0 }
    }

    private func add(_ t: String) {
        let x = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !x.isEmpty else { return }
        model.addTag(summary, x)
        text = ""
        dismiss()
    }
}

/// 自动换行的横排布局（标签用）
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let h = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let w = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width.map { min($0, w) } ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.items {
                let sz = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - sz.height) / 2), proposal: ProposedViewSize(sz))
                x += sz.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var cur = Row()
        for i in subviews.indices {
            let sz = subviews[i].sizeThatFits(.unspecified)
            let add = cur.items.isEmpty ? sz.width : cur.width + spacing + sz.width
            if add > width, !cur.items.isEmpty {
                rows.append(cur)
                cur = Row()
            }
            cur.width = cur.items.isEmpty ? sz.width : cur.width + spacing + sz.width
            cur.height = max(cur.height, sz.height)
            cur.items.append(i)
        }
        if !cur.items.isEmpty { rows.append(cur) }
        return rows
    }
}

// MARK: 小工具

func sourceName(_ s: Source) -> String {
    switch s { case .x: return "X"; case .wechat: return "公众号"; case .xhs: return "小红书"; case .web: return "网页"; case .clip: return "剪藏" }
}

func viaName(_ v: String) -> String {
    ["hotkey": "快捷键", "clipboard": "剪贴板横幅", "drop": "拖拽", "scheme": "URL Scheme", "shortcut": "快捷指令",
     "menu": "菜单", "cli": "命令行", "debug": "测试"][v] ?? v
}

func shortDate(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? "M月d日 HH:mm" : "yyyy年M月d日"
    return f.string(from: d)
}

func timeString(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "M/d HH:mm"
    return f.string(from: d)
}
