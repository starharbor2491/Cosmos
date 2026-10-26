import Foundation
import Testing
@testable import CosmosKit
@testable import CosmosCore

@MainActor
@Suite struct CommandBarTests {
    @Test func suggestionsLeaveNoCacheEntryAndSendNoCookies() {
        let config = CommandBarModel.suggestionSession.configuration
        #expect(config.urlCache == nil, "a cache would write what was typed to a file outside the data folder")
        #expect(config.httpCookieStorage == nil)
        #expect(!config.httpShouldSetCookies)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }

    func model(_ text: String, mode: CommandBarMode = .newTab, rig: Rig) -> CommandBarModel {
        let m = CommandBarModel(store: rig.store, window: rig.window, mode: mode)
        m.textChanged(text)
        return m
    }

    @Test func aTypedURLComesFirstAndSearchFollows() {
        let rig = Rig(seed: true)
        let m = model("swift.org/documentation", rig: rig)
        #expect(m.rows.first?.kind == .typedURL)
    }

    @Test func plainWordsOfferAWebSearch() {
        let rig = Rig()
        let m = model("lofi hip hop", rig: rig)
        #expect(m.rows.first?.kind == .webSearch)
    }

    @Test func sidebarTabsAreFoundByNameAndCompleteInline() {
        let rig = Rig(seed: true)
        let m = model("gith", rig: rig)
        #expect(m.rows.first?.title == "GitHub")
        #expect(m.inlineCompletion == "github.com")
    }

    @Test func commandsAppearForNaturalPhrases() {
        let rig = Rig(seed: true)
        let m = model("new space", rig: rig)
        #expect(m.rows.contains { if case .command("newSpace") = $0.kind { return true } else { return false } })
        // A strong command match leads the list rather than a web search.
        #expect(m.rows.first.map { if case .command = $0.kind { return true } else { return false } } == true)
    }

    @Test func tabEntersSiteSearchAndSearchesInsideTheSite() {
        let rig = Rig(seed: true)
        let m = model("youtube", rig: rig)
        #expect(m.tabHint?.id == "youtube")
        m.tab()
        #expect(m.site?.id == "youtube")
        m.textChanged("lofi beats")
        guard case .siteSearch("youtube")? = m.rows.first?.kind else { Issue.record("expected a site-search row"); return }
        #expect(m.rows.first?.url?.host?.contains("youtube.com") == true)
        #expect(m.backspaceOnEmpty())            // backspace on an empty field leaves site search
        #expect(m.site == nil)
    }

    @Test func calculatorAnswersArithmetic() {
        let rig = Rig()
        let m = model("12*(3+4)", rig: rig)
        #expect(m.rows.first?.kind == .calculation)
        #expect(m.rows.first?.title == "84")
    }

    @Test func activatingAnOpenTabSelectsItAndLearnsThePick() throws {
        let rig = Rig(seed: true)
        let m = model("nasa", rig: rig)
        let row = try #require(m.rows.first { $0.title == "NASA" })
        m.activate(row)
        let selected = try #require(rig.window.selectedItemID)
        #expect(rig.store.workspace.item(selected)?.displayTitle == "NASA")
        #expect(rig.store.learned.boost(query: "nasa", candidateID: row.id) > 0)
    }

    @Test func enteringAddressInNewTabMode_OpensANewTab() {
        let rig = Rig()
        let before = rig.store.workspace.allTabs().count
        let m = model("about:blank", rig: rig)
        m.activateSelected()
        #expect(rig.store.workspace.allTabs().count == before + 1)
        #expect(rig.window.overlay == nil)
    }

    @Test func emptyQueryShowsRecentTabs() {
        let rig = Rig()
        rig.store.newTab(url: URL(string: "about:blank?recent"), in: rig.window)
        let m = CommandBarModel(store: rig.store, window: rig.window, mode: .newTab)
        #expect(!m.rows.isEmpty)
    }
}
