import AppKit
import Foundation
import Testing
import CosmosEngine
@testable import CosmosKit
@testable import CosmosCore

/// Settings ▸ Features: one switch per feature. Off, a feature has no menu items, commands or buttons and does no work;
/// on again, it is as it was.
@MainActor
@Suite struct FeatureTests {
    @Test func everyFeatureHasOneGroupATitleAndALine() {
        #expect(Set(Feature.Group.allCases.flatMap(\.features)) == Set(Feature.allCases))
        #expect(Feature.Group.allCases.flatMap(\.features).count == Feature.allCases.count, "no feature is in two groups")
        for feature in Feature.allCases {
            #expect(!feature.title.isEmpty && !feature.detail.isEmpty && !feature.symbol.isEmpty)
        }
    }

    /// The switches that already had a place of their own (Blocking, Radial Menu…) are those same settings, so the two
    /// places always agree; the others are kept by name.
    @Test func eachSwitchTurnsItsFeatureOffAndOnAgain() {
        for feature in Feature.allCases {
            var s = Settings()
            s.set(feature, on: true)
            #expect(s.isOn(feature), "\(feature)")
            s.set(feature, on: false)
            #expect(!s.isOn(feature), "\(feature)")
            #expect(s.featuresOn == Feature.allCases.filter { $0 != feature && ($0 != .menuBarBrowser) }, "only \(feature) changed")
            s.set(feature, on: true)
            #expect(s.isOn(feature))
        }
        var s = Settings()
        s.set(.adBlocking, on: false)
        #expect(!s.adBlockingEnabled)
        s.set(.radialMenu, on: false)
        #expect(!s.radialMenu.enabled)
        s.menuBar.enabled = true
        #expect(s.isOn(.menuBarBrowser))
    }

    /// A new install starts quieter (right-click and the window's edge as macOS has them); everything else is on.
    @Test func aNewInstallStartsWithTheRadialMenuAndTheRailOff() {
        var s = Settings()
        s.useNewInstallDefaults()
        #expect(!s.isOn(.radialMenu) && !s.isOn(.utilities))
        #expect(s.featuresOn == Feature.allCases.filter { ![.radialMenu, .utilities, .menuBarBrowser].contains($0) })
    }

    @Test func theSwitchesAreSavedAndAFeatureNameFromAnotherBuildIsKept() throws {
        var s = Settings()
        s.set(.boosts, on: false)
        s.set(.peek, on: false)
        s.disabledFeatures.insert("somethingNewer")
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(!back.isOn(.boosts) && !back.isOn(.peek) && back.isOn(.extensions))
        #expect(back.disabledFeatures.contains("somethingNewer"))
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"adBlockingEnabled": false}"#.utf8))
        #expect(old.featuresOn == Feature.allCases.filter { $0 != .adBlocking && $0 != .menuBarBrowser }, "a file from before has everything else on")
    }

    @Test func boostsOffLeaveSitesAsTheyComeAndKeepTheBoosts() throws {
        let rig = Rig()
        _ = rig.store.environment(forProfile: rig.store.workspace.profiles[0].id)
        let profile = try #require(rig.store.fakeEngine.profiles.first { $0.id != nil })
        rig.store.boosts.boosts.append(Boost(name: "Big", hostPatterns: ["example.com"], css: "body { font-size: 30px }", zoom: 1.5))
        let withBoosts = profile.scripts.count
        #expect(withBoosts > 1)
        let tab = try #require(rig.store.newTab(url: URL(string: "https://example.com/"), in: rig.window).flatMap { rig.store.runtime(forItem: $0, in: rig.window) })
        #expect(rig.store.tab(tab, boostZoomFor: "example.com") == 1.5)

        rig.store.settings.set(.boosts, on: false)
        #expect(profile.scripts.count == 1, "only Cosmos's own page agent")
        #expect(rig.store.tab(tab, boostZoomFor: "example.com") == nil)
        #expect(rig.store.boosts.boosts.count == 1, "the Boost is kept")
        rig.window.overlay = nil
        rig.store.perform(.showBoosts, in: rig.window)
        #expect(rig.window.overlay == nil, "its command does nothing")

        rig.store.settings.set(.boosts, on: true)
        #expect(profile.scripts.count == withBoosts)
    }

    @Test func peekOffOpensAnOrdinaryTab() {
        let rig = Rig()
        rig.store.settings.set(.peek, on: false)
        let before = rig.store.workspace.items.count
        rig.store.openPeek(URL(string: "https://example.com/look")!, from: nil, in: rig.window)
        #expect(rig.window.peek == nil)
        #expect(rig.store.workspace.items.count == before + 1)
        #expect(rig.store.currentURL(in: rig.window)?.absoluteString == "https://example.com/look")

        rig.store.settings.set(.peek, on: true)
        rig.store.openPeek(URL(string: "https://example.com/again")!, from: nil, in: rig.window)
        #expect(rig.window.peek != nil)
        rig.store.settings.set(.peek, on: false)
        #expect(rig.window.peek == nil, "switching it off closes the one that is open")
    }

    @Test func utilitiesOffTakeTheRailAwayInEveryWindowAndBringItBack() {
        let rig = Rig()
        let other = rig.store.makeWindowState()
        rig.store.register(other)
        rig.window.utility = .zoom
        #expect(rig.window.railShown && other.railShown)
        rig.store.settings.set(.utilities, on: false)
        #expect(!rig.window.railShown && !other.railShown)
        #expect(rig.window.utility == nil)
        #expect(rig.window.utilitiesVisible, "the window's own choice is kept")
        rig.store.perform(.toggleUtilities, in: rig.window)
        #expect(rig.window.utilitiesVisible, "its command does nothing")
        let later = rig.store.makeWindowState()
        rig.store.register(later)
        #expect(!later.railShown, "a window opened while it is off has none either")
        rig.store.settings.set(.utilities, on: true)
        #expect(rig.window.railShown && other.railShown && later.railShown)
    }

    @Test func aSwitchedOffFeaturesCommandsAreNotOffered() {
        let rig = Rig()
        func offered(_ command: BrowserCommand) -> Bool {
            let model = CommandBarModel(store: rig.store, window: rig.window, mode: .newTab)
            model.textChanged(command.title)
            return model.rows.contains { $0.id == "cmd:\(command.rawValue)" }
        }
        let gated = BrowserCommand.allCases.filter { $0.feature != nil }
        #expect(Set(gated) == [.showBoosts, .manageExtensions, .fillPassword, .toggleUtilities])
        for command in gated { #expect(offered(command), "\(command) while on") }
        for feature in Feature.allCases { rig.store.settings.set(feature, on: false) }
        for command in gated { #expect(!offered(command), "\(command) while off") }
        #expect(offered(.reload), "the rest are as they were")
    }

    @Test func aSwitchedOffFeaturesMenuItemsAreHiddenAndDoNothing() throws {
        let delegate = CosmosAppDelegate(options: LaunchOptions())
        let menu = delegate.makeMainMenu()
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        let featured = items(menu).filter { ($0.representedObject as? MenuAction)?.feature != nil }
        #expect(Set(featured.compactMap { ($0.representedObject as? MenuAction)?.feature }) == [.extensions, .passwords, .utilities, .peek, .boosts])
        var settings = Settings()
        CosmosAppDelegate.showFeatureItems(in: menu, settings: settings)
        #expect(featured.allSatisfy { !$0.isHidden })
        settings.set(.boosts, on: false)
        CosmosAppDelegate.showFeatureItems(in: menu, settings: settings)
        let boost = try #require(featured.first { $0.title == "Boost This Site…" })
        #expect(boost.isHidden && !boost.allowsKeyEquivalentWhenHidden, "hidden, and its ⌥⌘B goes with it")
        #expect(featured.filter(\.isHidden) == [boost])
    }

    @Test func passwordsOffOfferNoFill() async {
        let rig = Rig()
        rig.store.settings.set(.passwords, on: false)
        rig.window.toast = nil
        rig.store.perform(.fillPassword, in: rig.window)
        #expect(rig.window.toast == nil, "not even to say there is nothing to fill")
        rig.window.utility = .passwords
        rig.store.settings.set(.passwords, on: true)
        rig.store.settings.set(.passwords, on: false)
        #expect(rig.window.utility == nil)
    }

    /// Off, saving and filling passwords does not even open the vault: a sign-in form on a page asks the Keychain nothing.
    @Test func passwordsOffNeverOpenTheVault() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-vault-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        BrowserStore(directory: dir, engine: FakeEngine(), passwordKey: { Rig.passwordKey })
            .passwords.save(origin: "https://example.com", username: "me", password: "secret")
        final class Count { var asked = 0 }
        let count = Count()
        let store = BrowserStore(directory: dir, engine: FakeEngine(), passwordKey: { count.asked += 1; return Rig.passwordKey })
        let window = store.makeWindowState()
        store.register(window)
        store.settings.set(.passwords, on: false)
        let id = try #require(store.newTab(url: URL(string: "https://example.com/login"), in: window))
        let tab = try #require(store.runtime(forItem: id, in: window))
        tab.handleAgentMessage(["type": "loginForm", "frameOrigin": "https://example.com"], fromMainFrame: true)
        #expect(count.asked == 0, "the vault stays shut")
        #expect(tab.savedLogins.isEmpty)

        store.settings.set(.passwords, on: true)
        tab.handleAgentMessage(["type": "loginForm", "frameOrigin": "https://example.com"], fromMainFrame: true)
        #expect(count.asked == 1)
        #expect(tab.savedLogins.map(\.username) == ["me"])
    }

    /// Switched off, Boosts leave the pages already open too (their styles go at once), and switched on they come back.
    @Test func boostsSwitchedReachThePagesAlreadyOpen() async throws {
        let rig = Rig()
        let boost = Boost(name: "Big", hostPatterns: ["example.com"], css: "body { font-size: 30px }")
        rig.store.boosts.boosts.append(boost)
        let tab = try #require(rig.store.newTab(url: URL(string: "https://example.com/"), in: rig.window).flatMap { rig.store.runtime(forItem: $0, in: rig.window) })
        let page = try #require(tab.page as? FakePage)
        page.navigate(to: URL(string: "https://example.com/")!)
        func scripts(_ text: String) -> Int { page.evaluated.filter { $0.script.contains("cosmos-boost-\(boost.id.uuidString)") && $0.script.contains(text) }.count }
        try await Task.sleep(for: .milliseconds(50))   // what the page was sent as it opened lands first
        let removals = scripts(".remove()"), styles = scripts("createElement('style')")
        rig.store.settings.set(.boosts, on: false)
        await until { scripts(".remove()") > removals }
        #expect(scripts(".remove()") == removals + 1)
        rig.store.settings.set(.boosts, on: true)
        await until { scripts("createElement('style')") > styles }
        #expect(scripts("createElement('style')") == styles + 1)
    }

    /// A pinned tab's page is told whether links leaving the site open in Peek when it loads, and again when Peek is
    /// switched on or off, so the change does not wait for a reload.
    @Test func openPagesHearWhenPeekIsSwitched() async throws {
        let rig = Rig()
        let id = try #require(rig.store.newTab(url: URL(string: "https://example.com/"), in: rig.window))
        rig.store.togglePin(id, in: rig.window)
        let tab = try #require(rig.store.runtime(forItem: id, in: rig.window))
        let page = try #require(tab.page as? FakePage)
        func told(_ peek: Bool) -> Int { page.evaluated.filter { $0.script.contains("peekCrossSite: \(peek)") }.count }
        try await Task.sleep(for: .milliseconds(50))   // what the page was sent as it opened lands first
        let off = told(false), on = told(true)
        rig.store.settings.set(.peek, on: false)
        await until { told(false) > off }
        #expect(told(false) == off + 1)
        rig.store.settings.set(.peek, on: true)
        await until { told(true) > on }
        #expect(told(true) == on + 1)
    }

    /// A hard press on a link is a quick look; with Peek off there is none, and it does not open a tab instead.
    @Test func aHardPressDoesNothingWithPeekOff() throws {
        let rig = Rig()
        let tab = try #require(rig.store.newTab(url: URL(string: "https://example.com/"), in: rig.window).flatMap { rig.store.runtime(forItem: $0, in: rig.window) })
        rig.store.settings.set(.peek, on: false)
        tab.handleAgentMessage(["type": "hover", "href": "https://example.org/elsewhere"], fromMainFrame: true)
        let before = rig.store.workspace.items.count
        tab.pageDidForceClick(tab.page)
        #expect(rig.store.workspace.items.count == before)
        #expect(rig.window.peek == nil)
    }

    @Test func aPrivateWindowHasTheSameFeaturesOff() {
        let rig = Rig()
        rig.store.settings.set(.boosts, on: false)
        rig.store.settings.set(.spaceSwipe, on: false)
        let incognito = BrowserStore(directory: nil, incognito: true, engine: FakeEngine())
        incognito.inheritPreferences(from: rig.store)
        #expect(!incognito.settings.isOn(.boosts) && !incognito.settings.isOn(.spaceSwipe))
        #expect(incognito.settings.isOn(.extensions))
        #expect(!incognito.settings.isOn(.menuBarBrowser), "the menu-bar browser is the regular browser's alone")
    }

    @Test func settingsListsEveryPaneOnceInItsGroups() {
        let listed = SettingsTab.groups.flatMap(\.tabs)
        #expect(listed.count == SettingsTab.allCases.count && Set(listed) == Set(SettingsTab.allCases))
        #expect(SettingsTab.groups.allSatisfy { $0.tabs.count <= 5 }, "small groups")
    }

    // MARK: Extensions

    private func extensionRig() async throws -> (Rig, ExtensionCenter, FakeExtensions, URL) {
        let rig = Rig()
        let center = ExtensionCenter(store: rig.store, directory: rig.dir)
        rig.store.extensionCenter = center
        _ = rig.store.newTab(url: URL(string: "https://example.com/"), in: rig.window)
        center.start()
        let engine = try #require(rig.store.fakeEngine.profiles.first?.fakeExtensions)
        let source = rig.dir.appendingPathComponent("src-ext", isDirectory: true)
        try ExtensionTests().writeTestExtension(to: source)
        return (rig, center, engine, source)
    }

    private func until(_ done: () -> Bool) async {
        for _ in 0..<100 where !done() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func extensionsOffUnloadEveryOneAndKeepThem() async throws {
        let (rig, center, engine, source) = try await extensionRig()
        try await center.install(from: source, origin: "a test folder") { _ in true }
        #expect(engine.loaded.count == 1)
        engine.buttons = [ExtensionAction(extensionID: engine.loaded.keys.first!, title: "Test")]
        #expect(center.actions(for: rig.store.currentRuntime(in: rig.window)).count == 1)

        rig.store.settings.set(.extensions, on: false)
        await until { engine.loaded.isEmpty }
        #expect(engine.loaded.isEmpty, "none runs")
        #expect(center.items.count == 1 && center.items[0].enabled, "kept, and still on for when they are back")
        #expect(center.actions(for: rig.store.currentRuntime(in: rig.window)).isEmpty, "no buttons")
        #expect(await center.checkForUpdates() == 0, "no update checks")

        rig.store.settings.set(.extensions, on: true)
        await until { engine.loaded.count == 1 }
        #expect(engine.loaded.count == 1, "back as it was")
    }

    /// Flipped quickly, while Chromium is still loading or unloading, extensions end as the last switch says: none running
    /// when it is off, each running once when it is on.
    @Test func flippingExtensionsQuicklyEndsAsTheLastSwitchSays() async throws {
        let (rig, center, engine, source) = try await extensionRig()
        try await center.install(from: source, origin: "a test folder") { _ in true }
        engine.delay = .milliseconds(40)
        for (switches, running) in [([false, true, false], 0), ([true, false, true], 1), ([false, true, false, true, false], 0)] {
            for on in switches {
                rig.store.settings.set(.extensions, on: on)
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(600))
            #expect(engine.loaded.count == running, "after \(switches)")
        }
        #expect(engine.mostAtOnce == 1, "never two loads of it at once")
    }

    @Test func anExtensionAddedWhileTheyAreOffWaitsForThem() async throws {
        let (rig, center, engine, source) = try await extensionRig()
        rig.store.settings.set(.extensions, on: false)
        try await center.install(from: source, origin: "a test folder") { _ in true }
        #expect(center.items.count == 1 && engine.loaded.isEmpty)
        #expect(center.message?.contains("switched off") == true)
        rig.store.settings.set(.extensions, on: true)
        await until { engine.loaded.count == 1 }
        #expect(engine.loaded.count == 1)
    }
}
