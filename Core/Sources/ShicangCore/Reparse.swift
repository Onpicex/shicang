import Foundation

/// 解析规则升级后，用收藏时存下的原始网页（source.html.gz）在本机重新解析老文章，不联网。
/// 只换正文结构（block 列表）：标题、作者、收藏时间、原始链接、别名、已下载的图片都沿用原来的；
/// 图片 / 视频封面的列表和原来对不上就不动这篇（文件名按图片顺序编号，对不上会串图）。
/// 目前只有公众号存了完整原始网页且解析不依赖网页渲染，X 和普通网页要重新联网抓，不在这里做。
public enum Reparser {
    public enum Outcome: Equatable, Sendable {
        case updated(blocksBefore: Int, blocksAfter: Int)
        case current                  // 已经是新版解析
        case skipped(String)
    }

    /// 只看来源和解析器版本（列表里的摘要就能判断；版本未知的也算，读 article.json 再确认）
    public static func outdated(source: Source, extractor: String?) -> Bool {
        source == .wechat && extractor != WeChatExtractor.version
    }

    public static func reparse(dir: URL) -> Outcome {
        let file = dir.appendingPathComponent("article.json")
        guard let d = try? Data(contentsOf: file), let old = try? Coders.decoder.decode(Article.self, from: d) else {
            return .skipped("读不到 article.json")
        }
        guard outdated(source: old.source, extractor: old.extractor) else { return .current }
        guard let gz = try? Data(contentsOf: dir.appendingPathComponent("source.html.gz")), let raw = Gzip.decompress(gz),
              let html = String(data: raw, encoding: .utf8) else { return .skipped("没有原始网页快照") }
        guard let url = URL(string: old.url) else { return .skipped("原文链接无效") }
        let t = CaptureTarget(source: .wechat, url: url, capturedURL: old.capturedURL, key: old.canonicalId)
        let parsed: Article
        do { parsed = try WeChatExtractor().parse(html: html, raw: raw, target: t).article } catch { return .skipped("重新解析失败：\(error)") }
        guard let art = merge(old: old, parsed: parsed) else { return .skipped("图片列表和原来对不上") }
        do { try LibraryWriter.writeFiles(art, to: dir) } catch { return .skipped("写回失败：\(error.localizedDescription)") }
        return .updated(blocksBefore: old.blocks.count, blocksAfter: art.blocks.count)
    }

    /// 新解析出的正文 + 原文章的其他字段；已下载的图片按顺序原样搬过来（URL 必须一一对上）
    static func merge(old: Article, parsed: Article) -> Article? {
        let oldImgs = old.blocks.compactMap(\.image), newImgs = parsed.blocks.compactMap(\.image)
        let oldCovers = old.blocks.compactMap { $0.video?.cover }, newCovers = parsed.blocks.compactMap { $0.video?.cover }
        guard oldImgs.map(\.url) == newImgs.map(\.url), oldCovers.map(\.url) == newCovers.map(\.url) else { return nil }
        var blocks = parsed.blocks
        var ii = 0, vi = 0
        for i in blocks.indices {
            if blocks[i].image != nil { blocks[i].image = oldImgs[ii]; ii += 1 }
            if blocks[i].video?.cover != nil { blocks[i].video?.cover = oldCovers[vi]; vi += 1 }
        }
        var art = old
        art.blocks = blocks
        art.extractor = parsed.extractor
        art.recomputeStats()
        return art
    }
}
