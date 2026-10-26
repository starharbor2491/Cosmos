import AppKit
import WebKit
import CosmosCore

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
    let haptics = Haptics()
    public let downloads = DownloadsManager()
    public let catalog = SearchCatalog.bundled
    public let isIncognito: Bool
    public let dataDirectory: URL?

    // MARK: Runtime state

    @ObservationIgnored var runtimes: [RuntimeKey: TabRuntime] = [:]
    @ObservationIgnored var environments: [UUID: ProfileEnvironment] = [:]
    @ObservationIgnored var incognitoEnvironment: ProfileEnvironment?
    /// The sidebar item being dragged right now, in any window (drop targets read it; nil when no drag is in flight).
    var draggingItemID: UUID?
    /// Bumped when a runtime is created or discarded so views that show "is this tab loaded?" refresh.
    public internal(set) var runtimeRevision = 0
    public private(set) var windows: [WindowState] = []
    /// The window the user is working in (key window); menu commands act on it.
    public weak var activeWindow: WindowState?
    /// Ids restorable with ⇧⌘T, newest first.
    var recentlyClosed: [UUID] = []
    @ObservationIgnored var blocker: ContentBlockerController?
    /// Browser extensions (macOS 15.4+ runs them); `nil` in incognito windows, which never load extensions.
    @ObservationIgnored var extensionCenter: ExtensionCenter?
    @ObservationIgnored var onOpenProbe: ((URL) -> Void)?
    @ObservationIgnored var onNewWindow: (() -> Void)?
    @ObservationIgnored var onOpenIncognito: (() -> Void)?
    @ObservationIgnored var onShowSettings: (() -> Void)?
    @ObservationIgnored var onShowSettingsTab: ((SettingsTab) -> Void)?
    @ObservationIgnored var onPopupWindow: ((TabRuntime, WKWindowFeatures) -> Void)?

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
    public init(directory: URL?, incognito: Bool = false) {
        isIncognito = incognito
        dataDirectory = directory
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ws = JSONFileStore<Workspace>(url: directory.appendingPathComponent("workspace.json"))
            let ar = JSONFileStore<ArchiveData>(url: directory.appendingPathComponent("archive.json"), backupInterval: 6 * 3600)
            let bo = JSONFileStore<BoostLibrary>(url: directory.appendingPathComponent("boosts.json"))
            let ro = JSONFileStore<LinkRouting>(url: directory.appendingPathComponent("link-routing.json"), backupInterval: 6 * 3600)
            let se = JSONFileStore<Settings>(url: directory.appendingPathComponent("settings.json"), backupInterval: 6 * 3600)
            let le = JSONFileStore<LearnedSelections>(url: directory.appendingPathComponent("command-bar-learning.json"), backupInterval: 24 * 3600)
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
            archive = ((try? ar.load()) ?? nil) ?? ArchiveData()
            boosts = ((try? bo.load()) ?? nil) ?? BoostLibrary()
            linkRouting = ((try? ro.load()) ?? nil) ?? LinkRouting()
            settings = ((try? se.load()) ?? nil) ?? Settings()
            learned = ((try? le.load()) ?? nil) ?? LearnedSelections()
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
            favicons = FaviconStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-incognito-\(UUID().uuidString)"))
        }
        haptics.isEnabled = settings.trackpadHaptics
        startTimers()
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
        let result = body(&workspace)
        markDirty(.workspace)
        return result
    }

    // MARK: Windows

    func register(_ window: WindowState) {
        windows.append(window)
        if activeWindow == nil { activeWindow = window }
        extensionCenter?.windowOpened(window)
    }

    func unregister(_ window: WindowState) {
        windows.removeAll { $0 === window }
        extensionCenter?.windowClosed(window)
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

    // MARK: Environments

    func environment(forProfile id: UUID?) -> ProfileEnvironment {
        if isIncognito || id == nil {
            if let e = incognitoEnvironment { return e }
            let e = ProfileEnvironment(profile: nil, isDefault: false)
            e.installBoosts(BoostLibrary())
            blocker?.attach(to: e)
            incognitoEnvironment = e
            return e
        }
        let pid = id!
        if let e = environments[pid] { return e }
        let profile = workspace.profile(pid) ?? workspace.profiles[0]
        let e = ProfileEnvironment(profile: profile, isDefault: profile.isDefault)
        e.installBoosts(boosts)
        e.extensionController = extensionCenter?.controllerObject
        if let blocker { blocker.attach(to: e) }
        environments[pid] = e
        return e
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
        haptics.isEnabled = settings.trackpadHaptics
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
