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
    public var waiting: Bool = false  // 别的 Mac 收藏的，这台先等它处理
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
    let registry: DeviceRegistry
    /// 别的 Mac 收藏的条目，这台等多久才接手（测试里调小）
    public private(set) var grace: TimeInterval = Turn.defaultGrace
    public func setGrace(_ v: TimeInterval) { grace = v }
    private var firstSeen: [String: Date] = [:]        // 条目 id → 这台第一次看到的时间
    private var foreignSeen: [String: Date] = [:]      // 外来文件路径 → 这台第一次看到的时间
    private var wakeAt: Date?
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
        registry = DeviceRegistry(paths: paths, device: device)
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
        registry.touch()
        await index.refresh()
        await dropSaved()
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
            if old.status == .failed {          // 再收藏一次失败的 = 立刻重试（在这台上点的，就由这台处理）
                old.status = .pending; old.nextRetryAt = nil; old.owner = inbox.device.id
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
        item.status = .pending; item.nextRetryAt = nil; item.owner = inbox.device.id     // 在这台上点的重试，就由这台处理
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
        let now = Date()
        return inbox.items().map { item in
            let due = Turn.readyAt(item, device: inbox.device, firstSeen: firstSeen[item.id] ?? now, grace: grace)
            let waiting = item.status == .pending && !Turn.isMine(item, device: inbox.device) && (due ?? now) > now
            return QueueEntry(item: item, running: running.contains(item.id), claimedBy: inbox.claimedByOther(item.id)?.deviceName, waiting: waiting)
        }
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
        registry.touch()
        if await index.refresh() { emit(.changed) }
        await dropSaved()
        kick()
        await repairDueImages()
        await classifier.scan()
    }

    private func schedule() {
        let now = Date()
        let items = inbox.items()
        var seen: [String: Date] = [:]
        for item in items { seen[item.id] = firstSeen[item.id] ?? now }
        firstSeen = seen
        guard !paused else { return }
        var nextDue: Date?
        for item in items where running.count < maxWorkers {
            guard !running.contains(item.id) else { continue }
            // 谁收藏谁处理：别的 Mac 收藏的先等一会儿，没人处理（或它失败了）才接手
            guard let due = Turn.readyAt(item, device: inbox.device, firstSeen: seen[item.id] ?? now, grace: grace) else { continue }
            if due > now { nextDue = min(nextDue ?? due, due); continue }
            if inbox.claimedByOther(item.id) != nil { continue }
            running.insert(item.id)
            Task { await self.process(item.id) }
        }
        if let nextDue { wake(at: nextDue) }
    }

    /// 到点再调度一次（等别的 Mac 的那段时间里没有别的事件会触发调度）
    private func wake(at due: Date) {
        if let w = wakeAt, w <= due, w > Date() { return }
        wakeAt = due
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, due.timeIntervalSinceNow + 0.05) * 1_000_000_000))
            self.woke(due)
        }
    }

    private func woke(_ due: Date) {
        if wakeAt == due { wakeAt = nil }
        kick()
    }

    /// 收件箱里的条目如果文章已经在库里（别的 Mac 存好了），直接清掉：
    /// 两台同时处理时，一台存好并删了条目，另一台随后写回的「失败」记录会一直留着
    private func dropSaved() async {
        var dropped = false
        for item in inbox.items() where !running.contains(item.id) {
            guard let id = await index.lookup(key: item.key) else { continue }
            saveHighlights(item, into: id)
            inbox.remove(item.id)
            dropped = true
            emit(.merged(id: id, title: await index.title(id)))
        }
        if dropped { emit(.changed) }
    }

    private func ingestForeign() async {
        defer { ingesting = false }
        let files = await inbox.foreignFiles()
        // 手机发来的由固定一台 Mac 先处理，别的 Mac 等一会儿、文件还在才接手
        let primary = registry.isPrimary()
        let now = Date()
        var seen: [String: Date] = [:]
        for f in files { seen[f.path] = foreignSeen[f.path] ?? now }
        foreignSeen = seen
        for file in files {
            if !primary, let s = seen[file.path], now.timeIntervalSince(s) < grace {
                wake(at: s.addingTimeInterval(grace))
                continue
            }
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
            // 这台没抓到，但别的 Mac 可能已经存好了：那就不记失败
            _ = await index.refresh()
            if let existing = await index.lookup(key: item.key) {
                inbox.remove(id)
                emit(.merged(id: existing, title: await index.title(existing)))
                return
            }
            let f = Extractors.classify(error)
            item.triedBy = Array(Set((item.triedBy ?? []) + [inbox.device.id])).sorted()
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
