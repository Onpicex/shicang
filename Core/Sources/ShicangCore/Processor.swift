import Foundation

public enum ProcessorEvent: Sendable {
    case queued(InboxItem)
    case started(InboxItem)
    case saved(ArticleSummary, imageFailures: Int)
    case merged(id: String, title: String)
    case failed(InboxItem)
    case changed                      // 列表/队列有变化（同步下来新文章、补到图等）
    case classified(id: String, title: String, category: String, model: String, seconds: Double, lowConfidence: Bool)
    case classifyFailed(id: String?, message: String)
    case classifyStatus(ClassifyStatus)
    case reparsed(id: String, title: String, note: String)     // 解析规则升级后用原始快照重新解析了一篇（或跳过）
}

/// 队列里一条的当前状态（给界面用）
public struct QueueEntry: Sendable, Identifiable, Hashable {
    public var item: InboxItem
    public var running: Bool
    public var claimedBy: String?     // 别的设备正在处理
    public var id: String { item.id }
}

/// 收藏处理器：收件箱 → 认领 → 抓取 → 写文件库。界面层只调 enqueue / retry / remove，并订阅事件。
public actor Processor {
    public let paths: Paths
    public let inbox: Inbox
    nonisolated public let index: LibraryIndex
    nonisolated public let classifier: Classifier
    let writer: LibraryWriter
    public var maxWorkers = 2
    public var timeoutPerItem: Double = 120

    private var running = Set<String>()
    private var ingesting = false
    private var handler: (@Sendable (ProcessorEvent) -> Void)?
    private var imagePlan: ImageRetryPlan
    private var planURL: URL { paths.local.appendingPathComponent("image-retry.json") }
    /// 暂时性失败的自动重试间隔：2 分钟、10 分钟、1 小时；之后要手动点重试
    static let backoff: [TimeInterval] = [120, 600, 3600]

    public init(paths: Paths, device: DeviceInfo, secrets: (@Sendable () -> Secrets)? = nil) {
        self.paths = paths
        inbox = Inbox(paths: paths, device: device)
        index = LibraryIndex(paths: paths, deviceId: device.id)
        classifier = Classifier(paths: paths, index: index, device: device, secrets: secrets)
        writer = LibraryWriter(paths: paths)
        imagePlan = ImageRetryPlan.load(paths.local.appendingPathComponent("image-retry.json"))
    }

    public func setHandler(_ h: @escaping @Sendable (ProcessorEvent) -> Void) async {
        handler = h
        await classifier.setHandler(h)
    }
    public func setWorkers(_ n: Int) { maxWorkers = max(1, n) }
    /// 暂停：只收不处理（测试、或用户临时不想联网时）
    public private(set) var paused = false
    public func setPaused(_ v: Bool) { paused = v; if !v { kick() } }
    private func emit(_ e: ProcessorEvent) { handler?(e) }

    /// 启动：建目录、清残留暂存、扫一遍文件库、开始处理
    public func start() async throws {
        try paths.ensure()
        let p = paths
        _ = await FileIO.run(key: "mkdir-extra", timeout: 5) { p.ensureExtraInboxes() }
        if let leftovers = try? FileManager.default.contentsOfDirectory(at: paths.staging, includingPropertiesForKeys: nil) {
            for u in leftovers { try? FileManager.default.removeItem(at: u) }
        }
        await index.refresh()
        emit(.changed)
        kick()
        await classifier.scan()
    }

    // MARK: 入队（要求 1 秒内返回：只做判平台、查重、写一个小文件）

    public func enqueue(_ text: String, via: String, device: String? = nil, capturedAt: Date = Date()) async -> EnqueueResult {
        let t: CaptureTarget
        do { t = try Capture.classify(text) } catch { return .rejected(Extractors.classify(error).message) }
        if t.source == .xhs { return .rejected("小红书暂不支持") }
        let hl = Capture.highlight(in: text)
        if let id = await index.lookup(key: t.key) {
            // 已经存过：这次带的大段文字加进「我的摘录」
            if let hl, (try? HighlightStore.append(hl, dir: paths.folder(for: id), device: device ?? inbox.device.name, at: capturedAt)) == true {
                await index.reload(id)
                emit(.changed)
                return .highlightAdded(id: id, title: await index.title(id))
            }
            return .exists(id: id, title: await index.title(id))
        }
        let id = Capture.hash(t.key)
        if var old = inbox.read(id) {
            var dirty = false
            if old.status == .failed {          // 再收藏一次失败的 = 立刻重试
                old.status = .pending; old.nextRetryAt = nil
                dirty = true
            }
            if let hl, !(old.highlight ?? "").components(separatedBy: Self.highlightSeparator).contains(where: { Clip.normalized($0) == Clip.normalized(hl) }) {
                old.highlight = [old.highlight, hl].compactMap { $0 }.joined(separator: Self.highlightSeparator)
                dirty = true
            }
            if dirty {
                try? inbox.write(old)
                emit(.changed)
                kick()
            }
            return .alreadyQueued(old)
        }
        let item = inbox.makeItem(t, shareText: text, via: via, device: device, capturedAt: capturedAt)
        do { try inbox.write(item) } catch { return .rejected("写入收件箱失败：\(error.localizedDescription)") }
        emit(.queued(item))
        kick()
        return .queued(item)
    }

    public func retry(_ id: String) {
        guard var item = inbox.read(id) else { return }
        item.status = .pending; item.nextRetryAt = nil
        try? inbox.write(item)
        emit(.changed)
        kick()
    }

    public func removeItem(_ id: String) {
        guard !running.contains(id) else { return }
        inbox.remove(id)
        emit(.changed)
    }

    public func trash(_ id: String) async throws {
        try await index.trash(id)
        imagePlan.entries[id] = nil
        imagePlan.save(planURL)
        emit(.changed)
    }

    public func queue() -> [QueueEntry] {
        inbox.items().map { QueueEntry(item: $0, running: running.contains($0.id), claimedBy: inbox.claimedByOther($0.id)?.deviceName) }
    }

    public var isIdle: Bool { running.isEmpty && !ingesting }

    // MARK: 调度

    /// 有变化就调（入队、目录变化、定时器）。外来文件先转成正式条目，再派活
    public func kick() {
        schedule()
        if !ingesting {
            ingesting = true
            Task { await self.ingestForeign() }
        }
    }

    /// 定时器调用：同步下来的新文章、到期的重试、到期的补图
    public func tick() async {
        if await index.refresh() { emit(.changed) }
        kick()
        await repairDueImages()
        await classifier.scan()
    }

    private func schedule() {
        guard !paused else { return }
        let now = Date()
        for item in inbox.items() where running.count < maxWorkers {
            guard !running.contains(item.id) else { continue }
            if item.status == .failed { guard let n = item.nextRetryAt, n <= now else { continue } }
            if inbox.claimedByOther(item.id) != nil { continue }
            running.insert(item.id)
            Task { await self.process(item.id) }
        }
    }

    private func ingestForeign() async {
        defer { ingesting = false }
        for file in await inbox.foreignFiles() {
            let ext = file.pathExtension.lowercased()
            guard let data = await FileIO.read(file) else { continue }          // 还在从 iCloud 下载：下回再说
            guard let f = Inbox.parseForeign(data, ext: ext) else {
                try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("unrecognized"))
                continue
            }
            // 手机分享的是一段文字（没有链接）：分享这个动作本身就是确认，直接剪藏
            if !Clip.looksLikeLink(f.text) {
                let t = f.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count >= 2, case .clipped = await saveClip(ClipInput(text: t), via: "shortcut", capturedAt: f.capturedAt ?? Date()) {
                    try? FileManager.default.removeItem(at: file)
                } else if t.count >= 2, await index.lookup(key: Clip.key(ClipInput(text: t))) != nil {
                    try? FileManager.default.removeItem(at: file)            // 同一段已经剪藏过
                } else {
                    try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("unrecognized"))
                }
                continue
            }
            let r = await enqueue(f.text, via: "shortcut", device: f.device, capturedAt: f.capturedAt ?? Date())
            if case .exists(let id, let title) = r { emit(.merged(id: id, title: title)) }     // 手机上收过的旧文：界面/日志要看得到
            if case .rejected = r {
                try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("unrecognized"))
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func process(_ id: String) async {
        defer { running.remove(id); schedule() }
        guard var item = inbox.read(id) else { return }
        guard inbox.claim(id) else { return }
        defer { inbox.release(id) }
        emit(.started(item))
        do {
            var t = try Capture.classify(item.url)
            if !item.capturedURL.isEmpty { t.capturedURL = item.capturedURL }   // 收件箱存的是规范化后的地址；原始链接（可能是 http://）另存着
            if let existing = await index.lookup(key: t.key) {           // 排队期间别的设备已经存了
                inbox.remove(id)
                emit(.merged(id: existing, title: await index.title(existing)))
                return
            }
            var ex = try await Extractors.run(t, timeout: timeoutPerItem)
            ex.article.capturedAt = item.capturedAt      // 收藏时间＝用户按下收藏那一刻（快捷指令可能隔很久才处理），不是抓取完成时间
            switch try await writer.save(ex) {
            case .saved(let art, let failures):
                saveHighlights(item, into: art.id)
                await index.add(art)
                if art.missingImages > 0 { imagePlan.schedule(art.id); imagePlan.save(planURL) }
                inbox.remove(id)
                if let s = await index.summary(art.id) { emit(.saved(s, imageFailures: failures.count)) }
                await classifier.enqueue([art.id])
            case .merged(let existing, let title):
                saveHighlights(item, into: existing)
                await index.reload(existing)
                inbox.remove(id)
                emit(.merged(id: existing, title: title))
            }
        } catch {
            let f = Extractors.classify(error)
            item.status = .failed
            item.attempts += 1
            item.lastError = f.message
            item.lastAttemptAt = Date()
            item.nextRetryAt = f.transient && item.attempts <= Self.backoff.count
                ? Date().addingTimeInterval(Self.backoff[item.attempts - 1]) : nil
            try? inbox.write(item)
            emit(.failed(item))
        }
    }

    /// 排队期间合进来的几段摘录用这个隔开，存的时候拆回多条
    static let highlightSeparator = "\n\u{1E}\n"

    private func saveHighlights(_ item: InboxItem, into id: String) {
        guard let h = item.highlight else { return }
        for part in h.components(separatedBy: Self.highlightSeparator) {
            _ = try? HighlightStore.append(part, dir: paths.folder(for: id), device: item.device, at: item.capturedAt)
        }
    }

    // MARK: 剪藏

    /// 剪贴板里的一段内容（用户在确认窗点了「保存」）：不经过收件箱，直接写进文件库，然后分类
    public func saveClip(_ input: ClipInput, via: String, capturedAt: Date = Date()) async -> EnqueueResult {
        let text = Clip.plainText(input)
        guard !text.isEmpty || (input.html ?? "").contains("<img") else { return .rejected("剪贴板里没有文字") }
        let key = Clip.key(input)
        if let id = await index.lookup(key: key) { return .exists(id: id, title: await index.title(id)) }
        let ex = Clip.build(input, capturedAt: capturedAt)
        do {
            switch try await writer.save(ex) {
            case .saved(let art, _):
                await index.add(art)
                if art.missingImages > 0 { imagePlan.schedule(art.id); imagePlan.save(planURL) }
                if let s = await index.summary(art.id) { emit(.saved(s, imageFailures: art.missingImages)) }
                await classifier.enqueue([art.id])
                return .clipped(id: art.id, title: art.title)
            case .merged(let existing, let title):
                return .exists(id: existing, title: title)
            }
        } catch {
            return .rejected("保存失败：\(error.localizedDescription)")
        }
    }

    // MARK: 解析规则升级

    /// 解析器版本过旧的文章用收藏时存下的原始网页在本机重新解析（不联网）。App 启动后跑一次；返回改了几篇
    @discardableResult
    public func reparseOutdated() async -> Int {
        let todo = await index.all.filter { Reparser.outdated(source: $0.source, extractor: $0.extractor) }
        var n = 0
        for s in todo {
            let dir = paths.folder(for: s.id)
            guard let r = await FileIO.run(key: "reparse-\(s.id)", timeout: 30, { Reparser.reparse(dir: dir) }) else {
                emit(.reparsed(id: s.id, title: s.title, note: "读文件超时，下次启动再试"))
                continue
            }
            switch r {
            case .updated(let a, let b):
                n += 1
                await index.reload(s.id)
                emit(.reparsed(id: s.id, title: s.title, note: "正文 \(a) → \(b) 块"))
            case .current:
                await index.reload(s.id)          // 列表缓存里还没记解析器版本：补上，下次不再查
            case .skipped(let why):
                emit(.reparsed(id: s.id, title: s.title, note: "跳过：\(why)"))
            }
        }
        if n > 0 { emit(.changed) }
        return n
    }

    // MARK: 缺图补抓

    public func repairDueImages() async {
        let due = imagePlan.due()
        guard !due.isEmpty else { return }
        for id in due {
            guard let r = await writer.repairImages(id: id) else { imagePlan.entries[id] = nil; continue }
            imagePlan.record(id, stillMissing: r.missing > 0)
            if r.fixed > 0 { await index.reload(id); emit(.changed) }
        }
        imagePlan.save(planURL)
    }

    /// 手动「补抓图片」
    public func repairImagesNow(_ id: String) async -> (fixed: Int, missing: Int)? {
        let r = await writer.repairImages(id: id)
        if let r, r.fixed > 0 { await index.reload(id); emit(.changed) }
        if let r { imagePlan.record(id, stillMissing: r.missing > 0); imagePlan.save(planURL) }
        return r
    }
}
