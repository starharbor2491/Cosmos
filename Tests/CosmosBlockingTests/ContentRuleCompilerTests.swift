import Foundation
import Testing
@testable import CosmosBlocking

@Suite struct ContentRuleCompilerTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let filter: String
        let expected: [String]
        var testDescription: String { filter }
        init(_ filter: String, _ expected: [String]) { self.filter = filter; self.expected = expected }
    }

    private static let host = #"^[^:]+://+([^:/]+\\.)?"#
    private static let sep = #"[^a-zA-Z0-9_.%-]"#

    /// Exact WebKit JSON for representative filters (the two fixed top-level-navigation guards are filtered out).
    static let cases: [Case] = [
        Case("||ads.example.com^", [
            #"{"trigger":{"url-filter":"\#(host)ads\\.example\\.com\#(sep)"},"action":{"type":"block"}}"#]),
        Case("||example.org/banner/*$image,third-party", [
            #"{"trigger":{"url-filter":"\#(host)example\\.org/banner/","resource-type":["image"],"load-type":["third-party"]},"action":{"type":"block"}}"#]),
        Case("|http://track.example.net/pixel.gif|", [
            #"{"trigger":{"url-filter":"^http://track\\.example\\.net/pixel\\.gif$"},"action":{"type":"block"}}"#]),
        Case("/adframe.", [
            #"{"trigger":{"url-filter":"/adframe\\."},"action":{"type":"block"}}"#]),
        Case(".swf|", [
            #"{"trigger":{"url-filter":"\\.swf$"},"action":{"type":"block"}}"#]),
        Case("||example.com/path^", [
            #"{"trigger":{"url-filter":"\#(host)example\\.com/path(\#(sep).*)?$"},"action":{"type":"block"}}"#]),
        Case("ad*banner.gif", [
            #"{"trigger":{"url-filter":"ad.*banner\\.gif"},"action":{"type":"block"}}"#]),
        Case("/ads?id=", [
            #"{"trigger":{"url-filter":"/ads\\?id="},"action":{"type":"block"}}"#]),
        Case("||Example.COM/Ads^", [
            #"{"trigger":{"url-filter":"\#(host)example\\.com/ads(\#(sep).*)?$"},"action":{"type":"block"}}"#]),
        Case("||example.com/Foo$match-case", [
            #"{"trigger":{"url-filter":"\#(host)example\\.com/Foo","url-filter-is-case-sensitive":true},"action":{"type":"block"}}"#]),
        // types
        Case("||x.test^$script", [
            #"{"trigger":{"url-filter":"\#(host)x\\.test\#(sep)","resource-type":["script"]},"action":{"type":"block"}}"#]),
        Case("||x.test^$xhr", [
            #"{"trigger":{"url-filter":"\#(host)x\\.test\#(sep)","resource-type":["raw","fetch"]},"action":{"type":"block"}}"#]),
        Case("||x.test^$stylesheet,font,media,ping,websocket,other", [
            #"{"trigger":{"url-filter":"\#(host)x\\.test\#(sep)","resource-type":["style-sheet","font","media","ping","websocket","other"]},"action":{"type":"block"}}"#]),
        Case("||x.test^$subdocument", [
            #"{"trigger":{"url-filter":"\#(host)x\\.test\#(sep)","resource-type":["document"],"load-context":["child-frame"]},"action":{"type":"block"}}"#]),
        Case("||x.test^$script,subdocument", [
            #"{"trigger":{"url-filter":"\#(host)x\\.test\#(sep)","resource-type":["script"]},"action":{"type":"block"}}"#,
            #"{"trigger":{"url-filter":"\#(host)x\\.test\#(sep)","resource-type":["document"],"load-context":["child-frame"]},"action":{"type":"block"}}"#]),
        Case("||x.test^$popup", [
            #"{"trigger":{"url-filter":"\#(host)x\\.test\#(sep)","resource-type":["popup"]},"action":{"type":"block"}}"#]),
        Case("||x.test^$document", [
            #"{"trigger":{"url-filter":"\#(host)x\\.test\#(sep)","resource-type":["document"],"load-context":["top-frame"]},"action":{"type":"block"}}"#]),
        Case("||x.test^$all", [
            #"{"trigger":{"url-filter":"\#(host)x\\.test\#(sep)"},"action":{"type":"block"}}"#]),
        Case("||x.test^$~script,~subdocument", [
            #"{"trigger":{"url-filter":"\#(host)x\\.test\#(sep)","resource-type":["image","style-sheet","font","media","raw","fetch","ping","websocket","other"]},"action":{"type":"block"}}"#]),
        // load type and domains
        Case("||x.test^$~third-party", [
            #"{"trigger":{"url-filter":"\#(host)x\\.test\#(sep)","load-type":["first-party"]},"action":{"type":"block"}}"#]),
        Case("/ads/*/x.js$domain=a.com|b.com", [
            #"{"trigger":{"url-filter":"/ads/.*/x\\.js","if-domain":["*a.com","*b.com"]},"action":{"type":"block"}}"#]),
        Case("||x.test^$script,third-party,domain=~a.com|~b.org", [
            #"{"trigger":{"url-filter":"\#(host)x\\.test\#(sep)","resource-type":["script"],"load-type":["third-party"],"unless-domain":["*a.com","*b.org"]},"action":{"type":"block"}}"#]),
        Case("/ads/*/x.js$domain=a.com|~b.a.com", [
            #"{"trigger":{"url-filter":"/ads/.*/x\\.js","if-domain":["*a.com"]},"action":{"type":"block"}}"#,
            #"{"trigger":{"url-filter":"/ads/.*/x\\.js","if-domain":["*b.a.com"]},"action":{"type":"ignore-previous-rules"}}"#]),
        Case("$popup,domain=a.com", [
            #"{"trigger":{"url-filter":".*","resource-type":["popup"],"if-domain":["*a.com"]},"action":{"type":"block"}}"#]),
        // exceptions
        Case("@@||example.com/ok.js$script", [
            #"{"trigger":{"url-filter":"\#(host)example\\.com/ok\\.js","resource-type":["script"]},"action":{"type":"ignore-previous-rules"}}"#]),
        Case("@@||site.test^$document", [
            #"{"trigger":{"url-filter":".*","if-domain":["*site.test"]},"action":{"type":"ignore-previous-rules"}}"#]),
        // regular expressions
        Case(#"/^https?:\/\/ads\d+\./"#, [
            #"{"trigger":{"url-filter":"^https?://ads[0-9]+\\."},"action":{"type":"block"}}"#]),
        Case(#"/banner(\d|x)/"#, []),
        Case(#"/ad{3}/"#, []),
        // unsupported
        Case("||x.test^$redirect=noop.js", []),
        Case("||x.test^$csp=script-src 'none'", []),
        Case("||x.test^$removeparam=utm", []),
        Case("$third-party", []),
        Case("||bücher.example^", []),
        Case("a", []),
    ]

    @Test(arguments: cases) func exactJSON(_ c: Case) {
        #expect(networkRules(c.filter) == c.expected)
    }

    // MARK: Ordering

    @Test func exceptionsFollowBlocksAndImportantComesLast() {
        let text = """
        ||imp.test^$important
        @@||ex.test^
        ||norm.test^
        @@||site.test^$document
        ||pop.test^$popup
        """
        let rules = networkRules(text)
        func index(containing s: String) -> Int { rules.firstIndex { $0.contains(s) }! }
        #expect(index(containing: "norm") < index(containing: "pop"))
        #expect(index(containing: "pop") < index(containing: "ex\\\\.test"))
        #expect(index(containing: "ex\\\\.test") < index(containing: "imp\\\\.test"))
        #expect(index(containing: "imp\\\\.test") < index(containing: "*site.test"))
        #expect(rules.count == 5)
    }

    @Test func topLevelGuardsComeAfterNormalBlocksAndBeforeExplicitDocumentBlocks() {
        let out = ContentRuleCompiler().compile(FilterParser.parse("||a.test^\n||b.test^$popup\n@@||c.test^\n"))
        let list = out.networkLists[0]
        #expect(list.count == 5)
        #expect(list[0].contains("a\\\\.test"))
        #expect(Set(list[1...2]) == protectionRules)
        #expect(list[3].contains("b\\\\.test"))
        #expect(list[4].contains("c\\\\.test"))
    }

    @Test func duplicatesAreCollapsed() {
        #expect(networkRules("||a.test^\n||a.test^\n||A.test^").count == 1)
    }

    @Test func badfilterDisablesTheMatchingFilter() {
        let result = ContentBlocker.compile(name: "t", text: "||a.test^$third-party\n||b.test^\n||a.test^$third-party,badfilter\n")
        let json = result.lists.first?.json ?? ""
        #expect(json.contains("b\\\\.test"))
        #expect(!json.contains("a\\\\.test"))
        #expect(result.report.skipped[.badfiltered] == 1)
    }

    @Test func hostsFileEntriesBecomeHostRules() {
        let rules = networkRules("0.0.0.0 ads.example.com\n127.0.0.1 localhost\n")
        #expect(rules == [#"{"trigger":{"url-filter":"\#(Self.host)ads\\.example\\.com\#(Self.sep)"},"action":{"type":"block"}}"#])
    }

    @Test func domainListsOver250AreSplitForIfDomain() {
        let domains = (0..<600).map { "d\($0).test" }.joined(separator: "|")
        let rules = networkRules("/ads/*.js$domain=\(domains)")
        #expect(rules.count == 3)
        #expect(rules.allSatisfy { RuleListValidator.validate(json: "[\($0)]").isEmpty })
    }

    // MARK: Semantics of the generated expressions

    struct Match: Sendable, CustomTestStringConvertible {
        let filter: String
        let url: String
        let matches: Bool
        var testDescription: String { "\(filter) ~ \(url)" }
        init(_ filter: String, _ url: String, _ matches: Bool) { self.filter = filter; self.url = url; self.matches = matches }
    }

    static let matchCases: [Match] = [
        Match("||ads.example.com^", "http://ads.example.com/x.js", true),
        Match("||ads.example.com^", "https://sub.ads.example.com/", true),
        Match("||ads.example.com^", "http://ads.example.com:8080/", true),
        Match("||ads.example.com^", "http://ads.example.com/", true),
        Match("||ads.example.com^", "http://notads.example.com/", false),
        Match("||ads.example.com^", "http://ads.example.com.evil.org/", false),
        Match("||ads.example.com^", "http://example.com/ads.example.com/", false),
        Match("||ads.example.com^", "http://x.org/?u=http://ads.example.com/", false),
        Match("||example.com/path^", "http://example.com/path", true),
        Match("||example.com/path^", "http://example.com/path?x=1", true),
        Match("||example.com/path^", "http://example.com/path/", true),
        Match("||example.com/path^", "http://example.com/pathology", false),
        Match("||example.com/path^", "http://example.com/path.js", false),
        Match("|http://example.com/", "http://example.com/a", true),
        Match("|http://example.com/", "https://example.com/a", false),
        Match("|http://example.com/", "http://x.com/?http://example.com/", false),
        Match(".swf|", "http://a.com/x.swf", true),
        Match(".swf|", "http://a.com/x.swf?x", false),
        Match("/ads/*/banner", "http://a.com/ads/foo/banner.png", true),
        Match("/ads/*/banner", "http://a.com/ads/banner", false),
        Match("ad*banner", "http://a.com/ad-big-banner.png", true),
        Match("/ads?id=", "http://a.com/ads?id=3", true),
        Match("/ads?id=", "http://a.com/adsid=3", false),
        Match("||Example.com/ADS", "http://EXAMPLE.com/ads", true),
        Match("/banner/^", "http://a.com/banner/", true),
        Match("/banner/^", "http://a.com/banner/x", false),
        Match(#"/^https?:\/\/ads\d+\./"#, "https://ads12.example.com/", true),
        Match(#"/^https?:\/\/ads\d+\./"#, "https://adsx.example.com/", false),
        Match(#"/\/banners?\/\w+\.gif$/"#, "http://a.com/banner/pic_1.gif", true),
        Match(#"/\/banners?\/\w+\.gif$/"#, "http://a.com/banner/pic_1.gif?x", false),
    ]

    @Test(arguments: matchCases) func generatedExpressionsMatchLikeAdblockPlus(_ m: Match) throws {
        let rules = networkRules(m.filter)
        let json = try #require(rules.first)
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let trigger = obj["trigger"] as! [String: Any]
        let pattern = trigger["url-filter"] as! String
        #expect(urlFilterMatches(pattern, m.url, caseSensitive: trigger["url-filter-is-case-sensitive"] as? Bool ?? false) == m.matches, "\(pattern)")
    }

    // MARK: Cosmetic

    @Test func genericSelectorsAreBatched() {
        #expect(cosmeticRules("##.a\n##.b > i\n###c\n") == [
            #"{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".a, .b > i, #c"}}"#])
    }

    @Test func selectorsSplitAtTheBatchLimit() {
        var options = ContentRuleCompiler.Options()
        options.selectorsPerRule = 2
        let rules = cosmeticRules("##.a\n##.b\n##.c\n##.d\n##.e\n", options: options)
        #expect(rules.count == 3)
        #expect(rules.last == #"{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".e"}}"#)
    }

    @Test func domainSpecificSelectorsAreGroupedByDomain() {
        let rules = cosmeticRules("a.com##.x\nb.com##.x\na.com##.y\nb.com##.y\nc.org##.z\n")
        #expect(rules == [
            #"{"trigger":{"url-filter":".*","if-domain":["*a.com","*b.com"]},"action":{"type":"css-display-none","selector":".x, .y"}}"#,
            #"{"trigger":{"url-filter":".*","if-domain":["*c.org"]},"action":{"type":"css-display-none","selector":".z"}}"#])
    }

    @Test func exceptionsBecomeUnlessDomainOnTheSelector() {
        let rules = cosmeticRules("##.keep\n##.x\nexample.com#@#.x\n~other.org##.y\n")
        #expect(rules == [
            #"{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".keep"}}"#,
            #"{"trigger":{"url-filter":".*","unless-domain":["*example.com"]},"action":{"type":"css-display-none","selector":".x"}}"#,
            #"{"trigger":{"url-filter":".*","unless-domain":["*other.org"]},"action":{"type":"css-display-none","selector":".y"}}"#])
    }

    @Test func globalExceptionRemovesTheSelectorEverywhere() {
        #expect(cosmeticRules("##.x\na.com##.x\n#@#.x\n##.y\n") == [
            #"{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".y"}}"#])
    }

    @Test func domainExceptionRemovesTheDomainFromSpecificRules() {
        let rules = cosmeticRules("a.com,b.com##.x\nb.com#@#.x\n")
        #expect(rules == [#"{"trigger":{"url-filter":".*","if-domain":["*a.com"]},"action":{"type":"css-display-none","selector":".x"}}"#])
    }

    @Test func subdomainConflictsAreDroppedRatherThanOverHiding() {
        let result = ContentBlocker.compile(name: "t", text: "a.com##.x\nsub.a.com#@#.x\nb.com,~sub.b.com##.y\n")
        #expect(result.lists.filter { $0.kind == .cosmetic }.isEmpty)
        #expect(result.report.skipped[.cosmeticConflict] == 1)
        #expect(result.report.skipped[.mixedDomains] == 1)
    }

    @Test func genericHideExemptionsAddUnlessDomain() {
        let rules = cosmeticRules("##.x\n@@||quiet.test^$generichide\n@@$generichide,domain=a.com|b.com\nc.com##.y\n")
        #expect(rules == [
            #"{"trigger":{"url-filter":".*","unless-domain":["*a.com","*b.com","*quiet.test"]},"action":{"type":"css-display-none","selector":".x"}}"#,
            #"{"trigger":{"url-filter":".*","if-domain":["*c.com"]},"action":{"type":"css-display-none","selector":".y"}}"#])
    }

    @Test func specificHideExemptionRemovesTheDomain() {
        let rules = cosmeticRules("a.com,b.com##.x\n@@||a.com^$specifichide\n")
        #expect(rules == [#"{"trigger":{"url-filter":".*","if-domain":["*b.com"]},"action":{"type":"css-display-none","selector":".x"}}"#])
    }

    @Test func networkAndCosmeticRulesGoToSeparateLists() {
        let result = ContentBlocker.compile(name: "mix", text: "||a.test^\n##.ad\n@@||b.test^\n")
        #expect(result.lists.map(\.name) == ["mix.network.1", "mix.cosmetic.1"])
        #expect(result.lists.map(\.kind) == [.network, .cosmetic])
        #expect(!result.lists[1].json.contains("ignore-previous-rules"))
    }

    @Test func emptyInputProducesNoLists() {
        let result = ContentBlocker.compile(lists: [("empty", "! only a comment\n"), ("none", "")])
        #expect(result.lists.isEmpty)
        #expect(result.report.ruleCount == 0)
    }

    // MARK: Chunking

    @Test func listsAreSplitAtTheRuleBudgetAndEveryChunkKeepsItsExceptions() {
        var options = ContentRuleCompiler.Options()
        options.maxRulesPerList = 40
        var lines: [String] = []
        for i in 0..<100 { lines.append("||block\(i).test^") }
        for i in 0..<3 { lines.append("@@||ok\(i).test^") }
        lines.append("||important.test^$important")
        let out = ContentRuleCompiler(options: options).compile(FilterParser.parse(lines.joined(separator: "\n")))
        #expect(out.networkLists.count > 1)
        var blocks = 0
        for list in out.networkLists {
            #expect(list.count <= 40)
            let lastBlock = list.lastIndex { $0.contains("\"block\"") && !$0.contains("important") } ?? -1
            let firstException = list.firstIndex { $0.contains("ok") && $0.contains("ignore-previous-rules") } ?? Int.max
            #expect(lastBlock < firstException, "exceptions must follow the blocks of their list")
            #expect(list.filter { $0.contains("ok") && $0.contains("ignore-previous-rules") }.count == 3)
            blocks += list.filter { $0.contains("\"block\"") }.count
        }
        #expect(blocks == 101)
        #expect(out.networkLists.flatMap { $0 }.filter { $0.contains("important\\\\.test") }.count == 1)
    }

    @Test func realisticCountsStayUnderTheListLimit() {
        let text = (0..<100_000).map { "||host\($0).example.com^" }.joined(separator: "\n")
        let result = ContentBlocker.compile(name: "big", text: text)
        #expect(result.lists.count == 3)
        #expect(result.lists.allSatisfy { $0.ruleCount <= 40_000 })
        #expect(result.report.networkCompiled == 100_000)
    }

    @Test func storeIdentifiersChangeWithTheRules() {
        let a = ContentBlocker.compile(name: "x", text: "||a.test^").lists[0]
        let again = ContentBlocker.compile(name: "x", text: "||a.test^").lists[0]
        let b = ContentBlocker.compile(name: "x", text: "||b.test^").lists[0]
        #expect(a.storeIdentifier == again.storeIdentifier)
        #expect(a.storeIdentifier != b.storeIdentifier)
        #expect(a.storeIdentifier == "cosmos.x.network.1.\(a.digest)")
        #expect(a.digest.count == 12)
    }

    // MARK: Report

    @Test func reportCountsEveryOutcome() {
        let text = """
        [Adblock Plus 2.0]
        ! comment
        ||a.test^
        ||b.test^$redirect=x
        ##.ok
        a.com##div:has-text(x)
        a.*##.entity
        /foo|bar/
        """
        let r = ContentBlocker.compile(name: "r", text: text).report
        #expect(r.lines == 8)
        #expect(r.networkParsed == 3)
        #expect(r.networkCompiled == 1)
        #expect(r.cosmeticParsed == 3)
        #expect(r.cosmeticCompiled == 1)
        #expect(r.parsed == 6)
        #expect(r.compiled == 2)
        #expect(r.skipped == [.unsupportedOption("redirect"): 1, .extendedSelector: 1, .entityDomain: 1, .regexNotRepresentable: 1])
        #expect(r.parsed == r.compiled + r.skippedTotal)
    }
}
