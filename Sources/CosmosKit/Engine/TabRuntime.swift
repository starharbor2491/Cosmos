import AppKit
import CosmosCore
import CosmosEngine

public enum LinkDisposition {
    case currentTab, newTabForeground, newTabBackground, peek, split, download
}

/// What a tab needs from the browser around it. `BrowserStore` implements it.
@MainActor
public protocol TabHost: AnyObject {
    var settings: Settings { get }
    var favicons: FaviconStore { get }
    var downloads: DownloadsManager { get }
    /// True while a tab or folder dragged out of the sidebar is in flight.
    var isDraggingSidebarItem: Bool { get }
    func tabDidChange(_ tab: TabRuntime)
    func tabDidFinishLoading(_ tab: TabRuntime)
    func tabIsPinnedOrFavorite(_ tab: TabRuntime) -> Bool
    func tab(_ tab: TabRuntime, open url: URL, as disposition: LinkDisposition)
    /// The page opened a page of its own (`window.open`, a link to a new window) that the engine has already made. Return
    /// false to close it.
    func tab(_ tab: TabRuntime, didOpen page: EnginePage, request: NewPageRequest) -> Bool
    func tabRequestsClose(_ tab: TabRuntime)
    func tabRequestsEscape(_ tab: TabRuntime)
    func tab(_ tab: TabRuntime, boostZoomFor host: String) -> Double?
    /// Remembers (or, with `nil`, forgets) what the user answered when a site asked for a permission. `key` is `host|kind`.
    func tab(_ tab: TabRuntime, remember allowed: Bool?, forPermission key: String)
    /// Shows the radial menu for the context menu a page asked for; false leaves the menu to be drawn as a menu.
    func tab(_ tab: TabRuntime, showRadialMenu menu: NSMenu, context: RadialContext, center: CGPoint, windowSize: CGSize) -> Bool
    /// True where there is no room for another window or tab (the menu-bar panel): a link that asks for one loads in place.
    var opensNewWindowsInPlace: Bool { get }
    /// The page is about to be replaced (a load, a reload, a link followed): anything that was made from it is out of date.
    func tabWillNavigate(_ tab: TabRuntime)
    /// The items extensions added to the right-click menu, for what the click was on.
    func extensionMenuItems(for tab: TabRuntime, contexts: Set<String>) -> [ExtensionMenuItem]
    func tab(_ tab: TabRuntime, performExtensionItem item: ExtensionMenuItem, context: ExtensionClickContext)
    /// Where the Mac is, for a site that was allowed to know.
    func tabWantsLocation(_ tab: TabRuntime) async -> PageLocation?
    /// A user name and password for a site that asks (HTTP authentication).
    func tab(_ tab: TabRuntime, credentialsFor challenge: AuthChallenge) async -> PageCredentials?
    /// Whether the site of `url` is on a malware or phishing list (and the user has not chosen to go anyway).
    func tab(_ tab: TabRuntime, dangerAt url: URL) -> PageDanger?
    func tab(_ tab: TabRuntime, allowDangerous url: URL)
    /// Posts a page's notification (to macOS), or takes it back.
    func tab(_ tab: TabRuntime, showNotification note: EngineNotification)
    func tab(_ tab: TabRuntime, closeNotification id: String)
    /// Puts a video in a floating window of its own; false when there is none to put it in.
    func tab(_ tab: TabRuntime, showPictureInPicture view: NSView) -> Bool
    func tabDidLeavePictureInPicture(_ tab: TabRuntime)
}

public extension TabHost {
    var opensNewWindowsInPlace: Bool { false }
    func tabWillNavigate(_ tab: TabRuntime) {}
    func extensionMenuItems(for tab: TabRuntime, contexts: Set<String>) -> [ExtensionMenuItem] { [] }
    func tab(_ tab: TabRuntime, performExtensionItem item: ExtensionMenuItem, context: ExtensionClickContext) {}
    func tabWantsLocation(_ tab: TabRuntime) async -> PageLocation? { nil }
    func tab(_ tab: TabRuntime, credentialsFor challenge: AuthChallenge) async -> PageCredentials? { await tab.askForCredentials(challenge) }
    func tab(_ tab: TabRuntime, showPictureInPicture view: NSView) -> Bool { false }
    func tabDidLeavePictureInPicture(_ tab: TabRuntime) {}
    func tab(_ tab: TabRuntime, showNotification note: EngineNotification) {}
    func tab(_ tab: TabRuntime, dangerAt url: URL) -> PageDanger? { nil }
    func tab(_ tab: TabRuntime, allowDangerous url: URL) {}
    func tab(_ tab: TabRuntime, closeNotification id: String) {}
}

/// One live page: owns the engine's page, mirrors its state into observable properties and answers what the page asks
/// (new windows, dialogs, files, permissions, context menus).
@MainActor
@Observable
public final class TabRuntime: NSObject {
    public private(set) var itemID: UUID
    /// The profile whose cookies this page uses; `nil` in incognito.
    public let profileID: UUID?
    @ObservationIgnored public let page: EnginePage
    @ObservationIgnored weak var host: TabHost?
    /// The view that shows the page.
    public var view: NSView { page.view }

    public private(set) var title = ""
    public private(set) var url: URL?
    public private(set) var isLoading = false
    public private(set) var progress = 0.0
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    public private(set) var isAudible = false
    public private(set) var hasPlayingVideo = false
    /// The page Cosmos stopped because its site is on a malware or phishing list, while the warning is up.
    public private(set) var danger: (url: URL, kind: PageDanger)?
    /// A video of this page is in its Picture in Picture window.
    public private(set) var isInPictureInPicture = false
    public private(set) var hoverURL: URL?
    public private(set) var themeColor: RGBA?
    public private(set) var loadFailed = false
    public private(set) var isCapturing = false
    public var isMuted = false { didSet { applyMute() } }
    public var lastActivity = Date()
    /// Set when this runtime is a throwaway (Peek, Probe, popup) rather than a sidebar tab.
    public var isEphemeral = false

    /// What was under the pointer at the last right click (the page agent reports it with the click).
    @ObservationIgnored private(set) var context = PageContext()

    struct PageContext {
        var link: URL?
        var image: URL?
        var media: URL?
        var selection = ""
        var editable = false
        var isMedia = false
        /// Where the click was, in the page's own pixels from its top-left; only known for the main frame.
        var point: CGPoint?
    }
    @ObservationIgnored private var pendingBoostZoom = true
    @ObservationIgnored private var mediaFrames: [String: Bool] = [:]
    @ObservationIgnored private var crashes = CrashLoopGuard()
    @ObservationIgnored private var isTornDown = false

    public init(itemID: UUID, profileID: UUID?, page: EnginePage, host: TabHost?) {
        self.itemID = itemID
        self.profileID = profileID
        self.page = page
        self.host = host
        super.init()
        page.delegate = self
        Self.owners[ObjectIdentifier(page)] = Owner(runtime: self)
        mirror()
    }

    convenience init(itemID: UUID, profileID: UUID?, environment: ProfileEnvironment, host: TabHost?) {
        self.init(itemID: itemID, profileID: profileID, page: environment.makePage(), host: host)
    }

    private struct Owner { weak var runtime: TabRuntime? }
    private static var owners: [ObjectIdentifier: Owner] = [:]

    /// The tab that shows `page`.
    static func owning(_ page: EnginePage) -> TabRuntime? { owners[ObjectIdentifier(page)]?.runtime }

    // MARK: State mirroring

    private func mirror() {
        let s = page.state
        title = s.title
        url = s.url
        isLoading = s.isLoading
        progress = s.progress
        canGoBack = s.canGoBack
        canGoForward = s.canGoForward
        isCapturing = s.isCapturing
    }

    // MARK: Commands

    public func load(_ url: URL) {
        loadFailed = false
        page.load(url)
    }

    public func reload(fromOrigin: Bool = false) {
        loadFailed = false
        page.reload(fromOrigin: fromOrigin)
    }
    public func stop() { page.stop() }
    public func goBack() { page.goBack() }
    public func goForward() { page.goForward() }
    /// The range ⌘+ and ⌘- keep to; a zoom read from a Boost file is held to it too.
    static func clampedZoom(_ z: Double) -> Double { z.isFinite ? min(5, max(0.25, z)) : 1 }

    public func zoomIn() { page.zoom = Self.clampedZoom(page.zoom + 0.1) }
    public func zoomOut() { page.zoom = Self.clampedZoom(page.zoom - 0.1) }
    public func resetZoom() { page.zoom = 1 }
    public var zoom: Double { page.zoom }

    /// Runs `js` in the page; `world` `.agent` is Cosmos's own, out of the page's reach.
    public func evaluate(_ js: String, in world: ScriptWorld = .page) {
        Task { _ = await page.evaluate(js, in: world) }
    }

    public func evaluate(returning js: String, in world: ScriptWorld = .page) async -> Any? {
        await page.evaluate(js, in: world)
    }

    public func find(_ text: String, backwards: Bool = false, completion: @escaping (Bool) -> Void) {
        guard !text.isEmpty else { completion(false); return }
        let js = "window.find(\(BoostInjector.jsString(text)), false, \(backwards), true, false, true, false)"
        Task { completion(await page.evaluate(js, in: .agent) as? Bool ?? false) }
    }

    public func clearFind() {
        evaluate("window.getSelection().removeAllRanges()", in: .agent)
    }

    private func applyMute() {
        evaluate("window.__cosmosMute && window.__cosmosMute(\(isMuted))", in: .agent)
    }

    /// Moves the playing video into Picture-in-Picture (used when the user leaves the tab).
    public func enterPictureInPicture() {
        let js = """
        (async () => {
          const vids = [...document.querySelectorAll('video')].filter(v => !v.paused && !v.ended && v.readyState > 2 && !v.disablePictureInPicture);
          vids.sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight);
          const v = vids[0];
          if (!v || document.pictureInPictureElement === v) return;
          try { await v.requestPictureInPicture(); } catch (e) {}
        })();
        """
        // In the page's own world, where the engine's Picture in Picture is.
        evaluate(js, in: .page)
    }

    public func exitPictureInPicture() {
        page.leavePictureInPicture()
    }

    public func takeSnapshot(width: CGFloat = 320, completion: @escaping (NSImage?) -> Void) {
        Task { completion(await page.snapshot(width: width)) }
    }

    /// Turns a throwaway page (Peek) into the page of a sidebar tab.
    func adopt(itemID: UUID) { self.itemID = itemID }

    /// Closes the page so the runtime can be released.
    public func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        Self.owners[ObjectIdentifier(page)] = nil
        page.delegate = nil
        page.close()
    }

    // MARK: New windows

    /// A page this one opened, already made by the engine.
    func opened(_ child: EnginePage, request: NewPageRequest) -> Bool {
        guard let host else { return false }
        if Self.loadsNewWindowInPlace(hostOpensInPlace: host.opensNewWindowsInPlace, request: request) {
            if let url = request.url, Self.isWebLink(url) { load(url) }
            return false
        }
        return host.tab(self, didOpen: child, request: request)
    }

    /// A page that asks for a script-sized window (an OAuth sign-in, a payment sheet) needs its opener, so it must get a
    /// real window; every other new-window request loads where it is when the host has no room for another window.
    static func loadsNewWindowInPlace(hostOpensInPlace: Bool, request: NewPageRequest) -> Bool {
        hostOpensInPlace && !request.isScriptSizedPopup
    }

    // MARK: Agent messages

    func handleAgentMessage(_ body: [String: Any], fromMainFrame: Bool) {
        switch body["type"] as? String {
        case "ready":
            if fromMainFrame { sendConfig() }
        case "meta":
            guard fromMainFrame, let pageURL = url, let host = pageURL.host else { return }
            let icons = (body["icons"] as? [[String: Any]] ?? []).compactMap { d -> (URL, String, String)? in
                guard let href = (d["href"] as? String).flatMap(URL.init(string:)), href.scheme == "https" || href.scheme == "http" || href.scheme == "data" else { return nil }
                return (href, d["sizes"] as? String ?? "", d["rel"] as? String ?? "")
            }
            self.host?.favicons.update(host: host, candidates: icons.map { FaviconStore.Candidate(href: $0.0, sizes: $0.1, rel: $0.2) }, pageURL: pageURL)
            themeColor = (body["themeColor"] as? String).flatMap(Self.parseCSSColor)
        case "link":
            guard let href = (body["href"] as? String).flatMap(URL.init(string:)), Self.isWebLink(href) else { break }
            followLink(href, meta: body["meta"] as? Bool ?? false, shift: body["shift"] as? Bool ?? false, alt: body["alt"] as? Bool ?? false)
        case "external":
            guard let href = (body["href"] as? String).flatMap(URL.init(string:)), let scheme = href.scheme?.lowercased(),
                  !Self.webSchemes.contains(scheme) else { break }
            openElsewhere(href)
        case "media":
            // Each frame reports its own media; the tab is audible while any of them plays.
            let key = (body["frame"] as? String).map { "\($0)" } ?? (fromMainFrame ? "top" : "sub")
            mediaFrames[key] = (body["playing"] as? Bool) ?? false
            isAudible = mediaFrames.values.contains(true)
            hasPlayingVideo = (body["video"] as? Bool) ?? false
            if !isAudible && !(body["video"] as? Bool ?? false) { hasPlayingVideo = false }
            host?.tabDidChange(self)
        case "context":
            var next = PageContext(link: Self.address(body["link"]), image: Self.address(body["image"]), media: Self.address(body["mediaSrc"]),
                                   selection: body["selection"] as? String ?? "", editable: body["editable"] as? Bool ?? false,
                                   isMedia: body["media"] as? Bool ?? false)
            if fromMainFrame, let x = body["x"] as? Double, let y = body["y"] as? Double, x.isFinite, y.isFinite { next.point = CGPoint(x: x, y: y) }
            context = next
            // A site that draws a right-click menu of its own said so; Cosmos then shows none.
            if !(body["handled"] as? Bool ?? false) { showContextMenu() }
        case "hover":
            hoverURL = (body["href"] as? String).flatMap(URL.init(string:))
        case "escape":
            host?.tabRequestsEscape(self)
        default: break
        }
    }

    private static func address(_ value: Any?) -> URL? { (value as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) } }

    /// What the agent needs to know about this tab: whether a link to another site opens in Peek.
    private func sendConfig() {
        let peek = host.map { $0.settings.peekFromPinned && $0.tabIsPinnedOrFavorite(self) } ?? false
        evaluate("window.__cosmosConfig && window.__cosmosConfig({ peekCrossSite: \(peek) })", in: .agent)
    }

    /// A click on a link the agent held back: ⌘-click opens a background tab, ⇧⌘-click a foreground one, ⇧-click Peek,
    /// ⌥-click downloads, and a plain click in a pinned tab or Favorite that leaves the site opens Peek.
    private func followLink(_ href: URL, meta: Bool, shift: Bool, alt: Bool) {
        if meta { host?.tab(self, open: href, as: shift ? .newTabForeground : .newTabBackground); return }
        if alt { host?.tab(self, open: href, as: .download); return }
        if shift { host?.tab(self, open: href, as: .peek); return }
        if let host, host.settings.peekFromPinned, host.tabIsPinnedOrFavorite(self),
           let current = url, !PublicSuffixList.shared.isSameSite(current, href) {
            host.tab(self, open: href, as: .peek)
        } else {
            load(href)
        }
    }

    static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "view-source", "javascript", "chrome-extension"]

    /// A link that belongs to another app (`zoommtg:`, `slack:`): the user clicked it, and is asked before it leaves.
    private func openElsewhere(_ url: URL) {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        if url.scheme?.lowercased() == "mailto" { NSWorkspace.shared.open(url); return }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let alert = NSAlert()
        alert.messageText = "Open “\(name)”?"
        alert.informativeText = "\(url.host.map { "“\($0)”" } ?? "This page") wants to open a link in \(name)."
        alert.addButton(withTitle: "Open \(name)")
        alert.addButton(withTitle: "Cancel")
        present(alert) { if $0 == .alertFirstButtonReturn { NSWorkspace.shared.open(url) } }
    }

    static func parseCSSColor(_ s: String) -> RGBA? {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.hasPrefix("#") else { return nil }
        t.removeFirst()
        if t.count == 3 { t = t.map { "\($0)\($0)" }.joined() }
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        return RGBA(hex: v)
    }

    /// Peek and Split load a page beside this one: only a web address (a page can link to a file or a script too).
    static func isWebLink(_ url: URL) -> Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") }

    // MARK: Errors

    private func presentError(_ error: PageLoadError, url failing: URL) {
        loadFailed = true
        switch error.kind {
        case .malware: danger = (failing, .malware)
        case .phishing: danger = (failing, .phishing)
        default: danger = nil
        }
        page.loadHTML(ErrorPage.html(for: error, url: failing), showing: failing)
        host?.tabDidChange(self)
    }

    // MARK: Sheets

    func present(_ alert: NSAlert, _ done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }

    /// Waits until the page is on screen: a tab in the background does not get to put up a dialog over whatever the user is
    /// looking at. False if the tab went away first.
    private func waitUntilShown() async -> Bool {
        while view.window == nil {
            if isTornDown { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return !isTornDown
    }

    private func sheet(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { c in present(alert) { c.resume(returning: $0) } }
    }
}

// MARK: - Engine page delegate

extension TabRuntime: EnginePageDelegate {
    public func pageStateDidChange(_ page: EnginePage) {
        mirror()
        host?.tabDidChange(self)
    }

    public func pageDidStartNavigation(_ page: EnginePage) {
        loadFailed = false
        danger = nil
        mediaFrames.removeAll()
        isAudible = false
        hoverURL = nil
        pendingBoostZoom = true
        // What was under the pointer on the last page says nothing about this one.
        context = PageContext()
        host?.tabWillNavigate(self)
    }

    public func pageDidCommitNavigation(_ page: EnginePage) {
        lastActivity = Date()
        mirror()
        if pendingBoostZoom, let h = url?.host, let z = host?.tab(self, boostZoomFor: h) {
            page.zoom = Self.clampedZoom(z)
        }
        pendingBoostZoom = false
        if isMuted { applyMute() }
        host?.tabDidChange(self)
    }

    public func pageDidFinishLoading(_ page: EnginePage) {
        mirror()
        host?.tabDidFinishLoading(self)
    }

    public func page(_ page: EnginePage, didFailLoading url: URL, error: PageLoadError) {
        presentError(error, url: url)
    }

    public func page(_ page: EnginePage, agentMessage: [String: Any], fromMainFrame: Bool) {
        handleAgentMessage(agentMessage, fromMainFrame: fromMainFrame)
    }

    public func page(_ page: EnginePage, runDialog dialog: PageDialog) async -> PageDialog.Answer {
        guard await waitUntilShown() else { return PageDialog.Answer(accepted: false) }
        let alert = NSAlert()
        alert.messageText = dialog.origin.isEmpty ? "This page says" : dialog.origin
        alert.informativeText = dialog.message
        var field: NSTextField?
        switch dialog.kind {
        case .alert:
            alert.addButton(withTitle: "OK")
        case .confirm:
            alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        case .prompt(let text):
            alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
            let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            f.stringValue = text
            alert.accessoryView = f
            field = f
        case .beforeUnload:
            alert.messageText = "Leave this page?"
            alert.informativeText = "Changes you made may not be saved."
            alert.addButton(withTitle: "Leave"); alert.addButton(withTitle: "Stay")
        }
        let response = await sheet(alert)
        let accepted = response == .alertFirstButtonReturn
        return PageDialog.Answer(accepted: accepted, text: accepted ? field?.stringValue : nil)
    }

    public func page(_ page: EnginePage, chooseFiles chooser: FileChooser) async -> [URL]? {
        guard await waitUntilShown() else { return nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = chooser.allowsMultiple
        panel.canChooseDirectories = chooser.allowsDirectories
        panel.canChooseFiles = true
        let response: NSApplication.ModalResponse = await withCheckedContinuation { c in
            if let window = view.window { panel.beginSheetModal(for: window) { c.resume(returning: $0) } } else { c.resume(returning: panel.runModal()) }
        }
        return response == .OK ? panel.urls : nil
    }

    public func page(_ page: EnginePage, wantsPermission request: PermissionRequest) async -> Bool {
        let noun: String = switch request.kind {
        case .camera: "camera"
        case .microphone: "microphone"
        case .cameraAndMicrophone: "camera and microphone"
        case .location: "location"
        case .notifications: "notifications"
        }
        let site = request.host
        let key = "\(site)|\(request.kind.rawValue)"
        if !site.isEmpty, let known = host?.settings.permissionDecisions[key] { return known }
        // Settings ▸ Engine blocks it for every site the user has not decided about.
        if let engine = host?.settings.engine, Self.blocks(engine, request.kind) { return false }
        guard await waitUntilShown() else { return false }
        let alert = NSAlert()
        alert.messageText = site.isEmpty ? "This page wants to use your \(noun)" : "“\(site)” wants to use your \(noun)"
        alert.informativeText = site.isEmpty ? "" : "Cosmos remembers your answer for this site. You can change it from the Site Controls panel."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        let allowed = await sheet(alert) == .alertFirstButtonReturn
        if !site.isEmpty { host?.tab(self, remember: allowed, forPermission: key) }
        return allowed
    }

    static func blocks(_ s: EngineSettings, _ kind: PermissionRequest.Kind) -> Bool {
        switch kind {
        case .camera: s.camera == .block
        case .microphone: s.microphone == .block
        case .cameraAndMicrophone: s.camera == .block || s.microphone == .block
        case .location: s.location == .block
        case .notifications: s.notifications == .block
        }
    }

    public func pageWantsLocation(_ page: EnginePage) async -> PageLocation? { await host?.tabWantsLocation(self) }

    public func page(_ page: EnginePage, showNotification note: EngineNotification) { host?.tab(self, showNotification: note) }

    public func page(_ page: EnginePage, dangerAt url: URL) -> PageDanger? { host?.tab(self, dangerAt: url) }

    /// The warning's "Visit Anyway": the site is let through for the rest of this run, and the page loads.
    public func visitDangerousSiteAnyway() {
        guard let danger else { return }
        host?.tab(self, allowDangerous: danger.url)
        self.danger = nil
        load(danger.url)
    }

    /// The warning's "Go Back": back to the page before, or to an empty one.
    public func leaveDangerousSite() {
        danger = nil
        if page.state.canGoBack { page.goBack() } else { load(URL(string: "about:blank")!) }
    }
    public func page(_ page: EnginePage, closeNotification id: String) { host?.tab(self, closeNotification: id) }

    public func page(_ page: EnginePage, wantsPictureInPicture view: NSView) async -> Bool {
        guard host?.tab(self, showPictureInPicture: view) == true else { return false }
        isInPictureInPicture = true
        return true
    }

    public func pageDidLeavePictureInPicture(_ page: EnginePage) {
        guard isInPictureInPicture else { return }
        isInPictureInPicture = false
        host?.tabDidLeavePictureInPicture(self)
    }

    public func page(_ page: EnginePage, wantsCredentialsFor challenge: AuthChallenge) async -> PageCredentials? {
        await host?.tab(self, credentialsFor: challenge)
    }

    /// The sheet that asks for a user name and password, over the tab once it is on screen.
    func askForCredentials(_ challenge: AuthChallenge) async -> PageCredentials? {
        guard await waitUntilShown() else { return nil }
        let alert = NSAlert()
        alert.messageText = challenge.isProxy ? "The proxy “\(challenge.host)” wants a user name and password" : "Sign in to “\(challenge.host)”"
        var info = challenge.realm.isEmpty ? "" : "The site says: “\(challenge.realm)”."
        if !challenge.isSecure { info += (info.isEmpty ? "" : " ") + "Your password will be sent without encryption." }
        alert.informativeText = info
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        user.placeholderString = "User name"
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        password.placeholderString = "Password"
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        fields.addSubview(user)
        fields.addSubview(password)
        alert.accessoryView = fields
        alert.window.initialFirstResponder = user
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        guard await sheet(alert) == .alertFirstButtonReturn else { return nil }
        return PageCredentials(user: user.stringValue, password: password.stringValue)
    }

    /// Pressing hard on a link opens it in Peek, like ⇧-click. The press ends in a click, which the agent then keeps from
    /// also following the link.
    public func pageDidForceClick(_ page: EnginePage) {
        guard let href = hoverURL, Self.isWebLink(href) else { return }
        evaluate("window.__cosmosHoldClick && window.__cosmosHoldClick()", in: .agent)
        host?.tab(self, open: href, as: .peek)
    }

    public func pageRequestsClose(_ page: EnginePage) { host?.tabRequestsClose(self) }

    public func pageRendererDidTerminate(_ page: EnginePage) {
        // The renderer crashed or was killed under memory pressure: bring the page back, unless it keeps happening.
        switch crashes.decide(at: Date()) {
        case .reload:
            page.reload(fromOrigin: false)
        case .showError:
            presentError(PageLoadError(kind: .crashed, detail: "The page's process stopped."), url: url ?? URL(string: "about:blank")!)
        case .ignore:
            break
        }
    }
}

// MARK: - Error page

/// Decides what to do when a page's renderer dies: a few times in a short while is bad luck (memory pressure, a
/// one-off crash) and worth a reload; more than that is the page, which gets one error page, and then nothing more
/// until the burst is over (loading the error page can itself be reported as a death).
struct CrashLoopGuard {
    enum Decision: Equatable { case reload, showError, ignore }

    static let window: TimeInterval = 30
    static let allowed = 3
    private var recent: [Date] = []
    private var gaveUp = false

    mutating func decide(at now: Date) -> Decision {
        recent = recent.filter { now.timeIntervalSince($0) < Self.window }
        if recent.count < Self.allowed {
            recent.append(now)
            gaveUp = false
            return .reload
        }
        if gaveUp { return .ignore }
        gaveUp = true
        return .showError
    }
}

enum ErrorPage {
    static func html(for error: PageLoadError, url: URL) -> String {
        let (headline, detail): (String, String) = {
            switch error.kind {
            case .offline:
                return ("You're out of range", "Cosmos can't reach the internet. Check your connection and try again.")
            case .hostNotFound:
                return ("Lost in space", "We couldn't find a server at “\(url.host ?? url.absoluteString)”. Check the address for typos.")
            case .timedOut:
                return ("Signal lost", "The server took too long to answer.")
            case .crashed:
                return ("This page keeps crashing", "It stopped responding several times in a row, so Cosmos stopped reloading it. Try again in a moment.")
            case .connectionFailed:
                return ("Connection lost", "The server isn't accepting connections right now.")
            case .insecure:
                return ("This connection isn't private", "Cosmos couldn't verify the identity of “\(url.host ?? "this site")”. Someone may be trying to intercept your connection.")
            case .malware:
                return ("This site may harm your Mac", "“\(url.host ?? "This site")” is on a public list of sites that have spread malware (URLhaus). Cosmos stopped it before the page was asked for.")
            case .phishing:
                return ("Deceptive site ahead", "“\(url.host ?? "This site")” is on a public list of sites that pose as others to take passwords or card numbers. Cosmos stopped it before the page was asked for.")
            case .other:
                return ("This page can't be reached", "Something went wrong loading this page.")
            }
        }()
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(headline))</title><style>
        :root { color-scheme: dark light; }
        html, body { height: 100%; margin: 0; }
        body { display: grid; place-items: center; font: 15px/1.5 -apple-system, system-ui, sans-serif; color: #e8e8f4;
               background: radial-gradient(1200px 700px at 70% 10%, #2a1860 0%, #0d0b24 55%, #05040f 100%); }
        main { max-width: 440px; padding: 24px; text-align: center; }
        svg { width: 120px; height: 120px; margin-bottom: 8px; }
        h1 { font-size: 26px; margin: 8px 0 8px; font-weight: 650; letter-spacing: -0.01em; }
        p { opacity: 0.78; margin: 0 0 20px; }
        code { opacity: 0.55; font-size: 12px; display: block; margin-top: 22px; word-break: break-all; }
        @media (prefers-color-scheme: light) { body { color: #1d1b33; background: radial-gradient(1200px 700px at 70% 10%, #e6defc 0%, #f4f1fb 60%, #fff 100%); } }
        </style></head><body><main>
        <svg viewBox="0 0 120 120" fill="none"><circle cx="60" cy="60" r="26" fill="#8b6cff"/><ellipse cx="60" cy="60" rx="52" ry="14" transform="rotate(-20 60 60)" stroke="#c9bdff" stroke-width="3" opacity=".8"/>
        <circle cx="96" cy="34" r="4" fill="#fff"/><circle cx="22" cy="86" r="2.5" fill="#fff" opacity=".7"/><circle cx="104" cy="88" r="2" fill="#fff" opacity=".5"/></svg>
        <h1>\(esc(headline))</h1><p>\(esc(detail))</p>
        \(error.kind == .malware || error.kind == .phishing ? "" : "<p>Press ⌘R to try again.</p>")
        <code>\(esc(url.absoluteString))<br>\(esc(error.detail))</code></main></body></html>
        """
    }
}
