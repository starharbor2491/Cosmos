import Foundation
import Testing
@testable import CosmosBlocking

#if canImport(WebKit)
import WebKit

/// Opt-in: hands compiled output to the real `WKContentRuleListStore`, the same call the browser makes.
///
///     COSMOS_VERIFY_WEBKIT=1 scripts/test.sh --filter WebKitCompileTests
///
/// WebKit stays out of the library target; only this test target imports it. It needs no window server, but it does
/// need a run loop, which `@MainActor` tests get. The downloaded corpus is compiled too when the network is reachable.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["COSMOS_VERIFY_WEBKIT"] == "1"))
@MainActor
struct WebKitCompileTests {
    private func makeStore() throws -> WKContentRuleListStore {
        let dir = makeTempDirectory("wk-store")
        return try #require(WKContentRuleListStore(url: dir))
    }

    private func compile(_ list: CompiledRuleList, in store: WKContentRuleListStore) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            store.compileContentRuleList(forIdentifier: list.name, encodedContentRuleList: list.json) { compiled, error in
                if let error { cont.resume(throwing: error) }
                else if compiled == nil { cont.resume(throwing: NSError(domain: "CosmosBlockingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "nil rule list"])) }
                else { cont.resume() }
            }
        }
    }

    @Test func webKitAcceptsEveryShapeOfRule() async throws {
        let text = """
        ||ads.example.com^
        ||example.org/banner/*$image,third-party
        |http://track.example.net/pixel.gif|
        ||foo.test/path^
        /ads?id=
        ||x.test^$xhr
        ||x.test^$script,subdocument
        ||x.test^$popup
        ||x.test^$document
        ||x.test^$all
        ||x.test^$~script,~subdocument
        /ads/*/x.js$domain=a.com|~b.a.com
        ||x.test^$script,third-party,domain=~a.com|~b.org
        ||cs.test/Foo$match-case
        ||imp.test^$important
        @@||example.com/ok.js$script
        @@||site.test^$document
        @@||ex.test^$domain=a.com
        /^https?:\\/\\/ads\\d+\\./
        ##.ad
        ##div:has(> a[href*="ads"]):not(.keep)
        example.com,~sub.example.com##.promo
        a.com##li:nth-child(2n+1)
        b.com##.x
        b.com#@#.x
        ~c.com##.y
        @@$generichide,domain=quiet.test
        """
        let result = ContentBlocker.compile(name: "shapes", text: ContentBlocker.fallbackListText + "\n" + text)
        #expect(result.lists.count >= 2)
        let store = try makeStore()
        for list in result.lists { try await compile(list, in: store) }
    }

    @Test func webKitAcceptsTheBundledFallback() async throws {
        let result = ContentBlocker.compile(name: "fallback", text: ContentBlocker.fallbackListText)
        #expect(result.lists.count == 2)
        let store = try makeStore()
        for list in result.lists { try await compile(list, in: store) }
    }

    @Test func webKitRejectsWhatTheValidatorRejects() async throws {
        let store = try makeStore()
        let bad = CompiledRuleList(name: "bad", json: #"[{"trigger":{"url-filter":"a|b"},"action":{"type":"block"}}]"#, ruleCount: 1)
        #expect(!RuleListValidator.validate(json: bad.json).isEmpty)
        await #expect(throws: (any Error).self) { try await self.compile(bad, in: store) }
    }

    @Test func webKitAcceptsTheRealLists() async throws {
        guard let easylist = await CorpusCache.shared.text(Corpus.easylist),
              let easyprivacy = await CorpusCache.shared.text(Corpus.easyprivacy) else {
            try Test.cancel("EasyList could not be downloaded (offline?)")
        }
        let result = ContentBlocker.compile(lists: [("easylist", easylist), ("easyprivacy", easyprivacy)])
        let store = try makeStore()
        for list in result.lists {
            let start = Date()
            try await compile(list, in: store)
            print("[webkit] \(list.name): \(list.ruleCount) rules compiled by WKContentRuleListStore in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        }
    }
}
#endif
