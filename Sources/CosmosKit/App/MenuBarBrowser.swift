import AppKit
import SwiftUI
import CosmosCore

/// The panel under the menu-bar icon. It can take the keyboard (an address to type, a page to scroll) without making
/// Cosmos the frontmost app, so opening it never pulls the browser windows forward.
final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The menu-bar browser: an icon in the menu bar that opens a small browser under it, for a quick look at something
/// without going to a window. It follows the settings (see `MenuBarSettings`): the icon is there only while it is on.
@MainActor
final class MenuBarBrowser: NSObject {
    let store: BrowserStore
    let session: MenuBarSession
    private(set) var statusItem: NSStatusItem?
    private(set) var panel: MenuBarPanel?
    private var closedAt: Date?
    private var resignObserver: NSObjectProtocol?
    private let showSettings: () -> Void
    private let showBrowser: () -> Void

    var isOpen: Bool { panel?.isVisible == true }

    /// - Parameter openInCosmos: where a page that belongs in a browser window goes.
    /// - Parameter showSettings: opens the Menu Bar pane of Settings.
    /// - Parameter showBrowser: brings a browser window forward.
    init(store: BrowserStore, openInCosmos: @escaping (URL) -> Void, showSettings: @escaping () -> Void, showBrowser: @escaping () -> Void) {
        self.store = store
        self.showSettings = showSettings
        self.showBrowser = showBrowser
        session = MenuBarSession(store: store)
        super.init()
        session.onHide = { [weak self] in self?.hide() }
        session.isPanelOpen = { [weak self] in self?.isOpen == true }
        session.onPinChange = { [weak self] in
            guard let self else { return }
            self.panel?.level = self.session.isPinned ? .floating : .statusBar
        }
        // A size the user dragged the panel to is kept (for this layout) and used the next time it opens.
        session.onResized = { [weak self] size in self?.store.settings.menuBar.setSize(size) }
        session.onOpenInCosmos = { [weak self] url in
            self?.hide()
            openInCosmos(url)
        }
    }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    // MARK: Following the settings

    /// Shows or hides the icon to match the settings, and re-fits the panel if it is open.
    func sync() {
        guard store.settings.menuBar.enabled else {
            hide()
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            session.teardown()
            // Switching it off and on again starts from the ordinary panel, not one that is still pinned.
            session.isPinned = false
            return
        }
        if statusItem == nil { installStatusItem() }
        // A panel that is open follows a change of layout or profile, without taking the keyboard back. (One the user has just
        // resized already has the size that was kept, and stays where it is.)
        if let panel, panel.isVisible {
            session.prepare()
            if panel.frame.size != store.settings.menuBar.size { place(panel) }
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // macOS remembers where the user dragged it to (⌘-drag) under this name.
        item.autosaveName = "CosmosMenuBarBrowser"
        if let button = item.button {
            button.image = AppIcon.menuBarImage()
            button.toolTip = "Cosmos menu bar browser"
            button.setAccessibilityLabel("Cosmos menu bar browser")
            button.target = self
            button.action = #selector(iconClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func iconClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            toggle()
        }
    }

    private func showMenu() {
        guard let statusItem else { return }
        hide()
        let menu = NSMenu()
        for (title, action) in [("Open Cosmos", #selector(menuOpenCosmos)), ("Menu Bar Settings…", #selector(menuSettings))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let hideItem = NSMenuItem(title: "Hide from the Menu Bar", action: #selector(menuHide), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)
        // A menu on the item shows for the click that is being handled, then goes, so a plain click opens the panel.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuOpenCosmos() { showBrowser() }
    @objc private func menuSettings() { showSettings() }
    @objc private func menuHide() { store.settings.menuBar.enabled = false }

    /// Puts the panel away and lets go of its page, with its back and forward list (Clear History).
    func forgetPage() {
        hide()
        session.teardown()
    }

    // MARK: Showing

    func toggle() {
        if isOpen { hide() } else if MenuBarToggle.shouldOpen(now: Date(), closedAt: closedAt) { show() }
    }

    /// Opens the panel under the icon (or, with no icon, at the top right of the screen), making the page first if needed.
    func show() {
        guard store.settings.menuBar.enabled else { return }
        let blank = session.runtime?.url == nil
        session.prepare()
        let panel = makePanelIfNeeded()
        place(panel)
        panel.makeKeyAndOrderFront(nil)
        if blank { session.focusAddress() }
    }

    /// Puts the panel under the icon (or at the top right with none), at the size it has (the layout's, or the one the user
    /// dragged it to).
    private func place(_ panel: MenuBarPanel) {
        let button = statusItem?.button
        let anchor = button.flatMap { b in b.window.map { $0.convertToScreen(b.convert(b.bounds, to: nil)) } }
        let screen = button?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(MenuBarPlacement.frame(anchor: anchor, size: store.settings.menuBar.size, visible: visible), display: true)
        panel.level = session.isPinned ? .floating : .statusBar
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        closedAt = Date()
    }

    private func makePanelIfNeeded() -> MenuBarPanel {
        if let panel { return panel }
        let made = MenuBarPanel(contentRect: NSRect(origin: .zero, size: store.settings.menuBar.size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        made.isReleasedWhenClosed = false
        made.title = "Cosmos menu bar browser"
        made.isOpaque = false
        made.backgroundColor = .clear
        made.hasShadow = true
        made.isFloatingPanel = true
        made.hidesOnDeactivate = false
        made.becomesKeyOnlyIfNeeded = false
        made.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: MenuBarBrowserView(store: store, session: session))
        host.sceneBridgingOptions = []
        host.sizingOptions = []
        made.contentView = host
        // Clicking anywhere else (another app, another window, the desktop) takes the keyboard away, which closes the
        // panel unless it is pinned or a sheet from the page (an alert, a file picker) is on it.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: made, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, !self.session.isPinned, panel.attachedSheet == nil else { return }
                self.hide()
            }
        }
        panel = made
        return made
    }
}
