import SwiftUI
import AppKit
import WebKit
import ShicangCore

/// 只在测试模式（SHICANG_TEST_ROOT）下生效的调试入口，用来在没有屏幕录制/辅助功能权限时做窗口级验证：
///   shicang://debug/snapshot?name=x      把所有可见窗口画成 PNG（cacheDisplay）+ 阅读器网页快照 → <测试根>/shots/
///   shicang://debug/select?sidebar=all|unread|starred|review|processing|failed|uncategorized|cat:<id>|src:<x>|tag:<t>&article=<id>&index=<n>&search=<q>
///                         &articles=<id>,<id>  /  &indexes=0,2,5  多选（直接改选中集合）  /  &all=1 全选  /  &none=1 取消选择
///   shicang://debug/batch?op=read|unread|star|unstar|category&cat=<id>|ai|confirm|reclassify|copy|trash   对选中的多篇批量操作（trash 不弹确认）
///   shicang://debug/key?code=51 | key?code=0&chars=a&cmd=1   列表先成为焦点，再往窗口发一次按键（51＝Delete；带 cmd 的走窗口和菜单栏的快捷键匹配）
///     &via=app：不带 cmd 的按键改走 NSApp.sendEvent（和真按键一样先过 App 内按键监听，如 Esc 取消多选）；&focus=search：焦点放到搜索框而不是列表
///   shicang://debug/press?label=<按钮文字>&index=<n>   在主窗口的无障碍树里找第 n 个文字相符的按钮，走它自己的按下动作（和真人点一样进按钮的 action）
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
///   shicang://debug/list?scroll=N | list?row=N&select=1   中栏文章列表：滚到第 N 行 / 让表格选中第 N 行（快照里看换成了哪个文章 id）
///   shicang://debug/list?row=N&menu=1   在第 N 行上模拟右键，取出列表要弹的菜单，把菜单项写进日志（不弹出来）
///   shicang://debug/list?row=N&menu=1&pick=标题   同上，再点其中标题相同的那一项（子菜单里的也行）
///   shicang://debug/list?rows=0,2,3&select=1   让表格一次选中多行（和 ⌘/⇧ 点按同一条路）
///   shicang://debug/list?selectall=1&via=menu|table   ⌘A：via=menu 找菜单栏里 ⌘A 那一项，把它的动作发给列表（列表先成为焦点）；via=table 直接调表格的全选
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
            if let a = q["articles"] { selection = Set(a.split(separator: ",").map(String.init)) }
            if q["all"] == "1" { selectAll() }
            if q["none"] == "1" { selection = [] }
            if let a = q["indexes"] {
                let list = filteredArticles
                selection = Set(a.split(separator: ",").compactMap { Int($0) }.filter { $0 < list.count }.map { list[$0].id })
            }
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
        case "/batch":
            let ids = selectedIds
            switch q["op"] ?? "" {
            case "read": setRead(ids: ids, true)
            case "unread": setRead(ids: ids, false)
            case "star": setStarred(ids: ids, true)
            case "unstar": setStarred(ids: ids, false)
            case "category": setCategory(ids: ids, q["cat"] == "ai" ? nil : q["cat"])
            case "confirm": confirmCategory(ids: ids)
            case "reclassify": reclassify(ids: ids)
            case "copy": copyLinks(ids)
            case "trash": trash(ids: ids)
            default: AppLog.shared.say("调试：不认识的批量操作")
            }
        case "/press": debugPress(q)
        case "/key": debugKey(q)
        case "/list": Task { await debugList(q) }
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
        lines.append("sidebar=\(String(describing: sidebar)) selected=\(selectedArticle ?? "-") 选中=\(selection.count) 篇 articles=\(articles.count) queue=\(queue.count) banner=\(clipboardOffer) active=\(NSApp.isActive)")
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
            lines.append("  \(selection.contains(a.id) ? "▶" : " ")\(a.isRead ? " " : "●")\(a.isStarred ? "★" : " ") [\(categoryName(a.categoryId) ?? "未分类")\(a.needsReview ? "·待确认" : "")] {\(sourceName(a.source))\(a.highlights.map { " 摘录\($0.count)" } ?? "") 图\(a.imagesSaved)/\(a.images)} \(a.id) \(a.title.prefix(40)) #\(a.tags.joined(separator: " #"))\(snippet(a.id).map { "  ⟨\($0.prefix(60))⟩" } ?? "")")
        }
        // 列表的行高、选中行、滚动位置（新插入的行高度被卡在 24 时一眼能看出来）
        for w in NSApp.windows where w.isVisible && w.title == "拾藏" {
            if let v = w.contentView { Self.dumpTables(v, into: &lines) }
        }
        // 剪贴板只在测试改过（/pbset 存了原内容）时才写进快照，不碰用户自己的剪贴板内容
        if debugSavedPasteboard != nil {
            let pb = NSPasteboard.general.string(forType: .string) ?? ""
            lines.append("剪贴板（测试内容）\(pb.split(separator: "\n").count) 行：\(pb.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(300))")
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

    private static func dumpTables(_ v: NSView, into lines: inout [String]) {
        if let t = v as? NSTableView {
            let heights = (0..<min(t.numberOfRows, 30)).map { String(format: "%.0f", t.rect(ofRow: $0).height) }
            let top = t.rows(in: t.visibleRect).location
            lines.append("表格 \(t is NSOutlineView ? "outline" : "table") 行=\(t.numberOfRows) 选中=\(t.selectedRow) 已选行=\(t.selectedRowIndexes.map(String.init).joined(separator: ",")) 可多选=\(t.allowsMultipleSelection) 顶行=\(top) 滚动=\(Int(t.visibleRect.minY)) 行高=\(heights.joined(separator: " "))")
        }
        for s in v.subviews { dumpTables(s, into: &lines) }
    }

    /// 中栏文章列表＝窗口里最靠右的 NSOutlineView（侧栏也是一个）
    private static func articleTable(_ w: NSWindow) -> NSOutlineView? { ListSelectionSync.articleTable() }

    private func debugList(_ q: [String: String]) async {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.title == "拾藏" }), let t = Self.articleTable(w) else {
            AppLog.shared.say("调试：没找到文章列表"); return
        }
        if let rows = q["rows"], q["select"] == "1" {
            let set = IndexSet(rows.split(separator: ",").compactMap { Int($0) }.filter { $0 < t.numberOfRows })
            t.selectRowIndexes(set, byExtendingSelection: false)
            AppLog.shared.say("调试：列表选中 \(set.count) 行"); return
        }
        if q["selectall"] == "1" {
            let fr = w.makeFirstResponder(t)
            if q["via"] == "table" {
                t.selectAll(nil)
                AppLog.shared.say("调试：表格全选（焦点 \(fr)）"); return
            }
            // 菜单栏里 ⌘A 那一项（SwiftUI 默认的「编辑 › 全选」），把它的动作沿焦点链发出去
            func find(_ m: NSMenu) -> NSMenuItem? {
                for i in m.items {
                    if i.keyEquivalent == "a", i.keyEquivalentModifierMask == .command { return i }
                    if let sub = i.submenu, let x = find(sub) { return x }
                }
                return nil
            }
            guard let item = NSApp.mainMenu.flatMap(find), let action = item.action else {
                AppLog.shared.say("调试：菜单栏里没有 ⌘A"); return
            }
            let ok = w.firstResponder?.tryToPerform(action, with: item) ?? false
            AppLog.shared.say("调试：菜单「\(item.title)」⌘A → \(NSStringFromSelector(action))，焦点 \(type(of: w.firstResponder!))，处理=\(ok)")
            return
        }
        if let n = q["scroll"].flatMap(Int.init), n < t.numberOfRows {
            t.scrollRowToVisible(n)
            AppLog.shared.say("调试：列表滚到第 \(n) 行，顶行 \(t.rows(in: t.visibleRect).location)")
        }
        guard let n = q["row"].flatMap(Int.init), n < t.numberOfRows else { return }
        t.scrollRowToVisible(n)
        try? await Task.sleep(for: .milliseconds(300))
        let r = t.rect(ofRow: n)
        let p = t.convert(NSPoint(x: r.midX, y: r.midY), to: nil)
        if q["menu"] == "1" {
            guard let e = NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let m = t.menu(for: e) else { AppLog.shared.say("调试：第 \(n) 行没有右键菜单"); return }
            // 照 AppKit 弹右键菜单的顺序走：表格 willOpenMenu → 菜单 willOpen → …… → 菜单 didClose → 表格 didCloseMenu → 再发菜单项的动作
            t.willOpenMenu(m, with: e)
            m.delegate?.menuNeedsUpdate?(m)
            m.delegate?.menuWillOpen?(m)
            m.update()
            try? await Task.sleep(for: .milliseconds(200))
            func dump(_ m: NSMenu, _ pre: String) -> [String] {
                m.items.flatMap { i -> [String] in
                    let me = i.isSeparatorItem ? "—" : "\(i.title)\(i.isEnabled ? "" : "(灰)")\(i.state == .on ? "✓" : "")"
                    return [pre + me] + (i.submenu.map { sub in sub.delegate?.menuNeedsUpdate?(sub); return dump(sub, pre + "  ") } ?? [])
                }
            }
            AppLog.shared.say("调试：第 \(n) 行右键菜单：" + dump(m, "").joined(separator: " | "))
            m.delegate?.menuDidClose?(m)
            t.didCloseMenu(m, with: e)
            if let want = q["pick"] {     // 再点其中一项（含子菜单），走菜单项自己的动作
                func find(_ m: NSMenu) -> (NSMenu, Int)? {
                    for (i, it) in m.items.enumerated() {
                        if it.title == want { return (m, i) }
                        if let sub = it.submenu, let r = find(sub) { return r }
                    }
                    return nil
                }
                guard let (pm, i) = find(m) else { AppLog.shared.say("调试：右键菜单里没有「\(want)」"); return }
                let enabled = pm.items[i].isEnabled
                pm.performActionForItem(at: i)
                AppLog.shared.say("调试：右键菜单点了「\(want)」\(enabled ? "" : "（灰的）")")
            }
            return
        }
        if q["select"] == "1" {      // 走表格自己的选中（和鼠标、键盘选中同一条路），看 SwiftUI 把它换成哪个文章 id
            t.selectRowIndexes(IndexSet(integer: n), byExtendingSelection: false)
            AppLog.shared.say("调试：列表选中第 \(n) 行"); return
        }
        AppLog.shared.say("调试：列表第 \(n) 行位置 \(Int(p.x)),\(Int(p.y))")
    }

    private func debugKey(_ q: [String: String]) {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.title == "拾藏" }), let t = Self.articleTable(w) else { return }
        if q["focus"] == "search", let f = Self.searchField(w.contentView?.superview ?? w.contentView) {
            w.makeFirstResponder(f)
        } else {
            w.makeFirstResponder(t)
        }
        let code = UInt16(q["code"] ?? "51") ?? 51
        let chars = q["chars"] ?? (code == 51 ? "\u{7f}" : "")
        let cmd = q["cmd"] == "1"
        var how = ""
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: cmd ? .command : [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                                           characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { continue }
            if cmd && type == .keyDown {
                let byWindow = w.performKeyEquivalent(with: e)
                let byMenu = byWindow ? false : (NSApp.mainMenu?.performKeyEquivalent(with: e) ?? false)
                how = "窗口=\(byWindow) 菜单=\(byMenu)"
            } else if !cmd {
                if q["via"] == "app" { NSApp.sendEvent(e) } else { w.sendEvent(e) }
            }
        }
        AppLog.shared.say("调试：按键 code=\(code)\(cmd ? " ⌘" : "") 已发送 \(how) 焦点 \(w.firstResponder.map { "\(type(of: $0))" } ?? "-") 选中 \(AppModel.shared.selection.count) 篇")
    }

    private static func searchField(_ v: NSView?) -> NSSearchField? {
        guard let v else { return nil }
        if let f = v as? NSSearchField { return f }
        for s in v.subviews { if let f = searchField(s) { return f } }
        return nil
    }

    /// 主窗口无障碍树里找按钮（文字＝label 或 title），走 accessibilityPerformPress（SwiftUI 按钮会执行它的 action）
    private func debugPress(_ q: [String: String]) {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.title == "拾藏" }), let want = q["label"] else { return }
        var hits: [NSAccessibilityProtocol] = []
        func walk(_ e: Any, _ depth: Int) {
            guard depth < 40, let el = e as? NSAccessibilityProtocol else { return }
            let role = el.accessibilityRole()
            if role == .button || role == .menuButton || role == .popUpButton,
               el.accessibilityLabel() == want || el.accessibilityTitle() == want { hits.append(el) }
            for c in el.accessibilityChildren() ?? [] { walk(c, depth + 1) }
        }
        walk(w, 0)
        let i = Int(q["index"] ?? "0") ?? 0
        if i < hits.count {
            let ok = hits[i].accessibilityPerformPress()
            AppLog.shared.say("调试：按下「\(want)」[\(i)/\(hits.count)] → \(ok)"); return
        }
        // SwiftUI 的内容不进进程内无障碍树：再在视图树里找真正的 NSButton（含弹出的确认框窗口），走 performClick
        var buttons: [NSButton] = []
        func walkView(_ v: NSView) { if let b = v as? NSButton { buttons.append(b) }; v.subviews.forEach(walkView) }
        for win in NSApp.windows where win.isVisible { if let v = win.contentView?.superview ?? win.contentView { walkView(v) } }
        let match = buttons.filter { $0.title == want || $0.accessibilityLabel() == want || $0.alternateTitle == want }
        guard i < match.count else {
            let names = buttons.map { $0.title.isEmpty ? ($0.accessibilityLabel() ?? "?") : $0.title }.filter { !$0.isEmpty }
            AppLog.shared.say("调试：没找到按钮「\(want)」，视图里的按钮：\(names.prefix(40).joined(separator: " / "))"); return
        }
        match[i].performClick(nil)
        AppLog.shared.say("调试：点了按钮「\(want)」[\(i)/\(match.count)]（\(type(of: match[i]))）")
    }

    private static func findWebView(_ v: NSView) -> WKWebView? {
        if let w = v as? WKWebView { return w }
        for s in v.subviews { if let w = findWebView(s) { return w } }
        return nil
    }
}
