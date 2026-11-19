import Foundation

/// 本机运行日志：~/Library/Application Support/拾藏/logs/app.log（超 2MB 轮换一份）。
/// 只记事件、链接、耗时；绝不写密钥和剪贴板全文。
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()
    private let queue = DispatchQueue(label: "shicang.applog")
    private var file: URL?
    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    func configure(_ dir: URL) {
        queue.sync { file = dir.appendingPathComponent("app.log") }
    }

    func say(_ s: String) {
        let line = fmt.string(from: Date()) + " " + s + "\n"
        queue.async { [self] in
            guard let file else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 2_000_000 {
                let old = file.deletingPathExtension().appendingPathExtension("1.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: file, to: old)
            }
            if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: file) else { return }
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        }
    }
}
