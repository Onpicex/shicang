import Testing
import Foundation
@testable import ShicangCore

/// 不允许 http 连接，没有例外（本机 localhost 也不行）
@Suite struct NetPolicyTests {
    @Test func allowedAndSecure() {
        func u(_ s: String) -> URL { URL(string: s)! }
        #expect(NetPolicy.allowed(u("https://example.com/a")))
        #expect(!NetPolicy.allowed(u("http://localhost:11434/v1")))
        #expect(!NetPolicy.allowed(u("http://127.0.0.1:1234/v1")))
        #expect(!NetPolicy.allowed(u("http://[::1]:8080/")))
        #expect(NetPolicy.allowed(u("https://localhost:8443/v1")))      // 本机走 https 可以
        #expect(!NetPolicy.allowed(u("https:///nohost")))
        #expect(!NetPolicy.allowed(u("http://203.0.113.7:3000")))
        #expect(!NetPolicy.allowed(u("http://192.168.1.5:11434/v1")))
        #expect(!NetPolicy.allowed(u("ftp://example.com/x")))

        #expect(NetPolicy.secure(u("http://example.com/a?b=1#c")).absoluteString == "https://example.com/a?b=1#c")
        #expect(NetPolicy.secure(u("http://example.com:80/x")).absoluteString == "https://example.com/x")
        #expect(NetPolicy.secure(u("http://example.com:8080/x")).absoluteString == "https://example.com:8080/x")
        #expect(NetPolicy.secure(u("HTTP://Example.com/x")).scheme == "https")
        #expect(NetPolicy.secure(u("http://localhost:11434/v1")).absoluteString == "https://localhost:11434/v1")
        #expect(NetPolicy.secure(u("https://example.com/x")).absoluteString == "https://example.com/x")
        #expect(throws: ExtractError.self) { try NetPolicy.checked(u("ftp://example.com/x")) }
        #expect((try? NetPolicy.checked(u("http://example.com/x")))?.absoluteString == "https://example.com/x")
    }

    @Test func redirectToHttpIsUpgraded() async {
        let task = URLSession.shared.dataTask(with: URL(string: "https://example.com/")!)   // 不 resume，不发请求
        let resp = HTTPURLResponse(url: URL(string: "https://example.com/")!, statusCode: 301, httpVersion: nil, headerFields: nil)!
        func follow(_ to: String) async -> String? {
            await withCheckedContinuation { c in
                NetPolicy.redirectGuard.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: resp,
                                                   newRequest: URLRequest(url: URL(string: to)!)) { r in c.resume(returning: r?.url?.absoluteString) }
            }
        }
        #expect(await follow("http://example.com/next") == "https://example.com/next")
        #expect(await follow("https://example.com/next") == "https://example.com/next")
        #expect(await follow("http://localhost:8080/x") == "https://localhost:8080/x")   // 跳到本机 http 也改成 https
        #expect(await follow("ftp://example.com/x") == nil)
    }

    @Test func aiAddressMustBeHttps() {
        let crs = AIPreset.find("crs")
        // 预设默认就是 https
        let def = AIConfig(preset: AIPreset.find("anthropic"), apiKey: "k")
        #expect(def.endpoint?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(def.isReady && def.missing == nil)
        #expect(!AIPreset.all.contains { !$0.baseURL.isEmpty && !$0.baseURL.hasPrefix("https://") })
        // 自建中继没有默认地址：提示填地址
        #expect(AIConfig(preset: crs, apiKey: "k").missing == "没填地址")
        // 明写 http（旧地址）→ 不可用，提示要 https
        let old = AIConfig(preset: crs, baseURL: "http://203.0.113.7:3000", apiKey: "k")
        #expect(!old.isReady)
        #expect(old.missing?.contains("https://") == true)
        #expect(AIClient(config: old) == nil)
        // 只填 host → 补 https
        #expect(AIConfig(preset: crs, baseURL: "relay.example.com/api", apiKey: "k").endpoint?.absoluteString == "https://relay.example.com/api/v1/messages")
        // 局域网地址只填 host 也补 https（http 不放行）
        let custom = AIPreset.find("custom")
        #expect(AIConfig(preset: custom, baseURL: "192.168.1.5:11434/v1", model: "m").endpoint?.scheme == "https")
        #expect(!AIConfig(preset: custom, baseURL: "http://192.168.1.5:11434/v1", model: "m").isReady)
        // 本机也没有例外：只填 host 补 https，明写 http 不可用
        #expect(AIConfig(preset: custom, baseURL: "127.0.0.1:8000/v1", model: "m").endpoint?.absoluteString == "https://127.0.0.1:8000/v1/chat/completions")
        let lo = AIConfig(preset: custom, baseURL: "http://localhost:11434/v1", model: "m")
        #expect(!lo.isReady && lo.missing?.contains("localhost") == true)
        #expect(AIClient(config: lo) == nil)
        #expect(!AIPreset.all.contains { ["ollama", "lmstudio"].contains($0.id) })   // 本机预设已删
    }

    @Test func capturedHttpLinksAreFetchedOverHttps() throws {
        let a = try Capture.classify("http://example.com/post?utm_source=x&id=3")
        let b = try Capture.classify("https://example.com/post?id=3")
        #expect(a.url.absoluteString == "https://example.com/post?id=3")
        #expect(a.key == b.key)                                       // http 和 https 是同一篇
        #expect(a.capturedURL == "http://example.com/post?utm_source=x&id=3")   // 记下你复制的原样
        let w = try Capture.classify("http://mp.weixin.qq.com/s/AbC123")
        #expect(w.url.scheme == "https" && w.key == "wechat:s/AbC123")
        let w2 = try Capture.classify("http://mp.weixin.qq.com/s?__biz=MzI4&mid=1&idx=1&sn=x")
        #expect(w2.url.scheme == "https")
    }

    @Test func failureOnHttpLinkExplainsWhy() throws {
        let f = ExtractFailure(message: "正文过短（0 字）", transient: false)
        let http = try Capture.classify("http://neverssl.example/")
        #expect(Extractors.httpHint(f, http).message.hasPrefix("这个网站可能不支持 https"))
        #expect(Extractors.httpHint(f, http).message.hasSuffix("正文过短（0 字）"))
        let https = try Capture.classify("https://neverssl.example/")
        #expect(Extractors.httpHint(f, https).message == f.message)
        let x = try Capture.classify("http://x.com/a/status/123")
        #expect(Extractors.httpHint(f, x).message == f.message)       // 只对通用网页加这句
    }
}
