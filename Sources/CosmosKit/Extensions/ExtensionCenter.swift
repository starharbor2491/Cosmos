import AppKit
import CryptoKit
import Foundation
import Observation
import CosmosCore
import CosmosEngine
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
    case notAnExtension
    case invalid(String)
    case download(String)
    case declined

    var errorDescription: String? {
        switch self {
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

/// The browser extensions the user added: the list, adding and removing, finding extensions in other browsers and the
/// Web Store. The engine runs them, in every profile, with its own `chrome.*` APIs; what a browser would draw for them
/// (the toolbar button, its popup, menu items, shortcuts) Cosmos draws from here.
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
    /// The engine's id of each loaded extension, the same in every profile: the Web Store's for one whose manifest has its
    /// key (as Cosmos writes it), otherwise one made from its folder.
    @ObservationIgnored private var engineIDs: [UUID: String] = [:]
    /// Gets what is at an address (the Web Store's update service, a package), failing on anything but a 200.
    @ObservationIgnored var fetch: (URL) async throws -> Data = ExtensionCenter.download
    /// Newer versions of Web Store extensions that ask for more than the user agreed to: they wait for the user's OK.
    private(set) var updatesWaiting: [UUID: String] = [:]
    /// True while Cosmos asks the Web Store about updates.
    private(set) var checking = false
    @ObservationIgnored private var environments: [WeakEnvironment] = []
    @ObservationIgnored private(set) var popup: ExtensionPopup?
    /// Popups dragged away from their buttons: open until they are closed, whatever popup opens next.
    @ObservationIgnored private(set) var detachedPopups: [ExtensionPopup] = []
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var updating: Task<Void, Never>?
    /// The Web Store ids a store page's Add to Chrome is adding now.
    @ObservationIgnored private var adding: Set<String> = []

    private struct Library: Codable { var items: [InstalledExtension] = [] }
    private struct WeakEnvironment { weak var value: ProfileEnvironment? }

    init(store: BrowserStore, directory: URL) {
        self.store = store
        self.directory = directory
        file = JSONFileStore<Library>(url: directory.appendingPathComponent("extensions.json"))
        items = ((try? file.load()) ?? nil)?.items ?? []
    }

    var extensionsFolder: URL { directory.appendingPathComponent("Extensions", isDirectory: true) }
    func folder(for item: InstalledExtension) -> URL { extensionsFolder.appendingPathComponent(item.id.uuidString, isDirectory: true) }

    private func save() {
        do { try file.save(Library(items: items)) } catch { message = "Couldn't save the extension list." }
    }

    // MARK: Starting

    /// Extensions as a whole are switched on (Settings ▸ Features). Off, none runs and none is checked for updates; each
    /// keeps its own on or off for when they are back.
    var isOn: Bool { store?.settings.isOn(.extensions) ?? true }

    /// The switch's moves, one after another: each waits for the one before it to be done in Chromium, then brings
    /// Chromium to what the switch says by then. Flipped quickly, it ends as the last flip says, and an extension is never
    /// being loaded and unloaded (or loaded twice) at once.
    private var switching: Task<Void, Never>?

    /// The switch moved: every enabled extension goes, popups and all, or comes back.
    func featureSwitched() {
        guard started else { return }
        if !isOn { for open in [popup].compactMap({ $0 }) + detachedPopups { open.close() } }
        let before = switching
        switching = Task { [weak self] in
            await before?.value
            await self?.followSwitch()
        }
        actionRevision += 1
    }

    private func followSwitch() async {
        for item in items where item.enabled {
            if isOn {
                if engineIDs[item.id] == nil { _ = await loadEverywhere(item) }
            } else {
                await unloadEverywhere(item.id)
            }
        }
    }

    /// Loads every enabled extension into each profile as the profile opens, and listens for their shortcuts.
    func start() {
        guard !started else { return }
        started = true
        for env in store?.environments.values.map({ $0 }) ?? [] { environmentCreated(env) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleShortcut(event) == true ? nil : event
        }
    }

    /// A profile opened: its engine gets every enabled extension.
    func environmentCreated(_ env: ProfileEnvironment) {
        guard started, let engine = env.engineProfile.extensions else { return }
        environments.removeAll { $0.value == nil }
        environments.append(WeakEnvironment(value: env))
        engine.onChange = { [weak self] in self?.actionRevision += 1 }
        // `chrome.notifications`: Cosmos posts them to macOS, and a click goes back to the extension.
        engine.onNotification = { [weak self, weak engine] extensionID, note in
            guard let notifier = self?.store?.notifier else { return }
            notifier.show(note, key: "extension/\(extensionID)/\(note.id)") { action in
                guard let engine else { return }
                Task { await engine.notification(note.id, of: extensionID, did: action) }
            }
        }
        engine.onNotificationClosed = { [weak self] extensionID, id in self?.store?.notifier.close(key: "extension/\(extensionID)/\(id)") }
        engine.onSidePanelRequest = { [weak self, weak engine, weak env] extensionID, page in
            guard let self, let engine, let env else { return }
            self.toggleSidePanel(extensionID, for: page, engine: engine, environment: env)
        }
        let enabled = isOn ? items.filter(\.enabled) : []
        Task { for item in enabled { await load(item, into: env) } }
    }

    private var liveEnvironments: [ProfileEnvironment] { environments.compactMap(\.value) }

    /// Shows an extension's side panel in the window of the tab it is for, beside the page; the same request again
    /// closes it, as the button does in Chrome.
    private func toggleSidePanel(_ extensionID: String, for page: EnginePage?, engine: EngineExtensions, environment env: ProfileEnvironment) {
        guard let store, let item = item(forEngineID: extensionID) else { return }
        let tab = page.flatMap { TabRuntime.owning($0) }
        guard let window = tab.flatMap({ store.window(showing: $0.itemID) }) ?? store.activeWindow ?? store.windows.first else { return }
        if window.sidePanel?.extensionID == extensionID {
            window.sidePanel?.runtime.tearDown()
            window.sidePanel = nil
            return
        }
        Task {
            guard let panel = await engine.openSidePanel(extensionID, for: page ?? store.currentRuntime(in: window)?.page) else { return }
            let runtime = TabRuntime(itemID: UUID(), profileID: env.profileID, page: panel, host: store)
            runtime.isEphemeral = true
            window.sidePanel?.runtime.tearDown()
            window.sidePanel = WindowState.SidePanel(extensionID: extensionID, title: item.name, runtime: runtime)
        }
    }

    @discardableResult
    private func load(_ item: InstalledExtension, into env: ProfileEnvironment) async -> Bool {
        guard let engine = env.engineProfile.extensions else { return false }
        defer { actionRevision += 1 }
        do {
            engineIDs[item.id] = try await engine.load(folder: folder(for: item))
            loadErrors[item.id] = nil
            // Switched off while Chromium was loading it: the switch's own pass may have gone by before it was in.
            if !isOn { await unloadEverywhere(item.id) }
            return true
        } catch {
            loadErrors[item.id] = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return false
        }
    }

    /// Into every open profile; at least the one the user is in, so a broken extension is found out now.
    private func loadEverywhere(_ item: InstalledExtension) async -> Bool {
        // Switched off, nothing is loaded; it will be when they are back on.
        guard isOn else { return true }
        if liveEnvironments.isEmpty, let store, let window = store.activeWindow ?? store.windows.first {
            _ = store.environment(forProfile: store.workspace.space(window.focusedSpaceID)?.profileID ?? store.workspace.profiles[0].id)
        }
        var ok = true
        for env in liveEnvironments where !(await load(item, into: env)) { ok = false }
        return ok
    }

    private func unloadEverywhere(_ id: UUID) async {
        guard let engineID = engineIDs.removeValue(forKey: id) else { return }
        // A newer copy of the same extension (the same key, so the same id) took its place in the engine: that one stays.
        if !engineIDs.values.contains(engineID) {
            for env in liveEnvironments { await env.engineProfile.extensions?.unload(id: engineID) }
        }
        actionRevision += 1
    }

    // MARK: Adding

    /// Adds the unpacked extension in `source` (a folder with `manifest.json`). `confirm` is asked, with the manifest's
    /// requests spelled out in plain words, before anything is copied; return `false` to cancel.
    @discardableResult
    func install(from source: URL, origin: String, webStoreID: String? = nil, enabled: Bool = true,
                 confirm: (ExtensionRequestSummary) async -> Bool) async throws -> InstalledExtension {
        guard let manifest = ChromiumExtensionScanner.readManifest(source) else { throw ExtensionError.notAnExtension }
        busy = true
        defer { busy = false }

        let name = ChromiumExtensionScanner.displayName(manifest: manifest, directory: source) ?? manifest["name"] as? String ?? "Extension"
        let probe = ExtensionRequestSummary.read(manifest)
        let summary = ExtensionRequestSummary(name: name, version: probe.version, origin: origin,
                                              permissions: probe.permissions, hostPatterns: probe.hostPatterns, problems: probe.problems)
        guard await confirm(summary) else { throw ExtensionError.declined }

        let item = InstalledExtension(id: UUID(), name: name, version: probe.version, enabled: enabled, installedAt: Date(), origin: origin,
                                      webStoreID: webStoreID, permissions: probe.permissions, hostPatterns: probe.hostPatterns)
        let destination = folder(for: item)
        let fm = FileManager.default
        try fm.createDirectory(at: extensionsFolder, withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: destination)
        // The same Web Store extension again replaces the copy that was there.
        let replaced = items.filter { $0.webStoreID != nil && $0.webStoreID == webStoreID }
        items.append(item)
        save()
        // One that stays off is not loaded, so not tried either. A move of the switch still going on in Chromium goes first.
        await switching?.value
        let loads = enabled ? await loadEverywhere(item) : true
        guard loads else {
            // Not loadable after all: don't leave a dead entry behind.
            let problem = loadErrors[item.id] ?? "it would not load."
            remove(item.id)
            throw ExtensionError.invalid(problem)
        }
        for old in replaced {
            updatesWaiting[old.id] = nil
            remove(old.id)
        }
        message = isOn ? "Added “\(name)”." : "Added “\(name)”. Extensions are switched off in Settings ▸ Features."
        return item
    }

    /// Installs from a Chrome Web Store id or link by downloading the package from Google's update service.
    @discardableResult
    func installFromWebStore(_ text: String, confirm: (ExtensionRequestSummary) async -> Bool) async throws -> InstalledExtension {
        guard let id = ChromeWebStore.extensionID(from: text) else {
            throw ExtensionError.invalid("that isn't a Chrome Web Store link or extension id.")
        }
        guard let version = store?.engine.versionDescription, let url = ChromeWebStore.downloadURL(for: id, chromiumVersion: version) else {
            throw ExtensionError.download("Chromium hasn't started yet. Try again in a moment.")
        }
        busy = true
        defer { busy = false }
        return try await withPackage(from: url, id: id) { unpacked in
            try await install(from: unpacked, origin: "Chrome Web Store", webStoreID: id, confirm: confirm)
        }
    }

    /// A Chrome Web Store page's Add to Chrome: as `installFromWebStore`, but clicked again for an extension that is still
    /// being downloaded or asked about, it adds nothing and answers nil.
    func addFromStorePage(_ id: String, confirm: (ExtensionRequestSummary) async -> Bool) async throws -> InstalledExtension? {
        guard adding.insert(id).inserted else { return nil }
        defer { adding.remove(id) }
        return try await installFromWebStore(id, confirm: confirm)
    }

    /// Downloads the package at `url`, checks that it is extension `id`'s, signed by its developer (and, when the update
    /// service gave one, that its SHA-256 is `sha256`), unpacks it with its key written into the manifest, so that it keeps
    /// the Web Store's id, and hands the folder to `body`. The folder is gone afterwards.
    private func withPackage<T>(from url: URL, id: String, sha256: String? = nil, _ body: (URL) async throws -> T) async throws -> T {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-ext-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let data = try await fetch(url)
            if let sha256, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() != sha256 {
                throw ExtensionError.invalid("the package is not the one the Web Store described.")
            }
            let package: VerifiedPackage
            do { package = try ChromeWebStore.verifiedPackage(data, expectedID: id) } catch {
                throw ExtensionError.invalid("the package's signature doesn't check out, so it may not be what its developer published.")
            }
            let zipFile = work.appendingPathComponent("package.zip")
            try package.zip.write(to: zipFile)
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            try Self.unzip(zipFile, into: unpacked)
            try ChromeWebStore.writeKey(package.publicKey, intoManifestIn: unpacked)
            return try await body(unpacked)
        } catch let error as ExtensionError {
            throw error
        } catch {
            throw ExtensionError.download(error.localizedDescription)
        }
    }

    /// What the Web Store's servers answer, or an error for anything but a 200 (204: it has no such extension). Nothing is
    /// cached: the question names every extension the user has.
    nonisolated static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("Mozilla/5.0 (Macintosh) Cosmos", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await webStoreSession.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ExtensionError.download(http.statusCode == 204 ? "the Web Store doesn't offer that extension." : "the Web Store answered \(http.statusCode).")
        }
        return data
    }

    nonisolated private static let webStoreSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        // Nor are cookies, which would tie one day's question to the next.
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    // MARK: Updating

    /// Asks the Web Store about every extension from it, at once, and takes each newer version that asks for nothing more
    /// than the user agreed to; one that asks for more waits in `updatesWaiting` for the user's OK (`update(_:confirm:)`).
    /// A package that isn't its developer's, or isn't the version announced, is not taken. One check at a time. Returns
    /// how many were updated.
    @discardableResult
    func checkForUpdates() async -> Int {
        guard !checking, isOn else { return 0 }
        checking = true
        defer { checking = false }
        let fromStore = items.filter { $0.webStoreID != nil }
        guard let url = ChromeWebStore.updateCheckURL(fromStore.map { ($0.webStoreID!, $0.version) },
                                                      chromiumVersion: store?.engine.versionDescription ?? "") else { return 0 }
        guard store?.engine.versionDescription != nil, let answer = try? await fetch(url) else {
            message = "Cosmos couldn't reach the Web Store to look for updates."
            return 0
        }
        var updated = 0
        for update in ChromeWebStore.updates(fromResponse: answer) {
            guard let found = items.first(where: { $0.webStoreID == update.id }),
                  ChromeWebStore.isVersion(update.version, newerThan: found.version), updatesWaiting[found.id] != update.version else { continue }
            do {
                let outcome = try await withPackage(from: update.codebase, id: update.id, sha256: update.sha256) { unpacked -> UpdateOutcome in
                    guard let manifest = ChromiumExtensionScanner.readManifest(unpacked) else { throw ExtensionError.notAnExtension }
                    let asks = ExtensionRequestSummary.read(manifest)
                    // As Chromium compares versions: "1.1.0" is "1.1".
                    guard !ChromeWebStore.isVersion(asks.version, newerThan: update.version),
                          !ChromeWebStore.isVersion(update.version, newerThan: asks.version) else {
                        throw ExtensionError.invalid("the package is version \(asks.version), not the \(update.version) the Web Store announced.")
                    }
                    // As it is now: the user may have turned it off, or removed it, while the package came.
                    guard let item = items.first(where: { $0.id == found.id }) else { return .gone }
                    guard Set(asks.permissions).isSubset(of: item.permissions), Set(asks.hostPatterns).isSubset(of: item.hostPatterns) else {
                        return .waiting
                    }
                    try await install(from: unpacked, origin: item.origin, webStoreID: update.id, enabled: item.enabled) { _ in true }
                    return .installed
                }
                switch outcome {
                case .installed: updated += 1
                case .waiting: updatesWaiting[found.id] = update.version
                case .gone: break
                }
            } catch {
                loadErrors[found.id] = "Version \(update.version) wasn't installed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            }
        }
        message = updated == 0 ? "No extension had an update to take." : updated == 1 ? "Updated an extension." : "Updated \(updated) extensions."
        return updated
    }

    private enum UpdateOutcome { case installed, waiting, gone }

    /// Checks for updates a few minutes after Cosmos starts, then once a day.
    func checkForUpdatesDaily() {
        guard updating == nil else { return }
        updating = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5 * 60))
            while !Task.isCancelled, self != nil {
                await self?.checkForUpdates()
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    /// Takes the waiting newer version of `id`, once the user has agreed to what it asks for.
    func update(_ id: UUID, confirm: (ExtensionRequestSummary) async -> Bool) async throws {
        guard let item = items.first(where: { $0.id == id }), let webStoreID = item.webStoreID else { return }
        guard let version = store?.engine.versionDescription, let url = ChromeWebStore.downloadURL(for: webStoreID, chromiumVersion: version) else {
            throw ExtensionError.download("Chromium hasn't started yet. Try again in a moment.")
        }
        busy = true
        defer { busy = false }
        try await withPackage(from: url, id: webStoreID) { unpacked in
            guard let next = ChromiumExtensionScanner.readManifest(unpacked).map(ExtensionRequestSummary.read)?.version,
                  ChromeWebStore.isVersion(next, newerThan: item.version) else {
                throw ExtensionError.invalid("the Web Store has no newer version of it.")
            }
            guard let current = items.first(where: { $0.id == id }) else { return }
            _ = try await install(from: unpacked, origin: current.origin, webStoreID: webStoreID, enabled: current.enabled, confirm: confirm)
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
        let item = items[i]
        if on {
            Task { _ = await loadEverywhere(item) }
        } else {
            loadErrors[id] = nil
            closePopups(of: id)
            Task { await unloadEverywhere(id) }
        }
    }

    /// An extension turned off or removed takes its popups with it, the ones dragged away too.
    private func closePopups(of id: UUID) {
        for open in [popup].compactMap({ $0 }) + detachedPopups where open.extensionID == id { open.close() }
    }

    func remove(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        loadErrors[id] = nil
        closePopups(of: id)
        save()
        Task {
            await unloadEverywhere(id)
            try? FileManager.default.removeItem(at: folder(for: item))
        }
        actionRevision += 1
    }

    // MARK: Toolbar buttons

    private func engine(for runtime: TabRuntime) -> EngineExtensions? {
        liveEnvironments.first { $0.profileID == runtime.profileID }?.engineProfile.extensions
    }

    private func item(forEngineID engineID: String) -> InstalledExtension? {
        guard isOn, let id = engineIDs.first(where: { $0.value == engineID })?.key else { return nil }
        return items.first { $0.id == id && $0.enabled }
    }

    func actions(for runtime: TabRuntime?) -> [ExtensionActionDisplay] {
        _ = actionRevision
        guard let runtime, let engine = engine(for: runtime) else { return [] }
        return engine.actions(for: runtime.page).compactMap { action in
            guard let item = item(forEngineID: action.extensionID) else { return nil }
            return ExtensionActionDisplay(id: item.id, label: action.title.isEmpty ? item.name : action.title,
                                          icon: action.icon.flatMap(NSImage.init(data:)), badge: action.badgeText, isEnabled: action.isEnabled)
        }
    }

    func performAction(_ id: UUID, runtime: TabRuntime?, anchor: NSView?) {
        guard let runtime, let engineID = engineIDs[id], let engine = engine(for: runtime) else { return }
        Task {
            guard let page = await engine.performAction(engineID, on: runtime.page) else { actionRevision += 1; return }
            showPopup(page, of: id, under: anchor, in: runtime.view)
        }
    }

    private func showPopup(_ page: EnginePage, of id: UUID?, under button: NSView?, in tab: NSView) {
        popup?.close()
        let popup = ExtensionPopup(page: page)
        popup.extensionID = id
        popup.onClose = { [weak self, weak popup] in
            guard let self else { return }
            if self.popup === popup { self.popup = nil }
            self.detachedPopups.removeAll { $0 === popup }
        }
        popup.onDetach = { [weak self, weak popup] in
            guard let self, let popup, self.popup === popup else { return }
            self.popup = nil
            self.detachedPopups.append(popup)
        }
        self.popup = popup
        popup.show(under: button, in: tab)
    }

    // MARK: Menus and shortcuts

    /// Items for the right-click menu: the ones that run something (a parent only opens its children) and whose contexts
    /// match what the click was on.
    func menuItems(for runtime: TabRuntime, contexts: Set<String>) -> [ExtensionMenuItem] {
        guard let engine = engine(for: runtime) else { return [] }
        let all = engine.menuItems(for: runtime.page).filter { item(forEngineID: $0.extensionID) != nil }
        let parents = Set(all.compactMap { item in item.parentID.map { "\(item.extensionID)/\($0)" } })
        return all.filter { !parents.contains($0.id) && !contexts.isDisjoint(with: $0.contexts) }
    }

    func performMenuItem(_ item: ExtensionMenuItem, context: ExtensionClickContext, on runtime: TabRuntime) {
        guard let engine = engine(for: runtime) else { return }
        Task { await engine.performMenuItem(item, context: context, on: runtime.page) }
    }

    /// A key press that is one of an extension's shortcuts runs it, over the tab in the key window.
    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard let store, let window = store.activeWindow, let runtime = store.currentRuntime(in: window),
              let engine = engine(for: runtime) else { return false }
        for command in engine.commands where item(forEngineID: command.extensionID) != nil {
            guard let shortcut = ExtensionShortcut(command.shortcut), shortcut.matches(event) else { continue }
            Task {
                // `_execute_action` opens the popup, as the button does.
                if let popup = await engine.performCommand(command, on: runtime.page) {
                    showPopup(popup, of: item(forEngineID: command.extensionID)?.id, under: nil, in: runtime.view)
                }
            }
            return true
        }
        return false
    }
}

/// A shortcut as a manifest writes it (`Ctrl+Shift+Y`; on a Mac `Ctrl` is ⌘ and `MacCtrl` is ⌃).
struct ExtensionShortcut: Equatable {
    var modifiers: NSEvent.ModifierFlags
    var key: String

    init?(_ text: String) {
        var mods: NSEvent.ModifierFlags = []
        var key: String?
        for part in text.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            switch part {
            case "ctrl", "command": mods.insert(.command)
            case "macctrl": mods.insert(.control)
            case "alt", "option": mods.insert(.option)
            case "shift": mods.insert(.shift)
            default: key = Self.keys[part] ?? (part.count == 1 ? part : nil)
            }
        }
        guard let key, !mods.subtracting(.shift).isEmpty else { return nil }
        modifiers = mods
        self.key = key
    }

    private static let keys: [String: String] = ["comma": ",", "period": ".", "space": " ", "up": "\u{F700}", "down": "\u{F701}",
                                                 "left": "\u{F702}", "right": "\u{F703}", "home": "\u{F729}", "end": "\u{F72B}",
                                                 "pageup": "\u{F72C}", "pagedown": "\u{F72D}", "insert": "\u{F727}", "delete": "\u{F728}"]

    func matches(_ event: NSEvent) -> Bool {
        let held = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // The key itself, as if nothing were held: ⇧ makes a digit type its symbol, and the shortcut is still the digit.
        let pressed = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
        return held == modifiers && pressed.lowercased() == key
    }
}

/// The window an extension's popup is in. A popover would be the natural one, but macOS does not show Chromium's drawing
/// in a popover (it stays white), so the popup is a panel of its own.
final class ExtensionPopupPanel: NSPanel {
    /// ⌘W with the popup in front: it has no close button of AppKit's for `performClose` to press.
    var onCloseRequest: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performClose(_ sender: Any?) { onCloseRequest?() }
}

/// The strip along the top of a popup that it is dragged by (the page takes every click), with the close button that a
/// popup dragged away from its button needs.
final class ExtensionPopupBar: NSView {
    static let height: CGFloat = 18
    let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
                                   .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) ?? NSImage(),
                               target: nil, action: nil)
    /// How far the pointer goes before a press on the bar is a drag (a click wobbles a point or two).
    static let threshold: CGFloat = 4
    /// Each move of a drag.
    var onDrag: (() -> Void)?
    /// The screen a point is on, without the menu bar and Dock: a drag keeps the bar there.
    var visibleScreen: (NSPoint) -> CGRect? = { point in
        PopupPlacement.visibleFrame(at: point, screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) })
    }
    private var grabbed: (mouse: NSPoint, topLeft: NSPoint)?
    private var dragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close"
        closeButton.isHidden = true
        closeButton.frame = NSRect(x: frame.width - Self.height - 4, y: 0, width: Self.height, height: Self.height)
        closeButton.autoresizingMask = [.minXMargin]
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 18, y: bounds.midY - 2, width: 36, height: 4), xRadius: 2, yRadius: 2).fill()
    }

    override func resetCursorRects() {
        addCursorRect(closeButton.isHidden ? bounds : NSRect(x: 0, y: 0, width: closeButton.frame.minX, height: bounds.height), cursor: .openHand)
    }
    // A popup that is not the key window is dragged by its first click too.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Where the pointer is on the screen, not in the window: the window moves under it.
    override func mouseDown(with event: NSEvent) { grab(at: NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { drag(to: NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { grabbed = nil }

    func grab(at mouse: NSPoint) {
        guard let window else { return }
        grabbed = (mouse, NSPoint(x: window.frame.minX, y: window.frame.maxY))
        dragging = false
    }

    // By the top-left corner: the popup can change height (its page laid out again) in the middle of a drag.
    func drag(to mouse: NSPoint) {
        guard let window, let grabbed else { return }
        let dx = mouse.x - grabbed.mouse.x, dy = mouse.y - grabbed.mouse.y
        guard dragging || hypot(dx, dy) >= Self.threshold else { return }
        dragging = true
        onDrag?()
        let size = window.frame.size
        let frame = CGRect(x: grabbed.topLeft.x + dx, y: grabbed.topLeft.y + dy - size.height, width: size.width, height: size.height)
        window.setFrameOrigin(PopupPlacement.dragged(frame, bar: Self.height, visible: visibleScreen(mouse)).origin)
    }
}

/// An extension's popup: its page in a panel under the button (with none, in the tab's top-right corner), sized to what
/// the page lays out. Like a popover, it goes with the button's window and closes when the keyboard goes elsewhere (a
/// click outside it, another app). Dragged by its bar, it leaves the button and stays where it is put until it is closed.
@MainActor
final class ExtensionPopup: NSObject, EnginePageDelegate {
    let page: EnginePage
    let bar = ExtensionPopupBar(frame: NSRect(x: 0, y: 0, width: 360, height: ExtensionPopupBar.height))
    private let panel = ExtensionPopupPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 420 + ExtensionPopupBar.height),
                                            styleMask: [.borderless], backing: .buffered, defer: false)
    /// What it hangs from: the button, or with none the tab's page.
    private weak var button: NSView?
    private weak var tab: NSView?
    private var hasButton = false
    private var resignObserver: NSObjectProtocol?
    private var closed = false
    private(set) var isDetached = false
    var isOpen: Bool { !closed }
    /// The extension it is of (`InstalledExtension.id`): turning that off or removing it closes the popup.
    var extensionID: UUID?
    var onClose: (() -> Void)?
    var onDetach: (() -> Void)?

    init(page: EnginePage) {
        self.page = page
        super.init()
        page.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Going to another app takes the keyboard away, which closes it; hiding it as well is not needed.
        panel.hidesOnDeactivate = false
        let content = NSView(frame: panel.contentLayoutRect)
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.layer?.masksToBounds = true
        let height = content.bounds.height - ExtensionPopupBar.height
        page.view.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: height)
        page.view.autoresizingMask = [.width, .height]
        bar.frame = NSRect(x: 0, y: height, width: content.bounds.width, height: ExtensionPopupBar.height)
        bar.autoresizingMask = [.width, .minYMargin]
        bar.onDrag = { [weak self] in self?.detach() }
        bar.closeButton.target = self
        bar.closeButton.action = #selector(closeClicked)
        panel.onCloseRequest = { [weak self] in self?.close() }
        content.addSubview(page.view)
        content.addSubview(bar)
        panel.contentView = content
    }

    func show(under button: NSView?, in tab: NSView) {
        self.button = button?.window == nil ? nil : button
        self.tab = tab
        hasButton = self.button != nil
        guard let window = (self.button ?? tab).window else { close(); return }
        place(page.view.frame.size)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(page.view)
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        fit()
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        page.delegate = nil
        page.close()
        onClose?()
    }

    @objc private func closeClicked() { close() }

    /// Dragged away from its button: it stays where it is put, over Cosmos's windows (not other apps'), and open until its
    /// close button or the page closes it.
    func detach() {
        guard !isDetached, !closed else { return }
        isDetached = true
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        panel.parent?.removeChildWindow(panel)
        panel.level = .floating
        panel.hidesOnDeactivate = true
        bar.closeButton.isHidden = false
        panel.invalidateCursorRects(for: bar)
        onDetach?()
    }

    /// Puts the panel, at `pageSize` and the bar over it, under the button (or in the tab's corner) where that is now: its
    /// window may have moved since the popup opened. A button that has gone since leaves it where it is; one that was
    /// dragged away stays where it was put, keeping its top edge.
    private func place(_ pageSize: CGSize) {
        let size = CGSize(width: pageSize.width, height: pageSize.height + ExtensionPopupBar.height)
        if isDetached {
            let frame = CGRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
            panel.setFrame(PopupPlacement.dragged(frame, bar: ExtensionPopupBar.height, visible: panel.screen?.visibleFrame), display: true)
            return
        }
        let view = hasButton ? button : tab
        guard let view, let window = view.window else { return }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        let visible = window.screen?.visibleFrame
        panel.setFrame(view === button ? PopupPlacement.frame(under: rect, size: size, visible: visible)
                                       : PopupPlacement.frame(inTopRightOf: rect, size: size, visible: visible), display: true)
    }

    /// Chromium sizes a popup to its page; here the page is asked how big it laid itself out, within Chrome's limits.
    private func fit() {
        Task {
            let size = await page.evaluate("[document.documentElement.scrollWidth, document.documentElement.scrollHeight]", in: .page) as? [Double]
            guard !closed, let size, size.count == 2, size[0] > 0, size[1] > 0 else { return }
            place(CGSize(width: min(800, max(25, size[0])), height: min(600, max(25, size[1]))))
        }
    }

    func pageStateDidChange(_ page: EnginePage) {}
    func pageDidStartNavigation(_ page: EnginePage) {}
    func pageDidCommitNavigation(_ page: EnginePage) {}
    func pageDidFinishLoading(_ page: EnginePage) { fit() }
    func page(_ page: EnginePage, didFailLoading url: URL, error: PageLoadError) {}
    func page(_ page: EnginePage, agentMessage: [String: Any], fromMainFrame: Bool) {}
    func page(_ page: EnginePage, runDialog dialog: PageDialog) async -> PageDialog.Answer { PageDialog.Answer(accepted: false) }
    func page(_ page: EnginePage, chooseFiles chooser: FileChooser) async -> [URL]? { nil }
    func page(_ page: EnginePage, wantsPermission request: PermissionRequest) async -> Bool { false }
    func pageWantsLocation(_ page: EnginePage) async -> PageLocation? { nil }
    func page(_ page: EnginePage, wantsCredentialsFor challenge: AuthChallenge) async -> PageCredentials? { nil }
    func page(_ page: EnginePage, wantsPictureInPicture view: NSView) async -> Bool { false }
    func page(_ page: EnginePage, showNotification note: EngineNotification) {}
    func page(_ page: EnginePage, dangerAt url: URL) -> PageDanger? { nil }
    func page(_ page: EnginePage, closeNotification id: String) {}
    func pageDidLeavePictureInPicture(_ page: EnginePage) {}
    func pageDidForceClick(_ page: EnginePage) {}
    func pageRequestsClose(_ page: EnginePage) { close() }
    func pageRendererDidTerminate(_ page: EnginePage) { close() }
}

/// What an extension asks for, in a form the "Add extension?" prompt can show.
struct ExtensionRequestSummary {
    var name: String
    var version: String
    var origin: String
    var permissions: [String]
    var hostPatterns: [String]
    /// Manifest problems and what may not work as in Chrome, in plain words.
    var problems: [String]

    /// What a manifest asks for.
    static func read(_ manifest: [String: Any]) -> (version: String, permissions: [String], hostPatterns: [String], problems: [String]) {
        let version = manifest["version"] as? String ?? "?"
        let declared = (manifest["permissions"] as? [String] ?? []) + (manifest["optional_permissions"] as? [String] ?? [])
        // Manifest V2 lists sites among its permissions; V3 has a list of its own.
        let isPattern: (String) -> Bool = { $0 == "<all_urls>" || $0.contains("://") }
        var hosts = declared.filter(isPattern) + (manifest["host_permissions"] as? [String] ?? [])
        for script in manifest["content_scripts"] as? [[String: Any]] ?? [] { hosts += script["matches"] as? [String] ?? [] }
        var unique: [String] = []
        for h in hosts where !unique.contains(h) { unique.append(h) }
        let permissions = declared.filter { !isPattern($0) }
        var problems: [String] = []
        if (manifest["manifest_version"] as? Int) == 2 { problems.append("It is built for Manifest V2, which Chromium no longer runs.") }
        // `identity.getAuthToken` signs in with the Google account Chrome is signed in to; Cosmos's Chromium has none.
        if manifest["oauth2"] != nil {
            problems.append("Its Google sign-in goes through a web page instead of a Google account in the browser; some Google services refuse that.")
        }
        return (version, permissions, unique, problems)
    }

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
            if !unique.isEmpty {
                out.append("Read and change your data on \(unique.prefix(4).joined(separator: ", "))" + (unique.count > 4 ? " and \(unique.count - 4) more sites" : ""))
            }
        }
        if hostPatterns.contains(where: { $0.lowercased().hasPrefix("file://") }) { out.append("Read files on your Mac that you open in Cosmos") }
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

}
