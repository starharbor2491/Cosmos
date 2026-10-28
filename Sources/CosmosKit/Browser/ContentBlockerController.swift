import Foundation
import Observation
import CosmosCore
import CosmosBlocking
import CosmosEngine

/// Connects the filter-list engine (`CosmosBlocking`) to the browser engine: keeps the enabled lists downloaded and
/// compiled, and hands them, with the sites blocking is off for, to every profile. The Settings screen reads the
/// observable status properties.
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
    @ObservationIgnored private var environments: [WeakEnvironment] = []
    /// What every profile blocks; `nil` while blocking is off.
    @ObservationIgnored private(set) var installed: [CompiledBlockingList]?
    /// Bumped by every `reload`; a slower, older reload that finishes late must not overwrite a newer one.
    @ObservationIgnored private var generation = 0

    private struct WeakEnvironment { weak var value: ProfileEnvironment? }

    /// - Parameter offline: never touch the network (demos and automated runs); the cached or bundled lists are used.
    init(store: BrowserStore, directory: URL, offline: Bool = false) {
        self.store = store
        self.offline = offline
        manager = FilterListManager(directory: directory.appendingPathComponent("FilterLists", isDirectory: true),
                                    settingsURL: directory.appendingPathComponent("blocking.json"))
    }

    // MARK: Environments

    func attach(to environment: ProfileEnvironment) {
        environments.removeAll { $0.value == nil }
        if !environments.contains(where: { $0.value === environment }) { environments.append(WeakEnvironment(value: environment)) }
        if let installed { environment.engineProfile.setContentBlocking(installed, allowlist: allowlist) }
    }

    private var allowlist: [String] { store?.settings.adBlockAllowlist ?? [] }

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
            install(nil, generation: mine)
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
        install(cached, generation: mine)

        if refresh {
            isUpdating = true
            let fresh = await manager.refresh(force: force)
            guard mine == generation else { return }
            if fresh.map(\.digest) != cached.map(\.digest) { install(fresh, generation: mine) }
            lastRefresh = Date()
        }
        if mine == generation {
            isUpdating = false
            statuses = await manager.status()
        }
    }

    /// Hands the lists to every profile (`nil` turns blocking off).
    private func install(_ lists: [CompiledRuleList]?, generation mine: Int) {
        guard mine == generation else { return }
        let converted = lists?.map { CompiledBlockingList(name: $0.name, json: $0.json, kind: $0.kind == .network ? .network : .cosmetic, digest: $0.digest) }
        installed = converted
        installedRuleCount = lists?.reduce(0) { $0 + $1.ruleCount } ?? 0
        for e in liveEnvironments { e.engineProfile.setContentBlocking(converted, allowlist: allowlist) }
    }

    // MARK: Per-site switch

    /// The allowlist after the user turned blocking on or off for `url`'s site. Turning it on takes away every entry that
    /// covers the site (a parent domain too); turning it off adds the host unless an entry already covers it.
    nonisolated static func allowlist(_ list: [String], blocking on: Bool, for url: URL) -> [String] {
        guard let host = url.host?.lowercased() else { return list }
        if on { return list.filter { !isAllowlisted(url, allowlist: [$0]) } }
        return isAllowlisted(url, allowlist: list) ? list : list + [host]
    }

    /// True when `url` belongs to a host the user turned blocking off for (the host itself or a subdomain of it).
    nonisolated static func isAllowlisted(_ url: URL, allowlist: [String]) -> Bool {
        guard let host = url.host?.lowercased(), !allowlist.isEmpty else { return false }
        return allowlist.contains { entry in
            let e = entry.lowercased()
            return host == e || host.hasSuffix("." + e)
        }
    }
}
