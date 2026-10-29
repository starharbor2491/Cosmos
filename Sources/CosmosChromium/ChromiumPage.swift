import AppKit
import CosmosCEF
import CosmosCore
import CosmosEngine

/// One Chromium tab: a CEF browser drawn in `ChromiumPageView`, driven over the DevTools protocol as a page target.
@MainActor
final class ChromiumPage: EnginePage {
    /// Weak: a task of the page can still be waiting when the profile has gone (a question nobody answered before the
    /// window closed), and then finds nothing to reach.
    private(set) weak var browser: ChromiumProfile?
    let pageView = ChromiumPageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    var view: NSView { pageView }
    weak var delegate: EnginePageDelegate?
    private(set) var state = PageState()

    /// The browser CEF draws the page with, once there is one.
    private(set) var cefBrowser: CosmosCEFBrowser?
    private(set) var targetID: String?
    private(set) var sessionID: String?
    private(set) var isClosed = false
    /// Hears the address of every document the page asks for, redirects included (an extension's sign-in page, which
    /// ends at an address of the extension's).
    /// Each address the page is about to go to (a redirect too), before anything is asked of the site: true takes it,
    /// and the page does not go there.
    var onNavigation: ((URL) -> Bool)?
    /// The page is gone: closed by Cosmos or by Chromium.
    var onClose: (() -> Void)?
    /// The video in Picture in Picture: its view, the script context (of the page or a frame) that watches it, and where
    /// that frame is in the page. Chromium streams the page's frames to it (the screencast) only while it is up.
    private var pictureInPicture: (view: ChromiumPictureInPictureView, context: Context, frameID: String, offset: CGPoint)?
    /// The page's notifications: the page-world context that holds each, for its events.
    private var notifications: [String: Context] = [:]
    /// Commands made before the target exists wait here.
    private var queued: [() -> Void] = []
    private var mainFrameID: String?
    /// Execution contexts: Cosmos's world of the main frame, and every context's frame and world. A context is known by
    /// its session as well as its id: a frame from another site has a session (and ids) of its own.
    struct Context: Hashable { let session: String; let id: Int }
    private var agentContextID: Int?
    private var contexts: [Context: (frameID: String, isAgent: Bool, isDefault: Bool, origin: String)] = [:]
    /// The address of each of the page's frames, by Chromium's frame id.
    private var frameURLs: [String: URL] = [:]
    /// Each frame's origin, which for a document without an address of its own (about:blank, srcdoc) is its creator's.
    private var frameOrigins: [String: URL] = [:]
    /// The scripts installed in each session (the page's and its frames'), and how often they have been replaced.
    private var scriptIDs: [String: [String]] = [:]
    private var scriptGeneration: [String: Int] = [:]
    /// Frames from other sites, which Chromium runs in processes (and sessions) of their own, and each one's frame.
    private var frameSessions: Set<String> = []
    private var frameOfSession: [String: String] = [:]
    private var isCasting = false
    private var frameGeneration = 0
    private let decodeQueue = DispatchQueue(label: "cosmos.chromium.frames", qos: .userInteractive)
    private var failedLoad: URL?
    private var showingOwnErrorPage = false
    /// A page from a dangerous site that CEF stopped, until Chromium is done with the navigation it cancelled (it still
    /// says that navigation started, which would take Cosmos's warning away).
    private var stoppedDanger: (url: URL, danger: PageDanger)?
    /// The `window.open` that made the next popup of this page, with its features.
    var lastWindowOpen: NewPageRequest?
    private(set) var isInElementFullscreen = false
    private var metricsEnabled = false
    private var overridesUserAgent = false

    /// Chromium keeps the zoom by site, as Chrome does: what this says is the zoom of the site the page shows.
    var zoom: Double {
        get { cefBrowser?.zoomFactor ?? 1 }
        set { cefBrowser?.zoomFactor = newValue }
    }
    var userAgent: String? { didSet { if userAgent != oldValue { applyUserAgent() } } }

    init(browser: ChromiumProfile) {
        self.browser = browser
        pageView.page = self
    }

    /// The page's browser, made in its view.
    func makeBrowser(context: CosmosCEFContext) -> CosmosCEFBrowser {
        let made = CosmosCEFBrowser(in: pageView, context: context, url: "about:blank")
        cefBrowser = made
        return made
    }

    /// A page a site opened: CEF made its browser out of sight, and it moves into this page's view once it says which
    /// target it is.
    func takeBrowser(forTarget target: String) {
        ChromiumRuntime.shared.whenBrowser(forTarget: target) { [weak self] made in
            guard let self, !self.isClosed else { made.close(); return }
            self.cefBrowser = made
            self.browser?.own(made)
            made.move(to: self.pageView)
        }
    }

    // MARK: Target

    /// Takes over a page target Chromium made (and paused, waiting for Cosmos): its scripts go in before it runs.
    func attach(targetID: String, sessionID: String, url: URL?) {
        self.targetID = targetID
        self.sessionID = sessionID
        if let url, url.absoluteString != "about:blank" { state.url = url }
        Task { await setUp() }
    }

    /// Everything the page needs goes out in order before Chromium is told to let it run, without waiting for answers: a
    /// page a site opened runs in its opener's renderer, which Chromium holds until then, so neither would answer.
    private func setUp() async {
        guard let sessionID, let c = browser?.connection else { return }
        prepare(session: sessionID, connection: c)
        applyUserAgent()
        c.post("Runtime.runIfWaitingForDebugger", session: sessionID)
        if let tree = try? await c.send("Page.getFrameTree", session: sessionID),
           let frame = (tree["frameTree"] as? [String: Any])?["frame"] as? [String: Any] {
            mainFrameID = frame["id"] as? String
        }
        viewVisibilityChanged()
        let waiting = queued
        queued = []
        waiting.forEach { $0() }
    }

    /// What the page's session and each of its frames' sessions are set up with, before they run.
    private func prepare(session: String, connection c: CDPConnection) {
        c.post("Page.enable", session: session)
        c.post("Runtime.enable", session: session)
        if session == sessionID {
            c.post("Page.setLifecycleEventsEnabled", ["enabled": true], session: session)
            c.post("Page.setInterceptFileChooserDialog", ["enabled": true], session: session)
        }
        // HTTP authentication: Chromium only says a site wants a password for requests it holds, so it holds documents
        // (not images or scripts), which go on at once; a challenge comes to Cosmos.
        c.post("Fetch.enable", Self.authInterception, session: session)
        c.post("Runtime.addBinding", ["name": "__cosmosPost", "executionContextName": ChromiumProfile.agentWorld], session: session)
        c.post("Target.setAutoAttach", Self.frameAttachment, session: session)
        installScripts(browser?.scripts ?? [], in: session)
    }

    static let authInterception: [String: Any] = ["patterns": [["urlPattern": "*", "resourceType": "Document", "requestStage": "Request"]],
                                                  "handleAuthRequests": true]
    /// Frames from other sites are held until Cosmos has set them up. A worker left out here never started (Chromium held it
    /// at its start too), so workers are attached as well, only to be let go (`release`).
    static let frameAttachment: [String: Any] = ["autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true,
                                                 "filter": [["type": "iframe"], ["type": "worker"], ["exclude": true]]]

    /// Replaces the scripts every new document gets (agent, Boosts), in the page and in its frames from other sites.
    func installScripts(_ scripts: [PageScript]) {
        guard let sessionID else { return }
        for session in [sessionID] + frameSessions { installScripts(scripts, in: session) }
    }

    /// The scripts go out at once, in order; each one's id comes back later. One that comes back after the scripts were
    /// replaced again is taken out at once.
    private func installScripts(_ scripts: [PageScript], in session: String) {
        guard let c = browser?.connection else { return }
        for id in scriptIDs[session] ?? [] { c.post("Page.removeScriptToEvaluateOnNewDocument", ["identifier": id], session: session) }
        scriptIDs[session] = []
        scriptGeneration[session, default: 0] += 1
        let generation = scriptGeneration[session]
        for script in scripts {
            var params: [String: Any] = ["source": Self.wrap(script), "runImmediately": true]
            if script.world == .agent { params["worldName"] = ChromiumProfile.agentWorld }
            c.send("Page.addScriptToEvaluateOnNewDocument", params, session: session) { [weak self] r in
                guard let self, let id = r?["identifier"] as? String else { return }
                if self.scriptGeneration[session] == generation {
                    self.scriptIDs[session, default: []].append(id)
                } else {
                    c.post("Page.removeScriptToEvaluateOnNewDocument", ["identifier": id], session: session)
                }
            }
        }
    }

    /// A frame from another site, paused before it runs: it gets the page's scripts, sign-in and frames of its own.
    private func attachFrame(session: String, frame: String?) {
        guard !frameSessions.contains(session) else { return }
        frameSessions.insert(session)
        frameOfSession[session] = frame
        browser?.route(session, to: self)
        guard let c = browser?.connection else { return }
        prepare(session: session, connection: c)
        c.post("Runtime.runIfWaitingForDebugger", session: session)
    }

    /// A worker, held at its start like every child (see `frameAttachment`): it goes on, and the session that attached
    /// it lets go of it.
    private func release(_ session: String, from parent: String) {
        browser?.connection?.post("Runtime.runIfWaitingForDebugger", session: session)
        browser?.connection?.post("Target.detachFromTarget", ["sessionId": session], session: parent)
    }

    private func detachFrame(session: String) {
        guard frameSessions.remove(session) != nil else { return }
        frameOfSession[session] = nil
        browser?.unroute(session)
        scriptIDs[session] = nil
        scriptGeneration[session] = nil
        contexts = contexts.filter { $0.key.session != session }
    }

    /// What a frame from another site's session reports: its scripts' worlds, their messages.
    private func handleFrame(_ event: CDPEvent, session: String) {
        let p = event.params
        switch event.method {
        case "Target.attachedToTarget":
            if let child = p["sessionId"] as? String, let info = p["targetInfo"] as? [String: Any] {
                if info["type"] as? String == "iframe" { attachFrame(session: child, frame: info["targetId"] as? String) } else { release(child, from: session) }
            }
        case "Target.detachedFromTarget":
            if let child = p["sessionId"] as? String { detachFrame(session: child) }
        case "Runtime.executionContextCreated", "Runtime.executionContextDestroyed", "Runtime.executionContextsCleared":
            contextEvent(event.method, p, session: session)
        case "Runtime.bindingCalled":
            binding(p, session: session)
        case "Page.frameNavigated":
            noteFrame(p)
        case "Fetch.requestPaused":
            documentPaused(p, session: session)
        case "Fetch.authRequired":
            authRequired(p, session: session)
        default:
            break
        }
    }

    /// A frame of the page, or of a frame from another site, went to an address.
    private func noteFrame(_ p: [String: Any]) {
        guard let frame = p["frame"] as? [String: Any], let id = frame["id"] as? String,
              let url = (frame["url"] as? String).flatMap(URL.init(string:)) else { return }
        frameURLs[id] = url
        frameOrigins[id] = (frame["securityOrigin"] as? String).flatMap(URL.init(string:))
        browser?.sawSite(url)
    }

    private func contextEvent(_ method: String, _ p: [String: Any], session: String) {
        switch method {
        case "Runtime.executionContextCreated":
            guard let context = p["context"] as? [String: Any], let id = context["id"] as? Int,
                  let aux = context["auxData"] as? [String: Any], let frameID = aux["frameId"] as? String else { return }
            let isAgent = (context["name"] as? String) == ChromiumProfile.agentWorld
            let origin = context["origin"] as? String ?? ""
            contexts[Context(session: session, id: id)] = (frameID, isAgent, aux["isDefault"] as? Bool ?? false, origin)
            if isAgent && frameID == mainFrameID && session == sessionID { agentContextID = id }
            // An extension's content scripts are about to run here: it is told which tab this is.
            if aux["type"] as? String == "isolated", origin.hasPrefix("chrome-extension://"), let extensionID = URL(string: origin)?.host {
                browser?.extensionHost.contentWorldCreated(in: self, extensionID: extensionID, session: session, contextID: id, frameID: frameID)
            }
        case "Runtime.executionContextDestroyed":
            guard let id = p["executionContextId"] as? Int else { return }
            contexts[Context(session: session, id: id)] = nil
            if session == sessionID && agentContextID == id { agentContextID = nil }
        default:
            contexts = contexts.filter { $0.key.session != session }
            if session == sessionID { agentContextID = nil }
        }
    }

    /// The session of a frame from another site (a frame's target is known by the frame's id).
    func session(forFrame frame: String) -> String? { frameOfSession.first { $0.value == frame }?.key }

    /// Runs `expression` in one script context, of the page or of one of its frames.
    private func evaluate(_ expression: String, in context: Context) {
        browser?.connection?.post("Runtime.evaluate", ["expression": expression, "contextId": context.id], session: context.session)
    }

    static func wrap(_ script: PageScript) -> String {
        switch script.time {
        case .documentStart: return script.source
        case .documentEnd:
            return "(function(){ const run = function(){\n\(script.source)\n}; if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run, { once: true }); else run(); })();"
        }
    }

    private func whenReady(_ work: @escaping () -> Void) {
        if sessionID != nil { work() } else if !isClosed { queued.append(work) }
    }

    private func command(_ method: String, _ params: [String: Any] = [:]) {
        whenReady { [weak self] in
            guard let self, let sessionID = self.sessionID else { return }
            self.browser?.connection?.post(method, params, session: sessionID)
        }
    }

    private func request(_ method: String, _ params: [String: Any] = [:]) async -> [String: Any]? {
        if sessionID == nil {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                if isClosed { c.resume() } else { queued.append { c.resume() } }
            }
        }
        guard let sessionID else { return nil }
        return try? await browser?.connection?.send(method, params, session: sessionID)
    }

    /// An input event (an editing command, text to paste): dropped if the page is not running yet.
    func input(_ method: String, _ params: [String: Any]) {
        guard let sessionID else { return }
        browser?.connection?.post(method, params, session: sessionID)
    }

    func runEditingCommand(_ commands: [String]) {
        guard !commands.isEmpty else { return }
        input("Input.dispatchKeyEvent", ["type": "rawKeyDown", "key": "", "code": "", "windowsVirtualKeyCode": 0, "commands": commands])
        input("Input.dispatchKeyEvent", ["type": "keyUp", "key": "", "code": "", "windowsVirtualKeyCode": 0])
    }

    // MARK: Events

    func handle(_ event: CDPEvent) {
        if let session = event.sessionID, session != sessionID { handleFrame(event, session: session); return }
        let p = event.params
        switch event.method {
        case "Target.attachedToTarget":
            if let child = p["sessionId"] as? String, let info = p["targetInfo"] as? [String: Any] {
                if info["type"] as? String == "iframe" { attachFrame(session: child, frame: info["targetId"] as? String) } else if let sessionID { release(child, from: sessionID) }
            }
        case "Target.detachedFromTarget":
            if let child = p["sessionId"] as? String { detachFrame(session: child) }
        case "Page.frameStartedLoading":
            guard isMain(p["frameId"]) else { return }
            failedLoad = nil
            showingOwnErrorPage = false
            state.isLoading = true
            state.progress = 0.1
            delegate?.pageDidStartNavigation(self)
            changed()
        case "Page.frameNavigated":
            noteFrame(p)
            guard let frame = p["frame"] as? [String: Any], frame["parentId"] == nil else { return }
            mainFrameID = frame["id"] as? String
            agentContextID = nil
            if pictureInPicture != nil { endPictureInPicture() }
            if let unreachable = (frame["unreachableUrl"] as? String).flatMap(URL.init(string:)) {
                state.url = unreachable
                failedLoad = unreachable
                Task { await reportFailure(unreachable) }
            } else if let url = (frame["url"] as? String).flatMap(URL.init(string:)) {
                state.url = url
                Task { await browser?.applyDecisions(to: url) }
                delegate?.pageDidCommitNavigation(self)
            }
            refreshHistory()
            changed()
        case "Page.navigatedWithinDocument":
            guard isMain(p["frameId"]), let url = (p["url"] as? String).flatMap(URL.init(string:)) else { return }
            state.url = url
            refreshHistory()
            changed()
        case "Page.lifecycleEvent":
            guard isMain(p["frameId"]) else { return }
            switch p["name"] as? String {
            case "DOMContentLoaded": state.progress = max(state.progress, 0.7); changed()
            case "firstContentfulPaint": state.progress = max(state.progress, 0.5); changed()
            default: break
            }
        case "Page.frameStoppedLoading":
            guard isMain(p["frameId"]) else { return }
            state.isLoading = false
            state.progress = 1
            refreshHistory()
            changed()
            if stoppedDanger != nil { reportStoppedDanger() } else if failedLoad == nil { delegate?.pageDidFinishLoading(self) }
        case "Fetch.requestPaused":
            if let sessionID { documentPaused(p, session: sessionID) }
        case "Fetch.authRequired":
            if let sessionID { authRequired(p, session: sessionID) }
        case "Page.fileChooserOpened":
            chooseFiles(p)
        case "Page.windowOpen":
            lastWindowOpen = NewPageRequest(url: (p["url"] as? String).flatMap(URL.init(string:)), features: p["windowFeatures"] as? [String] ?? [],
                                            userGesture: p["userGesture"] as? Bool ?? false)
        case "Page.screencastFrame":
            frame(p)
        case "Runtime.executionContextCreated", "Runtime.executionContextDestroyed", "Runtime.executionContextsCleared":
            if let sessionID { contextEvent(event.method, p, session: sessionID) }
        case "Runtime.bindingCalled":
            if let sessionID { binding(p, session: sessionID) }
        case "Inspector.targetCrashed":
            state.isLoading = false
            changed()
            delegate?.pageRendererDidTerminate(self)
        default:
            break
        }
    }

    func targetInfoChanged(_ info: [String: Any]) {
        setTitle(info["title"] as? String ?? "", url: info["url"] as? String ?? state.url?.absoluteString ?? "")
    }

    private func setTitle(_ title: String, url: String) {
        // Chromium names an untitled page after its address (without the scheme); Cosmos shows the address itself then.
        let bare = url.replacingOccurrences(of: "^[a-zA-Z][a-zA-Z0-9+.-]*://", with: "", options: .regularExpression)
        let next = (title == url || title == bare || title.hasPrefix("about:")) ? "" : title
        // A failed load keeps no title of its own: the error page's would end up in the sidebar and history.
        guard !showingOwnErrorPage, failedLoad == nil, !url.hasPrefix("chrome-error:"), next != state.title else { return }
        state.title = next
        changed()
    }

    /// The target went away without Cosmos closing it: the page called `window.close()`.
    func targetDestroyed() {
        guard !isClosed else { return }
        isClosed = true
        onClose?()
        delegate?.pageRequestsClose(self)
    }

    private func isMain(_ frameID: Any?) -> Bool {
        guard let id = frameID as? String else { return false }
        if mainFrameID == nil { mainFrameID = id }
        return id == mainFrameID
    }

    private func changed() {
        delegate?.pageStateDidChange(self)
        browser?.extensionHost.pageChanged(self)
    }

    private func refreshHistory() {
        Task {
            guard let r = await request("Page.getNavigationHistory"), let index = r["currentIndex"] as? Int,
                  let entries = r["entries"] as? [[String: Any]] else { return }
            let back = index > 0, forward = index < entries.count - 1
            if back != state.canGoBack || forward != state.canGoForward {
                state.canGoBack = back
                state.canGoForward = forward
                changed()
            }
        }
    }

    private func reportFailure(_ url: URL) async {
        let code = await evaluate("(document.querySelector('.error-code') || {}).textContent || ''", in: .page) as? String ?? ""
        guard failedLoad == url else { return }
        delegate?.page(self, didFailLoading: url, error: Self.loadError(code))
        changed()
    }

    static func loadError(_ code: String) -> PageLoadError {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "net::", with: "")
        let kind: PageLoadError.Kind
        switch c {
        case "ERR_INTERNET_DISCONNECTED", "ERR_NETWORK_CHANGED": kind = .offline
        case "ERR_NAME_NOT_RESOLVED", "ERR_NAME_RESOLUTION_FAILED", "ERR_ADDRESS_INVALID": kind = .hostNotFound
        case "ERR_CONNECTION_TIMED_OUT", "ERR_TIMED_OUT": kind = .timedOut
        case "ERR_CONNECTION_REFUSED", "ERR_CONNECTION_RESET", "ERR_CONNECTION_CLOSED", "ERR_ADDRESS_UNREACHABLE", "ERR_CONNECTION_FAILED", "ERR_EMPTY_RESPONSE":
            kind = .connectionFailed
        default:
            kind = c.hasPrefix("ERR_CERT_") || c.hasPrefix("ERR_SSL_") || c == "ERR_BAD_SSL_CLIENT_AUTH_CERT" ? .insecure : .other
        }
        return PageLoadError(kind: kind, detail: c.isEmpty ? "The page could not be loaded." : c)
    }

    private func binding(_ p: [String: Any], session: String) {
        guard (p["name"] as? String) == "__cosmosPost", let payload = p["payload"] as? String, let contextID = p["executionContextId"] as? Int,
              let message = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return }
        let key = Context(session: session, id: contextID)
        // Only Cosmos's own world can call the binding; a message from anywhere else is ignored.
        guard let context = contexts[key], context.isAgent else { return }
        let fromMain = session == sessionID && context.frameID == mainFrameID
        switch message["type"] as? String {
        case "__fullscreen": setElementFullscreen(message["value"] as? Bool ?? false)
        case "__ask":
            guard let id = message["id"] as? Int else { return }
            switch message["what"] as? String {
            case "permission":
                if let kind = PermissionRequest.Kind(rawValue: message["kind"] as? String ?? "") { askPermission(kind, id: id, context: key) }
            case "pictureInPicture": enterPictureInPicture(id: id, context: key, frameID: context.frameID)
            case "leavePictureInPicture": endPictureInPicture(); evaluate("__cosmosAnswer(\(id), true)", in: key)
            default: evaluate("__cosmosAnswer(\(id))", in: key)
            }
        case "__pipRect":
            if let pip = pictureInPicture, pip.context == key, let x = message["x"] as? Double, let y = message["y"] as? Double,
               let w = message["width"] as? Double, let h = message["height"] as? Double {
                // CSS pixels of the page; the page's view shows them at its zoom.
                let z = zoom
                pip.view.videoRect = CGRect(x: (x + pip.offset.x) * z, y: (y + pip.offset.y) * z, width: w * z, height: h * z)
            }
        case "__tell":
            guard let note = message["note"] as? [String: Any], let id = note["id"] as? String else { return }
            switch message["what"] as? String {
            case "notification":
                notifications[id] = pageWorld(of: key, frameID: context.frameID)
                let host = (note["origin"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? state.url?.host ?? ""
                delegate?.page(self, showNotification: EngineNotification(id: id, title: note["title"] as? String ?? "", body: note["body"] as? String ?? "",
                                                                         source: host))
            case "notificationClose":
                notifications[id] = nil
                delegate?.page(self, closeNotification: id)
            default: break
            }
        case "__pipGone":
            if pictureInPicture?.context == key { endPictureInPicture() }
        case "__title": if fromMain { setTitle(message["value"] as? String ?? "", url: state.url?.absoluteString ?? "") }
        // An error document (Chromium's, then Cosmos's) says nothing about the site: its icons are not the site's to fetch.
        case "meta" where fromMain && failedLoad != nil: break
        default:
            // Which site the frame is, as Chromium knows it: what the page says of itself is not taken for that.
            var told = message
            told["frameOrigin"] = context.origin
            delegate?.page(self, agentMessage: told, fromMainFrame: fromMain)
        }
    }

    // MARK: Picture in Picture frames

    /// Chromium draws the page itself; only a video in Picture in Picture needs its frames, wherever the tab is.
    func viewVisibilityChanged() {
        let casting = pictureInPicture != nil
        guard sessionID != nil, casting != isCasting else { return }
        isCasting = casting
        if casting {
            command("Page.startScreencast", ["format": "jpeg", "quality": 92, "everyNthFrame": 1])
        } else {
            command("Page.stopScreencast")
        }
    }

    private func frame(_ p: [String: Any]) {
        if let ack = p["sessionId"] as? Int { command("Page.screencastFrameAck", ["sessionId": ack]) }
        guard let base64 = p["data"] as? String,
              let width = (p["metadata"] as? [String: Any])?["deviceWidth"] as? Double, width > 0 else { return }
        frameGeneration += 1
        let generation = frameGeneration
        decodeQueue.async { [weak self] in
            guard let data = Data(base64Encoded: base64), let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.frameGeneration else { return }
                    self.pictureInPicture?.view.show(image, pixelsPerPoint: CGFloat(Double(image.width) / width))
                }
            }
        }
    }

    // MARK: Dialogs, files, menus

    /// A page's `alert`, `confirm`, `prompt` or leave-the-page question, which CEF hands Cosmos to show.
    func runDialog(_ kind: CosmosCEFDialogKind, message: String, defaultText: String, origin: String, answer: @escaping (Bool, String?) -> Void) {
        let dialogKind: PageDialog.Kind = switch kind {
        case .confirm: .confirm
        case .prompt: .prompt(default: defaultText)
        case .beforeUnload: .beforeUnload
        default: .alert
        }
        let host = URL(string: origin)?.host ?? ""
        Task {
            let reply = await delegate?.page(self, runDialog: PageDialog(kind: dialogKind, message: message, origin: host)) ?? PageDialog.Answer(accepted: false)
            answer(reply.accepted, reply.text)
        }
    }

    /// CEF asks before every navigation of the page and its frames. One to a dangerous site is stopped before anything is
    /// sent to it, and for the page itself Cosmos says why; a frame is left out quietly. False stops it.
    func allowsNavigation(to url: URL, mainFrame: Bool) -> Bool {
        if mainFrame, onNavigation?(url) == true { return false }
        guard let danger = delegate?.page(self, dangerAt: url) else { return true }
        if mainFrame {
            stoppedDanger = (url, danger)
            // In case Chromium says nothing more about the navigation.
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.reportStoppedDanger()
            }
        }
        return false
    }

    private func reportStoppedDanger() {
        guard let (url, danger) = stoppedDanger else { return }
        stoppedDanger = nil
        failedLoad = url
        state.url = url
        state.isLoading = false
        delegate?.page(self, didFailLoading: url, error: PageLoadError(kind: danger == .malware ? .malware : .phishing, detail: danger.rawValue))
        changed()
    }

    /// A document Chromium holds for sign-in (see `authInterception`): it goes on at once.
    private func documentPaused(_ p: [String: Any], session: String) {
        guard let id = p["requestId"] as? String else { return }
        browser?.connection?.post("Fetch.continueRequest", ["requestId": id], session: session)
    }

    private func authRequired(_ p: [String: Any], session: String) {
        guard let id = p["requestId"] as? String, let c = p["authChallenge"] as? [String: Any] else { return }
        let origin = (c["origin"] as? String).flatMap(URL.init(string:))
        let challenge = AuthChallenge(host: origin?.host ?? "", realm: c["realm"] as? String ?? "", isProxy: (c["source"] as? String) == "Proxy",
                                      isSecure: origin?.scheme == "https")
        Task {
            let answer = await delegate?.page(self, wantsCredentialsFor: challenge)
            var response: [String: Any] = ["response": answer == nil ? "CancelAuth" : "ProvideCredentials"]
            if let answer { response["username"] = answer.user; response["password"] = answer.password }
            browser?.connection?.post("Fetch.continueWithAuth", ["requestId": id, "authChallengeResponse": response], session: session)
        }
    }

    private func chooseFiles(_ p: [String: Any]) {
        guard let node = p["backendNodeId"] as? Int else { return }
        let multiple = (p["mode"] as? String) == "selectMultiple"
        Task {
            let urls = await delegate?.page(self, chooseFiles: FileChooser(allowsMultiple: multiple, allowsDirectories: false))
            guard let urls, !urls.isEmpty else { return }
            command("DOM.setFileInputFiles", ["files": urls.map(\.path), "backendNodeId": node])
        }
    }

    /// A frame of the page asked for a permission (see page-bridge.js). The question is about the page's site, as in
    /// Chrome, where a frame only gets what its page has. The answer goes into Chromium, then the frame's call goes ahead.
    private func askPermission(_ kind: PermissionRequest.Kind, id: Int, context: Context) {
        guard let url = state.url, let host = url.host, let origin = ChromiumProfile.origin(of: url) else {
            evaluate("__cosmosAnswer(\(id))", in: context)
            return
        }
        Task {
            let allowed = await delegate?.page(self, wantsPermission: PermissionRequest(kind: kind, host: host)) ?? false
            if allowed, kind == .location {
                // Chromium would ask macOS itself; it is given the place Cosmos has instead (none: the position is unavailable).
                var position: [String: Any] = [:]
                if let at = await delegate?.pageWantsLocation(self) {
                    position = ["latitude": at.latitude, "longitude": at.longitude, "accuracy": at.accuracy]
                }
                _ = await request("Emulation.setGeolocationOverride", position)
            }
            await browser?.setPermission(kind, allowed: allowed, origin: origin)
            evaluate("__cosmosAnswer(\(id))", in: context)
        }
    }

    /// A video asked for Picture in Picture (see page-bridge.js): a view of it goes to the delegate, and the context that
    /// asked starts saying where the video is.
    private func enterPictureInPicture(id: Int, context: Context, frameID: String) {
        if pictureInPicture != nil { endPictureInPicture() }
        let view = ChromiumPictureInPictureView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        Task {
            let offset = await self.offset(ofFrame: frameID, session: context.session)
            let shown = await delegate?.page(self, wantsPictureInPicture: view) ?? false
            if shown {
                pictureInPicture = (view, context, frameID, offset)
                viewVisibilityChanged()
                evaluate("__cosmosTrackPictureInPicture()", in: context)
            }
            evaluate("__cosmosAnswer(\(id), \(shown))", in: context)
        }
    }

    /// Where a frame from another site is in the page, in CSS pixels; zero for the page's own frames.
    private func offset(ofFrame frameID: String, session: String) async -> CGPoint {
        guard session != sessionID else { return .zero }
        _ = await request("DOM.getDocument", ["depth": 0])
        guard let owner = (await request("DOM.getFrameOwner", ["frameId": frameID]))?["backendNodeId"] as? Int,
              let model = (await request("DOM.getBoxModel", ["backendNodeId": owner]))?["model"] as? [String: Any],
              let quad = model["content"] as? [Double], quad.count >= 2 else { return .zero }
        return CGPoint(x: quad[0], y: quad[1])
    }

    /// Picture in Picture is over: the video goes back into the page, and the delegate hears of it.
    private func endPictureInPicture() {
        guard let pip = pictureInPicture else { return }
        pictureInPicture = nil
        evaluate("window.__cosmosStopPictureInPicture && __cosmosStopPictureInPicture()", in: pip.context)
        // The page's own world of the same frame holds the element and its events.
        if let page = pageWorld(of: pip.context, frameID: pip.frameID) {
            evaluate("window.__cosmosLeavePictureInPicture && __cosmosLeavePictureInPicture()", in: page)
        }
        viewVisibilityChanged()
        delegate?.pageDidLeavePictureInPicture(self)
    }

    func leavePictureInPicture() { endPictureInPicture() }

    /// The worlds an extension's content scripts run in, in the page and its frames.
    func extensionWorlds(of extensionID: String) -> [(session: String, id: Int, frameID: String)] {
        contexts.filter { !$0.value.isDefault && $0.value.origin == "chrome-extension://\(extensionID)" }
            .map { ($0.key.session, $0.key.id, $0.value.frameID) }
    }

    /// The page's own world in each of its frames, the main frame's first.
    var frameWorlds: [(session: String, id: Int, frameID: String)] {
        contexts.filter { $0.value.isDefault }.map { ($0.key.session, $0.key.id, $0.value.frameID) }
            .sorted { a, _ in a.frameID == mainFrameID }
    }

    var mainFrame: String? { mainFrameID }
    /// The address a frame is judged by (what an extension may reach there): its own, or for a document without one
    /// (about:blank, srcdoc, blob:) the origin it runs with.
    func url(ofFrame frame: String) -> URL? {
        guard let url = frameURLs[frame] else { return frame == mainFrame ? state.url : nil }
        return url.scheme == "http" || url.scheme == "https" ? url : frameOrigins[frame]
    }

    /// The page's own world of the frame that `context` (Cosmos's world) is in.
    private func pageWorld(of context: Context, frameID: String) -> Context? {
        contexts.first { $0.key.session == context.session && $0.value.frameID == frameID && $0.value.isDefault }?.key
    }

    func notification(_ id: String, did action: NotificationAction) {
        guard let context = notifications[id] else { return }
        if action == .closed { notifications[id] = nil }
        let name = action == .closed ? "closed" : "clicked"
        evaluate("window.__cosmosNotificationAction && __cosmosNotificationAction(\(ChromiumResources.jsString(id)), '\(name)')", in: context)
    }

    private func setElementFullscreen(_ on: Bool) {
        isInElementFullscreen = on
        guard let window = pageView.window, window.styleMask.contains(.fullScreen) != on else { return }
        window.toggleFullScreen(nil)
    }

    // MARK: EnginePage

    func load(_ url: URL) {
        failedLoad = nil
        // What the user decided about the site goes in first, so the page finds it there from its first line.
        Task {
            await browser?.applyDecisions(to: url)
            command("Page.navigate", ["url": url.absoluteString])
        }
    }

    func loadHTML(_ html: String, showing url: URL) {
        showingOwnErrorPage = true
        state.url = url
        state.title = ""
        whenReady { [weak self] in
            guard let self, let frameID = self.mainFrameID else { return }
            self.command("Page.setDocumentContent", ["frameId": frameID, "html": html])
        }
        changed()
    }

    func reload(fromOrigin: Bool) {
        if let failed = failedLoad { load(failed); return }
        command("Page.reload", ["ignoreCache": fromOrigin])
    }

    func stop() { command("Page.stopLoading") }
    func goBack() { travel(-1) }
    func goForward() { travel(1) }

    private func travel(_ delta: Int) {
        Task {
            guard let r = await request("Page.getNavigationHistory"), let index = r["currentIndex"] as? Int,
                  let entries = r["entries"] as? [[String: Any]], entries.indices.contains(index + delta),
                  let id = entries[index + delta]["id"] as? Int else { return }
            command("Page.navigateToHistoryEntry", ["entryId": id])
        }
    }

    /// The page's own user agent, or (empty) Chromium's again. Chromium's is left alone until a page has its own, so its
    /// client hints stay.
    private func applyUserAgent() {
        guard sessionID != nil, userAgent != nil || overridesUserAgent else { return }
        overridesUserAgent = userAgent != nil
        command("Emulation.setUserAgentOverride", ["userAgent": userAgent ?? ""])
    }

    /// In Cosmos's own world of each frame whose origin is `origin`, the main frame's first; the page's scripts never see
    /// the password before it is in the form.
    func fillLogin(username: String, password: String, origin: String) async -> Bool {
        let expression = "window.__cosmosFillLogin ? __cosmosFillLogin(\(ChromiumResources.jsString(username)), \(ChromiumResources.jsString(password))) : false"
        let worlds = contexts.filter { $0.value.isAgent && SavedLogin.origin($0.value.origin) == origin }
            .sorted { ($0.value.frameID == mainFrameID ? 0 : 1) < ($1.value.frameID == mainFrameID ? 0 : 1) }
        for (key, _) in worlds {
            let r = try? await browser?.connection?.send("Runtime.evaluate", ["expression": expression, "contextId": key.id, "returnByValue": true],
                                                         session: key.session)
            if (r?["result"] as? [String: Any])?["value"] as? Bool == true { return true }
        }
        return false
    }

    func evaluate(_ script: String, in world: ScriptWorld) async -> Any? {
        var params: [String: Any] = ["expression": script, "returnByValue": true, "awaitPromise": true]
        if world == .agent {
            if agentContextID == nil { _ = await request("Runtime.evaluate", ["expression": "1"]) }
            guard let context = agentContextID else { return nil }
            params["contextId"] = context
        }
        guard let r = await request("Runtime.evaluate", params), r["exceptionDetails"] == nil else { return nil }
        return (r["result"] as? [String: Any])?["value"]
    }

    func perform(_ command: EditCommand) {
        switch command {
        case .copy, .cut:
            let before = NSPasteboard.general.changeCount
            Task {
                // The page's own copy handlers run, and if Chromium does not reach the Mac's clipboard, Cosmos puts the
                // selection there itself.
                let selection = await evaluate("__cosmosSelection()", in: .agent) as? String ?? ""
                runEditingCommand([command.rawValue])
                try? await Task.sleep(nanoseconds: 80_000_000)
                if NSPasteboard.general.changeCount == before, !selection.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(selection, forType: .string)
                }
            }
        case .paste:
            guard let text = NSPasteboard.general.string(forType: .string) else { return }
            input("Input.insertText", ["text": text])
        case .selectAll, .undo, .redo:
            runEditingCommand([command.rawValue])
        }
    }

    func snapshot(width: CGFloat) async -> NSImage? {
        guard let r = await request("Page.captureScreenshot", ["format": "jpeg", "quality": 80]),
              let data = (r["data"] as? String).flatMap({ Data(base64Encoded: $0) }), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0 else { return nil }
        let height = width * CGFloat(image.height) / CGFloat(image.width)
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }

    func pdf() async -> Data? {
        guard let r = await request("Page.printToPDF", ["printBackground": true]) else { return nil }
        return (r["data"] as? String).flatMap { Data(base64Encoded: $0) }
    }

    func download(_ url: URL) { browser?.download(url, from: self) }

    func recentContextClick() -> ContextClick? { pageView.recentContextClick() }

    func forceClicked() { delegate?.pageDidForceClick(self) }

    /// Opens Chromium's DevTools for the page, or closes them when they are open. CEF shows them in a window of its own
    /// (it will not draw them in a view of Cosmos's), which goes when the page does.
    func showInspector() -> Bool {
        guard targetID != nil, let cefBrowser else { return false }
        if cefBrowser.hasDevTools { cefBrowser.closeDevTools() } else { cefBrowser.showDevTools() }
        return true
    }

    func usage() async -> PageUsage? {
        guard !isClosed else { return nil }
        if !metricsEnabled { metricsEnabled = true; _ = await request("Performance.enable") }
        guard let r = await request("Performance.getMetrics"), let metrics = r["metrics"] as? [[String: Any]] else { return nil }
        var values: [String: Double] = [:]
        for m in metrics { if let name = m["name"] as? String, let v = m["value"] as? Double { values[name] = v } }
        return PageUsage(memory: UInt64(max(0, values["JSHeapTotalSize"] ?? 0)), cpuSeconds: values["TaskDuration"] ?? 0)
    }

    /// Chromium draws pages in views of their own, not in a tab strip of its own: it has no active tab to follow.
    func activate() {}

    func close() {
        guard !isClosed else { return }
        isClosed = true
        onClose?()
        // What waited for the page to start ends now, with nothing (the page never had a session).
        let waiting = queued
        queued = []
        waiting.forEach { $0() }
        pageView.removeFromSuperview()
        for session in frameSessions { browser?.unroute(session) }
        frameSessions = []
        browser?.forget(self)
        closeBrowser()
    }

    func closeBrowser() {
        cefBrowser?.close()
        cefBrowser = nil
    }

    /// The profile closed: nothing more will come from this page.
    func browserDidStop() {
        isClosed = true
        sessionID = nil
        isCasting = false
        frameSessions = []
        contexts = [:]
        scriptIDs = [:]
        scriptGeneration = [:]
    }
}
