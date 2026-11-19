import Foundation

/// 所有目录集中在这里。数据在 iCloud Drive/拾藏，本机缓存/暂存/日志在 Application Support/拾藏（不同步）。
public struct Paths: Sendable {
    public let root: URL            // iCloud Drive/拾藏
    public let local: URL           // ~/Library/Application Support/拾藏
    public let extraInboxes: [URL]  // 快捷指令写入的目录（iCloud Drive/快捷指令/拾藏Inbox）

    public init(root: URL, local: URL, extraInboxes: [URL] = []) {
        self.root = root; self.local = local; self.extraInboxes = extraInboxes
    }

    public static func standard() -> Paths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let docs = home.appendingPathComponent("Library/Mobile Documents", isDirectory: true)
        return Paths(
            root: docs.appendingPathComponent("com~apple~CloudDocs/拾藏", isDirectory: true),
            local: home.appendingPathComponent("Library/Application Support/拾藏", isDirectory: true),
            extraInboxes: [docs.appendingPathComponent("iCloud~is~workflow~my~workflows/Documents/拾藏Inbox", isDirectory: true)])
    }

    public var library: URL { root.appendingPathComponent("Library", isDirectory: true) }
    public var inbox: URL { root.appendingPathComponent("Inbox", isDirectory: true) }
    public var config: URL { root.appendingPathComponent("Config", isDirectory: true) }
    /// 暂存：和 iCloud 目录在同一个卷上，写完整个文件夹后一次 rename 进 Library（别的设备看不到半成品）
    public var staging: URL { local.appendingPathComponent("staging", isDirectory: true) }
    public var logs: URL { local.appendingPathComponent("logs", isDirectory: true) }
    public var debug: URL { local.appendingPathComponent("debug", isDirectory: true) }

    public func folder(for id: String) -> URL {
        library.appendingPathComponent(String(id.prefix(2)), isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    public func ensure() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: local, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: local.path)
        for d in [library, inbox, config, staging, logs, debug] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    /// 快捷指令目录在别的 App 的 iCloud 容器里，可能卡住：单独建，调用方走 FileIO 带超时
    public func ensureExtraInboxes() {
        for d in extraInboxes { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }
}

/// 本机设备标识（认领文件里用）
public struct DeviceInfo: Codable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) { self.id = id; self.name = name }

    public static func load(local: URL) -> DeviceInfo {
        let f = local.appendingPathComponent("device.json")
        if let d = try? Data(contentsOf: f), let v = try? JSONDecoder().decode(DeviceInfo.self, from: d) { return v }
        let name = Host.current().localizedName ?? "Mac"
        let v = DeviceInfo(id: UUID().uuidString.lowercased(), name: name)
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try? JSONEncoder().encode(v).write(to: f, options: .atomic)
        return v
    }
}

public enum Coders {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// 宽松日期：ISO8601（带/不带小数秒、带/不带时区）或秒级时间戳
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            if let n = try? c.decode(Double.self) { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
            let s = try c.decode(String.self)
            if let v = parseDate(s) { return v }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "无法识别的日期：\(s)")
        }
        return d
    }

    public static func parseDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let f1 = ISO8601DateFormatter()
        if let v = f1.date(from: t) { return v }
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let v = f1.date(from: t) { return v }
        // 快捷指令常见：2026-11-19 16:20:05 / 2026-11-19T16:20:05（无时区按本地）
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ssZ"] {
            df.dateFormat = fmt
            if let v = df.date(from: t) { return v }
        }
        return nil
    }
}
