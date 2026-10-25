import Foundation
import Testing
@testable import CosmosBlocking

#if canImport(WebKit) && canImport(AppKit)
import AppKit
import Network
import WebKit

/// Opt-in: loads real pages in a `WKWebView` with lists compiled by this module, served from an in-process HTTP
/// server, and checks which requests reach the network and which elements are hidden. It confirms that the generated
/// expressions mean what Adblock Plus syntax means once WebKit evaluates them (host anchors, separators, third-party,
/// `*domain` matching, top-level navigation guards, exceptions, cosmetic exemptions).
///
///     COSMOS_VERIFY_WEBKIT=1 scripts/test.sh --filter WebKitBehaviorTests
///
/// `localhost`, `sub.localhost` and `127.0.0.1` stand in for different sites; all resolve to the local server.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["COSMOS_VERIFY_WEBKIT"] == "1"))
struct WebKitBehaviorTests {
    struct Scenario: Sendable, CustomTestStringConvertible {
        var name: String
        var rules = ""
        var rawJSON: String?
        var host = "localhost"
        var path = "/page.html"
        /// Resources (of `TestServer.resources`) that must not reach the server.
        var blocked: Set<String> = []
        var expectMainLoaded = true
        var js: [JSCheck] = []
        /// `window.open` this path (on the other host) after the page loaded, and say whether it may reach the server.
        var popup: String?
        var popupAllowed = false
        var testDescription: String { name }
        struct JSCheck: Sendable { var expression: String; var expected: String }
    }

    private static func display(_ id: String) -> String { "getComputedStyle(document.getElementById('\(id)')).display" }
    private static let img3p = "/ads/img3p.gif", img1p = "/ads/img1p.gif", js3p = "/js/tracker3p.js", js1p = "/js/tracker1p.js"
    private static let frame3p = "/frame3p.html", frame1p = "/frame1p.html", fetch3p = "/api/fetch3p", xhr1p = "/api/xhr1p"
    private static let allResources = Set(TestServer.resources)
    private static let thirdPartyHost: Set<String> = [img3p, js3p, frame3p, fetch3p]

    static let scenarios: [Scenario] = [
        Scenario(name: "||host^ blocks every request to that host, whatever the type", rules: "||127.0.0.1^", blocked: thirdPartyHost),
        Scenario(name: "||host^ needs a label boundary: ||ocalhost^ matches nothing", rules: "||ocalhost^"),
        Scenario(name: "||host^ works from the other side", rules: "||localhost^", host: "127.0.0.1", blocked: thirdPartyHost),
        Scenario(name: "plain substring", rules: "/ads/img", blocked: [img3p, img1p]),
        Scenario(name: "$third-party", rules: "/ads/*$third-party", blocked: [img3p]),
        Scenario(name: "$~third-party", rules: "/ads/*$~third-party", blocked: [img1p]),
        Scenario(name: "$script", rules: "/js/*$script", blocked: [js3p, js1p]),
        Scenario(name: "$image leaves scripts alone", rules: "/js/*$image"),
        Scenario(name: "$subdocument", rules: "/frame$subdocument", blocked: [frame3p, frame1p]),
        Scenario(name: "$image leaves frames alone", rules: "/frame$image"),
        Scenario(name: "$xhr covers XHR and fetch", rules: "/api/*$xhr", blocked: [fetch3p, xhr1p]),
        Scenario(name: "$image leaves XHR alone", rules: "/api/*$image"),
        Scenario(name: "default types cover scripts, images, frames and XHR", rules: "/ads/*\n/js/*\n/frame\n/api/*", blocked: allResources),
        Scenario(name: "$~image means every default type except images", rules: "/js/*$~image", blocked: [js3p, js1p]),
        Scenario(name: "$~script", rules: "/js/*$~script\n/ads/*$~script", blocked: [img3p, img1p]),
        Scenario(name: "exception cancels a block", rules: "/ads/*\n@@/ads/img1p.gif", blocked: [img3p]),
        Scenario(name: "exception written before the block still wins", rules: "@@/ads/img1p.gif\n/ads/*", blocked: [img3p]),
        Scenario(name: "$important beats an exception", rules: "/ads/img1p.gif$important\n@@/ads/img1p.gif", blocked: [img1p]),
        Scenario(name: "$domain include matches the page", rules: "/ads/img3p.gif$domain=localhost", blocked: [img3p]),
        Scenario(name: "$domain include ignores other pages", rules: "/ads/img1p.gif$domain=localhost", host: "127.0.0.1"),
        Scenario(name: "$domain include covers subdomains of the page", rules: "/ads/img3p.gif$domain=localhost", host: "sub.localhost", blocked: [img3p]),
        Scenario(name: "$domain=~x skips the page", rules: "/ads/*$domain=~localhost"),
        Scenario(name: "$domain=~x applies elsewhere", rules: "/ads/img1p.gif$domain=~localhost", host: "127.0.0.1", blocked: [img1p]),
        Scenario(name: "$domain=a|~sub.a allows the excluded subdomain", rules: "/ads/img3p.gif$domain=localhost|~sub.localhost", host: "sub.localhost"),
        Scenario(name: "$domain=a|~sub.a still blocks on a", rules: "/ads/img3p.gif$domain=localhost|~sub.localhost", blocked: [img3p]),
        Scenario(name: "$match-case is case sensitive", rules: "/ADS/IMG3P.GIF$match-case"),
        Scenario(name: "matching is case insensitive by default", rules: "/ADS/IMG3P.GIF", blocked: [img3p]),
        Scenario(name: "| anchors with a wildcard port", rules: "|http://localhost:*/ads/img1p.gif|", blocked: [img1p]),
        Scenario(name: "trailing ^ matches the end of a path", rules: "/js/tracker3p.js^", blocked: [js3p]),
        Scenario(name: "^ does not match a letter", rules: "/js/tracker3p^"),
        Scenario(name: "@@||site^$document exempts the whole page", rules: "/ads/*\n/js/*\n@@||localhost^$document"),
        Scenario(name: "@@||site^$document leaves other sites blocked", rules: "/ads/*\n@@||localhost^$document", host: "127.0.0.1", blocked: [img3p, img1p]),
        Scenario(name: "a generic filter does not block top-level navigation", rules: "/landing\n/ads/", path: "/ads/landing.html", blocked: [img3p, img1p]),
        Scenario(name: "without the guard rules the main document would be blocked", rawJSON: #"[{"trigger":{"url-filter":"/ads/landing"},"action":{"type":"block"}}]"#, path: "/ads/landing.html", expectMainLoaded: false),
        Scenario(name: "an explicit $document block blocks the main document", rules: "/ads/landing$document", path: "/ads/landing.html", expectMainLoaded: false),
        Scenario(name: "popups open when nothing blocks them", popup: "/ads/popup.html", popupAllowed: true),
        Scenario(name: "$popup blocks a popup", rules: "/ads/popup.html$popup", popup: "/ads/popup.html"),
        Scenario(name: "$popup,domain= blocks a popup opened from that site", rules: "||127.0.0.1^$popup,domain=localhost", popup: "/ads/popup.html"),
        Scenario(name: "a generic filter does not block popups", rules: "/ads/popup.html", popup: "/ads/popup.html", popupAllowed: true),
        Scenario(name: "an exception allows a $popup block", rules: "/ads/popup.html$popup\n@@/ads/popup.html$popup", popup: "/ads/popup.html", popupAllowed: true),
        Scenario(name: "generic hiding", rules: "##.ad-banner", js: [.init(expression: display("adb"), expected: "none"), .init(expression: display("content"), expected: "block")]),
        Scenario(name: "domain-specific hiding", rules: "localhost##.content", js: [.init(expression: display("adb"), expected: "block"), .init(expression: display("content"), expected: "none")]),
        Scenario(name: "domain-specific hiding skips other sites", rules: "localhost##.content", host: "127.0.0.1", js: [.init(expression: display("content"), expected: "block")]),
        Scenario(name: "domain-specific hiding covers subdomains", rules: "localhost##.content", host: "sub.localhost", js: [.init(expression: display("content"), expected: "none")]),
        Scenario(name: "#@# switches a generic selector off on that site", rules: "##.ad-banner\nlocalhost#@#.ad-banner", js: [.init(expression: display("adb"), expected: "block")]),
        Scenario(name: "#@# leaves other sites hidden", rules: "##.ad-banner\nlocalhost#@#.ad-banner", host: "127.0.0.1", js: [.init(expression: display("adb"), expected: "none")]),
        Scenario(name: "~site## excludes the site", rules: "~localhost##.ad-banner", js: [.init(expression: display("adb"), expected: "block")]),
        Scenario(name: "$generichide exempts generic hiding", rules: "##.ad-banner\n@@||localhost^$generichide", js: [.init(expression: display("adb"), expected: "block")]),
        Scenario(name: "$generichide keeps site-specific hiding", rules: "localhost##.content\n@@||localhost^$generichide", js: [.init(expression: display("content"), expected: "none")]),
        Scenario(name: "the bundled fallback list leaves a plain page alone", rules: ContentBlocker.fallbackListText),
    ]

    private static var store: WKContentRuleListStore?
    private static var server: TestServer?
    private static var counter = 0

    @MainActor private func environment() throws -> (WKContentRuleListStore, TestServer) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        if Self.store == nil { Self.store = WKContentRuleListStore(url: makeTempDirectory("wk-behavior")) }
        if Self.server == nil { Self.server = try TestServer() }
        return (Self.store!, Self.server!)
    }

    @MainActor @Test(arguments: scenarios) func behavesLikeAdblockPlus(_ s: Scenario) async throws {
        let (store, server) = try environment()
        Self.counter += 1
        let config = WKWebViewConfiguration()

        var lists: [(String, String)] = []
        if let raw = s.rawJSON { lists.append(("raw\(Self.counter)", raw)) }
        else { lists = ContentBlocker.compile(name: "s\(Self.counter)", text: s.rules).lists.map { ($0.name, $0.json) } }
        for (id, json) in lists {
            let compiled: WKContentRuleList? = await withCheckedContinuation { cont in
                store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, _ in cont.resume(returning: list) }
            }
            config.userContentController.add(try #require(compiled, "WebKit rejected \(id)"))
        }

        server.reset()
        let delegate = NavigationDelegate()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        web.navigationDelegate = delegate
        web.uiDelegate = delegate
        let url = try #require(URL(string: "http://\(s.host):\(server.port)\(s.path)"))
        let loaded = await delegate.load(url, in: web)
        #expect(loaded == s.expectMainLoaded, "main document load")
        guard s.expectMainLoaded else { return }

        #expect(await server.waitForDone(), "page never reported completion")
        let reached = server.requestedPaths()
        #expect(Self.allResources.subtracting(reached) == s.blocked, "blocked resources")
        if let popup = s.popup {
            _ = try await web.evaluateJavaScript("window.open('http://127.0.0.1:\(server.port)\(popup)'); 1")
            try await Task.sleep(nanoseconds: 700_000_000)
            #expect(server.requestedPaths().contains(popup) == s.popupAllowed, "popup \(popup)")
        }
        for check in s.js {
            let value = try await web.evaluateJavaScript(check.expression)
            #expect("\(value ?? "nil")" == check.expected, "\(check.expression)")
        }
    }
}

@MainActor
private final class NavigationDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var popups: [WKWebView] = []

    /// Popups get the opener's configuration, so the same rule lists judge them.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        popups.append(popup)
        return popup
    }

    func load(_ url: URL, in web: WKWebView) async -> Bool {
        await withCheckedContinuation { cont in
            continuation = cont
            web.load(URLRequest(url: url))
        }
    }

    private func finish(_ ok: Bool) { continuation?.resume(returning: ok); continuation = nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
}

/// Minimal HTTP/1.0 server on a random loopback port. Serves a test page whose resources are on the page's own host
/// ("1p") and on the other of `localhost` / `127.0.0.1` ("3p"), and records every path requested.
private final class TestServer: @unchecked Sendable {
    static let resources = ["/ads/img3p.gif", "/ads/img1p.gif", "/js/tracker3p.js", "/js/tracker1p.js", "/frame3p.html", "/frame1p.html", "/api/fetch3p", "/api/xhr1p"]

    private let listener: NWListener
    private let queue = DispatchQueue(label: "cosmos.test-server")
    private let lock = NSLock()
    private var log: [String] = []
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let p = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
        port = p
    }

    deinit { listener.cancel() }

    func reset() { lock.withLock { log.removeAll() } }
    func requestedPaths() -> Set<String> { lock.withLock { Set(log) } }

    func waitForDone() async -> Bool {
        for _ in 0..<100 {
            if lock.withLock({ log.contains("/__done") }) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private func page(host: String) -> String {
        let other = host == "127.0.0.1" ? "localhost" : "127.0.0.1"
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>t</title></head><body>
        <div class="ad-banner" id="adb">Ad</div><div class="content" id="content">Content</div>
        <img src="http://\(other):\(port)/ads/img3p.gif"><img src="http://\(host):\(port)/ads/img1p.gif">
        <script src="http://\(other):\(port)/js/tracker3p.js"></script><script src="http://\(host):\(port)/js/tracker1p.js"></script>
        <iframe src="http://\(other):\(port)/frame3p.html"></iframe><iframe src="http://\(host):\(port)/frame1p.html"></iframe>
        <script>
        var fetched = fetch("http://\(other):\(port)/api/fetch3p", {mode: "no-cors"}).catch(function () {});
        var xhr = new Promise(function (resolve) { var x = new XMLHttpRequest(); x.open("GET", "http://\(host):\(port)/api/xhr1p"); x.onloadend = resolve; x.send(); });
        var loaded = new Promise(function (resolve) { window.addEventListener("load", resolve); });
        Promise.all([fetched, xhr, loaded]).then(function () { new Image().src = "/__done"; });
        </script></body></html>
        """
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let lines = text.components(separatedBy: "\r\n")
            let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let host = lines.first { $0.lowercased().hasPrefix("host:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces).split(separator: ":")[0] }.map(String.init) ?? "localhost"
            let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
            self.lock.withLock { self.log.append(path) }

            var body = Data("{}".utf8), type = "application/json"
            if path.hasPrefix("/page") || path.contains("landing") { body = Data(self.page(host: host).utf8); type = "text/html" }
            else if path.hasSuffix(".gif") { body = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!; type = "image/gif" }
            else if path.hasSuffix(".js") { body = Data("/* ok */".utf8); type = "application/javascript" }
            else if path.hasSuffix(".html") { body = Data("<html><body>frame</body></html>".utf8); type = "text/html" }
            let head = "HTTP/1.0 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
#endif
