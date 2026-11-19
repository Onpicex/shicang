import Foundation
import Testing
@testable import ShicangCore

/// 在测试根目录里放一篇文章（直接写 article.json，不联网）
@discardableResult
func plantArticle(_ p: Paths, key: String, title: String, body: [String], author: String? = nil, source: Source = .web,
                  url: String = "https://example.com/a", capturedAt: Date = Date()) throws -> String {
    let id = Capture.hash(key)
    var a = Article(id: id, canonicalId: key, aliases: [], source: source, url: url, capturedURL: url, title: title,
                    author: author, capturedAt: capturedAt, blocks: body.map { .paragraph([Inline($0)]) }, extractor: "test",
                    stats: ArticleStats(chars: 0, images: 0, imagesSaved: 0, videos: 0))
    a.recomputeStats()
    let dir = p.folder(for: id)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try LibraryWriter.writeFiles(a, to: dir)
    return id
}

func fakeAI(_ cat: String, name: String, conf: Double = 0.9, tags: [String] = [], summary: String = "这是摘要。") -> AIResult {
    AIResult(categoryId: cat, categoryName: name, confidence: conf, tags: tags, summary: summary, keyPoints: ["要点一"],
             model: "test", at: Date(), device: "t")
}

@Suite struct SearchTextTests {
    @Test func tokensAreUnigramsAndBigrams() {
        let t = SearchText.indexTokens("黄仁勋谈 AI 芯片，GPT-5 发布").split(separator: " ").map(String.init)
        for x in ["黄", "仁", "勋", "黄仁", "仁勋", "勋谈", "ai", "芯片", "gpt", "5", "发布"] { #expect(t.contains(x), "\(x)") }
        #expect(!t.contains("黄仁勋"))         // 只到二字
        #expect(!t.contains("谈ai"))           // 中英文不跨段
    }

    @Test func fullWidthAndCaseNormalized() {
        let t = SearchText.indexTokens("ＣＬＡＵＤＥ Code").split(separator: " ").map(String.init)
        #expect(t.contains("claude") && t.contains("code"))
    }

    @Test func queryShapes() {
        #expect(SearchText.query("芯")?.match == "\"芯\"")
        #expect(SearchText.query("芯片")?.match == "\"芯片\"")
        #expect(SearchText.query("黄仁勋")?.match == "\"黄仁\" AND \"仁勋\"")
        #expect(SearchText.query("Claude")?.match == "\"claude\"*")
        #expect(SearchText.query("claude 芯片")?.match == "\"claude\" AND \"芯片\"")
        #expect(SearchText.query("  ，。 ") == nil)
        #expect(SearchText.query("「黄仁勋」")?.terms == ["黄仁勋"])
    }

    @Test func snippetAroundHit() {
        let body = String(repeating: "无关内容。", count: 30) + "这里讲到了量化交易的核心思路" + String(repeating: "后文。", count: 30)
        let s = SearchText.snippet(body, terms: ["量化交易"])!
        #expect(s.contains("量化交易") && s.hasPrefix("…") && s.hasSuffix("…"))
    }
}

@Suite struct SearchIndexTests {
    @Test func chineseAndEnglishSearch() async throws {
        let (p, base) = try tempPaths(); defer { try? FileManager.default.removeItem(at: base) }
        let a = try plantArticle(p, key: "web:a", title: "黄仁勋谈芯片供应链", body: ["英伟达的 GPU 需求仍在增长。", "台积电扩产。"], author: "张三")
        let b = try plantArticle(p, key: "web:b", title: "如何用 Claude Code 写测试", body: ["Claude 可以帮你生成单元测试。", "量化交易策略回测。"])
        let c = try plantArticle(p, key: "web:c", title: "周末做饭", body: ["红烧肉的做法：先焯水。", "仁和勋是两个字。"])
        let idx = LibraryIndex(paths: p, deviceId: "t")
        await idx.refresh()
        func ids(_ q: String) async -> Set<String> { Set(await idx.search(q).map(\.id)) }
        #expect(await ids("芯片") == [a])               // 2 字词
        #expect(await ids("黄仁勋") == [a])             // 3 字词（c 里有「仁」「勋」但不连着）
        #expect(await ids("供应链") == [a])
        #expect(await ids("量化交易") == [b])            // 正文命中
        #expect(await ids("claude") == [b])             // 英文，不分大小写
        #expect(await ids("Clau") == [b])               // 边打边搜（前缀）
        #expect(await ids("GPU") == [a])
        #expect(await ids("张三") == [a])               // 作者
        #expect(await ids("红烧肉 焯水") == [c])         // 多词 AND
        #expect(await ids("红烧肉 芯片").isEmpty)
        #expect(await ids("饭") == [c])                 // 单字
        let hit = await idx.search("量化交易").first!
        #expect(hit.snippet?.contains("量化交易") == true)
        // 标题命中排在正文命中前面
        try plantArticle(p, key: "web:d", title: "随笔", body: ["顺便提一句芯片。"])
        await idx.refresh()
        #expect(await idx.search("芯片").first?.id == a)
    }

    @Test func indexPersistsAndPicksUpAIAndDeletes() async throws {
        let (p, base) = try tempPaths(); defer { try? FileManager.default.removeItem(at: base) }
        let a = try plantArticle(p, key: "web:a", title: "标题甲", body: ["正文甲"])
        let idx = LibraryIndex(paths: p, deviceId: "t")
        await idx.refresh()
        #expect(await idx.summary(a)?.categoryId == nil)
        // 写 ai.json（模拟别的设备分好同步过来）
        try AIStore.write(fakeAI("crypto", name: "加密货币与区块链", tags: ["比特币", "DeFi"], summary: "讲稳定币的三句话。"), dir: p.folder(for: a))
        #expect(await idx.refresh())
        let s = await idx.summary(a)!
        #expect(s.categoryId == "crypto" && s.tags == ["比特币", "DeFi"] && s.cardSummary.contains("稳定币"))
        #expect(await idx.search("稳定币").map(\.id) == [a])       // AI 摘要进索引
        #expect(await idx.search("defi").map(\.id) == [a])         // 标签进索引
        #expect(await idx.refresh() == false)                      // 没变化不重读
        // 新开一个索引：从 SQLite 读，不用重新解析
        let idx2 = LibraryIndex(paths: p, deviceId: "t")
        #expect(await idx2.summary(a)?.categoryId == "crypto")
        #expect(await idx2.search("稳定币").map(\.id) == [a])
        // 文件夹没了 → 刷新后从索引里删掉
        try FileManager.default.removeItem(at: p.folder(for: a))
        #expect(await idx2.refresh())
        #expect(await idx2.count == 0)
        #expect(await idx2.search("标题甲").isEmpty)
    }

    @Test func stateOpsAndCorrections() async throws {
        let (p, base) = try tempPaths(); defer { try? FileManager.default.removeItem(at: base) }
        let a = try plantArticle(p, key: "web:a", title: "某篇讲 ETF 的文章", body: ["正文"])
        try AIStore.write(fakeAI("crypto", name: "加密货币与区块链", conf: 0.4, tags: ["ETF"]), dir: p.folder(for: a))
        let idx = LibraryIndex(paths: p, deviceId: "dev-a")
        await idx.refresh()
        #expect(await idx.summary(a)?.needsReview == true)
        await idx.setRead([a], true)
        await idx.setStarred(a, true)
        await idx.setCategory(a, "invest")
        var s = await idx.summary(a)!
        #expect(s.isRead && s.isStarred && s.categoryId == "invest" && !s.needsReview)
        #expect(await idx.taxonomy.corrections.last?.to == "投资理财")
        #expect(await idx.taxonomy.corrections.last?.from == "加密货币与区块链")
        // 改回 AI 的分类：纠正样例撤掉
        await idx.setCategory(a, "crypto")
        #expect(await idx.taxonomy.corrections.isEmpty)
        await idx.setTags(a, ["#基金", "ETF", "etf", " "])
        s = await idx.summary(a)!
        #expect(s.tags == ["基金", "ETF"])
        await idx.setTags(a, nil)
        #expect(await idx.summary(a)?.tags == ["ETF"])
        // 写进 state.json，另一个索引读得到
        let st = StateStore.load(dir: p.folder(for: a))
        #expect(st.isRead && st.isStarred && st.userCategory == "crypto" && st.read?.device == "dev-a")
        // 确认：低置信的 AI 分类定下来
        let b = try plantArticle(p, key: "web:b", title: "乙", body: ["x"])
        try AIStore.write(fakeAI("tech", name: "科技产品与行业", conf: 0.5), dir: p.folder(for: b))
        await idx.refresh()
        #expect(await idx.summary(b)?.needsReview == true)
        await idx.confirmCategory(b)
        #expect(await idx.summary(b)?.needsReview == false)
        #expect(await idx.summary(b)?.categoryId == "tech")
    }

    @Test func taxonomyOpsResolveArticles() async throws {
        let (p, base) = try tempPaths(); defer { try? FileManager.default.removeItem(at: base) }
        let a = try plantArticle(p, key: "web:a", title: "甲", body: ["x"])
        try AIStore.write(fakeAI("tools", name: "网络与效率工具", tags: ["Surge", "代理"]), dir: p.folder(for: a))
        let idx = LibraryIndex(paths: p, deviceId: "t")
        await idx.refresh()
        // 删除分类并入别的分类：文章跟着走
        try await idx.deleteCategory("tools", mergeInto: "dev")
        #expect(await idx.summary(a)?.categoryId == "dev")
        await #expect(throws: LibraryIndex.TaxonomyError.self) { try await idx.deleteCategory("other", mergeInto: "dev") }
        // 新增 + 重名
        let id = try await idx.addCategory(name: "网络与代理", note: "翻墙、路由器")
        await #expect(throws: LibraryIndex.TaxonomyError.self) { try await idx.addCategory(name: "网络与代理", note: nil) }
        #expect(await idx.taxonomy.active.last?.id == "other")      // 「其他」始终最后
        // 可以和已停用的分类同名
        try await idx.updateCategory(id, name: "网络与效率工具", note: nil)
        #expect(await idx.taxonomy.idForName("网络与效率工具") == id)
        // 标签改名/合并/删除
        try await idx.renameTag("代理", to: "网络代理")
        #expect(await idx.summary(a)?.tags == ["Surge", "网络代理"])
        #expect(await idx.search("网络代理").map(\.id) == [a])
        try await idx.renameTag("网络代理", to: "代理")             // 改回去不成环
        #expect(await idx.summary(a)?.tags == ["Surge", "代理"])
        try await idx.deleteTag("surge")
        #expect(await idx.summary(a)?.tags == ["代理"])
        // 配置写进 iCloud/Config，另一台设备（新索引）读到同样结果
        let idx2 = LibraryIndex(paths: p, deviceId: "t2")
        await idx2.refresh()
        #expect(await idx2.summary(a)?.categoryId == "dev")
        #expect(await idx2.summary(a)?.tags == ["代理"])
    }
}

@Suite struct StateMergeTests {
    @Test func fieldLevelMerge() {
        let t0 = Date(timeIntervalSince1970: 1000), t1 = t0.addingTimeInterval(10)
        var a = ArticleState(); a.read = Stamped(true, at: t1, device: "A"); a.starred = Stamped(false, at: t0, device: "A")
        var b = ArticleState(); b.read = Stamped(false, at: t0, device: "B"); b.starred = Stamped(true, at: t1, device: "B")
        b.category = Stamped("ai", at: t0, device: "B")
        let m = a.merged(with: b)
        #expect(m.isRead && m.isStarred && m.userCategory == "ai")
        #expect(m == b.merged(with: a))           // 顺序无关
        // 同一时刻：按设备 id 定赢家，两边一致
        var c = ArticleState(); c.read = Stamped(true, at: t0, device: "A")
        var d = ArticleState(); d.read = Stamped(false, at: t0, device: "B")
        #expect(c.merged(with: d) == d.merged(with: c))
        // 「恢复跟随 AI」也是一个带时间的决定，能盖掉旧的手动分类
        var e = ArticleState(); e.category = Stamped("ai", at: t0)
        var f = ArticleState(); f.category = Stamped(nil, at: t1)
        #expect(e.merged(with: f).userCategory == nil)
    }

    @Test func conflictCopyNames() {
        for n in ["state 2.json", "state (1).json", "state 的副本.json", "state copy.json", "state conflict 3.json"] {
            #expect(ConflictCopies.isCopy(n, base: "state", ext: "json"), "\(n)")
        }
        for n in ["state.json", "states 2.json", "state 2.json.icloud", "article 2.json", "state .json"] {
            #expect(!ConflictCopies.isCopy(n, base: "state", ext: "json"), "\(n)")
        }
    }

    @Test func conflictCopiesMergedAndRemoved() async throws {
        let (p, base) = try tempPaths(); defer { try? FileManager.default.removeItem(at: base) }
        let a = try plantArticle(p, key: "web:a", title: "甲", body: ["x"])
        let dir = p.folder(for: a)
        let t0 = Date(timeIntervalSince1970: 1000)
        var mine = ArticleState(); mine.read = Stamped(true, at: t0.addingTimeInterval(5), device: "A")
        var theirs = ArticleState(); theirs.starred = Stamped(true, at: t0, device: "B"); theirs.read = Stamped(false, at: t0, device: "B")
        try StateStore.write(mine, dir: dir)
        try Coders.encoder.encode(theirs).write(to: dir.appendingPathComponent("state 2.json"))
        let idx = LibraryIndex(paths: p, deviceId: "A")
        await idx.refresh()
        let s = await idx.summary(a)!
        #expect(s.isRead && s.isStarred)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("state 2.json").path))
        let onDisk = StateStore.load(dir: dir, resolve: false)
        #expect(onDisk.isRead && onDisk.isStarred)
        #expect(await idx.refresh() == false)       // 合并写回后签名已更新
    }

    @Test func categoryFileConflictMerge() throws {
        let (p, base) = try tempPaths(); defer { try? FileManager.default.removeItem(at: base) }
        var t = TaxonomyStore.load(p)                          // 写入默认表
        #expect(t.categories.count == 10)
        // 本机：改了 ai 的名字；另一台：新增一类（冲突副本）
        var mine = t.categories
        mine[0].name = "AI"; mine[0].updatedAt = Date(timeIntervalSince1970: 2000)
        try TaxonomyStore.save(categories: mine, p)
        var theirs = Taxonomy.defaultCategories
        theirs.insert(Category(id: "cnew", name: "播客", updatedAt: Date(timeIntervalSince1970: 1500)), at: 9)
        let f = TaxonomyStore.CategoryFile(updatedAt: Date(timeIntervalSince1970: 1500), categories: theirs)
        try Coders.encoder.encode(f).write(to: p.config.appendingPathComponent("categories 2.json"))
        t = TaxonomyStore.load(p)
        #expect(t.category("ai")?.name == "AI")
        #expect(t.category("cnew")?.name == "播客")
        #expect(!FileManager.default.fileExists(atPath: p.config.appendingPathComponent("categories 2.json").path))
    }
}

@Suite struct TaxonomyTests {
    @Test func resolveFollowsMerges() {
        var t = Taxonomy()
        t.categories[1].retired = true; t.categories[1].mergedInto = "ai"      // dev → ai
        #expect(t.resolve("dev") == "ai")
        #expect(t.resolve("nope") == nil)
        var st = ArticleState()
        #expect(t.effectiveCategory(ai: nil, state: st) == nil)
        #expect(t.effectiveCategory(ai: fakeAI("dev", name: "编程与开发"), state: st) == "ai")
        #expect(t.effectiveCategory(ai: fakeAI("gone", name: "投资理财"), state: st) == "invest")     // id 不认识就按名字
        #expect(t.effectiveCategory(ai: fakeAI("gone", name: "不存在"), state: st) == "other")
        st.category = Stamped("life")
        #expect(t.effectiveCategory(ai: fakeAI("dev", name: "编程与开发"), state: st) == "life")
    }

    @Test func tagAliases() {
        var t = Taxonomy()
        t.tagAliases = ["LLM": "大模型", "大语言模型": "大模型", "广告": ""]
        #expect(t.canonicalTags(["llm", "大语言模型", "Claude", "claude", "广告", "大模型"]) == ["大模型", "Claude"])
    }
}

@Suite struct ClassifierTests {
    @Test func endpointBuilding() {
        let crs = AIPreset.find("crs")
        #expect(crs.endpoint(nil) == nil && crs.endpoint("  ") == nil)                              // 自建中继没有默认地址
        #expect(crs.endpoint("https://relay.example.com/api")?.absoluteString == "https://relay.example.com/api/v1/messages")
        #expect(AIPreset.find("anthropic").endpoint(nil)?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(crs.endpoint("http://h:3000/")?.absoluteString == "http://h:3000/api/v1/messages")   // 照写照拼；能不能连由 NetPolicy 判（不能）
        #expect(crs.endpoint("h:3000/api")?.absoluteString == "https://h:3000/api/v1/messages")     // 只填 host 一律 https
        #expect(crs.endpoint("https://h/api/v1")?.absoluteString == "https://h/api/v1/messages")
        #expect(crs.endpoint("https://h/x/v1/messages")?.absoluteString == "https://h/x/v1/messages")
    }

    @Test func promptContainsCategoriesTagsAndCorrections() throws {
        var t = Taxonomy()
        t.categories[2].retired = true; t.categories[2].mergedInto = "dev"
        t.corrections = [Correction(title: "某文", from: "科技产品与行业", to: "投资理财", at: Date()),
                         Correction(title: "旧文", from: nil, to: "已删的类", at: Date())]
        let a = Article(id: "x", canonicalId: "web:x", aliases: [], source: .wechat, url: "u", capturedURL: "u", title: "标题",
                        author: "作者", capturedAt: Date(), blocks: [.paragraph([Inline(String(repeating: "字", count: 5000))])],
                        extractor: "t", stats: ArticleStats(chars: 0, images: 0, imagesSaved: 0, videos: 0))
        let b = ClassifyPrompt.build(a, taxonomy: t, existingTags: ["比特币", "Claude"])
        #expect(b.system.contains("AI 与大模型：大模型") && !b.system.contains("网络与效率工具"))
        #expect(b.system.contains("比特币、Claude"))
        #expect(b.system.contains("《某文》→ 投资理财") && !b.system.contains("已删的类"))
        #expect(b.user.hasPrefix("来源：微信公众号\n标题：标题\n作者：作者"))
        #expect(b.user.filter { $0 == "字" }.count == 3000 + 1)          // 正文截到 3000 字（+「前 3000 字」里的一个）
        let schema = try JSONSerialization.jsonObject(with: b.schemaJSON) as! [String: Any]
        let cat = ((schema["properties"] as! [String: Any])["category"] as! [String: Any])["enum"] as! [String]
        #expect(cat.count == 9 && cat.last == "其他")
    }

    @Test func parseAndNormalize() throws {
        var t = Taxonomy()
        t.tagAliases = ["LLM": "大模型"]
        let json = """
        {"category":"AI 与大模型","confidence":1.3,"tags":["#claude","LLM","大模型"," Agent  框架 ","","\(String(repeating: "长", count: 30))","a","b","c","d","e","f"],
         "summary":" 三句话。 ","key_points":["一"," ","二"]}
        """
        let r = try ClassifyPrompt.parse(json, taxonomy: t, existingTags: ["Claude"], model: "m", device: "d")
        #expect(r.categoryId == "ai" && r.categoryName == "AI 与大模型")
        #expect(r.confidence == 1)
        #expect(r.tags == ["Claude", "大模型", "Agent 框架", "a", "b", "c", "d", "e"])
        #expect(r.summary == "三句话。" && r.keyPoints == ["一", "二"])
        // 代码块包着也能解析；未知分类 → 其他
        let fenced = "```json\n{\"category\":\"火星\",\"confidence\":0.2,\"tags\":[],\"summary\":\"s\",\"key_points\":[]}\n```"
        let r2 = try ClassifyPrompt.parse(fenced, taxonomy: t, existingTags: [], model: "m", device: nil)
        #expect(r2.categoryId == "other" && r2.lowConfidence)
        #expect(throws: AIError.self) { try ClassifyPrompt.parse("我无法分类", taxonomy: t, existingTags: [], model: "m", device: nil) }
    }

    @Test func classifierWithoutKeyStaysQueued() async throws {
        let (p, base) = try tempPaths(); defer { try? FileManager.default.removeItem(at: base) }
        let a = try plantArticle(p, key: "web:a", title: "甲", body: ["x"], capturedAt: Date().addingTimeInterval(-3600))
        let idx = LibraryIndex(paths: p, deviceId: "t")
        await idx.refresh()
        let c = Classifier(paths: p, index: idx, device: DeviceInfo(id: "t", name: "t"), secrets: { Secrets() })
        await c.scan()
        try await Task.sleep(for: .milliseconds(200))
        let st = await c.currentStatus
        #expect(st.phase == .noKey && st.pending == 1)
        #expect(await idx.summary(a)?.ai == nil)
        await c.setEnabled(false)
        #expect(await c.currentStatus.phase == .disabled)
        #expect(Prefs.load(p).classifyEnabled == false)
    }

    @Test func unreachableRelayBacksOff() async throws {
        let (p, base) = try tempPaths(); defer { try? FileManager.default.removeItem(at: base) }
        try plantArticle(p, key: "web:a", title: "甲", body: ["x"])
        let idx = LibraryIndex(paths: p, deviceId: "t")
        await idx.refresh()
        // 127.0.0.1:9 一般没有服务：连接被拒 → 退避，不算文章失败（http 已禁止，用 https）
        let c = Classifier(paths: p, index: idx, device: DeviceInfo(id: "t", name: "t"),
                           secrets: { Secrets(crsBaseURL: "https://127.0.0.1:9", crsAPIKey: "test-key") })
        await c.enqueue(await idx.all.map(\.id))
        var st = await c.currentStatus
        for _ in 0..<50 where st.phase != .waiting { try await Task.sleep(for: .milliseconds(100)); st = await c.currentStatus }
        #expect(st.phase == .waiting && st.pending == 1 && st.retryAt != nil)
        #expect(st.message?.contains("连不上") == true)
    }
}
