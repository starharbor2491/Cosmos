import Foundation
import Observation
import WebKit
import CosmosCore
import CosmosBlocking

/// Connects the filter-list engine (`CosmosBlocking`) to WebKit: keeps the enabled lists downloaded and compiled,
/// turns them into `WKContentRuleList`s with `WKContentRuleListStore`, and attaches them to every profile's content
/// controller. The Settings screen reads the observable status properties.
@MainActor
@Observable
final class ContentBlockerController {
    /// Per-list state for Settings: last check, rule counts and what the compiler skipped.
    private(set) var statuses: [FilterListStatus] = []
    private(set) var isUpdating = false
    private(set) var lastRefresh: Date?
    /// Rules currently installed across all lists.
    private(set) var installedRuleCount = 0

    @ObservationIgnored private weak var store: BrowserStore?
    @ObservationIgnored let manager: FilterListManager
    @ObservationIgnored private let offline: Bool
    @ObservationIgnored private let ruleListStore: WKContentRuleListStore?
    @ObservationIgnored private var environments: [WeakEnvironment] = []
    @ObservationIgnored private var installed: [WKContentRuleList] = []
    @ObservationIgnored private var installedIdentifiers: [String] = []
    /// Bumped by every `reload`; a slower, older reload that finishes late must not overwrite a newer one.
    @ObservationIgnored private var generation = 0

    private struct WeakEnvironment { weak var value: ProfileEnvironment? }

    /// - Parameter offline: never touch the network (demos and automated runs); the cached or bundled lists are used.
    /// - Parameter ruleListStore: where WebKit keeps the compiled lists; tests pass a private one.
    convenience init(store: BrowserStore, directory: URL, offline: Bool = false) {
        self.init(store: store, directory: directory, offline: offline, ruleListStore: .default())
    }

    init(store: BrowserStore, directory: URL, offline: Bool, ruleListStore: WKContentRuleListStore?) {
        self.store = store
        self.offline = offline
        self.ruleListStore = ruleListStore
        manager = FilterListManager(directory: directory.appendingPathComponent("FilterLists", isDirectory: true),
                                    settingsURL: directory.appendingPathComponent("blocking.json"))
    }

    // MARK: Environments

    func attach(to environment: ProfileEnvironment) {
        environments.removeAll { $0.value == nil }
        if !environments.contains(where: { $0.value === environment }) { environments.append(WeakEnvironment(value: environment)) }
        if !installed.isEmpty { environment.setRuleLists(installed) }
    }

    private var liveEnvironments: [ProfileEnvironment] { environments.compactMap(\.value) }

    // MARK: Loading

    /// Installs what is on disk straight away, then brings the lists up to date in the background.
    func start() {
        Task { await reload(refresh: !offline, force: false) }
    }

    func settingsDidChange() {
        Task { await reload(refresh: !offline, force: false) }
    }

    /// "Update now" in Settings.
    func updateNow() {
        Task { await reload(refresh: !offline, force: true) }
    }

    /// Called every minute by the store; refreshes at most every six hours (each list is only re-downloaded once it is
    /// 24 hours old, and a "not modified" answer costs one small request).
    func refreshIfStale() {
        guard !offline, !isUpdating else { return }
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 6 * 3600 { return }
        Task { await reload(refresh: true, force: false) }
    }

    @discardableResult
    func addCustomList(name: String, url: URL) async -> FilterListInfo? {
        guard let info = try? await manager.addCustomList(name: name, url: url) else { return nil }
        if let store, !store.settings.enabledFilterLists.contains(info.id) { store.settings.enabledFilterLists.append(info.id) }
        else { await reload(refresh: !offline, force: false) }
        return info
    }

    func removeCustomList(id: String) async {
        try? await manager.removeCustomList(id: id)
        store?.settings.enabledFilterLists.removeAll { $0 == id }
        await reload(refresh: false, force: false)
    }

    private func reload(refresh: Bool, force: Bool) async {
        guard let store else { return }
        generation += 1
        let mine = generation
        let settings = store.settings

        guard settings.adBlockingEnabled else {
            await install([], generation: mine)
            if mine == generation { statuses = await manager.status(); isUpdating = false }
            return
        }

        // Settings is the source of truth for which lists are on; mirror it into the engine's own state.
        let wanted = Set(settings.enabledFilterLists)
        for info in await manager.availableLists() {
            let on = wanted.contains(info.id)
            if await manager.isEnabled(info.id) != on { try? await manager.setEnabled(info.id, on) }
        }
        guard mine == generation else { return }

        let cached = await manager.cachedRuleLists()
        guard mine == generation else { return }
        await install(cached, generation: mine)

        if refresh {
            isUpdating = true
            let fresh = await manager.refresh(force: force)
            guard mine == generation else { return }
            if fresh.map(\.storeIdentifier) != cached.map(\.storeIdentifier) { await install(fresh, generation: mine) }
            lastRefresh = Date()
        }
        if mine == generation {
            isUpdating = false
            statuses = await manager.status()
        }
    }

    /// Compiles (or looks up) each list in WebKit's rule-list store and attaches the result to every environment.
    private func install(_ lists: [CompiledRuleList], generation mine: Int) async {
        guard let wkStore = ruleListStore else { return }
        var ready: [WKContentRuleList] = []
        var identifiers: [String] = []
        var count = 0
        for list in lists {
            // The digest is part of the identifier, so a hit means the stored rules are current.
            if let existing = try? await wkStore.contentRuleList(forIdentifier: list.storeIdentifier) {
                ready.append(existing)
            } else if let compiled = try? await wkStore.compileContentRuleList(forIdentifier: list.storeIdentifier, encodedContentRuleList: list.json) {
                ready.append(compiled)
            } else {
                continue
            }
            identifiers.append(list.storeIdentifier)
            count += list.ruleCount
        }
        guard mine == generation else { return }
        installed = ready
        installedIdentifiers = identifiers
        installedRuleCount = count
        for e in liveEnvironments { e.setRuleLists(ready) }

        let keep = Set(identifiers)
        for id in await wkStore.availableIdentifiers() ?? [] where id.hasPrefix("cosmos.") && !keep.contains(id) {
            try? await wkStore.removeContentRuleList(forIdentifier: id)
        }
    }

    // MARK: Per-site switch

    /// True when `url` belongs to a host the user turned blocking off for (the host itself or a subdomain of it).
    nonisolated static func isAllowlisted(_ url: URL, allowlist: [String]) -> Bool {
        guard let host = url.host?.lowercased(), !allowlist.isEmpty else { return false }
        return allowlist.contains { entry in
            let e = entry.lowercased()
            return host == e || host.hasSuffix("." + e)
        }
    }

    /// Applies the user's blocking settings to one navigation. WebKit keeps the page's rule lists attached; this turns
    /// them off for just this page (it has no public switch, so the private preference is used when it exists).
    static func configure(_ preferences: WKWebpagePreferences, for url: URL, settings: Settings) {
        guard settings.adBlockingEnabled, !isAllowlisted(url, allowlist: settings.adBlockAllowlist) else {
            setContentBlockers(enabled: false, on: preferences)
            return
        }
    }

    private static func setContentBlockers(enabled: Bool, on preferences: WKWebpagePreferences) {
        let selector = NSSelectorFromString("_setContentBlockersEnabled:")
        guard preferences.responds(to: selector), let imp = preferences.method(for: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(imp, to: Setter.self)(preferences, selector, enabled)
    }
}
