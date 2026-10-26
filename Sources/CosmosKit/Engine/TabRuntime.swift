import AppKit
import WebKit
import CosmosCore

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
    func tab(_ tab: TabRuntime, createChildWith configuration: WKWebViewConfiguration, features: WKWindowFeatures) -> WKWebView?
    func tabRequestsClose(_ tab: TabRuntime)
    func tabRequestsEscape(_ tab: TabRuntime)
    func tab(_ tab: TabRuntime, boostZoomFor host: String) -> Double?
    /// Remembers (or, with `nil`, forgets) what the user answered when a site asked for a permission. `key` is `host|kind`.
    func tab(_ tab: TabRuntime, remember allowed: Bool?, forPermission key: String)
    /// Shows the radial menu for the system menu a page asked for; false leaves the system menu to be drawn.
    func tab(_ tab: TabRuntime, showRadialMenu menu: NSMenu, context: RadialContext, center: CGPoint, windowSize: CGSize) -> Bool
    /// True where there is no room for another window or tab (the menu-bar panel): a link that asks for one loads in place.
    var opensNewWindowsInPlace: Bool { get }
}

public extension TabHost {
    var opensNewWindowsInPlace: Bool { false }
}

/// One live page: owns the `WKWebView`, mirrors its state into observable properties and implements the WebKit
/// delegate duties (navigation policy, popups, dialogs, downloads hand-off, auth).
@MainActor
@Observable
public final class TabRuntime: NSObject {
    public private(set) var itemID: UUID
    /// The profile whose cookies this page uses; `nil` in incognito.
    public let profileID: UUID?
    @ObservationIgnored public let webView: CosmosWebView
    @ObservationIgnored weak var host: TabHost?

    public private(set) var title = ""
    public private(set) var url: URL?
    public private(set) var isLoading = false
    public private(set) var progress = 0.0
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    public private(set) var isAudible = false
    public private(set) var hasPlayingVideo = false
    public private(set) var hoverURL: URL?
    public private(set) var themeColor: RGBA?
    public private(set) var loadFailed = false
    public private(set) var isCapturing = false
    public var isMuted = false { didSet { applyMute() } }
    public var lastActivity = Date()
    /// Set when this runtime is a throwaway (Peek, Probe, popup) rather than a sidebar tab.
    public var isEphemeral = false

    @ObservationIgnored private var observers: [NSKeyValueObservation] = []
    /// What was under the pointer at the last right click (the page agent reports it just before the menu is asked for).
    @ObservationIgnored private(set) var context = PageContext()

    struct PageContext {
        var link: URL?
        var image: URL?
        var selection = ""
        var editable = false
        var media = false
        /// Where the click was, in the page's own pixels from its top-left; only known for the main frame.
        var point: CGPoint?
    }
    @ObservationIgnored private var pendingBoostZoom = true
    @ObservationIgnored private var mediaFrames: [String: Bool] = [:]
    @ObservationIgnored private var crashes = CrashLoopGuard()

    public init(itemID: UUID, profileID: UUID?, configuration: WKWebViewConfiguration, host: TabHost?) {
        self.itemID = itemID
        self.profileID = profileID
        self.host = host
        webView = CosmosWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        webView.runtime = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        observe()
    }

    // MARK: State mirroring

    private func observe() {
        func watch<V>(_ kp: KeyPath<WKWebView, V>, _ apply: @escaping (TabRuntime) -> Void) {
            observers.append((webView as WKWebView).observe(kp, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { if let self { apply(self); self.host?.tabDidChange(self) } }
            })
        }
        watch(\.title) { $0.title = $0.webView.title ?? "" }
        watch(\.url) { $0.url = $0.webView.url }
        watch(\.isLoading) { $0.isLoading = $0.webView.isLoading }
        watch(\.estimatedProgress) { $0.progress = $0.webView.estimatedProgress }
        watch(\.canGoBack) { $0.canGoBack = $0.webView.canGoBack }
        watch(\.canGoForward) { $0.canGoForward = $0.webView.canGoForward }
        watch(\.cameraCaptureState) { $0.isCapturing = $0.webView.cameraCaptureState == .active || $0.webView.microphoneCaptureState == .active }
        watch(\.microphoneCaptureState) { $0.isCapturing = $0.webView.cameraCaptureState == .active || $0.webView.microphoneCaptureState == .active }
    }

    // MARK: Commands

    public func load(_ url: URL) {
        loadFailed = false
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    public func reload(fromOrigin: Bool = false) {
        loadFailed = false
        if fromOrigin { webView.reloadFromOrigin() } else { webView.reload() }
    }
    public func stop() { webView.stopLoading() }
    public func goBack() { webView.goBack() }
    public func goForward() { webView.goForward() }
    /// The range ⌘+ and ⌘- keep to; a zoom read from a Boost file is held to it too.
    static func clampedZoom(_ z: Double) -> Double { z.isFinite ? min(5, max(0.25, z)) : 1 }

    public func zoomIn() { webView.pageZoom = min(5, webView.pageZoom + 0.1) }
    public func zoomOut() { webView.pageZoom = max(0.25, webView.pageZoom - 0.1) }
    public func resetZoom() { webView.pageZoom = 1 }
    public var zoom: Double { webView.pageZoom }

    public func evaluate(_ js: String, in world: WKContentWorld? = nil) {
        webView.evaluateJavaScript(js, in: nil, in: world ?? .page) { _ in }
    }

    public func find(_ text: String, backwards: Bool = false, completion: @escaping (Bool) -> Void) {
        guard !text.isEmpty else { completion(false); return }
        let cfg = WKFindConfiguration()
        cfg.backwards = backwards
        cfg.wraps = true
        cfg.caseSensitive = false
        webView.find(text, configuration: cfg) { completion($0.matchFound) }
    }

    public func clearFind() {
        evaluate("window.getSelection().removeAllRanges()")
        // WebKit keeps the yellow find indicator until told to hide it.
        let hide = NSSelectorFromString("_hideFindUI")
        if webView.responds(to: hide) { _ = webView.perform(hide) }
    }

    private func applyMute() {
        evaluate("window.__cosmosMute && window.__cosmosMute(\(isMuted))", in: .defaultClient)
    }

    /// Moves the playing video into Picture-in-Picture (used when the user leaves the tab).
    public func enterPictureInPicture() {
        let js = """
        (async () => {
          const vids = [...document.querySelectorAll('video')].filter(v => !v.paused && !v.ended && v.readyState > 2 && !v.disablePictureInPicture);
          vids.sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight);
          const v = vids[0];
          if (!v || document.pictureInPictureElement === v) return;
          try { await v.requestPictureInPicture(); }
          catch (e) { if (v.webkitSetPresentationMode) v.webkitSetPresentationMode('picture-in-picture'); }
        })();
        """
        evaluate(js)
    }

    public func exitPictureInPicture() {
        evaluate("if (document.pictureInPictureElement) document.exitPictureInPicture().catch(()=>{}); document.querySelectorAll('video').forEach(v => { if (v.webkitPresentationMode === 'picture-in-picture') v.webkitSetPresentationMode('inline'); });")
    }

    public func takeSnapshot(width: CGFloat = 320, completion: @escaping (NSImage?) -> Void) {
        let cfg = WKSnapshotConfiguration()
        cfg.snapshotWidth = NSNumber(value: Double(width))
        webView.takeSnapshot(with: cfg) { image, _ in completion(image) }
    }

    /// Turns a throwaway page (Peek) into the page of a sidebar tab.
    func adopt(itemID: UUID) { self.itemID = itemID }

    /// Detaches delegates and stops the page so the runtime can be released.
    public func tearDown() {
        observers.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.runtime = nil
        webView.removeFromSuperview()
    }

    // MARK: Agent messages

    func handleAgentMessage(_ body: [String: Any], fromMainFrame: Bool) {
        switch body["type"] as? String {
        case "meta":
            guard fromMainFrame, let pageURL = webView.url, let host = pageURL.host else { return }
            let icons = (body["icons"] as? [[String: Any]] ?? []).compactMap { d -> (URL, String, String)? in
                guard let href = (d["href"] as? String).flatMap(URL.init(string:)), href.scheme == "https" || href.scheme == "http" || href.scheme == "data" else { return nil }
                return (href, d["sizes"] as? String ?? "", d["rel"] as? String ?? "")
            }
            self.host?.favicons.update(host: host, candidates: icons.map { FaviconStore.Candidate(href: $0.0, sizes: $0.1, rel: $0.2) }, pageURL: pageURL)
            themeColor = (body["themeColor"] as? String).flatMap(Self.parseCSSColor)
        case "peekLink":
            guard let href = (body["href"] as? String).flatMap(URL.init(string:)), ["http", "https"].contains(href.scheme?.lowercased() ?? "") else { break }
            host?.tab(self, open: href, as: .peek)
        case "media":
            let key = (body["frame"] as? String) == "top" ? "top" : "sub-\(fromMainFrame)"
            mediaFrames[key] = (body["playing"] as? Bool) ?? false
            isAudible = mediaFrames.values.contains(true)
            hasPlayingVideo = (body["video"] as? Bool) ?? false
            if !isAudible && !(body["video"] as? Bool ?? false) { hasPlayingVideo = false }
            host?.tabDidChange(self)
        case "context":
            var next = PageContext(link: (body["link"] as? String).flatMap(URL.init(string:)), image: (body["image"] as? String).flatMap(URL.init(string:)),
                                   selection: body["selection"] as? String ?? "", editable: body["editable"] as? Bool ?? false, media: body["media"] as? Bool ?? false)
            if fromMainFrame, let x = body["x"] as? Double, let y = body["y"] as? Double, x.isFinite, y.isFinite { next.point = CGPoint(x: x, y: y) }
            context = next
        case "hover":
            hoverURL = (body["href"] as? String).flatMap(URL.init(string:))
        case "escape":
            host?.tabRequestsEscape(self)
        default: break
        }
    }

    static func parseCSSColor(_ s: String) -> RGBA? {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.hasPrefix("#") else { return nil }
        t.removeFirst()
        if t.count == 3 { t = t.map { "\($0)\($0)" }.joined() }
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        return RGBA(hex: v)
    }

    // MARK: Context menu

    func customiseContextMenu(_ menu: NSMenu) {
        var insertAfter: Int?
        for (i, item) in menu.items.enumerated() {
            switch item.webKitIdentifier {
            case "WKMenuItemIdentifierOpenLinkInNewWindow": item.title = "Open Link in New Tab"; insertAfter = i
            case "WKMenuItemIdentifierOpenImageInNewWindow": item.title = "Open Image in New Tab"
            case "WKMenuItemIdentifierOpenFrameInNewWindow": item.title = "Open Frame in New Tab"
            default: break
            }
        }
        if context.link != nil, let at = insertAfter {
            // The link is carried on the item, not read from the page context when the item runs: the ring can be open
            // while the page moves on.
            let peek = NSMenuItem(title: "Open Link in Peek", action: #selector(menuOpenInPeek(_:)), keyEquivalent: "")
            peek.target = self
            peek.representedObject = context.link
            peek.identifier = NSUserInterfaceItemIdentifier("cosmos.openLinkInPeek")
            peek.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
            let split = NSMenuItem(title: "Open Link in Split View", action: #selector(menuOpenInSplit(_:)), keyEquivalent: "")
            split.target = self
            split.representedObject = context.link
            split.identifier = NSUserInterfaceItemIdentifier("cosmos.openLinkInSplit")
            split.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
            menu.insertItem(split, at: at + 1)
            menu.insertItem(peek, at: at + 1)
        }
    }

    /// Puts the radial menu up in place of the system menu, if the settings, the site and the window allow it. Returns
    /// whether it did, in which case the caller cancels the system menu. Holding ⌥ on the click asks for the system menu.
    func presentRadialMenu(_ menu: NSMenu) -> Bool {
        let click = webView.recentClick()
        let modifiers = click?.modifiers ?? NSEvent.modifierFlags
        // In element fullscreen (a video taking the screen) the page lives in a window of WebKit's own and the ring would be
        // drawn in the browser window behind it, so the system menu stays.
        guard let host, let window = webView.window, webView.fullscreenState == .notInFullscreen,
              !modifiers.contains(.option), !NSWorkspace.shared.isVoiceOverEnabled else { return false }
        let kind = RadialContext.detect(link: context.link != nil, image: context.image != nil, selection: !context.selection.isEmpty,
                                        editable: context.editable, media: context.media)
        // Where the pointer is, in the window's space with y down. The click says so itself; for a menu that came from
        // the keyboard it is the page's report of where it was (only trustworthy when the view is not pinched), and
        // failing that wherever the mouse is.
        var windowPoint = window.mouseLocationOutsideOfEventStream
        if let click {
            windowPoint = click.location
        } else if let p = context.point, webView.magnification == 1 {
            let zoom = webView.pageZoom
            windowPoint = webView.convert(NSPoint(x: p.x * zoom, y: webView.isFlipped ? p.y * zoom : webView.bounds.height - p.y * zoom), to: nil)
        }
        let size = window.contentView?.bounds.size ?? window.frame.size
        return host.tab(self, showRadialMenu: menu, context: kind, center: CGPoint(x: windowPoint.x, y: size.height - windowPoint.y), windowSize: size)
    }

    @objc private func menuOpenInPeek(_ sender: NSMenuItem) { if let l = sender.representedObject as? URL { host?.tab(self, open: l, as: .peek) } }
    @objc private func menuOpenInSplit(_ sender: NSMenuItem) { if let l = sender.representedObject as? URL { host?.tab(self, open: l, as: .split) } }
}

// MARK: - Navigation

extension TabRuntime: WKNavigationDelegate {
    private static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "cosmos", "view-source", "javascript", "webkit-extension"]

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow, preferences); return }
        let scheme = url.scheme?.lowercased() ?? ""
        let flags = navigationAction.modifierFlags

        // Links that belong to other apps (mailto:, tel:, zoommtg:, slack: ...).
        if !Self.webSchemes.contains(scheme) {
            if navigationAction.navigationType == .linkActivated || navigationAction.sourceFrame.isMainFrame {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel, preferences)
            return
        }
        if navigationAction.shouldPerformDownload { decisionHandler(.download, preferences); return }

        if navigationAction.navigationType == .linkActivated, scheme == "http" || scheme == "https" {
            // ⌘-click: background tab, ⇧⌘-click: foreground tab, ⇧-click: Peek, ⌥-click: download.
            if flags.contains(.command) {
                host?.tab(self, open: url, as: flags.contains(.shift) ? .newTabForeground : .newTabBackground)
                decisionHandler(.cancel, preferences); return
            }
            if flags.contains(.shift) { host?.tab(self, open: url, as: .peek); decisionHandler(.cancel, preferences); return }
            if flags.contains(.option) { host?.tab(self, open: url, as: .download); decisionHandler(.cancel, preferences); return }
            // Pinned tabs and Favorites keep their place: a link to another site opens in Peek.
            if navigationAction.targetFrame?.isMainFrame ?? false, let host,
               host.settings.peekFromPinned, host.tabIsPinnedOrFavorite(self),
               let current = webView.url, !PublicSuffixList.shared.isSameSite(current, url) {
                host.tab(self, open: url, as: .peek)
                decisionHandler(.cancel, preferences); return
            }
        }
        if navigationAction.targetFrame?.isMainFrame ?? true, let host {
            ContentBlockerController.configure(preferences, for: url, settings: host.settings)
        }
        decisionHandler(.allow, preferences)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(), disposition.hasPrefix("attachment") {
            decisionHandler(.download); return
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        if let host { download.delegate = host.downloads; host.downloads.began(download, from: webView) }
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        if let host { download.delegate = host.downloads; host.downloads.began(download, from: webView) }
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadFailed = false
        mediaFrames.removeAll()
        isAudible = false
        hoverURL = nil
        pendingBoostZoom = true
        // What was under the pointer on the last page says nothing about this one (a PDF or an error page has no agent
        // to report its own).
        context = PageContext()
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        lastActivity = Date()
        if pendingBoostZoom, let h = webView.url?.host, let z = host?.tab(self, boostZoomFor: h) {
            webView.pageZoom = Self.clampedZoom(z)
        }
        pendingBoostZoom = false
        if isMuted { applyMute() }
        host?.tabDidChange(self)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        host?.tabDidFinishLoading(self)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        presentError(error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        presentError(error)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The renderer crashed or was killed under memory pressure: bring the page back, unless it keeps happening.
        switch crashes.decide(at: Date()) {
        case .reload:
            webView.reload()
        case .showError:
            let failing = webView.url ?? URL(string: "about:blank")!
            let error = NSError(domain: ErrorPage.crashDomain, code: 1, userInfo: [NSURLErrorFailingURLErrorKey: failing])
            loadFailed = true
            webView.loadHTMLString(ErrorPage.html(for: error, url: failing), baseURL: failing)
        case .ignore:
            break
        }
    }

    public func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest || method == NSURLAuthenticationMethodNTLM else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let alert = NSAlert()
        alert.messageText = "Sign in to \(challenge.protectionSpace.host)"
        alert.informativeText = challenge.protectionSpace.realm.map { "The site says: “\($0)”" } ?? "This site requires a username and password."
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        stack.orientation = .vertical
        stack.spacing = 6
        let user = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); user.placeholderString = "Username"
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); pass.placeholderString = "Password"
        stack.addArrangedSubview(user); stack.addArrangedSubview(pass)
        alert.accessoryView = stack
        let respond: (NSApplication.ModalResponse) -> Void = { r in
            if r == .alertFirstButtonReturn {
                completionHandler(.useCredential, URLCredential(user: user.stringValue, password: pass.stringValue, persistence: .forSession))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
        if let window = webView.window { alert.beginSheetModal(for: window, completionHandler: respond) } else { respond(alert.runModal()) }
    }

    private func presentError(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain", ns.code == 102 || ns.code == 101 { return }   // frame load interrupted by a download / policy change
        guard let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url else { return }
        loadFailed = true
        webView.loadHTMLString(ErrorPage.html(for: ns, url: failing), baseURL: failing)
    }
}

// MARK: - UI delegate

extension TabRuntime: WKUIDelegate {
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let host else { return nil }
        if Self.loadsNewWindowInPlace(hostOpensInPlace: host.opensNewWindowsInPlace, features: windowFeatures) {
            if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { load(url) }
            return nil
        }
        // Popups from script (OAuth, payment flows) need the opener relationship, so they must use WebKit's configuration.
        return host.tab(self, createChildWith: configuration, features: windowFeatures)
    }

    /// A page that asks for a script-sized window (an OAuth sign-in, a payment sheet) needs its opener, so it must get a
    /// real window; every other new-window request loads where it is when the host has no room for another window.
    static func isScriptSizedPopup(_ features: WKWindowFeatures) -> Bool { features.width != nil || features.height != nil }

    static func loadsNewWindowInPlace(hostOpensInPlace: Bool, features: WKWindowFeatures) -> Bool {
        hostOpensInPlace && !isScriptSizedPopup(features)
    }

    public func webViewDidClose(_ webView: WKWebView) { host?.tabRequestsClose(self) }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping @MainActor () -> Void) {
        let alert = dialog(message: message, frame: frame, buttons: ["OK"])
        present(alert) { _ in completionHandler() }
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = dialog(message: message, frame: frame, buttons: ["OK", "Cancel"])
        present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        let alert = dialog(message: prompt, frame: frame, buttons: ["OK", "Cancel"])
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        present(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        let finish: (NSApplication.ModalResponse) -> Void = { completionHandler($0 == .OK ? panel.urls : nil) }
        if let window = webView.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                        type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        let (kind, noun): (String, String) = {
            switch type {
            case .camera: return ("camera", "camera")
            case .microphone: return ("microphone", "microphone")
            case .cameraAndMicrophone: return ("cameraAndMicrophone", "camera and microphone")
            @unknown default: return ("media", "camera or microphone")
            }
        }()
        let site = origin.host
        let key = "\(site)|\(kind)"
        if !site.isEmpty, let known = host?.settings.permissionDecisions[key] {
            decisionHandler(known ? .grant : .deny)
            return
        }
        let alert = NSAlert()
        alert.messageText = site.isEmpty ? "This page wants to use your \(noun)" : "“\(site)” wants to use your \(noun)"
        alert.informativeText = site.isEmpty ? "" : "Cosmos remembers your answer for this site. You can change it from the Site Controls panel."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        present(alert) { [weak self] response in
            let allowed = response == .alertFirstButtonReturn
            if !site.isEmpty, let self { self.host?.tab(self, remember: allowed, forPermission: key) }
            decisionHandler(allowed ? .grant : .deny)
        }
    }

    private func dialog(message: String, frame: WKFrameInfo, buttons: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page says"
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert
    }

    private func present(_ alert: NSAlert, _ done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = webView.window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
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
    /// The domain of the error shown when a page's renderer keeps dying.
    static let crashDomain = "CosmosPageCrash"

    static func html(for error: NSError, url: URL) -> String {
        let (headline, detail): (String, String) = {
            switch (error.domain, error.code) {
            case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet), (NSURLErrorDomain, NSURLErrorDataNotAllowed):
                return ("You're out of range", "Cosmos can't reach the internet. Check your connection and try again.")
            case (NSURLErrorDomain, NSURLErrorCannotFindHost), (NSURLErrorDomain, NSURLErrorDNSLookupFailed):
                return ("Lost in space", "We couldn't find a server at “\(url.host ?? url.absoluteString)”. Check the address for typos.")
            case (NSURLErrorDomain, NSURLErrorTimedOut):
                return ("Signal lost", "The server took too long to answer.")
            case (crashDomain, _):
                return ("This page keeps crashing", "It stopped responding several times in a row, so Cosmos stopped reloading it. Try again in a moment.")
            case (NSURLErrorDomain, NSURLErrorCannotConnectToHost), (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
                return ("Connection lost", "The server isn't accepting connections right now.")
            case (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted), (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate),
                 (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot), (NSURLErrorDomain, NSURLErrorSecureConnectionFailed),
                 (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid), (NSURLErrorDomain, NSURLErrorClientCertificateRejected):
                return ("This connection isn't private", "Cosmos couldn't verify the identity of “\(url.host ?? "this site")”. Someone may be trying to intercept your connection.")
            default:
                return ("This page can't be reached", error.localizedDescription)
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
        a.button { display: inline-block; padding: 9px 20px; border-radius: 999px; background: #8b6cff; color: white; text-decoration: none; font-weight: 600; }
        a.button:hover { background: #a08aff; }
        @media (prefers-color-scheme: light) { body { color: #1d1b33; background: radial-gradient(1200px 700px at 70% 10%, #e6defc 0%, #f4f1fb 60%, #fff 100%); } }
        </style></head><body><main>
        <svg viewBox="0 0 120 120" fill="none"><circle cx="60" cy="60" r="26" fill="#8b6cff"/><ellipse cx="60" cy="60" rx="52" ry="14" transform="rotate(-20 60 60)" stroke="#c9bdff" stroke-width="3" opacity=".8"/>
        <circle cx="96" cy="34" r="4" fill="#fff"/><circle cx="22" cy="86" r="2.5" fill="#fff" opacity=".7"/><circle cx="104" cy="88" r="2" fill="#fff" opacity=".5"/></svg>
        <h1>\(esc(headline))</h1><p>\(esc(detail))</p>
        <a class="button" href="javascript:location.reload()">Try Again</a>
        <code>\(esc(url.absoluteString))<br>\(esc(error.domain)) \(error.code)</code></main></body></html>
        """
    }
}
