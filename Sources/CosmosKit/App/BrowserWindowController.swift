import AppKit
import SwiftUI
import CosmosCore

final class CosmosWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// One browser window: a transparent-titlebar NSWindow hosting the SwiftUI root.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let store: BrowserStore
    let state: WindowState
    var onClose: ((BrowserWindowController) -> Void)?
    private var closed = false

    init(store: BrowserStore, state: WindowState, cascadeFrom previous: NSWindow? = nil) {
        self.store = store
        self.state = state
        let win = CosmosWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = false
        win.minSize = NSSize(width: 760, height: 480)
        win.isReleasedWhenClosed = false
        win.tabbingMode = .disallowed
        win.collectionBehavior.insert(.fullScreenPrimary)
        win.backgroundColor = NSColor(red: 0.07, green: 0.06, blue: 0.13, alpha: 1)
        let host = NSHostingView(rootView: BrowserRootView(store: store, window: state).ignoresSafeArea())
        host.sceneBridgingOptions = []
        win.contentView = host
        super.init(window: win)
        win.delegate = self
        if state.isIncognito {
            win.title = "Incognito"
        } else if !win.setFrameUsingName("CosmosMainWindow") {
            win.center()
        }
        if let previous, !state.isIncognito, previous.isVisible {
            let origin = win.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY))
            _ = origin
        }
        win.setFrameAutosaveName(state.isIncognito ? "" : "CosmosMainWindow")
        store.register(state)
        trackTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Title

    private func trackTitle() {
        updateTitle()
        withObservationTracking {
            _ = store.currentRuntime(in: state)?.title
            _ = state.selectedItemID
            _ = store.workspace.item(state.selectedItemID ?? UUID())
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.updateTitle()
                self.trackTitle()
            }
        }
    }

    private func updateTitle() {
        guard let id = state.selectedItemID else { window?.title = state.isIncognito ? "Incognito" : "Cosmos"; return }
        window?.title = store.title(forItem: store.currentTabItemID(in: state) ?? id, in: state)
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        store.activeWindow = state
        store.extensionCenter?.windowFocused(state)
        BrowserWindowRegistry.shared.didBecomeKey(self)
    }

    func windowDidEnterFullScreen(_ notification: Notification) { state.isFullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) { state.isFullScreen = false }

    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        store.closePeek(in: state)
        store.unregister(state)
        window?.contentView = nil
        onClose?(self)
    }
}

/// Which controller is frontmost, for menu commands.
@MainActor
final class BrowserWindowRegistry {
    static let shared = BrowserWindowRegistry()
    private(set) weak var last: BrowserWindowController?
    func didBecomeKey(_ c: BrowserWindowController) { last = c }
}
