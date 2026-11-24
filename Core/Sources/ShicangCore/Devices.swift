import Foundation

/// 多台 Mac 共用一个文件库时的分工：谁收藏谁处理，别的 Mac 等一会儿、没人处理才接手。
/// 认领文件（.claim）靠 iCloud 同步，几秒内两台都看不到对方的认领，所以不能只靠它互斥。

/// 一台跑着拾藏的 Mac：`Config/devices/<id>.json`（每台只写自己的文件，不会互相冲突）
public struct DeviceRecord: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var lastSeen: Date
}

public struct DeviceRegistry: Sendable {
    public let paths: Paths
    public let device: DeviceInfo
    /// 多久没露面就不算在用
    public static let activeWindow: TimeInterval = 14 * 24 * 3600
    /// 自己的记录多久刷新一次
    public static let refreshEvery: TimeInterval = 6 * 3600

    public init(paths: Paths, device: DeviceInfo) { self.paths = paths; self.device = device }

    var dir: URL { paths.config.appendingPathComponent("devices", isDirectory: true) }
    func url(_ id: String) -> URL { dir.appendingPathComponent("\(id).json") }

    public func records() -> [DeviceRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.compactMap { n in
            (try? Data(contentsOf: dir.appendingPathComponent(n))).flatMap { try? Coders.decoder.decode(DeviceRecord.self, from: $0) }
        }
    }

    /// 登记自己（记录不存在或太旧才写，避免频繁改 iCloud 文件）
    public func touch(now: Date = Date()) {
        if let d = try? Data(contentsOf: url(device.id)), let r = try? Coders.decoder.decode(DeviceRecord.self, from: d),
           r.name == device.name, now.timeIntervalSince(r.lastSeen) < Self.refreshEvery { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = DeviceRecord(id: device.id, name: device.name, lastSeen: now)
        if let d = try? Coders.encoder.encode(r) { try? d.write(to: url(device.id), options: .atomic) }
    }

    /// 手机发来的收藏没有「收藏的那台 Mac」，由固定一台先处理：还在用的 Mac 里 id 最小的那台
    public static func primaryId(me: String, records: [DeviceRecord], now: Date = Date()) -> String {
        let active = records.filter { now.timeIntervalSince($0.lastSeen) < activeWindow }.map(\.id)
        return (active + [me]).min() ?? me
    }

    public func isPrimary(now: Date = Date()) -> Bool {
        Self.primaryId(me: device.id, records: records(), now: now) == device.id
    }
}

/// 一条收件箱条目什么时候轮到这台 Mac 处理
public enum Turn {
    /// 别的 Mac 收藏的条目，这台等多久才接手
    public static let defaultGrace: TimeInterval = 90

    /// 是不是这台 Mac 收藏的。旧版写的条目没有 owner：按设备名认（手机发来的不算任何一台 Mac 的）
    public static func isMine(_ item: InboxItem, device: DeviceInfo) -> Bool {
        if let o = item.owner { return o == device.id }
        return item.via != "shortcut" && item.device == device.name
    }

    /// 这台 Mac 试过没有。旧版写的失败记录没有 triedBy：自己收藏的当作试过
    public static func tried(_ item: InboxItem, device: DeviceInfo) -> Bool {
        item.triedBy?.contains(device.id) ?? (item.status == .failed && isMine(item, device: device))
    }

    /// 最早什么时候可以处理；nil＝不自动处理（失败且不再自动重试，等用户手动）
    /// - firstSeen：这台 Mac 第一次看到这一条的时间（不用收藏时间：条目可能隔很久才同步过来）
    public static func readyAt(_ item: InboxItem, device: DeviceInfo, firstSeen: Date, grace: TimeInterval) -> Date? {
        let mine = isMine(item, device: device)
        if item.status == .failed, tried(item, device: device) {
            guard let n = item.nextRetryAt else { return nil }
            return mine ? n : n.addingTimeInterval(grace)
        }
        // 排队中，或别的 Mac 失败了而这台还没试过
        return mine ? .distantPast : firstSeen.addingTimeInterval(grace)
    }
}
