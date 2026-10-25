import SwiftUI
import AppKit
import CosmosCore

/// Everything drawn above the page that isn't the page itself: the Command Bar and the modal-ish panels.
struct OverlayLayer: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            switch window.overlay {
            case .commandBar:
                Scrim(opacity: 0.30) { window.overlay = nil }
                VStack {
                    CommandBarView(store: store, window: window)
                        .padding(.top, 86)
                    Spacer()
                }
                .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
            case .archive:
                Scrim(opacity: 0.30) { window.overlay = nil }
                ArchivePanel(store: store, window: window).transition(.scale(scale: 0.97).combined(with: .opacity))
            case .history:
                Scrim(opacity: 0.30) { window.overlay = nil }
                HistoryPanel(store: store, window: window).transition(.scale(scale: 0.97).combined(with: .opacity))
            case .downloads:
                Scrim(opacity: 0.18) { window.overlay = nil }
                DownloadsPanel(store: store, window: window).transition(.scale(scale: 0.97).combined(with: .opacity))
            case .themeEditor(let id):
                Scrim(opacity: 0.30) { window.overlay = nil }
                ThemeEditorPanel(store: store, window: window, spaceID: id).transition(.scale(scale: 0.97).combined(with: .opacity))
            case .boosts:
                Scrim(opacity: 0.30) { window.overlay = nil }
                BoostsPanel(store: store, window: window).transition(.scale(scale: 0.97).combined(with: .opacity))
            case .welcome:
                Scrim(opacity: 0.45) { }
                WelcomeView(store: store, window: window).transition(.scale(scale: 0.97).combined(with: .opacity))
            case .siteControls:
                Scrim(opacity: 0.0) { window.overlay = nil }
                SiteControlsPanel(store: store, window: window).transition(.scale(scale: 0.97, anchor: .topLeading).combined(with: .opacity))
            case .shortcuts:
                Scrim(opacity: 0.30) { window.overlay = nil }
                ShortcutsPanel(window: window).transition(.scale(scale: 0.97).combined(with: .opacity))
            case .find, nil:
                EmptyView()
            }
        }
        .background(OverlayEscapeCatcher(active: shouldCatchEscape) { window.overlay = nil })
    }

    private var shouldCatchEscape: Bool {
        switch window.overlay {
        case .find, nil, .welcome, .commandBar: return false   // find and the command bar handle Esc in their own fields
        default: return true
        }
    }
}

private struct Scrim: View {
    let opacity: Double
    let onTap: () -> Void
    var body: some View {
        Color.black.opacity(opacity)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .transition(.opacity)
    }
}

/// Closes the current panel on Esc even when focus is in a web view.
private struct OverlayEscapeCatcher: NSViewRepresentable {
    let active: Bool
    let onEscape: () -> Void

    func makeNSView(context: Context) -> CatcherView { let v = CatcherView(); v.onEscape = onEscape; v.active = active; return v }
    func updateNSView(_ v: CatcherView, context: Context) { v.onEscape = onEscape; v.active = active }

    final class CatcherView: NSView {
        var onEscape: (() -> Void)?
        var active = false
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.active, event.window === self.window, event.keyCode == 53 else { return event }
                // Don't steal Esc from a text field that's editing (rename fields etc.).
                if let r = self.window?.firstResponder as? NSTextView, r.hasMarkedText() { return event }
                self.onEscape?()
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

// MARK: - Shared panel chrome

/// A centred, titled card: the frame every panel (Archive, History, Boosts, ...) lives in.
struct PanelFrame<Content: View, Accessory: View>: View {
    let title: String
    var symbol: String?
    var width: CGFloat = 640
    var height: CGFloat? = 520
    let close: () -> Void
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.accent)
                }
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.text)
                Spacer()
                accessory()
                ToolbarButton(symbol: "xmark", size: 12, help: "Close (Esc)", action: close)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Rectangle().fill(palette.stroke).frame(height: 0.5)
            content()
        }
        .frame(width: width)
        .frame(height: height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(palette.panel))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(palette.stroke, lineWidth: 0.8))
        .shadow(color: palette.shadow, radius: 36, y: 14)
    }
}

extension PanelFrame where Accessory == EmptyView {
    init(title: String, symbol: String? = nil, width: CGFloat = 640, height: CGFloat? = 520, close: @escaping () -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, symbol: symbol, width: width, height: height, close: close, accessory: { EmptyView() }, content: content)
    }
}

/// A search field styled for panels.
struct PanelSearchField: View {
    @Binding var text: String
    var prompt: String
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(palette.tertiary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(palette.text)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(palette.tertiary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.hover))
    }
}
