import Foundation
import Testing
@testable import CosmosBlocking

@Suite struct FilterParserTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let line: String
        let expected: FilterParser.Line
        var testDescription: String { line }
        init(_ line: String, _ expected: FilterParser.Line) { self.line = line; self.expected = expected }
    }

    static let networkCases: [Case] = [
        Case("||ads.example.com^", net("ads.example.com^", host: true)),
        Case("|http://example.com/ad.gif", net("http://example.com/ad.gif", start: true)),
        Case("/banner.swf|", net("/banner.swf", end: true)),
        Case("|https://example.com/|", net("https://example.com/", start: true, end: true)),
        Case("/banners/*/img^", net("/banners/*/img^")),
        Case("-advert-", net("-advert-")),
        Case("&adtype=*&", net("&adtype=*&")),
        // options
        Case("||example.com^$third-party", net("example.com^", host: true, third: true)),
        Case("||example.com^$~third-party", net("example.com^", host: true, third: false)),
        Case("||example.com^$3p", net("example.com^", host: true, third: true)),
        Case("||example.com^$1p", net("example.com^", host: true, third: false)),
        Case("||example.com^$first-party", net("example.com^", host: true, third: false)),
        Case("||example.com^$script", net("example.com^", host: true, types: [.script])),
        Case("||example.com^$script,image,~stylesheet", net("example.com^", host: true, types: [.script, .image])),
        Case("||example.com^$xhr,frame,css", net("example.com^", host: true, types: [.xmlhttprequest, .subdocument, .stylesheet])),
        Case("||example.com^$xmlhttprequest,subdocument,stylesheet,font,media,ping,websocket,other", net("example.com^", host: true, types: [.xmlhttprequest, .subdocument, .stylesheet, .font, .media, .ping, .websocket, .other])),
        Case("||example.com^$~script", net("example.com^", host: true, types: ResourceType.defaultSet.subtracting([.script]))),
        Case("||example.com^$~script,~image", net("example.com^", host: true, types: ResourceType.defaultSet.subtracting([.script, .image]))),
        Case("||example.com^$popup", net("example.com^", host: true, types: [.popup])),
        Case("||example.com^$document", net("example.com^", host: true, types: [.document])),
        Case("||example.com^$doc", net("example.com^", host: true, types: [.document])),
        Case("||example.com^$all", net("example.com^", host: true, types: Set(ResourceType.allCases))),
        Case("||example.com^$domain=a.com|b.com", net("example.com^", host: true, include: ["a.com", "b.com"])),
        Case("||example.com^$domain=~a.com", net("example.com^", host: true, exclude: ["a.com"])),
        Case("||example.com^$domain=a.com|~sub.a.com", net("example.com^", host: true, include: ["a.com"], exclude: ["sub.a.com"])),
        Case("||example.com^$from=A.com", net("example.com^", host: true, include: ["a.com"])),
        Case("||example.com^$match-case", net("example.com^", host: true, matchCase: true)),
        Case("||example.com^$important", net("example.com^", host: true, important: true)),
        Case("||example.com^$badfilter", net("example.com^", host: true, badfilter: true)),
        Case("||example.com^$third-party,script,important,domain=a.com", net("example.com^", host: true, types: [.script], third: true, include: ["a.com"], important: true)),
        // exceptions
        Case("@@||example.com^", net("example.com^", host: true, exception: true)),
        Case("@@||example.com/ok.js$script", net("example.com/ok.js", host: true, exception: true, types: [.script])),
        Case("@@||example.com^$document", net("example.com^", host: true, exception: true, types: [.document])),
        Case("@@||example.com^$generichide", net("example.com^", host: true, exception: true, hide: .generic)),
        Case("@@||example.com^$ghide", net("example.com^", host: true, exception: true, hide: .generic)),
        Case("@@||example.com^$specifichide", net("example.com^", host: true, exception: true, hide: .specific)),
        Case("@@||example.com^$elemhide", net("example.com^", host: true, exception: true, hide: .all)),
        Case("@@$generichide,domain=a.com|b.com", net("", exception: true, include: ["a.com", "b.com"], hide: .generic)),
        // option-only filters
        Case("$popup,domain=a.com", net("", types: [.popup], include: ["a.com"])),
        // regular expressions
        Case(#"/ads\d+\.js/"#, regexFilter(#"ads\d+\.js"#)),
        Case(#"/^https?:\/\/ads\./$script,third-party"#, regexFilter(#"^https?:\/\/ads\."#, types: [.script], third: true)),
        Case(#"@@/ads\.js/$match-case"#, regexFilter(#"ads\.js"#, exception: true, matchCase: true)),
        // a "$" inside the pattern is not an option separator
        Case("/ads$id", .skipped(.unsupportedOption("id"))),
        // hosts-file entries
        Case("0.0.0.0 ads.example.com", net("ads.example.com^", host: true)),
        Case("127.0.0.1\ttracker.example.net # comment", net("tracker.example.net^", host: true)),
        Case("127.0.0.1 localhost", .comment),
    ]

    @Test(arguments: networkCases) func network(_ c: Case) {
        #expect(FilterParser.parseLine(c.line) == c.expected)
    }

    static let cosmeticCases: [Case] = [
        Case("##.ad-banner", hide(".ad-banner")),
        Case("###ad", hide("#ad")),
        Case("##div[class*=\"sponsor\"] > a:not(.keep)", hide("div[class*=\"sponsor\"] > a:not(.keep)")),
        Case("##.a, .b", hide(".a, .b")),
        Case("example.com##.ad", hide(".ad", include: ["example.com"])),
        Case("a.com,b.org##.ad", hide(".ad", include: ["a.com", "b.org"])),
        Case("~a.com##.ad", hide(".ad", exclude: ["a.com"])),
        Case("a.com,~sub.a.com##.ad", hide(".ad", include: ["a.com"], exclude: ["sub.a.com"])),
        Case("Example.COM##.ad", hide(".ad", include: ["example.com"])),
        Case("#@#.ad", hide(".ad", exception: true)),
        Case("example.com#@#.ad", hide(".ad", include: ["example.com"], exception: true)),
        Case("example.com##div:has(> .ad)", hide("div:has(> .ad)", include: ["example.com"])),
        Case("example.com##li:nth-child(2n+1)", hide("li:nth-child(2n+1)", include: ["example.com"])),
        // extended syntax is skipped, never mis-compiled
        Case("example.com#?#div:has(span)", .skipped(.extendedSelector)),
        Case("example.com#@?#div:has(span)", .skipped(.extendedSelector)),
        Case("example.com##div:has-text(Sponsored)", .skipped(.extendedSelector)),
        Case("example.com##div:-abp-has(a)", .skipped(.extendedSelector)),
        Case("example.com##div:-abp-contains(Ad)", .skipped(.extendedSelector)),
        Case("example.com##div:contains(Ad)", .skipped(.extendedSelector)),
        Case("example.com##div:xpath(//a)", .skipped(.extendedSelector)),
        Case("example.com##div:matches-css(display: block)", .skipped(.extendedSelector)),
        Case("example.com##div:matches-css-before(content: /ad/)", .skipped(.extendedSelector)),
        Case("example.com##div:upward(2)", .skipped(.extendedSelector)),
        Case("example.com##div:not(:has-text(ad))", .skipped(.extendedSelector)),
        Case("example.com##+js(abort-on-property-read, ads)", .skipped(.scriptlet)),
        Case("example.com#@#+js(abort-on-property-read, ads)", .skipped(.scriptlet)),
        Case("example.com##^script:has-text(adblock)", .skipped(.htmlFilter)),
        Case("example.com$$script[tag-content=\"adblock\"]", .skipped(.htmlFilter)),
        Case("example.com#$#body { overflow: auto !important; }", .skipped(.cssInjection)),
        Case("example.com##.banner {height: 0 !important}", .skipped(.cssInjection)),
        Case("example.com#%#//scriptlet('abort-on-property-read', 'ads')", .skipped(.scriptRule)),
        Case("example.*##.ad", .skipped(.entityDomain)),
        Case("a.com,example.*##.ad", hide(".ad", include: ["a.com"])),
        Case("~example.*##.ad", .skipped(.entityDomain)),
        Case("example.com##div:foo", .skipped(.invalidSelector)),
        Case("example.com##a[href", .skipped(.invalidSelector)),
        Case("example.com##div:has(a:has(b))", .skipped(.invalidSelector)),
        Case("example.com##", .skipped(.malformed)),
    ]

    @Test(arguments: cosmeticCases) func cosmetic(_ c: Case) {
        #expect(FilterParser.parseLine(c.line) == c.expected)
    }

    static let skippedNetworkCases: [Case] = [
        Case("||example.com^$redirect=noopjs", .skipped(.unsupportedOption("redirect"))),
        Case("||example.com^$redirect-rule=noop.js", .skipped(.unsupportedOption("redirect-rule"))),
        Case("||example.com^$removeparam=utm_source", .skipped(.unsupportedOption("removeparam"))),
        Case("||example.com^$queryprune", .skipped(.unsupportedOption("queryprune"))),
        Case("||example.com^$csp=script-src 'none'", .skipped(.unsupportedOption("csp"))),
        Case("||example.com^$replace=/a/b/", .skipped(.unsupportedOption("replace"))),
        Case("||example.com^$rewrite=abp-resource:blank-js", .skipped(.unsupportedOption("rewrite"))),
        Case("||example.com^$denyallow=a.com|b.com", .skipped(.unsupportedOption("denyallow"))),
        Case("||example.com^$method=post", .skipped(.unsupportedOption("method"))),
        Case("||example.com^$header=via:1.1", .skipped(.unsupportedOption("header"))),
        Case("||example.com^$object", .skipped(.unsupportedOption("object"))),
        Case("||example.com^$~object,third-party", net("example.com^", host: true, third: true)),
        Case("||example.com^$script,~object-subrequest", net("example.com^", host: true, types: [.script])),
        Case("||example.com/ck/a*u=a1$doc,urlskip=?u /^a1(.*)$/ -safebase64", .skipped(.unsupportedOption("urlskip"))),
        Case("||example.com^$inline-script", .skipped(.unsupportedOption("inline-script"))),
        Case("||example.com^$domain=example.*", .skipped(.entityDomain)),
        Case("||example.com^$domain=~example.*", .skipped(.entityDomain)),
        Case("||example.com^$domain=a.com|example.*", net("example.com^", host: true, include: ["a.com"])),
        Case("||example.com^$script,~script", .skipped(.malformed)),
        Case("||exa mple.com^", .skipped(.malformed)),
    ]

    @Test(arguments: skippedNetworkCases) func unsupportedNetwork(_ c: Case) {
        #expect(FilterParser.parseLine(c.line) == c.expected)
    }

    @Test(arguments: ["", "   ", "! Title: EasyList", "!#include ads.txt", "[Adblock Plus 2.0]", "[uBlock Origin 1.0]", "# hosts comment", "\t! indented"])
    func comments(_ line: String) {
        #expect(FilterParser.parseLine(line) == .comment)
    }

    @Test func whitespaceAndCarriageReturnsAreTrimmed() {
        #expect(FilterParser.parseLine("  ||example.com^$third-party \r") == net("example.com^", host: true, third: true))
    }

    // MARK: Whole lists

    @Test func countsLinesAndHandlesCRLFAndMissingTrailingNewline() {
        let text = "[Adblock Plus 2.0]\r\n! Title\r\n||a.com^\r\n\r\n##.ad\r\n||b.com^$redirect=x"
        let r = FilterParser.parse(text)
        #expect(r.lineCount == 6)
        #expect(r.filters.count == 2)
        #expect(r.commentCount == 3)
        #expect(r.skipped == [.unsupportedOption("redirect"): 1])
        #expect(r.skippedNetwork == 1)
        #expect(r.skippedCosmetic == 0)
    }

    @Test func emptyAndTrailingNewlineTexts() {
        #expect(FilterParser.parse("").lineCount == 0)
        #expect(FilterParser.parse("||a.com^\n").lineCount == 1)
        #expect(FilterParser.parse("||a.com^\n\n").lineCount == 2)
    }

    @Test func preprocessorConditions() {
        let text = """
        ||always.com^
        !#if env_firefox
        ||firefox-only.com^
        !#endif
        !#if env_safari
        ||safari.com^
        !#else
        ||not-safari.com^
        !#endif
        !#if !env_safari && ext_ublock
        ||ublock-only.com^
        !#endif
        !#if env_chromium || env_safari
        ||chromium-or-safari.com^
        !#endif
        !#if (env_firefox || env_chromium) && !env_mobile
        ||nested-no.com^
        !#if env_safari
        ||nested-inner.com^
        !#endif
        !#endif
        """
        let r = FilterParser.parse(text)
        let patterns: [String] = r.filters.compactMap {
            if case .network(let n) = $0, case .glob(let g) = n.pattern { return g }
            return nil
        }
        #expect(patterns == ["always.com^", "safari.com^", "chromium-or-safari.com^"])
        #expect(r.conditionalCount == 5)
    }

    @Test func conditionEvaluator() {
        #expect(FilterParser.evaluateCondition("env_safari"))
        #expect(!FilterParser.evaluateCondition("env_chromium"))
        #expect(FilterParser.evaluateCondition("!env_chromium"))
        #expect(FilterParser.evaluateCondition("env_safari && !ext_ublock"))
        #expect(!FilterParser.evaluateCondition("env_safari && ext_ublock"))
        #expect(FilterParser.evaluateCondition("(ext_ublock || env_safari) && true"))
        #expect(!FilterParser.evaluateCondition("unknown_flag"))
    }

    @Test func entityDomainsAreNotCountedAsCosmetic() {
        let r = FilterParser.parse("a.*##.x\n||b.com^$redirect=y\n")
        #expect(r.skippedCosmetic == 1)
        #expect(r.skippedNetwork == 1)
    }

    // MARK: Speed

    @Test func parsesLargeListQuickly() {
        var lines: [String] = ["[Adblock Plus 2.0]"]
        for i in 0..<70_000 {
            switch i % 7 {
            case 0: lines.append("||ads\(i).example.com^$third-party")
            case 1: lines.append("/banner\(i)/*.gif$image,domain=a\(i).com|~b.com")
            case 2: lines.append("@@||cdn\(i).example.net/ok.js$script")
            case 3: lines.append("site\(i).com##.ad-\(i) > div:not(.keep)")
            case 4: lines.append("##div[id^=\"ad\(i)\"]")
            case 5: lines.append("! comment \(i)")
            default: lines.append("||tracker\(i).net^")
            }
        }
        let text = lines.joined(separator: "\n")
        let start = Date()
        let result = FilterParser.parse(text)
        let elapsed = Date().timeIntervalSince(start)
        #expect(result.filters.count > 55_000)
        #if DEBUG
        #expect(elapsed < 10, "parsing 70k lines took \(elapsed)s")
        #else
        #expect(elapsed < 2, "parsing 70k lines took \(elapsed)s")
        #endif
    }
}
