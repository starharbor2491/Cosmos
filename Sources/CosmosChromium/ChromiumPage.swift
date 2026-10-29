import AppKit
import CosmosEngine

/// One Chromium tab: a page target in the profile's Chromium, driven over the DevTools protocol and drawn by
/// `ChromiumPageView`.
@MainActor
final class ChromiumPage: EnginePage {
    /// Weak: a task of the page can still be waiting when the profile has gone (a question nobody answered before the
    /// window closed), and then finds nothing to reach.
    private(set) weak var browser: ChromiumProfile?
    let pageView = ChromiumPageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    var view: NSView { pageView }
    weak var delegate: EnginePageDelegate?
    private(set) var state = PageState()

    private(set) var targetID: String?
    private(set) var sessionID: String?
    private(set) var isClosed = false
    /// This page's DevTools, while they are open.
    weak var inspector: ChromiumPage?
    /// Hears the address of every document the page asks for, redirects included (an extension's sign-in page, which
    /// ends at an address of the extension's).
    var onDocumentRequest: ((URL) -> Void)? { didSet { if onDocumentRequest != nil { command("Network.enable") } } }
    /// The page is gone: closed by Cosmos or by Chromium.
    var onClose: (() -> Void)?
    /// The page Cosmos stopped as dangerous, until Chromium reports the failure.
    private var stoppedDanger: (host: String?, danger: PageDanger)?
    /// The video in Picture in Picture: its view, the script context (of the page or a frame) that watches it, and where
    /// that frame is in the page.
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
    private var contexts: [Context: (frameID: String, isAgent: Bool, isDefault: Bool)] = [:]
    /// The scripts installed in each session (the page's and its frames').
    private var scriptIDs: [String: [String]] = [:]
    /// Frames from other sites, which Chromium runs in processes (and sessions) of their own, and each one's frame.
    private var frameSessions: Set<String> = []
    private var frameOfSession: [String: String] = [:]
    /// What VoiceOver reads, once an assistive app has looked at the page.
    private(set) var accessibility: ChromiumAccessibility?
    private var isCasting = false
    private var frameGeneration = 0
    private let decodeQueue = DispatchQueue(label: "cosmos.chromium.frames", qos: .userInteractive)
    private var appliedMetrics: (width: Int, height: Int, zoomFactor: Double)?
    /// The zoom Chromium has for this page, when it is not the profile's default.
    private var appliedZoom: Double?
    private var failedLoad: URL?
    private var showingOwnErrorPage = false
    private(set) var caretRect: CGRect?
    /// The `window.open` that made the next popup of this page, with its features.
    var lastWindowOpen: NewPageRequest?
    private(set) var isInElementFullscreen = false
    private var metricsEnabled = false

    var zoom: Double = 1 { didSet { if zoom != oldValue { appliedMetrics = nil; viewGeometryChanged() } } }
    /// Device pixels per CSS pixel: Chromium lays the page out at the screen's scale times the page's zoom.
    var layoutScale: Double { appliedMetrics?.zoomFactor ?? Double(pageView.backingScale) * zoom }
    var userAgent: String? { didSet { if userAgent != oldValue { applyUserAgent() } } }

    init(browser: ChromiumProfile) {
        self.browser = browser
        pageView.page = self
    }

    // MARK: Target

    /// Takes over a page target Chromium made (and paused, waiting for Cosmos): its scripts go in before it runs.
    func attach(targetID: String, sessionID: String, url: URL?) {
        self.targetID = targetID
        self.sessionID = sessionID
        if let url, url.absoluteString != "about:blank" { state.url = url }
        Task { await setUp() }
    }

    private func setUp() async {
        guard let sessionID else { return }
        let c = browser?.connection
        for domain in ["Page.enable", "Runtime.enable"] { _ = try? await c?.send(domain, session: sessionID) }
        c?.post("Page.setLifecycleEventsEnabled", ["enabled": true], session: sessionID)
        c?.post("Page.setInterceptFileChooserDialog", ["enabled": true], session: sessionID)
        // HTTP authentication: Chromium only says a site wants a password for requests it holds, so it holds documents
        // (not images or scripts), which go on at once; a challenge comes to Cosmos.
        c?.post("Fetch.enable", Self.authInterception, session: sessionID)
        c?.post("Runtime.addBinding", ["name": "__cosmosPost", "executionContextName": ChromiumProfile.agentWorld], session: sessionID)
        c?.post("Target.setAutoAttach", Self.frameAttachment, session: sessionID)
        if accessibility != nil { c?.post("Accessibility.enable", session: sessionID) }
        await installScripts(browser?.scripts ?? [])
        applyUserAgent()
        if let tree = try? await c?.send("Page.getFrameTree", session: sessionID),
           let frame = (tree["frameTree"] as? [String: Any])?["frame"] as? [String: Any] {
            mainFrameID = frame["id"] as? String
        }
        c?.post("Runtime.runIfWaitingForDebugger", session: sessionID)
        viewGeometryChanged()
        viewVisibilityChanged()
        let waiting = queued
        queued = []
        waiting.forEach { $0() }
    }

    static let authInterception: [String: Any] = ["patterns": [["urlPattern": "*", "resourceType": "Document", "requestStage": "Request"]],
                                                  "handleAuthRequests": true]
    /// Frames from other sites are held until Cosmos has set them up. A worker left out here never started (Chromium held it
    /// at its start too), so workers are attached as well, only to be let go (`release`).
    static let frameAttachment: [String: Any] = ["autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true,
                                                 "filter": [["type": "iframe"], ["type": "worker"], ["exclude": true]]]

    /// Replaces the scripts every new document gets (agent, Boosts), in the page and in its frames from other sites.
    func installScripts(_ scripts: [PageScript]) async {
        guard let sessionID else { return }
        for session in [sessionID] + frameSessions { await installScripts(scripts, in: session) }
    }

    private func installScripts(_ scripts: [PageScript], in session: String) async {
        guard let c = browser?.connection else { return }
        for id in scriptIDs[session] ?? [] { c.post("Page.removeScriptToEvaluateOnNewDocument", ["identifier": id], session: session) }
        scriptIDs[session] = []
        for script in scripts {
            var params: [String: Any] = ["source": Self.wrap(script), "runImmediately": true]
            if script.world == .agent { params["worldName"] = ChromiumProfile.agentWorld }
            if let r = try? await c.send("Page.addScriptToEvaluateOnNewDocument", params, session: session), let id = r["identifier"] as? String {
                scriptIDs[session, default: []].append(id)
            }
        }
    }

    /// A frame from another site, paused before it runs: it gets the page's scripts, sign-in and frames of its own.
    private func attachFrame(session: String, frame: String?) {
        guard !frameSessions.contains(session) else { return }
        frameSessions.insert(session)
        frameOfSession[session] = frame
        browser?.route(session, to: self)
        Task {
            let c = browser?.connection
            for domain in ["Page.enable", "Runtime.enable"] { _ = try? await c?.send(domain, session: session) }
            c?.post("Fetch.enable", Self.authInterception, session: session)
            c?.post("Runtime.addBinding", ["name": "__cosmosPost", "executionContextName": ChromiumProfile.agentWorld], session: session)
            c?.post("Target.setAutoAttach", Self.frameAttachment, session: session)
            if self.accessibility != nil { c?.post("Accessibility.enable", session: session) }
            await installScripts(browser?.scripts ?? [], in: session)
            c?.post("Runtime.runIfWaitingForDebugger", session: session)
        }
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
        contexts = contexts.filter { $0.key.session != session }
    }

    /// What a frame from another site's session reports: its scripts' worlds, their messages, its documents.
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
        case "Fetch.requestPaused":
            documentPaused(p, session: session)
        case "Fetch.authRequired":
            authRequired(p, session: session)
        default:
            break
        }
    }

    private func contextEvent(_ method: String, _ p: [String: Any], session: String) {
        switch method {
        case "Runtime.executionContextCreated":
            guard let context = p["context"] as? [String: Any], let id = context["id"] as? Int,
                  let aux = context["auxData"] as? [String: Any], let frameID = aux["frameId"] as? String else { return }
            let isAgent = (context["name"] as? String) == ChromiumProfile.agentWorld
            contexts[Context(session: session, id: id)] = (frameID, isAgent, aux["isDefault"] as? Bool ?? false)
            if isAgent && frameID == mainFrameID && session == sessionID { agentContextID = id }
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

    /// An assistive app looked at the page: from now on its accessibility tree is read for it.
    func accessibilityWanted() -> ChromiumAccessibility {
        if let accessibility { return accessibility }
        let made = ChromiumAccessibility(page: self)
        accessibility = made
        for session in frameSessions { browser?.connection?.post("Accessibility.enable", session: session) }
        return made
    }

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

    /// An input event: dropped if the page is not running yet.
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
            guard let frame = p["frame"] as? [String: Any], frame["parentId"] == nil else { return }
            mainFrameID = frame["id"] as? String
            agentContextID = nil
            caretRect = nil
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
            // Chromium drops a page's own zoom when it navigates; it is set again.
            appliedZoom = nil
            if zoom != 1 || needsOwnZoom { appliedMetrics = nil; viewGeometryChanged() }
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
            if failedLoad == nil { delegate?.pageDidFinishLoading(self) }
        case "Fetch.requestPaused":
            if let sessionID { documentPaused(p, session: sessionID) }
        case "Network.requestWillBeSent":
            if (p["type"] as? String) == "Document", let url = ((p["request"] as? [String: Any])?["url"] as? String).flatMap(URL.init(string:)) {
                onDocumentRequest?(url)
            }
        case "Fetch.authRequired":
            if let sessionID { authRequired(p, session: sessionID) }
        case "Accessibility.loadComplete":
            accessibility?.pageLoaded()
        case "Accessibility.nodesUpdated":
            accessibility?.refreshSoon()
        case "Page.javascriptDialogOpening":
            runDialog(p)
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

    private func changed() { delegate?.pageStateDidChange(self) }

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
        var error = Self.loadError(code)
        if let stopped = stoppedDanger, stopped.host == url.host {
            error = PageLoadError(kind: stopped.danger == .malware ? .malware : .phishing, detail: stopped.danger.rawValue)
        }
        stoppedDanger = nil
        delegate?.page(self, didFailLoading: url, error: error)
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
        case "__cursor": pageView.setCursor(message["value"] as? String ?? "default")
        case "__select": showSelectMenu(message, context: key, fromMain: fromMain)
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
                let f = layoutScale
                pip.view.crop = CGRect(x: (x + pip.offset.x) * f, y: (y + pip.offset.y) * f, width: w * f, height: h * f)
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
        case "__caret":
            if fromMain, let x = message["x"] as? Double, let y = message["y"] as? Double, let h = message["height"] as? Double {
                caretRect = CGRect(x: x * zoom, y: (y + h) * zoom, width: 1, height: h * zoom)
            }
        // An error document (Chromium's, then Cosmos's) says nothing about the site: its icons are not the site's to fetch.
        case "meta" where fromMain && failedLoad != nil: break
        default: delegate?.page(self, agentMessage: message, fromMainFrame: fromMain)
        }
    }

    // MARK: Drawing

    var needsOwnZoom: Bool { browser.map { abs(pageView.backingScale - $0.defaultZoomFactor) > 0.01 } ?? false }

    func viewGeometryChanged() {
        guard sessionID != nil, pageView.bounds.width > 0, pageView.bounds.height > 0 else { return }
        accessibility?.refreshSoon()
        let scale = pageView.backingScale
        let width = Int((pageView.bounds.width * scale).rounded()), height = Int((pageView.bounds.height * scale).rounded())
        let factor = Double(scale) * zoom
        if let m = appliedMetrics, m.width == width, m.height == height, m.zoomFactor == factor { return }
        appliedMetrics = (width, height, factor)
        // Chromium lays the page out at `factor` (its browser zoom: the screen's scale times the page's own zoom) in a
        // viewport of the view's size in device pixels, so the frames it sends are sharp on a Retina screen.
        command("Emulation.setDeviceMetricsOverride", ["width": width, "height": height, "deviceScaleFactor": 1, "mobile": false])
        // A zoom of its own, or back to the default after one: Chromium keeps a page's zoom until it is told otherwise.
        if let browser, abs(factor - (appliedZoom ?? browser.defaultZoomFactor)) > 0.001, let targetID {
            browser.setZoom(factor, target: targetID)
            appliedZoom = abs(factor - browser.defaultZoomFactor) > 0.001 ? factor : nil
        }
    }

    func viewVisibilityChanged() {
        // A video in Picture in Picture is seen in its own window, wherever the tab is.
        let showing = pageView.isShowing || pictureInPicture != nil
        guard sessionID != nil, showing != isCasting else { return }
        isCasting = showing
        if showing {
            viewGeometryChanged()
            command("Page.startScreencast", ["format": "jpeg", "quality": 92, "everyNthFrame": 1])
        } else {
            command("Page.stopScreencast")
        }
    }

    private func frame(_ p: [String: Any]) {
        if let ack = p["sessionId"] as? Int { command("Page.screencastFrameAck", ["sessionId": ack]) }
        guard let base64 = p["data"] as? String else { return }
        frameGeneration += 1
        let generation = frameGeneration
        let scale = pageView.backingScale
        decodeQueue.async { [weak self] in
            guard let data = Data(base64Encoded: base64), let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.frameGeneration else { return }
                    self.pageView.show(image, scale: scale)
                    self.pictureInPicture?.view.show(image)
                }
            }
        }
    }

    // MARK: Dialogs, files, menus

    private func runDialog(_ p: [String: Any]) {
        let message = p["message"] as? String ?? ""
        let origin = (p["url"] as? String).flatMap(URL.init(string:))?.host ?? ""
        let kind: PageDialog.Kind = switch p["type"] as? String {
        case "confirm": .confirm
        case "prompt": .prompt(default: p["defaultPrompt"] as? String ?? "")
        case "beforeunload": .beforeUnload
        default: .alert
        }
        Task {
            let answer = await delegate?.page(self, runDialog: PageDialog(kind: kind, message: message, origin: origin)) ?? PageDialog.Answer(accepted: false)
            var params: [String: Any] = ["accept": answer.accepted]
            if let text = answer.text { params["promptText"] = text }
            command("Page.handleJavaScriptDialog", params)
        }
    }

    /// A page or frame about to load (Chromium holds documents for sign-in): it goes on, unless Cosmos says the site is
    /// dangerous, and then nothing is sent to it.
    private func documentPaused(_ p: [String: Any], session: String) {
        guard let id = p["requestId"] as? String else { return }
        let url = ((p["request"] as? [String: Any])?["url"] as? String).flatMap(URL.init(string:))
        if let url, let danger = delegate?.page(self, dangerAt: url) {
            if session == sessionID && isMain(p["frameId"]) { stoppedDanger = (url.host, danger) }
            browser?.connection?.post("Fetch.failRequest", ["requestId": id, "errorReason": "BlockedByClient"], session: session)
            return
        }
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

    private func showSelectMenu(_ m: [String: Any], context: Context, fromMain: Bool) {
        guard let id = m["id"] as? Int, let options = m["options"] as? [[String: Any]] else { return }
        let selected = m["selected"] as? Int ?? -1
        let menu = NSMenu()
        menu.autoenablesItems = false
        var lastGroup: String?
        for (index, option) in options.enumerated() {
            let group = option["group"] as? String
            if group != lastGroup, let group {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                let header = NSMenuItem(title: group, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
            }
            lastGroup = group
            let item = NSMenuItem(title: option["label"] as? String ?? "", action: #selector(SelectMenuTarget.choose(_:)), keyEquivalent: "")
            item.tag = index
            item.isEnabled = !(option["disabled"] as? Bool ?? false)
            item.state = index == selected ? .on : .off
            if group != nil { item.indentationLevel = 1 }
            menu.addItem(item)
        }
        let target = SelectMenuTarget { [weak self] index in
            self?.evaluate("__cosmosChoose(\(id), \(index))", in: context)
        }
        menu.items.forEach { $0.target = target }
        var at = pageView.convert(pageView.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        if fromMain, let x = m["x"] as? Double, let y = m["y"] as? Double { at = CGPoint(x: x * zoom, y: y * zoom) }
        let current = menu.items.first { $0.state == .on }
        _ = withExtendedLifetime(target) {
            menu.popUp(positioning: current, at: at, in: pageView)
        }
        // A menu dismissed without a choice leaves the element as it was.
        evaluate("__cosmosChoose(\(id), -1)", in: context)
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

    private func applyUserAgent() {
        guard sessionID != nil else { return }
        if let userAgent {
            command("Emulation.setUserAgentOverride", ["userAgent": userAgent])
        } else if let original = browser?.userAgent {
            command("Emulation.setUserAgentOverride", ["userAgent": original])
        }
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
        var image = pageView.currentImage
        if image == nil, let r = await request("Page.captureScreenshot", ["format": "jpeg", "quality": 80]),
           let data = (r["data"] as? String).flatMap({ Data(base64Encoded: $0) }), let source = CGImageSourceCreateWithData(data as CFData, nil) {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image, image.width > 0 else { return nil }
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

    /// Opens Chromium's DevTools for the page, or closes them when they are open.
    func showInspector() -> Bool {
        guard targetID != nil else { return false }
        if let inspector, !inspector.isClosed {
            if let d = inspector.delegate { d.pageRequestsClose(inspector) } else { inspector.close() }
            self.inspector = nil
            return true
        }
        Task { await browser?.openInspector(for: self) }
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

    func activate() {
        guard let targetID else { whenReady { [weak self] in self?.activate() }; return }
        browser?.connection?.post("Target.activateTarget", ["targetId": targetID])
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        onClose?()
        queued.removeAll()
        pageView.removeFromSuperview()
        for session in frameSessions { browser?.unroute(session) }
        frameSessions = []
        if let inspector, !inspector.isClosed { if let d = inspector.delegate { d.pageRequestsClose(inspector) } else { inspector.close() } }
        browser?.forget(self)
    }

    /// The browser lost its process: nothing more will come from this page.
    func browserDidStop() {
        isClosed = true
        sessionID = nil
        isCasting = false
        frameSessions = []
        contexts = [:]
        scriptIDs = [:]
    }
}

/// Receives the choice from a `<select>` menu.
private final class SelectMenuTarget: NSObject {
    let chosen: (Int) -> Void
    init(_ chosen: @escaping (Int) -> Void) { self.chosen = chosen }
    @objc func choose(_ sender: NSMenuItem) { chosen(sender.tag) }
}
