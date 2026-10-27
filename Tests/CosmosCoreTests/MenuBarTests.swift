import Foundation
import CoreGraphics
import Testing
@testable import CosmosCore

@Suite struct MenuBarSettingsTests {
    private let engine = SearchEngine(id: "duck", name: "Duck", keyword: "d", search: "https://duckduckgo.com/?q=%s")

    @Test func itIsOffUntilTurnedOnAndStartsAsAPhoneSizedBrowser() {
        let settings = MenuBarSettings()
        #expect(!settings.enabled)
        #expect(settings.layout == .phone)
        #expect(settings.rememberPage)
        #expect(settings.profileID == nil && settings.lastAddress == nil && settings.homeAddress.isEmpty)
    }

    @Test func aSearchEnginesFrontPageIsItsSearchAddressWithoutThePath() {
        #expect(engine.homeURL?.absoluteString == "https://duckduckgo.com/")
        let deep = SearchEngine(id: "x", name: "X", keyword: "x", search: "https://search.example.org/find/web?query=%s&lang=en")
        #expect(deep.homeURL?.absoluteString == "https://search.example.org/")
    }

    @Test func withNothingChosenItStartsOnTheSearchEnginesFrontPage() {
        #expect(MenuBarSettings().startURL(engine: engine)?.absoluteString == "https://duckduckgo.com/")
    }

    @Test func aHomeAddressIsTypedLikeAnyAddress() {
        var settings = MenuBarSettings()
        settings.homeAddress = "github.com/anthropics"
        #expect(settings.startURL(engine: engine)?.absoluteString == "https://github.com/anthropics")
        settings.homeAddress = "http://localhost:3000"
        #expect(settings.startURL(engine: engine)?.absoluteString == "http://localhost:3000")
    }

    @Test(arguments: ["two words", "javascript:alert(1)", "data:text/html,hi", "file:///etc/passwd", "   "])
    func somethingThatIsNotAWebAddressIsNotAHomePage(text: String) {
        #expect(MenuBarSettings.homeURL(from: text) == nil)
        var settings = MenuBarSettings()
        settings.homeAddress = text
        #expect(settings.startURL(engine: engine)?.absoluteString == "https://duckduckgo.com/", "falls back to the search page")
    }

    @Test func thePageYouLeftComesBackWhenThatIsOn() {
        var settings = MenuBarSettings()
        settings.homeAddress = "github.com"
        settings.remember(URL(string: "https://news.example.com/a?b=1"))
        #expect(settings.startURL(engine: engine)?.absoluteString == "https://news.example.com/a?b=1")
        settings.rememberPage = false
        #expect(settings.startURL(engine: engine)?.absoluteString == "https://github.com")
    }

    @Test func onlyWebPagesAreRemembered() {
        var settings = MenuBarSettings()
        settings.remember(URL(string: "https://example.com/"))
        for other in ["javascript:alert(1)", "data:text/html,hi", "file:///tmp/a", "about:blank", "mailto:a@b.c"] {
            settings.remember(URL(string: other))
            #expect(settings.lastAddress == "https://example.com/", "\(other) is not kept")
        }
        settings.remember(URL(string: "https://example.com/" + String(repeating: "a", count: 3000)))
        #expect(settings.lastAddress == "https://example.com/", "an address that long is not kept")
    }

    @Test func turningRememberingOffForgetsTheStoredPageAtOnce() {
        var settings = MenuBarSettings()
        settings.remember(URL(string: "https://example.com/private?q=secret"))
        #expect(settings.lastAddress != nil)
        settings.rememberPage = false
        #expect(settings.lastAddress == nil, "not at the next page load: now")
        settings.rememberPage = true
        #expect(settings.lastAddress == nil, "and turning it back on does not bring it back")
    }

    @Test func aFileThatKeepsAPageWhileNotRememberingDropsIt() throws {
        let file = Data(#"{"rememberPage": false, "lastAddress": "https://example.com/?q=1"}"#.utf8)
        #expect(try JSONDecoder().decode(MenuBarSettings.self, from: file).lastAddress == nil)
    }

    @Test func notRememberingForgetsWhatWasKept() {
        var settings = MenuBarSettings()
        settings.remember(URL(string: "https://example.com/"))
        settings.rememberPage = false
        settings.remember(URL(string: "https://other.example/"))
        #expect(settings.lastAddress == nil)
    }

    @Test func anUnknownOrBrokenFileKeepsTheDefaults() throws {
        let weird = Data(#"{"enabled": "yes", "layout": "hologram", "profileID": "nope", "rememberPage": 3, "homeAddress": 7, "extra": true}"#.utf8)
        let decoded = try JSONDecoder().decode(MenuBarSettings.self, from: weird)
        #expect(decoded == MenuBarSettings())
        #expect(try JSONDecoder().decode(MenuBarSettings.self, from: Data("{}".utf8)) == MenuBarSettings())

        var settings = MenuBarSettings()
        settings.enabled = true
        settings.layout = .desktop
        settings.profileID = UUID()
        settings.homeAddress = "example.com"
        settings.rememberPage = false
        let back = try JSONDecoder().decode(MenuBarSettings.self, from: JSONEncoder().encode(settings))
        #expect(back == settings)
    }

    @Test func theChosenProfileIsUsedAndAMissingOneFallsBackToTheDefault() {
        let main = Profile(name: "Main", isDefault: true)
        let work = Profile(name: "Work")
        let profiles = [work, main]
        var settings = MenuBarSettings()
        #expect(settings.profile(in: profiles)?.id == main.id, "nothing chosen: the default, wherever it is in the list")
        settings.profileID = work.id
        #expect(settings.profile(in: profiles)?.id == work.id)
        settings.profileID = UUID()
        #expect(settings.profile(in: profiles)?.id == main.id)
        #expect(settings.profile(in: [work])?.id == work.id, "with no default, the first")
        #expect(settings.profile(in: []) == nil)
    }

    @Test func eachLayoutHasItsOwnSizeAndOnlyThePhoneOneIsMobile() {
        #expect(MenuBarSettings.Layout.phone.size.width < MenuBarSettings.Layout.desktop.size.width)
        #expect(MenuBarSettings.Layout.phone.isMobile)
        #expect(!MenuBarSettings.Layout.desktop.isMobile)
    }
}

@Suite struct MenuBarPlacementTests {
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let size = CGSize(width: 390, height: 680)

    @Test func thePanelHangsCentredUnderItsIcon() {
        let icon = CGRect(x: 1200, y: 875, width: 28, height: 25)
        let frame = MenuBarPlacement.frame(anchor: icon, size: size, visible: visible)
        #expect(frame.midX == icon.midX)
        #expect(frame.maxY == icon.minY - MenuBarPlacement.gap)
        #expect(frame.size == size)
    }

    @Test func theRightEdgeOfTheScreenPushesItBackIn() {
        let frame = MenuBarPlacement.frame(anchor: CGRect(x: 1412, y: 875, width: 28, height: 25), size: size, visible: visible)
        #expect(frame.maxX == visible.maxX - MenuBarPlacement.margin)
    }

    @Test func theLeftEdgeToo() {
        let frame = MenuBarPlacement.frame(anchor: CGRect(x: 0, y: 875, width: 28, height: 25), size: size, visible: visible)
        #expect(frame.minX == visible.minX + MenuBarPlacement.margin)
    }

    @Test func aShortScreenShrinksThePanelInsteadOfLeavingItOffTheBottom() {
        let short = CGRect(x: 0, y: 0, width: 1440, height: 500)
        let frame = MenuBarPlacement.frame(anchor: CGRect(x: 1200, y: 500, width: 28, height: 25), size: size, visible: short)
        #expect(frame.minY >= short.minY + MenuBarPlacement.margin - 0.001)
        #expect(frame.height < size.height)
        #expect(frame.maxY <= 500 - MenuBarPlacement.gap + 0.001)
    }

    @Test func withoutAnIconItHangsFromTheTopRightCorner() {
        let frame = MenuBarPlacement.frame(anchor: nil, size: size, visible: visible)
        #expect(frame.maxY <= visible.maxY)
        #expect(frame.maxX <= visible.maxX - MenuBarPlacement.margin + 0.001)
        #expect(frame.minX >= visible.minX)
    }

    /// A status item that the menu bar has not laid out yet reports a frame at the corner of the screen, not in the menu bar; a
    /// panel hung under that would have no height at all.
    @Test(arguments: [CGRect(x: 0, y: 0, width: 28, height: 25), CGRect(x: 1200, y: 40, width: 28, height: 25), CGRect.zero])
    func anIconThatIsNotInTheMenuBarYetIsNotAnchoredTo(icon: CGRect) {
        let frame = MenuBarPlacement.frame(anchor: icon, size: size, visible: visible)
        #expect(frame == MenuBarPlacement.frame(anchor: nil, size: size, visible: visible))
        #expect(frame.height == size.height)
    }

    /// With the menu bar hidden the visible frame reaches the top of the screen, and a button inset a point or two inside its
    /// window sits just under it: that is still the menu bar.
    @Test func anIconAFewPointsUnderTheTopOfAMenuBarThatHidesIsStillAnchoredTo() {
        let icon = CGRect(x: 1200, y: 849, width: 28, height: 24)   // top at 873, the screen's top 875
        let frame = MenuBarPlacement.frame(anchor: icon, size: size, visible: visible)
        #expect(frame.midX == icon.midX)
        #expect(frame.maxY == icon.minY - MenuBarPlacement.gap)
    }

    @Test func aPanelWiderThanTheScreenIsNarrowedToFit() {
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 700)
        let frame = MenuBarPlacement.frame(anchor: CGRect(x: 100, y: 700, width: 28, height: 25), size: size, visible: tiny)
        #expect(frame.width <= tiny.width - 2 * MenuBarPlacement.margin + 0.001)
        #expect(frame.minX >= tiny.minX)
    }
}

/// The panel can be moved by its edges; it keeps where it was put when its size changes, and cannot be lost off screen.
@Suite struct MenuBarDragTests {
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let panel = CGRect(x: 600, y: 100, width: 390, height: 680)

    @Test func aPanelOnTheScreenIsLeftWhereItIsPut() {
        #expect(MenuBarPlacement.dragged(panel, visible: visible) == panel)
    }

    @Test func thePanelCannotBeDraggedUnderTheMenuBar() {
        let high = panel.offsetBy(dx: 0, dy: 400)
        let frame = MenuBarPlacement.dragged(high, visible: visible)
        #expect(frame.maxY == visible.maxY)
        #expect(frame.minX == high.minX)
    }

    @Test func aPartOfItAlwaysStaysOnEachSideSoItCanBeDraggedBack() {
        let grip = MenuBarPlacement.grip
        let right = MenuBarPlacement.dragged(panel.offsetBy(dx: 2000, dy: 0), visible: visible)
        #expect(right.minX == visible.maxX - grip)
        let left = MenuBarPlacement.dragged(panel.offsetBy(dx: -3000, dy: 0), visible: visible)
        #expect(left.maxX == visible.minX + grip)
        let low = MenuBarPlacement.dragged(panel.offsetBy(dx: 0, dy: -2000), visible: visible)
        #expect(low.maxY == visible.minY + grip)
    }

    @Test func draggingNeverChangesTheSize() {
        for dx in [-5000.0, 0, 5000] {
            for dy in [-5000.0, 0, 5000] {
                #expect(MenuBarPlacement.dragged(panel.offsetBy(dx: dx, dy: dy), visible: visible).size == panel.size)
            }
        }
    }

    @Test func aNewSizeKeepsTheTopLeftCornerWhereThePanelWas() {
        let frame = MenuBarPlacement.resized(panel, to: CGSize(width: 520, height: 600), visible: visible)
        #expect(frame.minX == panel.minX)
        #expect(frame.maxY == panel.maxY)
        #expect(frame.size == CGSize(width: 520, height: 600))
    }

    @Test func aNewSizeThatWouldRunOffTheScreenIsPulledBackIn() {
        let nearRight = CGRect(x: 1300, y: 100, width: 130, height: 680)
        let frame = MenuBarPlacement.resized(nearRight, to: CGSize(width: 520, height: 680), visible: visible)
        #expect(frame.maxX == visible.maxX - MenuBarPlacement.margin)
        let nearBottom = CGRect(x: 600, y: 20, width: 390, height: 300)
        let taller = MenuBarPlacement.resized(nearBottom, to: CGSize(width: 390, height: 680), visible: visible)
        #expect(taller.maxY == nearBottom.maxY, "the top stays where it was")
        #expect(taller.minY == visible.minY + MenuBarPlacement.margin, "and the panel is only as tall as the screen leaves room for")
    }
}

@Suite struct MenuBarToggleTests {
    @Test func aClickRightAfterThePanelClosedItselfDoesNotOpenItAgain() {
        let now = Date()
        #expect(MenuBarToggle.shouldOpen(now: now, closedAt: nil))
        #expect(!MenuBarToggle.shouldOpen(now: now, closedAt: now.addingTimeInterval(-0.05)))
        #expect(MenuBarToggle.shouldOpen(now: now, closedAt: now.addingTimeInterval(-1)))
    }
}
