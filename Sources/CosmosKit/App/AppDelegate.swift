import AppKit
import SwiftUI
import WebKit
import CosmosCore

/// Command-line / environment switches. Real users never need them; they exist for demos and automated checks.
struct LaunchOptions {
    var dataDirectory: URL?
    var demo = false
    var automationScript: URL?

    static func parse(_ args: [String], env: [String: String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--data-dir": if i + 1 < args.count { o.dataDirectory = URL(fileURLWithPath: args[i + 1]); i += 1 }
            case "--demo": o.demo = true
            case "--automation": if i + 1 < args.count { o.automationScript = URL(fileURLWithPath: args[i + 1]); i += 1 }
            default: break
            }
            i += 1
        }
        if o.dataDirectory == nil, let d = env["COSMOS_DATA_DIR"] { o.dataDirectory = URL(fileURLWithPath: d) }
        if o.automationScript == nil, let a = env["COSMOS_AUTOMATION"] { o.automationScript = URL(fileURLWithPath: a) }
        if env["COSMOS_DEMO"] == "1" { o.demo = true }
        return o
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
    let app = NSApplication.shared
    if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
        exit(renderAppIcon(to: CommandLine.arguments[i + 1]) ? 0 : 1)
    }
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
    private(set) var controllers: [BrowserWindowController] = []
    private var probes: [ProbeWindowController] = []
    var probeCount: Int { probes.count }
    private var settingsController: NSWindowController?
    private var automation: Automation?
    private var pendingURLs: [URL] = []
    private var launched = false

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = BrowserStore(directory: options.resolvedDataDirectory)
        wire(store)
        NSApp.appearance = store.settings.appearance.nsAppearance
        NSApp.mainMenu = makeMainMenu()
        installKeyChords()
        if options.demo { DemoSeed.populate(store) }

        let saved = store.savedSession?.windows.count ?? 0
        let count = (store.settings.restoreTabsOnLaunch && !options.demo) ? max(1, saved) : 1
        for i in 0..<count { openWindow(state: store.makeWindowState(restoring: i), restoreSelection: true) }
        if store.isFirstLaunch && !store.settings.hasCompletedOnboarding, let first = controllers.first {
            first.state.overlay = .welcome
        }
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
        store.saveSession()
        store.saveNow()
        store.isTerminating = true
        for c in controllers { c.store.isTerminating = true }
        return .terminateNow
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
        store.onOpenProbe = { [weak self, weak store] url in
            guard let self, let store else { return }
            self.openProbe(url, store: store)
        }
        store.onPopupWindow = { runtime, features in
            PopupWindows.present(runtime, features: WKWindowFeaturesBox(features))
        }
        store.downloads.onEvent = { [weak self, weak store] item in
            guard let self, let store else { return }
            self.activeState(for: store)?.showToast("Downloading \(item.filename)", symbol: "arrow.down.circle.fill")
        }
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
        controller.onClose = { [weak self] c in self?.controllers.removeAll { $0 === c } }
        controller.showWindow(nil)
        if restoreSelection, let sel = state.selection[state.focusedSpaceID], st.workspace.item(sel) != nil {
            st.select(sel, in: state)
        }
        return controller
    }

    func newWindow() {
        let space = active?.state.focusedSpaceID ?? store.workspace.spaces[0].id
        let state = WindowState(focusedSpaceID: space, sidebarWidth: store.settings.sidebarWidth)
        let c = openWindow(state: state)
        state.overlay = .commandBar(.newTab)
        c.window?.makeKeyAndOrderFront(nil)
    }

    func newIncognitoWindow() {
        let incognito = BrowserStore(directory: nil, incognito: true)
        wire(incognito)
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

    func showSettings() {
        if let c = settingsController, c.window?.isVisible == true { c.window?.makeKeyAndOrderFront(nil); return }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Cosmos Settings"
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: SettingsView(store: store))
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
        guard let controller = active ?? controllers.first else {
            newWindow()
            if let c = active { open(url, in: c) }
            return
        }
        if scheme == "file" { open(url, in: controller); return }
        switch store.linkRouting.destination(for: url) {
        case .probe: openProbe(url, store: store)
        case .mostRecentSpace: open(url, in: controller)
        case .space(let id):
            guard store.workspace.space(id) != nil else { open(url, in: controller); return }
            store.switchSpace(to: id, in: controller.state)
            open(url, in: controller)
        }
    }

    private func open(_ url: URL, in c: BrowserWindowController) {
        c.store.newTab(url: url, in: c.state)
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Menu validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.representedObject as? MenuAction else { return true }
        if action.needsWindow {
            guard let c = active else { return false }
            return action.enabled?(c) ?? true
        }
        return true
    }

    @objc func performMenuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuAction else { return }
        if action.needsWindow {
            guard let c = active else { return }
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
    let enabled: ((BrowserWindowController) -> Bool)?
    private let body: (BrowserWindowController?) -> Void

    init(needsWindow: Bool, enabled: ((BrowserWindowController) -> Bool)?, body: @escaping (BrowserWindowController?) -> Void) {
        self.needsWindow = needsWindow; self.enabled = enabled; self.body = body
    }

    func run(_ c: BrowserWindowController?) { body(c) }
}
