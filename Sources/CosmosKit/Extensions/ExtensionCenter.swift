import AppKit
import Foundation
import Observation
import WebKit
import CosmosCore
import CosmosImport

/// An extension the user has added to Cosmos. The files live in `<data folder>/Extensions/<id>/`, a copy that no longer
/// depends on the browser it came from.
struct InstalledExtension: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var version: String
    var enabled: Bool
    var installedAt: Date
    /// Where it came from, for display: "Arc", "Chrome Web Store", "a folder".
    var origin: String
    var webStoreID: String?
    /// What the user agreed to when adding it.
    var permissions: [String]
    var hostPatterns: [String]
}

enum ExtensionError: LocalizedError {
    case unsupportedSystem
    case notAnExtension
    case invalid(String)
    case download(String)
    case declined

    var errorDescription: String? {
        switch self {
        case .unsupportedSystem: return "Extensions need macOS 15.4 or later."
        case .notAnExtension: return "That folder doesn't contain an extension (there is no manifest.json)."
        case .invalid(let why): return "Cosmos can't run this extension: \(why)"
        case .download(let why): return "The download failed: \(why)"
        case .declined: return "Not added."
        }
    }
}

/// What the sidebar shows for one extension's toolbar button on the current tab.
struct ExtensionActionDisplay: Identifiable {
    var id: UUID
    var label: String
    var icon: NSImage?
    var badge: String
    var isEnabled: Bool
}

/// Everything about browser extensions that works on any macOS version: the list of what is installed, adding and
/// removing, finding extensions in other browsers and the Web Store. Running them is `ExtensionEngine`'s job, which
/// only exists on macOS 15.4+ where WebKit supports web extensions.
@MainActor
@Observable
final class ExtensionCenter {
    private(set) var items: [InstalledExtension] = []
    private(set) var loadErrors: [UUID: String] = [:]
    private(set) var busy = false
    /// The outcome of the last install or removal, shown in Settings.
    var message: String?
    /// Bumped when an extension's button changes (badge, icon, title) so the sidebar redraws.
    private(set) var actionRevision = 0
    private(set) var started = false

    @ObservationIgnored weak var store: BrowserStore?
    @ObservationIgnored let directory: URL
    @ObservationIgnored private let file: JSONFileStore<Library>
    @ObservationIgnored private(set) var engine: AnyObject?
    @ObservationIgnored let persistentStorage: Bool

    private struct Library: Codable { var items: [InstalledExtension] = [] }

    nonisolated static var isSupported: Bool {
        if #available(macOS 15.4, *) { return true }
        return false
    }

    /// - Parameter persistentStorage: whether extensions keep their own data (storage, caches) between launches.
    ///   Demos and tests pass `false` so they leave nothing behind.
    init(store: BrowserStore, directory: URL, persistentStorage: Bool = true) {
        self.store = store
        self.directory = directory
        self.persistentStorage = persistentStorage
        file = JSONFileStore<Library>(url: directory.appendingPathComponent("extensions.json"))
        items = ((try? file.load()) ?? nil)?.items ?? []
    }

    var extensionsFolder: URL { directory.appendingPathComponent("Extensions", isDirectory: true) }
    func folder(for item: InstalledExtension) -> URL { extensionsFolder.appendingPathComponent(item.id.uuidString, isDirectory: true) }

    private func save() {
        do { try file.save(Library(items: items)) } catch { message = "Couldn't save the extension list." }
    }

    @available(macOS 15.4, *)
    var running: ExtensionEngine? { engine as? ExtensionEngine }

    /// The `WKWebExtensionController` new web views must be configured with, once it exists.
    var controllerObject: AnyObject? {
        if #available(macOS 15.4, *) { return running?.controller }
        return nil
    }

    // MARK: Starting

    /// Creates the engine and loads every enabled extension. Called once at launch, before windows open, so the
    /// controller is there for the first web view (loading finishes a moment later).
    func start() {
        guard !started else { return }
        started = true
        guard #available(macOS 15.4, *), let store else { return }
        let engine = ExtensionEngine(center: self, store: store, persistent: persistentStorage)
        self.engine = engine
        for window in store.windows { engine.windowOpened(window) }
        Task { [weak self] in
            guard let self else { return }
            for item in self.items where item.enabled { await self.load(item) }
        }
    }

    @available(macOS 15.4, *)
    private func load(_ item: InstalledExtension) async {
        guard let engine = running else { return }
        do {
            try await engine.load(item, from: folder(for: item))
            loadErrors[item.id] = nil
        } catch {
            loadErrors[item.id] = error.localizedDescription
        }
        actionRevision += 1
    }

    // MARK: Adding

    /// Adds the unpacked extension in `source` (a folder with `manifest.json`). `confirm` is asked, with the manifest's
    /// requests spelled out in plain words, before anything is copied; return `false` to cancel.
    @discardableResult
    func install(from source: URL, origin: String, webStoreID: String? = nil,
                 confirm: (ExtensionRequestSummary) async -> Bool) async throws -> InstalledExtension {
        guard #available(macOS 15.4, *), let engine = running else { throw ExtensionError.unsupportedSystem }
        guard let manifest = ChromiumExtensionScanner.readManifest(source) else { throw ExtensionError.notAnExtension }
        busy = true
        defer { busy = false }

        let probe = try await engine.inspect(source)
        let name = ChromiumExtensionScanner.displayName(manifest: manifest, directory: source) ?? probe.name
        let summary = ExtensionRequestSummary(name: name, version: probe.version, origin: origin,
                                              permissions: probe.permissions, hostPatterns: probe.hostPatterns, problems: probe.problems)
        guard await confirm(summary) else { throw ExtensionError.declined }

        let item = InstalledExtension(id: UUID(), name: name, version: probe.version, enabled: true, installedAt: Date(), origin: origin,
                                      webStoreID: webStoreID, permissions: probe.permissions, hostPatterns: probe.hostPatterns)
        let destination = folder(for: item)
        let fm = FileManager.default
        try fm.createDirectory(at: extensionsFolder, withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: destination)
        items.removeAll { $0.webStoreID != nil && $0.webStoreID == webStoreID }
        items.append(item)
        save()
        await load(item)
        if let problem = loadErrors[item.id] {
            // Not loadable after all: don't leave a dead entry behind.
            remove(item.id)
            throw ExtensionError.invalid(problem)
        }
        message = "Added “\(name)”."
        return item
    }

    /// Installs from a Chrome Web Store id or link by downloading the package from Google's update service.
    @discardableResult
    func installFromWebStore(_ text: String, confirm: (ExtensionRequestSummary) async -> Bool) async throws -> InstalledExtension {
        guard let id = ChromeWebStore.extensionID(from: text), let url = ChromeWebStore.downloadURL(for: id) else {
            throw ExtensionError.invalid("that isn't a Chrome Web Store link or extension id.")
        }
        busy = true
        defer { busy = false }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-ext-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.setValue("Mozilla/5.0 (Macintosh) Cosmos", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw ExtensionError.download(http.statusCode == 204 ? "the Web Store doesn't offer that extension." : "the Web Store answered \(http.statusCode).")
            }
            let zip = try ChromeWebStore.zipPayload(fromCRX: data)
            let zipFile = work.appendingPathComponent("package.zip")
            try zip.write(to: zipFile)
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            try Self.unzip(zipFile, into: unpacked)
            return try await install(from: unpacked, origin: "Chrome Web Store", webStoreID: id, confirm: confirm)
        } catch let error as ExtensionError {
            throw error
        } catch {
            throw ExtensionError.download(error.localizedDescription)
        }
    }

    private static func unzip(_ zip: URL, into destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, destination.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ExtensionError.invalid("the package couldn't be unpacked.") }
    }

    /// Extensions found in Arc and other Chromium browsers on this Mac, newest first by name, minus those already added.
    func discoverable() async -> [DiscoveredExtension] {
        let found = await Task.detached(priority: .userInitiated) { ChromiumExtensionScanner.scanAll() }.value
        let have = Set(items.compactMap(\.webStoreID))
        var seen = Set<String>()
        return found.filter { !have.contains($0.id) && seen.insert($0.id).inserted }
    }

    // MARK: Managing

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].enabled != on else { return }
        items[i].enabled = on
        save()
        guard #available(macOS 15.4, *) else { return }
        if on {
            let item = items[i]
            Task { await load(item) }
        } else {
            running?.unload(id)
            loadErrors[id] = nil
            actionRevision += 1
        }
    }

    func remove(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if #available(macOS 15.4, *) { running?.remove(id) }
        items.removeAll { $0.id == id }
        loadErrors[id] = nil
        try? FileManager.default.removeItem(at: folder(for: item))
        save()
        actionRevision += 1
    }

    // MARK: Toolbar buttons and events

    func noteActionChanged() { actionRevision += 1 }

    func actions(for runtime: TabRuntime?) -> [ExtensionActionDisplay] {
        _ = actionRevision
        guard #available(macOS 15.4, *), let engine = running else { return [] }
        return items.filter(\.enabled).compactMap { engine.actionDisplay(for: $0.id, runtime: runtime) }
    }

    func performAction(_ id: UUID, runtime: TabRuntime?, anchor: NSView?) {
        guard #available(macOS 15.4, *) else { return }
        running?.performAction(id, runtime: runtime, anchor: anchor)
    }

    func tabOpened(_ runtime: TabRuntime) { if #available(macOS 15.4, *) { running?.tabOpened(runtime) } }
    func tabClosed(_ runtime: TabRuntime) { if #available(macOS 15.4, *) { running?.tabClosed(runtime) } }
    func tabActivated(_ runtime: TabRuntime?, previous: TabRuntime?) { if #available(macOS 15.4, *) { running?.tabActivated(runtime, previous: previous) } }
    func tabChanged(_ runtime: TabRuntime, loading: Bool = false) { if #available(macOS 15.4, *) { running?.tabChanged(runtime, loading: loading) } }
    func windowOpened(_ window: WindowState) { if #available(macOS 15.4, *) { running?.windowOpened(window) } }
    func windowClosed(_ window: WindowState) { if #available(macOS 15.4, *) { running?.windowClosed(window) } }
    func windowFocused(_ window: WindowState?) { if #available(macOS 15.4, *) { running?.windowFocused(window) } }
}

/// What an extension asks for, in a form the "Add extension?" prompt can show.
struct ExtensionRequestSummary {
    var name: String
    var version: String
    var origin: String
    var permissions: [String]
    var hostPatterns: [String]
    /// Manifest problems and features WebKit can't run, in plain words.
    var problems: [String]

    /// Plain-language lines for each permission and for site access.
    var lines: [String] {
        var out: [String] = []
        let all = hostPatterns.contains { $0 == "<all_urls>" || $0 == "*://*/*" || $0.hasPrefix("*://*/") || $0 == "http://*/*" || $0 == "https://*/*" }
        if all { out.append("Read and change your data on all websites") }
        else if !hostPatterns.isEmpty {
            var unique: [String] = []
            for pattern in hostPatterns {
                if let host = Self.host(of: pattern), !unique.contains(host) { unique.append(host) }
            }
            out.append("Read and change your data on \(unique.prefix(4).joined(separator: ", "))" + (unique.count > 4 ? " and \(unique.count - 4) more sites" : ""))
        }
        for permission in permissions {
            if let text = Self.words[permission] { out.append(text) }
        }
        return out
    }

    /// "https://*.example.com/path" gives "example.com"; "*://*/*" gives `nil`.
    static func host(of pattern: String) -> String? {
        guard let scheme = pattern.range(of: "://") else { return nil }
        var rest = pattern[scheme.upperBound...]
        if let slash = rest.firstIndex(of: "/") { rest = rest[..<slash] }
        var host = String(rest)
        if host.hasPrefix("*.") { host.removeFirst(2) }
        return host.isEmpty || host == "*" ? nil : host
    }

    private static let words: [String: String] = [
        "tabs": "See the titles and addresses of your tabs",
        "activeTab": "Use the page you're on when you click its button",
        "storage": "Save its own settings and data",
        "unlimitedStorage": "Store large amounts of its own data",
        "cookies": "Read and change cookies",
        "scripting": "Run scripts on the pages it can access",
        "declarativeNetRequest": "Block or redirect web requests",
        "declarativeNetRequestWithHostAccess": "Block or redirect web requests on the sites it can access",
        "declarativeNetRequestFeedback": "See which requests it blocked",
        "webRequest": "See your network requests",
        "webNavigation": "See when you navigate between pages",
        "nativeMessaging": "Talk to other apps on your Mac",
        "clipboardWrite": "Copy to your clipboard",
        "contextMenus": "Add items to right-click menus",
        "menus": "Add items to right-click menus",
        "alarms": "Run tasks on a schedule",
    ]

    /// Permissions Chrome has that WebKit's extension engine doesn't provide.
    static let unsupported: Set<String> = ["history", "bookmarks", "downloads", "identity", "management", "notifications", "offscreen", "sidePanel",
                                           "topSites", "proxy", "privacy", "browsingData", "sessions", "tabGroups", "webAuthenticationProxy",
                                           "contentSettings", "debugger", "desktopCapture", "pageCapture", "tabCapture", "system.cpu", "system.memory", "system.storage"]
}
