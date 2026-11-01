import AppKit
import CosmosCore
import CosmosEngine
import CosmosImport

/// One place a user can bring their browsing life from. The welcome lists these.
struct ImportSource: Identifiable {
    let id: String
    let name: String
    let symbol: String
    /// The browser's own icon, when it is installed.
    var icon: NSImage?
    let detail: String
    /// Whether the source's data was found on this Mac.
    var isAvailable: Bool
    /// Arc's spaces can go in alongside the ones already here or in their place (`run`'s last argument: replacing).
    var bringsSpaces = false
    let run: @MainActor (BrowserStore, WindowState, Bool) async throws -> ImportOutcome
}

struct ImportOutcome {
    var summary: String
    /// Arc has saved passwords or site sign-ins that can come too, as a second step (macOS asks first).
    var offersSignIns = false
    /// Arc's extensions, which Settings ▸ Extensions can bring over.
    var extensions = 0
    /// The Arc folder the spaces came from, where the passwords and sign-ins are too.
    var arcFolder: URL?
}

/// Collects the importers: Arc first, then every other browser profile found on this Mac.
@MainActor
enum ImportCoordinator {
    static func sources(for store: BrowserStore) async -> [ImportSource] {
        // A private window keeps nothing: what was imported into it would be gone when it closes.
        guard !store.isIncognito else { return [] }
        var out: [ImportSource] = []
        let arcDir = ArcImporter.defaultDirectory
        let arcFound = ArcImporter.hasProfile(at: arcDir)
        out.append(ImportSource(
            id: "arc", name: "Arc", symbol: "arrow.down.doc", icon: appIcon(for: .arc),
            detail: arcFound ? "Spaces, Favorites, pinned tabs, folders, split views and the archive."
                             : "Arc's data wasn't found on this Mac. Choose its folder to import from.",
            isAvailable: arcFound, bringsSpaces: true
        ) { store, window, replacing in
            var directory = arcDir
            if !arcFound {
                guard let chosen = Self.chooseFolder(message: "Choose Arc's data folder (it contains StorableSidebar.json)") else { throw CancellationError() }
                directory = chosen
            }
            return try await Self.importArc(from: directory, into: store, window: window, replacing: replacing)
        })

        // Discovery copies and opens databases to count rows: keep it off the main thread.
        let profiles = await Task.detached(priority: .userInitiated) {
            BrowserProfileDiscovery.discover(includeCounts: true).filter { $0.browser != .arc }
        }.value
        let byBrowser = Dictionary(grouping: profiles, by: \.browser)
        for browser in BrowserKind.allCases where browser != .arc {
            guard let list = byBrowser[browser], !list.isEmpty else { continue }
            let profile = list.first(where: \.isDefault) ?? list[0]
            let histCount = profile.approximateCounts[.history] ?? 0
            let markCount = profile.approximateCounts[.bookmarks] ?? 0
            let detail: String
            if profile.accessDenied { detail = "Needs Full Disk Access (System Settings → Privacy & Security)." }
            else { detail = "History (\(histCount.formatted())) and bookmarks (\(markCount.formatted()))." }
            out.append(ImportSource(id: "browser:\(profile.id)", name: browser.displayName, symbol: Self.symbol(for: browser),
                                    icon: appIcon(for: browser), detail: detail, isAvailable: true) { store, window, _ in
                try await Self.importBrowser(profile, into: store, window: window)
            })
        }
        return out
    }

    private static func symbol(for browser: BrowserKind) -> String {
        browser.family == .safari ? "safari" : (browser.family == .firefox ? "flame" : "globe")
    }

    /// The icon macOS shows for the browser, found by its bundle identifier (nil when it is not installed).
    static func appIcon(for browser: BrowserKind) -> NSImage? {
        let id = switch browser {
        case .arc: "company.thebrowser.Browser"
        case .chrome: "com.google.Chrome"
        case .brave: "com.brave.Browser"
        case .edge: "com.microsoft.edgemac"
        case .vivaldi: "com.vivaldi.Vivaldi"
        case .opera: "com.operasoftware.Opera"
        case .chromium: "org.chromium.Chromium"
        case .firefox: "org.mozilla.firefox"
        case .safari: "com.apple.Safari"
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    // MARK: Arc

    /// Arc's spaces and tabs into the browser: in place of what is here when asked to (or when nothing is here yet),
    /// alongside it otherwise.
    private static func importArc(from directory: URL, into store: BrowserStore, window: WindowState, replacing: Bool) async throws -> ImportOutcome {
        let result = try await Task.detached(priority: .userInitiated) { try ArcImporter.importProfile(at: directory) }.value
        store.applyArcImport(result, replacing: replacing || store.workspace.isPristine, in: window)
        let profile = ArcImporter.defaultChromiumProfile(in: directory)
        let hasSignIns = (ChromiumSecrets.loginFiles + ["Cookies", "Network/Cookies"]).contains {
            FileManager.default.fileExists(atPath: profile.appendingPathComponent($0).path)
        }
        var extensions = 0
        if store.extensionCenter != nil {
            extensions = await Task.detached(priority: .utility) { ChromiumExtensionScanner.scanAll(browsers: [.arc]).count }.value
        }
        return ImportOutcome(summary: summary(of: result.report), offersSignIns: hasSignIns, extensions: extensions, arcFolder: directory)
    }

    /// What an Arc import brought, in a line: "4 spaces, 63 tabs and 210 archived tabs".
    static func summary(of report: ImportReport) -> String {
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n.formatted()) \(n == 1 ? one : many)" }
        var parts = [count(report.spaces, "space", "spaces"), count(report.tabs, "tab", "tabs")]
        if report.archivedItems > 0 { parts.append(count(report.archivedItems, "archived tab", "archived tabs")) }
        if report.boosts > 0 { parts.append(count(report.boosts, "Boost", "Boosts")) }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1] : parts[0]
        return "Brought \(list)."
    }

    // MARK: Arc's passwords and sign-ins

    /// Arc's saved passwords into Cosmos's, and its cookies (the sites it is signed in to) into the default profile. The
    /// key to both is in Arc's Keychain item, which macOS asks the user before handing over; `secret` stands in for that
    /// in tests. Returns what to tell the user (counts only: no sites, no names).
    static func importArcSignIns(into store: BrowserStore, from directory: URL = ArcImporter.defaultDirectory,
                                 secret: @escaping @Sendable () -> String? = {
                                     ChromiumSafeStorage.keychainSecret(service: ArcImporter.safeStorage.service, account: ArcImporter.safeStorage.account)
                                 }) async -> String {
        guard !store.isIncognito else { return "A private window keeps nothing, so there is nothing to import into." }
        let profile = ArcImporter.defaultChromiumProfile(in: directory)
        let read = await Task.detached(priority: .userInitiated) { () -> (logins: ChromiumSecrets.Read<ImportedLogin>?, cookies: ChromiumSecrets.Read<ImportedCookie>?, locked: Bool) in
            guard let secret = secret() else { return (nil, nil, true) }
            let storage = ChromiumSafeStorage(secret: secret)
            return (try? ChromiumSecrets.readLogins(profileDirectory: profile, storage: storage),
                    try? ChromiumSecrets.readCookies(profileDirectory: profile, storage: storage), false)
        }.value
        if read.locked { return "Cosmos couldn't get Arc's key from your Keychain, so nothing was imported. If macOS asked, choose Allow next time." }
        var parts: [String] = []
        if let logins = read.logins {
            let added = store.passwords.add(logins.items.map {
                SavedLogin(origin: $0.origin, username: $0.username, password: $0.password, created: $0.created ?? Date())
            }, neverSaved: logins.neverSaved)
            parts.append("\(added.formatted()) password\(added == 1 ? "" : "s")")
        }
        if let cookies = read.cookies {
            let engineProfile = store.environment(forProfile: store.workspace.profiles[0].id).engineProfile
            let set = await engineProfile.setCookies(cookies.items.map {
                EngineCookie(domain: $0.domain, name: $0.name, value: $0.value, path: $0.path, expires: $0.expires, isSecure: $0.isSecure,
                             isHTTPOnly: $0.isHTTPOnly, sameSite: EngineCookie.SameSite(rawValue: $0.sameSite.rawValue) ?? .unspecified)
            })
            parts.append("sign-ins to sites (\(set.formatted()) cookie\(set == 1 ? "" : "s"))")
        }
        if parts.isEmpty { return "Arc has no saved passwords or sign-ins Cosmos could read." }
        return "Imported " + parts.joined(separator: " and ") + " from Arc."
    }

    // MARK: Other browsers

    private static func importBrowser(_ profile: BrowserProfile, into store: BrowserStore, window: WindowState) async throws -> ImportOutcome {
        let data = try await Task.detached(priority: .userInitiated) {
            try BrowserImporter.read(profile, options: BrowserImportOptions(history: true, bookmarks: true))
        }.value
        if !data.history.isEmpty { try store.history.importEntries(data.history) }
        var parts: [String] = []
        if !data.history.isEmpty { parts.append("\(data.history.count.formatted()) pages of history") }
        if !data.bookmarks.isEmpty {
            let summary = store.edit { ws in
                BookmarkImporter.populateWithSummary(&ws, with: data.bookmarks, intoSpaceTitled: "From \(profile.browser.displayName)")
            }
            parts.append("\(summary.tabsAdded.formatted()) bookmarks in a space called “From \(profile.browser.displayName)”")
        }
        if parts.isEmpty { return ImportOutcome(summary: "Nothing to import from \(profile.browser.displayName).") }
        return ImportOutcome(summary: "Brought " + parts.joined(separator: " and ") + ".")
    }

    private static func chooseFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
}

extension BrowserStore {
    /// Puts an Arc import into the browser: replacing everything, or alongside what is already there.
    func applyArcImport(_ result: ArcImportResult, replacing: Bool, in window: WindowState) {
        if replacing {
            for rt in runtimes.values { rt.tearDown() }
            runtimes.removeAll()
            runtimeRevision += 1
            edit { $0 = result.workspace }
            for w in windows { w.selection = [:]; w.recent = [] }
        } else {
            edit { $0.merge(result.workspace) }
        }
        for entry in result.archive.reversed() where !archive.entries.contains(where: { $0.id == entry.id }) { archive.add(entry) }
        if let routing = result.linkRouting {
            for rule in routing.rules where !linkRouting.rules.contains(where: { $0.id == rule.id }) { linkRouting.rules.append(rule) }
        }
        for boost in result.boosts where !boosts.boosts.contains(where: { $0.id == boost.id }) { boosts.boosts.append(boost) }
        settings.hasCompletedOnboarding = true
        let target = result.focusedSpaceID.flatMap { workspace.space($0)?.id } ?? workspace.spaces.first?.id
        if let target { switchSpace(to: target, in: window) }
        saveNow()
    }
}
