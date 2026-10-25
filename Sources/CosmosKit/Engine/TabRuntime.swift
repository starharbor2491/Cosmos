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
    func tabDidChange(_ tab: TabRuntime)
    func tabDidFinishLoading(_ tab: TabRuntime)
    func tabIsPinnedOrFavorite(_ tab: TabRuntime) -> Bool
    func tab(_ tab: TabRuntime, open url: URL, as disposition: LinkDisposition)
    func tab(_ tab: TabRuntime, createChildWith configuration: WKWebViewConfiguration, features: WKWindowFeatures) -> WKWebView?
    func tabRequestsClose(_ tab: TabRuntime)
    func tabRequestsEscape(_ tab: TabRuntime)
    func tab(_ tab: TabRuntime, boostZoomFor host: String) -> Double?
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
    @ObservationIgnored private var context: (link: URL?, image: URL?, selection: String) = (nil, nil, "")
    @ObservationIgnored private var pendingBoostZoom = true
    @ObservationIgnored private var mediaFrames: [String: Bool] = [:]

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
    public func zoomIn() { webView.pageZoom = min(5, webView.pageZoom + 0.1) }
    public func zoomOut() { webView.pageZoom = max(0.25, webView.pageZoom - 0.1) }
    public func resetZoom() { webView.pageZoom = 1 }
    public var zoom: Double { webView.pageZoom }

    public func evaluate(_ js: String, in world: WKContentWorld = .page) {
        webView.evaluateJavaScript(js, in: nil, in: world) { _ in }
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
            self.host?.favicons.update(host: host, candidates: icons.map { (href: $0.0, sizes: $0.1, rel: $0.2) }, pageURL: pageURL)
            themeColor = (body["themeColor"] as? String).flatMap(Self.parseCSSColor)
        case "media":
            let key = (body["frame"] as? String) == "top" ? "top" : "sub-\(fromMainFrame)"
            mediaFrames[key] = (body["playing"] as? Bool) ?? false
            isAudible = mediaFrames.values.contains(true)
            hasPlayingVideo = (body["video"] as? Bool) ?? false
            if !isAudible && !(body["video"] as? Bool ?? false) { hasPlayingVideo = false }
            host?.tabDidChange(self)
        case "context":
            context = ((body["link"] as? String).flatMap(URL.init(string:)), (body["image"] as? String).flatMap(URL.init(string:)), body["selection"] as? String ?? "")
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
        if let link = context.link, let at = insertAfter {
            let peek = NSMenuItem(title: "Open Link in Peek", action: #selector(menuOpenInPeek), keyEquivalent: "")
            peek.target = self
            peek.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
            let split = NSMenuItem(title: "Open Link in Split View", action: #selector(menuOpenInSplit), keyEquivalent: "")
            split.target = self
            split.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
            menu.insertItem(split, at: at + 1)
            menu.insertItem(peek, at: at + 1)
            _ = link
        }
    }

    @objc private func menuOpenInPeek() { if let l = context.link { host?.tab(self, open: l, as: .peek) } }
    @objc private func menuOpenInSplit() { if let l = context.link { host?.tab(self, open: l, as: .split) } }
}

// MARK: - Navigation

extension TabRuntime: WKNavigationDelegate {
    private static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "cosmos", "view-source", "javascript"]

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
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        lastActivity = Date()
        if pendingBoostZoom, let h = webView.url?.host, let z = host?.tab(self, boostZoomFor: h) {
            webView.pageZoom = z
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
        // The renderer crashed or was killed under memory pressure: bring the page back.
        webView.reload()
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
        // Popups from script (OAuth, payment flows) need the opener relationship, so they must use WebKit's configuration.
        return host.tab(self, createChildWith: configuration, features: windowFeatures)
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
        decisionHandler(.prompt)
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

enum ErrorPage {
    static func html(for error: NSError, url: URL) -> String {
        let (headline, detail): (String, String) = {
            switch (error.domain, error.code) {
            case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet), (NSURLErrorDomain, NSURLErrorDataNotAllowed):
                return ("You're out of range", "Cosmos can't reach the internet. Check your connection and try again.")
            case (NSURLErrorDomain, NSURLErrorCannotFindHost), (NSURLErrorDomain, NSURLErrorDNSLookupFailed):
                return ("Lost in space", "We couldn't find a server at “\(url.host ?? url.absoluteString)”. Check the address for typos.")
            case (NSURLErrorDomain, NSURLErrorTimedOut):
                return ("Signal lost", "The server took too long to answer.")
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
