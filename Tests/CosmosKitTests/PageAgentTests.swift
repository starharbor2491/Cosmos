import AppKit
import Foundation
import Testing
import CosmosBlocking
import CosmosEngine
@testable import CosmosChromium
@testable import CosmosKit
@testable import CosmosCore

/// A Chromium to test on: `COSMOS_TEST_CHROMIUM` (a Chromium.app), or the one Cosmos keeps. Nil when there is none, and
/// the tests that need one are skipped.
enum RealChromium {
    static let app: URL? = {
        if let path = ProcessInfo.processInfo.environment["COSMOS_TEST_CHROMIUM"], FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let install = ChromiumInstall(root: LaunchOptions.chromiumDirectory)
        guard let current = install.loadState().current else { return nil }
        let app = install.app(for: current)
        return FileManager.default.fileExists(atPath: app.path) ? app : nil
    }()
}

/// Cosmos on the real engine: the page agent in Chromium pages, and what Cosmos makes of what it reports. Chromium runs
/// headless (no window, no Dock icon); each test starts its own and stops it at the end.
@MainActor
@Suite(.enabled(if: RealChromium.app != nil, "no Chromium to test on"), .serialized)
struct PageAgentTests {
    let engine: ChromiumEngine
    let rig: Rig

    init() {
        engine = ChromiumEngine(supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-test-chromium-\(UUID().uuidString)"),
                                application: RealChromium.app, offline: true)
        engine.start()
        rig = Rig(engine: engine)
    }

    /// Every test ends with this, so no Chromium outlives it.
    private func stop() {
        rig.store.closeEnvironments()
        engine.shutdown()
    }

    private func html(_ body: String) -> SiteServer.Route { .init(type: "text/html", body: Data(body.utf8)) }

    private func waitFor(_ seconds: Double = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
    }

    /// A tab on `url`, loaded, with a page area of its own size (it is in no window).
    private func open(_ url: URL) async throws -> TabRuntime {
        let id = try #require(rig.store.newTab(url: url, in: rig.window))
        let runtime = try #require(rig.store.runtime(forItem: id, in: rig.window))
        runtime.view.setFrameSize(NSSize(width: 800, height: 600))
        try await waitFor { runtime.url == url && !runtime.isLoading }
        try #require(runtime.url == url, "the page did not load")
        return runtime
    }

    private func center(of selector: String, in runtime: TabRuntime) async throws -> CGPoint {
        let js = "(() => { const r = document.querySelector(\(BoostInjector.jsString(selector))).getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()"
        let xy = try #require(await runtime.evaluate(returning: js) as? [Double])
        return CGPoint(x: xy[0], y: xy[1])
    }

    /// A real (trusted) click, as Chromium gets one from the page area.
    private func click(_ selector: String, in runtime: TabRuntime, button: String = "left", modifiers: Int = 0) async throws {
        let p = try await center(of: selector, in: runtime)
        let page = try #require(runtime.page as? ChromiumPage)
        let bit = button == "right" ? 2 : 1
        page.input("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": p.x, "y": p.y, "button": "none", "buttons": 0, "modifiers": modifiers])
        page.input("Input.dispatchMouseEvent", ["type": "mousePressed", "x": p.x, "y": p.y, "button": button, "buttons": bit, "clickCount": 1, "modifiers": modifiers])
        page.input("Input.dispatchMouseEvent", ["type": "mouseReleased", "x": p.x, "y": p.y, "button": button, "buttons": 0, "clickCount": 1, "modifiers": modifiers])
    }

    private func pressEscape(in runtime: TabRuntime) throws {
        let page = try #require(runtime.page as? ChromiumPage)
        for type in ["rawKeyDown", "keyUp"] {
            page.input("Input.dispatchKeyEvent", ["type": type, "key": "Escape", "code": "Escape", "windowsVirtualKeyCode": 27, "nativeVirtualKeyCode": 53])
        }
    }

    // MARK: Page state

    /// Chromium only says so when a page navigates; a title the page sets later reaches the sidebar through the agent.
    @Test func thePagesTitleFollowsTheDocument() async throws {
        defer { stop() }
        let server = try await SiteServer(routes: ["/": html("<title>First</title><body>hello</body>")])
        let runtime = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)
        try await waitFor { runtime.title == "First" }
        #expect(runtime.title == "First")
        _ = await runtime.evaluate(returning: "document.title = 'Second'")
        try await waitFor { runtime.title == "Second" }
        #expect(runtime.title == "Second")
        try await waitFor { self.rig.store.workspace.item(runtime.itemID)?.tab?.pageTitle == "Second" }
        #expect(rig.store.workspace.item(runtime.itemID)?.tab?.pageTitle == "Second")
    }

    /// A load that fails shows Cosmos's own page, and the address stays the one that failed.
    @Test func aRefusedConnectionShowsCosmossPage() async throws {
        defer { stop() }
        let id = try #require(rig.store.newTab(url: URL(string: "http://127.0.0.1:9/"), in: rig.window))
        let runtime = try #require(rig.store.runtime(forItem: id, in: rig.window))
        try await waitFor { runtime.loadFailed && !runtime.isLoading }
        #expect(runtime.loadFailed)
        #expect(runtime.url?.absoluteString == "http://127.0.0.1:9/")
        let text = await runtime.evaluate(returning: "document.body ? document.body.innerText : ''") as? String
        #expect(text?.contains("Press ⌘R to try again") == true)
        // Showing Cosmos's page is not a visit: what failed stays out of History.
        try await Task.sleep(for: .milliseconds(500))
        #expect(rig.store.history.count() == 0)
    }

    // MARK: What was clicked

    @Test func aLinkInsideAnSVGIsALinkToo() async throws {
        defer { stop() }
        let server = try await SiteServer(routes: ["/": html("<body style='margin:0'><a href='/html'><span id='h'>html link</span></a><br><svg width='100' height='100'><a href='/svg'><rect id='r' width='100' height='100'/></a></svg></body>")])
        let runtime = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)

        try await click("#h", in: runtime, button: "right")
        try await waitFor { runtime.context.link != nil }
        #expect(runtime.context.link?.path == "/html")

        try await click("#r", in: runtime, button: "right")
        try await waitFor { runtime.context.link?.path == "/svg" }
        #expect(runtime.context.link?.path == "/svg", "an SVG <a> is a link, so the ring offers link actions")
    }

    @Test func whatWasUnderThePointerIsForgottenWhenThePageChanges() async throws {
        defer { stop() }
        let server = try await SiteServer(routes: ["/": html("<body><a id='a' href='/x'>link</a></body>"), "/two": html("<p>two</p>")])
        let runtime = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)
        try await click("#a", in: runtime, button: "right")
        try await waitFor { runtime.context.link != nil }
        #expect(runtime.context.link != nil)

        runtime.load(URL(string: "http://127.0.0.1:\(server.port)/two")!)
        try await waitFor { runtime.url?.path == "/two" && runtime.context.link == nil }
        #expect(runtime.url?.path == "/two")
        #expect(runtime.context.link == nil)
    }

    /// ⌘-click opens the link in a tab behind this one; a plain click follows it here.
    @Test func commandClickOpensABackgroundTabAndAPlainClickFollows() async throws {
        defer { stop() }
        let server = try await SiteServer(routes: ["/": html("<body><a id='a' href='/next'>next</a></body>"), "/next": html("<title>Next</title>")])
        let runtime = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)
        let before = rig.store.workspace.allTabs().count

        try await click("#a", in: runtime, modifiers: 4)
        try await waitFor { self.rig.store.workspace.allTabs().count == before + 1 }
        #expect(rig.store.workspace.allTabs().contains { $0.tab?.url?.path == "/next" })
        #expect(rig.window.selectedItemID == runtime.itemID, "the new tab opens behind")
        #expect(runtime.url?.path == "/")

        try await click("#a", in: runtime)
        try await waitFor { runtime.url?.path == "/next" }
        #expect(runtime.url?.path == "/next")
    }

    // MARK: Escape

    /// Escape closes what the browser has open over the page, unless the page used it itself. A key the page made up
    /// does not count.
    @Test func escapeIsTheBrowsersUnlessThePageTookIt() async throws {
        defer { stop() }
        let server = try await SiteServer(routes: [
            "/mine": html("<body><script>document.addEventListener('keydown', e => { if (e.key === 'Escape') e.preventDefault(); });</script></body>"),
            "/plain": html("<body>nothing listens here</body>"),
        ])
        let mine = try await open(URL(string: "http://127.0.0.1:\(server.port)/mine")!)
        rig.window.overlay = .find
        try pressEscape(in: mine)
        try await Task.sleep(for: .milliseconds(400))
        #expect(rig.window.overlay == .find, "the page handled Escape itself")

        let plain = try await open(URL(string: "http://127.0.0.1:\(server.port)/plain")!)
        rig.window.overlay = .find
        _ = await plain.evaluate(returning: "document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true, cancelable: true})); 1")
        try await Task.sleep(for: .milliseconds(400))
        #expect(rig.window.overlay == .find, "a page's own made-up key is not the user's")

        try pressEscape(in: plain)
        try await waitFor { self.rig.window.overlay == nil }
        #expect(rig.window.overlay == nil, "nobody claimed it, so it is the browser's")
    }

    // MARK: Extensions

    /// An extension runs inside Chromium with Chromium's own `chrome.*` APIs. What Chrome would draw for it (the button
    /// and its badge, a menu item, a shortcut) reaches Cosmos, and Cosmos's clicks reach the extension with the right tab.
    @Test func anExtensionRunsAndItsButtonMenuAndShortcutWork() async throws {
        defer { stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-test-extension-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = [
            "manifest.json": """
            {"manifest_version": 3, "name": "Cosmos Test", "version": "1.0", "permissions": ["contextMenus"],
             "background": {"service_worker": "worker.js"}, "action": {"default_title": "Cosmos Test"},
             "content_scripts": [{"matches": ["http://127.0.0.1/*"], "js": ["content.js"]}],
             "commands": {"ping": {"suggested_key": {"default": "Ctrl+Shift+Y"}, "description": "Ping"}}}
            """,
            "worker.js": """
            chrome.contextMenus.removeAll(() => chrome.contextMenus.create({ id: 'item', title: 'Cosmos test item', contexts: ['page'] }));
            chrome.action.setBadgeText({ text: '7' });
            chrome.action.onClicked.addListener(tab => chrome.tabs.sendMessage(tab.id, 'action'));
            chrome.contextMenus.onClicked.addListener((info, tab) => chrome.tabs.sendMessage(tab.id, 'menu'));
            chrome.commands.onCommand.addListener((name, tab) => chrome.tabs.sendMessage(tab.id, 'command-' + name));
            """,
            "content.js": """
            document.documentElement.setAttribute('data-cosmos-ext', 'ran');
            chrome.runtime.onMessage.addListener(m => document.documentElement.setAttribute('data-got-' + m, '1'));
            """,
        ]
        for (name, text) in files { try Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
        let extensions = try #require(rig.store.environment(forProfile: rig.space.profileID).engineProfile.extensions)
        let id = try await extensions.load(folder: folder)

        let server = try await SiteServer(routes: ["/": html("<body>hello</body>")])
        let runtime = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)
        func attribute(_ name: String) async -> String? {
            await runtime.evaluate(returning: "document.documentElement.getAttribute('\(name)')") as? String
        }
        func waitForAttribute(_ name: String) async throws -> String? {
            for _ in 0..<200 { if let v = await attribute(name) { return v }; try await Task.sleep(for: .milliseconds(50)) }
            return nil
        }
        #expect(try await waitForAttribute("data-cosmos-ext") == "ran", "the content script ran")

        try await waitFor { extensions.actions(for: runtime.page).first { $0.extensionID == id }?.badgeText == "7" }
        let button = try #require(extensions.actions(for: runtime.page).first { $0.extensionID == id })
        #expect(button.title == "Cosmos Test")
        #expect(button.badgeText == "7")
        #expect(await extensions.performAction(id, on: runtime.page) == nil, "no popup: the click goes to the worker")
        #expect(try await waitForAttribute("data-got-action") == "1")

        try await waitFor { extensions.menuItems(for: runtime.page).contains { $0.extensionID == id } }
        let item = try #require(extensions.menuItems(for: runtime.page).first { $0.extensionID == id })
        #expect(item.title == "Cosmos test item")
        await extensions.performMenuItem(item, context: ExtensionClickContext(pageURL: runtime.url), on: runtime.page)
        #expect(try await waitForAttribute("data-got-menu") == "1")

        let command = try #require(extensions.commands.first { $0.extensionID == id && $0.name == "ping" })
        await extensions.performCommand(command, on: runtime.page)
        #expect(try await waitForAttribute("data-got-command-ping") == "1")
    }

    // MARK: Boosts and blocking

    @Test func aBoostStylesThePagesOfItsSite() async throws {
        defer { stop() }
        let server = try await SiteServer(routes: ["/": html("<body><p id='p'>hello</p><div id='ad'>ad</div></body>")])
        rig.store.boosts = BoostLibrary(boosts: [Boost(name: "t", hostPatterns: ["127.0.0.1"], zapSelectors: ["#ad"])])
        let runtime = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)
        let ad = await runtime.evaluate(returning: "getComputedStyle(document.getElementById('ad')).display") as? String
        let kept = await runtime.evaluate(returning: "getComputedStyle(document.getElementById('p')).display") as? String
        #expect(ad == "none")
        #expect(kept == "block")
    }

    /// The filter lists reach Chromium as its own request rules and hiding rules; a site the user allowed is left alone.
    @Test func blockingStopsRequestsAndHidesElementsExceptWhereAllowed() async throws {
        defer { stop() }
        let page = "<body><div class='cosmos-test-ad'>ad</div><script src='/ad.js'></script></body>"
        let server = try await SiteServer(routes: ["/": html(page), "/ad.js": .init(type: "text/javascript", body: Data("window.adRan = true".utf8))])
        let lists = ContentBlocker.compile(name: "t", text: "/ad.js$script\n##.cosmos-test-ad\n").lists
            .map { CompiledBlockingList(name: $0.name, json: $0.json, kind: $0.kind == .network ? .network : .cosmetic, digest: $0.digest) }
        let profile = rig.store.environment(forProfile: rig.space.profileID).engineProfile
        profile.setContentBlocking(lists, allowlist: [])

        let blocked = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await blocked.evaluate(returning: "window.adRan === true") as? Bool == false)
        #expect(await blocked.evaluate(returning: "getComputedStyle(document.querySelector('.cosmos-test-ad')).display") as? String == "none")

        profile.setContentBlocking(lists, allowlist: ["127.0.0.1"])
        try await Task.sleep(for: .milliseconds(500))
        let allowed = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)
        for _ in 0..<40 where (await allowed.evaluate(returning: "window.adRan === true") as? Bool) != true { try await Task.sleep(for: .milliseconds(50)) }
        #expect(await allowed.evaluate(returning: "window.adRan === true") as? Bool == true)
        #expect(await allowed.evaluate(returning: "getComputedStyle(document.querySelector('.cosmos-test-ad')).display") as? String == "block")
    }

    /// EasyList and EasyPrivacy together are about 104,000 rules, more than Chromium promises one extension (30,000); the
    /// rest comes from a pool all extensions share, and a ruleset that does not fit is switched off whole. A list that
    /// size, cut into rulesets of 10,000, must have every ruleset on: the last rule of each blocks its image.
    @Test func everyRulesetOfListsAsLargeAsTheRealOnesIsOn() async throws {
        defer { stop() }
        let count = 110_000, size = DNRCompiler.Options().maxRulesPerList
        let text = (0..<count).map { "/cosmos-budget/\($0).gif" }.joined(separator: "\n")
        let compiled = ContentBlocker.compile(name: "big", text: text)
        try #require(compiled.report.ruleCount == count)
        let lists = compiled.lists.map { CompiledBlockingList(name: $0.name, json: $0.json, kind: $0.kind == .network ? .network : .cosmetic, digest: $0.digest) }
        #expect(lists.count == count / size)
        let probes = (1...(count / size)).map { $0 * size - 1 }
        let images = (probes.map { "/cosmos-budget/\($0).gif" } + ["/kept.gif"]).map { "<img src='\($0)'>" }.joined()
        let gif = SiteServer.Route(type: "image/gif", body: Data(base64Encoded: "R0lGODlhAQABAAAAACw=")!)
        var routes: [String: SiteServer.Route] = ["/": html("<body>\(images)</body>"), "/kept.gif": gif]
        for p in probes { routes["/cosmos-budget/\(p).gif"] = gif }
        let server = try await SiteServer(routes: routes)
        rig.store.environment(forProfile: rig.space.profileID).engineProfile.setContentBlocking(lists, allowlist: [])
        try await Task.sleep(for: .seconds(2))

        _ = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)
        try await waitFor(5) { server.requests.contains("/kept.gif") }
        #expect(server.requests.contains("/kept.gif"), "the page's own image loads")
        let through = server.requests.filter { $0.hasPrefix("/cosmos-budget/") }
        #expect(through.isEmpty, "rulesets that were off: \(through)")
    }
}
