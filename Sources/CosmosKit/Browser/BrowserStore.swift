import AppKit
import CryptoKit
import CosmosBlocking
import CosmosCore
import CosmosEngine

/// The browser's model and controller: owns the workspace (spaces, tabs, folders), the archive, Boosts and settings,
/// persists them, and manages the live pages (`TabRuntime`s) behind sidebar items.
///
/// One persistent store serves every normal window; each incognito window gets its own in-memory store.
@MainActor
@Observable
public final class BrowserStore: TabHost {
    // MARK: Persisted state

    public private(set) var workspace: Workspace
    public var archive: ArchiveData { didSet { markDirty(.archive) } }
    public var boosts: BoostLibrary { didSet { markDirty(.boosts); reinstallBoosts() } }
    public var linkRouting: LinkRouting { didSet { markDirty(.routing) } }
    public var settings: Settings { didSet { markDirty(.settings); settingsChanged(old: oldValue) } }
    public var learned = LearnedSelections() { didSet { markDirty(.learned) } }

    // MARK: Services

    public let history: HistoryStore
    public let favicons: FaviconStore
    /// Saved passwords (Settings ▸ Passwords), in `Passwords.vault`; in memory for a private window, which neither saves
    /// nor fills them.
    public let passwords: PasswordManager
    let haptics = Haptics()
    /// Where the Mac is, for sites the user let know: macOS is asked by Cosmos, never by the engine. Tests replace it.
    @ObservationIgnored var locate: @MainActor () async -> PageLocation? = { await LocationSource.shared.current() }
    /// Asks for a user name and password for a site: a sheet over the tab. Tests replace it.
    @ObservationIgnored var signIn: @MainActor (TabRuntime, AuthChallenge) async -> PageCredentials? = { tab, challenge in await tab.askForCredentials(challenge) }
    public let downloads = DownloadsManager()
    let resources = ResourceMonitor()
    public let catalog = SearchCatalog.bundled
    public let isIncognito: Bool
    public let dataDirectory: URL?
    /// What draws the pages. The store only knows it through `BrowserEngine`.
    @ObservationIgnored let engine: BrowserEngine
    /// Where the engine is (downloading, ready, failed), for the page area to show while there is no page.
    public internal(set) var engineStatus: EngineStatus = .ready(version: "")

    // MARK: Runtime state

    @ObservationIgnored var runtimes: [RuntimeKey: TabRuntime] = [:]
    /// Each window's number for extensions (`ExtensionTabs`).
    @ObservationIgnored var extensionWindowNumbers = NSMapTable<WindowState, NSNumber>.weakToStrongObjects()
    @ObservationIgnored var nextExtensionWindowNumber = 0
    @ObservationIgnored var environments: [UUID: ProfileEnvironment] = [:]
    @ObservationIgnored var incognitoEnvironment: ProfileEnvironment?
    /// The sidebar item being dragged right now, in any window (drop targets read it; nil when no drag is in flight).
    var draggingItemID: UUID?
    public var isDraggingSidebarItem: Bool { draggingItemID != nil }
    /// Bumped when a runtime is created or discarded so views that show "is this tab loaded?" refresh.
    public internal(set) var runtimeRevision = 0
    public private(set) var windows: [WindowState] = []
    /// The window the user is working in (key window); menu commands act on it.
    public weak var activeWindow: WindowState?
    /// Ids restorable with ⇧⌘T, newest first.
    var recentlyClosed: [UUID] = []
    @ObservationIgnored var blocker: ContentBlockerController?
    /// Browser extensions; `nil` in incognito windows, which never load extensions.
    @ObservationIgnored var extensionCenter: ExtensionCenter?
    @ObservationIgnored var onOpenProbe: ((URL) -> Void)?
    @ObservationIgnored var onNewWindow: (() -> Void)?
    @ObservationIgnored var onOpenIncognito: (() -> Void)?
    @ObservationIgnored var onShowSettings: (() -> Void)?
    @ObservationIgnored var onShowSettingsTab: ((SettingsTab) -> Void)?
    /// Shows an overlay in a browser window and brings that window forward.
    @ObservationIgnored var onPresent: ((Overlay) -> Void)?
    /// Closes a browser window that has nothing left to show. Tests replace it to see that one was asked for.
    @ObservationIgnored var onCloseWindowRequest: ((WindowState) -> Void)?
    /// Where a download starts. Tests replace it to see that one was asked for.
    @ObservationIgnored var downloadStarter: ((URL, TabRuntime) -> Void)?
    /// The choices a private window inherits (the ring, haptics) changed: the app passes them on to the open ones.
    @ObservationIgnored var onPreferencesChanged: (() -> Void)?
    /// History was cleared: whatever the app keeps of where you have been (the menu-bar browser's page) goes too.
    @ObservationIgnored var onHistoryCleared: (() -> Void)?
    /// The menu-bar browser's settings changed: the app shows, hides or rebuilds it.
    @ObservationIgnored var onMenuBarChange: (() -> Void)?
    /// The engine's own settings changed: the app hands them to the engine (they apply as each profile's engine restarts).
    @ObservationIgnored var onEngineSettingsChanged: (() -> Void)?
    @ObservationIgnored var onPopupWindow: ((TabRuntime, NewPageRequest, _ bringForward: Bool) -> Void)?
    /// Shows a tab's video in a floating window (the app's Picture in Picture panel), and closes it.
    @ObservationIgnored var onPictureInPicture: ((TabRuntime, NSView) -> Bool)?
    @ObservationIgnored var onPictureInPictureEnded: ((TabRuntime) -> Void)?
    /// Brings a tab to the front in its window (a click on its notification).
    @ObservationIgnored var onShowTab: ((TabRuntime) -> Void)?
    /// Where sites' and extensions' notifications go: macOS. Tests replace it.
    @ObservationIgnored var notifier: Notifying = SystemNotifier.shared
    /// Sites on the malware and phishing lists, and the ones the user chose to visit anyway (until Cosmos quits).
    @ObservationIgnored var dangerousSites = DangerousSites()
    @ObservationIgnored var dangerousSitesVisitedAnyway: Set<String> = []

    // MARK: Persistence plumbing

    enum FileKind: CaseIterable { case workspace, archive, boosts, routing, settings, learned }
    @ObservationIgnored private var dirty: Set<FileKind> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private let workspaceFile: JSONFileStore<Workspace>?
    @ObservationIgnored private let archiveFile: JSONFileStore<ArchiveData>?
    @ObservationIgnored private let boostsFile: JSONFileStore<BoostLibrary>?
    @ObservationIgnored private let routingFile: JSONFileStore<LinkRouting>?
    @ObservationIgnored private let settingsFile: JSONFileStore<Settings>?
    @ObservationIgnored private let learnedFile: JSONFileStore<LearnedSelections>?
    @ObservationIgnored private let sessionFile: JSONFileStore<SessionState>?
    @ObservationIgnored public private(set) var isFirstLaunch = false
    @ObservationIgnored var savedSession: SessionState?
    /// Set once the app is quitting: windows closing then must not overwrite the session they were saved in.
    @ObservationIgnored var isTerminating = false

    /// Opens (or creates) the browser's data in `directory`; pass `nil` for a throwaway in-memory (incognito) store.
    /// `passwordKey` gives the key to the saved passwords (the Keychain's, made there the first time).
    public init(directory: URL?, incognito: Bool = false, engine: BrowserEngine,
                passwordKey: @escaping () throws -> SymmetricKey = PasswordManager.keychainKey) {
        isIncognito = incognito
        dataDirectory = directory
        self.engine = engine
        passwords = PasswordManager(file: incognito ? nil : directory?.appendingPathComponent("Passwords.vault"), key: passwordKey)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ws = JSONFileStore<Workspace>(url: directory.appendingPathComponent("workspace.json"))
            let ar = JSONFileStore<ArchiveData>(url: directory.appendingPathComponent("archive.json"), backupInterval: 6 * 3600)
            let bo = JSONFileStore<BoostLibrary>(url: directory.appendingPathComponent("boosts.json"))
            let ro = JSONFileStore<LinkRouting>(url: directory.appendingPathComponent("link-routing.json"), backupInterval: 6 * 3600)
            let se = JSONFileStore<Settings>(url: directory.appendingPathComponent("settings.json"), backupInterval: 6 * 3600)
            // What the Command Bar learned is a cache of habits: no dated copies, they would only keep what was typed.
            let le = JSONFileStore<LearnedSelections>(url: directory.appendingPathComponent("command-bar-learning.json"), keepBackups: 0)
            workspaceFile = ws; archiveFile = ar; boostsFile = bo; routingFile = ro; settingsFile = se; learnedFile = le
            sessionFile = JSONFileStore<SessionState>(url: directory.appendingPathComponent("session.json"), backupInterval: 24 * 3600, keepBackups: 3)

            var loaded = (try? ws.load()) ?? nil
            if loaded == nil, let restored = try? ws.restoreLatestBackup() { loaded = restored }
            if var w = loaded {
                if !w.problems().isEmpty { w.repair() }
                workspace = w
            } else {
                workspace = Workspace.fresh()
                isFirstLaunch = true
            }
            archive = Self.loadOrRecover(ar) ?? ArchiveData()
            boosts = Self.loadOrRecover(bo) ?? BoostLibrary()
            linkRouting = Self.loadOrRecover(ro) ?? LinkRouting()
            settings = Self.loadOrRecover(se) ?? Settings()
            var loadedLearning = ((try? le.load()) ?? nil) ?? LearnedSelections()
            // Dated copies an earlier version made, and the typed things it kept, go on the first launch.
            le.deleteBackups()
            if loadedLearning.dropUnlearnable() { try? le.rewriteDiscardingBackups(loadedLearning) }
            learned = loadedLearning
            savedSession = (try? sessionFile?.load()) ?? nil
            history = (try? HistoryStore(path: directory.appendingPathComponent("history.sqlite").path)) ?? (try! HistoryStore(path: nil))
            favicons = FaviconStore(directory: directory.appendingPathComponent("Favicons", isDirectory: true))
        } else {
            workspaceFile = nil; archiveFile = nil; boostsFile = nil; routingFile = nil; settingsFile = nil; learnedFile = nil; sessionFile = nil
            workspace = Workspace.fresh(spaceTitle: "Incognito", theme: .eclipse)
            archive = ArchiveData(interval: .never)
            boosts = BoostLibrary()
            linkRouting = LinkRouting()
            settings = Settings()
            history = try! HistoryStore(path: nil)
            favicons = FaviconStore(directory: nil)
        }
        haptics.isEnabled = settings.trackpadHaptics
        startTimers()
    }

    /// What a file holds (nil when there is none yet). One that is there but cannot be read (cut short by a full disk, or
    /// written by a newer Cosmos) is not replaced by an empty value the next save would write over it: its last good copy
    /// comes back, and failing that it is put aside under another name.
    private static func loadOrRecover<V>(_ file: JSONFileStore<V>) -> V? {
        do {
            return try file.load()
        } catch {
            if let restored = try? file.restoreLatestBackup() { return restored }
            file.setAside()
            return nil
        }
    }

    // MARK: Saving

    func markDirty(_ kind: FileKind) {
        guard dataDirectory != nil else { return }
        dirty.insert(kind)
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    public func saveNow() {
        guard dataDirectory != nil else { return }
        saveTask?.cancel()
        let kinds = dirty
        dirty.removeAll()
        for k in kinds {
            switch k {
            case .workspace: try? workspaceFile?.save(workspace)
            case .archive: try? archiveFile?.save(archive)
            case .boosts: try? boostsFile?.save(boosts)
            case .routing: try? routingFile?.save(linkRouting)
            case .settings: try? settingsFile?.save(settings)
            case .learned: try? learnedFile?.save(learned)
            }
        }
    }

    /// Forgets where you have been: the visited pages, what the Command Bar learned from picking them, the logos
    /// fetched for those sites (the cache would otherwise still list every host) and the page the menu-bar browser was on.
    public func clearHistory() { clearHistory(since: nil) }

    /// Forgets the visits since `date` (everything for nil), and with them what the Command Bar learned from what was typed
    /// in that time, the logos of sites nothing uses any more, and the page the menu-bar browser was on (the most recent
    /// page there is, whatever the range).
    public func clearHistory(since date: Date?) {
        history.clear(since: date)
        if let date {
            learned.forget(since: date)
            dropUnusedLogos()
        } else {
            learned = LearnedSelections()
            favicons.removeAll()
        }
        settings.menuBar.lastAddress = nil
        forgetInSavedFiles()
        onHistoryCleared?()
        forEachEngineProfile { await $0.clearHistory(since: date) }
    }

    /// Forgets one page of the history: its row, what the Command Bar learned from picking or typing it, its logo when no
    /// other page or tab needs it, and the menu-bar page when that is the one.
    public func deleteHistoryEntry(_ url: URL) {
        history.delete(url: url)
        learned.forget(candidateIDs: ["hist:\(url.absoluteString)", HistoryStore.address(for: url).map { "hist:\($0)" } ?? ""])
        dropUnusedLogos()
        // The page the panel is on is that page even when its address carries a fragment the history row does not.
        let panelIsOnIt = HistoryStore.address(for: url).map { gone in
            settings.menuBar.lastAddress.flatMap(URL.init(string:)).flatMap(HistoryStore.address(for:)) == gone
        } ?? false
        if panelIsOnIt { settings.menuBar.lastAddress = nil }
        forgetInSavedFiles()
        if panelIsOnIt { onHistoryCleared?() }
        forEachEngineProfile { await $0.deleteHistory(of: url) }
    }

    /// The engine keeps a history of its own in every profile, including one with no page open now, so that profile's
    /// engine is started for this (as for Clear Site Data). Side by side: one that does not answer holds up no other.
    private func forEachEngineProfile(_ work: @escaping @MainActor (EngineProfile) async -> Void) {
        let profiles = workspace.profiles.map { environment(forProfile: $0.id).engineProfile }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for profile in profiles { group.addTask { await work(profile) } }
            }
        }
    }

    /// The files keep dated copies of themselves, and a copy made before something was forgotten would still hold it. What
    /// could: the settings (the menu-bar page), what the Command Bar learned (the typed words) and the sidebar (the address
    /// of every tab at the time, including pages a tab has since left). The first two are written again now and their copies
    /// dropped. The sidebar's live file has to keep the pages that are open, so its copies are dropped and no new one is made
    /// until the file has had time to move on (see `deleteBackupsAndPause`). A limit that is accepted: the pause lives in
    /// memory (a relaunch starts without it) and ends after one interval, and a copy made then lists the pages that are open
    /// then, which can include one that was open when history was cleared and has not been left since.
    private func forgetInSavedFiles() {
        guard dataDirectory != nil else { return }
        try? settingsFile?.rewriteDiscardingBackups(settings)
        try? learnedFile?.rewriteDiscardingBackups(learned)
        workspaceFile?.deleteBackupsAndPause()
    }

    /// Removes one archived tab (every one for nil), and the dated copies of the archive that still list it.
    /// The closed tab's address is in the sidebar's copies from when it was open and its logo is cached for its site.
    func removeFromArchive(_ id: UUID?) {
        // What was typed to find them goes too (the file keeps no copies, so it needs no rewrite).
        let removed = id.map { [$0] } ?? archive.entries.map(\.id)
        learned.forget(candidateIDs: Set(removed.map { "arch:\($0)" }))
        if let id { archive.remove(id) } else { archive.entries.removeAll() }
        dropUnusedLogos()
        guard dataDirectory != nil else { return }
        try? archiveFile?.rewriteDiscardingBackups(archive)
        workspaceFile?.deleteBackupsAndPause()
    }

    /// Logos are kept for the sites that have a page in the history or a tab, archived or not.
    private func dropUnusedLogos() {
        var hosts = history.hosts()
        for item in workspace.allTabs() { if let host = item.tab?.url?.host { hosts.insert(host) } }
        for entry in archive.entries { for item in entry.items { if let host = item.tab?.url?.host { hosts.insert(host) } } }
        favicons.keepOnly(hosts: hosts)
    }

    /// An incognito window is a store of its own with default settings. It takes over the choices that are about how the
    /// browser behaves rather than what it remembers, so a private window honours them too.
    func inheritPreferences(from parent: BrowserStore) {
        settings.radialMenu = parent.settings.radialMenu
        settings.trackpadHaptics = parent.settings.trackpadHaptics
    }

    func saveSession() {
        guard let sessionFile else { return }
        let state = SessionState(windows: windows.filter { !$0.isIncognito }.map {
            .init(focusedSpaceID: $0.focusedSpaceID, selection: $0.selection, sidebarVisible: $0.sidebarVisible, sidebarWidth: $0.sidebarWidth)
        })
        try? sessionFile.save(state)
    }

    /// Mutates the workspace and schedules a save. Every structural edit goes through here.
    @discardableResult
    func edit<T>(_ body: (inout Workspace) -> T) -> T {
        // A split dissolves into its last pane when another pane leaves it. A window that had the split selected
        // follows to that pane instead of being left on an item that no longer exists (a blank page).
        var panes: [UUID: [UUID]] = [:]
        for w in windows { for sel in w.selection.values { panes[sel] = workspace.item(sel)?.childIDs } }
        let result = body(&workspace)
        for w in windows {
            for (space, sel) in w.selection where workspace.item(sel) == nil {
                w.selection[space] = panes[sel]?.first { workspace.item($0) != nil }
            }
            // A window whose space went (replaced by an import) moves to one that is there.
            if workspace.space(w.focusedSpaceID) == nil, let first = workspace.spaces.first { w.focusedSpaceID = first.id }
        }
        markDirty(.workspace)
        return result
    }

    // MARK: Windows

    func register(_ window: WindowState) {
        windows.append(window)
        if activeWindow == nil { activeWindow = window }
    }

    func unregister(_ window: WindowState) {
        windows.removeAll { $0 === window }
        if activeWindow === window { activeWindow = windows.last }
        if !isTerminating { saveSession() }
    }

    /// A window for the saved session (or a default one) on its first space.
    func makeWindowState(restoring index: Int = 0) -> WindowState {
        let defaultSpace = workspace.spaces[0].id
        if !isIncognito, settings.restoreTabsOnLaunch, let saved = savedSession, index < saved.windows.count {
            let w = saved.windows[index]
            let space = workspace.space(w.focusedSpaceID)?.id ?? defaultSpace
            let state = WindowState(focusedSpaceID: space, sidebarWidth: w.sidebarWidth)
            state.sidebarVisible = w.sidebarVisible
            state.selection = w.selection.filter { workspace.item($0.value) != nil && workspace.space($0.key) != nil }
            return state
        }
        return WindowState(focusedSpaceID: defaultSpace, sidebarWidth: settings.sidebarWidth, isIncognito: isIncognito)
    }

    /// Shows `overlay` in a browser window. Settings uses it: it has no overlays of its own, so the app brings a browser
    /// window forward to show it in. Without the app (in tests) the active window just gets it.
    func present(_ overlay: Overlay) {
        if let onPresent { onPresent(overlay) } else { activeWindow?.overlay = overlay }
    }

    /// The sky of the space being looked at, for windows that are not part of a browser window (Settings, the menu-bar
    /// browser) so they match it.
    var currentTheme: SpaceTheme {
        let focused = (activeWindow ?? windows.first)?.focusedSpaceID
        return focused.flatMap { workspace.space($0)?.theme } ?? workspace.spaces.first?.theme ?? .nebula
    }

    // MARK: Environments

    /// Where the engine keeps a profile's cookies and storage; nil for a store that keeps nothing.
    func engineFolder(forProfile id: UUID) -> URL? {
        dataDirectory?.appendingPathComponent("Engine Profiles", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func environment(forProfile id: UUID?) -> ProfileEnvironment {
        if isIncognito || id == nil {
            if let e = incognitoEnvironment { return e }
            let e = ProfileEnvironment(profileID: nil, engineProfile: engine.makeProfile(id: nil, directory: nil), store: self)
            e.engineProfile.setPermissionDecisions(permissionDecisionList)
            blocker?.attach(to: e)
            incognitoEnvironment = e
            return e
        }
        let pid = id!
        if let e = environments[pid] { return e }
        let profile = workspace.profile(pid) ?? workspace.profiles[0]
        let e = ProfileEnvironment(profileID: profile.id, engineProfile: engine.makeProfile(id: profile.id, directory: engineFolder(forProfile: profile.id)),
                                   store: self)
        e.engineProfile.setPermissionDecisions(permissionDecisionList)
        e.installBoosts(boosts)
        if let blocker { blocker.attach(to: e) }
        if let extensions = e.engineProfile.extensions {
            extensions.tabsHost = ExtensionTabs(store: self, profileID: profile.id, extensions: extensions)
        }
        environments[pid] = e
        extensionCenter?.environmentCreated(e)
        return e
    }

    /// What the user decided about sites' permissions, as the engine takes it.
    var permissionDecisionList: [PermissionDecision] {
        settings.permissionDecisions.compactMap { key, allowed in
            guard let p = SitePermission(key: key, allowed: allowed), let kind = PermissionRequest.Kind(rawValue: p.kind) else { return nil }
            return PermissionDecision(host: p.host, kind: kind, allowed: allowed)
        }
    }

    /// The engine's side of every profile this store has opened.
    var engineProfiles: [EngineProfile] {
        environments.values.map(\.engineProfile) + (incognitoEnvironment.map { [$0.engineProfile] } ?? [])
    }

    /// Ends the engine's side of every profile (the store's windows are gone, or the app is quitting).
    func closeEnvironments() {
        for rt in runtimes.values { rt.tearDown() }
        runtimes.removeAll()
        for e in environments.values { e.engineProfile.close() }
        environments.removeAll()
        incognitoEnvironment?.engineProfile.close()
        incognitoEnvironment = nil
    }

    /// Starts every profile's engine again, so changed engine settings apply. Open tabs reload.
    func restartEngine() {
        for profile in engineProfiles { profile.restart() }
    }

    /// The engine has a Chromium now, after a time without one: every page asked for meanwhile is made again.
    func engineBecameReady() {
        for pid in Set(runtimes.keys.map(\.profile)) { engineRestarted(profileID: pid) }
    }

    /// The engine lost a profile's pages (it stopped, or it only now became ready): every tab of that profile gets a new
    /// page, and the ones on screen load again.
    func engineRestarted(profileID: UUID?) {
        for (key, rt) in runtimes where key.profile == profileID {
            rt.tearDown()
            runtimes[key] = nil
        }
        for w in windows {
            if let peek = w.peek, peek.runtime.profileID == profileID { closePeek(in: w) }
            for sel in w.selection.values { for t in workspace.tabs(under: sel) { ensureRuntime(forItem: t.id, in: w) } }
        }
        runtimeRevision += 1
    }

    func profileID(forItem id: UUID, in window: WindowState?) -> UUID? {
        if isIncognito { return nil }
        if let sid = workspace.spaceID(of: id), let space = workspace.space(sid) { return space.profileID }
        // Favorites live in every space: open them with the profile of the space being viewed.
        let focus = window?.focusedSpaceID ?? activeWindow?.focusedSpaceID ?? workspace.spaces[0].id
        return workspace.space(focus)?.profileID ?? workspace.profiles[0].id
    }

    func reinstallBoosts() {
        for e in environments.values { e.installBoosts(boosts) }
    }

    private func settingsChanged(old: Settings) {
        if old.adBlockingEnabled != settings.adBlockingEnabled || old.enabledFilterLists != settings.enabledFilterLists
            || old.adBlockAllowlist != settings.adBlockAllowlist {
            blocker?.settingsDidChange()
        }
        if old.appearance != settings.appearance { NSApp?.appearance = settings.appearance.nsAppearance }
        if old.engine != settings.engine { onEngineSettingsChanged?() }
        if old.permissionDecisions != settings.permissionDecisions {
            for profile in engineProfiles { profile.setPermissionDecisions(permissionDecisionList) }
        }
        // Not remembering the page forgets the one that was: the copies the file made while it was there go too.
        if old.menuBar.rememberPage && !settings.menuBar.rememberPage { try? settingsFile?.rewriteDiscardingBackups(settings) }
        haptics.isEnabled = settings.trackpadHaptics
        if old.radialMenu != settings.radialMenu || old.trackpadHaptics != settings.trackpadHaptics { onPreferencesChanged?() }
        // The page the panel is on is saved as it loads; that is bookkeeping, not a change anyone has to act on.
        var before = old.menuBar
        before.lastAddress = settings.menuBar.lastAddress
        if before != settings.menuBar { onMenuBarChange?() }
    }

    // MARK: Timers (auto-archive, memory saver)

    private func startTimers() {
        guard dataDirectory != nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.periodicMaintenance() }
        }
        t.tolerance = 10
        timers.append(t)
    }

    func periodicMaintenance() {
        runAutoArchive()
        discardIdleRuntimes()
        blocker?.refreshIfStale()
    }
}

extension Settings.AppearanceMode {
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Runtimes are keyed by item *and* profile: a Favorite is one sidebar item but a separate page per profile.
struct RuntimeKey: Hashable {
    let item: UUID
    let profile: UUID?
}
