import AppKit
import Testing
@testable import CosmosKit
@testable import CosmosCore

/// The panel under the menu-bar icon opens at its layout's size, or at the size the user dragged it to (kept for that layout),
/// and hangs from the icon (here: from the top right, there being no icon) however it is sized. There is no status item in
/// these tests, only the panel.
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

    @Test func openedWithNoIconItHangsFromTheTopRightAtTheLayoutsSize() throws {
        let (browser, rig) = browser()
        browser.show()
        defer { browser.forgetPage() }
        let panel = try #require(browser.panel)
        #expect(panel.isVisible)
        #expect(panel.frame == MenuBarPlacement.frame(anchor: nil, size: rig.store.settings.menuBar.layout.size, visible: visible))
    }

    /// What the panel's edges do when let go: the size is kept and the panel is not put back under the icon at the old size.
    @Test func aSizeTheUserDraggedItToIsKeptAndNotUndoneByTheNextSync() throws {
        let (browser, rig) = browser()
        browser.show()
        defer { browser.forgetPage() }
        let panel = try #require(browser.panel)
        let dragged = CGSize(width: 520, height: 470)
        panel.setFrame(NSRect(origin: panel.frame.origin, size: dragged), display: true)   // what the drag itself does
        browser.session.onResized(dragged)   // and what letting go of it does
        #expect(rig.store.settings.menuBar.size == dragged)
        #expect(rig.store.settings.menuBar.hasCustomSize)
        let frame = panel.frame
        browser.sync()
        #expect(panel.frame == frame, "a panel that already has the kept size stays where it is")
    }

    @Test func openedAgainItHangsFromTheIconAtTheKeptSize() throws {
        let (browser, rig) = browser()
        browser.show()
        defer { browser.forgetPage() }
        let panel = try #require(browser.panel)
        let dragged = CGSize(width: 520, height: 470)
        panel.setFrame(NSRect(origin: NSPoint(x: panel.frame.minX - 60, y: panel.frame.minY - 100), size: dragged), display: true)
        browser.session.onResized(dragged)
        browser.hide()
        browser.show()
        #expect(panel.frame == MenuBarPlacement.frame(anchor: nil, size: dragged, visible: visible))
        #expect(rig.store.settings.menuBar.size == dragged)
    }

    @Test func eachLayoutKeepsItsOwnSize() throws {
        let (browser, rig) = browser()
        browser.show()
        defer { browser.forgetPage() }
        let panel = try #require(browser.panel)
        browser.session.onResized(CGSize(width: 500, height: 450))
        rig.store.settings.menuBar.layout = .desktop
        browser.show()
        #expect(panel.frame.size == MenuBarSettings.Layout.desktop.size, "the phone layout's size is not the desktop layout's")
        rig.store.settings.menuBar.layout = .phone
        browser.show()
        #expect(panel.frame.size == CGSize(width: 500, height: 450), "and it is still there when the layout comes back")
    }

    @Test func aPanelNobodyResizedFollowsTheLayoutToItsOwnPlace() throws {
        let (browser, rig) = browser()
        browser.show()
        defer { browser.forgetPage() }
        let panel = try #require(browser.panel)
        rig.store.settings.menuBar.layout = .desktop
        browser.sync()
        #expect(panel.frame == MenuBarPlacement.frame(anchor: nil, size: MenuBarSettings.Layout.desktop.size, visible: visible))
    }

    @Test func resettingTheSizeBringsTheOpenPanelBackToTheLayoutsSize() throws {
        let (browser, rig) = browser()
        browser.show()
        defer { browser.forgetPage() }
        let panel = try #require(browser.panel)
        browser.session.onResized(CGSize(width: 520, height: 470))
        panel.setFrame(NSRect(origin: panel.frame.origin, size: CGSize(width: 520, height: 470)), display: true)
        rig.store.settings.menuBar.resetSize()
        browser.sync()
        #expect(panel.frame.size == rig.store.settings.menuBar.layout.size)
        #expect(!rig.store.settings.menuBar.hasCustomSize)
    }
}
