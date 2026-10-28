import AppKit
import CosmosEngine

/// One Chromium tab: a page target in the profile's Chromium, driven over the DevTools protocol and drawn by
/// `ChromiumPageView`.
@MainActor
final class ChromiumPage: EnginePage {
    unowned let browser: ChromiumProfile
    let pageView = ChromiumPageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    var view: NSView { pageView }
    weak var delegate: EnginePageDelegate?
    private(set) var state = PageState()

    private(set) var targetID: String?
    private(set) var sessionID: String?
    private var isClosed = false
    /// Commands made before the target exists wait here.
    private var queued: [() -> Void] = []
    private var mainFrameID: String?
    /// Execution context ids: Cosmos's world of the main frame, and every context's frame and world.
    private var agentContextID: Int?
    private var contexts: [Int: (frameID: String, isAgent: Bool, isDefault: Bool)] = [:]
    private var scriptIDs: [String] = []
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
        let c = browser.connection
        for domain in ["Page.enable", "Runtime.enable"] { _ = try? await c?.send(domain, session: sessionID) }
        c?.post("Page.setLifecycleEventsEnabled", ["enabled": true], session: sessionID)
        c?.post("Page.setInterceptFileChooserDialog", ["enabled": true], session: sessionID)
        c?.post("Runtime.addBinding", ["name": "__cosmosPost", "executionContextName": ChromiumProfile.agentWorld], session: sessionID)
        await installScripts(browser.scripts)
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

    /// Replaces the scripts every new document gets (agent, Boosts).
    func installScripts(_ scripts: [PageScript]) async {
        guard let sessionID, let c = browser.connection else { return }
        for id in scriptIDs { c.post("Page.removeScriptToEvaluateOnNewDocument", ["identifier": id], session: sessionID) }
        scriptIDs = []
        for script in scripts {
            var params: [String: Any] = ["source": Self.wrap(script), "runImmediately": true]
            if script.world == .agent { params["worldName"] = ChromiumProfile.agentWorld }
            if let r = try? await c.send("Page.addScriptToEvaluateOnNewDocument", params, session: sessionID), let id = r["identifier"] as? String {
                scriptIDs.append(id)
            }
        }
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
            self.browser.connection?.post(method, params, session: sessionID)
        }
    }

    private func request(_ method: String, _ params: [String: Any] = [:]) async -> [String: Any]? {
        if sessionID == nil {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                if isClosed { c.resume() } else { queued.append { c.resume() } }
            }
        }
        guard let sessionID else { return nil }
        return try? await browser.connection?.send(method, params, session: sessionID)
    }

    /// An input event: dropped if the page is not running yet.
    func input(_ method: String, _ params: [String: Any]) {
        guard let sessionID else { return }
        browser.connection?.post(method, params, session: sessionID)
    }

    func runEditingCommand(_ commands: [String]) {
        guard !commands.isEmpty else { return }
        input("Input.dispatchKeyEvent", ["type": "rawKeyDown", "key": "", "code": "", "windowsVirtualKeyCode": 0, "commands": commands])
        input("Input.dispatchKeyEvent", ["type": "keyUp", "key": "", "code": "", "windowsVirtualKeyCode": 0])
    }

    // MARK: Events

    func handle(_ event: CDPEvent) {
        let p = event.params
        switch event.method {
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
            if let unreachable = (frame["unreachableUrl"] as? String).flatMap(URL.init(string:)) {
                state.url = unreachable
                failedLoad = unreachable
                Task { await reportFailure(unreachable) }
            } else if let url = (frame["url"] as? String).flatMap(URL.init(string:)) {
                state.url = url
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
        case "Page.javascriptDialogOpening":
            runDialog(p)
        case "Page.fileChooserOpened":
            chooseFiles(p)
        case "Page.windowOpen":
            lastWindowOpen = NewPageRequest(url: (p["url"] as? String).flatMap(URL.init(string:)), features: p["windowFeatures"] as? [String] ?? [],
                                            userGesture: p["userGesture"] as? Bool ?? false)
        case "Page.screencastFrame":
            frame(p)
        case "Runtime.executionContextCreated":
            guard let context = p["context"] as? [String: Any], let id = context["id"] as? Int,
                  let aux = context["auxData"] as? [String: Any], let frameID = aux["frameId"] as? String else { return }
            let isAgent = (context["name"] as? String) == ChromiumProfile.agentWorld
            contexts[id] = (frameID, isAgent, aux["isDefault"] as? Bool ?? false)
            if isAgent && frameID == mainFrameID { agentContextID = id }
        case "Runtime.executionContextDestroyed":
            if let id = p["executionContextId"] as? Int { contexts[id] = nil; if agentContextID == id { agentContextID = nil } }
        case "Runtime.executionContextsCleared":
            contexts.removeAll()
            agentContextID = nil
        case "Runtime.bindingCalled":
            binding(p)
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

    private func binding(_ p: [String: Any]) {
        guard (p["name"] as? String) == "__cosmosPost", let payload = p["payload"] as? String,
              let message = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return }
        let contextID = p["executionContextId"] as? Int
        let context = contextID.flatMap { contexts[$0] }
        // Only Cosmos's own world can call the binding; a message from anywhere else is ignored.
        guard let context, context.isAgent else { return }
        let fromMain = context.frameID == mainFrameID
        switch message["type"] as? String {
        case "__cursor": pageView.setCursor(message["value"] as? String ?? "default")
        case "__select": if let contextID { showSelectMenu(message, contextID: contextID, fromMain: fromMain) }
        case "__fullscreen": setElementFullscreen(message["value"] as? Bool ?? false)
        case "__title": if fromMain { setTitle(message["value"] as? String ?? "", url: state.url?.absoluteString ?? "") }
        case "__caret":
            if fromMain, let x = message["x"] as? Double, let y = message["y"] as? Double, let h = message["height"] as? Double {
                caretRect = CGRect(x: x * zoom, y: (y + h) * zoom, width: 1, height: h * zoom)
            }
        default: delegate?.page(self, agentMessage: message, fromMainFrame: fromMain)
        }
    }

    // MARK: Drawing

    var needsOwnZoom: Bool { abs(pageView.backingScale - browser.defaultZoomFactor) > 0.01 }

    func viewGeometryChanged() {
        guard sessionID != nil, pageView.bounds.width > 0, pageView.bounds.height > 0 else { return }
        let scale = pageView.backingScale
        let width = Int((pageView.bounds.width * scale).rounded()), height = Int((pageView.bounds.height * scale).rounded())
        let factor = Double(scale) * zoom
        if let m = appliedMetrics, m.width == width, m.height == height, m.zoomFactor == factor { return }
        appliedMetrics = (width, height, factor)
        // Chromium lays the page out at `factor` (its browser zoom: the screen's scale times the page's own zoom) in a
        // viewport of the view's size in device pixels, so the frames it sends are sharp on a Retina screen.
        command("Emulation.setDeviceMetricsOverride", ["width": width, "height": height, "deviceScaleFactor": 1, "mobile": false])
        // A zoom of its own, or back to the default after one: Chromium keeps a page's zoom until it is told otherwise.
        if abs(factor - (appliedZoom ?? browser.defaultZoomFactor)) > 0.001, let targetID {
            browser.setZoom(factor, target: targetID)
            appliedZoom = abs(factor - browser.defaultZoomFactor) > 0.001 ? factor : nil
        }
    }

    func viewVisibilityChanged() {
        let showing = pageView.isShowing
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

    private func chooseFiles(_ p: [String: Any]) {
        guard let node = p["backendNodeId"] as? Int else { return }
        let multiple = (p["mode"] as? String) == "selectMultiple"
        Task {
            let urls = await delegate?.page(self, chooseFiles: FileChooser(allowsMultiple: multiple, allowsDirectories: false))
            guard let urls, !urls.isEmpty else { return }
            command("DOM.setFileInputFiles", ["files": urls.map(\.path), "backendNodeId": node])
        }
    }

    private func showSelectMenu(_ m: [String: Any], contextID: Int, fromMain: Bool) {
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
            self?.command("Runtime.evaluate", ["expression": "__cosmosChoose(\(id), \(index))", "contextId": contextID])
        }
        menu.items.forEach { $0.target = target }
        var at = pageView.convert(pageView.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        if fromMain, let x = m["x"] as? Double, let y = m["y"] as? Double { at = CGPoint(x: x * zoom, y: y * zoom) }
        let current = menu.items.first { $0.state == .on }
        _ = withExtendedLifetime(target) {
            menu.popUp(positioning: current, at: at, in: pageView)
        }
        // A menu dismissed without a choice leaves the element as it was.
        command("Runtime.evaluate", ["expression": "__cosmosChoose(\(id), -1)", "contextId": contextID])
    }

    private func setElementFullscreen(_ on: Bool) {
        isInElementFullscreen = on
        guard let window = pageView.window, window.styleMask.contains(.fullScreen) != on else { return }
        window.toggleFullScreen(nil)
    }

    // MARK: EnginePage

    func load(_ url: URL) {
        failedLoad = nil
        command("Page.navigate", ["url": url.absoluteString])
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
        } else if let original = browser.userAgent {
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

    func download(_ url: URL) { browser.download(url, from: self) }

    func recentContextClick() -> ContextClick? { pageView.recentContextClick() }

    func forceClicked() { delegate?.pageDidForceClick(self) }

    func showInspector() -> Bool { false }

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
        browser.connection?.post("Target.activateTarget", ["targetId": targetID])
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        queued.removeAll()
        pageView.removeFromSuperview()
        browser.forget(self)
    }

    /// The browser lost its process: nothing more will come from this page.
    func browserDidStop() {
        isClosed = true
        sessionID = nil
        isCasting = false
    }
}

/// Receives the choice from a `<select>` menu.
private final class SelectMenuTarget: NSObject {
    let chosen: (Int) -> Void
    init(_ chosen: @escaping (Int) -> Void) { self.chosen = chosen }
    @objc func choose(_ sender: NSMenuItem) { chosen(sender.tag) }
}
