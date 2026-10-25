import AppKit
import Foundation
import WebKit
import CosmosCore

/// A Cosmos tab as WebKit's extension engine sees it (`chrome.tabs`).
@available(macOS 15.4, *)
@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    private(set) weak var runtime: TabRuntime?
    private unowned let engine: ExtensionEngine

    init(runtime: TabRuntime, engine: ExtensionEngine) {
        self.runtime = runtime
        self.engine = engine
    }

    private var store: BrowserStore? { engine.store_ }
    private var windowState: WindowState? {
        guard let runtime, let store else { return nil }
        return store.window(showing: runtime.itemID) ?? store.activeWindow ?? store.windows.first
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { windowState.map { engine.window(for: $0) } }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let runtime, let state = windowState else { return 0 }
        return engine.window(for: state).liveTabs.firstIndex { $0.runtime === runtime } ?? 0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { runtime?.webView }
    func title(for context: WKWebExtensionContext) -> String? { runtime?.title }
    func url(for context: WKWebExtensionContext) -> URL? { runtime?.url }
    func pendingURL(for context: WKWebExtensionContext) -> URL? { runtime?.webView.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(runtime?.isLoading ?? false) }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { runtime?.isAudible ?? false }
    func isMuted(for context: WKWebExtensionContext) -> Bool { runtime?.isMuted ?? false }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { runtime?.zoom ?? 1 }
    func size(for context: WKWebExtensionContext) -> CGSize { runtime?.webView.bounds.size ?? .zero }

    func isPinned(for context: WKWebExtensionContext) -> Bool {
        guard let runtime, let store else { return false }
        return store.tabIsPinnedOrFavorite(runtime)
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let runtime, let store, let state = windowState else { return false }
        return store.currentRuntime(in: state) === runtime
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        runtime?.load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        runtime?.reload(fromOrigin: fromOrigin)
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) { runtime?.goBack(); completionHandler(nil) }
    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) { runtime?.goForward(); completionHandler(nil) }

    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        runtime?.isMuted = muted
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let runtime, let store, let state = windowState { store.select(runtime.itemID, in: state) }
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let runtime, let store { store.closeTab(runtime.itemID, in: windowState) }
        completionHandler(nil)
    }
}

/// A Cosmos window as WebKit's extension engine sees it (`chrome.windows`).
@available(macOS 15.4, *)
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    let state: WindowState
    private unowned let engine: ExtensionEngine

    init(state: WindowState, engine: ExtensionEngine) {
        self.state = state
        self.engine = engine
    }

    /// Every live page, in sidebar order. Cosmos keeps all spaces in one window, so a "window" shows them all.
    var liveTabs: [ExtensionTab] {
        guard let store = engine.store_ else { return [] }
        return store.workspace.allTabs().compactMap { item in store.runtime(forItem: item.id, in: state).map { engine.tab(for: $0) } }
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { liveTabs }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let store = engine.store_, let rt = store.currentRuntime(in: state) else { return nil }
        return engine.tab(for: rt)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { state.isIncognito }

    private var nsWindow: NSWindow? { NSApp.windows.first { ($0.windowController as? BrowserWindowController)?.state === state } }
    func frame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.frame ?? .zero }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.screen?.frame ?? NSScreen.main?.frame ?? .zero }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        nsWindow?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }
}
