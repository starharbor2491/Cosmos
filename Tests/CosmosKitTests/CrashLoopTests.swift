import Foundation
import Testing
import WebKit
@testable import CosmosKit

/// A page whose renderer keeps dying must not be reloaded forever: that pins a core and, when WebKit reports the death
/// from inside the reload, recurses until the stack runs out.
@MainActor
@Suite struct CrashLoopTests {
    @Test func aRendererThatKeepsDyingStopsBeingReloaded() async throws {
        let runtime = TabRuntime(itemID: UUID(), profileID: nil, configuration: WKWebViewConfiguration(), host: nil)
        runtime.load(try #require(URL(string: "about:blank")))
        for _ in 0..<3 {
            runtime.webViewWebContentProcessDidTerminate(runtime.webView)
            #expect(!runtime.loadFailed)
        }
        runtime.webViewWebContentProcessDidTerminate(runtime.webView)
        #expect(runtime.loadFailed)
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
