import Foundation
import Testing
import Network
import WebKit
@testable import ShicangCore

/// 隐藏浏览器的「拦 http」规则：真编译、真加载页面。规则写错（比如 url-filter 用了 WebKit 不支持的 `|`）时
/// 每次网页收藏都会直接失败，只能靠不跑 JS 的兜底，所以这里必须真跑一遍
@MainActor @Suite(.serialized) struct HiddenBrowserTests {
    /// 本机临时端口，只数有没有连接进来（不回任何内容）
    final class Probe: @unchecked Sendable {
        let listener: NWListener
        private let lock = NSLock()
        private var n = 0
        var connections: Int { lock.lock(); defer { lock.unlock() }; return n }
        init() throws {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] c in
                guard let self else { return }
                self.lock.lock(); self.n += 1; self.lock.unlock()
                c.cancel()
            }
        }
        func start() async throws -> UInt16 {
            listener.start(queue: .global())
            for _ in 0..<50 {
                if let p = listener.port?.rawValue, p != 0 { return p }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw ExtractError.parse("监听端口没起来")
        }
    }

    static func page(_ port: UInt16) -> String {
        "<html><body><p>hi</p><img src=\"http://127.0.0.1:\(port)/a.png\"><script src=\"http://127.0.0.1:\(port)/b.js\"></script>"
        + "<iframe src=\"http://127.0.0.1:\(port)/f.html\"></iframe></body></html>"
    }

    @Test func rulesCompileAndAreShared() async throws {
        async let a = HiddenBrowser.noHTTP()
        async let b = HiddenBrowser.noHTTP()
        let (x, y) = try await (a, b)
        #expect(x === y)
    }

    @Test func httpSubresourcesNeverConnect() async throws {
        // 对照：不装规则的 WKWebView 会连到本机端口（证明这个测试能看到连接）
        let control = try Probe()
        let cport = try await control.start()
        defer { control.listener.cancel() }
        let plain = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: {
            let c = WKWebViewConfiguration(); c.websiteDataStore = .nonPersistent(); return c }())
        plain.loadHTMLString(Self.page(cport), baseURL: URL(string: "https://shicang-test.invalid/"))
        for _ in 0..<40 where control.connections == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(control.connections > 0, "对照组没连进来，这个测试看不到连接")

        // 隐藏浏览器装了规则：一个连接都不该有
        let probe = try Probe()
        let port = try await probe.start()
        defer { probe.listener.cancel() }
        let hb = HiddenBrowser(userAgent: UA.macSafari)
        defer { hb.close() }
        try await hb.blockHTTP()
        hb.webView.loadHTMLString(Self.page(port), baseURL: URL(string: "https://shicang-test.invalid/"))
        try await Task.sleep(for: .seconds(3))
        #expect(probe.connections == 0)
        #expect(try await hb.js("return document.querySelector('p').textContent") as? String == "hi")   // 页面本身照常加载
    }
}
