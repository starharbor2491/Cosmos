import AppKit
import Testing
@testable import CosmosKit
@testable import CosmosCore

/// The panel under the menu-bar icon keeps the place the user dragged it to while it is open, takes a new layout's size there,
/// and comes back under the icon (here: at the top right, there being no icon) when it is opened again. There is no status item
/// in these tests, only the panel.
/// Serialized: a panel that becomes key makes every other one resign, which closes them (as it should), so two of these tests
/// waiting on the run loop at once would close each other's panel.
@MainActor
@Suite(.serialized) struct MenuBarPanelTests {
    private func browser() -> (MenuBarBrowser, Rig) {
        let rig = Rig()
        rig.store.settings.menuBar.enabled = true
        rig.store.settings.menuBar.rememberPage = false
        rig.store.settings.menuBar.homeAddress = "http://127.0.0.1:1/"
        let browser = MenuBarBrowser(store: rig.store, openInCosmos: { _ in }, showSettings: {}, showBrowser: {})
        return (browser, rig)
    }

    private var visible: CGRect { NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900) }

    /// The move notification reaches the controller on the next turn of the run loop.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }

    @Test func openedWithNoIconItHangsFromTheTopRightAtTheLayoutsSize() throws {
        let (browser, rig) = browser()
        browser.show()
        defer { browser.forgetPage() }
        let panel = try #require(browser.panel)
        #expect(panel.isVisible)
        #expect(panel.frame == MenuBarPlacement.frame(anchor: nil, size: rig.store.settings.menuBar.layout.size, visible: visible))
    }

    @Test func aPanelTheUserMovedStaysWhereItWasPutWhenTheLayoutChanges() async throws {
        let (browser, rig) = browser()
        browser.show()
        defer { browser.forgetPage() }
        let panel = try #require(browser.panel)
        let moved = NSPoint(x: panel.frame.minX - 500, y: panel.frame.minY - 40)   // far enough from the right edge for the wider layout
        panel.setFrame(NSRect(origin: moved, size: panel.frame.size), display: true)   // how a drag by the edge moves it
        try await settle()
        let top = panel.frame.maxY

        rig.store.settings.menuBar.layout = .desktop
        browser.show()   // what a change of settings or another look at the icon does to a panel that is open
        let size = MenuBarSettings.Layout.desktop.size
        #expect(panel.frame.size == size)
        #expect(panel.frame.minX == moved.x, "it did not jump back under the icon")
        #expect(abs(panel.frame.maxY - top) < 0.5, "the top edge stays where the user left it")
    }

    @Test func aPanelNobodyMovedFollowsTheLayoutToItsOwnPlace() throws {
        let (browser, rig) = browser()
        browser.show()
        defer { browser.forgetPage() }
        let panel = try #require(browser.panel)
        rig.store.settings.menuBar.layout = .desktop
        browser.show()
        #expect(panel.frame == MenuBarPlacement.frame(anchor: nil, size: MenuBarSettings.Layout.desktop.size, visible: visible))
    }

    @Test func openedAgainItComesBackToItsPlaceNotWhereItWasDragged() async throws {
        let (browser, rig) = browser()
        browser.show()
        defer { browser.forgetPage() }
        let panel = try #require(browser.panel)
        let home = panel.frame
        panel.setFrame(NSRect(origin: NSPoint(x: home.minX - 200, y: home.minY - 100), size: home.size), display: true)
        try await settle()
        browser.hide()
        browser.show()
        #expect(panel.frame == MenuBarPlacement.frame(anchor: nil, size: rig.store.settings.menuBar.layout.size, visible: visible))
    }
}
