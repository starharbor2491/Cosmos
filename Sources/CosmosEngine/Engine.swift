import AppKit
import CosmosCore

// What Cosmos needs from the thing that draws web pages. The browser (CosmosKit) only talks to these protocols, so the
// engine underneath can change without the sidebar, Command Bar, Boosts or settings knowing. Chromium (CosmosChromium) is
// the engine today.

/// Where the engine itself is: Chromium has to start before the first page can show.
public enum EngineStatus: Equatable, Sendable {
    /// Getting ready: what is happening, and how far along when that is known (0...1).
    case preparing(String, progress: Double?)
    case ready(version: String)
    case failed(String)

    public var isReady: Bool { if case .ready = self { return true } else { return false } }
}

@MainActor
public protocol BrowserEngine: AnyObject {
    /// "Chromium".
    var name: String { get }
    var status: EngineStatus { get }
    /// Called on the main actor whenever `status` changes.
    var onStatusChange: (() -> Void)? { get set }
    /// The version that runs ("156.0.8078.48"), once it runs.
    var versionDescription: String? { get }
    /// The engine side of one browsing profile: its own cookies, storage, extensions and blocking. `directory` nil keeps
    /// nothing once the profile is closed (incognito).
    func makeProfile(id: UUID?, directory: URL?) -> EngineProfile
    /// Stops every profile (the app is quitting), then runs `done`, once the engine has written what it had not yet.
    func shutdown(then done: @escaping () -> Void)
}

/// Which JavaScript world a script runs in. `.agent` is Cosmos's own: pages cannot see it or call into it, and it is
/// the only world that can reach `__cosmosPost(json)`, which delivers a message to `EnginePageDelegate`.
public enum ScriptWorld: Sendable { case page, agent }

/// A script every page of a profile gets.
public struct PageScript: Equatable, Sendable {
    public enum Time: Sendable { case documentStart, documentEnd }
    public var source: String
    public var world: ScriptWorld
    public var time: Time
    public init(source: String, world: ScriptWorld, time: Time) {
        self.source = source; self.world = world; self.time = time
    }
}

@MainActor
public protocol EngineProfile: AnyObject {
    var delegate: EngineProfileDelegate? { get set }
    /// A new, empty page (about:blank) for this profile.
    func makePage() -> EnginePage
    /// Replaces the scripts every page gets. Pages loaded from now on run them; open pages keep theirs until reloaded.
    func setPageScripts(_ scripts: [PageScript])
    /// Content blocking: the compiled lists (see `CosmosBlocking`), and hosts where blocking is off. `nil` turns it off.
    func setContentBlocking(_ lists: [CompiledBlockingList]?, allowlist: [String])
    /// What the user decided, site by site. Replaces the previous set; what is no longer in it is asked about again.
    func setPermissionDecisions(_ decisions: [PermissionDecision])
    /// The profile's extensions, if the engine runs them.
    var extensions: EngineExtensions? { get }
    /// Forgets cookies, site storage and the page cache.
    func clearSiteData() async
    /// Forgets the engine's own history of the pages visited since `date` (all of it for nil).
    func clearHistory(since date: Date?) async
    /// Forgets the engine's own history of a page, with or without a fragment.
    func deleteHistory(of url: URL) async
    /// The engine's own processes for this profile, for the Resources view.
    func processIDs() async -> [Int32]
    /// Stops the profile's engine and starts it again with the current settings; its pages come back through
    /// `EngineProfileDelegate.profileDidRestart`.
    func restart()
    /// Ends the profile and everything in it.
    func close()
}

/// A compiled filter list in the engine's own format, as `CosmosBlocking` makes it.
public struct CompiledBlockingList: Equatable, Sendable {
    public enum Kind: String, Sendable { case network, cosmetic }
    public var name: String
    public var json: String
    public var kind: Kind
    public var digest: String
    public init(name: String, json: String, kind: Kind, digest: String) {
        self.name = name; self.json = json; self.kind = kind; self.digest = digest
    }
}

/// How a page opened by another page (or by an extension) asked to be shown.
public struct NewPageRequest: Equatable, Sendable {
    public var url: URL?
    /// `window.open` features (`width=400`, ...): a script-sized popup has its own small window.
    public var features: [String]
    public var userGesture: Bool
    /// Made by an extension rather than by a page.
    public var fromExtension: Bool
    public init(url: URL?, features: [String] = [], userGesture: Bool = false, fromExtension: Bool = false) {
        self.url = url; self.features = features; self.userGesture = userGesture; self.fromExtension = fromExtension
    }
    /// A page that asked for a window of a given size needs its opener (an OAuth sign-in, a payment sheet).
    public var isScriptSizedPopup: Bool { features.contains { $0.hasPrefix("width=") || $0.hasPrefix("height=") } }
}

@MainActor
public protocol EngineProfileDelegate: AnyObject {
    /// A page the engine opened on its own: a link or script that wanted a new window, or an extension's new tab. Return
    /// false to close it.
    func profile(_ profile: EngineProfile, didOpen page: EnginePage, opener: EnginePage?, request: NewPageRequest) -> Bool
    func profile(_ profile: EngineProfile, didStartDownload download: EngineDownload)
    /// The engine stopped and came back: every page of the profile is gone and has to be made again.
    func profileDidRestart(_ profile: EngineProfile)
}

/// What a page is doing, as the address pill and sidebar show it.
public struct PageState: Equatable, Sendable {
    public var url: URL?
    public var title = ""
    public var isLoading = false
    public var progress = 0.0
    public var canGoBack = false
    public var canGoForward = false
    /// Camera or microphone in use.
    public var isCapturing = false
    public init() {}
}

/// A load that did not get to show its page.
public struct PageLoadError: Error, Equatable, Sendable {
    /// `malware` and `phishing`: Cosmos stopped the page itself (`EnginePageDelegate.page(_:dangerAt:)`).
    public enum Kind: Equatable, Sendable { case offline, hostNotFound, timedOut, connectionFailed, insecure, crashed, malware, phishing, other }
    public var kind: Kind
    /// The engine's own words (`net::ERR_NAME_NOT_RESOLVED`).
    public var detail: String
    public init(kind: Kind, detail: String) { self.kind = kind; self.detail = detail }
}

/// A JavaScript `alert`, `confirm` or `prompt`.
public struct PageDialog: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case alert, confirm, prompt(default: String), beforeUnload }
    public var kind: Kind
    public var message: String
    /// The site that asked.
    public var origin: String
    public init(kind: Kind, message: String, origin: String) { self.kind = kind; self.message = message; self.origin = origin }
    public struct Answer: Equatable, Sendable {
        public var accepted: Bool
        public var text: String?
        public init(accepted: Bool, text: String? = nil) { self.accepted = accepted; self.text = text }
    }
}

public struct FileChooser: Equatable, Sendable {
    public var allowsMultiple: Bool
    public var allowsDirectories: Bool
    public init(allowsMultiple: Bool, allowsDirectories: Bool) { self.allowsMultiple = allowsMultiple; self.allowsDirectories = allowsDirectories }
}

/// A site asking for something the user has to allow.
public struct PermissionRequest: Equatable, Sendable {
    public enum Kind: String, Hashable, Sendable { case camera, microphone, cameraAndMicrophone, location, notifications }
    public var kind: Kind
    /// The host that asked (`meet.example.com`).
    public var host: String
    public init(kind: Kind, host: String) { self.kind = kind; self.host = host }
}

/// A notification a site or an extension wants shown. The engine has nowhere to show it: Cosmos posts it to macOS.
public struct EngineNotification: Equatable, Sendable {
    /// Unique within its page or extension; a site's tag, when it gave one, so a new one replaces the old.
    public var id: String
    public var title: String
    public var body: String
    /// Who it is from, as macOS shows it: the site's host, or the extension's name.
    public var source: String
    /// The image to show with it (PNG or JPEG), when there is one.
    public var icon: Data?
    /// Button titles (an extension's `buttons`).
    public var buttons: [String]
    public init(id: String, title: String, body: String, source: String, icon: Data? = nil, buttons: [String] = []) {
        self.id = id; self.title = title; self.body = body; self.source = source; self.icon = icon; self.buttons = buttons
    }
}

/// Why a site is dangerous, as the lists Cosmos warns from say.
public enum PageDanger: String, Equatable, Sendable { case malware, phishing }

/// What the user did with a notification.
public enum NotificationAction: Equatable, Sendable { case clicked, button(Int), closed }

/// A site (or a proxy) asking for a user name and password: HTTP authentication.
public struct AuthChallenge: Equatable, Sendable {
    public var host: String
    /// What the site calls the place ("Staff only"): the server's words, not Cosmos's.
    public var realm: String
    public var isProxy: Bool
    /// False when the password would cross the network unencrypted.
    public var isSecure: Bool
    public init(host: String, realm: String, isProxy: Bool, isSecure: Bool) {
        self.host = host; self.realm = realm; self.isProxy = isProxy; self.isSecure = isSecure
    }
}

public struct PageCredentials: Equatable, Sendable {
    public var user: String
    public var password: String
    public init(user: String, password: String) { self.user = user; self.password = password }
}

/// What the user decided about one site and one kind of permission. The engine applies it to the site's pages, so a site
/// that was allowed is allowed before it asks.
public struct PermissionDecision: Hashable, Sendable {
    public var host: String
    public var kind: PermissionRequest.Kind
    public var allowed: Bool
    public init(host: String, kind: PermissionRequest.Kind, allowed: Bool) { self.host = host; self.kind = kind; self.allowed = allowed }
}

/// Where the Mac is, for a site the user let know: the engine gets it from Cosmos and never asks the system itself.
public struct PageLocation: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// Metres.
    public var accuracy: Double
    public init(latitude: Double, longitude: Double, accuracy: Double) {
        self.latitude = latitude; self.longitude = longitude; self.accuracy = accuracy
    }
}

public enum EditCommand: String, Sendable, CaseIterable { case copy, cut, paste, selectAll, undo, redo }

@MainActor
public protocol EnginePage: AnyObject {
    /// The view that shows the page and takes its mouse and keyboard input.
    var view: NSView { get }
    var delegate: EnginePageDelegate? { get set }
    var state: PageState { get }
    func load(_ url: URL)
    /// Shows `html` as the page, keeping `url` in the address bar (Cosmos's own error pages).
    func loadHTML(_ html: String, showing url: URL)
    func reload(fromOrigin: Bool)
    func stop()
    func goBack()
    func goForward()
    /// Page zoom, 1 = 100%.
    var zoom: Double { get set }
    /// `nil` for the engine's own.
    var userAgent: String? { get set }
    /// Runs the expression `script` (awaiting it when it is a promise) and returns its JSON-compatible result.
    func evaluate(_ script: String, in world: ScriptWorld) async -> Any?
    func perform(_ command: EditCommand)
    /// A picture of what the page shows now, `width` points wide.
    func snapshot(width: CGFloat) async -> NSImage?
    /// The page laid out for paper.
    func pdf() async -> Data?
    /// Downloads `url` with the page's cookies.
    func download(_ url: URL)
    /// True when the engine draws the page itself fullscreen (a video in element fullscreen).
    var isInElementFullscreen: Bool { get }
    /// The last right (or control) click on the page, if it was recent enough to be the one a context menu is for.
    func recentContextClick() -> ContextClick?
    /// Shows the engine's inspector, when it has one Cosmos can show.
    func showInspector() -> Bool
    /// Takes the video in Picture in Picture back into the page.
    func leavePictureInPicture()
    /// The user clicked or closed one of the page's notifications: its own events fire.
    func notification(_ id: String, did action: NotificationAction)
    /// What the page costs: JavaScript memory and processor time so far (seconds).
    func usage() async -> PageUsage?
    /// This is the page in front: the engine's own idea of the active tab (which extensions see) follows Cosmos's.
    func activate()
    /// The page goes away for good.
    func close()
}

public struct PageUsage: Equatable, Sendable {
    public var memory: UInt64
    public var cpuSeconds: Double
    public init(memory: UInt64, cpuSeconds: Double) { self.memory = memory; self.cpuSeconds = cpuSeconds }
}

/// A click that asks for a context menu, as the click itself said it: where it was in the window and which modifier keys
/// were down. The page's own report of it comes a moment later.
public struct ContextClick: Equatable, Sendable {
    public var location: NSPoint
    public var modifiers: NSEvent.ModifierFlags
    public var uptime: TimeInterval
    public init(location: NSPoint, modifiers: NSEvent.ModifierFlags, uptime: TimeInterval) {
        self.location = location; self.modifiers = modifiers; self.uptime = uptime
    }
}

@MainActor
public protocol EnginePageDelegate: AnyObject {
    func pageStateDidChange(_ page: EnginePage)
    /// A new document is on its way: anything made from the old one is out of date.
    func pageDidStartNavigation(_ page: EnginePage)
    /// The new document is showing.
    func pageDidCommitNavigation(_ page: EnginePage)
    func pageDidFinishLoading(_ page: EnginePage)
    func page(_ page: EnginePage, didFailLoading url: URL, error: PageLoadError)
    /// A message the agent world sent with `__cosmosPost(json)`.
    func page(_ page: EnginePage, agentMessage: [String: Any], fromMainFrame: Bool)
    func page(_ page: EnginePage, runDialog dialog: PageDialog) async -> PageDialog.Answer
    func page(_ page: EnginePage, chooseFiles chooser: FileChooser) async -> [URL]?
    func page(_ page: EnginePage, wantsPermission request: PermissionRequest) async -> Bool
    /// Asked before every page and frame loads: a reason makes the engine stop it before anything is sent to the site. A
    /// page that is stopped fails with `PageLoadError.Kind.malware` or `.phishing`; a frame is left out quietly.
    func page(_ page: EnginePage, dangerAt url: URL) -> PageDanger?
    /// A site wants a user name and password; nil cancels, and the page shows what the site sends instead.
    func page(_ page: EnginePage, wantsCredentialsFor challenge: AuthChallenge) async -> PageCredentials?
    /// The page wants a notification shown (it has permission: the engine checked).
    func page(_ page: EnginePage, showNotification note: EngineNotification)
    /// The page took a notification back (`notification.close()`).
    func page(_ page: EnginePage, closeNotification id: String)
    /// A video asked for Picture in Picture; `view` shows it. True when the view was put in a window of its own.
    func page(_ page: EnginePage, wantsPictureInPicture view: NSView) async -> Bool
    /// The video left Picture in Picture (the page ended it, the video went, or `leavePictureInPicture` was called).
    func pageDidLeavePictureInPicture(_ page: EnginePage)
    /// A site that was allowed the location wants it now; nil when it cannot be had.
    func pageWantsLocation(_ page: EnginePage) async -> PageLocation?
    /// A Force Click (a deep press on the trackpad) on the page. The click itself still reaches the page.
    func pageDidForceClick(_ page: EnginePage)
    /// The page asked to be closed (`window.close()`).
    func pageRequestsClose(_ page: EnginePage)
    /// The process drawing the page died.
    func pageRendererDidTerminate(_ page: EnginePage)
}

/// One file coming down, as the engine reports it.
@MainActor
public final class EngineDownload {
    public enum State: Equatable { case running, finished(URL), failed(String), cancelled }
    public let url: URL?
    public let suggestedFilename: String
    public private(set) var state: State = .running
    public private(set) var receivedBytes: Int64 = 0
    public private(set) var totalBytes: Int64 = 0
    /// Called after every change.
    public var onChange: ((EngineDownload) -> Void)?
    private let cancelAction: () -> Void

    public init(url: URL?, suggestedFilename: String, cancel: @escaping () -> Void) {
        self.url = url
        self.suggestedFilename = suggestedFilename
        cancelAction = cancel
    }

    public var fraction: Double { totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0 }

    public func cancel() {
        guard state == .running else { return }
        cancelAction()
        update(state: .cancelled)
    }

    /// For the engine: report progress or the end.
    public func update(received: Int64? = nil, total: Int64? = nil, state newState: State? = nil) {
        if state != .running { return }
        if let received { receivedBytes = received }
        if let total { totalBytes = total }
        if let newState { state = newState }
        onChange?(self)
    }
}

/// An extension's button, as Cosmos draws it next to the address.
public struct ExtensionAction: Equatable, Sendable, Identifiable {
    public var extensionID: String
    public var title: String
    public var icon: Data?
    public var badgeText: String
    public var badgeColor: RGBA?
    public var isEnabled: Bool
    public var hasPopup: Bool
    public var id: String { extensionID }
    public init(extensionID: String, title: String, icon: Data? = nil, badgeText: String = "", badgeColor: RGBA? = nil, isEnabled: Bool = true, hasPopup: Bool = false) {
        self.extensionID = extensionID; self.title = title; self.icon = icon; self.badgeText = badgeText
        self.badgeColor = badgeColor; self.isEnabled = isEnabled; self.hasPopup = hasPopup
    }
}

/// An item an extension added to the right-click menu (`chrome.contextMenus`).
public struct ExtensionMenuItem: Equatable, Sendable, Identifiable {
    public var extensionID: String
    public var itemID: String
    public var title: String
    /// `page`, `link`, `image`, `selection`, `editable`, `all`, ...
    public var contexts: [String]
    public var parentID: String?
    public var id: String { extensionID + "/" + itemID }
    public init(extensionID: String, itemID: String, title: String, contexts: [String], parentID: String? = nil) {
        self.extensionID = extensionID; self.itemID = itemID; self.title = title; self.contexts = contexts; self.parentID = parentID
    }
}

/// A keyboard shortcut an extension declared (`commands` in its manifest).
public struct ExtensionCommand: Equatable, Sendable {
    public var extensionID: String
    public var name: String
    public var shortcut: String
    public var description: String
    public init(extensionID: String, name: String, shortcut: String, description: String) {
        self.extensionID = extensionID; self.name = name; self.shortcut = shortcut; self.description = description
    }
}

/// What a right click was on, for an extension's menu item.
public struct ExtensionClickContext: Equatable, Sendable {
    public var pageURL: URL?
    public var linkURL: URL?
    public var srcURL: URL?
    public var selectionText: String?
    public var editable: Bool
    public init(pageURL: URL?, linkURL: URL? = nil, srcURL: URL? = nil, selectionText: String? = nil, editable: Bool = false) {
        self.pageURL = pageURL; self.linkURL = linkURL; self.srcURL = srcURL; self.selectionText = selectionText; self.editable = editable
    }
}

/// One of Cosmos's tabs as extensions see it (`chrome.tabs`): its page, the window it is in and its place there.
public struct ExtensionTab {
    public var page: EnginePage
    /// Cosmos's number for the window, the same while it is open.
    public var windowID: Int
    public var index: Int
    /// The tab its window shows.
    public var isActive: Bool
    public var isPinned: Bool
    public init(page: EnginePage, windowID: Int, index: Int, isActive: Bool, isPinned: Bool) {
        self.page = page; self.windowID = windowID; self.index = index; self.isActive = isActive; self.isPinned = isPinned
    }
}

public struct ExtensionWindow: Equatable {
    public var id: Int
    public var isFocused: Bool
    public var frame: CGRect
    public init(id: Int, isFocused: Bool, frame: CGRect) { self.id = id; self.isFocused = isFocused; self.frame = frame }
}

/// Cosmos's tabs and windows, for what extensions ask of them (`chrome.tabs`, `chrome.windows`): Cosmos keeps the tabs,
/// the engine only their pages.
@MainActor
public protocol ExtensionTabsHost: AnyObject {
    /// The profile's tabs that have a page, window by window, in the order the sidebar shows them.
    var extensionTabs: [ExtensionTab] { get }
    var extensionWindows: [ExtensionWindow] { get }
    /// A new tab on `url` in window `windowID` (nil: the focused one), brought forward with `active`; its page.
    func openExtensionTab(_ url: URL, windowID: Int?, active: Bool) -> EnginePage?
    func activateExtensionTab(_ page: EnginePage)
    func closeExtensionTab(_ page: EnginePage)
    /// A window of its own on `url`, small (of `size`) for a popup; its page.
    func openExtensionWindow(_ url: URL, popup: Bool, size: CGSize?) -> EnginePage?
}

/// The browser-UI side of the extension APIs. Extensions run inside the engine with its own `chrome.*` APIs; what the
/// engine would normally draw (the toolbar button and its popup, menu items, shortcuts) Cosmos draws through this.
@MainActor
public protocol EngineExtensions: AnyObject {
    /// Called whenever an action, menu or the set of extensions changes.
    var onChange: (() -> Void)? { get set }
    /// Where `chrome.tabs` and `chrome.windows` look; nil: extensions see no tabs.
    var tabsHost: ExtensionTabsHost? { get set }
    /// Cosmos's tabs changed (one opened, closed, moved or came forward): the extensions hear of it.
    func tabsDidChange()
    /// An extension wants a notification shown (`chrome.notifications.create`), or took one back.
    var onNotification: ((_ extensionID: String, EngineNotification) -> Void)? { get set }
    var onNotificationClosed: ((_ extensionID: String, _ id: String) -> Void)? { get set }
    /// The user clicked or closed an extension's notification: its `chrome.notifications` events fire.
    func notification(_ id: String, of extensionID: String, did action: NotificationAction) async
    /// An extension wants its side panel opened (`sidePanel.open`, or its button when `setPanelBehavior` says so), for
    /// the tab of `page` (nil: the window's current tab).
    var onSidePanelRequest: ((_ extensionID: String, _ page: EnginePage?) -> Void)? { get set }
    /// The extension's side panel page for that tab, to show beside it; nil when it has none there.
    func openSidePanel(_ extensionID: String, for page: EnginePage?) async -> EnginePage?
    /// Loads an unpacked extension folder. Returns its id.
    func load(folder: URL) async throws -> String
    func unload(id: String) async
    func actions(for page: EnginePage?) -> [ExtensionAction]
    /// The user clicked an extension's button over `page`. Returns the popup's page, if the extension has one.
    func performAction(_ extensionID: String, on page: EnginePage) async -> EnginePage?
    func menuItems(for page: EnginePage?) -> [ExtensionMenuItem]
    func performMenuItem(_ item: ExtensionMenuItem, context: ExtensionClickContext, on page: EnginePage) async
    var commands: [ExtensionCommand] { get }
    /// Runs an extension's shortcut over `page`. Returns the popup's page when the shortcut opens the extension's popup.
    @discardableResult
    func performCommand(_ command: ExtensionCommand, on page: EnginePage?) async -> EnginePage?
}
