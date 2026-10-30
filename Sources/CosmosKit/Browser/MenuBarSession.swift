import AppKit
import CosmosCore
import CosmosEngine

/// The page behind the menu-bar browser and what it needs from the main browser, without any of its own UI. The page is
/// made from the chosen profile's environment, so it uses the very same cookie jar and site data as that profile's tabs
/// (the same logins), the same blocking rules and Boosts, and what it loads goes into the same history.
@MainActor
@Observable
final class MenuBarSession {
    /// What Chrome on a phone says about itself; sites that look at it answer with their mobile pages.
    static let phoneUserAgent = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

    let store: BrowserStore
    private(set) var runtime: TabRuntime?
    /// A pinned panel stays open when the keyboard goes elsewhere.
    var isPinned = false { didSet { onPinChange() } }
    /// Counts up when the address field should take the keyboard (the panel opened on nothing).
    private(set) var addressFocusRequests = 0
    /// The panel should go away: the page closed itself, or Esc was pressed in a panel that is not pinned.
    @ObservationIgnored var onHide: () -> Void = {}
    /// The pin was turned on or off: the panel floats above other windows while it is on.
    @ObservationIgnored var onPinChange: () -> Void = {}
    /// Whether the panel is on screen: a window its page opens is the user's to see only then.
    @ObservationIgnored var isPanelOpen: () -> Bool = { false }
    /// The panel was resized by hand to this size.
    @ObservationIgnored var onResized: (CGSize) -> Void = { _ in }
    /// A page that belongs in a browser window (⌘-click, "Open in Cosmos").
    @ObservationIgnored var onOpenInCosmos: (URL) -> Void = { _ in }
    @ObservationIgnored private var host: MenuBarHost?
    @ObservationIgnored private var builtForProfile: UUID?

    init(store: BrowserStore) {
        self.store = store
    }

    /// The profile whose data the panel uses: the one chosen in Settings, or the default if that is gone.
    var profileID: UUID {
        let profiles = store.workspace.profiles
        return (store.settings.menuBar.profile(in: profiles) ?? profiles[0]).id
    }

    private var engine: SearchEngine { store.catalog.engine(store.settings.searchEngineID) }

    /// The page, made if it is not there yet or if the profile changed. A change of layout keeps the page and tells it
    /// again what it is.
    @discardableResult
    func prepare() -> TabRuntime {
        let profile = profileID
        if let runtime, builtForProfile == profile {
            applyLayout(to: runtime)
            return runtime
        }
        teardown()
        let host = MenuBarHost(session: self, store: store)
        let made = TabRuntime(itemID: UUID(), profileID: profile, environment: store.environment(forProfile: profile), host: host)
        made.isEphemeral = true
        applyLayout(to: made)
        if let start = store.settings.menuBar.startURL(engine: engine) { made.load(start) }
        self.host = host
        builtForProfile = profile
        runtime = made
        return made
    }

    private func applyLayout(to runtime: TabRuntime) {
        let agent = store.settings.menuBar.layout.isMobile ? Self.phoneUserAgent : nil
        guard Self.agentDiffers(current: runtime.page.userAgent, wanted: agent) else { return }
        runtime.page.userAgent = agent
        // Sites choose their page by the agent, so one that is open is asked again.
        if runtime.url != nil { runtime.reload() }
    }

    /// Whether a page's agent has to be changed to `wanted`. A page that was never given one has the engine's own.
    static func agentDiffers(current: String?, wanted: String?) -> Bool {
        (current ?? "") != (wanted ?? "")
    }

    func teardown() {
        runtime?.tearDown()
        runtime = nil
        host = nil
        builtForProfile = nil
    }

    func focusAddress() { addressFocusRequests += 1 }

    /// Loads what was typed in the address field.
    func go(_ text: String) {
        guard let url = Self.destination(for: text, engine: engine) else { return }
        prepare().load(url)
    }

    /// What typed text stands for: a web address, or a search. Nothing for empty text. Only web pages open here;
    /// anything else typed is searched for.
    static func destination(for text: String, engine: SearchEngine) -> URL? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        if case .url(let url) = URLInput.resolve(typed), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { return url }
        return engine.searchURL(for: typed)
    }
}

/// What the page asks of its host, answered for a panel: there is no sidebar, no window and no ring, so the page keeps to
/// itself, and what belongs in a browser window is sent there.
@MainActor
final class MenuBarHost: TabHost {
    private weak var session: MenuBarSession?
    private let store: BrowserStore

    init(session: MenuBarSession, store: BrowserStore) {
        self.session = session
        self.store = store
    }

    var settings: Settings { store.settings }
    var favicons: FaviconStore { store.favicons }
    var downloads: DownloadsManager { store.downloads }
    var isDraggingSidebarItem: Bool { false }
    var opensNewWindowsInPlace: Bool { true }

    func tabDidChange(_ tab: TabRuntime) {}

    func tabWantsLocation(_ tab: TabRuntime) async -> PageLocation? { await store.locate() }

    func tab(_ tab: TabRuntime, credentialsFor challenge: AuthChallenge) async -> PageCredentials? { await store.signIn(tab, challenge) }
    func tab(_ tab: TabRuntime, showPictureInPicture view: NSView) -> Bool { store.onPictureInPicture?(tab, view) ?? false }
    func tabDidLeavePictureInPicture(_ tab: TabRuntime) { store.onPictureInPictureEnded?(tab) }
    var passwordManager: PasswordManager? { store.passwordManager }
    func tab(_ tab: TabRuntime, wantsExtensionFromWebStore id: String) { store.tab(tab, wantsExtensionFromWebStore: id) }
    func tab(_ tab: TabRuntime, showNotification note: EngineNotification) { store.tab(tab, showNotification: note) }
    func tab(_ tab: TabRuntime, closeNotification id: String) { store.tab(tab, closeNotification: id) }
    func tab(_ tab: TabRuntime, dangerAt url: URL) -> PageDanger? { store.tab(tab, dangerAt: url) }
    func tab(_ tab: TabRuntime, allowDangerous url: URL) { store.allowDangerousSite(url) }

    func tabDidFinishLoading(_ tab: TabRuntime) {
        guard let url = tab.url else { return }
        store.history.record(url: url, title: tab.title, typed: false)
        store.history.updateTitle(url: url, title: tab.title)
        store.settings.menuBar.remember(url)
    }

    func tabIsPinnedOrFavorite(_ tab: TabRuntime) -> Bool { false }

    func tab(_ tab: TabRuntime, open url: URL, as disposition: LinkDisposition) {
        switch disposition {
        case .currentTab: tab.load(url)
        case .newTabForeground, .newTabBackground, .peek, .split: session?.onOpenInCosmos(url)
        case .download: store.startDownload(of: url, from: tab)
        }
    }

    /// Only a script-sized window gets here (the rest load in place, see `opensNewWindowsInPlace`): an OAuth sign-in needs
    /// its opener, so it is a window of its own.
    func tab(_ tab: TabRuntime, didOpen page: EnginePage, request: NewPageRequest) -> Bool {
        store.openPopup(page, profileID: tab.profileID, request: request, bringForward: session?.isPanelOpen() == true)
    }

    func tabRequestsClose(_ tab: TabRuntime) { session?.onHide() }

    func tabRequestsEscape(_ tab: TabRuntime) {
        if session?.isPinned == false { session?.onHide() }
    }

    func tab(_ tab: TabRuntime, boostZoomFor host: String) -> Double? { store.tab(tab, boostZoomFor: host) }

    func tab(_ tab: TabRuntime, remember allowed: Bool?, forPermission key: String) { store.tab(tab, remember: allowed, forPermission: key) }

    func tab(_ tab: TabRuntime, showRadialMenu menu: NSMenu, context: RadialContext, center: CGPoint, windowSize: CGSize) -> Bool { false }
}
