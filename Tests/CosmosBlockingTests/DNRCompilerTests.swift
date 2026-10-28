import Foundation
import Testing
@testable import CosmosBlocking

@Suite struct DNRCompilerTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let filter: String
        /// The action type, nil when the filter makes no rule.
        let action: String?
        let priority: Int
        /// The rule's `condition`, as JSON.
        let condition: String
        var testDescription: String { filter }
        init(_ filter: String, _ action: String? = nil, priority: Int = 1, _ condition: String = "{}") {
            self.filter = filter; self.action = action; self.priority = priority; self.condition = condition
        }
    }

    /// Representative filters and the rule each becomes (nil: none).
    static let cases: [Case] = [
        Case("||ads.example.com^", "block", #"{"urlFilter": "||ads.example.com^"}"#),
        Case("|http://track.example.net/pixel.gif|", "block", #"{"urlFilter": "|http://track.example.net/pixel.gif|"}"#),
        Case("/adframe.", "block", #"{"urlFilter": "/adframe."}"#),
        Case(".swf|", "block", #"{"urlFilter": ".swf|"}"#),
        Case("ad*banner.gif", "block", #"{"urlFilter": "ad*banner.gif"}"#),
        Case("||example.com/Foo$match-case", "block", #"{"urlFilter": "||example.com/Foo", "isUrlFilterCaseSensitive": true}"#),
        // types
        Case("||x.test^$script", "block", #"{"urlFilter": "||x.test^", "resourceTypes": ["script"]}"#),
        Case("||x.test^$xhr", "block", #"{"urlFilter": "||x.test^", "resourceTypes": ["xmlhttprequest"]}"#),
        Case("||x.test^$subdocument", "block", #"{"urlFilter": "||x.test^", "resourceTypes": ["sub_frame"]}"#),
        Case("||x.test^$document", "block", #"{"urlFilter": "||x.test^", "resourceTypes": ["main_frame"]}"#),
        Case("||x.test^$stylesheet,font,media,ping,websocket,other", "block",
             #"{"urlFilter": "||x.test^", "resourceTypes": ["font", "media", "other", "ping", "stylesheet", "websocket"]}"#),
        Case("||x.test^$~script,~subdocument", "block",
             #"{"urlFilter": "||x.test^", "resourceTypes": ["font", "image", "media", "other", "ping", "stylesheet", "websocket", "xmlhttprequest"]}"#),
        // party and sites
        Case("||x.test^$third-party", "block", #"{"urlFilter": "||x.test^", "domainType": "thirdParty"}"#),
        Case("||x.test^$~third-party", "block", #"{"urlFilter": "||x.test^", "domainType": "firstParty"}"#),
        Case("/ads/*/x.js$domain=b.com|A.com", "block", #"{"urlFilter": "/ads/*/x.js", "initiatorDomains": ["a.com", "b.com"]}"#),
        Case("/ads/*/x.js$domain=a.com|~b.a.com", "block", #"{"urlFilter": "/ads/*/x.js", "initiatorDomains": ["a.com"], "excludedInitiatorDomains": ["b.a.com"]}"#),
        Case("$script,domain=a.com", "block", #"{"resourceTypes": ["script"], "initiatorDomains": ["a.com"]}"#),
        // exceptions and priorities
        Case("@@||example.com/ok.js$script", "allow", priority: 2, #"{"urlFilter": "||example.com/ok.js", "resourceTypes": ["script"]}"#),
        Case("||imp.test^$important", "block", priority: 3, #"{"urlFilter": "||imp.test^"}"#),
        Case("@@||site.test^$document", "allowAllRequests", priority: 4, #"{"urlFilter": "||site.test^", "resourceTypes": ["main_frame", "sub_frame"]}"#),
        // regular expressions: RE2 has no look-around and no back-references
        Case(#"/^https?:\/\/ads\d+\./"#, "block", #"{"regexFilter": "^https?:\\/\\/ads\\d+\\."}"#),
        Case(#"/ad(?=x)/"#),
        Case(#"/(a)\1/"#),
        Case(#"/ad.*+x/"#),
        Case(#"/ad(?>s)x/"#),
        Case(#"/[a-z/"#),
        Case(#"/ads\/"#),
        // nothing Chromium could do as asked
        Case("||x.test^$popup"),
        Case("$popup,domain=a.com"),
        Case("||x.test^$redirect=noop.js"),
        Case("||x.test^$csp=script-src 'none'"),
        Case("||x.test^$removeparam=utm"),
        Case("$third-party"),
        Case("||bücher.example^"),
    ]

    @Test(arguments: cases) func filtersBecomeTheirRule(_ c: Case) throws {
        let rules = networkRules(c.filter)
        guard let action = c.action else {
            #expect(rules.isEmpty, "\(rules)")
            return
        }
        try #require(rules.count == 1, "\(rules)")
        #expect(rules[0]["action"] as? NSDictionary == ["type": action])
        #expect(rules[0]["condition"] as? NSDictionary == decode(c.condition))
        #expect(rules[0]["priority"] as? Int == c.priority)
    }

    @Test(arguments: cases) func everyRuleIsOneChromiumAccepts(_ c: Case) {
        for list in DNRCompiler().compile(FilterParser.parse(c.filter)).networkLists {
            #expect(dnrProblems(ContentBlocker.assemble(list)).isEmpty)
        }
    }

    // MARK: Precedence

    /// Chromium applies the matching rule with the highest priority: an exception beats a block, `$important` beats an
    /// exception, and a site the list allows entirely beats everything.
    @Test func prioritiesOrderBlockExceptionImportantAndWholePageExceptions() {
        let rules = networkRules("||a.test^\n@@||a.test^\n||a.test^$important\n@@||a.test^$document\n")
        #expect(rules.map { ($0["action"] as? NSDictionary)?["type"] as? String } == ["block", "allow", "block", "allowAllRequests"])
        #expect(rules.map { $0["priority"] as? Int } == [1, 2, 3, 4])
    }

    @Test func duplicatesAreCollapsed() {
        #expect(networkRules("||a.test^\n||a.test^\n").count == 1)
    }

    @Test func badfilterDisablesTheMatchingFilter() {
        let result = ContentBlocker.compile(name: "t", text: "||a.test^$third-party\n||b.test^\n||a.test^$third-party,badfilter\n")
        let json = result.lists.first?.json ?? ""
        #expect(json.contains("b.test"))
        #expect(!json.contains("a.test"))
        #expect(result.report.skipped[.badfiltered] == 1)
    }

    @Test func hostsFileEntriesBecomeHostRules() {
        let rules = networkRules("0.0.0.0 ads.example.com\n127.0.0.1 localhost\n")
        #expect(rules.map { ($0["condition"] as! NSDictionary)["urlFilter"] as? String } == ["||ads.example.com^"])
    }

    @Test func regularExpressionsStopAtTheirShareOfChromiumsBudget() {
        var options = DNRCompiler.Options()
        options.maxRegexRules = 2
        let out = DNRCompiler(options: options).compile(FilterParser.parse("/ad1[0-9]/\n/ad2[0-9]/\n/ad3[0-9]/\n||plain.test^\n"))
        let rules = out.networkLists.flatMap { $0 }.map(decode)
        #expect(rules.filter { ($0["condition"] as! NSDictionary)["regexFilter"] != nil }.count == 2)
        #expect(rules.count == 3)
        #expect(out.report.skipped[.overLimit] == 1)
    }

    // MARK: Element hiding

    @Test func genericSpecificAndExcludedSelectorsAreKeptApart() {
        let c = cosmetic("##.a\n##.b > i\na.com,B.com##.x\n~other.org##.y\n")
        #expect(c.generic == [".a", ".b > i", ".y"])
        #expect(c.specific == ["a.com": [".x"], "b.com": [".x"]])
        #expect(c.exceptions == ["other.org": [".y"]])
    }

    @Test func aSiteExceptionIsKeptForTheSite() {
        let c = cosmetic("##.x\nexample.com#@#.x\na.com,b.com##.z\nb.com#@#.z\n")
        #expect(c.generic == [".x"])
        #expect(c.exceptions == ["example.com": [".x"], "b.com": [".z"]])
        #expect(c.specific == ["a.com": [".z"], "b.com": [".z"]], "the page script drops b.com's .z by its exception")
    }

    @Test func anExceptionWithoutASiteRemovesTheSelectorEverywhere() {
        let c = cosmetic("##.x\na.com##.x\n#@#.x\n##.y\n")
        #expect(c.generic == [".y"])
        #expect(c.specific.isEmpty)
    }

    @Test func hidingSwitchesBecomeSiteListsNotRequestRules() {
        let out = DNRCompiler().compile(FilterParser.parse("##.x\n@@||quiet.test^$generichide\n@@$generichide,domain=a.com|b.com\n@@||bare.test^$elemhide\n"))
        #expect(out.networkLists.isEmpty)
        #expect(out.cosmetic.genericHide == ["a.com", "b.com", "quiet.test"])
        #expect(out.cosmetic.hideNothing == ["bare.test"])
    }

    @Test func invalidSelectorsAreSkipped() {
        let result = ContentBlocker.compile(name: "t", text: "##.ok\n##div:has-text(x)\n##..broken\n")
        let c = try? JSONDecoder().decode(DNRCompiler.Cosmetic.self, from: Data((result.lists.first { $0.kind == .cosmetic }?.json ?? "").utf8))
        #expect(c?.generic == [".ok"])
        #expect(result.report.cosmeticCompiled == 1)
        #expect(result.report.parsed == result.report.compiled + result.report.skippedTotal)
    }

    // MARK: Lists

    @Test func networkAndCosmeticRulesGoToSeparateLists() {
        let result = ContentBlocker.compile(name: "mix", text: "||a.test^\n##.ad\n@@||b.test^\n")
        #expect(result.lists.map(\.name) == ["mix.network.1", "mix.cosmetic.1"])
        #expect(result.lists.map(\.kind) == [.network, .cosmetic])
        #expect(dnrProblems(result.lists[0].json).isEmpty)
        #expect((try? JSONDecoder().decode(DNRCompiler.Cosmetic.self, from: Data(result.lists[1].json.utf8)))?.generic == [".ad"])
    }

    @Test func emptyInputProducesNoLists() {
        let result = ContentBlocker.compile(lists: [("empty", "! only a comment\n"), ("none", "")])
        #expect(result.lists.isEmpty)
        #expect(result.report.ruleCount == 0)
    }

    /// Chromium turns off a whole ruleset that goes over budget, so a list is cut into small ones that fail alone.
    @Test func listsAreCutIntoRulesetsOfTheGivenSize() {
        var options = DNRCompiler.Options()
        options.maxRulesPerList = 40
        let text = (0..<100).map { "||block\($0).test^" }.joined(separator: "\n")
        let result = ContentBlocker.compile(name: "big", text: text, options: options)
        #expect(result.lists.map(\.ruleCount) == [40, 40, 20])
        #expect(result.lists.map(\.name) == ["big.network.1", "big.network.2", "big.network.3"])
        #expect(result.lists.allSatisfy { dnrProblems($0.json).isEmpty })
        #expect(result.report.networkCompiled == 100)
    }

    @Test func digestsChangeWithTheRules() {
        let a = ContentBlocker.compile(name: "x", text: "||a.test^").lists[0]
        let again = ContentBlocker.compile(name: "x", text: "||a.test^").lists[0]
        let b = ContentBlocker.compile(name: "x", text: "||b.test^").lists[0]
        #expect(a.digest == again.digest)
        #expect(a.digest != b.digest)
        #expect(a.digest.count == 12)
    }

    // MARK: Report

    /// A filter that both switches hiding off for a site and makes a request rule counts once, whichever part of it took.
    @Test(arguments: ["@@||a.com^$generichide,script", "@@||a.com^$generichide,popup", "@@||a.com^$elemhide,image"])
    func aHidingSwitchWithTypesCountsOnce(_ filter: String) {
        let r = ContentBlocker.compile(name: "r", text: filter).report
        #expect(r.networkParsed == 1)
        #expect(r.networkCompiled == 1)
        #expect(r.parsed == r.compiled + r.skippedTotal)
    }

    /// A `$badfilter` line did its work by switching another filter off.
    @Test func aBadfilterLineCountsAsCompiled() {
        let r = ContentBlocker.compile(name: "t", text: "||a.test^\n||a.test^$badfilter\n").report
        #expect(r.networkParsed == 2)
        #expect(r.networkCompiled == 1)
        #expect(r.skipped == [.badfiltered: 1])
        #expect(r.parsed == r.compiled + r.skippedTotal)
    }

    /// A hiding switch has to name sites; one that names none does nothing, and the report says so.
    @Test func aHidingSwitchThatNamesNoSiteIsSkipped() {
        let out = DNRCompiler().compile(FilterParser.parse("@@/ads/$generichide\n"))
        #expect(out.cosmetic.genericHide.isEmpty)
        #expect(out.report.networkCompiled == 0)
        #expect(out.report.skipped == [.unsupportedOption("generichide"): 1])
    }

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
        /ad(?!s)/
        """
        let r = ContentBlocker.compile(name: "r", text: text).report
        #expect(r.lines == 9)
        #expect(r.networkParsed == 4)
        #expect(r.networkCompiled == 2, "`/foo|bar/` is a regular expression RE2 can run")
        #expect(r.cosmeticParsed == 3)
        #expect(r.cosmeticCompiled == 1)
        #expect(r.skipped == [.unsupportedOption("redirect"): 1, .extendedSelector: 1, .entityDomain: 1, .regexNotRepresentable: 1])
        #expect(r.parsed == r.compiled + r.skippedTotal)
    }
}
