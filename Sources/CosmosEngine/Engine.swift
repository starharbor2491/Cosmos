import AppKit
import CosmosCore

// What Cosmos needs from the thing that draws web pages. The browser (CosmosKit) only talks to these protocols, so the
// engine underneath can change without the sidebar, Command Bar, Boosts or settings knowing. Chromium (CosmosChromium) is
// the engine today.

/// Where the engine itself is: Chromium has to be downloaded before the first page can show.
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
    /// The version that runs ("159.0.8129.0"), with the build it came from when that is known.
    var versionDescription: String? { get }
    /// When the engine last looked for a newer version, and what went wrong if it could not.
    var lastUpdateCheck: Date? { get }
    var lastUpdateError: String? { get }
    /// A newer version that is ready and runs from the next launch.
    var pendingUpdate: String? { get }
    /// Looks for a newer version now. A new one is used from the next launch.
    func checkForUpdates() async
    /// The engine side of one browsing profile: its own cookies, storage, extensions and blocking. `directory` nil keeps
    /// nothing once the profile is closed (incognito).
    func makeProfile(id: UUID?, directory: URL?) -> EngineProfile
    /// Stops every profile (the app is quitting).
    func shutdown()
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
    /// The profile's extensions, if the engine runs them.
    var extensions: EngineExtensions? { get }
    /// Forgets cookies, site storage and the page cache.
    func clearSiteData() async
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
    public enum Kind: Equatable, Sendable { case offline, hostNotFound, timedOut, connectionFailed, insecure, crashed, other }
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
    public enum Kind: String, Sendable { case camera, microphone, cameraAndMicrophone, location, notifications }
    public var kind: Kind
    /// The host that asked (`meet.example.com`).
    public var host: String
    public init(kind: Kind, host: String) { self.kind = kind; self.host = host }
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

/// The browser-UI side of the extension APIs. Extensions run inside the engine with its own `chrome.*` APIs; what the
/// engine would normally draw (the toolbar button and its popup, menu items, shortcuts) Cosmos draws through this.
@MainActor
public protocol EngineExtensions: AnyObject {
    /// Called whenever an action, menu or the set of extensions changes.
    var onChange: (() -> Void)? { get set }
    /// Loads an unpacked extension folder. Returns its id.
    func load(folder: URL) async throws -> String
    func unload(id: String) async
    func actions(for page: EnginePage?) -> [ExtensionAction]
    /// The user clicked an extension's button over `page`. Returns the popup's page, if the extension has one.
    func performAction(_ extensionID: String, on page: EnginePage) async -> EnginePage?
    func menuItems(for page: EnginePage?) -> [ExtensionMenuItem]
    func performMenuItem(_ item: ExtensionMenuItem, context: ExtensionClickContext, on page: EnginePage) async
    var commands: [ExtensionCommand] { get }
    func performCommand(_ command: ExtensionCommand, on page: EnginePage?) async
}
