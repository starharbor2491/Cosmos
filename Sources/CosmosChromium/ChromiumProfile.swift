import AppKit
import CosmosEngine

/// One Cosmos profile in Chromium: its own Chromium process with its own user-data folder (cookies, storage, extensions),
/// so profiles share nothing. Pages are page targets in it; Cosmos attaches to each before it runs (Chromium waits for
/// Cosmos), so the agent and Boosts are in place for the first document.
@MainActor
final class ChromiumProfile: EngineProfile {
    static let agentWorld = "cosmos"

    unowned let engine: ChromiumEngine
    let id: UUID?
    /// Where Chromium keeps this profile. For a profile with no directory (incognito) it is a temporary folder that goes
    /// when the profile closes.
    let dataDirectory: URL
    let isEphemeral: Bool
    weak var delegate: EngineProfileDelegate?

    private var process: ChromiumProcess?
    private var starting: Task<Bool, Never>?
    var connection: CDPConnection? { process?.connection }
    private(set) var scripts: [PageScript] = []
    private(set) var userAgent: String?
    /// Chromium's zoom for a page at 100%: the main screen's scale, so frames are drawn at full resolution.
    private(set) var defaultZoomFactor: Double = Double(NSScreen.main?.backingScaleFactor ?? 2)

    private var pages: [String: ChromiumPage] = [:]
    private var sessions: [String: ChromiumPage] = [:]
    private var unclaimed: [String: (session: String, info: [String: Any])] = [:]
    /// Targets Cosmos made itself, waiting for Chromium to attach them.
    private var claims: [String: CheckedContinuation<String, Never>] = [:]
    private var downloads: [String: EngineDownload] = [:]
    private var bridgeSession: String?
    private var bridgeReady: [CheckedContinuation<Void, Never>] = []
    private(set) lazy var extensionHost = ChromiumExtensionHost(profile: self)
    private var blocking: (lists: [CompiledBlockingList], allowlist: [String])?
    /// What the user decided about sites, applied to each site as its pages load (Chromium forgets it when it stops).
    private var decisions: Set<PermissionDecision> = []
    private var decidedOrigins: Set<String> = []
    private var closed = false
    /// The blank page Chromium opens when it starts. It stays (a Chromium with no page left may quit) but is no tab.
    private var startupTargets: Set<String> = []

    var extensions: EngineExtensions? { extensionHost }

    init(engine: ChromiumEngine, id: UUID?, directory: URL?) {
        self.engine = engine
        self.id = id
        if let directory {
            dataDirectory = directory
            isEphemeral = false
        } else {
            dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-incognito-\(UUID().uuidString)", isDirectory: true)
            isEphemeral = true
        }
    }

    // MARK: Starting

    /// Starts Chromium for this profile once the engine has a Chromium to start. True when it is running.
    @discardableResult
    func start() async -> Bool {
        if process != nil { return true }
        if let starting { return await starting.value }
        let task = Task { await launch() }
        starting = task
        let ok = await task.value
        starting = nil
        return ok
    }

    private func launch() async -> Bool {
        guard !closed, let app = await engine.readyApplication() else { return false }
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let version = ChromiumInstall.version(of: app) ?? ""
        userAgent = ChromiumPreferences.userAgent(chromiumVersion: version)
        ChromiumPreferences.prepare(userDataDirectory: dataDirectory, settings: engine.settings, defaultZoom: defaultZoomFactor)
        let flags = ChromiumPreferences.flags(settings: engine.settings) + ["--user-agent=\(userAgent ?? "")"] + engine.extraFlags
        let executable = app.appendingPathComponent("Contents/MacOS/Chromium")
        guard let process = try? ChromiumProcess(executable: executable,
                                                 arguments: ChromiumProcess.arguments(userDataDirectory: dataDirectory, extraFlags: flags),
                                                 environment: ChromiumProcess.environment(userDataDirectory: dataDirectory)) else {
            engine.launchFailed(app)
            return false
        }
        self.process = process
        process.connection.onEvent = { [weak self] event in self?.handle(event) }
        process.onExit = { [weak self] _ in self?.processEnded(process) }
        let c = process.connection
        do {
            _ = try await c.send("Browser.getVersion")
            let existing = (try await c.send("Target.getTargets"))["targetInfos"] as? [[String: Any]] ?? []
            startupTargets = Set(existing.filter { ($0["type"] as? String) == "page" }.compactMap { $0["targetId"] as? String })
            _ = try await c.send("Target.setDiscoverTargets", ["discover": true])
            _ = try await c.send("Target.setAutoAttach", ["autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true,
                                                         "filter": [["type": "page"], ["type": "service_worker"], ["exclude": true]]])
            let staging = stagingDirectory
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            _ = try await c.send("Browser.setDownloadBehavior", ["behavior": "allowAndName", "downloadPath": staging.path, "eventsEnabled": true])
        } catch {
            process.terminate()
            self.process = nil
            // A snapshot that will not start goes back to the one before it, if there is one.
            engine.launchFailed(app)
            return false
        }
        if let bridge = ChromiumResources.bridgeExtension {
            _ = try? await c.send("Extensions.loadUnpacked", ["path": bridge.path])
        }
        await extensionHost.browserStarted()
        if let blocking { await installBlocker(blocking.lists, allowlist: blocking.allowlist) }
        return true
    }

    var stagingDirectory: URL { dataDirectory.appendingPathComponent("Cosmos Downloads", isDirectory: true) }

    private func processEnded(_ ended: ChromiumProcess) {
        guard process === ended else { return }
        process = nil
        bridgeSession = nil
        let lost = Array(pages.values)
        pages.removeAll(); sessions.removeAll(); unclaimed.removeAll()
        for (_, claim) in claims { claim.resume(returning: "") }
        claims.removeAll()
        for page in lost { page.browserDidStop() }
        for (_, d) in downloads { d.update(state: .failed("Chromium stopped")) }
        downloads.removeAll()
        extensionHost.browserStopped()
        decidedOrigins = []
        guard !closed else { return }
        delegate?.profileDidRestart(self)
    }

    // MARK: Pages

    func makePage() -> EnginePage {
        let page = ChromiumPage(browser: self)
        Task {
            guard await start(), let c = connection,
                  let r = try? await c.send("Target.createTarget", ["url": "about:blank"]), let target = r["targetId"] as? String else { return }
            let session = await self.session(forNewTarget: target)
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

    /// The session of a target Cosmos just made: Chromium attaches it (paused) either before or after `createTarget` answers.
    private func session(forNewTarget target: String) async -> String {
        if let waiting = unclaimed.removeValue(forKey: target) { return waiting.session }
        return await withCheckedContinuation { claims[target] = $0 }
    }

    private func adopt(_ page: ChromiumPage, target: String, session: String, info: [String: Any]) {
        pages[target] = page
        sessions[session] = page
        page.attach(targetID: target, sessionID: session, url: (info["url"] as? String).flatMap(URL.init(string:)))
    }

    func forget(_ page: ChromiumPage) {
        guard let target = page.targetID else { return }
        pages[target] = nil
        if let s = page.sessionID { sessions[s] = nil }
        connection?.post("Target.closeTarget", ["targetId": target])
    }

    func page(forTarget id: String) -> ChromiumPage? { pages[id] }

    /// Chromium's DevTools for `page`: a page of their own, which goes to the delegate to be shown in a window.
    func openInspector(for page: ChromiumPage) async {
        // Chromium does not attach DevTools to Cosmos on its own, as it does pages: Cosmos attaches to them.
        guard let target = page.targetID, let c = connection,
              let r = try? await c.send("Target.openDevTools", ["targetId": target]), let tools = r["targetId"] as? String,
              let session = (try? await c.send("Target.attachToTarget", ["targetId": tools, "flatten": true]))?["sessionId"] as? String else { return }
        let info = (try? await c.send("Target.getTargetInfo", ["targetId": tools]))?["targetInfo"] as? [String: Any] ?? [:]
        let inspector = ChromiumPage(browser: self)
        adopt(inspector, target: tools, session: session, info: info)
        page.inspector = inspector
        let request = NewPageRequest(url: nil, features: ["width=1100", "height=720"], isDeveloperTools: true)
        if delegate?.profile(self, didOpen: inspector, opener: page, request: request) != true { inspector.close() }
    }

    /// Events of `session` (a frame from another site) go to `page`.
    func route(_ session: String, to page: ChromiumPage) { sessions[session] = page }
    func unroute(_ session: String) { sessions[session] = nil }

    func setPageScripts(_ scripts: [PageScript]) {
        let helper = ChromiumResources.engineHelper.map { [PageScript(source: $0, world: .agent, time: .documentStart)] } ?? []
        let bridge = ChromiumResources.pageBridge.map { [PageScript(source: $0, world: .page, time: .documentStart)] } ?? []
        self.scripts = helper + bridge + scripts
        for page in pages.values { Task { await page.installScripts(self.scripts) } }
    }

    // MARK: Events

    private func handle(_ event: CDPEvent) {
        if let session = event.sessionID {
            if let page = sessions[session] { page.handle(event); return }
            extensionHost.handle(event)
            return
        }
        let p = event.params
        switch event.method {
        case "Target.attachedToTarget":
            guard let session = p["sessionId"] as? String, let info = p["targetInfo"] as? [String: Any],
                  let target = info["targetId"] as? String else { return }
            attached(target: target, session: session, info: info, waiting: p["waitingForDebugger"] as? Bool ?? false)
        case "Target.targetInfoChanged":
            if let info = p["targetInfo"] as? [String: Any], let target = info["targetId"] as? String { pages[target]?.targetInfoChanged(info) }
        case "Target.targetDestroyed":
            if let target = p["targetId"] as? String, let page = pages.removeValue(forKey: target) {
                if let s = page.sessionID { sessions[s] = nil }
                page.targetDestroyed()
            }
            extensionHost.targetDestroyed(p["targetId"] as? String)
        case "Target.targetCrashed":
            if let target = p["targetId"] as? String, let page = pages[target] {
                page.handle(CDPEvent(method: "Inspector.targetCrashed", params: [:], sessionID: page.sessionID))
            }
        case "Browser.downloadWillBegin":
            downloadBegan(p)
        case "Browser.downloadProgress":
            downloadProgressed(p)
        default:
            break
        }
    }

    private func attached(target: String, session: String, info: [String: Any], waiting: Bool) {
        let type = info["type"] as? String ?? ""
        let url = info["url"] as? String ?? ""
        if type == "service_worker" {
            if url.hasPrefix("chrome-extension://"), url.contains("/cosmos-bridge.js") {
                bridgeSession = session
                connection?.post("Runtime.runIfWaitingForDebugger", session: session)
                bridgeReady.forEach { $0.resume() }
                bridgeReady = []
            } else {
                extensionHost.serviceWorkerAttached(target: target, session: session, url: url)
            }
            return
        }
        // A tab is only looked into, for the page it holds (`ChromiumExtensionHost.tabTarget(of:)`): it is not a page.
        if type == "tab" { return }
        if let claim = claims.removeValue(forKey: target) {
            claim.resume(returning: session)
            return
        }
        if startupTargets.contains(target) {
            connection?.post("Runtime.runIfWaitingForDebugger", session: session)
            connection?.post("Target.detachFromTarget", ["sessionId": session])
            return
        }
        if extensionHost.claimsPopup(url: url) {
            let page = ChromiumPage(browser: self)
            adopt(page, target: target, session: session, info: info)
            extensionHost.popupAttached(page)
            return
        }
        // DevTools are claimed by the page that asked for them (`openInspector`), never opened as its popup.
        if !url.hasPrefix("devtools://"), let opener = (info["openerId"] as? String).flatMap({ pages[$0] }) {
            openOnItsOwn(target: target, session: session, info: info, opener: opener)
            return
        }
        // Either a page Cosmos asked for whose answer has not come back yet, or one an extension opened.
        unclaimed[target] = (session, info)
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard self.unclaimed[target] != nil else { return }
            self.unclaimed[target] = nil
            if url.hasPrefix("devtools://") || url.hasPrefix("chrome://") { self.connection?.post("Runtime.runIfWaitingForDebugger", session: session); return }
            self.openOnItsOwn(target: target, session: session, info: info, opener: nil)
        }
    }

    private func openOnItsOwn(target: String, session: String, info: [String: Any], opener: ChromiumPage?) {
        let page = ChromiumPage(browser: self)
        adopt(page, target: target, session: session, info: info)
        var request = opener?.lastWindowOpen ?? NewPageRequest(url: nil)
        opener?.lastWindowOpen = nil
        if request.url == nil { request.url = (info["url"] as? String).flatMap(URL.init(string:)) }
        request.fromExtension = opener == nil
        if delegate?.profile(self, didOpen: page, opener: opener, request: request) != true { page.close() }
    }

    // MARK: Bridge (zoom)

    private func bridge() async -> String? {
        if let bridgeSession { return bridgeSession }
        guard process != nil else { return nil }
        await withCheckedContinuation { bridgeReady.append($0) }
        return bridgeSession
    }

    /// Sets Chromium's own zoom for one page (the bridge extension does it with `chrome.tabs.setZoom`).
    func setZoom(_ factor: Double, target: String) {
        Task {
            guard let session = await bridge() else { return }
            connection?.post("Runtime.evaluate", ["expression": "cosmosZoom(\(ChromiumResources.jsString(target)), \(factor))", "awaitPromise": true],
                             session: session)
        }
    }

    func setPermissionDecisions(_ decisions: [PermissionDecision]) {
        let new = Set(decisions)
        guard new != self.decisions else { return }
        self.decisions = new
        decidedOrigins = []
        guard process != nil else { return }
        Task {
            // What the user took back is asked about again; what remains goes back in.
            _ = try? await connection?.send("Browser.resetPermissions")
            for page in Array(pages.values) { await applyDecisions(to: page.state.url) }
        }
    }

    /// Puts what the user decided about `url`'s site into Chromium, once per site while it runs (before it runs, there is
    /// nothing to put it into: the page's navigation does it again once it does).
    func applyDecisions(to url: URL?) async {
        guard process != nil, let url, let host = url.host, let origin = Self.origin(of: url), !decidedOrigins.contains(origin) else { return }
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

    /// Grants or refuses a permission to a site (`http://host:port`) in Chromium, which otherwise refuses it on its own.
    /// It lasts while this Chromium runs; after a restart the site asks again and Cosmos answers from what it remembers.
    func setPermission(_ kind: PermissionRequest.Kind, allowed: Bool, origin: String) async {
        let names: [String] = switch kind {
        case .camera: ["camera"]
        case .microphone: ["microphone"]
        case .cameraAndMicrophone: ["camera", "microphone"]
        case .location: ["geolocation"]
        case .notifications: ["notifications"]
        }
        for name in names {
            _ = try? await connection?.send("Browser.setPermission", ["permission": ["name": name], "setting": allowed ? "granted" : "denied",
                                                                     "origin": origin])
        }
    }

    /// Runs `expression` in the bridge extension's service worker.
    func bridgeEvaluate(_ expression: String) async -> Any? {
        guard let session = await bridge(),
              let r = try? await connection?.send("Runtime.evaluate", ["expression": expression, "awaitPromise": true, "returnByValue": true], session: session)
        else { return nil }
        return (r["result"] as? [String: Any])?["value"]
    }

    // MARK: Downloads

    func download(_ url: URL, from page: ChromiumPage) {
        // A throwaway page fetches it with the profile's cookies; Chromium turns the response into a download.
        Task {
            guard await start(), let c = connection,
                  let r = try? await c.send("Target.createTarget", ["url": "about:blank", "background": true]), let target = r["targetId"] as? String else { return }
            let session = await self.session(forNewTarget: target)
            c.post("Runtime.runIfWaitingForDebugger", session: session)
            _ = try? await c.send("Page.navigate", ["url": url.absoluteString], session: session)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            c.post("Target.closeTarget", ["targetId": target])
        }
    }

    private func downloadBegan(_ p: [String: Any]) {
        guard let guid = p["guid"] as? String else { return }
        let url = (p["url"] as? String).flatMap(URL.init(string:))
        let download = EngineDownload(url: url, suggestedFilename: p["suggestedFilename"] as? String ?? url?.lastPathComponent ?? "Download") { [weak self] in
            self?.connection?.post("Browser.cancelDownload", ["guid": guid])
        }
        downloads[guid] = download
        delegate?.profile(self, didStartDownload: download)
    }

    private func downloadProgressed(_ p: [String: Any]) {
        guard let guid = p["guid"] as? String, let download = downloads[guid] else { return }
        let received = (p["receivedBytes"] as? NSNumber)?.int64Value
        let total = (p["totalBytes"] as? NSNumber)?.int64Value
        switch p["state"] as? String {
        case "completed":
            downloads[guid] = nil
            download.update(received: received, total: total, state: .finished(stagingDirectory.appendingPathComponent(guid)))
        case "canceled":
            downloads[guid] = nil
            download.update(state: .cancelled)
        default:
            download.update(received: received, total: total)
        }
    }

    // MARK: Blocking

    func setContentBlocking(_ lists: [CompiledBlockingList]?, allowlist: [String]) {
        // The same lists again (another setting changed) leave the extension as it is.
        if let blocking, let lists, blocking.lists.map(\.digest) == lists.map(\.digest), blocking.allowlist == allowlist { return }
        if blocking == nil, lists == nil { return }
        blocking = lists.map { ($0, allowlist) }
        Task { await installBlocker(lists ?? [], allowlist: allowlist) }
    }

    private func installBlocker(_ lists: [CompiledBlockingList], allowlist: [String]) async {
        guard process != nil, let c = connection else { return }
        let folder = dataDirectory.appendingPathComponent("Cosmos Blocker", isDirectory: true)
        let existing = (try? await c.send("Extensions.getExtensions"))?["extensions"] as? [[String: Any]] ?? []
        for e in existing where (e["path"] as? String) == folder.path {
            if let id = e["id"] as? String { _ = try? await c.send("Extensions.uninstall", ["id": id]) }
        }
        guard !lists.isEmpty, BlockerExtension.write(lists, allowlist: allowlist, to: folder) else { return }
        _ = try? await c.send("Extensions.loadUnpacked", ["path": folder.path])
    }

    // MARK: Data

    func clearSiteData() async {
        guard await start(), let c = connection else { return }
        _ = try? await c.send("Storage.clearCookies")
        _ = try? await c.send("Network.clearBrowserCache")
        for page in pages.values {
            if let origin = page.state.url.flatMap({ u -> String? in guard let s = u.scheme, let h = u.host else { return nil }; return "\(s)://\(h)" }) {
                c.post("Storage.clearDataForOrigin", ["origin": origin, "storageTypes": "all"])
            }
        }
        _ = await bridgeEvaluate("cosmosClearData()")
    }

    func processIDs() async -> [Int32] {
        guard let c = connection, let process else { return [] }
        let info = (try? await c.send("SystemInfo.getProcessInfo"))?["processInfo"] as? [[String: Any]] ?? []
        return [process.pid] + info.compactMap { ($0["id"] as? Int).map(Int32.init) }.filter { $0 != process.pid }
    }

    func restart() {
        guard let process else { return }
        // The process's end is reported as a restart (see `processEnded`); the next page starts it again.
        process.terminate()
    }

    func close() {
        closed = true
        for page in Array(pages.values) { page.browserDidStop() }
        pages.removeAll()
        sessions.removeAll()
        process?.terminate()
        process = nil
        if isEphemeral {
            let folder = dataDirectory
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { try? FileManager.default.removeItem(at: folder) }
        }
    }
}
