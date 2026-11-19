import SwiftUI
import ServiceManagement
@preconcurrency import KeyboardShortcuts
import ShicangCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            GeneralSettings().tabItem { Label("通用", systemImage: "gearshape") }.tag(SettingsTab.general)
            AISettings().tabItem { Label("AI 分类", systemImage: "sparkles") }.tag(SettingsTab.ai)
            TaxonomySettings().tabItem { Label("分类与标签", systemImage: "folder") }.tag(SettingsTab.taxonomy)
        }
        .frame(width: 580)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: 4) {
                KeyboardShortcuts.Recorder("收藏剪贴板：", name: .saveClipboard)
                Text("链接直接收藏原文；一段文字或图文先弹小窗确认再剪藏。只在按快捷键时读一次剪贴板，平时不读。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("登录时自动打开拾藏", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            LabeledContent("数据文件夹") {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("iCloud 云盘 / 拾藏").textSelection(.enabled)
                    Button("在访达中显示") { model.revealDataFolder() }.controlSize(.small)
                }
            }
            LabeledContent("iPhone 快捷指令收件箱") {
                Text("iCloud 云盘 / 快捷指令 / 拾藏Inbox").textSelection(.enabled)
            }
            LabeledContent("本机") { Text(model.device.name) }
            LabeledContent("文件库") { Text("\(model.articles.count) 篇 · 收件箱 \(model.queue.count) 条") }
        }
        .formStyle(.grouped)
    }
}

/// AI 平台设置：同时只用一个平台；密钥只存本机 Application Support/拾藏/secrets.json（600），界面上永远只显示「已设置/未设置」
private struct AISettings: View {
    @Environment(AppModel.self) private var model
    @State private var message: String?
    @State private var confirmAll = false

    var body: some View {
        @Bindable var d = model.aiDraft
        let p = d.preset
        let isActive = loadedActive == d.provider
        Form {
            Section {
                Toggle("收藏后自动分类、写摘要", isOn: Binding(get: { model.classifyEnabled }, set: { model.setClassifyEnabled($0) }))
                LabeledContent("在用") {
                    Text(model.aiModel.isEmpty ? model.aiPlatform : "\(model.aiPlatform) · \(model.aiModel)")
                        .foregroundStyle(model.aiReady ? .primary : .secondary)
                }
                LabeledContent("状态") { statusView }
                LabeledContent("已分类") {
                    let done = model.articles.filter { $0.ai != nil }.count
                    HStack(spacing: 10) {
                        Text("\(done) / \(model.articles.count) 篇\(model.count(.review) > 0 ? " · 待确认 \(model.count(.review))" : "")")
                        Button("全部重新分类…") { confirmAll = true }
                            .controlSize(.small)
                            .disabled(!model.aiReady || !model.classifyEnabled || model.articles.isEmpty)
                    }
                }
            } footer: {
                Text("关掉＝仅保存不分类：新收藏照常抓取保存，以后打开时再补分类。AI 平台连不上也一样先保存，恢复后自动补。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("平台", selection: Binding(get: { d.provider }, set: { model.aiDraftLoad($0); message = nil })) {
                    ForEach(AIPreset.all) { x in Text(x.name).tag(x.id) }
                }
                if !p.note.isEmpty {
                    Text(p.note).font(.caption).foregroundStyle(.secondary)
                }
                TextField("Base URL", text: $d.baseURL, prompt: Text(p.baseURL.isEmpty ? "https://…/v1" : p.baseURL))
                if let u = AIConfig(preset: p, baseURL: AIConfig.clean(d.baseURL)).endpoint, !NetPolicy.allowed(u) {
                    Text(AIConfig.httpBanned).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("模型") {
                    HStack(spacing: 4) {
                        TextField("模型", text: $d.model, prompt: Text(p.model.isEmpty ? "模型 ID" : p.model))
                            .labelsHidden()
                        Menu {
                            if d.modelChoices.isEmpty {
                                Text("没有推荐，点「拉取模型列表」")
                            }
                            ForEach(d.modelChoices, id: \.self) { m in
                                Button(m) { d.model = m }
                            }
                        } label: { Image(systemName: "chevron.down") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("推荐的模型和拉到的列表")
                    }
                }
                TextField("备用模型", text: $d.fallbacks, prompt: Text("可留空；多个用逗号隔开"))
                SecureField("API Key", text: $d.newKey, prompt: Text(keyPrompt(d, p)))
                if p.needsKey && !d.savedHasKey {      // 已设置时输入框里写着「已设置（留空表示不改）」，不再单列一行
                    Text("去哪拿：\(p.keyHint)").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button("拉取模型列表") { model.aiDraftFetchModels() }.disabled(d.busy != nil)
                    Button("测试") { model.aiDraftTest() }.disabled(d.busy != nil)
                    if let b = d.busy {
                        ProgressView().controlSize(.small)
                        Text(b).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if d.savedHasKey {
                        Button("清除密钥", role: .destructive) {
                            do { try model.aiDraftClearKey(); message = "已清除" } catch { message = "清除失败：\(error.localizedDescription)" }
                        }
                    }
                    Button(isActive ? "保存" : "保存并使用") {
                        do { try model.aiDraftSave(); message = "已保存，现在用 \(p.name)" } catch { message = "保存失败：\(error.localizedDescription)" }
                    }
                    .keyboardShortcut(.defaultAction)
                }
                if let r = d.result {
                    Text(r).font(.caption).foregroundStyle(d.resultOK ? .green : .red).textSelection(.enabled)
                } else if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("AI 平台")
            } footer: {
                Text("同时只用一个平台：主模型不可用时依次试同平台的备用模型，整个平台连不上就排队稍后再试，不会自动换到别的平台。「测试」用表单里还没保存的设置发一次真实请求。地址只能用 https，本机 localhost 也一样。密钥只存在本机 ~/Library/Application Support/拾藏/secrets.json（仅你可读），不进 iCloud、不写日志、不进导出。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 640)     // 不定高时窗口只有 450，平台/密钥/测试全在折叠线下；640 在 13 寸屏（可视约 775）也放得下
        .onAppear { model.aiDraftLoad(); message = nil }
        .confirmationDialog("把 \(model.articles.count) 篇全部重新分类？", isPresented: $confirmAll) {
            Button("全部重新分类") { model.reclassifyAll() }
        } message: {
            Text("会按现在的分类表重新跑一遍 AI（每篇十几秒，视平台和模型而定）。手动改过的分类和标签保留不变。")
        }
    }

    /// 存盘里当前在用的平台（和表单里选的不同时，按钮写「保存并使用」）
    private var loadedActive: String { model.aiProvider }

    private func keyPrompt(_ d: AIDraft, _ p: AIPreset) -> String {
        if d.savedHasKey { return "已设置（留空表示不改）" }
        return p.needsKey ? "未设置" : "不需要（平台要求才填）"
    }

    @ViewBuilder private var statusView: some View {
        let st = model.classifyStatus
        switch st.phase {
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("分类中\(st.pending > 1 ? "，还剩 \(st.pending) 篇" : "")")
            }
        case .waiting:
            VStack(alignment: .trailing, spacing: 2) {
                Text("暂停\(st.retryAt.map { "，\(timeString($0)) 自动再试" } ?? "")").foregroundStyle(.orange)
                if let m = st.message { Text(m).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
            }
        case .badKey:
            VStack(alignment: .trailing, spacing: 2) {
                Text("设置有误，改好后点保存").foregroundStyle(.red)
                if let m = st.message { Text(m).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
            }
        case .noKey: Text(st.message ?? "未设置密钥").foregroundStyle(.secondary)
        case .disabled: Text("已关闭（仅保存不分类）").foregroundStyle(.secondary)
        case .idle:
            Text(st.done > 0 ? "空闲 · 本次已分类 \(st.done) 篇" : "空闲").foregroundStyle(.secondary)
        }
    }
}

// MARK: 分类与标签

private struct TaxonomySettings: View {
    @Environment(AppModel.self) private var model
    @State private var selectedCat: String?
    @State private var editing: CategoryDraft?
    @State private var deleting: ShicangCore.Category?
    @State private var selectedTag: String?
    @State private var renamingTag: String?
    @State private var confirmDeleteTag: String?
    @State private var tagFilter = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            categorySection
            tagSection
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(.vertical, 6)
        .sheet(item: $editing) { d in CategoryEditor(draft: d) { editing = nil } }
        .sheet(item: $deleting) { c in CategoryDeleteSheet(category: c) { deleting = nil } }
        .sheet(item: Binding(get: { renamingTag.map(TagRef.init) }, set: { renamingTag = $0?.tag })) { r in
            TagRenameSheet(tag: r.tag) { renamingTag = nil }
        }
        .confirmationDialog("删除标签「\(confirmDeleteTag ?? "")」？", isPresented: Binding(get: { confirmDeleteTag != nil }, set: { if !$0 { confirmDeleteTag = nil } })) {
            Button("删除", role: .destructive) {
                if let t = confirmDeleteTag { run { try await model.deleteTag(t) } }
                confirmDeleteTag = nil
            }
        } message: {
            Text("所有文章上的这个标签都会去掉（所有设备），以后 AI 给出同名标签也会自动去掉。")
        }
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("分类").font(.headline)
            Text("AI 只会从这些分类里选。「说明」会一起发给 AI，写清这一类的边界能让它分得更准。")
                .font(.caption).foregroundStyle(.secondary)
            List(selection: $selectedCat) {
                ForEach(model.taxonomy.active) { c in
                    HStack(alignment: .firstTextBaseline) {
                        Label(c.name, systemImage: categoryIcon(c.id))
                        if let n = c.note, !n.isEmpty {
                            Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("\(model.count(.category(c.id))) 篇").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .tag(c.id)
                    .contextMenu {
                        Button("编辑…") { editing = CategoryDraft(c) }
                        if c.id != Taxonomy.otherId { Button("删除…") { deleting = c } }
                    }
                }
            }
            .frame(height: 250)
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack(spacing: 6) {
                Button { editing = CategoryDraft(nil) } label: { Image(systemName: "plus") }.help("新增分类")
                Button { if let c = selectedCategory { deleting = c } } label: { Image(systemName: "minus") }
                    .disabled(selectedCategory == nil || selectedCat == Taxonomy.otherId).help("删除分类（文章并入别的分类）")
                Button { move(-1) } label: { Image(systemName: "arrow.up") }.disabled(!canMove(-1)).help("上移")
                Button { move(1) } label: { Image(systemName: "arrow.down") }.disabled(!canMove(1)).help("下移")
                Spacer()
                Button("编辑…") { if let c = selectedCategory { editing = CategoryDraft(c) } }.disabled(selectedCategory == nil)
            }
            .controlSize(.small)
        }
    }

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("标签").font(.headline)
                Text("\(model.tagCounts.count) 个").font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("筛选", text: $tagFilter).textFieldStyle(.roundedBorder).frame(width: 160).controlSize(.small)
            }
            Text("改名成已有的标签＝合并（同义词以后也自动归到一起）。").font(.caption).foregroundStyle(.secondary)
            List(filteredTags, id: \.tag, selection: $selectedTag) { t in
                HStack {
                    Text("#\(t.tag)")
                    Spacer()
                    Text("\(t.count) 篇").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .tag(t.tag)
                .contextMenu {
                    Button("改名 / 合并…") { renamingTag = t.tag }
                    Button("删除…", role: .destructive) { confirmDeleteTag = t.tag }
                }
            }
            .frame(height: 170)
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .overlay { if model.tagCounts.isEmpty { Text("还没有标签（AI 分类时会自动打）").font(.caption).foregroundStyle(.secondary) } }
            HStack(spacing: 6) {
                Button("改名 / 合并…") { renamingTag = selectedTag }.disabled(selectedTag == nil)
                Button("删除…") { confirmDeleteTag = selectedTag }.disabled(selectedTag == nil)
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private var selectedCategory: ShicangCore.Category? { model.taxonomy.active.first { $0.id == selectedCat } }

    private var filteredTags: [TagCount] {
        let q = tagFilter.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? model.tagCounts : model.tagCounts.filter { $0.tag.lowercased().contains(q) }
    }

    private func canMove(_ d: Int) -> Bool {
        let ids = model.taxonomy.active.map(\.id)
        guard let id = selectedCat, id != Taxonomy.otherId, let i = ids.firstIndex(of: id) else { return false }
        let j = i + d
        return j >= 0 && j < ids.count && ids[j] != Taxonomy.otherId
    }

    private func move(_ d: Int) {
        guard let id = selectedCat else { return }
        run { try await model.moveCategory(id, by: d) }
    }

    private func run(_ f: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await f(); error = nil } catch { self.error = "\(error)" }
        }
    }
}

private struct TagRef: Identifiable { let tag: String; var id: String { tag } }

struct CategoryDraft: Identifiable {
    let id = UUID()
    var categoryId: String?
    var name: String
    var note: String
    init(_ c: ShicangCore.Category?) { categoryId = c?.id; name = c?.name ?? ""; note = c?.note ?? "" }
}

private struct CategoryEditor: View {
    @Environment(AppModel.self) private var model
    @State var draft: CategoryDraft
    let done: () -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.categoryId == nil ? "新增分类" : "编辑分类").font(.headline)
            Form {
                TextField("名称", text: $draft.name, prompt: Text("比如：播客与音频"))
                TextField("说明（给 AI 看）", text: $draft.note, prompt: Text("这一类包括什么、不包括什么"), axis: .vertical)
                    .lineLimit(2...4)
            }
            .formStyle(.grouped)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { done() }.keyboardShortcut(.cancelAction)
                Button(draft.categoryId == nil ? "添加" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private func save() {
        Task {
            do {
                let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = draft.categoryId {
                    try await model.updateCategory(id, name: draft.name, note: note.isEmpty ? nil : note)
                } else {
                    try await model.addCategory(name: draft.name, note: note.isEmpty ? nil : note)
                }
                done()
            } catch { self.error = "\(error)" }
        }
    }
}

private struct CategoryDeleteSheet: View {
    @Environment(AppModel.self) private var model
    let category: ShicangCore.Category
    let done: () -> Void
    @State private var target = Taxonomy.otherId
    @State private var error: String?

    var body: some View {
        let n = model.count(.category(category.id))
        VStack(alignment: .leading, spacing: 12) {
            Text("删除分类「\(category.name)」").font(.headline)
            Picker("这类的 \(n) 篇文章并入", selection: $target) {
                ForEach(model.taxonomy.active.filter { $0.id != category.id }) { c in Text(c.name).tag(c.id) }
            }
            Text("文章文件不会改动；在别的设备上也一样生效。").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { done() }.keyboardShortcut(.cancelAction)
                Button("删除", role: .destructive) {
                    Task {
                        do { try await model.deleteCategory(category.id, into: target); done() } catch { self.error = "\(error)" }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 400)
    }
}

private struct TagRenameSheet: View {
    @Environment(AppModel.self) private var model
    let tag: String
    let done: () -> Void
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        let target = name.trimmingCharacters(in: .whitespaces)
        let existing = model.tagCounts.first { $0.tag.caseInsensitiveCompare(target) == .orderedSame && $0.tag != tag }
        VStack(alignment: .leading, spacing: 12) {
            Text("标签「#\(tag)」改名").font(.headline)
            TextField("新名字", text: $name).textFieldStyle(.roundedBorder)
            if let e = existing {
                Text("已有标签「#\(e.tag)」（\(e.count) 篇），会合并成一个。").font(.caption).foregroundStyle(.orange)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { done() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "改名" : "合并") {
                    Task {
                        do { try await model.renameTag(tag, to: existing?.tag ?? target); done() } catch { self.error = "\(error)" }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(target.isEmpty || target == tag)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear { name = tag }
    }
}
