import SwiftUI
import AppKit
import WebKit
import ShicangCore

/// 只在测试模式（SHICANG_TEST_ROOT）下生效的调试入口，用来在没有屏幕录制/辅助功能权限时做窗口级验证：
///   shicang://debug/snapshot?name=x      把所有可见窗口画成 PNG（cacheDisplay）+ 阅读器网页快照 → <测试根>/shots/
///   shicang://debug/select?sidebar=all|unread|starred|review|processing|failed|uncategorized|cat:<id>|src:<x>|tag:<t>&article=<id>&index=<n>&search=<q>
///   shicang://debug/state?article=<id>&read=0|1&star=0|1&category=<id>|ai&confirm=1&tags=a,b|ai&addtag=x&reclassify=1
///   shicang://debug/tax?op=add|edit|delete|move|tagrename|tagdelete&id=&name=&note=&into=&by=&old=&new=&tag=
///   shicang://debug/classify?enabled=0|1  /  shicang://debug/reclassify-all
///   shicang://debug/hotkey               走和全局快捷键完全相同的代码路径（读剪贴板 → 入队 → 回执）
///   shicang://debug/check-clipboard      重新探测剪贴板（同「切回窗口」）
///   shicang://debug/accept               点横幅上的「收藏」
///   shicang://debug/drop?file=<路径>     模拟把 .webloc/.url/.txt 文件拖进窗口
///   shicang://debug/settings?tab=general|ai|taxonomy   打开设置窗口
///   shicang://debug/close-main           关掉主窗口
///   shicang://debug/pbset?text=&html=&srcurl=&webarchive=1&waurl=   改剪贴板（第一次先把原内容存进内存）  /  shicang://debug/pbrestore 写回原内容
///   shicang://debug/clip?text=&html=&url=   不经剪贴板直接走「链接 / 剪藏」分流
///   shicang://debug/clip-confirm?title=   点剪藏小窗的「保存」（可先改标题）  /  shicang://debug/clip-cancel 点「取消」
///   shicang://debug/ai-draft?provider=&base=&model=&fallbacks=&key=   改设置页 AI 表单（key 只用假密钥测试）
///   shicang://debug/ai-draft-test | ai-draft-models | ai-draft-save | ai-draft-clearkey   点表单上的按钮
extension AppModel {
    func handleDebug(_ u: URL, _ q: [String: String]) {
        guard let root = testRoot else { AppLog.shared.say("忽略调试指令（非测试模式）"); return }
        let cmd = u.path
        var shown = q
        if shown["key"] != nil { shown["key"] = "***" }
        AppLog.shared.say("调试指令 \(cmd) \(shown.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.prefix(80))" }.joined(separator: " "))")
        switch cmd {
        case "/snapshot":
            Task { await snapshot(name: q["name"] ?? "shot", dir: root.appendingPathComponent("shots")) }
        case "/select":
            if let s = q["sidebar"] { selectSidebar(Self.sidebarItem(s)) }
            if let s = q["search"] { search = s }
            if let a = q["article"] { selectedArticle = a.isEmpty ? nil : a }
            if let a = q["index"], let i = Int(a) {
                Task {
                    await runSearch()
                    try? await Task.sleep(for: .milliseconds(150))     // 同 reveal：等列表画完再选
                    let list = filteredArticles
                    if i < list.count { selectedArticle = list[i].id }
                }
            }
        case "/state":
            guard let id = q["article"] ?? selectedArticle, let s = summary(id) else { return }
            if let v = q["read"] { setRead(id, v == "1") }
            if let v = q["star"], (v == "1") != s.isStarred { toggleStar(s) }
            if let v = q["category"] { setCategory(id, v == "ai" ? nil : v) }
            if q["confirm"] == "1" { confirmCategory(id) }
            if let v = q["tags"] { setTags(id, v == "ai" ? nil : v.split(separator: ",").map(String.init)) }
            if let v = q["addtag"] { addTag(s, v) }
            if let v = q["removetag"] { removeTag(s, v) }
            if q["reclassify"] == "1" { reclassify(id) }
        case "/tax":
            Task {
                do {
                    switch q["op"] ?? "" {
                    case "add": try await addCategory(name: q["name"] ?? "", note: q["note"])
                    case "edit": try await updateCategory(q["id"] ?? "", name: q["name"] ?? "", note: q["note"])
                    case "delete": try await deleteCategory(q["id"] ?? "", into: q["into"] ?? Taxonomy.otherId)
                    case "move": try await moveCategory(q["id"] ?? "", by: Int(q["by"] ?? "") ?? 0)
                    case "tagrename": try await renameTag(q["old"] ?? "", to: q["new"] ?? "")
                    case "tagdelete": try await deleteTag(q["tag"] ?? "")
                    default: break
                    }
                } catch { AppLog.shared.say("调试 tax 失败：\(error)") }
            }
        case "/classify":
            if let v = q["enabled"] { setClassifyEnabled(v == "1") }
        case "/reclassify-all": reclassifyAll()
        case "/hotkey": captureClipboard(via: "hotkey")
        case "/check-clipboard": checkClipboardOffer()
        case "/accept": acceptClipboardOffer()
        case "/drop":
            if let f = q["file"] { Task { await captureDropped(URL(fileURLWithPath: f)) } }
        case "/settings":
            openSettings(["ai": .ai, "taxonomy": .taxonomy][q["tab"] ?? ""] ?? .general)
        case "/close-main":
            NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true || $0.title == "拾藏" }?.close()
        case "/pbset": debugSetPasteboard(q)
        case "/pbrestore": debugRestorePasteboard()
        case "/reader": Task { await debugReader(q) }
        case "/clip":
            route(PasteboardContent(text: q["text"] ?? "", html: q["html"], sourceURL: q["url"]), via: "debug")
        case "/clip-confirm":
            if let t = q["title"] { clipConfirm.draft?.title = t }
            clipConfirm.save()
        case "/clip-cancel": cancelClip()
        case "/ai-draft":
            if let v = q["provider"] { aiDraftLoad(v) }
            let d = aiDraft
            if let v = q["base"] { d.baseURL = v }
            if let v = q["model"] { d.model = v }
            if let v = q["fallbacks"] { d.fallbacks = v }
            if let v = q["key"] { d.newKey = v }
        case "/ai-draft-test": aiDraftTest()
        case "/ai-draft-models": aiDraftFetchModels()
        case "/ai-draft-save":
            do { try aiDraftSave() } catch { AppLog.shared.say("调试 ai-draft-save 失败：\(error)") }
        case "/ai-draft-clearkey":
            do { try aiDraftClearKey() } catch { AppLog.shared.say("调试 ai-draft-clearkey 失败：\(error)") }
        default: break
        }
    }

    private func snapshot(name: String, dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines: [String] = []
        for (i, w) in NSApp.windows.enumerated() where w.isVisible && w.frame.width > 60 && w.frame.height > 30 {
            guard let v = w.contentView?.superview ?? w.contentView else { continue }
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            let f = dir.appendingPathComponent("\(name)-w\(i).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: f)
            lines.append("w\(i) title=\(w.title) id=\(w.identifier?.rawValue ?? "-") frame=\(Int(w.frame.width))x\(Int(w.frame.height)) key=\(w.isKeyWindow) level=\(w.level.rawValue)")
            if let wv = Self.findWebView(v) {
                if let img = try? await wv.takeSnapshot(configuration: nil), let tiff = img.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("\(name)-w\(i)-reader.png"))
                    lines.append("  reader url=\(wv.url?.absoluteString ?? "-")")
                }
            }
        }
        // cacheDisplay 拍不到玻璃材质里的内容（侧栏），所以再附一份界面元素清单（进程内无障碍树，不需要权限）
        for w in NSApp.windows where w.isVisible && w.title == "拾藏" { var warm: [String] = []; Self.dumpAX(w, depth: 0, into: &warm) }
        try? await Task.sleep(for: .milliseconds(400))      // SwiftUI 的无障碍树第一次被问到时才建
        for (i, w) in NSApp.windows.enumerated() where w.isVisible && w.title == "拾藏" {
            var ax: [String] = []
            Self.dumpAX(w, depth: 0, into: &ax)
            try? ax.joined(separator: "\n").write(to: dir.appendingPathComponent("\(name)-w\(i)-ax.txt"), atomically: true, encoding: .utf8)
        }
        lines.append("sidebar=\(String(describing: sidebar)) selected=\(selectedArticle ?? "-") articles=\(articles.count) queue=\(queue.count) banner=\(clipboardOffer) active=\(NSApp.isActive)")
        // 侧栏是玻璃材质拍不到，把侧栏内容（和界面同一份数据）写成文字
        lines.append("侧栏 全部=\(articles.count) 未读=\(count(.unread)) 星标=\(count(.starred)) 待确认=\(count(.review)) 处理中=\(processing.count) 失败=\(failed.count) 未分类=\(count(.uncategorized))")
        lines.append("分类 " + taxonomy.active.map { "\($0.name)(\($0.id))=\(count(.category($0.id)))" }.joined(separator: " "))
        lines.append("来源 " + sourcesPresent.map { "\(sourceName($0.0))=\($0.1)" }.joined(separator: " "))
        lines.append("标签 " + tagCounts.prefix(40).map { "\($0.tag)=\($0.count)" }.joined(separator: " "))
        let st = classifyStatus
        lines.append("AI 平台=\(aiPlatform)(\(aiProvider)) 模型=\(aiModel) ready=\(aiReady)")
        let d = aiDraft
        lines.append("AI 表单 provider=\(d.provider) base=\(d.baseURL) model=\(d.model) fallbacks=\(d.fallbacks) savedHasKey=\(d.savedHasKey) newKey=\(d.newKey.isEmpty ? "空" : "已填") models=\(d.models.count)\(d.models.prefix(5).map { " " + $0 }.joined()) busy=\(d.busy ?? "-") ok=\(d.resultOK) result=\(d.result ?? "-")")
        if let c = clipConfirm.draft {
            let pv = c.preview
            lines.append("剪藏窗 visible=\(clipConfirm.isVisible) via=\(c.via) 标题=\(c.title) 字=\(pv.chars) 图=\(pv.images) rich=\(pv.rich) host=\(pv.host ?? "-") 行=\(pv.lines.count) key=\(NSApp.windows.first { $0.title == "拾藏剪藏" }?.isKeyWindow ?? false)")
        } else {
            lines.append("剪藏窗 无")
        }
        lines.append("AI 分类 enabled=\(classifyEnabled) platform=\(st.platform ?? "-") phase=\(st.phase) pending=\(st.pending) done=\(st.done) model=\(st.lastModel ?? "-") retry=\(st.retryAt.map { timeString($0) } ?? "-") msg=\(st.message ?? "-")")
        lines.append("搜索「\(search)」hits=\(searchHits.map { "\($0.count)" } ?? "nil") 列表=\(filteredArticles.count) 篇")
        for a in filteredArticles.prefix(30) {
            lines.append("  \(a.id == selectedArticle ? "▶" : " ")\(a.isRead ? " " : "●")\(a.isStarred ? "★" : " ") [\(categoryName(a.categoryId) ?? "未分类")\(a.needsReview ? "·待确认" : "")] {\(sourceName(a.source))\(a.highlights.map { " 摘录\($0.count)" } ?? "") 图\(a.imagesSaved)/\(a.images)} \(a.id) \(a.title.prefix(40)) #\(a.tags.joined(separator: " #"))\(snippet(a.id).map { "  ⟨\($0.prefix(60))⟩" } ?? "")")
        }
        lines.append("纠正样例 \(taxonomy.corrections.count) 条" + (taxonomy.corrections.last.map { "，最近：《\($0.title.prefix(20))》\($0.from ?? "-") → \($0.to)" } ?? ""))
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        AppLog.shared.say("快照 \(name)：\(lines.count - 1) 个窗口")
    }

    /// 测试用：改剪贴板。第一次调用先把原来的所有条目、所有类型原样存进内存，/pbrestore 写回（不落盘、不写日志）
    private func debugSetPasteboard(_ q: [String: String]) {
        let pb = NSPasteboard.general
        if debugSavedPasteboard == nil {
            debugSavedPasteboard = (pb.pasteboardItems ?? []).map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }
            AppLog.shared.say("调试：已在内存里保存原剪贴板 \(debugSavedPasteboard!.count) 条")
        }
        let item = NSPasteboardItem()
        if let t = q["text"] { item.setString(t, forType: .string) }
        if let h = q["html"], q["webarchive"] != "1" { item.setString(h, forType: .html) }
        if let u = q["srcurl"] { item.setString(u, forType: PasteboardContent.chromiumSourceURL) }
        if q["webarchive"] == "1", let h = q["html"] {
            var main: [String: Any] = ["WebResourceData": Data(h.utf8), "WebResourceMIMEType": "text/html",
                                       "WebResourceTextEncodingName": "UTF-8", "WebResourceFrameName": ""]
            if let u = q["waurl"] { main["WebResourceURL"] = u }
            if let d = try? PropertyListSerialization.data(fromPropertyList: ["WebMainResource": main], format: .binary, options: 0) {
                item.setData(d, forType: PasteboardContent.webArchive)
            }
        }
        pb.clearContents()
        pb.writeObjects([item])
        AppLog.shared.say("调试：剪贴板已改为测试内容 [\(item.types.map(\.rawValue).joined(separator: ", "))]")
    }

    /// 阅读器里按 CSS 选择器找第 N 个元素，滚到视野中间；click=1 时往窗口发一次鼠标按下/抬起
    /// （事件走 WebKit 自己的点击和链接处理，和真人点一样会进 decidePolicyFor）。页面 JS 是关的，这里是 App 自己执行脚本
    private func debugReader(_ q: [String: String]) async {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.title == "拾藏" }),
              let root = w.contentView?.superview ?? w.contentView, let wv = Self.findWebView(root) else {
            AppLog.shared.say("调试：没找到阅读器"); return
        }
        let sel = q["selector"] ?? "a.copy", i = Int(q["index"] ?? "0") ?? 0
        let js = """
        const all = document.querySelectorAll(sel), el = all[i];
        if (!el) return null;
        el.scrollIntoView({block: 'center'});
        const r = el.getBoundingClientRect();
        return [r.left + r.width / 2, r.top + r.height / 2, all.length];
        """
        let res: Any?
        do { res = try await wv.callAsyncJavaScript(js, arguments: ["sel": sel, "i": i], in: nil, contentWorld: .defaultClient) }
        catch { AppLog.shared.say("调试：阅读器脚本失败 \(error.localizedDescription)"); return }
        guard let a = res as? [Double], a.count == 3 else { AppLog.shared.say("调试：阅读器里没有 \(sel)[\(i)]"); return }
        AppLog.shared.say("调试：阅读器 \(sel)[\(i)]（共 \(Int(a[2])) 个）位置 \(Int(a[0])),\(Int(a[1]))")
        guard q["click"] == "1" else { return }
        try? await Task.sleep(for: .milliseconds(400))
        let p = wv.convert(NSPoint(x: a[0], y: wv.isFlipped ? a[1] : wv.bounds.height - a[1]), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                              pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            w.sendEvent(e)
        }
        AppLog.shared.say("调试：已点击 \(sel)[\(i)]")
    }

    private func debugRestorePasteboard() {
        guard let saved = debugSavedPasteboard else { AppLog.shared.say("调试：没有要恢复的剪贴板"); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let items = saved.map { entries -> NSPasteboardItem in
            let it = NSPasteboardItem()
            for (t, d) in entries { it.setData(d, forType: t) }
            return it
        }
        if !items.isEmpty { pb.writeObjects(items) }
        debugSavedPasteboard = nil
        AppLog.shared.say("调试：剪贴板已恢复 \(items.count) 条")
    }

    static func sidebarItem(_ s: String) -> SidebarItem {
        if s.hasPrefix("cat:") { return .category(String(s.dropFirst(4))) }
        if s.hasPrefix("src:"), let src = Source(rawValue: String(s.dropFirst(4))) { return .source(src) }
        if s.hasPrefix("tag:") { return .tag(String(s.dropFirst(4))) }
        return ["unread": .unread, "starred": .starred, "review": .review, "processing": .processing, "failed": .failed,
                "uncategorized": .uncategorized][s] ?? .all
    }

    private static func dumpAX(_ e: Any, depth: Int, into out: inout [String]) {
        guard depth < 40, out.count < 3000, let el = e as? NSAccessibilityProtocol else { return }
        let role = el.accessibilityRole()?.rawValue ?? "?"
        var bits: [String] = []
        if let l = el.accessibilityLabel(), !l.isEmpty { bits.append("label=\(l)") }
        if let t = el.accessibilityTitle(), !t.isEmpty { bits.append("title=\(t)") }
        if let v = el.accessibilityValue() { let s = "\(v)"; if !s.isEmpty && s.count < 200 { bits.append("value=\(s)") } }
        if el.isAccessibilitySelected() { bits.append("[selected]") }
        let f = el.accessibilityFrame()
        out.append(String(repeating: "  ", count: depth) + role + " " + bits.joined(separator: " ") + " @\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))")
        for c in el.accessibilityChildren() ?? [] { dumpAX(c, depth: depth + 1, into: &out) }
    }

    private static func findWebView(_ v: NSView) -> WKWebView? {
        if let w = v as? WKWebView { return w }
        for s in v.subviews { if let w = findWebView(s) { return w } }
        return nil
    }
}
