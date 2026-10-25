import AppKit
import Foundation
import WebKit
import CosmosCore
import CosmosImport

struct ExtensionProbe {
    var name: String
    var version: String
    var permissions: [String]
    var hostPatterns: [String]
    var problems: [String]
}

/// Runs extensions with WebKit's `WKWebExtensionController` (macOS 15.4+): loads and unloads them, tells WebKit about
/// Cosmos's windows and tabs so `chrome.tabs`, content scripts and messaging work, and shows toolbar popups.
@available(macOS 15.4, *)
@MainActor
final class ExtensionEngine: NSObject, WKWebExtensionControllerDelegate {
    /// Names the controller's persistent storage. Fixed, so extension data survives restarts.
    private static let allData: Set<WKWebExtension.DataType> = [.local, .session, .synchronized]
    private static let controllerID = UUID(uuidString: "C05A05E7-1E57-4D0C-A5B0-000000000E71")!

    let controller: WKWebExtensionController
    private weak var center: ExtensionCenter?
    private weak var store: BrowserStore?
    private var contexts: [UUID: WKWebExtensionContext] = [:]
    private let tabAdapters = NSMapTable<AnyObject, ExtensionTab>.weakToStrongObjects()
    private let windowAdapters = NSMapTable<AnyObject, ExtensionWindow>.weakToStrongObjects()
    /// The toolbar button last clicked: the popup opens next to it.
    private weak var anchorView: NSView?

    init(center: ExtensionCenter, store: BrowserStore, persistent: Bool) {
        self.center = center
        self.store = store
        let configuration = persistent ? WKWebExtensionController.Configuration(identifier: Self.controllerID) : WKWebExtensionController.Configuration.nonPersistent()
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    // MARK: Loading

    /// Reads an extension folder without loading it, for the "Add extension?" prompt.
    func inspect(_ folder: URL) async throws -> ExtensionProbe {
        let ext: WKWebExtension
        do { ext = try await WKWebExtension(resourceBaseURL: folder) }
        catch { throw ExtensionError.invalid(error.localizedDescription) }
        guard ext.supportsManifestVersion(2) || ext.supportsManifestVersion(3) else { throw ExtensionError.invalid("its manifest version isn't supported.") }
        let permissions = ext.requestedPermissions.map(\.rawValue).sorted()
        let hosts = ext.allRequestedMatchPatterns.map(\.string).sorted()
        var problems = ext.errors.map(\.localizedDescription)
        let missing = permissions.filter { ExtensionRequestSummary.unsupported.contains($0) }
        if !missing.isEmpty { problems.append("Parts of it that use \(missing.joined(separator: ", ")) won't work in Cosmos.") }
        return ExtensionProbe(name: ext.displayName ?? folder.lastPathComponent, version: ext.displayVersion ?? "", permissions: permissions,
                              hostPatterns: hosts, problems: problems)
    }

    func load(_ item: InstalledExtension, from folder: URL) async throws {
        unload(item.id)
        let ext = try await WKWebExtension(resourceBaseURL: folder)
        let context = WKWebExtensionContext(for: ext)
        let identifier = (item.webStoreID ?? item.id.uuidString).lowercased()
        context.uniqueIdentifier = identifier
        if let base = URL(string: "webkit-extension://\(identifier)") { context.baseURL = base }
        context.isInspectable = true
        context.inspectionName = item.name
        // What the user agreed to when adding it.
        let never = Date.distantFuture
        for permission in item.permissions { context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: permission), expirationDate: never) }
        for pattern in item.hostPatterns {
            if let p = try? WKWebExtension.MatchPattern(string: pattern) { context.setPermissionStatus(.grantedExplicitly, for: p, expirationDate: never) }
        }
        try controller.load(context)
        contexts[item.id] = context
    }

    func unload(_ id: UUID) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        try? controller.unload(context)
    }

    /// Unloads and also deletes what the extension stored.
    func remove(_ id: UUID) {
        let context = contexts[id]
        unload(id)
        guard let context else { return }
        controller.fetchDataRecord(ofTypes: Self.allData, for: context) { [controller] record in
            guard let record else { return }
            controller.removeData(ofTypes: Self.allData, from: [record]) {}
        }
    }

    // MARK: Windows and tabs

    func tab(for runtime: TabRuntime) -> ExtensionTab {
        if let existing = tabAdapters.object(forKey: runtime) { return existing }
        let adapter = ExtensionTab(runtime: runtime, engine: self)
        tabAdapters.setObject(adapter, forKey: runtime)
        return adapter
    }

    func window(for state: WindowState) -> ExtensionWindow {
        if let existing = windowAdapters.object(forKey: state) { return existing }
        let adapter = ExtensionWindow(state: state, engine: self)
        windowAdapters.setObject(adapter, forKey: state)
        return adapter
    }

    var store_: BrowserStore? { store }

    func windowOpened(_ window: WindowState) { controller.didOpenWindow(self.window(for: window)) }
    func windowClosed(_ window: WindowState) { controller.didCloseWindow(self.window(for: window)); windowAdapters.removeObject(forKey: window) }
    func windowFocused(_ window: WindowState?) { controller.didFocusWindow(window.map { self.window(for: $0) }) }

    func tabOpened(_ runtime: TabRuntime) { controller.didOpenTab(tab(for: runtime)) }

    func tabClosed(_ runtime: TabRuntime) {
        controller.didCloseTab(tab(for: runtime), windowIsClosing: false)
        tabAdapters.removeObject(forKey: runtime)
    }

    func tabActivated(_ runtime: TabRuntime?, previous: TabRuntime?) {
        guard let runtime else { return }
        controller.didActivateTab(tab(for: runtime), previousActiveTab: previous.map { tab(for: $0) })
        controller.didSelectTabs([tab(for: runtime)])
    }

    func tabChanged(_ runtime: TabRuntime, loading: Bool) {
        var changed: WKWebExtension.TabChangedProperties = [.title, .URL]
        if loading { changed.insert(.loading) }
        controller.didChangeTabProperties(changed, for: tab(for: runtime))
    }

    // MARK: Toolbar buttons

    func actionDisplay(for id: UUID, runtime: TabRuntime?) -> ExtensionActionDisplay? {
        guard let context = contexts[id], let action = context.action(for: runtime.map { tab(for: $0) }) else { return nil }
        return ExtensionActionDisplay(id: id, label: action.label, icon: action.icon(for: CGSize(width: 18, height: 18)),
                                      badge: action.badgeText, isEnabled: action.isEnabled)
    }

    func performAction(_ id: UUID, runtime: TabRuntime?, anchor: NSView?) {
        guard let context = contexts[id] else { return }
        anchorView = anchor
        context.performAction(for: runtime.map { tab(for: $0) })
    }

    // MARK: Delegate

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        (store?.windows ?? []).map { window(for: $0) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        (store?.activeWindow ?? store?.windows.first).map { window(for: $0) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        guard let store else { return nil }
        let target = (configuration.window as? ExtensionWindow)?.state ?? store.activeWindow ?? store.windows.first
        guard let target, let id = store.newTab(url: configuration.url, in: target, activate: configuration.shouldBeActive),
              let runtime = store.ensureRuntime(forItem: id, in: target, load: false) else { return nil }
        if configuration.shouldBeMuted { runtime.isMuted = true }
        return tab(for: runtime)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
        guard let url = extensionContext.optionsPageURL, let store, let window = store.activeWindow ?? store.windows.first else { return }
        _ = store.newTab(url: url, in: window)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        let names = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        let allowed = Self.ask("“\(extensionContext.webExtension.displayName ?? "An extension")” wants more access", "It is asking for: \(names).")
        return (allowed ? permissions : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        let hosts = Set(urls.compactMap(\.host)).sorted().prefix(4).joined(separator: ", ")
        let allowed = Self.ask("“\(extensionContext.webExtension.displayName ?? "An extension")” wants to use \(hosts)", "It will be able to read and change your data on this site.")
        return (allowed ? urls : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        let hosts = matchPatterns.map(\.string).sorted().prefix(4).joined(separator: ", ")
        let allowed = Self.ask("“\(extensionContext.webExtension.displayName ?? "An extension")” wants to use \(hosts)", "It will be able to read and change your data on these sites.")
        return (allowed ? matchPatterns : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        center?.noteActionChanged()
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext) async throws {
        guard let popover = action.popupPopover else { return }
        if let anchor = anchorView, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else if let content = NSApp.keyWindow?.contentView {
            popover.show(relativeTo: NSRect(x: 60, y: content.bounds.maxY - 56, width: 1, height: 1), of: content, preferredEdge: .maxY)
        }
    }

    private static func ask(_ title: String, _ detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
