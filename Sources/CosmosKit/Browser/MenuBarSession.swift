import AppKit
import WebKit
import CosmosCore

/// The page behind the menu-bar browser and what it needs from the main browser, without any of its own UI. The page is
/// made from the chosen profile's environment, so it uses the very same cookie jar and site data as that profile's tabs
/// (the same logins), the same blocking rules and Boosts, and what it loads goes into the same history.
@MainActor
@Observable
final class MenuBarSession {
    /// What a phone's Safari says about itself; sites that look at it answer with their mobile pages.
    static let phoneUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

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
        let made = TabRuntime(itemID: UUID(), profileID: profile, configuration: store.environment(forProfile: profile).makeConfiguration(), host: host)
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
        guard Self.agentDiffers(current: runtime.webView.customUserAgent, wanted: agent) else { return }
        runtime.webView.customUserAgent = agent
        // Sites choose their page by the agent, so one that is open is asked again.
        if runtime.url != nil { runtime.reload() }
    }

    /// Whether a web view's agent has to be changed to `wanted`. A web view that was never given one answers "".
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
    func tab(_ tab: TabRuntime, createChildWith configuration: WKWebViewConfiguration, features: WKWindowFeatures) -> WKWebView? {
        store.openPopup(from: tab, configuration: configuration, features: features, bringForward: session?.isPanelOpen() == true)
    }

    func tabRequestsClose(_ tab: TabRuntime) { session?.onHide() }

    func tabRequestsEscape(_ tab: TabRuntime) {
        if session?.isPinned == false { session?.onHide() }
    }

    func tab(_ tab: TabRuntime, boostZoomFor host: String) -> Double? { store.tab(tab, boostZoomFor: host) }

    func tab(_ tab: TabRuntime, remember allowed: Bool?, forPermission key: String) { store.tab(tab, remember: allowed, forPermission: key) }

    func tab(_ tab: TabRuntime, showRadialMenu menu: NSMenu, context: RadialContext, center: CGPoint, windowSize: CGSize) -> Bool { false }
}
