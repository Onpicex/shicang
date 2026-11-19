import Foundation
import CoreServices

/// 监听目录变化（FSEvents，1 秒合并）。iCloud 同步下来的文件也会触发。
public final class DirectoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let watched: [String]
    private let latency: Double
    fileprivate let handler: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "shicang.watcher")

    public init(_ dirs: [URL], latency: Double = 1.0, handler: @escaping @Sendable ([String]) -> Void) {
        watched = dirs.map(\.path); self.latency = latency; self.handler = handler
    }

    @discardableResult
    public func start() -> Bool {
        guard stream == nil else { return true }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            me.handler(list)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, watched as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return false }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else { FSEventStreamInvalidate(s); FSEventStreamRelease(s); return false }
        stream = s
        return true
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}

/// 带超时的文件操作：iCloud 目录可能卡住（曾见 launchd 进程 readdir 永久阻塞），绝不在主线程/处理 actor 上直接等
public enum FileIO {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var inFlight = Set<String>()       // 同一路径上一回还没返回就不再开新线程（卡住的线程只会有一个）
    }
    private final class Once: @unchecked Sendable {
        let lock = NSLock()
        var done = false
        func first() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }
    private static let state = State()

    public static func run<T: Sendable>(key: String, timeout: Double, _ body: @escaping @Sendable () -> T) async -> T? {
        let started = state.lock.withLock { state.inFlight.insert(key).inserted }
        guard started else { return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            let once = Once()
            DispatchQueue.global(qos: .utility).async {
                let v = body()
                _ = state.lock.withLock { state.inFlight.remove(key) }
                if once.first() { c.resume(returning: v) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.first() { c.resume(returning: nil) }
            }
        }
    }

    public static func list(_ dir: URL, timeout: Double = 5) async -> [String]? {
        await run(key: "ls:" + dir.path, timeout: timeout) {
            (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        }
    }

    public static func read(_ file: URL, timeout: Double = 20) async -> Data? {
        await run(key: "read:" + file.path, timeout: timeout) { try? Data(contentsOf: file) } ?? nil
    }
}
