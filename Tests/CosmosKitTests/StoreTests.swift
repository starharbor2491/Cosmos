import Foundation
import Testing
import WebKit
@testable import CosmosKit
@testable import CosmosCore

/// A store backed by a throwaway directory, with a window on the first space.
@MainActor
final class Rig {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-test-\(UUID().uuidString)", isDirectory: true)
    let store: BrowserStore
    let window: WindowState

    init(seed: Bool = false) {
        store = BrowserStore(directory: dir)
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

    /// WebKit raises an exception, and the app dies, if the page it gets back for `window.open()` was not built from
    /// the configuration it handed over.
    @Test func aScriptOpenedWindowIsBuiltFromTheConfigurationWebKitGave() throws {
        let rig = Rig()
        let opener = try #require(rig.store.newTab(url: URL(string: "about:blank?opener"), in: rig.window))
        let openerRuntime = try #require(rig.store.runtime(forItem: opener, in: rig.window))
        let configuration = WKWebViewConfiguration()
        let child = try #require(rig.store.tab(openerRuntime, createChildWith: configuration, features: WKWindowFeatures()))
        // WebKit hands out a copy of a web view's configuration; the copy shares the process pool.
        #expect(child.configuration.processPool === configuration.processPool)
        #expect(rig.store.workspace.allTabs().count == 2)
        #expect(rig.store.workspace.problems().isEmpty)
    }

    @Test func workspaceSurvivesARestart() throws {
        let rig = Rig(seed: true)
        rig.store.newTab(url: URL(string: "https://example.com/saved"), in: rig.window)
        rig.store.switchSpace(number: 2, in: rig.window)
        rig.store.saveSession()
        rig.store.saveNow()

        let reopened = BrowserStore(directory: rig.dir)
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
        let incognito = BrowserStore(directory: nil, incognito: true)
        let window = incognito.makeWindowState()
        incognito.register(window)
        let id = try #require(incognito.newTab(url: URL(string: "about:blank?x"), in: window))
        incognito.closeTab(id, in: window)
        #expect(incognito.archive.entries.isEmpty)
        #expect(incognito.dataDirectory == nil)
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
        let incognito = BrowserStore(directory: nil, incognito: true)
        let window = incognito.makeWindowState()
        incognito.register(window)
        _ = try #require(incognito.newTab(url: URL(string: "about:blank?perm"), in: window))
        let runtime = try #require(incognito.currentRuntime(in: window))
        incognito.tab(runtime, remember: true, forPermission: "meet.example|camera")
        #expect(incognito.settings.permissionDecisions.isEmpty)
    }
}
