import AppKit
import CryptoKit
import SwiftUI
import CosmosCore
import CosmosEngine
import CosmosChromium

/// Command-line / environment switches. Real users never need them; they exist for demos and automated checks.
struct LaunchOptions {
    var dataDirectory: URL?
    var demo = false
    /// Never download filter lists (demos and automated runs use the cached or bundled ones).
    var offline = false
    var automationScript: URL?

    static func parse(_ args: [String], env: [String: String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--data-dir": if i + 1 < args.count { o.dataDirectory = URL(fileURLWithPath: args[i + 1]); i += 1 }
            case "--demo": o.demo = true
            case "--offline": o.offline = true
            case "--automation": if i + 1 < args.count { o.automationScript = URL(fileURLWithPath: args[i + 1]); i += 1 }
            default: break
            }
            i += 1
        }
        if o.dataDirectory == nil, let d = env["COSMOS_DATA_DIR"] { o.dataDirectory = URL(fileURLWithPath: d) }
        if o.automationScript == nil, let a = env["COSMOS_AUTOMATION"] { o.automationScript = URL(fileURLWithPath: a) }
        if env["COSMOS_DEMO"] == "1" { o.demo = true }
        if env["COSMOS_OFFLINE"] == "1" { o.offline = true }
        return o
    }

    /// A demo in a data folder that is its own (the temporary one, or a new or empty one it was given): nothing there is
    /// anyone's, so its passwords' key and Chromium's are made up for the run and no Keychain question stops it. A demo
    /// pointed at a folder that has data in it uses the real keys, so that it neither locks away the passwords there nor
    /// garbles the cookies. Asked before the store writes anything.
    var usesThrowawayKeys: Bool {
        guard demo else { return false }
        guard let dataDirectory else { return true }
        return ((try? FileManager.default.contentsOfDirectory(atPath: dataDirectory.path)) ?? []).isEmpty
    }

    var resolvedDataDirectory: URL {
        if let dataDirectory { return dataDirectory }
        if demo { return FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-demo-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cosmos", isDirectory: true)
    }
}

/// Starts the app. Called from the executable's `main.swift`.
@MainActor
public func runCosmos() {
    // First: Chromium runs in this process, and needs it set up before anything else opens a file or makes NSApp.
    let app = ChromiumEngine.prepareApplication()
    let delegate = CosmosAppDelegate(options: LaunchOptions.parse(CommandLine.arguments, env: ProcessInfo.processInfo.environment))
    retainedDelegate = delegate
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}

@MainActor private var retainedDelegate: CosmosAppDelegate?

@MainActor
final class CosmosAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let options: LaunchOptions
    private(set) var store: BrowserStore!
    private(set) var engine: ChromiumEngine!
    private(set) var controllers: [BrowserWindowController] = []
    private var probes: [ProbeWindowController] = []
    var probeCount: Int { probes.count }
    private var settingsController: NSWindowController?
    /// The open Settings window's dropdown layer, so the automation script can open a list.
    var settingsDropdowns: DropdownHost?
    /// The small browser under the menu-bar icon (the icon is there only while the setting is on).
    private(set) var menuBar: MenuBarBrowser?
    private var automation: Automation?
    private var pendingURLs: [URL] = []
    private var launched = false

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Views read this while they are built, so it has to be set before the first window exists.
        SpatialProbe.isRecording = options.automationScript != nil
        engine = ChromiumEngine()
        let throwaway = options.usesThrowawayKeys
        let demoKey = SymmetricKey(size: .bits256)
        store = BrowserStore(directory: options.resolvedDataDirectory, engine: engine,
                             passwordKey: throwaway ? { demoKey } : PasswordManager.keychainKey)
        engine.settings = store.settings.engine
        NSApp.applicationIconImage = AppIcon.image(store.settings.appIcon)
        // Every profile's data is in the data folder's `Engine Profiles`; the first profile's is the one extensions run in.
        let first = store.workspace.profiles[0].id
        if let folder = store.engineFolder(forProfile: first) {
            ChromiumEngine.configure(root: folder.deletingLastPathComponent(), defaultProfileID: first, defaultProfile: folder,
                                     switches: throwaway ? ["--use-mock-keychain"] : [])
        }
        var wasReady = engine.status.isReady
        engine.onStatusChange = { [weak self] in
            guard let self else { return }
            let status = self.engine.status
            for s in self.allStores { s.engineStatus = status }
            // Pages asked for while there was no Chromium (the first download failed, then a retry worked) never got
            // one: they are made again now.
            if status.isReady, !wasReady { for s in self.allStores { s.engineBecameReady() } }
            wasReady = status.isReady
        }
        engine.start()
        store.engineStatus = engine.status
        store.favicons.offline = options.offline
        wire(store)
        if let dir = store.dataDirectory {
            let extensions = ExtensionCenter(store: store, directory: dir)
            store.extensionCenter = extensions
            extensions.start()
            // Demos and automated runs reach no service of their own.
            if !options.demo, !options.offline, options.automationScript == nil { extensions.checkForUpdatesDaily() }
            let blocker = ContentBlockerController(store: store, directory: dir, offline: options.offline || options.demo)
            store.blocker = blocker
            blocker.start()
        }
        // A new install starts with the quieter set; the welcome offers the rest. (Demos keep everything on to show it.)
        let welcomeDue = store.welcomeIsDue(demo: options.demo)
        NSApp.appearance = store.settings.appearance.nsAppearance
        NSApp.mainMenu = makeMainMenu()
        showFeatureItems()
        installKeyChords()
        if options.demo { DemoSeed.populate(store) }

        let saved = store.savedSession?.windows.count ?? 0
        let count = (store.settings.restoreTabsOnLaunch && !options.demo) ? max(1, saved) : 1
        for i in 0..<count { openWindow(state: store.makeWindowState(restoring: i), restoreSelection: true) }
        if welcomeDue, let first = controllers.first { first.state.overlay = .welcome }
        installMenuBarBrowser()
        launched = true
        NSApp.activate(ignoringOtherApps: true)
        for url in pendingURLs { openExternal(url) }
        pendingURLs = []

        if let script = options.automationScript {
            automation = Automation(delegate: self, scriptURL: script)
            automation?.start()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // ⌘Q while a page has the keyboard comes back from Chromium inside its work on the main thread: waiting there for
        // Chromium to stop would wait forever, as nothing Chromium has to do, nor the answer, runs until that work
        // returns. So this quit is called off and made again from the run loop, a moment later.
        if ChromiumEngine.isDoingWork {
            sender.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            return .terminateCancel
        }
        store.saveSession()
        store.saveNow()
        store.isTerminating = true
        for c in controllers { c.store.isTerminating = true }
        // Cosmos ends once Chromium has stopped: it writes out what it had not yet (cookies, site settings).
        engine.shutdown { DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }

    /// The main store and every incognito window's own.
    private var allStores: [BrowserStore] {
        var out: [BrowserStore] = store.map { [$0] } ?? []
        for c in controllers where !out.contains(where: { $0 === c.store }) { out.append(c.store) }
        return out
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else { pendingURLs.append(contentsOf: urls); return }
        for url in urls { openExternal(url) }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Window", action: #selector(dockNewWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Incognito Window", action: #selector(dockNewIncognito), keyEquivalent: "").target = self
        return menu
    }

    @objc private func dockNewWindow() { newWindow() }
    @objc private func dockNewIncognito() { newIncognitoWindow() }

    // MARK: Key chords

    private var chordMonitor: Any?

    /// Chords that menu key equivalents can't express reliably (shifted symbols, Tab, arrows with ⌥⌘) or that web
    /// pages would otherwise swallow. Arc lets its shortcuts win over websites, so these run before any responder.
    private func installKeyChords() {
        chordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let c = self.active, (event.window ?? NSApp.keyWindow) === c.window else { return event }
            // The welcome takes its own keys (its practice window answers ⌥⌘→); the browser behind it waits.
            guard c.state.overlay != .welcome, c.state.overlay != .importBrowser else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let state = c.state, store = c.store
            switch (event.keyCode, flags) {
            case (24, [.control, .shift]): store.perform(.addSplit, in: state)
            case (27, [.control, .shift]): store.perform(.closeSplitPane, in: state)
            case (48, [.control]): store.selectRecent(1, in: state)
            case (48, [.control, .shift]): store.selectRecent(2, in: state)
            case (124, [.command, .option]): store.cycleSpace(1, in: state)
            case (123, [.command, .option]): store.cycleSpace(-1, in: state)
            case (125, [.command, .option]): store.selectAdjacentTab(1, in: state)
            case (126, [.command, .option]): store.selectAdjacentTab(-1, in: state)
            default: return event
            }
            return nil
        }
    }

    // MARK: Wiring

    private func wire(_ store: BrowserStore) {
        store.onNewWindow = { [weak self] in self?.newWindow() }
        store.onOpenIncognito = { [weak self] in self?.newIncognitoWindow() }
        store.onShowSettings = { [weak self] in self?.showSettings() }
        store.onShowSettingsTab = { [weak self] tab in self?.showSettings(tab: tab) }
        store.onPresent = { [weak self] overlay in self?.present(overlay) }
        store.onOpenProbe = { [weak self, weak store] url in
            guard let self, let store else { return }
            self.openProbe(url, store: store)
        }
        store.onPopupWindow = { runtime, request, bringForward in
            PopupWindows.present(runtime, request: request, bringForward: bringForward)
        }
        store.onPictureInPicture = { [weak self, weak store] runtime, video in
            guard let self, let store else { return false }
            return self.showPictureInPicture(video, for: runtime, of: store)
        }
        store.onShowTab = { [weak self, weak store] runtime in
            guard let self, let store else { return }
            self.showTab(runtime, of: store)
        }
        store.onPictureInPictureEnded = { [weak self] runtime in
            guard let panel = self?.pictureInPicture, panel.runtime === runtime else { return }
            self?.pictureInPicture = nil
            panel.closeBecausePageEnded()
        }
        store.onEngineSettingsChanged = { [weak self, weak store] in
            guard let self, let store, store === self.store else { return }
            self.engine.settings = store.settings.engine
        }
        store.downloads.onEvent = { [weak self, weak store] item in
            guard let self, let store else { return }
            self.activeState(for: store)?.showToast("Downloading \(item.filename)", symbol: "arrow.down.circle.fill")
        }
    }

    // MARK: Picture in Picture

    /// One video at a time, as in Chrome: a new one sends the one before back to its page.
    private var pictureInPicture: PictureInPicturePanel?

    private func showPictureInPicture(_ video: NSView, for runtime: TabRuntime, of store: BrowserStore) -> Bool {
        if let previous = pictureInPicture { pictureInPicture = nil; previous.close() }
        let panel = PictureInPicturePanel(showing: video, for: runtime)
        panel.onBackToTab = { [weak self, weak store, weak runtime] in
            guard let self, let store, let runtime else { return }
            self.showTab(runtime, of: store)
        }
        panel.onClose = { [weak self, weak panel] in if self?.pictureInPicture === panel { self?.pictureInPicture = nil } }
        panel.orderFrontRegardless()
        pictureInPicture = panel
        return true
    }

    /// Brings a tab to the front: its window, and the tab in it.
    private func showTab(_ runtime: TabRuntime, of store: BrowserStore) {
        guard let state = store.window(showing: runtime.itemID) ?? activeState(for: store) else { return }
        if store.workspace.item(runtime.itemID) != nil { store.select(runtime.itemID, in: state) }
        controllers.first { $0.state === state }?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func activeState(for store: BrowserStore) -> WindowState? {
        store.activeWindow ?? store.windows.first
    }

    // MARK: Windows

    @discardableResult
    func openWindow(state: WindowState, store target: BrowserStore? = nil, restoreSelection: Bool = false) -> BrowserWindowController {
        let st = target ?? store!
        let controller = BrowserWindowController(store: st, state: state, cascadeFrom: controllers.last?.window)
        controllers.append(controller)
        controller.onClose = { [weak self] c in
            guard let self else { return }
            self.controllers.removeAll { $0 === c }
            // The last window of an incognito store takes its pages and its engine profile (and with it every cookie) along.
            if c.store.isIncognito, !self.controllers.contains(where: { $0.store === c.store }) { c.store.closeEnvironments() }
        }
        controller.showWindow(nil)
        if restoreSelection, let sel = state.selection[state.focusedSpaceID], st.workspace.item(sel) != nil {
            st.select(sel, in: state)
        }
        return controller
    }

    func newWindow() {
        // The space of the window in front, unless that is a private window (its spaces are not this store's).
        let space = active.flatMap { store.workspace.space($0.state.focusedSpaceID)?.id } ?? store.workspace.spaces[0].id
        let state = WindowState(focusedSpaceID: space, sidebarWidth: store.settings.sidebarWidth)
        let c = openWindow(state: state)
        state.overlay = .commandBar(.newTab)
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installMenuBarBrowser() {
        let browser = MenuBarBrowser(store: store, openInCosmos: { [weak self] url in self?.openInBrowser(url) },
                                     showSettings: { [weak self] in self?.showSettings(tab: .menuBar) },
                                     showBrowser: { [weak self] in self?.showBrowserWindow() })
        menuBar = browser
        store.onMenuBarChange = { [weak browser] in browser?.sync() }
        store.onHistoryCleared = { [weak browser] in browser?.forgetPage() }
        store.onFeaturesChanged = { [weak self] in self?.showFeatureItems() }
        store.onPreferencesChanged = { [weak self] in
            guard let self else { return }
            for c in self.controllers where c.store !== self.store { c.store.inheritPreferences(from: self.store) }
        }
        browser.sync()
    }

    /// Opens `url` as a new tab in the browser window the user last used, opening one if there is none.
    func openInBrowser(_ url: URL) {
        if active == nil { newWindow() }
        guard let c = active ?? controllers.first else { return }
        open(url, in: c)
    }

    /// Brings a browser window forward, opening one if there is none.
    func showBrowserWindow() {
        if let c = active ?? controllers.first {
            c.window?.makeKeyAndOrderFront(nil)
        } else {
            newWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Shows `overlay` in the browser window the user last used, opening one if there is none, and brings it forward.
    func present(_ overlay: Overlay) {
        // In one of the browser's own windows, never a private one in front of it (it would act on a store that keeps nothing).
        func own() -> BrowserWindowController? { active.flatMap { $0.store === store ? $0 : nil } ?? controllers.last { $0.store === store } }
        if own() == nil { newWindow() }
        guard let c = own() else { return }
        c.state.overlay = overlay
        c.window?.makeKeyAndOrderFront(nil)
    }

    func newIncognitoWindow() {
        let incognito = BrowserStore(directory: nil, incognito: true, engine: engine)
        incognito.engineStatus = engine.status
        wire(incognito)
        incognito.favicons.offline = store.favicons.offline
        incognito.inheritPreferences(from: store)
        incognito.blocker = store.blocker
        let state = incognito.makeWindowState()
        let c = openWindow(state: state, store: incognito)
        state.overlay = .commandBar(.newTab)
        c.window?.makeKeyAndOrderFront(nil)
    }

    func openProbe(_ url: URL, store target: BrowserStore) {
        let focused = (target.activeWindow ?? target.windows.first)?.focusedSpaceID
        let space = focused.flatMap { target.workspace.space($0) } ?? target.workspace.spaces[0]
        let probe = ProbeWindowController(store: target, url: url, profileID: space.profileID, spaceTheme: space.theme)
        probes.append(probe)
        probe.onClose = { [weak self] p in self?.probes.removeAll { $0 === p } }
        probe.show()
    }

    var settingsWindow: NSWindow? { settingsController?.window }

    func showSettings(tab: SettingsTab? = nil) {
        // From the menu-bar icon or panel Cosmos is not the frontmost app, and Settings would open behind another one.
        NSApp.activate(ignoringOtherApps: true)
        if let c = settingsController, c.window?.isVisible == true {
            if tab == nil { c.window?.makeKeyAndOrderFront(nil); return }
            c.close()
        }
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsView.size), styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "Cosmos Settings"
        // The window is the space's sky edge to edge, with only the window buttons over it.
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        let dropdowns = DropdownHost()
        settingsDropdowns = dropdowns
        let hosting = NSHostingView(rootView: SettingsView(store: store, tab: tab ?? .general, dropdowns: dropdowns))
        // The window keeps the size it is given instead of growing to its content's idea of itself.
        hosting.sizingOptions = []
        win.contentView = hosting
        win.setFrame(NSRect(origin: .zero, size: SettingsView.size), display: false)
        win.center()
        let c = NSWindowController(window: win)
        settingsController = c
        c.showWindow(nil)
    }

    /// The browser window menu commands act on.
    var active: BrowserWindowController? {
        if let key = NSApp.keyWindow, let c = controllers.first(where: { $0.window === key }) { return c }
        return BrowserWindowRegistry.shared.last.flatMap { l in controllers.contains(where: { $0 === l }) ? l : nil } ?? controllers.last
    }

    // MARK: Links from other apps

    func openExternal(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https", "file"].contains(scheme) else { return }
        // A link from another app follows the link rules whether or not a window is open, and goes to one of the browser's
        // own windows, never to a private one that happens to be in front.
        let destination: LinkDestination = scheme == "file" ? .mostRecentSpace : store.linkRouting.destination(for: url)
        if case .probe = destination { openProbe(url, store: store); return }
        func own() -> BrowserWindowController? { active.flatMap { $0.store === store ? $0 : nil } ?? controllers.last { $0.store === store } }
        if own() == nil { newWindow() }
        guard let controller = own() else { return }
        if case .space(let id) = destination, store.workspace.space(id) != nil { store.switchSpace(to: id, in: controller.state) }
        open(url, in: controller)
    }

    private func open(_ url: URL, in c: BrowserWindowController) {
        c.store.newTab(url: url, in: c.state)
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Menu validation

    /// Whether menu commands that act on a browser window mean anything now. They do not while the menu-bar panel holds the
    /// keyboard: `active` would fall back to the last browser window and the command would change a window nobody is
    /// looking at.
    static func windowCommandsApply(keyWindow: NSWindow?) -> Bool { !(keyWindow is MenuBarPanel) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.representedObject as? MenuAction else { return true }
        if let feature = action.feature, store?.settings.isOn(feature) == false { return false }
        if action.needsWindow {
            guard Self.windowCommandsApply(keyWindow: NSApp.keyWindow), let c = active else { return false }
            return action.enabled?(c) ?? true
        }
        return true
    }

    @objc func performMenuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuAction else { return }
        if let feature = action.feature, store?.settings.isOn(feature) == false { return }
        if action.needsWindow {
            guard Self.windowCommandsApply(keyWindow: NSApp.keyWindow), let c = active else { return }
            action.run(c)
        } else {
            action.run(active)
        }
    }
}

/// A menu item's behaviour, carried on the item.
@MainActor
final class MenuAction: NSObject {
    let needsWindow: Bool
    /// The feature the item belongs to: while that is switched off the item is hidden and does nothing.
    let feature: Feature?
    let enabled: ((BrowserWindowController) -> Bool)?
    private let body: (BrowserWindowController?) -> Void

    init(needsWindow: Bool, feature: Feature? = nil, enabled: ((BrowserWindowController) -> Bool)?, body: @escaping (BrowserWindowController?) -> Void) {
        self.needsWindow = needsWindow; self.feature = feature; self.enabled = enabled; self.body = body
    }

    func run(_ c: BrowserWindowController?) { body(c) }
}
