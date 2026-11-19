import SwiftUI
import AppKit
import ShicangCore

/// 收藏回执：屏幕右上角浮出、不抢焦点、不挡鼠标，约 2 秒后淡出。
@MainActor
final class HUDController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ r: EnqueueResult) {
        switch r {
        case .queued(let i):
            show(title: "已收到", detail: i.displayTitle, symbol: "checkmark.circle.fill", tint: .green)
        case .alreadyQueued(let i):
            show(title: i.status == .failed ? "已重新排队" : "已在队列中", detail: i.displayTitle, symbol: "clock.fill", tint: .blue)
        case .exists(_, let title):
            show(title: "已经收藏过", detail: title, symbol: "books.vertical.fill", tint: .purple)
        case .highlightAdded(_, let title):
            show(title: "已加到摘录", detail: title, symbol: "text.quote", tint: .teal)
        case .clipped(_, let title):
            show(title: "已剪藏", detail: title, symbol: "doc.on.clipboard.fill", tint: .green)
        case .rejected(let why):
            show(title: "没有收藏", detail: why, symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    func show(title: String, detail: String?, symbol: String, tint: Color) {
        let root = HUDView(title: title, detail: detail, symbol: symbol, tint: tint)
        let host = NSHostingView(rootView: root)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let p = panel ?? makePanel()
        panel = p
        p.contentView = host
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            p.setFrame(NSRect(x: vf.maxX - size.width - 18, y: vf.maxY - size.height - 14, width: size.width, height: size.height), display: true)
        }
        p.alphaValue = 1
        p.orderFrontRegardless()
        AppLog.shared.say("回执浮层：\(title)\(detail.map { " · " + $0 } ?? "")")

        hideTask?.cancel()
        hideTask = Task { [weak p] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled, let p else { return }
            await NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                p.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            p.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 64),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.title = "拾藏回执"
        return p
    }
}

private struct HUDView: View {
    let title: String
    let detail: String?
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                if let detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 250, alignment: .leading)     // 固定宽度：fittingSize 会把可换行文字压到最窄
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .padding(2)
    }
}
