import SwiftUI
import AppKit
import ShicangCore

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("从剪贴板收藏") { model.captureClipboard(via: "menu") }
        Divider()
        Text(statusLine)
        if !model.articles.isEmpty {
            Section("最近收藏") {
                ForEach(model.articles.prefix(5)) { s in
                    Button(String(s.title.prefix(32))) { open(s.id) }
                }
            }
        }
        Divider()
        Button("打开拾藏") { open(nil) }
        SettingsLink { Text("设置…") }
        Divider()
        Button("退出拾藏") { NSApp.terminate(nil) }
    }

    private var statusLine: String {
        let p = model.processing.count, f = model.failed.count
        if p == 0 && f == 0 { return "文件库 \(model.articles.count) 篇 · 队列空" }
        return "处理中 \(p) · 失败 \(f)"
    }

    private func open(_ id: String?) {
        if let id { model.reveal(id) }
        openWindow(id: "main")
        NSApp.activate()
    }
}
