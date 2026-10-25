import AppKit
import CosmosCore
import CosmosImport

/// One place a user can bring their browsing life from. The Welcome screen lists these.
struct ImportSource: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let detail: String
    /// Whether the source's data was found on this Mac.
    var isAvailable: Bool
    let run: @MainActor (BrowserStore, WindowState) async throws -> ImportOutcome
}

struct ImportOutcome {
    var summary: String
}

/// Collects the importers: Arc first, then every other browser profile found on this Mac.
@MainActor
enum ImportCoordinator {
    static func sources(for store: BrowserStore) async -> [ImportSource] {
        var out: [ImportSource] = []
        let arcDir = ArcImporter.defaultDirectory
        let arcFound = ArcImporter.hasProfile(at: arcDir)
        out.append(ImportSource(
            id: "arc", name: "Arc", symbol: "arrow.down.doc",
            detail: arcFound ? "Spaces, Favorites, pinned tabs, folders, split views, archive and link rules."
                             : "Arc's data wasn't found on this Mac. Choose its folder to import from.",
            isAvailable: arcFound
        ) { store, window in
            var directory = arcDir
            if !arcFound {
                guard let chosen = Self.chooseFolder(message: "Choose Arc's data folder (it contains StorableSidebar.json)") else { throw CancellationError() }
                directory = chosen
            }
            return try await Self.importArc(from: directory, into: store, window: window)
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
                                    detail: detail, isAvailable: true) { store, window in
                try await Self.importBrowser(profile, into: store, window: window)
            })
        }
        return out
    }

    private static func symbol(for browser: BrowserKind) -> String {
        browser.family == .safari ? "safari" : (browser.family == .firefox ? "flame" : "globe")
    }

    // MARK: Arc

    private static func importArc(from directory: URL, into store: BrowserStore, window: WindowState) async throws -> ImportOutcome {
        let result = try await Task.detached(priority: .userInitiated) { try ArcImporter.importProfile(at: directory) }.value
        var replace = store.workspace.isPristine
        if !replace {
            switch Self.askMergeOrReplace(spaces: result.report.spaces, tabs: result.report.tabs) {
            case .merge: replace = false
            case .replace: replace = true
            case .cancel: throw CancellationError()
            }
        }
        store.applyArcImport(result, replacing: replace, in: window)
        var summary = result.report.summary
        if ExtensionCenter.isSupported, store.extensionCenter != nil {
            let extensions = await Task.detached(priority: .utility) { ChromiumExtensionScanner.scanAll(browsers: [.arc]).count }.value
            if extensions > 0 {
                summary += "\n\nArc also has \(extensions) extension\(extensions == 1 ? "" : "s"). To bring them over, open Settings ▸ Extensions and choose Find in Arc and Other Browsers."
            }
        }
        return ImportOutcome(summary: summary)
    }

    private enum Choice { case merge, replace, cancel }

    private static func askMergeOrReplace(spaces: Int, tabs: Int) -> Choice {
        let alert = NSAlert()
        alert.messageText = "Add Arc's \(spaces) space\(spaces == 1 ? "" : "s") to your current ones?"
        alert.informativeText = "Cosmos already has spaces and tabs. Adding keeps them and brings Arc's alongside. Replacing swaps everything for what Arc had (\(tabs) tabs); Cosmos keeps a backup of the old file."
        alert.addButton(withTitle: "Add to Current")
        alert.addButton(withTitle: "Replace Everything")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .merge
        case .alertSecondButtonReturn: return .replace
        default: return .cancel
        }
    }

    // MARK: Other browsers

    private static func importBrowser(_ profile: BrowserProfile, into store: BrowserStore, window: WindowState) async throws -> ImportOutcome {
        let data = try await Task.detached(priority: .userInitiated) {
            try BrowserImporter.read(profile, options: BrowserImportOptions(history: true, bookmarks: true))
        }.value
        if !data.history.isEmpty { try store.history.importEntries(data.history) }
        var parts: [String] = []
        if !data.history.isEmpty { parts.append("\(data.history.count.formatted()) history entries") }
        if !data.bookmarks.isEmpty {
            let summary = store.edit { ws in
                BookmarkImporter.populateWithSummary(&ws, with: data.bookmarks, intoSpaceTitled: "From \(profile.browser.displayName)")
            }
            parts.append("\(summary.tabsAdded.formatted()) bookmarks in a space called “From \(profile.browser.displayName)”")
        }
        if parts.isEmpty { return ImportOutcome(summary: "Nothing to import from \(profile.browser.displayName).") }
        return ImportOutcome(summary: "Imported " + parts.joined(separator: " and ") + ".")
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
