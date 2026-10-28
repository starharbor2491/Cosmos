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

/// The panel can be resized by dragging its edges and corners. Screen coordinates, y up: dragging the top edge up grows it.
@Suite struct MenuBarResizeTests {
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let panel = CGRect(x: 600, y: 100, width: 390, height: 680)

    private func resized(_ edges: MenuBarPlacement.Edges, _ dx: CGFloat, _ dy: CGFloat, from frame: CGRect? = nil) -> CGRect {
        MenuBarPlacement.resized(frame ?? panel, edges: edges, delta: CGSize(width: dx, height: dy), visible: visible)
    }

    @Test func theRightEdgeMovesAndTheLeftStaysPut() {
        let frame = resized(.right, 80, 0)
        #expect(frame.minX == panel.minX && frame.maxX == panel.maxX + 80)
        #expect(frame.minY == panel.minY && frame.height == panel.height, "nothing else changed")
    }

    @Test func theLeftEdgeMovesAndTheRightStaysPut() {
        let frame = resized(.left, -50, 0)
        #expect(frame.maxX == panel.maxX && frame.minX == panel.minX - 50 && frame.width == panel.width + 50)
    }

    @Test func theTopEdgeGrowsUpwardAndTheBottomEdgeDownward() {
        let up = resized(.top, 0, 40)
        #expect(up.minY == panel.minY && up.maxY == panel.maxY + 40)
        let down = resized(.bottom, 0, -30)
        #expect(down.maxY == panel.maxY && down.minY == panel.minY - 30 && down.height == panel.height + 30)
    }

    @Test func aCornerMovesTwoEdgesAtOnce() {
        let frame = resized([.left, .bottom], -20, -10)
        #expect(frame.maxX == panel.maxX && frame.maxY == panel.maxY)
        #expect(frame.width == panel.width + 20 && frame.height == panel.height + 10)
    }

    @Test func itNeverGetsSmallerThanTheLeastThatWorksAndTheEdgeOppositeStaysWhereItIs() {
        let least = MenuBarPlacement.minimumSize
        let right = resized(.right, -5000, 0)
        #expect(right.width == least.width && right.minX == panel.minX)
        let left = resized(.left, 5000, 0)
        #expect(left.width == least.width && left.maxX == panel.maxX, "pushed past the other side, it stops at the least width")
        let top = resized(.top, 0, -5000)
        #expect(top.height == least.height && top.minY == panel.minY)
        let bottom = resized(.bottom, 0, 5000)
        #expect(bottom.height == least.height && bottom.maxY == panel.maxY)
    }

    @Test func noEdgeGoesPastTheScreen() {
        #expect(resized(.right, 9000, 0).maxX == visible.maxX)
        #expect(resized(.left, -9000, 0).minX == visible.minX)
        #expect(resized(.top, 0, 9000).maxY == visible.maxY, "not up under the menu bar")
        #expect(resized(.bottom, 0, -9000).minY == visible.minY)
    }

    @Test func noMovementChangesNothing() {
        for edges: MenuBarPlacement.Edges in [.left, .right, .top, .bottom, [.left, .top], [.right, .bottom]] {
            #expect(resized(edges, 0, 0) == panel)
        }
    }

    @Test func edgesThatAreNotTakenDoNotMove() {
        let frame = resized(.right, 30, 500)
        #expect(frame.minY == panel.minY && frame.height == panel.height, "a sideways edge ignores the vertical movement")
    }
}

@Suite struct MenuBarSizeSettingsTests {
    @Test func aLayoutHasItsOwnSizeUntilTheUserChangesIt() {
        var settings = MenuBarSettings()
        #expect(settings.size == MenuBarSettings.Layout.phone.size && !settings.hasCustomSize)
        settings.setSize(CGSize(width: 450, height: 720))
        #expect(settings.size == CGSize(width: 450, height: 720) && settings.hasCustomSize)
    }

    @Test func eachLayoutKeepsItsOwnSize() {
        var settings = MenuBarSettings()
        settings.setSize(CGSize(width: 450, height: 720))
        settings.layout = .desktop
        #expect(settings.size == MenuBarSettings.Layout.desktop.size, "the desktop panel was not resized")
        settings.setSize(CGSize(width: 800, height: 600))
        settings.layout = .phone
        #expect(settings.size == CGSize(width: 450, height: 720))
    }

    @Test func resettingGoesBackToTheLayoutsSize() {
        var settings = MenuBarSettings()
        settings.setSize(CGSize(width: 450, height: 720))
        settings.resetSize()
        #expect(settings.size == MenuBarSettings.Layout.phone.size && !settings.hasCustomSize)
    }

    @Test func aSizeIsKeptWithinWhatCanWork() {
        var settings = MenuBarSettings()
        settings.setSize(CGSize(width: 10, height: 10))
        #expect(settings.size == MenuBarPlacement.minimumSize)
        settings.setSize(CGSize(width: 90_000, height: 90_000))
        #expect(settings.size.width <= MenuBarSettings.maximumSize.width && settings.size.height <= MenuBarSettings.maximumSize.height)
        settings.setSize(CGSize(width: CGFloat.nan, height: 500))
        #expect(settings.size.width.isFinite, "a size that is not a number is not kept")
    }

    @Test func aSizeSurvivesBeingSavedAndRead() throws {
        var settings = MenuBarSettings()
        settings.setSize(CGSize(width: 450, height: 720))
        let back = try JSONDecoder().decode(MenuBarSettings.self, from: JSONEncoder().encode(settings))
        #expect(back.size == CGSize(width: 450, height: 720))
    }

    @Test func aFileWithNoSizeOrNonsenseSizesStillOpens() throws {
        let none = try JSONDecoder().decode(MenuBarSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(none.size == MenuBarSettings.Layout.phone.size)
        let junk = try JSONDecoder().decode(MenuBarSettings.self, from: Data(#"{"customSizes":{"phone":{"width":-5,"height":1e99},"nope":{"width":400,"height":500},"desktop":"wide"}}"#.utf8))
        #expect(junk.size == MenuBarSettings.Layout.phone.size && !junk.hasCustomSize)
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
