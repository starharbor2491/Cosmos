import Foundation
import Network
import Testing
import AppKit
import CosmosEngine
@testable import CosmosKit
@testable import CosmosCore
import CosmosImport

/// Stands in for Chromium, so the browser around the engine can be tested without starting one. Pages remember what
/// they were asked to do; a test makes them report what an engine would (`navigate`, `crash`, `open`).
@MainActor
final class FakeEngine: BrowserEngine {
    let name = "Fake"
    var status: EngineStatus = .ready(version: "1.0") { didSet { onStatusChange?() } }
    var onStatusChange: (() -> Void)?
    var versionDescription: String? = "1.0"
    private(set) var profiles: [FakeProfile] = []


    func makeProfile(id: UUID?, directory: URL?) -> EngineProfile {
        let profile = FakeProfile(id: id, directory: directory)
        profiles.append(profile)
        return profile
    }

    func shutdown(then done: @escaping () -> Void) { profiles.forEach { $0.close() }; done() }
}

@MainActor
final class FakeProfile: EngineProfile {
    let id: UUID?
    let directory: URL?
    weak var delegate: EngineProfileDelegate?
    var extensions: EngineExtensions?
    private(set) var scripts: [PageScript] = []
    /// The last `setContentBlocking`, nil before the first.
    private(set) var blocking: (lists: [CompiledBlockingList]?, allowlist: [String])?
    private(set) var permissionDecisions: [PermissionDecision] = []
    private(set) var pages: [FakePage] = []
    private(set) var restarts = 0
    private(set) var clearedSiteData = 0
    private(set) var clearedHistory: [Date?] = []
    private(set) var deletedHistory: [URL] = []
    private(set) var isClosed = false
    var processes: [Int32] = []

    init(id: UUID?, directory: URL?) {
        self.id = id
        self.directory = directory
        // Like Chromium, a profile that keeps nothing (incognito) runs no extensions.
        extensions = directory == nil && id == nil ? nil : FakeExtensions()
    }

    var fakeExtensions: FakeExtensions? { extensions as? FakeExtensions }

    func makePage() -> EnginePage {
        let page = FakePage()
        pages.append(page)
        return page
    }

    func setPageScripts(_ scripts: [PageScript]) { self.scripts = scripts }
    func setContentBlocking(_ lists: [CompiledBlockingList]?, allowlist: [String]) { blocking = (lists, allowlist) }
    func setPermissionDecisions(_ decisions: [PermissionDecision]) { permissionDecisions = decisions }
    func clearSiteData() async { clearedSiteData += 1 }
    func clearHistory(since date: Date?) async { clearedHistory.append(date) }
    func deleteHistory(of url: URL) async { deletedHistory.append(url) }
    var cookies: [EngineCookie] = []
    func setCookies(_ cookies: [EngineCookie]) async -> Int { self.cookies += cookies; return cookies.count }
    func processIDs() async -> [Int32] { processes }
    func restart() { restarts += 1; delegate?.profileDidRestart(self) }
    func close() { isClosed = true }

    /// What the engine does when a page (or, with no opener, an extension) opens one: it makes the page, then asks.
    @discardableResult
    func open(_ request: NewPageRequest, from opener: FakePage?) -> (page: FakePage, kept: Bool) {
        let page = makePage() as! FakePage
        let kept = delegate?.profile(self, didOpen: page, opener: opener, request: request) ?? false
        if !kept { page.close() }
        return (page, kept)
    }

    func startDownload(_ download: EngineDownload) { delegate?.profile(self, didStartDownload: download) }
}

@MainActor
final class FakePage: EnginePage {
    /// Takes the keyboard, as an engine's page view does.
    final class PageView: NSView { override var acceptsFirstResponder: Bool { true } }
    let view: NSView = PageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    weak var delegate: EnginePageDelegate?
    var state = PageState()
    private(set) var loads: [URL] = []
    private(set) var shownHTML: [(html: String, url: URL)] = []
    private(set) var reloads = 0
    private(set) var stops = 0
    private(set) var evaluated: [(script: String, world: ScriptWorld)] = []
    /// What `evaluate` answers for a script.
    var answer: (String) -> Any? = { _ in nil }
    var zoom = 1.0
    var userAgent: String?
    private(set) var commands: [EditCommand] = []
    private(set) var downloads: [URL] = []
    var contextClick: ContextClick?
    var isInElementFullscreen = false
    var reportedUsage: PageUsage?
    private(set) var activations = 0
    private(set) var isClosed = false

    func load(_ url: URL) { loads.append(url) }
    func loadHTML(_ html: String, showing url: URL) { shownHTML.append((html, url)) }
    func reload(fromOrigin: Bool) { reloads += 1 }
    func stop() { stops += 1 }
    func goBack() {}
    func goForward() {}
    func evaluate(_ script: String, in world: ScriptWorld) async -> Any? {
        evaluated.append((script, world))
        return answer(script)
    }
    func perform(_ command: EditCommand) { commands.append(command) }
    func snapshot(width: CGFloat) async -> NSImage? { nil }
    func pdf() async -> Data? { nil }
    func download(_ url: URL) { downloads.append(url) }
    func recentContextClick() -> ContextClick? { contextClick }
    func showInspector() -> Bool { false }
    var filled: [(username: String, password: String, origin: String)] = []
    func fillLogin(username: String, password: String, origin: String) async -> Bool { filled.append((username, password, origin)); return true }
    private(set) var leftPictureInPicture = 0
    func leavePictureInPicture() { leftPictureInPicture += 1 }
    private(set) var notificationActions: [(id: String, action: NotificationAction)] = []
    func notification(_ id: String, did action: NotificationAction) { notificationActions.append((id, action)) }
    func usage() async -> PageUsage? { reportedUsage }
    func activate() { activations += 1 }
    func close() { isClosed = true }

    /// What a finished navigation to `url` looks like to the page's delegate.
    func navigate(to url: URL, title: String = "") {
        state.isLoading = true
        delegate?.pageDidStartNavigation(self)
        state.url = url
        state.title = title
        delegate?.pageDidCommitNavigation(self)
        state.isLoading = false
        state.progress = 1
        delegate?.pageDidFinishLoading(self)
    }

    /// A message from the page agent, as `__cosmosPost` delivers it.
    func post(_ message: [String: Any], fromMainFrame: Bool = true) {
        delegate?.page(self, agentMessage: message, fromMainFrame: fromMainFrame)
    }

    func crash() { delegate?.pageRendererDidTerminate(self) }
}

/// The engine's side of extensions: loads remember their folder, and the buttons and menu items are whatever a test
/// sets.
@MainActor
final class FakeExtensions: EngineExtensions {
    var onChange: (() -> Void)?
    private(set) var loaded: [String: URL] = [:]
    private(set) var unloaded: [String] = []
    /// While set, every load fails with this reason.
    var refusal: String?
    /// How long a load or an unload takes, as Chromium's do, so a test can catch one half done.
    var delay: Duration = .zero
    /// Loads under way at once for one folder, at most: more than one is the same extension loaded twice.
    private(set) var mostAtOnce = 0
    private var underWay: [String: Int] = [:]
    var buttons: [ExtensionAction] = []
    var items: [ExtensionMenuItem] = []
    var commands: [ExtensionCommand] = []
    private(set) var performed: [String] = []
    private(set) var clicked: [(ExtensionMenuItem, ExtensionClickContext)] = []

    struct LoadError: LocalizedError { var errorDescription: String? }

    /// The id the engine gives the extension in `folder`: like Chromium's, the one its manifest's key makes, otherwise one
    /// that follows from the folder.
    static func id(for folder: URL) -> String {
        if let key = (ChromiumExtensionScanner.readManifest(folder)?["key"] as? String).flatMap({ Data(base64Encoded: $0) }) {
            return ChromeWebStore.extensionID(ofKey: key)
        }
        return "ext-" + folder.lastPathComponent
    }

    func load(folder: URL) async throws -> String {
        if let refusal { throw LoadError(errorDescription: refusal) }
        let id = Self.id(for: folder)
        underWay[id, default: 0] += 1
        mostAtOnce = max(mostAtOnce, underWay[id]!)
        defer { underWay[id]! -= 1 }
        if delay > .zero { try? await Task.sleep(for: delay) }
        loaded[id] = folder
        return id
    }
    func unload(id: String) async {
        if delay > .zero { try? await Task.sleep(for: delay) }
        loaded[id] = nil
        unloaded.append(id)
    }
    func actions(for page: EnginePage?) -> [ExtensionAction] { buttons.filter { loaded[$0.extensionID] != nil } }
    /// Its buttons open popups (a page each), as an extension with `default_popup` does.
    var opensPopups = false
    func performAction(_ extensionID: String, on page: EnginePage) async -> EnginePage? {
        performed.append(extensionID)
        return opensPopups ? FakePage() : nil
    }
    func menuItems(for page: EnginePage?) -> [ExtensionMenuItem] { items }
    func performMenuItem(_ item: ExtensionMenuItem, context: ExtensionClickContext, on page: EnginePage) async { clicked.append((item, context)) }
    func performCommand(_ command: ExtensionCommand, on page: EnginePage?) async -> EnginePage? { performed.append(command.name); return nil }
    var tabsHost: ExtensionTabsHost?
    private(set) var tabChanges = 0
    func tabsDidChange() { tabChanges += 1 }
    var onSidePanelRequest: ((String, EnginePage?) -> Void)?
    private(set) var sidePanelsOpened: [String] = []
    func openSidePanel(_ extensionID: String, for page: EnginePage?) async -> EnginePage? { sidePanelsOpened.append(extensionID); return FakePage() }
    var onNotification: ((String, EngineNotification) -> Void)?
    var onNotificationClosed: ((String, String) -> Void)?
    private(set) var notificationActions: [(id: String, extensionID: String, action: NotificationAction)] = []
    func notification(_ id: String, of extensionID: String, did action: NotificationAction) async { notificationActions.append((id, extensionID, action)) }
}

extension TabRuntime {
    /// The fake page under a runtime made by a store on a `FakeEngine`.
    var fake: FakePage { page as! FakePage }
}

extension BrowserStore {
    var fakeEngine: FakeEngine { engine as! FakeEngine }
}

/// Serves one fixed HTML page on 127.0.0.1 so a real http:// document can be loaded.
final class PageServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16

    init(html: String) async throws {
        let body = Data(html.utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let l = try NWListener(using: .tcp, on: .any)
        l.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        port = try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            nonisolated(unsafe) var resumed = false
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: if !resumed { resumed = true; c.resume(returning: l.port?.rawValue ?? 0) }
                case .failed(let e): if !resumed { resumed = true; c.resume(throwing: e) }
                default: break
                }
            }
            l.start(queue: .global())
        }
        listener = l
    }

    deinit { listener.cancel() }
}


/// Serves fixed responses by path on 127.0.0.1 and records every request line's path (query included), so a test can
/// check both what a client got and what it asked for.
/// Stands in for macOS's Notification Center: records what Cosmos posts, and lets a test click it.
@MainActor
final class FakeNotifier: Notifying {
    var shown: [(note: EngineNotification, key: String, onAction: (NotificationAction) -> Void)] = []
    var closed: [String] = []
    func show(_ note: EngineNotification, key: String, onAction: @escaping (NotificationAction) -> Void) { shown.append((note, key, onAction)) }
    func close(key: String) { closed.append(key) }
}

final class SiteServer: @unchecked Sendable {
    struct Route {
        var type: String
        var body: Data
        /// Seconds the server waits before answering, to be in the middle of a request when something else happens.
        var delay: TimeInterval = 0
        /// "user:password": without them in a Basic `Authorization` header the answer is 401 and a Basic challenge.
        var basicAuth: String? = nil
        /// More lines for the answer's head ("Set-Cookie: a=b").
        var headers: [String] = []
        /// The answer's status, when it is not "200 OK" ("302 Found", with a Location header).
        var status: String? = nil
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [(path: String, lines: [String])] = []
        func add(_ path: String, _ lines: [String]) { lock.lock(); asked.append((path, lines)); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return asked.map(\.path) }
        func lines(of path: String) -> [[String]] { lock.lock(); defer { lock.unlock() }; return asked.filter { $0.path == path }.map(\.lines) }
    }

    private let listener: NWListener
    private let recorder: Recorder
    let port: UInt16
    var requests: [String] { recorder.all }
    /// The head of each request for `path`, a line each.
    func requestHeads(of path: String) -> [[String]] { recorder.lines(of: path) }

    init(routes: [String: Route]) async throws {
        let recorder = Recorder()
        let l = try NWListener(using: .tcp, on: .any)
        l.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let lines = data.map { String(decoding: $0, as: UTF8.self).components(separatedBy: "\r\n") } ?? []
                let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                // A connection that sends nothing (Chromium connects ahead of a page it may load) asks for nothing.
                if !lines.isEmpty { recorder.add(path, lines) }
                let route = routes[path.components(separatedBy: "?").first ?? path]
                let credentials = route?.basicAuth.map { "authorization: basic " + Data($0.utf8).base64EncodedString().lowercased() }
                let refused = credentials.map { c in !lines.contains { $0.lowercased() == c } } ?? false
                let body = refused ? Data("<body>sign in</body>".utf8) : route?.body ?? Data()
                let status = route == nil ? "404 Not Found" : refused ? "401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"Cosmos test\"" : route?.status ?? "200 OK"
                let extra = (route?.headers ?? []).map { $0 + "\r\n" }.joined()
                let head = "HTTP/1.1 \(status)\r\nContent-Type: \(refused ? "text/html" : route?.type ?? "text/plain")\r\nContent-Length: \(body.count)\r\n\(extra)Connection: close\r\n\r\n"
                let send = { connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() }) }
                if let delay = route?.delay, delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: send) } else { send() }
            }
        }
        port = try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            nonisolated(unsafe) var resumed = false
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: if !resumed { resumed = true; c.resume(returning: l.port?.rawValue ?? 0) }
                case .failed(let e): if !resumed { resumed = true; c.resume(throwing: e) }
                default: break
                }
            }
            l.start(queue: .global())
        }
        listener = l
        self.recorder = recorder
    }

    deinit { listener.cancel() }
}
