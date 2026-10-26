import AppKit
import Foundation
import Testing
import WebKit
@testable import CosmosKit
@testable import CosmosCore

/// The page behind the menu-bar browser: the same profile data store as the browser windows, so the cookies and logins
/// are shared, and the small differences a panel needs.
@MainActor
@Suite struct MenuBarSessionTests {
    private func html(_ body: String) -> SiteServer.Route { .init(type: "text/html", body: Data(body.utf8)) }

    private func waitFor(_ seconds: Double = 5, _ condition: () -> Bool) async throws {
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

    @Test func changingTheMenuBarSettingsTellsTheApp() {
        let rig = Rig()
        var told = 0
        rig.store.onMenuBarChange = { told += 1 }
        rig.store.settings.menuBar.enabled = true
        rig.store.settings.menuBar.layout = .desktop
        rig.store.settings.radialMenu.enabled = false
        #expect(told == 2, "only the menu-bar settings count")
    }
}
