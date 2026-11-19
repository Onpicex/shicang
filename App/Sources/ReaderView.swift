import SwiftUI
import WebKit
import UniformTypeIdentifiers
import ShicangCore

/// 阅读器：WKWebView 加载 shicang-reader://article/<id>/index.html。
/// 页面和图片都由本地处理器从文章文件夹读出；CSP 禁止外部加载、JS 关闭，链接一律交给默认浏览器。
struct ReaderView: NSViewRepresentable {
    let summary: ArticleSummary
    let paths: Paths

    /// 文章更新（补到图、合并别名、AI 摘要写好、解析规则升级后重新解析）后重新加载
    private var loadKey: String {
        "\(summary.id)|\(summary.imagesSaved)|\(summary.title)|\(summary.aliases.count)|\(summary.ai?.at.timeIntervalSince1970 ?? 0)|\(summary.highlights?.count ?? 0)|\(summary.extractor ?? "")|\(summary.chars)"
    }

    func makeCoordinator() -> Coordinator { Coordinator(paths: paths) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(context.coordinator.handler, forURLScheme: "shicang-reader")
        cfg.websiteDataStore = .nonPersistent()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.allowsMagnification = true
        wv.setAccessibilityIdentifier("reader")
        load(wv, context.coordinator)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        if context.coordinator.loadedKey != loadKey { load(wv, context.coordinator) }
    }

    private func load(_ wv: WKWebView, _ c: Coordinator) {
        c.loadedKey = loadKey
        guard let url = URL(string: "shicang-reader://article/\(summary.id)/index.html") else { return }
        wv.load(URLRequest(url: url))
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let handler: ReaderSchemeHandler
        var loadedKey = ""
        init(paths: Paths) { handler = ReaderSchemeHandler(paths: paths) }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let u = action.request.url else { return .cancel }
            if u.scheme == "shicang-reader" { return .allow }
            // 代码块右上角的「复制」：链接里带着代码原文（页面不跑 JS，只能这样把文字交出来）
            if u.scheme == ReaderHTML.copyScheme {
                if action.navigationType == .linkActivated,
                   let text = String(u.absoluteString.dropFirst(ReaderHTML.copyScheme.count + 1)).removingPercentEncoding {
                    AppModel.shared.copyCode(text)
                }
                return .cancel
            }
            if ["http", "https", "mailto"].contains(u.scheme?.lowercased() ?? ""), action.navigationType == .linkActivated {
                NSWorkspace.shared.open(u)
            }
            return .cancel
        }
    }
}

/// shicang-reader://article/<id>/index.html → 现场把 article.json 渲染成 HTML
/// shicang-reader://article/<id>/images/01.jpg → 文章文件夹里的文件（禁止跳出文件夹）
/// 读文件放后台线程：iCloud 文件可能被「优化存储」移走，读时要等下载，不能卡主线程。
@MainActor
final class ReaderSchemeHandler: NSObject, WKURLSchemeHandler {
    let paths: Paths
    private var active = Set<ObjectIdentifier>()

    init(paths: Paths) { self.paths = paths }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        active.insert(key)
        let url = task.request.url
        let paths = self.paths
        Task {
            let res = await Task.detached { Self.load(url, paths) }.value
            guard self.active.remove(key) != nil, let url else { return }
            if let (data, mime) = res {
                let isText = mime.hasPrefix("text/")
                task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: isText ? "utf-8" : nil))
                task.didReceive(data)
                task.didFinish()
            } else {
                task.didFailWithError(URLError(.fileDoesNotExist))
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }

    nonisolated static func load(_ url: URL?, _ paths: Paths) -> (Data, String)? {
        guard let url, url.host == "article" else { return nil }
        let comps = url.pathComponents.filter { $0 != "/" }
        guard comps.count >= 2, let id = comps.first, Inbox.isHashName(id), !comps.contains(".."), !comps.contains(".") else { return nil }
        let folder = paths.folder(for: id).standardizedFileURL
        let rest = comps.dropFirst().joined(separator: "/")
        if rest == "index.html" {
            guard let d = try? Data(contentsOf: folder.appendingPathComponent("article.json")),
                  let art = try? Coders.decoder.decode(Article.self, from: d) else { return nil }
            return (Data(ReaderHTML.render(art, ai: AIStore.load(dir: folder), highlights: HighlightStore.load(dir: folder, resolve: false)).utf8), "text/html")
        }
        let file = folder.appendingPathComponent(rest).standardizedFileURL
        guard file.path.hasPrefix(folder.path + "/"), let d = try? Data(contentsOf: file) else { return nil }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return (d, mime)
    }
}
