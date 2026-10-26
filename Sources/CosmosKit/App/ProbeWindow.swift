import AppKit
import SwiftUI
import CosmosCore

/// Probe: a small floating window for a link that arrives from another app (Arc's Little Arc). Read it, then either
/// close it or send it to a space.
@MainActor
final class ProbeWindowController: NSWindowController, NSWindowDelegate {
    let store: BrowserStore
    let runtime: TabRuntime
    var onClose: ((ProbeWindowController) -> Void)?
    private var closed = false

    init(store: BrowserStore, url: URL?, profileID: UUID?, spaceTheme: SpaceTheme) {
        self.store = store
        let env = store.environment(forProfile: profileID)
        runtime = TabRuntime(itemID: UUID(), profileID: store.isIncognito ? nil : profileID, configuration: env.makeConfiguration(), host: store)
        runtime.isEphemeral = true
        if let url, url.scheme != "about" { runtime.load(url) }

        let win = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
                          backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isFloatingPanel = true
        win.hidesOnDeactivate = false
        win.becomesKeyOnlyIfNeeded = false
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 420, height: 320)
        win.backgroundColor = NSColor(red: 0.07, green: 0.06, blue: 0.13, alpha: 1)
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.setFrameAutosaveName("CosmosProbeWindow")
        super.init(window: win)
        win.delegate = self
        let root = ProbeView(store: store, runtime: runtime, theme: spaceTheme,
                             onOpenInSpace: { [weak self] in self?.openInSpace() },
                             onClose: { [weak self] in self?.window?.close() })
            .ignoresSafeArea()
        let host = NSHostingView(rootView: root)
        host.sceneBridgingOptions = []
        win.contentView = host
        if !win.setFrameUsingName("CosmosProbeWindow") { win.center() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Moves the page into the frontmost browser window as a new tab, keeping its state.
    func openInSpace() {
        guard let target = store.activeWindow ?? store.windows.first else { return }
        store.adopt(runtime: runtime, in: target)
        runtime.isEphemeral = false
        window?.close()
        NSApp.activate(ignoringOtherApps: true)
        BrowserWindowRegistry.shared.last?.window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        if runtime.isEphemeral { runtime.tearDown() }
        window?.contentView = nil
        onClose?(self)
    }
}

private struct ProbeView: View {
    let store: BrowserStore
    let runtime: TabRuntime
    let theme: SpaceTheme
    let onOpenInSpace: () -> Void
    let onClose: () -> Void

    var body: some View {
        let palette = Palette(theme: theme)
        ZStack {
            ThemeBackground(theme: theme, animated: false)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 62, height: 1)
                    FaviconView(store: store, url: runtime.url, size: 15)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(runtime.title.isEmpty ? (runtime.isLoading ? "Loading…" : "Probe") : runtime.title)
                            .font(.system(size: 12.5, weight: .semibold)).lineLimit(1).foregroundStyle(palette.text)
                        Text(URLInput.hostForDisplay(runtime.url)).font(.system(size: 11)).lineLimit(1).foregroundStyle(palette.secondary)
                    }
                    Spacer(minLength: 8)
                    if runtime.isLoading { OrbitSpinner(size: 14, color: palette.accent) }
                    ToolbarButton(symbol: "chevron.left", enabled: runtime.canGoBack, help: "Back") { runtime.goBack() }
                    ToolbarButton(symbol: "chevron.right", enabled: runtime.canGoForward, help: "Forward") { runtime.goForward() }
                    Button(action: onOpenInSpace) {
                        Label("Open in Space", systemImage: "arrow.up.right.square")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(Capsule().fill(palette.accentFill))
                            .foregroundStyle(palette.onAccent)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Move this page into your browser window (⌘↩)")
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(WindowDragArea())
                RuntimeWebHost(runtime: runtime)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.page, style: .continuous))
                    .padding(EdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8))
            }
        }
        .environment(\.palette, palette)
        .preferredColorScheme(palette.isDark ? .dark : .light)
    }
}

// MARK: - Script-opened popups (OAuth consent, payment sheets, ...)

@MainActor
enum PopupWindows {
    static func present(_ runtime: TabRuntime, features: WKWindowFeaturesBox, bringForward: Bool) {
        let width = max(360, features.width ?? 520), height = max(320, features.height ?? 640)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.isRestorable = false   // its title is the page's host
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        runtime.webView.frame = container.bounds
        runtime.webView.autoresizingMask = [.width, .height]
        container.addSubview(runtime.webView)
        win.contentView = container
        if let x = features.x, let y = features.y, let screen = NSScreen.main {
            win.setFrameTopLeftPoint(NSPoint(x: x, y: screen.frame.height - y))
        } else {
            win.center()
        }
        win.title = runtime.url?.host ?? "Sign in"
        let delegate = PopupDelegate(runtime: runtime)
        objc_setAssociatedObject(win, &PopupDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
        win.delegate = delegate
        // A sign-in opened from the menu-bar panel appears while Cosmos is not the frontmost app. A page that asks for a
        // window on its own (a background tab, a hidden panel) does not get to take the focus from what the user is doing.
        if bringForward { NSApp.activate(ignoringOtherApps: true) }
        win.makeKeyAndOrderFront(nil)
    }
}

import WebKit

struct WKWindowFeaturesBox {
    var x: Double?, y: Double?, width: Double?, height: Double?
    init(_ f: WKWindowFeatures) {
        x = f.x?.doubleValue; y = f.y?.doubleValue; width = f.width?.doubleValue; height = f.height?.doubleValue
    }
}

@MainActor
private final class PopupDelegate: NSObject, NSWindowDelegate {
    nonisolated(unsafe) static var key = 0
    let runtime: TabRuntime
    init(runtime: TabRuntime) {
        self.runtime = runtime
        super.init()
        observe()
    }

    private func observe() {
        withObservationTracking { _ = runtime.title } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.runtime.webView.window?.title = self.runtime.title.isEmpty ? (self.runtime.url?.host ?? "") : self.runtime.title
                self.observe()
            }
        }
    }

    func windowWillClose(_ notification: Notification) { runtime.tearDown() }
}
