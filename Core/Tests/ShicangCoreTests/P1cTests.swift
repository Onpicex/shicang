import Foundation
import Testing
@testable import ShicangCore

// MARK: 假服务器：只拦 *.mock 域名，按域名分派

final class MockAI: URLProtocol, @unchecked Sendable {
    struct Seen: @unchecked Sendable { var path: String; var headers: [String: String]; var body: [String: Any]? }
    typealias Handler = @Sendable (_ path: String, _ headers: [String: String], _ body: [String: Any]) -> (Int, String)
    nonisolated(unsafe) static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) static var seen: [String: [Seen]] = [:]
    static let lock = NSLock()

    static func install() {
        lock.lock(); defer { lock.unlock() }
        if AIClient.testProtocolClasses == nil { AIClient.testProtocolClasses = [MockAI.self] }
    }
    static func on(_ host: String, _ h: @escaping Handler) { install(); lock.lock(); handlers[host] = h; seen[host] = []; lock.unlock() }
    static func requests(_ host: String) -> [Seen] { lock.lock(); defer { lock.unlock() }; return seen[host] ?? [] }

    override class func canInit(with r: URLRequest) -> Bool { r.url?.host?.hasSuffix(".mock") == true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        let host = request.url?.host ?? ""
        var data = request.httpBody
        if data == nil, let s = request.httpBodyStream {
            s.open(); defer { s.close() }
            var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            data = d
        }
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let headers = (request.allHTTPHeaderFields ?? [:]).reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        MockAI.lock.lock()
        let h = MockAI.handlers[host]
        MockAI.seen[host, default: []].append(Seen(path: request.url?.path ?? "", headers: headers, body: body))
        MockAI.lock.unlock()
        let (code, text) = h?(request.url?.path ?? "", headers, body) ?? (404, "{}")
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func chat(_ content: String, model: String = "m") -> String {
        let obj: [String: Any] = ["model": model, "choices": [["message": ["role": "assistant", "content": content], "finish_reason": "stop"]],
                                  "usage": ["prompt_tokens": 10, "completion_tokens": 5]]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }
    static func messages(_ text: String, model: String) -> String {
        let obj: [String: Any] = ["model": model, "stop_reason": "end_turn", "content": [["type": "text", "text": text]],
                                  "usage": ["input_tokens": 10, "output_tokens": 5]]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }
    static let goodJSON = #"{"category":"编程与开发","confidence":0.9,"tags":["SQLite","搜索"],"summary":"一。二。三。","key_points":["甲","乙"]}"#
}

// MARK: 平台预设与设置

@Suite struct AIProviderTests {
    @Test func presetEndpoints() {
        func ep(_ id: String, _ base: String?) -> String? { AIPreset.find(id).endpoint(base)?.absoluteString }
        #expect(ep("openai", nil) == "https://api.openai.com/v1/chat/completions")
        #expect(ep("gemini", nil) == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        #expect(ep("deepseek", nil) == "https://api.deepseek.com/v1/chat/completions")
        #expect(ep("qwen", nil) == "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
        #expect(ep("zhipu", nil) == "https://open.bigmodel.cn/api/paas/v4/chat/completions")
        #expect(ep("zhipu", "open.bigmodel.cn") == "https://open.bigmodel.cn/api/paas/v4/chat/completions")      // 只填域名
        #expect(ep("doubao", "https://ark.cn-beijing.volces.com/api/v3/") == "https://ark.cn-beijing.volces.com/api/v3/chat/completions")
        #expect(ep("custom", "localhost:11434/v1") == "https://localhost:11434/v1/chat/completions")   // 本机也补 https
        #expect(ep("custom", "https://x.example/v1/chat/completions") == "https://x.example/v1/chat/completions")
        #expect(ep("custom", nil) == nil)
        #expect(ep("anthropic", nil) == "https://api.anthropic.com/v1/messages")
        #expect(AIPreset.find("不存在").id == AIPreset.defaultId && AIPreset.defaultId == "anthropic")
        let p = AIPreset.find("openai")
        #expect(p.modelsURL(p.endpoint(nil)!)?.absoluteString == "https://api.openai.com/v1/models")
        #expect(Set(AIPreset.all.map(\.id)).count == AIPreset.all.count)
    }

    @Test func configChainAndReadiness() {
        var c = AIConfig(preset: AIPreset.find("anthropic"))
        #expect(c.modelChain == ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"])
        #expect(!c.isReady && c.missing == "未设置密钥")
        c.apiKey = "  "
        #expect(!c.hasKey)
        c.apiKey = "k"
        #expect(c.isReady && c.missing == nil)
        c.model = "claude-sonnet-5-5"                     // 主模型和备用重复：去掉
        #expect(c.modelChain == ["claude-sonnet-5-5", "claude-haiku-5-5"])
        c.fallbacks = []                                  // 不要备用
        #expect(c.modelChain == ["claude-sonnet-5-5"])
        let noKey = AIConfig(preset: AIPreset.find("custom"), baseURL: "https://llm.example/v1", model: "m")
        #expect(noKey.isReady)                            // 「其他」平台密钥可不填
        var custom = AIConfig(preset: AIPreset.find("custom"))
        #expect(custom.missing == "没填地址")
        custom.baseURL = "https://x.example/v1"
        #expect(custom.missing == "没填模型")
        custom.model = "m"
        #expect(custom.isReady)
    }

    @Test func secretsLegacyAndV2() throws {
        // 早期版本的旧文件
        let old = Data(#"{"crsBaseURL":"http://h:3000","crsAPIKey":"sk-legacy-123"}"#.utf8)
        let s = try JSONDecoder().decode(Secrets.self, from: old)
        #expect(s.activeProvider == "crs" && s.active.key == "sk-legacy-123" && s.active.baseURL == "http://h:3000")
        #expect(!s.isReady && s.active.missing?.contains("https://") == true)   // 不允许 http：旧的 http 地址能读出来，但不可用、提示改 https
        let oldHttps = try JSONDecoder().decode(Secrets.self, from: Data(#"{"crsBaseURL":"https://h/api","crsAPIKey":"sk-legacy-123"}"#.utf8))
        #expect(oldHttps.isReady)
        let oldNoURL = try JSONDecoder().decode(Secrets.self, from: Data(#"{"crsAPIKey":"sk-legacy-123"}"#.utf8))
        #expect(oldNoURL.activeProvider == "crs" && oldNoURL.active.missing == "没填地址")   // 自建中继没有默认地址
        // 新格式往返；旧字段不再写出
        var v2 = s
        v2.providers["deepseek"] = AIProviderSettings(model: "deepseek-v4-pro", apiKey: "sk-ds-456")
        v2.activeProvider = "deepseek"
        let d = try JSONEncoder().encode(v2)
        let txt = String(data: d, encoding: .utf8)!
        #expect(!txt.contains("crsAPIKey") && txt.contains("\"schema\":2"))
        let back = try JSONDecoder().decode(Secrets.self, from: d)
        #expect(back == v2 && back.active.effectiveModel == "deepseek-v4-pro" && back.config(for: "crs").key == "sk-legacy-123")
        // 打日志永远不出现密钥
        for desc in [String(describing: back), String(reflecting: back), "\(back.active)", "\(back.providers["deepseek"]!)"] {
            #expect(!desc.contains("sk-ds-456") && !desc.contains("sk-legacy-123"))
        }
        // 旧属性仍可读写
        var t = Secrets()
        t.crsAPIKey = "x"
        #expect(t.providers["crs"]?.apiKey == "x" && t.config(for: "crs").hasKey)
        #expect(t.activeProvider == AIPreset.defaultId)
    }

    @Test func lenientParse() throws {
        let t = Taxonomy()
        let messy = """
        <think>先想想 {"category":"错的"}</think>
        好的，结果如下：
        ```json
        {"category":"「编程与开发」","confidence":"85","tags":"SQLite、全文搜索, 中文","summary":["一。","二。"],"keyPoints":"甲\\n乙"}
        ```
        """
        let r = try ClassifyPrompt.parse(messy, taxonomy: t, existingTags: [], model: "m", device: nil)
        #expect(r.categoryId == "dev" && r.confidence == 0.85)
        #expect(r.tags == ["SQLite", "全文搜索", "中文"] && r.summary == "一。二。" && r.keyPoints == ["甲", "乙"])
        // 只有分类也行
        let r2 = try ClassifyPrompt.parse(#"{"category":"投资理财"}"#, taxonomy: t, existingTags: [], model: "m", device: nil)
        #expect(r2.categoryId == "invest" && r2.confidence == 0.5 && r2.tags.isEmpty)
        #expect(throws: AIError.self) { try ClassifyPrompt.parse(#"{"tags":["a"]}"#, taxonomy: t, existingTags: [], model: "m", device: nil) }
    }
}

// MARK: 客户端（假服务器）

@Suite struct AIClientTests {
    func prompt() -> ClassifyPrompt.Built {
        let a = Article(id: "x", canonicalId: "web:x", aliases: [], source: .web, url: "u", capturedURL: "u", title: "标题",
                        author: nil, capturedAt: Date(), blocks: [.paragraph([Inline("正文")])], extractor: "t",
                        stats: ArticleStats(chars: 2, images: 0, imagesSaved: 0, videos: 0))
        return ClassifyPrompt.build(a, taxonomy: Taxonomy(), existingTags: [])
    }

    @Test func openAIStructuredOutput() async throws {
        MockAI.on("ok.mock") { _, _, _ in (200, MockAI.chat(MockAI.goodJSON, model: "gpt-x")) }
        let c = AIClient(config: AIConfig(preset: AIPreset.find("openai"), baseURL: "https://ok.mock/v1", model: "gpt-x", apiKey: "sk-test"))!
        let p = prompt()
        let r = try await c.call(model: "gpt-x", system: p.system, user: p.user, schemaJSON: p.schemaJSON, schemaName: "classification", formatHint: p.formatHint)
        #expect(r.jsonMode == "schema" && r.model == "gpt-x" && r.text.contains("编程与开发"))
        let req = MockAI.requests("ok.mock")
        #expect(req.count == 1 && req[0].path == "/v1/chat/completions")
        #expect(req[0].headers["authorization"] == "Bearer sk-test")
        let b = req[0].body!
        #expect(b["max_completion_tokens"] as? Int == 8000 && b["max_tokens"] == nil)       // OpenAI 新模型要用 max_completion_tokens
        #expect(b["reasoning_effort"] as? String == "low")
        #expect((b["response_format"] as? [String: Any])?["type"] as? String == "json_schema")
        let sys = ((b["messages"] as! [[String: Any]])[0]["content"] as! String)
        #expect(sys.contains("输出格式：只输出一个 JSON 对象"))
    }

    @Test func openAIDowngradesUntilAccepted() async throws {
        // 不认 reasoning_effort、不认 json_schema，只认 json_object 的服务
        MockAI.on("ladder.mock") { _, _, b in
            if b["reasoning_effort"] != nil { return (400, #"{"error":{"message":"unknown field reasoning_effort"}}"#) }
            if (b["response_format"] as? [String: Any])?["type"] as? String == "json_schema" { return (400, #"{"error":{"message":"json_schema unsupported"}}"#) }
            return (200, MockAI.chat("```json\n" + MockAI.goodJSON + "\n```"))
        }
        let c = AIClient(config: AIConfig(preset: AIPreset.find("gemini"), baseURL: "https://ladder.mock/v1beta/openai", model: "g1", apiKey: "k"))!
        let p = prompt()
        let r = try await c.call(model: "g1", system: p.system, user: p.user, schemaJSON: p.schemaJSON, formatHint: p.formatHint)
        #expect(r.jsonMode == "object")
        #expect(MockAI.requests("ladder.mock").count == 3)
        // 第二次直接用试出来的方式
        _ = try await c.call(model: "g1", system: p.system, user: p.user, schemaJSON: p.schemaJSON, formatHint: p.formatHint)
        #expect(MockAI.requests("ladder.mock").count == 4)
        let parsed = try ClassifyPrompt.parse(r.text, taxonomy: Taxonomy(), existingTags: [], model: r.model, device: nil)
        #expect(parsed.categoryId == "dev")
    }

    @Test func systemPromptIgnoredMovesIntoUserMessage() async throws {
        // 有的中转站把 system 换成自己的提示词（实测 CRS 的 OpenAI 兼容接口就是）：回的是一段话，不是 JSON
        MockAI.on("nosys.mock") { _, _, b in
            let msgs = b["messages"] as? [[String: Any]] ?? []
            if msgs.contains(where: { $0["role"] as? String == "system" }) { return (200, MockAI.chat("这篇文章讲的是 SQLite……")) }
            let u = msgs.first?["content"] as? String ?? ""
            return u.contains("输出格式") && u.contains("正文") ? (200, MockAI.chat(MockAI.goodJSON)) : (200, MockAI.chat("?"))
        }
        let c = AIClient(config: AIConfig(preset: AIPreset.find("custom"), baseURL: "https://nosys.mock/v1", model: "m"))!
        let p = prompt()
        let r = try await c.call(model: "m", system: p.system, user: p.user, schemaJSON: p.schemaJSON, formatHint: p.formatHint)
        #expect(r.jsonMode == "schema+inline" && MockAI.requests("nosys.mock").count == 2)
        _ = try await c.call(model: "m", system: p.system, user: p.user, schemaJSON: p.schemaJSON, formatHint: p.formatHint)
        #expect(MockAI.requests("nosys.mock").count == 3)            // 记住了，第二次一发就中
        let t = await AITester.run(AIConfig(preset: AIPreset.find("custom"), baseURL: "https://nosys.mock/v1", model: "m"), taxonomy: Taxonomy())
        if case .success(let m) = t { #expect(m.contains("已改放进用户消息")) } else { Issue.record("\(t)") }
    }

    @Test func errorMapping() async throws {
        MockAI.on("e401.mock") { _, _, _ in (401, #"{"error":{"message":"Invalid API key"}}"#) }
        MockAI.on("e404.mock") { _, _, _ in (404, #"{"error":{"message":"model not found"}}"#) }
        MockAI.on("e429.mock") { _, _, _ in (429, #"{"error":{"message":"rate limited"}}"#) }
        MockAI.on("e400.mock") { _, _, _ in (400, #"{"error":{"message":"bad"}}"#) }
        let p = prompt()
        func run(_ host: String) async -> AIError? {
            let c = AIClient(config: AIConfig(preset: AIPreset.find("custom"), baseURL: "https://\(host)/v1", model: "m"))!
            do { _ = try await c.call(model: "m", system: p.system, user: p.user, schemaJSON: p.schemaJSON); return nil }
            catch { return error as? AIError }
        }
        if case .unauthorized(let m) = await run("e401.mock") { #expect(m.contains("Invalid API key")) } else { Issue.record("401 应为 unauthorized") }
        if case .config(let m) = await run("e404.mock") { #expect(m.contains("404")) } else { Issue.record("404 应为 config") }
        if case .http(429, _) = await run("e429.mock") {} else { Issue.record("429 应为 http") }
        #expect(AIError.http(429, "").transient)
        if case .config(let m) = await run("e400.mock") { #expect(m.contains("400")) } else { Issue.record("首次 400 应为 config") }
        #expect(MockAI.requests("e400.mock").count == 3)        // json_schema → json_object → 只靠提示词，都被拒才报错
    }

    @Test func anthropicRequestShape() async throws {
        MockAI.on("crs.mock") { _, _, _ in (200, MockAI.messages(MockAI.goodJSON, model: "claude-opus-5-5")) }
        let c = AIClient(config: AIConfig(preset: AIPreset.find("crs"), baseURL: "https://crs.mock:3000", apiKey: "cr_test"))!
        let p = prompt()
        let r = try await c.call(model: "claude-opus-5-5", system: p.system, user: p.user, schemaJSON: p.schemaJSON)
        #expect(r.model == "claude-opus-5-5")
        let s = MockAI.requests("crs.mock")[0]
        #expect(s.path == "/api/v1/messages" && s.headers["x-api-key"] == "cr_test" && s.headers["anthropic-version"] == "2023-06-01")
        let oc = s.body!["output_config"] as! [String: Any]
        #expect(oc["effort"] as? String == "low" && (oc["format"] as? [String: Any])?["type"] as? String == "json_schema")
    }

    @Test func listModels() async throws {
        MockAI.on("models.mock") { path, _, _ in path == "/v1/models" ? (200, #"{"data":[{"id":"b"},{"id":"a"},{"id":"b"}]}"#) : (404, "{}") }
        let c = AIClient(config: AIConfig(preset: AIPreset.find("custom"), baseURL: "https://models.mock/v1", model: "m"))!
        #expect(try await c.listModels() == ["a", "b"])
    }

    @Test func testerReportsMode() async throws {
        MockAI.on("tester.mock") { _, _, _ in (200, MockAI.chat(MockAI.goodJSON, model: "ds")) }
        let r = await AITester.run(AIConfig(preset: AIPreset.find("deepseek"), baseURL: "https://tester.mock/v1", apiKey: "k"), taxonomy: Taxonomy())
        guard case .success(let msg) = r else { Issue.record("应成功：\(r)"); return }
        #expect(msg.contains("ds") && msg.contains("JSON 模式") && msg.contains("编程与开发"))
        let b = MockAI.requests("tester.mock")[0].body!
        #expect((b["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        let bad = await AITester.run(AIConfig(preset: AIPreset.find("deepseek")), taxonomy: Taxonomy())
        if case .failure(.config(let m)) = bad { #expect(m == "未设置密钥") } else { Issue.record("没密钥应直接报") }
    }

    @Test func classifierUsesActivePlatformAndFallbackModel() async throws {
        let (p, base) = try tempPaths(); defer { try? FileManager.default.removeItem(at: base) }
        let id = try plantArticle(p, key: "web:fb", title: "SQLite 中文搜索", body: ["FTS5 切字"])
        let idx = LibraryIndex(paths: p, deviceId: "t")
        await idx.refresh()
        // 主模型 503（暂时不可用）→ 同平台备用模型
        MockAI.on("fb.mock") { _, _, b in
            (b["model"] as? String) == "main" ? (503, #"{"error":{"message":"overloaded"}}"#) : (200, MockAI.chat(MockAI.goodJSON, model: "backup"))
        }
        let secrets = Secrets(activeProvider: "custom", providers: [
            "custom": AIProviderSettings(baseURL: "https://fb.mock/v1", model: "main", fallbacks: ["backup"]),
            "crs": AIProviderSettings(apiKey: "不该用到"),
        ])
        let c = Classifier(paths: p, index: idx, device: DeviceInfo(id: "t", name: "t"), secrets: { secrets })
        await c.enqueue([id])
        for _ in 0..<50 where await idx.summary(id)?.ai == nil { try await Task.sleep(for: .milliseconds(100)) }
        let ai = await idx.summary(id)?.ai
        #expect(ai?.categoryId == "dev" && ai?.model == "backup")
        #expect(await c.currentStatus.platform == "其他（OpenAI 兼容）")
        #expect(MockAI.requests("fb.mock").map { $0.body?["model"] as? String } == ["main", "backup"])
    }

    @Test func classifierStopsOnBadModel() async throws {
        let (p, base) = try tempPaths(); defer { try? FileManager.default.removeItem(at: base) }
        try plantArticle(p, key: "web:bad", title: "甲", body: ["x"])
        let idx = LibraryIndex(paths: p, deviceId: "t")
        await idx.refresh()
        MockAI.on("bad.mock") { _, _, _ in (404, #"{"error":{"message":"The model `nope` does not exist"}}"#) }
        let secrets = Secrets(activeProvider: "deepseek", providers: ["deepseek": AIProviderSettings(baseURL: "https://bad.mock/v1", model: "nope", apiKey: "k")])
        let c = Classifier(paths: p, index: idx, device: DeviceInfo(id: "t", name: "t"), secrets: { secrets })
        await c.enqueue(await idx.all.map(\.id))
        var st = await c.currentStatus
        for _ in 0..<50 where st.phase != .badKey { try await Task.sleep(for: .milliseconds(100)); st = await c.currentStatus }
        #expect(st.phase == .badKey && st.pending == 1)
        #expect(st.message?.contains("DeepSeek nope") == true && st.message?.contains("404") == true)
        #expect(MockAI.requests("bad.mock").count == 1)        // 地址/模型不对：不再试备用、不重试，等用户改
    }
}

// MARK: 剪藏

@Suite struct ClipTests {
    @Test func linkOrClipDecision() {
        // 写了协议的链接：不管旁边有多少字都按链接
        #expect(Clip.looksLikeLink("https://example.com/a"))
        #expect(Clip.looksLikeLink("好文 https://mp.weixin.qq.com/s/abc 推荐"))
        #expect(Clip.looksLikeLink(String(repeating: "很长的正文。", count: 40) + " http://example.com/x"))
        // 只有裸域名：整段就是它才算链接
        #expect(Clip.looksLikeLink("example.com/post/1"))
        #expect(Clip.looksLikeLink(" www.example.com/a \n"))
        #expect(!Clip.looksLikeLink("我们把代码都放在 github.com 上，文档写在 notion.so 里，这样团队协作比较方便。"))
        #expect(!Clip.looksLikeLink("一段没有任何网址的话"))
        #expect(!Clip.looksLikeLink("联系 someone@example.com"))
        // 有协议的优先于前面的裸域名
        #expect(Capture.firstURL(in: "在 github.com 看到的：https://example.com/real")?.absoluteString == "https://example.com/real")
        #expect(Capture.highlight(in: "github.com " + String(repeating: "长", count: 120) + " https://example.com/real")?.contains("github.com") == true)
    }

    @Test func plainTextParagraphsAndTitle() {
        let input = ClipInput(text: "  读书笔记\n第二行\n\n\n第二段   \n")
        let ex = Clip.build(input, capturedAt: Date())
        #expect(ex.article.source == .clip && ex.article.url == "" && ex.article.extractor == Clip.extractorText)
        #expect(ex.article.blocks.count == 2 && ex.article.blocks[0].plainText == "读书笔记\n第二行" && ex.article.blocks[1].plainText == "第二段")
        #expect(ex.article.title == "读书笔记")
        #expect(ex.rawSnapshots.map(\.0) == ["source.txt"])
        // 标题：长第一行取到第一个句号；再不行截断
        #expect(Clip.suggestedTitle(ClipInput(text: "这是一段很长的话。后面还有很多很多很多很多很多很多很多很多很多很多很多很多很多很多很多很多很多字")) == "这是一段很长的话。")
        let long = String(repeating: "长", count: 60)
        #expect(Clip.suggestedTitle(ClipInput(text: long)) == String(repeating: "长", count: 36) + "…")
        // 用户填的标题优先
        #expect(Clip.build(ClipInput(text: "x", title: " 我的标题 "), capturedAt: Date()).article.title == "我的标题")
    }

    @Test func dedupKeyIgnoresWhitespace() {
        #expect(Clip.key(ClipInput(text: "a  b\n c")) == Clip.key(ClipInput(text: "a b c")))
        #expect(Clip.key(ClipInput(text: "a b c")) != Clip.key(ClipInput(text: "a b d")))
        #expect(Clip.key(ClipInput(text: "")).isEmpty == false)
        #expect(Clip.sourceURL(ClipInput(text: "", sourceURL: "file:///x")) == nil)
        #expect(Clip.sourceURL(ClipInput(text: "", sourceURL: " https://a.example/p ")) != nil)
    }

    @Test func richHTMLKeepsFormatAndImages() {
        let html = """
        <meta charset="utf-8"><h2>为什么要写作</h2><p>写作是<b>思考</b>的工具，<a href="/post/2">链接</a>。</p>
        <ul><li>第一条</li><li>第二条</li></ul><blockquote>引用一句</blockquote>
        <img src="https://img.example/a.png" alt="图"><img src="file:///Users/x/b.png"><img src="/rel.png">
        """
        let text = "为什么要写作\n写作是思考的工具，链接。\n第一条\n第二条\n引用一句"
        let ex = Clip.build(ClipInput(text: text, html: html, sourceURL: "https://blog.example/post/1"), capturedAt: Date())
        let a = ex.article
        #expect(a.extractor == Clip.extractorHTML && a.title == "为什么要写作")
        #expect(a.url == "https://blog.example/post/1" && ex.imageReferer == "https://blog.example/post/1")
        let kinds = a.blocks.map(\.type)
        #expect(kinds.contains(.heading) && kinds.contains(.listItem) && kinds.contains(.quote))
        #expect(a.blocks.contains { ($0.inlines ?? []).contains { $0.bold == true && $0.text == "思考" } })
        // 本机文件图去掉；相对路径按来源页补全
        let imgs = a.blocks.compactMap(\.image).map(\.url)
        #expect(imgs == ["https://img.example/a.png", "https://blog.example/rel.png"])
        #expect(ex.rawSnapshots.map(\.0) == ["source.txt", "source.html"])
        let pv = Clip.preview(ClipInput(text: text, html: html, sourceURL: "https://blog.example/post/1"))
        #expect(pv.rich && pv.images == 2 && pv.host == "blog.example" && pv.lines.first == "为什么要写作")
    }

    @Test func htmlMismatchFallsBackToText() {
        // HTML 只有一小部分（或混进大量隐藏内容）：不信它，按纯文字存
        let ex = Clip.build(ClipInput(text: String(repeating: "正文很长。", count: 40), html: "<p>只有一句</p>"), capturedAt: Date())
        #expect(ex.article.extractor == Clip.extractorText)
        let code = #"<div style="white-space: pre;"><div>func a() {</div><div>    return 1</div><div>}</div></div>"#
        let ex2 = Clip.build(ClipInput(text: "func a() {\n    return 1\n}", html: code), capturedAt: Date())
        #expect(ex2.article.blocks.count == 1 && ex2.article.blocks[0].type == .code && ex2.article.blocks[0].text == "func a() {\n    return 1\n}")
    }

    @Test func highlightFromShareText() {
        #expect(Capture.highlight(in: "看看这个 https://x.com/a/status/1") == nil)                 // 短分享文案不算
        let long = String(repeating: "这段话我很喜欢。", count: 20)
        let h = Capture.highlight(in: "\(long)\nhttps://mp.weixin.qq.com/s/abc")
        #expect(h == long)
        #expect(Capture.highlight(in: long) == nil)                                               // 没链接：走剪藏，不是摘录
    }

    @Test func highlightStoreAppendDedupAndConflicts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hl-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try HighlightStore.append("x", dir: dir, device: nil) == false)                   // 文件夹不存在不建
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try HighlightStore.append("第一段", dir: dir, device: "Mac", at: t0) == true)
        #expect(try HighlightStore.append(" 第一段 ", dir: dir, device: "Mac") == false)          // 重复
        // 另一台设备同时写出来的冲突副本：合并后删掉
        let other = try Coders.encoder.encode(HighlightStore.File(items: [Highlight(text: "第二段", at: t0.addingTimeInterval(-60), device: "iPhone")]))
        try other.write(to: dir.appendingPathComponent("highlights 2.json"))
        let all = HighlightStore.load(dir: dir)
        #expect(all.map(\.text) == ["第二段", "第一段"])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("highlights 2.json").path))
        #expect(HighlightStore.load(dir: dir).count == 2)
    }
}

// MARK: 处理器：剪藏与摘录

@Suite struct ClipProcessorTests {
    @Test func saveClipThenDedup() async throws {
        let (p, base) = try tempPaths(); defer { try? FileManager.default.removeItem(at: base) }
        let proc = Processor(paths: p, device: DeviceInfo(id: "d", name: "Mac"), secrets: { Secrets() })
        await proc.setPaused(true)
        try await proc.start()
        let input = ClipInput(text: "一段想留下来的话\n\n第二段", title: "随手记")
        let r = await proc.saveClip(input, via: "clipboard")
        guard case .clipped(let id, let title) = r else { Issue.record("应剪藏：\(r.message)"); return }
        #expect(title == "随手记" && r.message.hasPrefix("已剪藏"))
        let s = await proc.index.summary(id)
        #expect(s?.source == .clip && s?.title == "随手记" && s?.chars ?? 0 > 0)
        let dir = p.folder(for: id)
        for f in ["article.json", "article.md", "source.txt.gz"] {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path), "\(f)")
        }
        let r2 = await proc.saveClip(ClipInput(text: "一段想留下来的话 第二段"), via: "clipboard")
        guard case .exists(let id2, _) = r2 else { Issue.record("同一段应已存在：\(r2.message)"); return }
        #expect(id2 == id)
        guard case .rejected = await proc.saveClip(ClipInput(text: "  \n "), via: "clipboard") else { Issue.record("空的应拒绝"); return }
        // 阅读页：没有原文链接
        let art = try Coders.decoder.decode(Article.self, from: Data(contentsOf: dir.appendingPathComponent("article.json")))
        let html = ReaderHTML.render(art, ai: nil)
        #expect(!html.contains("原文 ↗") && html.contains("剪藏"))
        let withSrc = Clip.build(ClipInput(text: "x", sourceURL: "https://blog.example/p"), capturedAt: Date()).article
        #expect(ReaderHTML.render(withSrc, ai: nil).contains("来自 <a href=\"https://blog.example/p\">blog.example ↗</a>"))
    }

    @Test func longShareTextBecomesHighlight() async throws {
        let (p, base) = try tempPaths(); defer { try? FileManager.default.removeItem(at: base) }
        let proc = Processor(paths: p, device: DeviceInfo(id: "d", name: "Mac"), secrets: { Secrets() })
        await proc.setPaused(true)
        try await proc.start()
        let passage = String(repeating: "原文里打动我的一段话。", count: 12)
        // 还没存过：排队，摘录跟着排队项走，分享文字不再当分享文案
        let r = await proc.enqueue("\(passage)\nhttps://example.com/post/9", via: "hotkey")
        guard case .queued(let item) = r else { Issue.record("应入队：\(r.message)"); return }
        #expect(item.highlight == passage && item.shareText == nil)
        // 排队中又来一段：合并
        let p2 = String(repeating: "另一段。", count: 30)
        _ = await proc.enqueue("https://example.com/post/9 \(p2)", via: "hotkey")
        #expect(await proc.queue().first?.item.highlight == passage + Processor.highlightSeparator + p2)

        // 已经存过的文章：直接加进摘录
        let id = try plantArticle(p, key: "web:https://example.com/post/8", title: "已存的文章", body: ["正文"], url: "https://example.com/post/8")
        await proc.index.refresh()
        let t = try Capture.classify("https://example.com/post/8")
        #expect(Capture.hash(t.key) == id)
        let r3 = await proc.enqueue("https://example.com/post/8\n\(passage)", via: "hotkey")
        guard case .highlightAdded(let hid, let title) = r3 else { Issue.record("应加摘录：\(r3.message)"); return }
        #expect(hid == id && title == "已存的文章" && r3.message.hasPrefix("已加到摘录"))
        #expect(HighlightStore.load(dir: p.folder(for: id)).map(\.text) == [passage])
        #expect(await proc.index.summary(id)?.highlights == [passage])
        guard case .exists = await proc.enqueue("https://example.com/post/8\n\(passage)", via: "hotkey") else { Issue.record("同一段再来应只提示已存在"); return }
        guard case .exists = await proc.enqueue("https://example.com/post/8 看看", via: "hotkey") else { Issue.record("短文案应只提示已存在"); return }
        // 搜索能搜到摘录里的字
        #expect(await proc.index.search("打动").map(\.id).contains(id))
        let art = try Coders.decoder.decode(Article.self, from: Data(contentsOf: p.folder(for: id).appendingPathComponent("article.json")))
        let html = ReaderHTML.render(art, ai: nil, highlights: HighlightStore.load(dir: p.folder(for: id)))
        #expect(html.contains("我的摘录") && html.contains("打动我的一段话"))
    }
}

@Test func imageTypeSniffing() {
    #expect(ImageFetcher.sniffExt(Data([0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x10, 0x10, 0, 0, 0, 0])) == "ico")
    #expect(ImageFetcher.sniffExt(Data([0, 0, 0, 0x1C, 0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69, 0x66])) == "avif")
    #expect(ImageFetcher.sniffExt(Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])) == "heic")
    #expect(ImageFetcher.sniffExt(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])) == "png")
    #expect(ImageFetcher.sniffExt(Data("<svg xmlns".utf8)) == nil)      // SVG 靠 Content-Type 判
}
