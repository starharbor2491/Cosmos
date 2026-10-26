import AppKit
import Foundation
import Testing
import WebKit
@testable import CosmosKit
@testable import CosmosCore

/// What WebKit hands over for `window.open(url, name, "width=480,height=640")`.
private final class SizedFeatures: WKWindowFeatures {
    override var width: NSNumber? { 480 }
    override var height: NSNumber? { 640 }
}

/// The page behind the menu-bar browser: the same profile data store as the browser windows, so the cookies and logins
/// are shared, and the small differences a panel needs.
@MainActor
@Suite struct MenuBarSessionTests {
    private func html(_ body: String) -> SiteServer.Route { .init(type: "text/html", body: Data(body.utf8)) }

    private func waitFor(_ seconds: Double = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
    }

    private func read(_ script: String, in web: WKWebView) async throws -> String {
        try await web.evaluateJavaScript(script) as? String ?? ""
    }

    // MARK: Shared data

    @Test func theDefaultProfilesDataStoreIsTheOneTheBrowserWindowsUse() {
        let rig = Rig()
        let session = MenuBarSession(store: rig.store)
        let runtime = session.prepare()
        let profile = rig.store.workspace.profiles.first { $0.isDefault } ?? rig.store.workspace.profiles[0]
        #expect(runtime.webView.configuration.websiteDataStore === rig.store.environment(forProfile: profile.id).dataStore)
        #expect(runtime.profileID == profile.id)
        session.teardown()
    }

    @Test func aChosenProfilesDataStoreIsUsedAndAMissingOneFallsBackToTheDefault() throws {
        let rig = Rig()
        let work = Profile(name: "Work")
        rig.store.edit { $0.profiles.append(work) }
        rig.store.settings.menuBar.profileID = work.id
        let session = MenuBarSession(store: rig.store)
        let chosen = session.prepare()
        #expect(chosen.profileID == work.id)
        #expect(chosen.webView.configuration.websiteDataStore === rig.store.environment(forProfile: work.id).dataStore)

        rig.store.settings.menuBar.profileID = UUID()
        let fallback = session.prepare()
        let defaultID = try #require(rig.store.workspace.profiles.first { $0.isDefault }?.id)
        #expect(fallback.profileID == defaultID)
        #expect(fallback !== chosen, "changing the profile builds a new page")
        session.teardown()
    }

    @Test func aCookieSetInABrowserTabIsThereInThePanel() async throws {
        let server = try await SiteServer(routes: ["/": html("<p>hello</p>")])
        let rig = Rig()
        let name = "cosmos_menubar_\(UUID().uuidString.prefix(8))"
        let origin = "http://127.0.0.1:\(server.port)/"

        _ = rig.store.newTab(url: URL(string: "about:blank"), in: rig.window)
        let tab = try #require(rig.store.currentRuntime(in: rig.window))
        tab.webView.load(URLRequest(url: URL(string: origin)!))
        try await waitFor { tab.webView.url?.host == "127.0.0.1" && !tab.webView.isLoading }
        _ = try await tab.webView.evaluateJavaScript("document.cookie = '\(name)=shared; path=/'")

        rig.store.settings.menuBar.homeAddress = origin
        rig.store.settings.menuBar.rememberPage = false
        let session = MenuBarSession(store: rig.store)
        let panel = session.prepare()
        try await waitFor { panel.webView.url?.host == "127.0.0.1" && !panel.webView.isLoading }
        let cookies = try await read("document.cookie", in: panel.webView)
        #expect(cookies.contains("\(name)=shared"), "the panel should be signed in wherever the browser is")

        _ = try await tab.webView.evaluateJavaScript("document.cookie = '\(name)=; path=/; max-age=0'")
        session.teardown()
    }

    // MARK: Starting and typing

    @Test func itOpensOnTheHomeAddressAndRemembersWhereItWent() async throws {
        let server = try await SiteServer(routes: ["/": html("<title>home</title>"), "/two": html("<title>two</title>")])
        let rig = Rig()
        rig.store.settings.menuBar.homeAddress = "http://127.0.0.1:\(server.port)/"
        let session = MenuBarSession(store: rig.store)
        let panel = session.prepare()
        try await waitFor { panel.url?.path == "/" && !panel.isLoading }
        #expect(panel.url?.host == "127.0.0.1")

        session.go("http://127.0.0.1:\(server.port)/two")
        try await waitFor { rig.store.settings.menuBar.lastAddress?.hasSuffix("/two") == true }
        #expect(rig.store.settings.menuBar.lastAddress == "http://127.0.0.1:\(server.port)/two")
        session.teardown()
    }

    @Test func nothingIsRememberedWhenThatIsOff() async throws {
        let server = try await SiteServer(routes: ["/": html("<title>home</title>")])
        let rig = Rig()
        rig.store.settings.menuBar.homeAddress = "http://127.0.0.1:\(server.port)/"
        rig.store.settings.menuBar.rememberPage = false
        let session = MenuBarSession(store: rig.store)
        let panel = session.prepare()
        try await waitFor { panel.url?.host == "127.0.0.1" && !panel.isLoading }
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.store.settings.menuBar.lastAddress == nil)
        session.teardown()
    }

    @Test func typedTextBecomesAnAddressOrASearch() {
        let engine = SearchEngine(id: "duck", name: "Duck", keyword: "d", search: "https://duckduckgo.com/?q=%s")
        #expect(MenuBarSession.destination(for: "github.com/x", engine: engine)?.absoluteString == "https://github.com/x")
        #expect(MenuBarSession.destination(for: "  localhost:3000 ", engine: engine)?.absoluteString == "http://localhost:3000")
        #expect(MenuBarSession.destination(for: "weather in oslo", engine: engine)?.absoluteString == "https://duckduckgo.com/?q=weather%20in%20oslo")
        #expect(MenuBarSession.destination(for: "   ", engine: engine) == nil)
        #expect(MenuBarSession.destination(for: "data:text/html,hi", engine: engine)?.scheme != "data", "no data: pages typed into a panel")
    }

    // MARK: The panel's own differences

    @Test func thePhoneLayoutSaysItIsAPhoneAndTheDesktopLayoutDoesNot() {
        let rig = Rig()
        rig.store.settings.menuBar.layout = .phone
        let session = MenuBarSession(store: rig.store)
        let runtime = session.prepare()
        #expect(runtime.webView.customUserAgent?.contains("iPhone") == true)

        rig.store.settings.menuBar.layout = .desktop
        let again = session.prepare()
        #expect(again === runtime, "a layout change keeps the page")
        #expect((again.webView.customUserAgent ?? "").isEmpty)
        session.teardown()
    }

    /// WKWebView answers "" for an agent that was never set, so "" and nil are the same, and changing nothing is not a change.
    @Test func anAgentThatIsUnsetIsTheSameWhetherItIsNilOrEmpty() {
        #expect(!MenuBarSession.agentDiffers(current: "", wanted: nil))
        #expect(!MenuBarSession.agentDiffers(current: nil, wanted: nil))
        #expect(!MenuBarSession.agentDiffers(current: MenuBarSession.phoneUserAgent, wanted: MenuBarSession.phoneUserAgent))
        #expect(MenuBarSession.agentDiffers(current: "", wanted: MenuBarSession.phoneUserAgent))
        #expect(MenuBarSession.agentDiffers(current: MenuBarSession.phoneUserAgent, wanted: nil))
    }

    @Test func aLinkThatWantsANewWindowOpensInPlaceInThePanelButNotInABrowserTab() {
        let rig = Rig()
        let session = MenuBarSession(store: rig.store)
        let runtime = session.prepare()
        #expect(runtime.host?.opensNewWindowsInPlace == true)
        #expect(!rig.store.opensNewWindowsInPlace)
        session.teardown()
    }

    /// A real click on a `target="_blank"` link, sent to the page the way a mouse would: the panel has no room for another
    /// window, so the page it points to has to load where the link was.
    @Test func aClickOnALinkThatWantsANewWindowLoadsItInThePanel() async throws {
        let server = try await SiteServer(routes: [
            "/": html("<html><body style='margin:0'><a href='/two' target='_blank' style='display:block;width:300px;height:300px'>go</a></body></html>"),
            "/two": html("<title>two</title><p>second page</p>"),
        ])
        let rig = Rig()
        rig.store.settings.menuBar.homeAddress = "http://127.0.0.1:\(server.port)/"
        rig.store.settings.menuBar.rememberPage = false
        let session = MenuBarSession(store: rig.store)
        let panel = session.prepare()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(panel.webView)
        panel.webView.frame = NSRect(x: 0, y: 0, width: 390, height: 600)
        window.orderFront(nil)
        try await waitFor { panel.url?.path == "/" && !panel.isLoading }
        try await Task.sleep(for: .milliseconds(300))

        func click(_ type: NSEvent.EventType) {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 50, y: 550), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        click(.leftMouseDown)
        click(.leftMouseUp)
        try await waitFor { panel.url?.path == "/two" }
        #expect(panel.url?.path == "/two")
        window.orderOut(nil)
        session.teardown()
    }

    /// A page that asks for a script-sized window (an OAuth sign-in, a payment sheet) needs its opener, so it gets a
    /// window of its own, as in the browser. Only plain "open in a new tab" requests are loaded in the panel.
    @Test func aScriptSizedPopupGetsItsOwnWindowButAPlainNewWindowLoadsInPlace() throws {
        let rig = Rig()
        var shown: [TabRuntime] = []
        var forward: [Bool] = []
        rig.store.onPopupWindow = { runtime, _, bringForward in shown.append(runtime); forward.append(bringForward) }
        let session = MenuBarSession(store: rig.store)
        let runtime = session.prepare()

        let plain = WKWindowFeatures()
        let sized = SizedFeatures()
        #expect(sized.width != nil, "the test's popup features should carry a size")
        #expect(TabRuntime.loadsNewWindowInPlace(hostOpensInPlace: true, features: plain))
        #expect(!TabRuntime.loadsNewWindowInPlace(hostOpensInPlace: true, features: sized))
        #expect(!TabRuntime.loadsNewWindowInPlace(hostOpensInPlace: false, features: plain))

        let popup = runtime.host?.tab(runtime, createChildWith: WKWebViewConfiguration(), features: sized)
        #expect(popup != nil)
        #expect(shown.count == 1 && shown.first?.isEphemeral == true)
        #expect(shown.first?.webView === popup)
        #expect(forward == [false], "a panel that is not on screen cannot have asked the user for a window")

        session.isPanelOpen = { true }
        _ = runtime.host?.tab(runtime, createChildWith: WKWebViewConfiguration(), features: sized)
        #expect(forward == [false, true], "a window asked for from the open panel comes to the front")
        session.teardown()
    }

    @Test func aDownloadFromThePanelDoesNotNeedABrowserWindow() {
        let rig = Rig()
        let session = MenuBarSession(store: rig.store)
        let runtime = session.prepare()
        // No browser window is active, which is what used to make the store drop the request.
        rig.store.activeWindow = nil
        var asked: [URL] = []
        rig.store.downloadStarter = { url, _ in asked.append(url) }
        let file = URL(string: "https://example.com/file.zip")!
        runtime.host?.tab(runtime, open: file, as: .download)
        #expect(asked == [file])
        session.teardown()
    }

    @Test func pagesForTheBrowserWindowsGoThereAndTheRestStaysInThePanel() {
        let rig = Rig()
        let session = MenuBarSession(store: rig.store)
        var sent: [URL] = []
        session.onOpenInCosmos = { sent.append($0) }
        let runtime = session.prepare()
        let url = URL(string: "https://example.com/new")!
        runtime.host?.tab(runtime, open: url, as: .newTabBackground)
        runtime.host?.tab(runtime, open: url, as: .peek)
        #expect(sent == [url, url])
        session.teardown()
    }

    @Test func escapeAndThePageClosingItselfHideThePanelUnlessItIsPinned() {
        let rig = Rig()
        let session = MenuBarSession(store: rig.store)
        var hidden = 0
        session.onHide = { hidden += 1 }
        let runtime = session.prepare()

        runtime.host?.tabRequestsEscape(runtime)
        runtime.host?.tabRequestsClose(runtime)
        #expect(hidden == 2)

        session.isPinned = true
        runtime.host?.tabRequestsEscape(runtime)
        #expect(hidden == 2, "a pinned panel stays when Esc is pressed")
        runtime.host?.tabRequestsClose(runtime)
        #expect(hidden == 3, "but a page that closes itself is done")
        session.teardown()
    }

    @Test func tearingDownLetsGoOfThePageAndPreparingAgainMakesANewOne() {
        let rig = Rig()
        let session = MenuBarSession(store: rig.store)
        let first = session.prepare()
        session.teardown()
        #expect(session.runtime == nil)
        #expect(session.prepare() !== first)
        session.teardown()
    }

    @Test func thePanelKnowsNothingAboutTheSidebarOrRadialRings() {
        let rig = Rig()
        let session = MenuBarSession(store: rig.store)
        let runtime = session.prepare()
        let host = runtime.host
        #expect(host?.tabIsPinnedOrFavorite(runtime) == false)
        #expect(host?.tab(runtime, showRadialMenu: NSMenu(), context: .link, center: .zero, windowSize: CGSize(width: 390, height: 680)) == false)
        session.teardown()
    }
}

@MainActor
@Suite struct MenuBarBrowserTests {
    private func browser(_ rig: Rig) -> MenuBarBrowser {
        MenuBarBrowser(store: rig.store, openInCosmos: { _ in }, showSettings: {}, showBrowser: {})
    }

    @Test func whileItIsOffThereIsNoIconNoPageAndNothingOpens() {
        let rig = Rig()
        let browser = browser(rig)
        browser.sync()
        browser.show()
        browser.toggle()
        #expect(browser.statusItem == nil)
        #expect(browser.panel == nil)
        #expect(!browser.isOpen)
        #expect(browser.session.runtime == nil)
    }

    @Test func turningItOffLetsGoOfThePin() {
        let rig = Rig()
        let browser = browser(rig)
        browser.session.isPinned = true
        browser.sync()
        #expect(!browser.session.isPinned)
    }

    @Test func theSettingsRoundTripThroughTheSettingsFile() throws {
        var settings = Settings()
        settings.menuBar.enabled = true
        settings.menuBar.layout = .desktop
        settings.menuBar.homeAddress = "example.com"
        settings.radialMenu.enabled = false
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        #expect(back.menuBar == settings.menuBar)
        #expect(back.radialMenu == settings.radialMenu)
    }

    @Test func aBrokenMenuBarEntryInTheSettingsFileKeepsTheDefaults() throws {
        let broken = Data(#"{"menuBar": "yes please", "radialMenu": [1, 2], "appearance": "dark"}"#.utf8)
        let back = try JSONDecoder().decode(Settings.self, from: broken)
        #expect(back.menuBar == MenuBarSettings())
        #expect(back.radialMenu == RadialSettings())
        #expect(back.appearance == .dark, "the rest of the file still loads")
    }

    /// Private windows take the ring and haptics choices over when they open, and again when those choices change while
    /// they are open: the app is told, and passes them on.
    @Test func changingTheRingOrHapticsChoicesTellsTheApp() {
        let rig = Rig()
        var told = 0
        rig.store.onPreferencesChanged = { told += 1 }
        rig.store.settings.radialMenu.enabled = false
        rig.store.settings.trackpadHaptics = false
        rig.store.settings.showSearchSuggestions = false
        rig.store.settings.menuBar.remember(URL(string: "https://example.com/"))
        #expect(told == 2, "only the choices a private window inherits")
    }

    @Test func changingTheMenuBarSettingsTellsTheApp() {
        let rig = Rig()
        var told = 0
        rig.store.onMenuBarChange = { told += 1 }
        rig.store.settings.menuBar.enabled = true
        rig.store.settings.menuBar.layout = .desktop
        rig.store.settings.radialMenu.enabled = false
        #expect(told == 2, "only the menu-bar settings count")
    }

    /// The page the panel is on is saved as it loads. That is bookkeeping, not a change of settings: acting on it would
    /// bring the panel back to the front (and take the keyboard) every time a page finished loading in the background.
    @Test func clearingHistoryForgetsTheMenuBarPageToo() {
        let rig = Rig()
        var cleared = 0
        rig.store.onHistoryCleared = { cleared += 1 }
        rig.store.settings.menuBar.remember(URL(string: "https://example.com/a?private=1"))
        #expect(rig.store.settings.menuBar.lastAddress != nil)

        rig.store.clearHistory()

        #expect(rig.store.settings.menuBar.lastAddress == nil)
        #expect(cleared == 1, "the app is told, so it can drop the page that is still loaded")
    }

    /// The History panel's "Clear…" menu clears a range, and each of its choices has to forget the menu-bar page too: it is
    /// the most recent page there is, and it holds a full address.
    @Test(arguments: [3600.0, 86_400, 7 * 86_400]) func clearingARangeOfHistoryForgetsTheMenuBarPageToo(seconds: Double) {
        let rig = Rig()
        var cleared = 0
        rig.store.onHistoryCleared = { cleared += 1 }
        rig.store.settings.menuBar.remember(URL(string: "https://example.com/a?private=1"))
        rig.store.history.record(url: URL(string: "https://example.com/b")!, title: "B")

        rig.store.clearHistory(since: Date().addingTimeInterval(-seconds))

        #expect(rig.store.settings.menuBar.lastAddress == nil)
        #expect(cleared == 1)
        #expect(rig.store.history.count() == 0, "the range reached the history itself")
    }

    @Test func clearingEverythingAlsoForgetsWhatTheCommandBarLearnedAndTheLogos() throws {
        let rig = Rig()
        rig.store.learned.record(query: "exa", candidateID: "tab:1")
        let folder = rig.dir.appendingPathComponent("Favicons", isDirectory: true)
        try TestIcon.png(side: 32, color: .systemOrange).write(to: folder.appendingPathComponent("example.com.png"))
        #expect(rig.store.favicons.image(forHost: "example.com") != nil)

        rig.store.clearHistory(since: nil)

        #expect(rig.store.learned.picks.isEmpty)
        #expect(rig.store.favicons.image(forHost: "example.com") == nil)
    }

    /// What was typed in the last hour is as much a record of it as the pages are: the Command Bar's picks carry the typed
    /// search and the typed address, and they have dates.
    @Test func clearingARangeForgetsWhatWasTypedInIt() throws {
        let rig = Rig()
        rig.store.learned.record(query: "old", candidateID: "hist:https://example.com/old", at: Date().addingTimeInterval(-86400 * 3))
        rig.store.learned.record(query: "private search", candidateID: "hist:https://example.com/private")
        rig.store.learned.record(query: "example.com/secret", candidateID: "hist:https://example.com/secret")

        rig.store.clearHistory(since: Date().addingTimeInterval(-3600))

        #expect(rig.store.learned.picks.keys.sorted() == ["old"])
        rig.store.saveNow()
        let saved = try Data(contentsOf: rig.dir.appendingPathComponent("command-bar-learning.json"))
        #expect(!saved.contains(Data("secret".utf8)) && !saved.contains(Data("private".utf8)))
    }

    @Test func clearingARangeDropsTheLogosOfSitesNothingUsesAnymore() throws {
        let rig = Rig()
        let folder = rig.dir.appendingPathComponent("Favicons", isDirectory: true)
        for name in ["gone.example", "kept.example", "intab.example"] { try TestIcon.png(side: 32, color: .systemOrange).write(to: folder.appendingPathComponent("\(name).png")) }
        rig.store.history.record(url: URL(string: "https://gone.example/x")!, title: "", at: Date().addingTimeInterval(-600))
        rig.store.history.record(url: URL(string: "https://www.kept.example/")!, title: "", at: Date().addingTimeInterval(-86400 * 3))
        let root = rig.space.unpinnedRootID
        _ = rig.store.edit { $0.addTab(url: URL(string: "https://intab.example/page")!, under: root, at: 0) }

        rig.store.clearHistory(since: Date().addingTimeInterval(-3600))

        #expect(rig.store.favicons.image(forHost: "gone.example") == nil)
        #expect(rig.store.favicons.image(forHost: "kept.example") != nil, "still in the history")
        #expect(rig.store.favicons.image(forHost: "intab.example") != nil, "still has a tab")
    }

    /// Deleting one row is a clear of one address, and the address can be in more places than the history.
    @Test func deletingOneHistoryRowForgetsItEverywhere() {
        let rig = Rig()
        let url = URL(string: "https://example.com/a?private=1")!
        let other = URL(string: "https://example.com/b")!
        var cleared = 0
        rig.store.onHistoryCleared = { cleared += 1 }
        rig.store.history.record(url: url, title: "A")
        rig.store.history.record(url: other, title: "B")
        rig.store.learned.record(query: "exa", candidateID: "hist:\(url.absoluteString)")
        rig.store.learned.record(query: "exa", candidateID: "hist:\(other.absoluteString)")
        rig.store.settings.menuBar.remember(url)

        rig.store.deleteHistoryEntry(url)

        #expect(rig.store.history.count() == 1)
        #expect(rig.store.settings.menuBar.lastAddress == nil, "the panel would have opened on it again")
        #expect(rig.store.learned.picks["exa"]?.keys.sorted() == ["hist:\(other.absoluteString)"])
        #expect(cleared == 1)
    }

    /// The files keep dated copies of themselves. What was forgotten must not be readable in those either, nor anywhere else
    /// in the data folder: not in the settings (the menu-bar page), not in what the Command Bar learned, and not in the
    /// sidebar's own copies, which list the page every tab was on at the time, including pages a tab has since left.
    @Test(arguments: ["all", "range", "one row", "one row, panel moved on"]) func clearingLeavesNothingReadableAnywhereInTheDataFolder(how: String) throws {
        let rig = Rig()
        let url = URL(string: "https://example.com/secret-page")!
        let tabPage = URL(string: "https://example.com/secret-tab-page")!
        rig.store.history.record(url: url, title: "Secret")
        rig.store.history.record(url: tabPage, title: "Secret tab")
        rig.store.learned.record(query: "secret query", candidateID: "hist:\(url.absoluteString)")
        rig.store.settings.menuBar.remember(url)
        let root = rig.space.unpinnedRootID
        let tab = try #require(rig.store.edit { $0.addTab(url: tabPage, under: root, at: 0) })
        rig.store.saveNow()
        rig.store.settings.menuBar.remember(URL(string: "https://example.com/other")!)
        rig.store.saveNow()
        // The tab goes on to another page; the copy of the sidebar made a moment ago still lists the one it left.
        rig.store.edit { $0.updateTab(tab) { $0.url = URL(string: "https://example.com/elsewhere") } }
        rig.store.settings.menuBar.remember(url)
        rig.store.saveNow()
        // An earlier version also kept dated copies of what the Command Bar learned.
        let backups = rig.dir.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try Data(#"{"picks":{"secret query":{}}}"#.utf8).write(to: backups.appendingPathComponent("command-bar-learning.2026-10-01-00-00-00-000.json"))
        func filesHolding(_ word: String) -> [String] {
            ((FileManager.default.enumerator(at: rig.dir, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []).filter { file in
                !file.hasDirectoryPath && ((try? Data(contentsOf: file)) ?? Data()).contains(Data(word.utf8))
            }.map { $0.path.replacingOccurrences(of: rig.dir.path, with: "") }
        }
        #expect(filesHolding("secret").contains { $0.contains("Backups/settings.") }, "the setup should have made a dated copy of the settings")
        #expect(filesHolding("secret-tab-page").contains { $0.contains("Backups/workspace.") }, "and of the sidebar, listing the page the tab left")

        switch how {
        case "all": rig.store.clearHistory()
        case "range": rig.store.clearHistory(since: Date().addingTimeInterval(-3600))
        case "one row": rig.store.deleteHistoryEntry(url); rig.store.deleteHistoryEntry(tabPage)
        default:
            rig.store.settings.menuBar.remember(URL(string: "https://example.com/moved-on"))
            rig.store.deleteHistoryEntry(url); rig.store.deleteHistoryEntry(tabPage)
        }
        rig.store.saveNow()

        #expect(filesHolding("secret") == [], "still readable")
    }

    /// An archived tab is a closed tab's address: deleting it, or clearing the Archive, takes the dated copies of the
    /// archive file with it.
    @Test func removingFromTheArchiveLeavesNoDatedCopyListingIt() throws {
        let rig = Rig()
        func entry(_ address: String) -> ArchivedItem {
            ArchivedItem(reason: .closed, spaceID: nil, items: [SidebarItem(content: .tab(TabData(url: URL(string: address)!, pageTitle: "Page")))])
        }
        let doomed = entry("https://example.com/secret-closed-one")
        let everything = entry("https://example.com/secret-closed-two")
        rig.store.archive.add(doomed)
        rig.store.archive.add(everything)
        rig.store.saveNow()
        rig.store.archive.add(entry("https://example.com/kept"))
        rig.store.saveNow()
        func filesHolding(_ word: String) -> [String] {
            ((FileManager.default.enumerator(at: rig.dir, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []).filter { file in
                !file.hasDirectoryPath && ((try? Data(contentsOf: file)) ?? Data()).contains(Data(word.utf8))
            }.map { $0.path }
        }
        #expect(filesHolding("secret-closed-one").contains { $0.contains("Backups/archive.") }, "the setup should have made a dated copy")

        rig.store.deleteArchived(doomed.id)
        rig.store.saveNow()
        #expect(filesHolding("secret-closed-one") == [])
        #expect(filesHolding("secret-closed-two") != [], "only that entry went")

        rig.store.clearArchive()
        rig.store.saveNow()
        #expect(filesHolding("secret-closed") == [])
    }

    /// An earlier version made dated copies of what the Command Bar learned and kept the typed things; they go on launch.
    @Test func anOlderLearningFileAndItsCopiesAreCleanedOnLaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-upgrade-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Backups", isDirectory: true), withIntermediateDirectories: true)
        let old = #"{"maxQueries":600,"picks":{"typed words":{"web:typed words":{"count":1,"lastAt":"2026-10-20T10:00:00Z"},"hist:https://example.com/":{"count":1,"lastAt":"2026-10-20T10:00:00Z"}}}}"#
        try Data(old.utf8).write(to: dir.appendingPathComponent("command-bar-learning.json"))
        try Data(old.utf8).write(to: dir.appendingPathComponent("Backups/command-bar-learning.2026-10-20-10-00-00-000.json"))

        let store = BrowserStore(directory: dir)

        #expect(store.learned.picks["typed words"]?.keys.sorted() == ["hist:https://example.com/"], "what was typed as an address or search is gone, the page pick stays")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Backups/command-bar-learning.2026-10-20-10-00-00-000.json").path))
        let saved = try String(contentsOf: dir.appendingPathComponent("command-bar-learning.json"), encoding: .utf8)
        #expect(!saved.contains("web:typed words"))
    }

    /// The menu-bar page keeps its fragment, a history row does not: it is the same page.
    @Test func deletingTheRowOfThePageThePanelIsOnForgetsItWhateverItsFragment() {
        let rig = Rig()
        rig.store.history.record(url: URL(string: "https://example.com/a")!, title: "A")
        rig.store.settings.menuBar.remember(URL(string: "https://example.com/a#section")!)
        rig.store.deleteHistoryEntry(URL(string: "https://example.com/a")!)
        #expect(rig.store.settings.menuBar.lastAddress == nil)
    }

    @Test func deletingAnotherRowLeavesTheMenuBarPageAlone() {
        let rig = Rig()
        var cleared = 0
        rig.store.onHistoryCleared = { cleared += 1 }
        rig.store.history.record(url: URL(string: "https://example.com/b")!, title: "B")
        rig.store.settings.menuBar.remember(URL(string: "https://example.com/a")!)

        rig.store.deleteHistoryEntry(URL(string: "https://example.com/b")!)

        #expect(rig.store.settings.menuBar.lastAddress == "https://example.com/a")
        #expect(cleared == 0)
    }

    /// Every control that clears history goes through the store, which knows everything that has to be forgotten with it.
    @Test func noInterfaceCodeClearsTheHistoryStoreDirectly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        for folder in ["Sources/CosmosKit/UI", "Sources/CosmosKit/Settings", "Sources/CosmosKit/App"] {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
                for (index, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated() where line.contains("history.clear(") || line.contains("history.delete(") {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "use store.clearHistory(since:) or store.deleteHistoryEntry: \(offenders.joined(separator: ", "))")
    }

    @Test func clearingTheHistoryDropsThePageThePanelStillHolds() {
        let rig = Rig()
        let browser = MenuBarBrowser(store: rig.store, openInCosmos: { _ in }, showSettings: {}, showBrowser: {})
        rig.store.onHistoryCleared = { [weak browser] in browser?.forgetPage() }
        _ = browser.session.prepare()
        #expect(browser.session.runtime != nil)
        rig.store.clearHistory()
        #expect(browser.session.runtime == nil, "its back and forward list went with it")
    }

    @Test func rememberingThePageTheyAreOnDoesNotTellTheApp() {
        let rig = Rig()
        var told = 0
        rig.store.onMenuBarChange = { told += 1 }
        rig.store.settings.menuBar.remember(URL(string: "https://example.com/a"))
        rig.store.settings.menuBar.remember(URL(string: "https://example.com/b"))
        #expect(told == 0)
        #expect(rig.store.settings.menuBar.lastAddress == "https://example.com/b")
        rig.store.settings.menuBar.homeAddress = "example.org"
        #expect(told == 1)
    }
}

@MainActor
@Suite struct MenuBarCommandTests {
    /// With the panel holding the keyboard, ⌘T, ⌘D, ⌘F and the rest of the menu would run on the last browser window,
    /// which is somewhere the person is not looking. Commands that need a browser window are off while the panel is key.
    @Test func windowCommandsAreOffWhileThePanelHasTheKeyboard() {
        _ = NSApplication.shared
        let panel = MenuBarPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled], backing: .buffered, defer: true)
        #expect(!CosmosAppDelegate.windowCommandsApply(keyWindow: panel))
        #expect(CosmosAppDelegate.windowCommandsApply(keyWindow: other))
        #expect(CosmosAppDelegate.windowCommandsApply(keyWindow: nil))
    }
}
