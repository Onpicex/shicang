import SwiftUI
import ShicangCore

struct SaveRefused: LocalizedError { let errorDescription: String? }

/// 设置页「AI 分类」表单的未保存状态。放在 AppModel 里，测试模式的调试指令能和按钮走同一套代码。
@MainActor @Observable
final class AIDraft {
    var provider = AIPreset.defaultId
    var baseURL = ""
    var model = ""
    var fallbacks = ""
    var newKey = ""
    var savedHasKey = false
    var models: [String] = []          // 「拉取模型列表」拿到的
    var busy: String?                  // 测试中… / 拉取中…
    var result: String?
    var resultOK = false

    var preset: AIPreset { AIPreset.find(provider) }

    static func parseList(_ s: String) -> [String] {
        s.split(whereSeparator: { ",，、;；\n".contains($0) || $0 == " " }).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 模型下拉：预设推荐 + 拉到的列表（去重，推荐在前）
    var modelChoices: [String] {
        var seen = Set<String>()
        return (preset.suggestions + models).filter { seen.insert($0).inserted }
    }
}

extension AppModel {
    /// 当前生效的设置（测试模式 + SHICANG_TEST_USE_APP_KEY=1 时，测试目录里没填的密钥借正式设置的，只读、不复制）
    func loadSecrets() -> Secrets {
        useAppKey ? Self.mergedSecrets(test: paths, std: Paths.standard()) : SecretStore.load(paths)
    }

    nonisolated static func mergedSecrets(test: Paths, std: Paths) -> Secrets {
        var s = SecretStore.load(test)
        let real = SecretStore.load(std)
        if !FileManager.default.fileExists(atPath: SecretStore.url(test).path) { s.activeProvider = real.activeProvider }
        for (id, p) in real.providers {
            if s.providers[id] == nil { s.providers[id] = p }
            else if AIConfig.clean(s.providers[id]?.apiKey) == nil { s.providers[id]?.apiKey = p.apiKey }
        }
        return s
    }

    func refreshAIState() {
        let s = loadSecrets()
        let a = s.active
        aiProvider = s.activeProvider
        aiReady = a.isReady
        aiPlatform = a.preset.name
        aiModel = a.effectiveModel
    }

    /// 打开设置页 / 切换平台时：把这个平台存过的设置填进表单（没存过就填预设默认值）
    func aiDraftLoad(_ provider: String? = nil) {
        let s = loadSecrets()
        let id = provider ?? s.activeProvider
        let c = s.config(for: id)
        let d = aiDraft
        if d.provider != id { d.provider = id }
        d.baseURL = AIConfig.clean(c.baseURL) ?? c.preset.baseURL
        d.model = c.effectiveModel
        d.fallbacks = c.effectiveFallbacks.joined(separator: ", ")
        d.newKey = ""
        d.savedHasKey = c.hasKey
        d.models = []
        d.result = nil
        d.busy = nil
    }

    /// 表单里（还没保存）的设置；密钥框留空＝用存过的
    func aiDraftConfig() -> AIConfig {
        let d = aiDraft
        let saved = loadSecrets().config(for: d.provider)
        return AIConfig(preset: d.preset, baseURL: AIConfig.clean(d.baseURL), model: AIConfig.clean(d.model),
                        fallbacks: AIDraft.parseList(d.fallbacks), apiKey: AIConfig.clean(d.newKey) ?? saved.apiKey)
    }

    /// 平台返回的错误里万一带了密钥原文，替换掉再显示/写日志
    private func redact(_ s: String, _ cfg: AIConfig) -> String {
        guard let k = cfg.key, k.count >= 6 else { return s }
        return s.replacingOccurrences(of: k, with: "***")
    }

    func aiDraftTest() {
        let d = aiDraft
        let cfg = aiDraftConfig()
        let tax = taxonomy
        d.busy = "测试中…"
        d.result = nil
        AppLog.shared.say("AI 测试开始：\(cfg)")
        Task {
            let r = await AITester.run(cfg, taxonomy: tax)
            guard d.provider == cfg.preset.id else { return }
            d.busy = nil
            switch r {
            case .success(let s): d.result = s; d.resultOK = true
            case .failure(let e): d.result = redact(e.description, cfg); d.resultOK = false
            }
            AppLog.shared.say("AI 测试 \(cfg.preset.id) \(cfg.effectiveModel) → \(d.result ?? "")")
        }
    }

    func aiDraftFetchModels() {
        let d = aiDraft
        var cfg = aiDraftConfig()
        if cfg.effectiveModel.isEmpty { cfg.model = "-" }       // 拉列表不需要模型，只是 AIClient 要求填了
        guard let client = AIClient(config: cfg, timeout: 20) else {
            d.result = cfg.missing.map { "拉不了：\($0)" } ?? "设置不完整"; d.resultOK = false
            return
        }
        d.busy = "拉取中…"
        d.result = nil
        Task {
            do {
                let list = try await client.listModels()
                guard d.provider == cfg.preset.id else { return }
                d.models = list
                d.result = list.isEmpty ? "平台没有返回模型" : "拉到 \(list.count) 个模型，点模型右边的箭头选"
                d.resultOK = !list.isEmpty
            } catch {
                guard d.provider == cfg.preset.id else { return }
                d.result = "拉取失败：" + redact((error as? AIError)?.description ?? error.localizedDescription, cfg)
                d.resultOK = false
            }
            d.busy = nil
            AppLog.shared.say("拉取模型列表 \(cfg.preset.id) → \(d.result ?? "")")
        }
    }

    /// 保存＝切到这个平台并使用；地址/模型/备用和预设默认值一样就不写（以后预设更新能跟上）
    func aiDraftSave() throws {
        let d = aiDraft
        let p = d.preset
        var s = SecretStore.load(paths)                 // 只写本目录的文件（测试模式不会把借来的正式密钥写进测试目录）
        var e = s.providers[p.id] ?? AIProviderSettings()
        let base = AIConfig.clean(d.baseURL)
        if let u = AIConfig(preset: p, baseURL: base).endpoint, !NetPolicy.allowed(u) {   // 不允许 http：不存，免得存进去才发现分类停了
            throw SaveRefused(errorDescription: AIConfig.httpBanned)
        }
        e.baseURL = base == p.baseURL ? nil : base
        let m = AIConfig.clean(d.model)
        e.model = m == p.model ? nil : m
        let fb = AIDraft.parseList(d.fallbacks)
        e.fallbacks = fb == p.fallbacks ? nil : fb
        if let k = AIConfig.clean(d.newKey) { e.apiKey = k }
        s.providers[p.id] = e
        s.activeProvider = p.id
        try SecretStore.save(s, paths)
        d.newKey = ""
        d.savedHasKey = loadSecrets().config(for: p.id).hasKey
        refreshAIState()
        let c = processor.classifier
        Task { await c.secretsChanged() }
        AppLog.shared.say("AI 设置已保存：\(loadSecrets())")
    }

    func aiDraftClearKey() throws {
        let d = aiDraft
        var s = SecretStore.load(paths)
        s.providers[d.provider]?.apiKey = nil
        try SecretStore.save(s, paths)
        d.newKey = ""
        d.savedHasKey = loadSecrets().config(for: d.provider).hasKey
        refreshAIState()
        let c = processor.classifier
        Task { await c.secretsChanged() }
        AppLog.shared.say("\(d.preset.name) 密钥已清除")
    }
}
