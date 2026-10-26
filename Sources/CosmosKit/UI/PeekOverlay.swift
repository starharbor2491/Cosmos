import SwiftUI
import AppKit
import CosmosCore

/// Peek: a link opens in a floating page over the current tab. Close it with Esc or a click outside; "Open in Space"
/// (or ⌘↩) keeps it as a real tab.
struct PeekOverlay: View {
    let store: BrowserStore
    let window: WindowState
    let peek: PeekSession
    @Environment(\.palette) private var palette

    var body: some View {
        let rt = peek.runtime
        ZStack {
            Color.black.opacity(0.34)
                .contentShape(Rectangle())
                .onTapGesture { store.closePeek(in: window) }
                .transition(.opacity)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    FaviconView(store: store, url: rt.url, size: 16)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(rt.title.isEmpty ? URLInput.hostForDisplay(rt.url) : rt.title)
                            .font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                            .foregroundStyle(palette.text)
                        Text(URLInput.hostForDisplay(rt.url))
                            .font(.system(size: 11)).lineLimit(1)
                            .foregroundStyle(palette.secondary)
                    }
                    Spacer(minLength: 12)
                    if rt.isLoading { OrbitSpinner(size: 14, color: palette.accent) }
                    Button { store.promotePeek(in: window) } label: {
                        Label("Open in Space", systemImage: "arrow.up.right.square")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(palette.accent.opacity(0.9)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Keep this page as a tab (⌘↩)")
                    ToolbarButton(symbol: "xmark", size: 12, help: "Close Peek (Esc)") { store.closePeek(in: window) }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial)
                .background(palette.panel)

                RuntimeWebHost(runtime: rt)
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.page, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.page, style: .continuous).strokeBorder(palette.stroke, lineWidth: 0.8))
            .shadow(color: .black.opacity(0.45), radius: 40, y: 16)
            .padding(.horizontal, 44).padding(.vertical, 26)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: peek.id)
        .background(PeekKeyCatcher { store.closePeek(in: window) })
    }
}

struct RuntimeWebHost: NSViewRepresentable {
    let runtime: TabRuntime

    func makeNSView(context: Context) -> RuntimeHostView { RuntimeHostView(runtime: runtime) }
    func updateNSView(_ nsView: RuntimeHostView, context: Context) {}

    final class RuntimeHostView: NSView {
        private let webView: CosmosWebView
        init(runtime: TabRuntime) {
            webView = runtime.webView
            super.init(frame: .zero)
            wantsLayer = true
            webView.removeFromSuperview()
            webView.frame = bounds
            webView.autoresizingMask = [.width, .height]
            addSubview(webView)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let w = self.window else { return }
                w.makeFirstResponder(self.webView)
            }
        }
    }
}

/// Esc anywhere in the window closes the Peek (key events are otherwise swallowed by the page).
private struct PeekKeyCatcher: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onEscape = onEscape
        return v
    }
    func updateNSView(_ v: CatcherView, context: Context) { v.onEscape = onEscape }

    final class CatcherView: NSView {
        var onEscape: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window, event.keyCode == 53 else { return event }
                self.onEscape?()
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
