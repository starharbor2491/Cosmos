import CryptoKit
import Foundation
import Testing
import CosmosEngine
@testable import CosmosKit
@testable import CosmosCore

/// A store backed by a throwaway directory, with a window on the first space.
@MainActor
final class Rig {
    /// The saved passwords' key in tests: the Mac's Keychain is never reached.
    nonisolated static let passwordKey = SymmetricKey(size: .bits256)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-test-\(UUID().uuidString)", isDirectory: true)
    let store: BrowserStore
    let window: WindowState

    init(seed: Bool = false, engine: BrowserEngine? = nil) {
        store = BrowserStore(directory: dir, engine: engine ?? FakeEngine(), passwordKey: { Rig.passwordKey })
        window = store.makeWindowState()
        store.register(window)
        if seed { DemoSeed.populate(store) }
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    var space: Space { store.workspace.space(window.focusedSpaceID)! }
    var today: [SidebarItem] { store.workspace.unpinned(in: space) }
}

@MainActor
@Suite struct StoreTests {
    @Test func newTabIsSelectedAndLandsAtTopOfToday() {
        let rig = Rig()
        let a = rig.store.newTab(url: URL(string: "about:blank?a"), in: rig.window)
        let b = rig.store.newTab(url: URL(string: "about:blank?b"), in: rig.window)
        #expect(rig.today.map(\.id) == [b, a].compactMap { $0 })
        #expect(rig.window.selectedItemID == b)
        #expect(rig.store.workspace.problems().isEmpty)
    }

    /// The engine keeps a history of its own in each profile: forgetting a page, or a range, reaches every profile's,
    /// including one where no page has been opened.
    @Test func forgettingHistoryReachesTheEnginesOwnInEveryProfile() async throws {
        let engine = FakeEngine()
        let rig = Rig(engine: engine)
        let work = rig.store.addProfile(named: "Work")
        let url = URL(string: "https://example.com/a#part")!
        let since = Date().addingTimeInterval(-3600)
        rig.store.deleteHistoryEntry(url)
        rig.store.clearHistory(since: since)
        rig.store.clearHistory()
        let ids = rig.store.workspace.profiles.map(\.id)
        #expect(ids.count == 2 && ids.contains(work))
        func engineProfile(_ id: UUID) -> FakeProfile? { engine.profiles.first { $0.id == id } }
        for _ in 0..<100 where ids.contains(where: { (engineProfile($0)?.clearedHistory.count ?? 0) < 2 }) { try await Task.sleep(for: .milliseconds(10)) }
        for id in ids {
            let profile = try #require(engineProfile(id))
            #expect(profile.deletedHistory == [url])
            #expect(profile.clearedHistory.count == 2 && profile.clearedHistory.contains(since) && profile.clearedHistory.contains(nil))
        }
    }

    @Test func closingATodayTabArchivesItAndReopenRestoresIt() throws {
        let rig = Rig()
        let id = try #require(rig.store.newTab(url: URL(string: "https://example.com/page"), in: rig.window))
        rig.store.closeTab(id, in: rig.window)
        #expect(rig.store.workspace.item(id) == nil)
        #expect(rig.store.archive.entries.count == 1)
        #expect(rig.store.archive.entries.first?.reason == .closed)

        rig.store.reopenLastClosed(in: rig.window)
        #expect(rig.store.archive.entries.isEmpty)
        let restored = try #require(rig.today.first)
        #expect(restored.tab?.url?.absoluteString == "https://example.com/page")
        #expect(rig.window.selectedItemID == restored.id)
    }

    @Test func blankTabsAreNotWorthArchiving() throws {
        let rig = Rig()
        let id = try #require(rig.store.newTab(url: nil, in: rig.window))
        rig.store.closeTab(id, in: rig.window)
        #expect(rig.store.workspace.item(id) == nil)
        #expect(rig.store.archive.entries.isEmpty)
    }

    @Test func pinnedTabsSleepInsteadOfClosing() throws {
        let rig = Rig()
        let id = try #require(rig.store.newTab(url: URL(string: "https://example.com/pinned"), in: rig.window))
        rig.store.togglePin(id, in: rig.window)
        #expect(rig.store.workspace.section(of: id) == .pinned(spaceID: rig.space.id))
        rig.store.closeTab(id, in: rig.window)
        #expect(rig.store.workspace.item(id) != nil)
        #expect(rig.store.archive.entries.isEmpty)
    }

    @Test func clearUnpinnedKeepsTheSelectedTabAndPinned() throws {
        let rig = Rig()
        let pinned = try #require(rig.store.newTab(url: URL(string: "about:blank?pin"), in: rig.window))
        rig.store.togglePin(pinned, in: rig.window)
        for i in 0..<3 { rig.store.newTab(url: URL(string: "about:blank?\(i)"), in: rig.window) }
        rig.store.clearUnpinned(in: rig.window)
        #expect(rig.today.count == 1)                    // the selected one stays
        #expect(rig.store.archive.entries.count == 2)         // three Today tabs, the selected one stays
        #expect(rig.store.workspace.item(pinned) != nil)
    }

    @Test func splitViewPairsTabsAndClosingAPaneLeavesTheOtherSelected() throws {
        let rig = Rig()
        let first = try #require(rig.store.newTab(url: URL(string: "about:blank?one"), in: rig.window))
        rig.store.addSplit(in: rig.window, with: URL(string: "about:blank?two"))
        let splitID = try #require(rig.window.selectedItemID)
        #expect(rig.store.workspace.item(splitID)?.isSplit == true)
        #expect(rig.store.workspace.item(splitID)?.childIDs.count == 2)

        rig.store.closeFocusedPane(in: rig.window)
        #expect(rig.store.workspace.item(splitID) == nil)
        #expect(rig.window.selectedItemID == first)
        #expect(rig.store.workspace.problems().isEmpty)
    }

    @Test func spacesSwitchWrapAndDeleteKeepTabsInTheArchive() throws {
        let rig = Rig(seed: true)
        #expect(rig.store.workspace.spaces.count == 3)
        let first = rig.window.focusedSpaceID
        rig.store.cycleSpace(1, in: rig.window)
        #expect(rig.window.focusedSpaceID != first)
        rig.store.cycleSpace(-1, in: rig.window)
        #expect(rig.window.focusedSpaceID == first)
        rig.store.switchSpace(number: 3, in: rig.window)
        let last = rig.window.focusedSpaceID
        let tabsBefore = rig.store.workspace.allTabs().count
        rig.store.deleteSpace(last, in: rig.window)
        #expect(rig.store.workspace.spaces.count == 2)
        #expect(rig.window.focusedSpaceID != last)
        #expect(rig.store.archive.entries.count > 0)
        #expect(rig.store.workspace.allTabs().count < tabsBefore)
        #expect(rig.store.workspace.problems().isEmpty)
    }

    @Test func pinningAPaneOfTheSelectedSplitLeavesTheWindowOnTheOtherPane() throws {
        let rig = Rig()
        let a = try #require(rig.store.newTab(url: URL(string: "about:blank?a"), in: rig.window))
        let b = try #require(rig.store.newTab(url: URL(string: "about:blank?b"), in: rig.window))
        rig.store.splitWith(a, dragged: b, in: rig.window)
        let split = try #require(rig.window.selectedItemID)
        #expect(rig.store.workspace.item(split)?.isSplit == true)
        rig.store.togglePin(b, in: rig.window)
        #expect(rig.store.workspace.item(split) == nil)
        let selected = try #require(rig.window.selectedItemID)
        #expect(selected == a)
        #expect(rig.store.workspace.item(selected) != nil)
    }

    /// A page a script or a link opened in a new window is already made (and loading) in the engine: it becomes the new,
    /// selected tab with that very page, not a fresh page that would lose its opener.
    @Test func aPageTheEngineOpenedBecomesASelectedTabWithThatPage() throws {
        let rig = Rig()
        let opener = try #require(rig.store.newTab(url: URL(string: "https://example.com/opener"), in: rig.window))
        let openerRuntime = try #require(rig.store.runtime(forItem: opener, in: rig.window))
        let profile = try #require(rig.store.fakeEngine.profiles.first)
        let opened = profile.open(NewPageRequest(url: URL(string: "https://example.com/child"), userGesture: true), from: openerRuntime.fake)
        #expect(opened.kept)
        let child = try #require(rig.window.selectedItemID)
        #expect(child != opener)
        #expect(rig.store.runtime(forItem: child, in: rig.window)?.page === opened.page)
        #expect(opened.page.loads.isEmpty, "the engine is loading it already")
        #expect(rig.store.workspace.item(child)?.tab?.url?.absoluteString == "https://example.com/child")
        #expect(rig.store.workspace.allTabs().count == 2)
        #expect(rig.store.workspace.problems().isEmpty)
    }

    @Test func eachProfileHasItsOwnEngineFolderAndIncognitoHasNone() throws {
        let rig = Rig()
        rig.store.newTab(url: URL(string: "https://example.com/"), in: rig.window)
        let profile = try #require(rig.store.fakeEngine.profiles.first)
        #expect(profile.id == rig.space.profileID)
        #expect(profile.directory?.path == rig.dir.appendingPathComponent("Engine Profiles/\(rig.space.profileID.uuidString)").path)

        let incognito = BrowserStore(directory: nil, incognito: true, engine: FakeEngine())
        let window = incognito.makeWindowState()
        incognito.register(window)
        incognito.newTab(url: URL(string: "https://example.com/"), in: window)
        #expect(!incognito.fakeEngine.profiles.isEmpty)
        #expect(incognito.fakeEngine.profiles.allSatisfy { $0.id == nil && $0.directory == nil })
    }

    /// The engine stopped (a settings change, a crash): its pages are gone, so the tabs on screen get new ones and load.
    @Test func whenTheEngineRestartsTheTabsOnScreenGetNewPages() throws {
        let rig = Rig()
        let id = try #require(rig.store.newTab(url: URL(string: "https://example.com/a"), in: rig.window))
        let old = try #require(rig.store.runtime(forItem: id, in: rig.window))
        let profile = try #require(rig.store.fakeEngine.profiles.first)
        profile.restart()
        let new = try #require(rig.store.runtime(forItem: id, in: rig.window))
        #expect(new !== old)
        #expect(old.fake.isClosed)
        #expect(new.fake.loads == [URL(string: "https://example.com/a")!])
    }

    /// The memory saver counts from when a tab was last looked at: one the user just left after half an hour on it is not
    /// idle, however long ago it was first selected.
    @Test func aTabJustLeftIsNotPutToSleepAtOnce() throws {
        let rig = Rig()
        rig.store.settings.memorySaverMinutes = 10
        let a = try #require(rig.store.newTab(url: URL(string: "https://example.com/a"), in: rig.window))
        try #require(rig.store.runtime(forItem: a, in: rig.window)).lastActivity = Date().addingTimeInterval(-30 * 60)
        rig.store.newTab(url: URL(string: "https://example.com/b"), in: rig.window)
        rig.store.discardIdleRuntimes()
        #expect(rig.store.runtime(forItem: a, in: rig.window) != nil)
    }

    /// Replacing everything (an Arc import) takes the spaces the windows were on: they move to one that is there, or every
    /// command that works on "this space" quietly does nothing.
    @Test func aWindowWhoseSpaceIsGoneMovesToOneThatIsThere() throws {
        let rig = Rig()
        rig.store.edit { $0 = Workspace.fresh(spaceTitle: "Imported") }
        #expect(rig.store.workspace.space(rig.window.focusedSpaceID) != nil)
        #expect(rig.store.newTab(url: URL(string: "https://example.com/"), in: rig.window) != nil)
    }

    /// "Close the window with its last tab": with it on, the ⌘W that closes the last tab closes the window too; with it
    /// off the window stays, empty, until the next ⌘W.
    @Test func closingTheLastTabClosesTheWindowOnlyWithTheSettingOn() {
        let rig = Rig()
        var closed = 0
        rig.store.onCloseWindowRequest = { _ in closed += 1 }
        rig.store.newTab(url: URL(string: "https://example.com/a"), in: rig.window)
        rig.store.closeSelected(in: rig.window)
        #expect(closed == 0)
        #expect(rig.window.selectedItemID == nil)
        rig.store.closeSelected(in: rig.window)
        #expect(closed == 1, "⌘W on an empty window closes it")

        rig.store.settings.closeWindowOnLastTab = true
        rig.store.newTab(url: URL(string: "https://example.com/b"), in: rig.window)
        rig.store.closeSelected(in: rig.window)
        #expect(closed == 2)
    }

    @Test func workspaceSurvivesARestart() throws {
        let rig = Rig(seed: true)
        rig.store.newTab(url: URL(string: "https://example.com/saved"), in: rig.window)
        rig.store.switchSpace(number: 2, in: rig.window)
        rig.store.saveSession()
        rig.store.saveNow()

        let reopened = BrowserStore(directory: rig.dir, engine: FakeEngine())
        #expect(reopened.workspace.allTabs().count == rig.store.workspace.allTabs().count)
        #expect(reopened.workspace.spaces.map(\.title) == rig.store.workspace.spaces.map(\.title))
        let state = reopened.makeWindowState(restoring: 0)
        #expect(state.focusedSpaceID == rig.window.focusedSpaceID)
    }

    @Test func demoSeedOnlyFillsAnEmptyWorkspace() {
        let rig = Rig(seed: true)
        let tabs = rig.store.workspace.allTabs().count
        DemoSeed.populate(rig.store)
        #expect(rig.store.workspace.allTabs().count == tabs)
        #expect(rig.store.workspace.problems().isEmpty)
    }

    @Test func anIncognitoStoreKeepsNothing() throws {
        let incognito = BrowserStore(directory: nil, incognito: true, engine: FakeEngine())
        let window = incognito.makeWindowState()
        incognito.register(window)
        let id = try #require(incognito.newTab(url: URL(string: "about:blank?x"), in: window))
        incognito.closeTab(id, in: window)
        #expect(incognito.archive.entries.isEmpty)
        #expect(incognito.dataDirectory == nil)
    }

    /// A private window keeps nothing, so nothing is imported into one: what was brought over would be gone when it closes.
    @Test func aPrivateWindowOffersNothingToImport() async {
        let incognito = BrowserStore(directory: nil, incognito: true, engine: FakeEngine())
        #expect(await ImportCoordinator.sources(for: incognito).isEmpty)
    }

    @Test func permissionAnswersAreRememberedPerSiteAndCanBeReset() throws {
        let rig = Rig()
        _ = try #require(rig.store.newTab(url: URL(string: "about:blank?perm"), in: rig.window))
        let runtime = try #require(rig.store.currentRuntime(in: rig.window))
        rig.store.tab(runtime, remember: true, forPermission: "meet.example|camera")
        rig.store.tab(runtime, remember: false, forPermission: "meet.example|microphone")
        #expect(rig.store.settings.permissionDecisions["meet.example|camera"] == true)
        #expect(rig.store.settings.permissionDecisions["meet.example|microphone"] == false)
        rig.store.tab(runtime, remember: nil, forPermission: "meet.example|camera")
        #expect(rig.store.settings.permissionDecisions["meet.example|camera"] == nil)
    }

    @Test func incognitoNeverRemembersPermissions() throws {
        let incognito = BrowserStore(directory: nil, incognito: true, engine: FakeEngine())
        let window = incognito.makeWindowState()
        incognito.register(window)
        _ = try #require(incognito.newTab(url: URL(string: "about:blank?perm"), in: window))
        let runtime = try #require(incognito.currentRuntime(in: window))
        incognito.tab(runtime, remember: true, forPermission: "meet.example|camera")
        #expect(incognito.settings.permissionDecisions.isEmpty)
    }
}
