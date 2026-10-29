import AppKit
import CosmosCEF
import CosmosCore

/// Chromium, through CEF, in Cosmos's own process: started once and shared by every profile. Everything Cosmos asks of
/// it goes over one DevTools connection (the pipe `CosmosCEFReservePipe` sets up), and what comes back is sent on from
/// here: a session's events to whoever routed it, a new target to the profile it belongs to.
@MainActor
final class ChromiumRuntime {
    /// Where CEF and its helper apps are, where profiles keep their data, and Chromium's switches.
    struct Configuration {
        /// The app the helper apps are inside; nil for this process's own bundle (Cosmos.app).
        var mainBundle: URL?
        var framework: URL
        var helper: URL
        /// Every profile's data is in a folder directly inside this one (Chromium opens no other), next to its `Local State`.
        var root: URL
        /// The profile CEF starts with, the only one extensions run in, and where its data is (directly inside `root`).
        var defaultProfileID: UUID
        var defaultCache: URL
        var switches: [String]
        /// Chromium's helpers run in its sandbox, which only works when this process is the app they are in (not a test).
        var sandboxed = true

        /// Inside Cosmos.app: the framework and helpers in Contents/Frameworks.
        static func app(root: URL, defaultProfileID: UUID, defaultProfile: URL, switches: [String] = []) -> Configuration? {
            guard let frameworks = Bundle.main.privateFrameworksURL else { return nil }
            let framework = frameworks.appendingPathComponent("Chromium Embedded Framework.framework", isDirectory: true)
            guard FileManager.default.fileExists(atPath: framework.path) else { return nil }
            return Configuration(mainBundle: nil, framework: framework,
                                 helper: frameworks.appendingPathComponent("Cosmos Helper.app/Contents/MacOS/Cosmos Helper"),
                                 root: root, defaultProfileID: defaultProfileID, defaultCache: defaultProfile,
                                 switches: switches)
        }
    }

    static let shared = ChromiumRuntime()
    /// How `start` starts CEF. The app and the tests set it before the first profile needs Chromium.
    static var configuration: Configuration?

    /// Nil while CEF runs; why it does not, once it was tried.
    private(set) var failure: String?
    private(set) var isRunning = false
    private var starting: Task<Bool, Never>?
    private(set) lazy var connection: CDPConnection = {
        let c = CDPConnection(readFrom: FileHandle(fileDescriptor: CosmosCEFAnswerDescriptor()),
                              writeTo: FileHandle(fileDescriptor: CosmosCEFCommandDescriptor()))
        c.onEvent = { [weak self] event in self?.handle(event) }
        return c
    }()

    var root: URL? { Self.configuration?.root }
    /// Where the default profile's data is: CEF's global context.
    var defaultCache: URL? { Self.configuration?.defaultCache }
    var chromiumVersion: String { CosmosCEFRuntime.chromiumVersion }


    private struct Weak { weak var profile: ChromiumProfile? }
    /// Where each session's events go: a page, a frame of one, an extension's worker.
    private var routes: [String: (CDPEvent) -> Void] = [:]
    private var profilesByTarget: [String: Weak] = [:]
    /// Weak both ways: a browser that has gone is not mistaken for a new one made where it was.
    private let owners = NSMapTable<CosmosCEFBrowser, ChromiumProfile>(keyOptions: .weakMemory, valueOptions: .weakMemory)
    private var downloads: [ObjectIdentifier: Weak] = [:]
    /// Pages waiting for the browser CEF made for their target (a popup), which says which target it is a moment later.
    private var browserWaiters: [String: [(CosmosCEFBrowser) -> Void]] = [:]
    /// Targets Cosmos has a session with, or is attaching to.
    private var attachedTargets: Set<String> = []
    /// The profile CEF starts with, which is Cosmos's default one: extensions and their workers are its.
    weak var defaultProfile: ChromiumProfile?

    private init() {}

    /// Starts CEF and Cosmos's session with it, once, with `settings` (those that only apply as Chromium starts). False
    /// (with `failure`) when it cannot run.
    func start(settings: EngineSettings) async -> Bool {
        if isRunning { return true }
        if failure != nil { return false }
        if let starting { return await starting.value }
        let task = Task { await launch(settings: settings) }
        starting = task
        let ok = await task.value
        starting = nil
        return ok
    }

    private func launch(settings: EngineSettings) async -> Bool {
        guard let configuration = Self.configuration else { failure = "Cosmos has no Chromium to run"; return false }
        let defaultCache = configuration.defaultCache
        try? FileManager.default.createDirectory(at: defaultCache, withIntermediateDirectories: true)
        // What Chromium reads only as it starts: the whole browser's settings and the default profile's.
        ChromiumPreferences.prepare(profile: defaultCache, root: configuration.root, settings: settings, keepsHistory: true)
        // The DevTools pipe would tell every page it is automated (`navigator.webdriver`), which sites such as Google's
        // sign-in turn away.
        let switches = ["--disable-blink-features=AutomationControlled"] + configuration.switches + ChromiumPreferences.flags(settings: settings)
        guard CosmosCEFRuntime.start(withMainBundle: configuration.mainBundle?.path, framework: configuration.framework.path,
                                     helper: configuration.helper.path, rootCache: configuration.root.path, globalCache: defaultCache.path,
                                     switches: switches, sandboxed: configuration.sandboxed) else {
            failure = CosmosCEFRuntime.lastError ?? "Chromium did not start"
            return false
        }
        await withCheckedContinuation { c in CosmosCEFRuntime.whenReady { c.resume() } }
        CosmosCEFBrowser.targetKnown = { [weak self] browser in self?.browserKnown(browser) }
        CosmosCEFBrowser.downloadStarted = { [weak self] browser, download in self?.downloadStarted(download, in: browser) }
        CosmosCEFBrowser.downloadUpdated = { [weak self] download in self?.downloadUpdated(download) }
        CosmosCEFBrowser.navigation = { [weak self] browser, address, isMainFrame in
            guard let self, let url = URL(string: address) ?? URL(string: address, encodingInvalidCharacters: true) else { return true }
            if let page = self.page(of: browser) { return page.allowsNavigation(to: url, mainFrame: isMainFrame) }
            // A popup's first page, before Cosmos has it: judged as its opener's would be.
            guard let opener = self.openerPage(of: browser) else { return true }
            return opener.delegate?.page(opener, dangerAt: url) == nil
        }
        CosmosCEFBrowser.dialog = { [weak self] browser, kind, message, text, origin, answer in
            guard let page = self?.page(of: browser) else { answer(false, nil); return }
            page.runDialog(kind, message: message, defaultText: text, origin: origin, answer: answer)
        }
        let c = connection
        c.start()
        do {
            // Cosmos is told of every target and attaches to its own: its pages as their browsers say which they are, and
            // extensions' workers as they start. Chromium could attach them itself (`Target.setAutoAttach`), but with
            // that on, a page's `window.open` never returns.
            _ = try await c.send("Target.setDiscoverTargets", ["discover": true])
        } catch {
            failure = "Chromium did not answer: \(error)"
            return false
        }
        isRunning = true
        return true
    }

    // MARK: Who is whose

    /// `browser` is a page of `profile`'s: its target, downloads and dialogs go to that profile.
    func own(_ browser: CosmosCEFBrowser, for profile: ChromiumProfile) {
        owners.setObject(profile, forKey: browser)
    }

    /// The profile of a browser: the one it was made for, or for a popup Cosmos has not taken yet, its opener's.
    private func profile(of browser: CosmosCEFBrowser) -> ChromiumProfile? {
        var next: CosmosCEFBrowser? = browser
        while let b = next {
            if let owner = owners.object(forKey: b) { return owner }
            next = b.opener
        }
        return nil
    }

    private func page(of browser: CosmosCEFBrowser) -> ChromiumPage? { profile(of: browser)?.page(of: browser) }

    /// The page that opened a popup, or the one that opened that.
    private func openerPage(of browser: CosmosCEFBrowser) -> ChromiumPage? {
        var next = browser.opener
        while let b = next {
            if let page = page(of: b) { return page }
            next = b.opener
        }
        return nil
    }

    /// What Chromium says about the target `id` goes to `profile`.
    func register(target id: String, for profile: ChromiumProfile) {
        profilesByTarget[id] = Weak(profile: profile)
    }

    func forget(target id: String) {
        profilesByTarget[id] = nil
        browserWaiters[id] = nil
        attachedTargets.remove(id)
    }

    func route(_ session: String, to handler: @escaping (CDPEvent) -> Void) { routes[session] = handler }
    func unroute(_ session: String) { routes[session] = nil }

    /// `work` gets the browser CEF made for `target` once it says which target it is (at once if it has).
    func whenBrowser(forTarget target: String, _ work: @escaping (CosmosCEFBrowser) -> Void) {
        if let browser = CosmosCEFBrowser.browser(forTarget: target) { work(browser) } else { browserWaiters[target, default: []].append(work) }
    }

    // MARK: Events

    private func handle(_ event: CDPEvent) {
        if let session = event.sessionID {
            routes[session]?(event)
            return
        }
        let p = event.params
        switch event.method {
        case "Target.targetCreated":
            // An extension's worker, as it starts: the default profile's extension host takes it.
            guard let info = p["targetInfo"] as? [String: Any], info["type"] as? String == "service_worker",
                  (info["url"] as? String)?.hasPrefix("chrome-extension://") == true, let target = info["targetId"] as? String else { return }
            attach(target) { [weak self] session, info in
                guard let profile = self?.defaultProfile ?? self?.anyProfile else { self?.release(session); return }
                profile.attached(target: target, session: session, info: info)
            }
        case "Target.targetInfoChanged", "Target.targetDestroyed", "Target.targetCrashed":
            let target = (p["targetInfo"] as? [String: Any])?["targetId"] as? String ?? p["targetId"] as? String
            let profile = target.flatMap { profilesByTarget[$0]?.profile } ?? defaultProfile
            profile?.handleBrowserEvent(event)
            if event.method == "Target.targetDestroyed", let target { forget(target: target) }
        default:
            break
        }
    }

    /// Attaches to `target`, once, and hands its session and what it is to `then`.
    private func attach(_ target: String, then: @escaping (String, [String: Any]) -> Void) {
        guard attachedTargets.insert(target).inserted else { return }
        Task {
            guard let session = (try? await connection.send("Target.attachToTarget", ["targetId": target, "flatten": true]))?["sessionId"] as? String
            else { attachedTargets.remove(target); return }
            let info = (try? await connection.send("Target.getTargetInfo", ["targetId": target]))?["targetInfo"] as? [String: Any] ?? ["targetId": target]
            then(session, info)
        }
    }

    /// A browser said which target it is: a page waiting for it gets it, and Cosmos attaches to it for its profile.
    private func browserKnown(_ browser: CosmosCEFBrowser) {
        guard let target = browser.targetID else { return }
        if let waiters = browserWaiters.removeValue(forKey: target), let claimed = CosmosCEFBrowser.browser(forTarget: target) {
            waiters.forEach { $0(claimed) }
        }
        // A popup whose opener has gone before Cosmos could place it: nobody would ever see it.
        guard let owner = profile(of: browser) else { browser.close(); return }
        attach(target) { [weak self, weak owner] session, info in
            guard let owner else { self?.release(session); return }
            owner.attached(target: target, session: session, info: info)
        }
    }

    private var anyProfile: ChromiumProfile? { profilesByTarget.values.compactMap(\.profile).first }

    /// A target Cosmos has nothing to do with goes on, unwatched.
    func release(_ session: String) {
        connection.post("Runtime.runIfWaitingForDebugger", session: session)
        connection.post("Target.detachFromTarget", ["sessionId": session])
    }

    // MARK: Downloads

    private func downloadStarted(_ download: CosmosCEFDownload, in browser: CosmosCEFBrowser) -> String? {
        guard let profile = profile(of: browser), let path = profile.downloadBegan(download) else { return nil }
        downloads[ObjectIdentifier(download)] = Weak(profile: profile)
        return path
    }

    private func downloadUpdated(_ download: CosmosCEFDownload) {
        let key = ObjectIdentifier(download)
        downloads[key]?.profile?.downloadProgressed(download)
        if download.isComplete || download.isCanceled || download.isInterrupted { downloads[key] = nil }
    }
}
