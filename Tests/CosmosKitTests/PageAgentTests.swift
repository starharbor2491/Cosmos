import AppKit
import Foundation
import Testing
import CosmosBlocking
import CosmosEngine
@testable import CosmosChromium
@testable import CosmosKit
@testable import CosmosCore

/// Cosmos on the real engine: the page agent in Chromium pages, and what Cosmos makes of what it reports. Chromium runs
/// in the test process (`CEFTestRuntime`), in views that are in no window; each test has profiles of its own, and its
/// store's first profile is the default one, which extensions run in.
@MainActor
@Suite(.enabled(if: CEFTestRuntime.isAvailable, "no CEF in Vendor/CEF (scripts/fetch-cef.sh)"), .serialized)
struct PageAgentTests {
    let engine: ChromiumEngine
    let rig: Rig

    init() async throws {
        if let failure = await CEFTestRuntime.start() { throw CDPError(code: -1, message: failure) }
        engine = ChromiumEngine()
        engine.start()
        rig = Rig(engine: engine)
        CEFTestRuntime.makeDefault(rig.store.workspace.profiles[0].id)
    }

    /// Every test ends with this, so none of its profiles outlives it.
    private func stop() {
        rig.store.closeEnvironments()
        engine.closeProfiles()
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
        let page = try #require(runtime.page as? ChromiumPage)
        // Chromium drops input that comes before the page has drawn: two frames, and it has.
        _ = await page.evaluate("new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => r(1))))", in: .page)
        let p = try await center(of: selector, in: runtime)
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

    /// Chromium run headless or over a pipe tells every page it is automated (`navigator.webdriver`), and sites such as
    /// Google's sign-in turn such browsers away. Cosmos's pages are told what Chrome's are.
    @Test func pagesAreNotToldTheBrowserIsAutomated() async throws {
        defer { stop() }
        let server = try await SiteServer(routes: ["/": html("<body>hello</body>")])
        let runtime = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)
        #expect(await runtime.evaluate(returning: "navigator.webdriver") as? Bool == false)
    }

    /// Chromium holds a page's workers at their start until it is told to go on, as it holds its frames. A worker in the
    /// page, in a frame from another site, and a shared one all run.
    @Test func aPagesWorkersRun() async throws {
        defer { stop() }
        let start = "new Worker(URL.createObjectURL(new Blob(['postMessage(\"ran\")']))).onmessage = e => parent.postMessage('frame ' + e.data, '*');"
        let frame = try await SiteServer(routes: ["/frame": html("<script>\(start)</script>")])
        let page = "<body><script>window.got = []; addEventListener('message', e => got.push(e.data));</script></body>"
        let server = try await SiteServer(routes: ["/": html(page)])
        let runtime = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)
        let worker = """
        new Promise(r => { new Worker(URL.createObjectURL(new Blob(['postMessage("ran")']))).onmessage = e => r(e.data);
          setTimeout(() => r('no answer'), 5000); })
        """
        #expect(await runtime.evaluate(returning: worker) as? String == "ran")
        let nested = """
        new Promise(r => { const inner = URL.createObjectURL(new Blob(['postMessage("ran")']));
          const outer = URL.createObjectURL(new Blob(['const w = new Worker(' + JSON.stringify(inner) + '); w.onmessage = e => postMessage("nested " + e.data);']));
          new Worker(outer).onmessage = e => r(e.data); setTimeout(() => r('no answer'), 5000); })
        """
        #expect(await runtime.evaluate(returning: nested) as? String == "nested ran")
        // And let go of: Cosmos stays attached to nothing it does not use.
        let connections = rig.store.engineProfiles.compactMap { ($0 as? ChromiumProfile)?.connection }
        let connection = try #require(connections.first)
        let targets = (try await connection.send("Target.getTargets"))["targetInfos"] as? [[String: Any]] ?? []
        let workers = targets.filter { $0["type"] as? String == "worker" }
        #expect(!workers.isEmpty && workers.allSatisfy { $0["attached"] as? Bool == false }, "\(workers.map { $0["attached"] ?? "?" })")
        let shared = """
        new Promise(r => { const w = new SharedWorker(URL.createObjectURL(new Blob(['onconnect = e => e.ports[0].postMessage("ran")'])));
          w.port.onmessage = e => r(e.data); setTimeout(() => r('no answer'), 5000); })
        """
        #expect(await runtime.evaluate(returning: shared) as? String == "ran")
        _ = await runtime.evaluate(returning: "document.body.insertAdjacentHTML('beforeend', \"<iframe src='http://localhost:\(frame.port)/frame'></iframe>\"); 1")
        for _ in 0..<100 where ((await runtime.evaluate(returning: "got.length") as? Int) ?? 0) < 1 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(await runtime.evaluate(returning: "got") as? [String] == ["frame ran"])
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

    // MARK: Permissions

    /// Chromium headless turns every request down, having nowhere to ask. Cosmos is asked instead, and what the user
    /// decided is what the page gets: here, remembered answers, so no sheet comes up.
    @Test func aSiteAsksAndGetsWhatTheUserDecided() async throws {
        defer { stop() }
        let server = try await SiteServer(routes: ["/": html("<body>hello</body>")])
        let decisions = ["127.0.0.1|notifications": true, "127.0.0.1|camera": true, "127.0.0.1|microphone": false, "127.0.0.1|location": true]
        for (key, allowed) in decisions { rig.store.settings.permissionDecisions[key] = allowed }
        rig.store.locate = { PageLocation(latitude: 48.85, longitude: 2.35, accuracy: 20) }
        let runtime = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)

        #expect(await runtime.evaluate(returning: "Notification.requestPermission()") as? String == "granted")
        let camera = "navigator.mediaDevices.getUserMedia({ video: true }).then(s => 'video ' + s.getVideoTracks().length, e => e.name)"
        #expect(await runtime.evaluate(returning: camera) as? String == "video 1")
        let microphone = "navigator.mediaDevices.getUserMedia({ audio: true }).then(s => 'audio', e => e.name)"
        #expect(await runtime.evaluate(returning: microphone) as? String == "NotAllowedError")
        let location = "new Promise(r => navigator.geolocation.getCurrentPosition(p => r(p.coords.latitude + ',' + p.coords.longitude), e => r('error ' + e.code)))"
        #expect(await runtime.evaluate(returning: location) as? String == "48.85,2.35")
        let watch = "new Promise(r => { const id = navigator.geolocation.watchPosition(p => { navigator.geolocation.clearWatch(id); r(String(p.coords.latitude)); }, e => r('error ' + e.code)); })"
        #expect(await runtime.evaluate(returning: watch) as? String == "48.85")
    }

    /// A question still open when its profile closes (a private window closed, Cosmos quitting) is let go: the answer that
    /// comes after has no profile left to reach. Driven on the engine alone, with the question held open by the test.
    @Test func aQuestionAnsweredAfterItsProfileHasGoneIsLetGo() async throws {
        defer { stop() }
        final class HeldQuestion: EnginePageDelegate {
            var asked: CheckedContinuation<Bool, Never>?
            func page(_ page: EnginePage, wantsPermission request: PermissionRequest) async -> Bool {
                await withCheckedContinuation { asked = $0 }
            }
            func pageStateDidChange(_ page: EnginePage) {}
            func pageDidStartNavigation(_ page: EnginePage) {}
            func pageDidCommitNavigation(_ page: EnginePage) {}
            func pageDidFinishLoading(_ page: EnginePage) {}
            func page(_ page: EnginePage, didFailLoading url: URL, error: PageLoadError) {}
            func page(_ page: EnginePage, agentMessage: [String: Any], fromMainFrame: Bool) {}
            func page(_ page: EnginePage, runDialog dialog: PageDialog) async -> PageDialog.Answer { PageDialog.Answer(accepted: false) }
            func page(_ page: EnginePage, chooseFiles chooser: FileChooser) async -> [URL]? { nil }
            func page(_ page: EnginePage, dangerAt url: URL) -> PageDanger? { nil }
            func page(_ page: EnginePage, wantsCredentialsFor challenge: AuthChallenge) async -> PageCredentials? { nil }
            func page(_ page: EnginePage, showNotification note: EngineNotification) {}
            func page(_ page: EnginePage, closeNotification id: String) {}
            func page(_ page: EnginePage, wantsPictureInPicture view: NSView) async -> Bool { false }
            func pageDidLeavePictureInPicture(_ page: EnginePage) {}
            func pageWantsLocation(_ page: EnginePage) async -> PageLocation? { nil }
            func pageDidForceClick(_ page: EnginePage) {}
            func pageRequestsClose(_ page: EnginePage) {}
            func pageRendererDidTerminate(_ page: EnginePage) {}
        }
        let server = try await SiteServer(routes: ["/": html("<body>hello</body>")])
        let question = HeldQuestion()
        weak var gone: EngineProfile?
        var page: ChromiumPage?
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-question-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let profile = engine.makeProfile(id: UUID(), directory: folder)
            gone = profile
            profile.setPageScripts([])
            let made = try #require(profile.makePage() as? ChromiumPage)
            page = made
            made.delegate = question
            made.view.setFrameSize(NSSize(width: 800, height: 600))
            made.load(URL(string: "http://127.0.0.1:\(server.port)/")!)
            try await waitFor { made.state.url?.port == Int(server.port) && !made.state.isLoading }
            _ = await made.evaluate("Notification.requestPermission(); 1", in: .page)
            try await waitFor(5) { question.asked != nil }
            try #require(question.asked != nil, "the page did not ask")
            profile.close()
        }
        try await waitFor(5) { gone == nil }
        try #require(gone == nil, "the profile is still held, so this cannot show anything")
        question.asked?.resume(returning: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(page?.state.url != nil, "the page is still there, and nothing broke")
    }

    /// A site the user allowed is allowed from the start, without asking again; a reset takes it back.
    @Test func aRememberedAllowIsThereBeforeTheSiteAsks() async throws {
        defer { stop() }
        let server = try await SiteServer(routes: ["/": html("<body>hello</body>")])
        rig.store.settings.permissionDecisions["127.0.0.1|notifications"] = true
        let runtime = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)
        for _ in 0..<100 where (await runtime.evaluate(returning: "Notification.permission") as? String) != "granted" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(await runtime.evaluate(returning: "Notification.permission") as? String == "granted")
        rig.store.settings.permissionDecisions = [:]
        for _ in 0..<100 where (await runtime.evaluate(returning: "Notification.permission") as? String) == "granted" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(await runtime.evaluate(returning: "Notification.permission") as? String == "default")
    }

    /// Settings ▸ Engine blocks a kind: a site the user has not decided about is refused, and nobody is asked (a question
    /// would never be answered here, so the page would wait).
    @Test func whatSettingsBlockIsRefused() async throws {
        defer { stop() }
        let server = try await SiteServer(routes: ["/": html("<body>hello</body>")])
        rig.store.settings.engine.notifications = .block
        let runtime = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)
        let ask = "Promise.race([Notification.requestPermission(), new Promise(r => setTimeout(() => r('asked'), 5000))])"
        #expect(await runtime.evaluate(returning: ask) as? String == "denied")
    }

    // MARK: Frames from other sites

    /// Chromium runs a frame from another site in a process of its own. It still gets what a page gets: the Boosts for
    /// its site, and Cosmos's answer when it asks for a permission (as in Chrome, the page's site is what is asked about).
    @Test func aFrameFromAnotherSiteGetsItsBoostsAndAsksThroughCosmos() async throws {
        defer { stop() }
        let report = """
        <body><div id='ad'>ad</div><script>
        setTimeout(() => parent.postMessage('display ' + getComputedStyle(document.getElementById('ad')).display, '*'), 300);
        navigator.geolocation.getCurrentPosition(p => parent.postMessage('lat ' + p.coords.latitude, '*'), e => parent.postMessage('lat error ' + e.code, '*'));
        </script></body>
        """
        let frame = try await SiteServer(routes: ["/frame": html(report)])
        let page = """
        <body><script>window.got = []; addEventListener('message', e => got.push(e.data));</script>
        <iframe allow='geolocation' src='http://localhost:\(frame.port)/frame'></iframe></body>
        """
        let server = try await SiteServer(routes: ["/": html(page)])
        rig.store.boosts = BoostLibrary(boosts: [Boost(name: "t", hostPatterns: ["localhost"], zapSelectors: ["#ad"])])
        rig.store.settings.permissionDecisions["127.0.0.1|location"] = true
        rig.store.locate = { PageLocation(latitude: 12.5, longitude: 3, accuracy: 10) }
        let runtime = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)
        for _ in 0..<100 where ((await runtime.evaluate(returning: "got.length") as? Int) ?? 0) < 2 { try await Task.sleep(for: .milliseconds(50)) }
        let got = Set(await runtime.evaluate(returning: "got") as? [String] ?? [])
        #expect(got == ["display none", "lat 12.5"])
    }

    // MARK: History

    /// Chromium keeps a history of its own for each profile, which Cosmos does not show. Deleting a page from History
    /// (with or without a fragment) and Clear History empty it there too.
    @Test func clearingHistoryAlsoEmptiesChromiumsOwn() async throws {
        defer { stop() }
        let server = try await SiteServer(routes: ["/a": html("<title>A</title>a"), "/b": html("<title>B</title>b")])
        let a = URL(string: "http://127.0.0.1:\(server.port)/a")!, b = URL(string: "http://127.0.0.1:\(server.port)/b")!
        let first = try await open(a)
        _ = await first.evaluate(returning: "location.hash = 'part'; 1")
        _ = try await open(b)
        let profile = try #require(rig.store.engineProfiles.first as? ChromiumProfile)
        // Only this test's pages: the default profile is CEF's global context, which every test in the process shares.
        func visited() async -> [String] {
            let all = await profile.bridgeEvaluate("chrome.history.search({ text: '', startTime: 0 }).then(r => r.map(i => i.url).sort())") as? [String]
            return all?.filter { $0.hasPrefix("http://127.0.0.1:\(server.port)/") } ?? ["unreadable"]
        }
        let all = [a.absoluteString, a.absoluteString + "#part", b.absoluteString]
        for _ in 0..<100 where await visited() != all { try await Task.sleep(for: .milliseconds(50)) }
        var seen = await visited()
        #expect(seen == all)
        rig.store.deleteHistoryEntry(a)
        for _ in 0..<100 where await visited() != [b.absoluteString] { try await Task.sleep(for: .milliseconds(50)) }
        seen = await visited()
        #expect(seen == [b.absoluteString])
        rig.store.clearHistory()
        for _ in 0..<100 where await visited() != [] { try await Task.sleep(for: .milliseconds(50)) }
        seen = await visited()
        #expect(seen == [])
    }

    // MARK: Notifications

    /// A site's notification is "shown" inside Chromium where nobody sees it; Cosmos posts it to macOS, and a click
    /// reaches the page's own handler and brings the tab forward.
    @Test func aSitesNotificationIsPostedByCosmosAndItsClickReachesThePage() async throws {
        defer { stop() }
        let server = try await SiteServer(routes: ["/": html("<body>news</body>")])
        rig.store.settings.permissionDecisions["127.0.0.1|notifications"] = true
        let notifier = FakeNotifier()
        rig.store.notifier = notifier
        var brought: [TabRuntime] = []
        rig.store.onShowTab = { brought.append($0) }
        let runtime = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)
        for _ in 0..<100 where (await runtime.evaluate(returning: "Notification.permission") as? String) != "granted" { try await Task.sleep(for: .milliseconds(50)) }
        _ = await runtime.evaluate(returning: "window.clicks = 0; window.n = new Notification('Hello', { body: 'World', tag: 'greeting' }); n.onclick = () => clicks++; 1")
        try await waitFor(5) { !notifier.shown.isEmpty }
        let shown = try #require(notifier.shown.first)
        #expect(shown.note.title == "Hello")
        #expect(shown.note.body == "World")
        #expect(shown.note.source == "127.0.0.1")
        shown.onAction(.clicked)
        for _ in 0..<100 where (await runtime.evaluate(returning: "clicks") as? Int) != 1 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(await runtime.evaluate(returning: "clicks") as? Int == 1)
        #expect(brought.count == 1, "the tab comes forward")
        _ = await runtime.evaluate(returning: "n.close(); 1")
        try await waitFor(5) { notifier.closed.contains(shown.key) }
        #expect(notifier.closed.contains(shown.key), "the page took it back")
    }

    /// What the page bridge reports is a window message, which any script can post. Cosmos posts only what a frame shows
    /// itself, with permission, under its own site's name: not a forged report without permission, not one naming another
    /// site, and not one a frame from another site sends to the page.
    @Test func aPageOrFrameCannotForgeANotification() async throws {
        defer { stop() }
        let forge = "{ __cosmosTell: 'notification', note: { id: 'forged', title: 'Forged', body: '', origin: 'bank.example' } }"
        let frame = try await SiteServer(routes: ["/frame": html("<script>parent.postMessage(\(forge), '*'); parent.postMessage('sent', '*');</script>")])
        let server = try await SiteServer(routes: ["/": html("<body><script>window.got = []; addEventListener('message', e => got.push(e.data));</script></body>")])
        let notifier = FakeNotifier()
        rig.store.notifier = notifier
        let runtime = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)

        _ = await runtime.evaluate(returning: "postMessage(\(forge), '*'); 1")
        try await Task.sleep(for: .milliseconds(800))
        #expect(notifier.shown.isEmpty, "posted without permission")

        rig.store.settings.permissionDecisions["127.0.0.1|notifications"] = true
        for _ in 0..<100 where (await runtime.evaluate(returning: "Notification.permission") as? String) != "granted" { try await Task.sleep(for: .milliseconds(50)) }
        _ = await runtime.evaluate(returning: "postMessage(\(forge), '*'); 1")
        try await waitFor(5) { !notifier.shown.isEmpty }
        #expect(notifier.shown.map(\.note.source) == ["127.0.0.1"], "posted under another site's name")

        _ = await runtime.evaluate(returning: "document.body.insertAdjacentHTML('beforeend', \"<iframe src='http://localhost:\(frame.port)/frame'></iframe>\"); 1")
        for _ in 0..<100 where !((await runtime.evaluate(returning: "got.includes('sent')") as? Bool) ?? false) { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(800))
        #expect(notifier.shown.count == 1, "a frame posted one in the page's name")
    }

    /// The page bridge's questions and Cosmos's answers are window messages too. A frame from another site posting them to
    /// the page neither asks a question in the page's name nor answers one the page is waiting on.
    @Test func aFrameCannotAskOrAnswerInThePagesName() async throws {
        defer { stop() }
        let forge = """
        for (let id = 1; id <= 20; id++) parent.postMessage({ __cosmosAnswer: id, value: true }, '*');
        parent.postMessage({ __cosmosAsk: 'permission', id: 999, kind: 'camera' }, '*'); parent.postMessage('sent', '*');
        """
        let frame = try await SiteServer(routes: ["/frame": html("<script>\(forge)</script>")])
        let page = "<body><script>window.got = []; addEventListener('message', e => got.push(e.data && e.data.__cosmosAnswer !== undefined ? 'answer ' + e.data.__cosmosAnswer : e.data));</script></body>"
        let server = try await SiteServer(routes: ["/": html(page)])
        // A camera question would be answered at once from this, without a sheet; a notification one waits (no window here).
        rig.store.settings.permissionDecisions["127.0.0.1|camera"] = false
        let runtime = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)
        _ = await runtime.evaluate(returning: "window.answered = 'waiting'; Notification.requestPermission().then(r => answered = r); 1")
        _ = await runtime.evaluate(returning: "document.body.insertAdjacentHTML('beforeend', \"<iframe src='http://localhost:\(frame.port)/frame'></iframe>\"); 1")
        for _ in 0..<100 where !((await runtime.evaluate(returning: "got.includes('sent')") as? Bool) ?? false) { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(800))
        #expect(await runtime.evaluate(returning: "answered") as? String == "waiting", "a frame answered the page's question")
        #expect(await runtime.evaluate(returning: "got.includes('answer 999')") as? Bool == false, "a frame asked in the page's name")
    }

    /// An extension's `chrome.notifications` too: Cosmos posts it with the extension's icon, and a click reaches the
    /// extension's `onClicked`.
    @Test(.disabled("Extensions on CEF: Cosmos has to answer chrome.tabs and the toolbar button itself, and put its shim ahead of the worker (docs/cef-engine.md)")) func anExtensionsNotificationIsPostedAndItsClickReachesTheExtension() async throws {
        defer { stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-test-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = [
            "manifest.json": """
            {"manifest_version": 3, "name": "Cosmos Notes", "version": "1.0", "permissions": ["notifications"],
             "background": {"service_worker": "worker.js"}, "action": {"default_title": "Notes"},
             "content_scripts": [{"matches": ["http://127.0.0.1/*"], "js": ["content.js"]}]}
            """,
            "worker.js": """
            chrome.action.onClicked.addListener(tab => chrome.notifications.create('n1', { type: 'basic', iconUrl: 'icon.png', title: 'From the extension', message: 'Hi', buttons: [{ title: 'Open' }] }));
            chrome.notifications.onClicked.addListener(id => chrome.tabs.query({}, tabs => tabs.forEach(t => chrome.tabs.sendMessage(t.id, 'clicked-' + id).catch(() => {}))));
            chrome.notifications.onButtonClicked.addListener((id, index) => chrome.tabs.query({}, tabs => tabs.forEach(t => chrome.tabs.sendMessage(t.id, 'button-' + index).catch(() => {}))));
            """,
            "content.js": "chrome.runtime.onMessage.addListener(m => document.documentElement.setAttribute('data-got-' + m, '1'));",
        ]
        for (name, text) in files { try Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
            .write(to: folder.appendingPathComponent("icon.png"))
        let notifier = FakeNotifier()
        rig.store.notifier = notifier
        let extensions = try #require(rig.store.environment(forProfile: rig.space.profileID).engineProfile.extensions)
        var posted: [(String, EngineNotification)] = []
        extensions.onNotification = { id, note in posted.append((id, note)) }
        let id = try await extensions.load(folder: folder)
        let server = try await SiteServer(routes: ["/": html("<body>hello</body>")])
        let runtime = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)
        try await waitFor { extensions.actions(for: runtime.page).contains { $0.extensionID == id } }
        _ = await extensions.performAction(id, on: runtime.page)
        try await waitFor(5) { !posted.isEmpty }
        let (from, note) = try #require(posted.first)
        #expect(from == id)
        #expect(note.title == "From the extension")
        #expect(note.body == "Hi")
        #expect(note.source == "Cosmos Notes")
        #expect(note.buttons == ["Open"])
        #expect(note.icon != nil, "its icon, from the extension's own folder")
        await extensions.notification(note.id, of: id, did: .clicked)
        await extensions.notification(note.id, of: id, did: .button(0))
        for _ in 0..<100 where (await runtime.evaluate(returning: "document.documentElement.getAttribute('data-got-button-0')") as? String) == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await runtime.evaluate(returning: "document.documentElement.getAttribute('data-got-clicked-n1')") as? String == "1")
        #expect(await runtime.evaluate(returning: "document.documentElement.getAttribute('data-got-button-0')") as? String == "1")
    }

    /// Writes an extension's files into a new folder, removed when the test ends.
    private func extensionFolder(_ files: [String: String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-test-extension-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
        return folder
    }

    /// `chrome.sidePanel`: Chromium keeps the options but has no panel to show. Cosmos is asked to open it (here by the
    /// button, as `setPanelBehavior` says), and gets the extension's panel page, which runs with the extension's APIs.
    @Test(.disabled("Extensions on CEF: Cosmos has to answer chrome.tabs and the toolbar button itself, and put its shim ahead of the worker (docs/cef-engine.md)")) func anExtensionsSidePanelOpensAsAPageCosmosShows() async throws {
        defer { stop() }
        let folder = try extensionFolder([
            "manifest.json": """
            {"manifest_version": 3, "name": "Cosmos Panel", "version": "1.0", "permissions": ["sidePanel", "tabs"],
             "background": {"service_worker": "worker.js"}, "action": {"default_title": "Panel"}, "side_panel": {"default_path": "panel.html"}}
            """,
            "worker.js": "chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true });",
            "panel.html": "<body>panel<script src='panel.js'></script></body>",
            "panel.js": "chrome.tabs.query({}).then(tabs => { document.title = 'panel sees ' + tabs.length + ' tabs'; });",
        ])
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensions = try #require(rig.store.environment(forProfile: rig.space.profileID).engineProfile.extensions)
        var asked: [String] = []
        extensions.onSidePanelRequest = { id, _ in asked.append(id) }
        let id = try await extensions.load(folder: folder)
        let server = try await SiteServer(routes: ["/": html("<body>hello</body>")])
        let runtime = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)
        try await waitFor { extensions.actions(for: runtime.page).contains { $0.extensionID == id } }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await extensions.performAction(id, on: runtime.page) == nil, "the panel is not a popup")
        try await waitFor(5) { asked == [id] }
        #expect(asked == [id])
        let panel = try #require(await extensions.openSidePanel(id, for: runtime.page) as? ChromiumPage)
        defer { panel.close() }
        try await waitFor { panel.state.title.hasPrefix("panel sees") }
        #expect(panel.state.url?.absoluteString == "chrome-extension://\(id)/panel.html")
        #expect(panel.state.title.hasPrefix("panel sees"), "the panel runs with the extension's APIs")
    }

    /// `identity.launchWebAuthFlow`: Chromium would sign in in a window nobody sees. Cosmos opens the sign-in page as a
    /// window of its own, and the address the site sends back to the extension is the extension's answer.
    @Test(.disabled("Extensions on CEF: Cosmos has to answer chrome.tabs and the toolbar button itself, and put its shim ahead of the worker (docs/cef-engine.md)")) func anExtensionsSignInOpensAWindowAndEndsWhereTheSiteSendsBack() async throws {
        defer { stop() }
        let server = try await SiteServer(routes: [
            "/": html("<body>hello</body>"),
            "/auth": html("<body>sign in<script>setTimeout(() => location = new URLSearchParams(location.search).get('back') + 'done?code=42', 200)</script></body>"),
        ])
        let folder = try extensionFolder([
            "manifest.json": """
            {"manifest_version": 3, "name": "Cosmos Sign In", "version": "1.0", "permissions": ["identity"],
             "background": {"service_worker": "worker.js"}, "action": {"default_title": "Sign in"},
             "content_scripts": [{"matches": ["http://127.0.0.1/*"], "js": ["content.js"]}]}
            """,
            "worker.js": """
            chrome.action.onClicked.addListener(tab => {
              const url = 'http://127.0.0.1:\(server.port)/auth?back=' + encodeURIComponent(chrome.identity.getRedirectURL());
              chrome.identity.launchWebAuthFlow({ url, interactive: true }).then(r => chrome.tabs.sendMessage(tab.id, r), e => chrome.tabs.sendMessage(tab.id, 'error ' + e.message));
            });
            """,
            "content.js": "chrome.runtime.onMessage.addListener(m => document.documentElement.setAttribute('data-signed-in', m));",
        ])
        defer { try? FileManager.default.removeItem(at: folder) }
        var popups: [NewPageRequest] = []
        rig.store.onPopupWindow = { _, request, _ in popups.append(request) }
        let extensions = try #require(rig.store.environment(forProfile: rig.space.profileID).engineProfile.extensions)
        let id = try await extensions.load(folder: folder)
        let runtime = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)
        try await waitFor { extensions.actions(for: runtime.page).contains { $0.extensionID == id } }
        _ = await extensions.performAction(id, on: runtime.page)
        for _ in 0..<200 where (await runtime.evaluate(returning: "document.documentElement.getAttribute('data-signed-in')") as? String) == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(popups.count == 1, "the sign-in page had a window")
        #expect(await runtime.evaluate(returning: "document.documentElement.getAttribute('data-signed-in')") as? String
                == "https://\(id).chromiumapp.org/done?code=42")
    }

    // MARK: Picture in Picture

    /// Chromium headless has no Picture in Picture window, so Cosmos makes one: the page's frames, cropped to the video.
    /// The page sees what it would in Chrome (the element, the events), and whichever side ends it, both know.
    @Test func pictureInPictureShowsTheVideoInCosmossOwnWindow() async throws {
        defer { stop() }
        let page = """
        <body style='margin:0'><div style='height:50px'></div><video id='v' muted style='width:320px;height:180px;display:block;margin-left:40px'></video><script>
        const c = document.createElement('canvas'); c.width = 320; c.height = 180; const g = c.getContext('2d'); let n = 0;
        setInterval(() => { g.fillStyle = n++ % 2 ? '#c00' : '#00c'; g.fillRect(0, 0, 320, 180); }, 40);
        const v = document.getElementById('v'); v.srcObject = c.captureStream(25); v.play();
        window.events = []; v.addEventListener('enterpictureinpicture', () => events.push('enter')); v.addEventListener('leavepictureinpicture', () => events.push('leave'));
        </script></body>
        """
        let server = try await SiteServer(routes: ["/": html(page)])
        var shown: NSView?
        var ended = 0
        rig.store.onPictureInPicture = { _, view in shown = view; return true }
        rig.store.onPictureInPictureEnded = { _ in ended += 1 }
        let runtime = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)
        for _ in 0..<100 where (await runtime.evaluate(returning: "v.readyState") as? Int ?? 0) < 3 { try await Task.sleep(for: .milliseconds(50)) }

        runtime.enterPictureInPicture()
        try await waitFor(5) { shown != nil }
        let view = try #require(shown as? ChromiumPictureInPictureView)
        #expect(await runtime.evaluate(returning: "document.pictureInPictureElement === v") as? Bool == true)
        try await waitFor(5) { view.crop != nil && view.image != nil }
        let scale = Double(runtime.view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        let crop = try #require(view.crop)
        #expect(abs(crop.minX - 40 * scale) < 2 && abs(crop.minY - 50 * scale) < 2 && abs(crop.width - 320 * scale) < 2, "the video's own rectangle: \(crop)")

        runtime.exitPictureInPicture()
        for _ in 0..<100 where (await runtime.evaluate(returning: "document.pictureInPictureElement === null") as? Bool) != true { try await Task.sleep(for: .milliseconds(50)) }
        #expect(await runtime.evaluate(returning: "events.join()") as? String == "enter,leave")

        runtime.enterPictureInPicture()
        try await waitFor(5) { (ended == 1) && runtime.isInPictureInPicture }
        _ = await runtime.evaluate(returning: "document.exitPictureInPicture().then(() => 'ok')")
        try await waitFor(5) { ended == 2 }
        #expect(ended == 2, "the page left it: Cosmos closes its window")
        #expect(!runtime.isInPictureInPicture)
    }

    // MARK: Dangerous sites

    /// A page from a site on a phishing or malware list is stopped before it is even asked for, and Cosmos says why; the
    /// user can still choose to go.
    @Test func aDangerousSiteIsStoppedBeforeItLoadsAndTheUserCanStillGo() async throws {
        defer { stop() }
        let server = try await SiteServer(routes: ["/": html("<body>dangerous</body>")])
        rig.store.dangerousSites = DangerousSites.parse("0.0.0.0 localhost", reason: .phishing)
        let id = try #require(rig.store.newTab(url: URL(string: "http://localhost:\(server.port)/"), in: rig.window))
        let runtime = try #require(rig.store.runtime(forItem: id, in: rig.window))
        runtime.view.setFrameSize(NSSize(width: 800, height: 600))
        try await waitFor { runtime.danger != nil }
        #expect(runtime.danger?.kind == .phishing)
        #expect(runtime.url?.host == "localhost", "the address stays the one that was stopped")
        #expect(server.requests.isEmpty, "nothing was asked of the site: \(server.requests)")
        runtime.visitDangerousSiteAnyway()
        for _ in 0..<100 where (await runtime.evaluate(returning: "document.body ? document.body.innerText : ''") as? String) != "dangerous" {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await runtime.evaluate(returning: "document.body.innerText") as? String == "dangerous")
        #expect(runtime.danger == nil)
    }

    /// A frame from such a site, inside a page that is fine, is simply left out.
    @Test func aDangerousFrameIsLeftOutOfAPageThatIsFine() async throws {
        defer { stop() }
        let bad = try await SiteServer(routes: ["/": html("<body>dangerous</body>")])
        let server = try await SiteServer(routes: ["/": html("<body>home<iframe src='http://localhost:\(bad.port)/'></iframe></body>")])
        rig.store.dangerousSites = DangerousSites.parse("0.0.0.0 localhost", reason: .malware)
        let runtime = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)
        try await Task.sleep(for: .milliseconds(500))
        #expect(runtime.danger == nil)
        #expect(await runtime.evaluate(returning: "document.body.innerText") as? String == "home")
        #expect(bad.requests.isEmpty)
    }

    // MARK: Signing in

    /// HTTP authentication: Chromium headless has no sign-in dialog, so the challenge comes to Cosmos and its answer goes
    /// back; no answer leaves the page the site sends to someone who did not sign in.
    @Test func aSiteThatAsksForAPasswordGetsTheOneTheUserGives() async throws {
        defer { stop() }
        let routes: [String: SiteServer.Route] = ["/secret": .init(type: "text/html", body: Data("<body>secret</body>".utf8), basicAuth: "ann:pw")]
        let server = try await SiteServer(routes: routes)
        var asked: [AuthChallenge] = []
        rig.store.signIn = { _, challenge in asked.append(challenge); return PageCredentials(user: "ann", password: "pw") }
        let runtime = try await open(URL(string: "http://127.0.0.1:\(server.port)/secret")!)
        try await waitFor { false == runtime.isLoading }
        #expect(await runtime.evaluate(returning: "document.body.innerText") as? String == "secret")
        #expect(asked == [AuthChallenge(host: "127.0.0.1", realm: "Cosmos test", isProxy: false, isSecure: false)])

        let other = try await SiteServer(routes: routes)
        rig.store.signIn = { _, _ in nil }
        let refused = try await open(URL(string: "http://127.0.0.1:\(other.port)/secret")!)
        #expect(await refused.evaluate(returning: "document.body.innerText") as? String == "sign in")
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
    /// A click on an extension's button goes to the tab the page is in, which Cosmos first asks Chromium about. A Chromium
    /// slow to answer (a busy Mac) must not lose the click: here it is paused for two seconds at that moment.
    @Test(.disabled("Extensions on CEF: Cosmos has to answer chrome.tabs and the toolbar button itself, and put its shim ahead of the worker (docs/cef-engine.md)")) func anExtensionsButtonStillWorksWhenChromiumIsSlowToSayWhichTabThePageIsIn() async throws {
        defer { stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-test-slow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = [
            "manifest.json": """
            {"manifest_version": 3, "name": "Cosmos Slow", "version": "1.0", "background": {"service_worker": "worker.js"},
             "action": {"default_title": "Slow"}, "content_scripts": [{"matches": ["http://127.0.0.1/*"], "js": ["content.js"]}]}
            """,
            "worker.js": "chrome.action.onClicked.addListener(tab => chrome.tabs.sendMessage(tab.id, 'action'));",
            "content.js": "chrome.runtime.onMessage.addListener(m => document.documentElement.setAttribute('data-got-' + m, '1'));",
        ]
        for (name, text) in files { try Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
        let profile = try #require(rig.store.environment(forProfile: rig.space.profileID).engineProfile as? ChromiumProfile)
        let host = try #require(profile.extensions as? ChromiumExtensionHost)
        let id = try await host.load(folder: folder)
        let server = try await SiteServer(routes: ["/": html("<body>hello</body>")])
        let runtime = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)
        try await waitFor { host.actions(for: runtime.page).contains { $0.extensionID == id } }
        let browser = try #require(await profile.processIDs().first)
        defer { kill(browser, SIGCONT) }
        host.willAskTab = {
            kill(browser, SIGSTOP)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(browser, SIGCONT) }
        }
        var popups = 0
        rig.store.onPopupWindow = { _, _, _ in popups += 1 }
        let tabs = rig.store.workspace.unpinned(in: rig.space).count
        _ = await host.performAction(id, on: runtime.page)
        host.willAskTab = nil
        for _ in 0..<100 where (await runtime.evaluate(returning: "document.documentElement.getAttribute('data-got-action')") as? String) == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await runtime.evaluate(returning: "document.documentElement.getAttribute('data-got-action')") as? String == "1")
        #expect(rig.store.workspace.unpinned(in: rig.space).count == tabs && popups == 0, "the click opened nothing else")
    }

    @Test(.disabled("Extensions on CEF: Cosmos has to answer chrome.tabs and the toolbar button itself, and put its shim ahead of the worker (docs/cef-engine.md)")) func anExtensionRunsAndItsButtonMenuAndShortcutWork() async throws {
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
        var popups = 0
        rig.store.onPopupWindow = { _, _, _ in popups += 1 }
        let tabs = rig.store.workspace.unpinned(in: rig.space).count
        #expect(await extensions.performAction(id, on: runtime.page) == nil, "no popup: the click goes to the worker")
        #expect(try await waitForAttribute("data-got-action") == "1")
        // Finding the tab the page is in means looking into Chromium's tabs, which are not pages to open.
        try await Task.sleep(for: .milliseconds(1200))
        #expect(rig.store.workspace.unpinned(in: rig.space).count == tabs && popups == 0, "the click opened nothing else")

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

    /// A private window is a profile kept in memory, made from the default one: the default profile's blocker runs in it.
    @Test func aPrivateWindowIsBlockedToo() async throws {
        defer { stop() }
        let page = "<body><div class='cosmos-test-ad'>ad</div><script src='/ad.js'></script></body>"
        let server = try await SiteServer(routes: ["/": html(page), "/ad.js": .init(type: "text/javascript", body: Data("window.adRan = true".utf8))])
        let lists = ContentBlocker.compile(name: "t", text: "/ad.js$script\n##.cosmos-test-ad\n").lists
            .map { CompiledBlockingList(name: $0.name, json: $0.json, kind: $0.kind == .network ? .network : .cosmetic, digest: $0.digest) }
        let profile = rig.store.environment(forProfile: rig.space.profileID).engineProfile
        profile.setContentBlocking(lists, allowlist: [])
        _ = try await open(URL(string: "http://127.0.0.1:\(server.port)/")!)

        let incognito = engine.makeProfile(id: nil, directory: nil)
        defer { incognito.close() }
        incognito.setPageScripts([])
        let made = try #require(incognito.makePage() as? ChromiumPage)
        made.load(URL(string: "http://127.0.0.1:\(server.port)/")!)
        try await waitFor { made.state.url?.port == Int(server.port) && !made.state.isLoading }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await made.evaluate("window.adRan === true", in: .page) as? Bool == false)
        #expect(await made.evaluate("getComputedStyle(document.querySelector('.cosmos-test-ad')).display", in: .page) as? String == "none")
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
