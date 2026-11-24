import Foundation

/// 收件箱里的一条待处理链接：`Inbox/<hash>.json`（hash = 收藏时去重键的哈希）
public struct InboxItem: Codable, Sendable, Identifiable, Hashable {
    public enum Status: String, Codable, Sendable { case pending, failed }

    public var schema: Int = 1
    public var id: String               // = Capture.hash(key)
    public var key: String              // 收藏时的去重键（x:<id> / wechat:s/<code> / web:<url>）
    public var source: Source
    public var url: String              // 规范化后的链接
    public var capturedURL: String      // 原始链接
    public var shareText: String?       // 分享文字（只在和链接不同的时候存）
    public var highlight: String?       // 链接旁边的大段文字：存好后记成这篇的「我的摘录」
    public var via: String              // 入口：hotkey / clipboard / drop / scheme / shortcut / menu / cli
    public var device: String           // 收藏设备名
    public var capturedAt: Date
    public var status: Status = .pending
    public var attempts: Int = 0
    public var lastError: String?
    public var lastAttemptAt: Date?
    public var nextRetryAt: Date?       // 自动重试时间（暂时性错误才有）
    public var owner: String?           // 收藏的那台 Mac 的设备 ID：它先处理，别的 Mac 等一会儿才接手（旧版条目没有）
    public var triedBy: [String]?       // 试过但失败的设备 ID（每台 Mac 至少各试一次）

    public var displayTitle: String {
        let u = URL(string: url)
        switch source {
        case .x: return "X · " + (u?.pathComponents.dropFirst().first.map { "@" + $0 } ?? url)
        case .wechat: return "公众号文章"
        default: return u?.host ?? url
        }
    }
}

/// 认领文件：`Inbox/<hash>.claim`。写设备 ID + 到期时间；过期后其他设备可接手。
public struct Claim: Codable, Sendable {
    public var device: String
    public var deviceName: String
    public var expiresAt: Date
    public var isExpired: Bool { expiresAt < Date() }
}

public enum EnqueueResult: Sendable {
    case queued(InboxItem)
    case alreadyQueued(InboxItem)
    case exists(id: String, title: String)
    case highlightAdded(id: String, title: String)     // 文章已存在，这次带的大段文字加进了「我的摘录」
    case clipped(id: String, title: String)            // 剪藏：直接存好了
    case rejected(String)

    public var message: String {
        switch self {
        case .queued: return "已收到"
        case .alreadyQueued: return "已在队列中"
        case .exists(_, let t): return "已存在：\(t)"
        case .highlightAdded(_, let t): return "已加到摘录：\(t)"
        case .clipped(_, let t): return "已剪藏：\(t)"
        case .rejected(let why): return why
        }
    }
}

/// 收件箱读写。所有方法都是同步文件操作，调用方自己决定在哪个 actor 上跑。
public struct Inbox: Sendable {
    public let paths: Paths
    public let device: DeviceInfo
    public static let lease: TimeInterval = 10 * 60

    public init(paths: Paths, device: DeviceInfo) { self.paths = paths; self.device = device }

    public func itemURL(_ id: String) -> URL { paths.inbox.appendingPathComponent("\(id).json") }
    public func claimURL(_ id: String) -> URL { paths.inbox.appendingPathComponent("\(id).claim") }

    public static func isHashName(_ name: String) -> Bool {
        name.count == 16 && name.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    public func read(_ id: String) -> InboxItem? {
        guard let d = try? Data(contentsOf: itemURL(id)) else { return nil }
        return try? Coders.decoder.decode(InboxItem.self, from: d)
    }

    public func write(_ item: InboxItem) throws {
        try Coders.encoder.encode(item).write(to: itemURL(item.id), options: .atomic)
    }

    public func remove(_ id: String) {
        try? FileManager.default.removeItem(at: itemURL(id))
        try? FileManager.default.removeItem(at: claimURL(id))
    }

    /// 全部正式条目（`<hash>.json`）
    public func items() -> [InboxItem] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.inbox.path)) ?? []
        return names.compactMap { n -> InboxItem? in
            guard n.hasSuffix(".json") else { return nil }
            let id = String(n.dropLast(5))
            guard Self.isHashName(id) else { return nil }
            return read(id)
        }.sorted { $0.capturedAt < $1.capturedAt }
    }

    public func makeItem(_ t: CaptureTarget, shareText: String?, via: String, device: String? = nil, capturedAt: Date = Date()) -> InboxItem {
        let hl = shareText.flatMap { Capture.highlight(in: $0) }
        let share = hl != nil ? nil : shareText.flatMap { s -> String? in
            let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty || v == t.capturedURL || v == t.url.absoluteString ? nil : String(v.prefix(2000))
        }
        return InboxItem(id: Capture.hash(t.key), key: t.key, source: t.source, url: t.url.absoluteString,
                         capturedURL: t.capturedURL, shareText: share, highlight: hl, via: via, device: device ?? self.device.name,
                         capturedAt: capturedAt, owner: self.device.id)
    }

    // MARK: 认领

    public func readClaim(_ id: String) -> Claim? {
        guard let d = try? Data(contentsOf: claimURL(id)) else { return nil }
        return try? Coders.decoder.decode(Claim.self, from: d)
    }

    /// 别的设备持有、且没过期 → 不能处理
    public func claimedByOther(_ id: String) -> Claim? {
        guard let c = readClaim(id), !c.isExpired, c.device != device.id else { return nil }
        return c
    }

    /// 写认领文件；写完立刻读回确认是自己（iCloud 同步有延迟，两台同时写时由文件夹哈希兜底合并）
    public func claim(_ id: String) -> Bool {
        if claimedByOther(id) != nil { return false }
        let c = Claim(device: device.id, deviceName: device.name, expiresAt: Date().addingTimeInterval(Self.lease))
        guard let d = try? Coders.encoder.encode(c), (try? d.write(to: claimURL(id), options: .atomic)) != nil else { return false }
        return readClaim(id)?.device == device.id
    }

    public func release(_ id: String) {
        if readClaim(id)?.device == device.id { try? FileManager.default.removeItem(at: claimURL(id)) }
    }

    // MARK: 外来文件（快捷指令 / 手工放入）

    /// 收件箱里非 `<hash>.json` 的文件：快捷指令存的 `<时间戳>.json`/`.txt`，或拖进去的 `.webloc`/`.url`
    /// 快捷指令目录在别的 App 的 iCloud 容器里，列目录走带超时的 FileIO（卡住也不拖垮处理流程）
    public func foreignFiles() async -> [URL] {
        var out: [URL] = []
        for dir in [paths.inbox] + paths.extraInboxes {
            let names = await FileIO.list(dir) ?? []
            for n in names where !n.hasPrefix(".") {
                let ext = (n as NSString).pathExtension.lowercased()
                let base = (n as NSString).deletingPathExtension
                if dir == paths.inbox && (ext == "claim" || (ext == "json" && Self.isHashName(base))) { continue }
                guard ["json", "txt", "text", "webloc", "url", ""].contains(ext) else { continue }
                out.append(dir.appendingPathComponent(n))
            }
        }
        return out
    }

    public struct Foreign: Sendable {
        public var text: String
        public var device: String?
        public var capturedAt: Date?
    }

    /// 解析外来文件。JSON：取 url / share_text / text / device / captured_at（字段名宽松）；其他：整段当分享文字
    public static func parseForeign(_ data: Data, ext: String) -> Foreign? {
        if ext == "webloc", let pl = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let u = pl["URL"] as? String {
            return Foreign(text: u)
        }
        guard let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { return nil }
        if ext == "url" {   // Windows .url：URL=...
            for line in s.split(whereSeparator: \.isNewline) where line.hasPrefix("URL=") { return Foreign(text: String(line.dropFirst(4))) }
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            func str(_ keys: [String]) -> String? {
                for k in keys {
                    if let v = obj[k] as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return v }
                    if let v = obj[k] as? [String], let f = v.first { return f }
                }
                return nil
            }
            let share = str(["share_text", "shareText", "text", "input"])
            let url = str(["url", "URL", "link"])
            let text = [url, share].compactMap { $0 }.joined(separator: "\n")
            guard !text.isEmpty else { return nil }
            var date: Date?
            if let d = obj["captured_at"] ?? obj["capturedAt"] ?? obj["date"] {
                if let n = d as? Double { date = Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
                else if let ds = d as? String { date = Coders.parseDate(ds) }
            }
            return Foreign(text: text, device: str(["device", "device_name"]), capturedAt: date)
        }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : Foreign(text: t)
    }
}
