import AppKit
import CosmosCEF
import CosmosCore
import CosmosEngine

/// One Cosmos profile in Chromium: a CEF context with a folder of its own (cookies, storage, cache), or nothing on disk
/// for a private window. The default profile is the one CEF starts with, the only one extensions run in. Pages are CEF
/// browsers; Cosmos attaches to each before it runs (Chromium waits), so the agent and Boosts are in place for the first
/// document.
@MainActor
final class ChromiumProfile: EngineProfile {
    static let agentWorld = "cosmos"

    /// Weak: the profile's tasks can outlast the engine (when Cosmos, or a test, lets go of it).
    private(set) weak var engine: ChromiumEngine?
    let id: UUID?
    let isDefault: Bool
    let isEphemeral: Bool
    /// Where Chromium keeps this profile (inside the engine's root), nil for a private window.
    let cacheDirectory: URL?
    /// Where downloads wait until Cosmos moves them.
    let stagingDirectory: URL
    weak var delegate: EngineProfileDelegate?

    private var runtime: ChromiumRuntime { .shared }
    var connection: CDPConnection? { runtime.isRunning && !closed ? runtime.connection : nil }
    private(set) var context: CosmosCEFContext?
    private(set) var scripts: [PageScript] = []
    /// What Cosmos gave (`setPageScripts`), and the hiding of a profile that blocks on its own.
    private var givenScripts: [PageScript] = []
    private var hiding: [PageScript] = []
    /// The rules a profile without the blocker extension matches its requests with, and their making.
    private let ownRules = OwnRequestRules()
    private var ownRulesMade: Task<Void, Never>?
    /// Every profile but the default one, which has the blocker extension, and a private window's, which the extension
    /// reaches (it is made from the default one).
    private var blocksOnItsOwn: Bool { !isDefault && !isEphemeral }

    private var pages: [String: ChromiumPage] = [:]
    private var sessions: [String: ChromiumPage] = [:]
    private var unclaimed: [String: (session: String, info: [String: Any])] = [:]
    /// Targets Cosmos made itself, waiting for Chromium to attach them.
    private var claims: [String: CheckedContinuation<String, Never>] = [:]
    private var downloads: [ObjectIdentifier: (cef: CosmosCEFDownload, download: EngineDownload, file: URL)] = [:]
    private var bridgeSession: String?
    private var bridgeReady: [CheckedContinuation<Void, Never>] = []
    private(set) lazy var extensionHost = ChromiumExtensionHost(profile: self)
    /// Where the copies of the extensions Chromium loads are (`ExtensionStage`): the default profile's only.
    var extensionStages: URL? { isDefault ? cacheDirectory?.appendingPathComponent("Cosmos Extensions", isDirectory: true) : nil }
    private var blocking: (lists: [CompiledBlockingList], allowlist: [String])?
    /// What the user decided about sites, applied to each site as its pages load.
    private var decisions: Set<PermissionDecision> = []
    private var decidedOrigins: Set<String> = []
    /// What Cosmos has set in Chromium, to take back when the user does.
    private var setPermissions: Set<SetPermission> = []
    private struct SetPermission: Hashable { let permission: CosmosCEFPermission; let origin: String }
    private var started = false
    private var starting: Task<Bool, Never>?
    /// The sites this profile's pages and frames have been on since Cosmos started, in memory only: what Clear Site Data
    /// reaches in a profile without the bridge extension.
    private var sitesSeen: Set<String> = []
    private var closed = false

    var extensions: EngineExtensions? { isDefault ? extensionHost : nil }

    init(engine: ChromiumEngine, id: UUID?, directory: URL?) {
        self.engine = engine
        self.id = id
        isEphemeral = directory == nil
        let runtime = ChromiumRuntime.shared
        isDefault = directory != nil && id != nil && id == ChromiumRuntime.configuration?.defaultProfileID
        cacheDirectory = isDefault ? runtime.defaultCache : directory.map { Self.cacheDirectory(for: $0, id: id, root: runtime.root) }
        stagingDirectory = (cacheDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-private-\(UUID().uuidString)"))
            .appendingPathComponent("Cosmos Downloads", isDirectory: true)
        if isDefault { runtime.defaultProfile = self }
    }

    /// Where Chromium keeps the data of the profile whose folder is `directory`: the folder itself. Chromium opens only a
    /// profile whose folder is directly inside its root folder, so a profile whose folder is elsewhere (a test's) gets
    /// one there.
    static func cacheDirectory(for directory: URL, id: UUID?, root: URL?) -> URL {
        guard let root, directory.standardizedFileURL.deletingLastPathComponent().path != root.standardizedFileURL.path else { return directory }
        return root.appendingPathComponent("Profile \((id ?? UUID()).uuidString)", isDirectory: true)
    }

    // MARK: Starting

    /// Starts Chromium if it is not running yet, and this profile's side of it once. True when it is running. Every caller
    /// waits for the whole of it: a page made before the blocker is in would load unblocked.
    @discardableResult
    func start() async -> Bool {
        guard !closed, let engine else { return false }
        if let starting { return await starting.value }
        let task = Task { await setUp(engine) }
        starting = task
        return await task.value
    }

    private func setUp(_ engine: ChromiumEngine) async -> Bool {
        guard await runtime.start(settings: engine.settings) else { return false }
        started = true
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        if let cacheDirectory, !isDefault {
            // The default profile's were written before Chromium started.
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            ChromiumPreferences.prepare(profile: cacheDirectory, root: nil, settings: engine.settings, keepsHistory: false)
        }
        context = isDefault ? CosmosCEFContext.global : CosmosCEFContext(cachePath: cacheDirectory?.path)
        if blocksOnItsOwn {
            context?.blocksRequest = OwnRequestRules.check(ownRules)
            await ownRulesMade?.value
        }
        if isDefault, let c = connection {
            if let bridge = ChromiumResources.bridgeExtension {
                _ = try? await c.send("Extensions.loadUnpacked", ["path": bridge.path])
            }
            await extensionHost.browserStarted()
            if let blocking { await installBlocker(blocking.lists, allowlist: blocking.allowlist) }
        }
        return true
    }


    // MARK: Pages

    func makePage() -> EnginePage {
        let page = ChromiumPage(browser: self)
        Task {
            guard await start(), let context, !page.isClosed else { return }
            let browser = page.makeBrowser(context: context)
            runtime.own(browser, for: self)
            let known = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in browser.whenTargetKnown { c.resume(returning: $0) } }
            guard let target = known else { return }
            // What Chromium says of it (that it closed, say) comes here from now on.
            runtime.register(target: target, for: self)
            let session = await self.session(forNewTarget: target)
            guard !session.isEmpty, !page.isClosed else { return }
            adopt(page, target: target, session: session, info: [:])
        }
        return page
    }

    /// A page Cosmos opens on its own (an extension's side panel or sign-in page). With `request`, the delegate is given it
    /// to show, as a page a site opened; without, the caller shows it.
    func openPage(_ url: URL, request: NewPageRequest? = nil) -> ChromiumPage? {
        guard let page = makePage() as? ChromiumPage else { return nil }
        if let request, delegate?.profile(self, didOpen: page, opener: nil, request: request) != true {
            page.close()
            return nil
        }
        page.load(url)
        return page
    }

    /// The session of a target Cosmos just made: Chromium attaches it (paused) either before or after CEF says which target
    /// the browser is.
    private func session(forNewTarget target: String) async -> String {
        if let waiting = unclaimed.removeValue(forKey: target) { return waiting.session }
        return await withCheckedContinuation { claims[target] = $0 }
    }

    private func adopt(_ page: ChromiumPage, target: String, session: String, info: [String: Any]) {
        pages[target] = page
        sessions[session] = page
        runtime.route(session) { [weak self] event in self?.handle(event) }
        runtime.register(target: target, for: self)
        page.attach(targetID: target, sessionID: session, url: (info["url"] as? String).flatMap(URL.init(string:)))
        // A popup's first page can have loaded before Cosmos attached: its title is only in what the target says now.
        if info["title"] != nil { page.targetInfoChanged(info) }
    }

    func forget(_ page: ChromiumPage) {
        guard let target = page.targetID else { return }
        pages[target] = nil
        if let s = page.sessionID { sessions[s] = nil; runtime.unroute(s) }
        runtime.forget(target: target)
    }

    func page(forTarget id: String) -> ChromiumPage? { pages[id] }
    func page(of browser: CosmosCEFBrowser) -> ChromiumPage? { pages.values.first { $0.cefBrowser === browser } }

    /// A popup CEF made for one of this profile's pages is that page's now: its downloads and dialogs come here.
    func own(_ browser: CosmosCEFBrowser) { runtime.own(browser, for: self) }

    /// Events of `session` (a frame from another site) go to `page`.
    func route(_ session: String, to page: ChromiumPage) {
        sessions[session] = page
        runtime.route(session) { [weak self] event in self?.handle(event) }
    }
    func unroute(_ session: String) {
        sessions[session] = nil
        runtime.unroute(session)
    }

    func setPageScripts(_ scripts: [PageScript]) {
        givenScripts = scripts
        installPageScripts()
    }

    private func installPageScripts() {
        let helper = ChromiumResources.engineHelper.map { [PageScript(source: $0, world: .agent, time: .documentStart)] } ?? []
        let bridge = ChromiumResources.pageBridge.map { [PageScript(source: $0, world: .page, time: .documentStart)] } ?? []
        scripts = helper + bridge + hiding + givenScripts
        for page in pages.values { page.installScripts(scripts) }
    }

    // MARK: Events

    /// What one of this profile's sessions sent: a page's (or its frames'), or an extension worker's.
    private func handle(_ event: CDPEvent) {
        if let session = event.sessionID, let page = sessions[session] { page.handle(event); return }
        extensionHost.handle(event)
    }

    /// What Chromium says about one of this profile's targets, or its downloads.
    func handleBrowserEvent(_ event: CDPEvent) {
        let p = event.params
        switch event.method {
        case "Target.targetInfoChanged":
            if let info = p["targetInfo"] as? [String: Any], let target = info["targetId"] as? String { pages[target]?.targetInfoChanged(info) }
        case "Target.targetDestroyed":
            if let target = p["targetId"] as? String {
                // A browser that closed before it was set up.
                claims.removeValue(forKey: target)?.resume(returning: "")
                if let page = pages.removeValue(forKey: target) {
                    if let s = page.sessionID { sessions[s] = nil; runtime.unroute(s) }
                    page.targetDestroyed()
                }
            }
        case "Target.targetCrashed":
            if let target = p["targetId"] as? String, let page = pages[target] {
                page.handle(CDPEvent(method: "Inspector.targetCrashed", params: [:], sessionID: page.sessionID))
            }
        default:
            break
        }
    }

    /// A target of this profile's attached, paused before it runs.
    func attached(target: String, session: String, info: [String: Any]) {
        guard !closed else { runtime.release(session); return }
        let type = info["type"] as? String ?? ""
        let url = info["url"] as? String ?? ""
        if type == "service_worker" {
            runtime.route(session) { [weak self] event in self?.handle(event) }
            if let worker = URL(string: url), worker.scheme == "chrome-extension", worker.host == ChromiumResources.bridgeExtensionID {
                bridgeSession = session
                connection?.post("Runtime.runIfWaitingForDebugger", session: session)
                bridgeReady.forEach { $0.resume() }
                bridgeReady = []
            } else {
                extensionHost.serviceWorkerAttached(target: target, session: session, url: url)
            }
            return
        }
        runtime.register(target: target, for: self)
        if let claim = claims.removeValue(forKey: target) {
            claim.resume(returning: session)
            return
        }
        if let opener = (info["openerId"] as? String).flatMap({ pages[$0] }) {
            openOnItsOwn(target: target, session: session, info: info, opener: opener)
            return
        }
        // Either a page Cosmos asked for whose browser has not said which target it is yet, or one an extension opened.
        unclaimed[target] = (session, info)
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard self.unclaimed[target] != nil else { return }
            self.unclaimed[target] = nil
            if url.hasPrefix("chrome://") { self.runtime.release(session); return }
            self.openOnItsOwn(target: target, session: session, info: info, opener: nil)
        }
    }

    private func openOnItsOwn(target: String, session: String, info: [String: Any], opener: ChromiumPage?) {
        let page = ChromiumPage(browser: self)
        adopt(page, target: target, session: session, info: info)
        page.takeBrowser(forTarget: target)
        var request = opener?.lastWindowOpen ?? NewPageRequest(url: nil)
        opener?.lastWindowOpen = nil
        if request.url == nil { request.url = (info["url"] as? String).flatMap(URL.init(string:)) }
        request.fromExtension = opener == nil
        if delegate?.profile(self, didOpen: page, opener: opener, request: request) != true { page.close() }
    }

    // MARK: Bridge

    private func bridge() async -> String? {
        guard isDefault else { return nil }
        if let bridgeSession { return bridgeSession }
        guard await start() else { return nil }
        await withCheckedContinuation { bridgeReady.append($0) }
        return bridgeSession
    }

    func setPermissionDecisions(_ decisions: [PermissionDecision]) {
        let new = Set(decisions)
        guard new != self.decisions else { return }
        self.decisions = new
        decidedOrigins = []
        guard let context else { return }
        // What the user took back is asked about again; what remains goes back in.
        for set in setPermissions { context.setPermission(set.permission, origin: set.origin, to: .default) }
        setPermissions = []
        Task { for page in Array(pages.values) { await applyDecisions(to: page.state.url) } }
    }

    /// Puts what the user decided about `url`'s site into Chromium, once per site.
    func applyDecisions(to url: URL?) async {
        guard context != nil, let url, let host = url.host, let origin = Self.origin(of: url), !decidedOrigins.contains(origin) else { return }
        let mine = decisions.filter { $0.host == host }
        guard !mine.isEmpty else { return }
        decidedOrigins.insert(origin)
        for d in mine { await setPermission(d.kind, allowed: d.allowed, origin: origin) }
    }

    /// `http://host:port`, what Chromium keeps permissions by.
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    /// Grants or refuses a permission to a site (`http://host:port`) in this profile.
    func setPermission(_ kind: PermissionRequest.Kind, allowed: Bool, origin: String) async {
        guard !closed, let context else { return }
        let permissions: [CosmosCEFPermission] = switch kind {
        case .camera: [.camera]
        case .microphone: [.microphone]
        case .cameraAndMicrophone: [.camera, .microphone]
        case .location: [.location]
        case .notifications: [.notifications]
        }
        for permission in permissions {
            context.setPermission(permission, origin: origin, to: allowed ? .allow : .block)
            setPermissions.insert(SetPermission(permission: permission, origin: origin))
        }
    }

    /// Runs `expression` in the bridge extension's service worker (the default profile's).
    func bridgeEvaluate(_ expression: String) async -> Any? {
        guard let session = await bridge(),
              let r = try? await connection?.send("Runtime.evaluate", ["expression": expression, "awaitPromise": true, "returnByValue": true], session: session)
        else { return nil }
        return (r["result"] as? [String: Any])?["value"]
    }

    // MARK: Downloads

    func download(_ url: URL, from page: ChromiumPage) {
        // With the page's profile and cookies; it comes back through downloadBegan like any other.
        page.cefBrowser?.startDownload(url.absoluteString)
    }

    /// A page of this profile began a download: where CEF puts it until Cosmos moves it (nil refuses it).
    func downloadBegan(_ cef: CosmosCEFDownload) -> String? {
        guard !closed else { return nil }
        let url = URL(string: cef.url)
        let name = cef.suggestedName.isEmpty ? (url?.lastPathComponent ?? "Download") : cef.suggestedName
        let download = EngineDownload(url: url, suggestedFilename: name) { [weak cef] in cef?.cancel() }
        let file = stagingDirectory.appendingPathComponent(UUID().uuidString)
        downloads[ObjectIdentifier(cef)] = (cef, download, file)
        delegate?.profile(self, didStartDownload: download)
        return file.path
    }

    func downloadProgressed(_ cef: CosmosCEFDownload) {
        let key = ObjectIdentifier(cef)
        guard let (_, download, file) = downloads[key] else { return }
        let total = cef.total >= 0 ? cef.total : nil
        if cef.isComplete {
            downloads[key] = nil
            download.update(received: cef.received, total: total, state: .finished(file))
        } else if cef.isCanceled {
            downloads[key] = nil
            download.update(state: .cancelled)
        } else if cef.isInterrupted {
            downloads[key] = nil
            download.update(state: .failed("The download stopped before the end."))
        } else {
            download.update(received: cef.received, total: total)
        }
    }

    // MARK: Cookies

    func setCookies(_ cookies: [EngineCookie]) async -> Int {
        guard !cookies.isEmpty, await start(), let context else { return 0 }
        let list = cookies.map { c -> CosmosCEFCookie in
            let o = CosmosCEFCookie()
            o.domain = c.domain; o.name = c.name; o.value = c.value; o.path = c.path
            o.expires = c.expires
            o.secure = c.isSecure; o.httpOnly = c.isHTTPOnly; o.sameSite = c.sameSite.rawValue
            return o
        }
        return await withCheckedContinuation { done in context.setCookies(list) { done.resume(returning: $0) } }
    }

    // MARK: Blocking

    func setContentBlocking(_ lists: [CompiledBlockingList]?, allowlist: [String]) {
        // The same lists again (another setting changed) leave the extension as it is.
        if let blocking, let lists, blocking.lists.map(\.digest) == lists.map(\.digest), blocking.allowlist == allowlist { return }
        if blocking == nil, lists == nil { return }
        blocking = lists.map { ($0, allowlist) }
        if blocksOnItsOwn { blockOnItsOwn(); return }
        guard isDefault, started else { return }
        Task { await installBlocker(lists ?? [], allowlist: allowlist) }
    }

    /// Blocking where the blocker extension does not run: the hiding is a page script, and requests are matched on CEF's
    /// network thread by rules made away from the main thread (a profile's start waits for them).
    private func blockOnItsOwn() {
        let lists = blocking?.lists ?? [], allowlist = blocking?.allowlist ?? []
        hiding = BlockerExtension.hidingScript(lists, allowlist: allowlist).map { [PageScript(source: $0, world: .agent, time: .documentStart)] } ?? []
        installPageScripts()
        let holder = ownRules
        let generation = holder.nextGeneration()
        ownRulesMade = Task.detached(priority: .userInitiated) {
            holder.set(lists.contains { $0.kind == .network } ? RequestRules(lists: lists, allowlist: allowlist) : nil, generation: generation)
        }
    }

    private func installBlocker(_ lists: [CompiledBlockingList], allowlist: [String]) async {
        guard isDefault, let c = connection, let cacheDirectory else { return }
        let folder = cacheDirectory.appendingPathComponent("Cosmos Blocker", isDirectory: true)
        let existing = (try? await c.send("Extensions.getExtensions"))?["extensions"] as? [[String: Any]] ?? []
        for e in existing where (e["path"] as? String) == folder.path {
            if let id = e["id"] as? String { _ = try? await c.send("Extensions.uninstall", ["id": id]) }
        }
        guard !lists.isEmpty, BlockerExtension.write(lists, allowlist: allowlist, to: folder) else { return }
        // Private windows are in-memory profiles made from this one: the blocker runs in them too.
        _ = try? await c.send("Extensions.loadUnpacked", ["path": folder.path, "enableInIncognito": true])
    }

    // MARK: Data

    /// A frame of one of this profile's pages is on `url`.
    func sawSite(_ url: URL) {
        if !isDefault, let origin = Self.origin(of: url) { sitesSeen.insert(origin) }
    }

    func clearSiteData() async {
        guard await start(), let c = connection, let context else { return }
        await withCheckedContinuation { done in context.deleteCookies { done.resume() } }
        // The default profile's bridge extension clears the cache and every site's storage.
        if isDefault { _ = await bridgeEvaluate("cosmosClearData()"); return }
        // Elsewhere only a page's session can, as it acts on its own profile: the cache, and the storage of every site
        // the profile has been on since Cosmos started. (What a site stored in an earlier run, and has not been back to
        // since, stays: Chromium cannot list the sites that have storage.)
        let sites = sitesSeen
        sitesSeen = []
        guard let page = makePage() as? ChromiumPage else { return }
        defer { page.close() }
        for _ in 0..<200 where page.sessionID == nil { try? await Task.sleep(for: .milliseconds(25)) }
        guard let session = page.sessionID else { return }
        _ = try? await c.send("Network.clearBrowserCache", session: session)
        for origin in sites { _ = try? await c.send("Storage.clearDataForOrigin", ["origin": origin, "storageTypes": "all"], session: session) }
    }

    func clearHistory(since date: Date?) async {
        guard isDefault, await start() else { return }
        _ = await bridgeEvaluate("cosmosClearHistory(\((date?.timeIntervalSince1970 ?? 0) * 1000))")
    }

    func deleteHistory(of url: URL) async {
        guard isDefault, await start() else { return }
        _ = await bridgeEvaluate("cosmosDeleteHistory(\(ChromiumResources.jsString(url.absoluteString)))")
    }

    func processIDs() async -> [Int32] {
        guard let c = connection else { return [] }
        let info = (try? await c.send("SystemInfo.getProcessInfo"))?["processInfo"] as? [[String: Any]] ?? []
        let me = getpid()
        return [me] + info.compactMap { ($0["id"] as? Int).map(Int32.init) }.filter { $0 != me }
    }

    /// Chromium runs inside Cosmos and does not start again: the current settings go into it as it runs, and the pages
    /// load again with them. (The graphics processor setting waits for the next launch.)
    func restart() {
        guard let context, let engine else { return }
        context.setPreferences(ChromiumPreferences.preferences(engine.settings, keepsHistory: isDefault))
        CosmosCEFRuntime.setGlobalPreferences(ChromiumPreferences.localState(engine.settings))
        for page in pages.values { page.reload(fromOrigin: false) }
    }

    func close() {
        closed = true
        for page in Array(pages.values) {
            page.browserDidStop()
            page.closeBrowser()
        }
        for (_, claim) in claims { claim.resume(returning: "") }
        claims.removeAll()
        for session in sessions.keys { runtime.unroute(session) }
        pages.removeAll()
        sessions.removeAll()
        for (_, d) in downloads {
            d.cef.cancel()
            d.download.update(state: .failed("The window closed"))
        }
        downloads.removeAll()
        if isDefault {
            extensionHost.browserStopped()
            if runtime.defaultProfile === self { runtime.defaultProfile = nil }
        }
        if isEphemeral {
            let folder = stagingDirectory.deletingLastPathComponent()
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { try? FileManager.default.removeItem(at: folder) }
        }
    }
}
