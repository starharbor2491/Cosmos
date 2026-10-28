import Foundation
import Testing
import CosmosEngine
@testable import CosmosKit

/// A page whose renderer keeps dying must not be reloaded forever: that pins a core and, when the engine reports the
/// death from inside the reload, recurses until the stack runs out.
@MainActor
@Suite struct CrashLoopTests {
    @Test func aRendererThatKeepsDyingStopsBeingReloaded() throws {
        let page = FakePage()
        let runtime = TabRuntime(itemID: UUID(), profileID: nil, page: page, host: nil)
        runtime.load(try #require(URL(string: "https://example.com/")))
        for n in 1...3 {
            page.crash()
            #expect(!runtime.loadFailed)
            #expect(page.reloads == n)
        }
        page.crash()
        #expect(runtime.loadFailed)
        #expect(page.reloads == 3)
        #expect(page.shownHTML.last?.html.contains("keeps crashing") == true)
    }

    /// A load that fails shows Cosmos's own page in its place, with the address it was for still in the address bar.
    @Test func aFailedLoadShowsCosmossPageForThatAddress() throws {
        let page = FakePage()
        let runtime = TabRuntime(itemID: UUID(), profileID: nil, page: page, host: nil)
        let url = try #require(URL(string: "https://nowhere.example/<b>"))
        runtime.pageDidStartNavigation(page)
        runtime.page(page, didFailLoading: url, error: PageLoadError(kind: .hostNotFound, detail: "net::ERR_NAME_NOT_RESOLVED"))
        #expect(runtime.loadFailed)
        let shown = try #require(page.shownHTML.last)
        #expect(shown.url == url)
        #expect(shown.html.contains("Lost in space"))
        #expect(shown.html.contains("net::ERR_NAME_NOT_RESOLVED"))
        #expect(!shown.html.contains("<b>"), "the address is shown as text")
    }

    @Test func crashesFarApartAreEachWorthAReload() {
        var guardrail = CrashLoopGuard()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let answers = (0..<10).map { guardrail.decide(at: start.addingTimeInterval(Double($0) * 60)) }
        #expect(answers.allSatisfy { $0 == .reload })
    }

    /// Loading the error page can be reported as another death (when no renderer can start at all); that must not
    /// start the loop again.
    @Test func crashesInARowGetOneErrorPageAndThenSilence() {
        var guardrail = CrashLoopGuard()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let answers = (0..<7).map { guardrail.decide(at: start.addingTimeInterval(Double($0))) }
        #expect(answers == [.reload, .reload, .reload, .showError, .ignore, .ignore, .ignore])
        let later = guardrail.decide(at: start.addingTimeInterval(120))
        #expect(later == .reload)
    }
}
