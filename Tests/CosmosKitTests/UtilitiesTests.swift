import Foundation
import Testing
@testable import CosmosCore
@testable import CosmosKit

@MainActor
@Suite struct UtilitiesTests {
    /// Google Translate's proxy names a site with its dots as dashes (and its dashes doubled), and keeps the page's path
    /// and query; a page that is not on the public web has no translation there.
    @Test func aPageIsTranslatedThroughGooglesAddressForIt() {
        let url = TranslateUtility.googleTranslate(URL(string: "https://news.my-site.example/a/b?q=1#top"), into: "fr")
        #expect(url?.host == "news-my--site-example.translate.goog")
        #expect(url?.path == "/a/b")
        #expect(url?.fragment == "top")
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.map(\.name) == ["q", "_x_tr_sl", "_x_tr_tl", "_x_tr_hl"])
        #expect(items.first { $0.name == "_x_tr_tl" }?.value == "fr")
        #expect(TranslateUtility.googleTranslate(URL(string: "http://localhost:8080/"), into: "fr") == nil)
        #expect(TranslateUtility.googleTranslate(URL(string: "file:///tmp/a.html"), into: "fr") == nil)
        #expect(TranslateUtility.googleTranslate(URL(string: "https://a-b.translate.goog/"), into: "fr") == nil, "already translated")
    }

    @Test func savedPasswordsAreFoundBySiteOrUserName() {
        let day = Date(timeIntervalSince1970: 1_750_000_000)
        let logins = [SavedLogin(origin: "https://mail.example.com", username: "Ana@example.com", password: "1", created: day),
                      SavedLogin(origin: "https://shop.test", username: "ben", password: "2", created: day)]
        #expect(PasswordsPane.matching(logins, "").count == 2)
        #expect(PasswordsPane.matching(logins, " ana ").map(\.username) == ["Ana@example.com"])
        #expect(PasswordsPane.matching(logins, "SHOP").map(\.username) == ["ben"])
        #expect(PasswordsPane.matching(logins, "nothing").isEmpty)
    }

    /// The page keeps room: in a narrow window the Library's sidebar narrows (never below the user's width), and a
    /// utility panel with no room beside the page floats over its edge.
    @Test func thePageKeepsRoomBesideTheSidebarAndPanels() {
        let rig = Rig()
        let w = rig.window
        w.sidebarWidth = 248
        w.contentWidth = 760
        w.libraryOpen = true
        #expect(PaneFit.sidebarWidth(w) == 760 - 40 - PaneFit.minimumPage)
        w.contentWidth = 1600
        #expect(PaneFit.sidebarWidth(w) == LibraryPage.width)
        w.contentWidth = 500
        #expect(PaneFit.sidebarWidth(w) == 248, "never narrower than the user's own")
        w.libraryOpen = false
        #expect(PaneFit.sidebarWidth(w) == 248)

        w.utility = .zoom
        w.contentWidth = 900
        #expect(PaneFit.utilityFloats(w), "248 + 40 + 300 leaves the page under 360")
        w.contentWidth = 1000
        #expect(!PaneFit.utilityFloats(w))
        w.libraryOpen = true
        #expect(PaneFit.utilityFloats(w), "with the Library open (480) there is no room")
        w.utility = nil
        #expect(!PaneFit.utilityFloats(w))
    }

    /// Chromium keeps a zoom for each site: a tab that goes to a site zoomed before shows that zoom, not 100%.
    @Test func theZoomShownIsThePagesOwn() throws {
        let rig = Rig()
        let id = try #require(rig.store.newTab(url: URL(string: "https://example.com/"), in: rig.window))
        let runtime = try #require(rig.store.runtime(forItem: id, in: rig.window))
        let page = try #require(runtime.page as? FakePage)
        page.zoom = 1.25
        runtime.pageStateDidChange(page)
        #expect(runtime.zoom == 1.25)
        runtime.zoomIn()
        #expect(abs(runtime.zoom - 1.35) < 0.0001)
    }

    /// The rail's toggle puts the rail and its panel away and brings them back.
    @Test func theUtilitiesComeAndGoWithTheirToggle() {
        let rig = Rig()
        rig.window.utility = .zoom
        rig.store.perform(.toggleUtilities, in: rig.window)
        #expect(!rig.window.utilitiesVisible)
        rig.store.perform(.toggleUtilities, in: rig.window)
        #expect(rig.window.utilitiesVisible && rig.window.utility == .zoom)
    }
}
