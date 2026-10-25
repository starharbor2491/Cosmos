import Foundation
import Testing
import Network
import WebKit
@testable import CosmosKit
@testable import CosmosCore

@MainActor
private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    var settings: Settings?
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if let settings, let url = navigationAction.request.url { ContentBlockerController.configure(preferences, for: url, settings: settings) }
        decisionHandler(.allow, preferences)
    }
    func load(_ url: URL, in web: WKWebView) async {
        web.navigationDelegate = self
        await withCheckedContinuation { c in
            continuation = c
            web.load(URLRequest(url: url))
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { continuation?.resume(); continuation = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { continuation?.resume(); continuation = nil }
}

/// Serves one fixed HTML page on 127.0.0.1 so a real http:// document can be loaded.
private final class PageServer: @unchecked Sendable {
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

@MainActor
@Suite struct ContentBlockerTests {
    @Test func allowlistCoversTheHostAndItsSubdomainsOnly() throws {
        let list = ["example.com", "News.Site"]
        #expect(ContentBlockerController.isAllowlisted(try #require(URL(string: "https://example.com/a")), allowlist: list))
        #expect(ContentBlockerController.isAllowlisted(try #require(URL(string: "https://www.example.com/")), allowlist: list))
        #expect(ContentBlockerController.isAllowlisted(try #require(URL(string: "https://sub.news.site/x")), allowlist: list))
        #expect(!ContentBlockerController.isAllowlisted(try #require(URL(string: "https://notexample.com/")), allowlist: list))
        #expect(!ContentBlockerController.isAllowlisted(try #require(URL(string: "https://example.org/")), allowlist: list))
        #expect(!ContentBlockerController.isAllowlisted(try #require(URL(string: "https://example.com/")), allowlist: []))
    }

    /// Loads a page whose `.cosmos-test-ad` element a user-supplied list hides, and returns its computed `display`.
    private func adDisplay(allowlist: [String]) async throws -> (ad: String?, kept: String?) {
        let rig = Rig()
        let source = rig.dir.appendingPathComponent("mine.txt")
        try FileManager.default.createDirectory(at: rig.dir, withIntermediateDirectories: true)
        try "! test list\nlocalhost##.cosmos-test-ad\n".write(to: source, atomically: true, encoding: .utf8)

        let wkStore = try #require(WKContentRuleListStore(url: rig.dir.appendingPathComponent("RuleLists", isDirectory: true)))
        // Only the user's own file:// list is on, so nothing is downloaded from the internet.
        rig.store.settings.enabledFilterLists = []
        rig.store.settings.adBlockAllowlist = allowlist
        let blocker = ContentBlockerController(store: rig.store, directory: rig.dir, offline: false, ruleListStore: wkStore)
        rig.store.blocker = blocker
        let env = rig.store.environment(forProfile: rig.store.workspace.profiles[0].id)   // attached on creation
        _ = await blocker.addCustomList(name: "mine", url: source)

        for _ in 0..<100 where env.ruleLists.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!env.ruleLists.isEmpty)

        let server = try await PageServer(html: "<div class='cosmos-test-ad'>ad</div><p id='keep'>hello</p>")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: env.makeConfiguration())
        let waiter = LoadWaiter()
        waiter.settings = rig.store.settings
        await waiter.load(try #require(URL(string: "http://localhost:\(server.port)/")), in: web)
        let ad = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.cosmos-test-ad')).display") as? String
        let kept = try await web.evaluateJavaScript("getComputedStyle(document.getElementById('keep')).display") as? String
        withExtendedLifetime(waiter) {}
        return (ad, kept)
    }

    /// A list of the user's own is compiled, attached to the profile and applied to a real page.
    @Test func aCustomListIsCompiledAttachedAndAppliedToPages() async throws {
        let shown = try await adDisplay(allowlist: [])
        #expect(shown.ad == "none")
        #expect(shown.kept == "block")
    }

    /// The Site Controls switch: the same page on an allowlisted host is left untouched.
    @Test func blockingIsOffOnAllowlistedSites() async throws {
        let shown = try await adDisplay(allowlist: ["localhost"])
        #expect(shown.ad == "block")
    }

    @Test func turningBlockingOffRemovesTheRules() async throws {
        let rig = Rig()
        let source = rig.dir.appendingPathComponent("mine.txt")
        try FileManager.default.createDirectory(at: rig.dir, withIntermediateDirectories: true)
        try "localhost##.x\n".write(to: source, atomically: true, encoding: .utf8)
        let wkStore = try #require(WKContentRuleListStore(url: rig.dir.appendingPathComponent("RuleLists", isDirectory: true)))
        // Only the user's own file:// list is on, so nothing is downloaded from the internet.
        rig.store.settings.enabledFilterLists = []
        let blocker = ContentBlockerController(store: rig.store, directory: rig.dir, offline: false, ruleListStore: wkStore)
        rig.store.blocker = blocker
        let env = rig.store.environment(forProfile: rig.store.workspace.profiles[0].id)
        _ = await blocker.addCustomList(name: "mine", url: source)
        for _ in 0..<100 where env.ruleLists.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!env.ruleLists.isEmpty)

        rig.store.settings.adBlockingEnabled = false
        for _ in 0..<100 where !env.ruleLists.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(env.ruleLists.isEmpty)
        #expect(blocker.installedRuleCount == 0)
    }
}
