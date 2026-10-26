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

    @Test func aPanelWiderThanTheScreenIsNarrowedToFit() {
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 700)
        let frame = MenuBarPlacement.frame(anchor: CGRect(x: 100, y: 700, width: 28, height: 25), size: size, visible: tiny)
        #expect(frame.width <= tiny.width - 2 * MenuBarPlacement.margin + 0.001)
        #expect(frame.minX >= tiny.minX)
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
