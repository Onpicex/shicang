import SwiftUI
import AppKit
@preconcurrency import KeyboardShortcuts
import ShicangCore

extension KeyboardShortcuts.Name {
    /// 全局快捷键：收藏剪贴板里的链接（默认 ⌥⌘S）
    nonisolated(unsafe) static let saveClipboard = Self("saveClipboard", default: .init(.s, modifiers: [.option, .command]))
}

@main
struct ShicangApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("拾藏", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 920, minHeight: 560)
        }
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("从剪贴板收藏") { model.captureClipboard(via: "menu") }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            Image(systemName: model.failed.isEmpty ? "tray.and.arrow.down" : "exclamationmark.triangle")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()          // 要早于 open URL 回调（App 被 shicang:// 拉起时）
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        KeyboardShortcuts.onKeyDown(for: .saveClipboard) {
            AppModel.shared.captureClipboard(via: "hotkey")
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.checkClipboardOffer() }
        }
        EscapeDeselect.install()
        AppLog.shared.say("启动完成 pid=\(ProcessInfo.processInfo.processIdentifier)")
    }

    /// shicang://save?url=…（或 ?text=…）
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls { AppModel.shared.handleOpenURL(u) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
