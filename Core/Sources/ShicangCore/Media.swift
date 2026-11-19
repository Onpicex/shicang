import Foundation

/// 按站点限速：同一站点并发 ≤ 2、相邻两次请求间隔 0.3–0.5 秒（P0 中连续取图触发过 Cloudflare 封 IP）
public actor HostLimiter {
    public static let shared = HostLimiter()

    let maxConcurrent: Int
    let minInterval: ClosedRange<Double>
    private var active: [String: Int] = [:]
    private var nextAllowed: [String: Date] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init(maxConcurrent: Int = 2, minInterval: ClosedRange<Double> = 0.3...0.5) {
        self.maxConcurrent = maxConcurrent; self.minInterval = minInterval
    }

    public func acquire(_ host: String) async {
        while true {
            if active[host, default: 0] < maxConcurrent {
                let wait = nextAllowed[host].map { $0.timeIntervalSinceNow } ?? 0
                if wait <= 0 {
                    active[host, default: 0] += 1
                    nextAllowed[host] = Date().addingTimeInterval(Double.random(in: minInterval))
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                continue
            }
            await withCheckedContinuation { c in waiters[host, default: []].append(c) }
        }
    }

    public func release(_ host: String) {
        active[host, default: 1] -= 1
        if var w = waiters[host], !w.isEmpty {
            let c = w.removeFirst()
            waiters[host] = w
            c.resume()
        }
    }

    public func run<T: Sendable>(_ host: String, _ body: @Sendable () async -> T) async -> T {
        await acquire(host)
        let r = await body()
        release(host)
        return r
    }
}

public enum ImageFetcher {
    /// 下载一张图到 dir/name.<ext>，成功返回文件名
    public static func download(_ urlString: String, to dir: URL, name: String, referer: String?,
                                limiter: HostLimiter = .shared) async -> String? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return nil }
        var h: [String: String] = ["Accept": "image/avif,image/webp,image/png,image/jpeg,*/*"]
        if let r = referer { h["Referer"] = r }
        let headers = h
        let result: (Data, HTTPURLResponse)? = await limiter.run(host) {
            try? await HTTP.get(url, ua: UA.iPhoneSafari, headers: headers, retries: 1)
        }
        guard let (data, resp) = result, resp.statusCode == 200, data.count > 200 else { return nil }
        let ct = (resp.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let sniff = sniffExt(data)
        guard ct.hasPrefix("image/") || sniff != nil else { return nil }
        let ext = sniff ?? (ct.contains("png") ? "png" : ct.contains("gif") ? "gif" : ct.contains("webp") ? "webp"
                            : ct.contains("svg") ? "svg" : ct.contains("avif") ? "avif" : ct.contains("icon") ? "ico" : "jpg")
        let file = "\(name).\(ext)"
        do { try data.write(to: dir.appendingPathComponent(file), options: .atomic) } catch { return nil }
        return file
    }

    public static func sniffExt(_ d: Data) -> String? {
        let b = [UInt8](d.prefix(12))
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if b.count >= 12 && b[0...3] == [0x52, 0x49, 0x46, 0x46] && b[8...11] == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if b.count >= 12 && b[4...7] == [0x66, 0x74, 0x79, 0x70] { return b[8...11] == [0x61, 0x76, 0x69, 0x66] ? "avif" : "heic" }
        if b.starts(with: [0x00, 0x00, 0x01, 0x00]) { return "ico" }
        return nil
    }

    /// 文章里所有要下载的图：正文图按出现顺序编号 01、02…，视频封面 NN-video-cover，题图 cover
    struct Job: Sendable { var block: Int?; var isVideoCover: Bool; var url: String; var name: String }

    static func jobs(for art: Article) -> [Job] {
        var out: [Job] = []
        var n = 0
        for (i, b) in art.blocks.enumerated() {
            if let img = b.image { n += 1; out.append(Job(block: i, isVideoCover: false, url: img.url, name: String(format: "%02d", n))) }
            if let c = b.video?.cover { n += 1; out.append(Job(block: i, isVideoCover: true, url: c.url, name: String(format: "%02d-video-cover", n))) }
        }
        if let c = art.cover { out.append(Job(block: nil, isVideoCover: false, url: c.url, name: "cover")) }
        return out
    }

    /// 并发下载（同站点由 HostLimiter 控制），把文件名写回文章；只下 `file == nil` 的
    public static func fetchAll(_ art: inout Article, into dir: URL, referer: String?) async -> [String] {
        let imgDir = dir.appendingPathComponent("images")
        try? FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)
        let todo = jobs(for: art).filter { j in
            if let i = j.block { return j.isVideoCover ? art.blocks[i].video?.cover?.file == nil : art.blocks[i].image?.file == nil }
            return art.cover?.file == nil
        }
        let results = await withTaskGroup(of: (Job, String?).self) { g -> [(Job, String?)] in
            for j in todo { g.addTask { (j, await download(j.url, to: imgDir, name: j.name, referer: referer)) } }
            var r: [(Job, String?)] = []
            for await x in g { r.append(x) }
            return r
        }
        var failures: [String] = []
        for (j, f) in results {
            guard let f else { if j.block != nil && !j.isVideoCover { failures.append(j.url) }; continue }
            let rel = "images/" + f
            if let i = j.block {
                if j.isVideoCover { art.blocks[i].video?.cover?.file = rel } else { art.blocks[i].image?.file = rel }
            } else { art.cover?.file = rel }
        }
        art.recomputeStats()
        return failures
    }
}
