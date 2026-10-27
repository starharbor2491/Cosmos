import SwiftUI
import AppKit
import CosmosCore

/// Everything drawn above the page that isn't the page itself: the Command Bar and the modal-ish panels.
struct OverlayLayer: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geo in
            panels
                .frame(width: geo.size.width, height: geo.size.height)
                .environment(\.overlayBounds, geo.size)
        }
        .background(OverlayEscapeCatcher(active: shouldCatchEscape) { store.dismiss(in: window) })
    }

    private var panels: some View {
        ZStack {
            switch window.overlay {
            case .commandBar:
                Scrim(opacity: 0.30) { window.overlay = nil }
                VStack {
                    CommandBarView(store: store, window: window)
                        .padding(.top, 86)
                    Spacer()
                }
                .transition(Self.pop(from: .top))
            case .themeEditor(let id):
                Scrim(opacity: 0.30) { window.overlay = nil }
                ThemeEditorPanel(store: store, window: window, spaceID: id).transition(Self.pop(from: .center))
            case .boosts:
                Scrim(opacity: 0.30) { window.overlay = nil }
                BoostsPanel(store: store, window: window).transition(Self.pop(from: .center))
            case .welcome:
                Scrim(opacity: 0.45) { window.overlay = nil }
                WelcomeView(store: store, window: window).transition(Self.pop(from: .center))
            case .siteControls:
                Scrim(opacity: 0.0) { window.overlay = nil }
                SiteControlsPanel(store: store, window: window).transition(Self.pop(from: .topLeading))
            case .shortcuts:
                Scrim(opacity: 0.30) { window.overlay = nil }
                ShortcutsPanel(window: window).transition(Self.pop(from: .center))
            case .find, nil:
                EmptyView()
            }
        }
    }

    /// A panel grows out of where it was asked for: the Command Bar from the top, Site Controls from the address pill,
    /// everything else from the middle.
    private static func pop(from anchor: UnitPoint) -> AnyTransition {
        .scale(scale: 0.96, anchor: anchor).combined(with: .opacity)
    }

    private var shouldCatchEscape: Bool {
        switch window.overlay {
        case .find, .commandBar: return false   // find and the command bar handle Esc in their own fields
        case nil: return window.libraryOpen && window.peek == nil   // Esc leaves the Library (see `BrowserStore.dismiss`); a Peek closes first
        default: return true
        }
    }
}

private struct OverlayBoundsKey: EnvironmentKey { static let defaultValue = CGSize.zero }

extension EnvironmentValues {
    /// The window area panels are laid out in, so one that is bigger than a small window can shrink to fit.
    var overlayBounds: CGSize {
        get { self[OverlayBoundsKey.self] }
        set { self[OverlayBoundsKey.self] = newValue }
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
struct OverlayEscapeCatcher: NSViewRepresentable {
    let active: Bool
    let onEscape: () -> Void

    func makeNSView(context: Context) -> CatcherView { let v = CatcherView(); v.onEscape = onEscape; v.active = active; return v }
    func updateNSView(_ v: CatcherView, context: Context) { v.onEscape = onEscape; v.active = active }

    final class CatcherView: NSView {
        var onEscape: (() -> Void)?
        var active = false
        private var monitor: Any?

        /// It sits behind the whole window: it must not take the clicks meant for what is drawn over it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
    @Environment(\.overlayBounds) private var bounds

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.accentGlyph)
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
        .frame(width: Metrics.panelSize(width, within: bounds.width))
        .frame(height: height.map { Metrics.panelSize($0, within: bounds.height) })
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.Radius.panel, style: .continuous))
        .background(RoundedRectangle(cornerRadius: Metrics.Radius.panel, style: .continuous).fill(palette.panel))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.panel, style: .continuous).strokeBorder(palette.stroke, lineWidth: 0.8))
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
            PromptTextField(text: $text, prompt: prompt)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(palette.text)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(palette.tertiary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).fill(palette.hover))
    }
}

/// A plain text field whose prompt is drawn in the panel's own hint colour. The system's placeholder colour is a fixed
/// grey that all but vanishes on a themed panel (about 1.2:1), so no field in the interface uses it.
struct PromptTextField: View {
    @Binding var text: String
    var prompt: String
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(prompt).foregroundStyle(palette.tertiary).lineLimit(1).allowsHitTesting(false).accessibilityHidden(true)
            }
            TextField("", text: $text).accessibilityLabel(prompt)
        }
    }
}
