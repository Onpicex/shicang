import SwiftUI
import AppKit
import ShicangCore

// MARK: 读剪贴板（只在用户按快捷键 / 点菜单 / 点横幅「收藏」时调用）

/// 剪贴板里和收藏有关的几样：纯文字、带格式的 HTML、来源网页地址
struct PasteboardContent: Sendable {
    var text: String
    var html: String?
    var sourceURL: String?
    var types: [String] = []

    static let chromiumSourceURL = NSPasteboard.PasteboardType("org.chromium.source-url")
    static let webArchive = NSPasteboard.PasteboardType("com.apple.webarchive")

    @MainActor static func read(_ pb: NSPasteboard = .general) -> PasteboardContent {
        var text = pb.string(forType: .string) ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let u = pb.string(forType: .URL) { text = u }
        var html = pb.string(forType: .html)
        var src = pb.string(forType: chromiumSourceURL)                      // Chrome / Edge / Arc 等
        if let d = pb.data(forType: webArchive), let w = parseWebArchive(d) {  // Safari：网页归档里有 HTML 和来源页
            if html == nil || html!.isEmpty { html = w.html }
            if src == nil { src = w.url }
        }
        return PasteboardContent(text: text, html: html, sourceURL: src, types: (pb.types ?? []).map(\.rawValue))
    }

    static func parseWebArchive(_ d: Data) -> (html: String?, url: String?)? {
        guard let plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
              let main = plist["WebMainResource"] as? [String: Any] else { return nil }
        var html: String?
        if let data = main["WebResourceData"] as? Data {
            var enc = String.Encoding.utf8
            if let name = main["WebResourceTextEncodingName"] as? String {
                let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
                if cf != kCFStringEncodingInvalidId { enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)) }
            }
            html = String(data: data, encoding: enc) ?? String(data: data, encoding: .utf8)
        }
        return (html, main["WebResourceURL"] as? String)
    }

    /// 日志里只记类型和长度，不记内容
    var logLine: String {
        let kinds = types.map { t -> String in
            switch t {
            case NSPasteboard.PasteboardType.string.rawValue: return "文字"
            case NSPasteboard.PasteboardType.html.rawValue: return "HTML"
            case NSPasteboard.PasteboardType.rtf.rawValue: return "RTF"
            case NSPasteboard.PasteboardType.URL.rawValue: return "URL"
            case Self.webArchive.rawValue: return "网页归档"
            case Self.chromiumSourceURL.rawValue: return "来源页"
            case NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue: return "图片"
            default: return ""
            }
        }.filter { !$0.isEmpty }
        return "[\(Array(NSOrderedSet(array: kinds)).compactMap { $0 as? String }.joined(separator: "/"))] 文字 \(text.count) 字 HTML \(html?.count ?? 0) 字\(sourceURL.flatMap { URL(string: $0)?.host }.map { " 来自 \($0)" } ?? "")"
    }
}

// MARK: 剪藏确认小窗

@MainActor @Observable
final class ClipDraft {
    var input: ClipInput
    var preview: Clip.Preview
    var via: String
    var title: String
    init(input: ClipInput, preview: Clip.Preview, via: String) {
        self.input = input; self.preview = preview; self.via = via; title = preview.title
    }
}

/// 不激活拾藏的浮动小窗：在别的 App 里按快捷键也能直接打字改标题、回车保存、Esc 取消，焦点回到原来的 App
private final class ClipPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class ClipConfirmController {
    private var panel: ClipPanel?
    private(set) var draft: ClipDraft?
    var onSave: ((ClipDraft) -> Void)?

    var isVisible: Bool { panel?.isVisible == true && draft != nil }

    func show(input: ClipInput, preview: Clip.Preview, via: String) {
        let d = ClipDraft(input: input, preview: preview, via: via)
        draft = d
        let host = NSHostingView(rootView: ClipConfirmView(draft: d, save: { [weak self] in self?.save() }, cancel: { [weak self] in self?.cancel() }))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let p = panel ?? makePanel()
        panel = p
        p.contentView = host
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            p.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.minY + vf.height * 0.62 - size.height / 2, width: size.width, height: size.height), display: true)
        }
        // makeKeyAndOrderFront 在别的 App 在前台时拿不到键盘焦点（实测 key=false）；分两步才行，且不会把主窗口带上来
        p.orderFrontRegardless()
        p.makeKey()
        AppLog.shared.say("剪藏确认窗：\(preview.chars) 字 图\(preview.images)\(preview.rich ? " 保留格式" : "")\(preview.host.map { " 来自 \($0)" } ?? "") [\(via)] 焦点=\(p.isKeyWindow)")
    }

    func save() {
        guard let d = draft else { return }
        close()
        onSave?(d)
    }

    func cancel() {
        guard draft != nil else { return }
        close()
        AppLog.shared.say("剪藏已取消")
    }

    private func close() {
        draft = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    private func makePanel() -> ClipPanel {
        let p = ClipPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                          styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.becomesKeyOnlyIfNeeded = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.title = "拾藏剪藏"
        p.onCancel = { [weak self] in self?.cancel() }
        return p
    }
}

private struct ClipConfirmView: View {
    @Bindable var draft: ClipDraft
    let save: () -> Void
    let cancel: () -> Void
    @FocusState private var titleFocused: Bool

    var body: some View {
        let pv = draft.preview
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard.fill").font(.title3).foregroundStyle(Color.accentColor)
                Text("剪藏这段内容？").font(.headline)
                Spacer()
                Text(stats(pv)).font(.caption).foregroundStyle(.secondary)
            }
            TextField("标题", text: $draft.title, prompt: Text("标题"))
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
                .onSubmit(save)
            VStack(alignment: .leading, spacing: 4) {
                if pv.lines.isEmpty {
                    Text(pv.images > 0 ? "（只有图片）" : "（空）").foregroundStyle(.tertiary)
                }
                ForEach(Array(pv.lines.enumerated()), id: \.offset) { _, l in
                    Text(l).lineLimit(2).truncationMode(.tail)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 8) {
                Text(foot(pv)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 480)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .padding(1)
        .task {
            try? await Task.sleep(for: .milliseconds(80))
            titleFocused = true
        }
    }

    private func stats(_ pv: Clip.Preview) -> String {
        "\(pv.chars) 字" + (pv.images > 0 ? " · \(pv.images) 张图" : "")
    }

    private func foot(_ pv: Clip.Preview) -> String {
        var bits: [String] = [pv.rich ? "保留格式\(pv.images > 0 ? "和图片" : "")" : "按纯文字保存"]
        if let h = pv.host { bits.append("来自 \(h)") }
        return bits.joined(separator: " · ")
    }
}
