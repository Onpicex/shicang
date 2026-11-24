import Foundation
import Testing
@testable import ShicangCore

/// 多台 Mac 共用一个文件库：谁收藏谁处理，别的 Mac 等一会儿才接手（全是假数据，不联网）
@Suite struct DeviceTurnTests {
    let me = DeviceInfo(id: "bbbb", name: "书房 Mac")
    let other = DeviceInfo(id: "aaaa", name: "客厅 Mac")

    func item(_ p: Paths, by d: DeviceInfo, url: String = "https://example.com/post/1", via: String = "hotkey") throws -> InboxItem {
        Inbox(paths: p, device: d).makeItem(try Capture.classify(url), shareText: nil, via: via)
    }

    @Test func ownerGoesFirstOthersWait() throws {
        let (p, base) = try tempPaths()
        defer { try? FileManager.default.removeItem(at: base) }
        let it = try item(p, by: other)
        #expect(it.owner == "aaaa")
        let seen = Date()
        #expect(Turn.isMine(it, device: other))
        #expect(!Turn.isMine(it, device: me))
        #expect(Turn.readyAt(it, device: other, firstSeen: seen, grace: 90) == .distantPast)
        #expect(Turn.readyAt(it, device: me, firstSeen: seen, grace: 90) == seen.addingTimeInterval(90))
    }

    @Test func legacyItemsWithoutOwner() throws {
        let (p, base) = try tempPaths()
        defer { try? FileManager.default.removeItem(at: base) }
        var it = try item(p, by: other)
        it.owner = nil                                   // 旧版写的条目：按设备名认
        #expect(Turn.isMine(it, device: other))
        #expect(!Turn.isMine(it, device: me))
        it.via = "shortcut"; it.device = "iPhone"        // 手机发来的不算任何一台 Mac 的
        #expect(!Turn.isMine(it, device: other))
        // 旧版字段缺失也能解码
        let old = #"{"schema":1,"id":"0123456789abcdef","key":"web:https://example.com/a","source":"web","url":"https://example.com/a","capturedURL":"https://example.com/a","via":"hotkey","device":"客厅 Mac","capturedAt":"2026-11-20T00:00:00Z","status":"pending","attempts":0}"#
        let d = try Coders.decoder.decode(InboxItem.self, from: Data(old.utf8))
        #expect(d.owner == nil && d.triedBy == nil)
    }

    @Test func failedItemsEachDeviceTriesOnce() throws {
        let (p, base) = try tempPaths()
        defer { try? FileManager.default.removeItem(at: base) }
        var it = try item(p, by: other)
        let seen = Date()
        it.status = .failed; it.attempts = 4; it.nextRetryAt = nil; it.triedBy = ["aaaa"]
        // 收藏的那台试过了、不再自动重试；另一台还没试过，等一会儿后试一次
        #expect(Turn.readyAt(it, device: other, firstSeen: seen, grace: 90) == nil)
        #expect(Turn.readyAt(it, device: me, firstSeen: seen, grace: 90) == seen.addingTimeInterval(90))
        it.triedBy = ["aaaa", "bbbb"]
        #expect(Turn.readyAt(it, device: me, firstSeen: seen, grace: 90) == nil)
        // 自动重试：收藏的那台到点就试，另一台再晚一会儿
        let n = seen.addingTimeInterval(120)
        it.nextRetryAt = n
        #expect(Turn.readyAt(it, device: other, firstSeen: seen, grace: 90) == n)
        #expect(Turn.readyAt(it, device: me, firstSeen: seen, grace: 90) == n.addingTimeInterval(90))
        // 旧版失败记录没有 triedBy：自己收藏的当作试过，别的 Mac 的当作没试过
        it.triedBy = nil; it.nextRetryAt = nil
        #expect(Turn.readyAt(it, device: other, firstSeen: seen, grace: 90) == nil)
        #expect(Turn.readyAt(it, device: me, firstSeen: seen, grace: 90) == seen.addingTimeInterval(90))
    }

    @Test func registryPicksOnePrimary() throws {
        let (p, base) = try tempPaths()
        defer { try? FileManager.default.removeItem(at: base) }
        let a = DeviceRegistry(paths: p, device: other), b = DeviceRegistry(paths: p, device: me)
        #expect(b.isPrimary())                           // 只有自己
        a.touch(); b.touch()
        #expect(a.records().count == 2)
        #expect(a.isPrimary() && !b.isPrimary())         // id 小的那台
        // 很久没露面的不算
        let now = Date()
        let stale = [DeviceRecord(id: "aaaa", name: "客厅 Mac", lastSeen: now.addingTimeInterval(-30 * 86400))]
        #expect(DeviceRegistry.primaryId(me: "bbbb", records: stale, now: now) == "bbbb")
        // 刚登记过就不重写文件
        let url = a.url("aaaa")
        let m1 = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        a.touch(now: now.addingTimeInterval(60))
        let m2 = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(m1 == m2)
    }

    /// 链接写坏的条目：处理时立刻失败，不联网——用来看「有没有被处理」
    func broken(_ p: Paths, by d: DeviceInfo) throws -> InboxItem {
        var it = try item(p, by: d)
        it.url = "这不是链接"
        try Inbox(paths: p, device: d).write(it)
        return it
    }

    func wait(_ seconds: Double, until ok: () async -> Bool) async throws -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await ok() { return true }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        return await ok()
    }

    @Test func otherMacsItemIsLeftAloneThenTakenOver() async throws {
        let (p, base) = try tempPaths()
        defer { try? FileManager.default.removeItem(at: base) }
        let it = try broken(p, by: other)
        let proc = Processor(paths: p, device: me)
        await proc.setGrace(0.8)
        try await proc.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        let q = await proc.queue()
        #expect(q.first?.item.status == .pending)        // 还在等收藏的那台
        #expect(q.first?.waiting == true)
        #expect(q.first?.running == false)
        // 过了等待时间没人处理：自己接手（不靠定时器，自己到点醒）
        let inbox = Inbox(paths: p, device: me)
        #expect(try await wait(3) { inbox.read(it.id)?.status == .failed })
        #expect(inbox.read(it.id)?.triedBy == ["bbbb"])
        // 试过一次、不是暂时性错误：不再自动重试
        try await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(inbox.read(it.id)?.attempts == 1)
    }

    @Test func ownItemProcessedImmediately() async throws {
        let (p, base) = try tempPaths()
        defer { try? FileManager.default.removeItem(at: base) }
        let it = try broken(p, by: me)
        let proc = Processor(paths: p, device: me)
        await proc.setGrace(60)
        try await proc.start()
        let inbox = Inbox(paths: p, device: me)
        #expect(try await wait(2) { inbox.read(it.id)?.status == .failed })
    }

    @Test func retryHereMakesThisMacTheOwner() async throws {
        let (p, base) = try tempPaths()
        defer { try? FileManager.default.removeItem(at: base) }
        let it = try broken(p, by: other)
        let proc = Processor(paths: p, device: me)
        await proc.setGrace(60)
        try await proc.start()
        await proc.retry(it.id)                           // 在这台上点了重试：不用等
        let inbox = Inbox(paths: p, device: me)
        #expect(try await wait(2) { inbox.read(it.id)?.status == .failed })
        #expect(inbox.read(it.id)?.owner == "bbbb")
    }

    @Test func itemsAlreadyInLibraryAreDropped() async throws {
        let (p, base) = try tempPaths()
        defer { try? FileManager.default.removeItem(at: base) }
        // 另一台 Mac 留下的「失败」记录，但文章其实已经在库里
        var it = try item(p, by: other)
        it.status = .failed; it.attempts = 3; it.lastError = "页面里没有正文区"; it.triedBy = ["aaaa"]
        let inbox = Inbox(paths: p, device: me)
        try inbox.write(it)
        try Data("{}".utf8).write(to: inbox.claimURL(it.id))
        try FileManager.default.createDirectory(at: p.folder(for: it.id), withIntermediateDirectories: true)
        let proc = Processor(paths: p, device: me)
        await proc.setPaused(true)
        try await proc.start()
        #expect(await proc.queue().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: inbox.itemURL(it.id).path))
        #expect(!FileManager.default.fileExists(atPath: inbox.claimURL(it.id).path))
    }

    @Test func phoneItemsGoToThePrimaryMacFirst() async throws {
        let (p, base) = try tempPaths()
        defer { try? FileManager.default.removeItem(at: base) }
        DeviceRegistry(paths: p, device: other).touch()   // 另一台 id 更小＝它先处理手机发来的
        let file = p.extraInboxes[0].appendingPathComponent("20261124-100000.json")
        try #"{"url":"https://example.com/post/2","device":"iPhone"}"#.write(to: file, atomically: true, encoding: .utf8)
        let proc = Processor(paths: p, device: me)
        await proc.setPaused(true)
        await proc.setGrace(0.8)
        try await proc.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await proc.queue().isEmpty)               // 先不收
        #expect(FileManager.default.fileExists(atPath: file.path))
        // 等了一会儿文件还在（那台没开机）：自己收
        #expect(try await wait(3) { await proc.queue().count == 1 })
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await proc.queue().first?.item.owner == "bbbb")
    }
}
