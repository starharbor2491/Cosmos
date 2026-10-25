import Foundation
import Testing
@testable import CosmosBlocking

@Suite struct RuleListValidatorTests {
    private func list(_ rules: String...) -> String { "[" + rules.joined(separator: ",") + "]" }
    private func block(_ trigger: String) -> String { #"{"trigger":{\#(trigger)},"action":{"type":"block"}}"# }

    @Test func acceptsWellFormedLists() {
        let json = list(
            block(#""url-filter":"ads""#),
            block(#""url-filter":"^[^:]+://+([^:/]+\\.)?example\\.com[^a-zA-Z0-9_.%-]","resource-type":["script","raw","fetch"],"load-type":["third-party"]"#),
            block(#""url-filter":".*","resource-type":["document"],"load-context":["child-frame"],"if-domain":["*example.com","a.b.org"]"#),
            block(#""url-filter":"Ads","url-filter-is-case-sensitive":true,"unless-domain":["*example.com"]"#),
            #"{"trigger":{"url-filter":".*"},"action":{"type":"ignore-previous-rules"}}"#,
            #"{"trigger":{"url-filter":".*","if-domain":["*a.com"]},"action":{"type":"css-display-none","selector":".ad, div:has(> a)"}}"#,
            #"{"trigger":{"url-filter":"x(ab)*y?$"},"action":{"type":"block-cookies"}}"#,
            #"{"trigger":{"url-filter":"^http://"},"action":{"type":"make-https"}}"#)
        #expect(RuleListValidator.validate(json: json) == [])
    }

    @Test func acceptsEverythingTheCompilerProduces() {
        let text = ContentBlocker.fallbackListText
        #expect(!text.isEmpty)
        let result = ContentBlocker.compile(name: "fb", text: text + "\n||x.test^$popup\n@@||y.test^$document\n/a/*b$domain=a.com|~b.a.com\n")
        #expect(!result.lists.isEmpty)
        for l in result.lists { #expect(RuleListValidator.validate(json: l.json) == [], "\(l.name)") }
    }

    struct Bad: Sendable, CustomTestStringConvertible {
        let json: String
        let problem: String
        var testDescription: String { problem }
        init(_ json: String, _ problem: String) { self.json = json; self.problem = problem }
    }

    static let bad: [Bad] = [
        Bad("{}", "top level"),
        Bad("not json", "invalid JSON"),
        Bad("[]", "empty"),
        Bad(#"["x"]"#, "not an object"),
        Bad(#"[{"action":{"type":"block"}}]"#, "missing trigger"),
        Bad(#"[{"trigger":{"url-filter":"a"}}]"#, "missing action"),
        Bad(#"[{"trigger":{"url-filter":""},"action":{"type":"block"}}]"#, "empty"),
        Bad(#"[{"trigger":{},"action":{"type":"block"}}]"#, "url-filter missing"),
        Bad(#"[{"trigger":{"url-filter":"a","bogus":1},"action":{"type":"block"}}]"#, "unknown trigger key"),
        Bad(#"[{"trigger":{"url-filter":"a|b"},"action":{"type":"block"}}]"#, "alternation"),
        Bad(#"[{"trigger":{"url-filter":"(a|b)c"},"action":{"type":"block"}}]"#, "alternation"),
        Bad(#"[{"trigger":{"url-filter":"a(?=b)"},"action":{"type":"block"}}]"#, "lookaround"),
        Bad(#"[{"trigger":{"url-filter":"a(?<!b)c"},"action":{"type":"block"}}]"#, "lookaround"),
        Bad(#"[{"trigger":{"url-filter":"(a)\\1"},"action":{"type":"block"}}]"#, "escape"),
        Bad(#"[{"trigger":{"url-filter":"a{2,3}"},"action":{"type":"block"}}]"#, "counted repetition"),
        Bad(#"[{"trigger":{"url-filter":"a\\db"},"action":{"type":"block"}}]"#, "escape"),
        Bad(#"[{"trigger":{"url-filter":"a\\bb"},"action":{"type":"block"}}]"#, "escape"),
        Bad(#"[{"trigger":{"url-filter":"a^b"},"action":{"type":"block"}}]"#, "^ is only"),
        Bad(#"[{"trigger":{"url-filter":"a$b"},"action":{"type":"block"}}]"#, "$ is only"),
        Bad(#"[{"trigger":{"url-filter":"a**"},"action":{"type":"block"}}]"#, "repeated quantifier"),
        Bad(#"[{"trigger":{"url-filter":"*a"},"action":{"type":"block"}}]"#, "quantifier without"),
        Bad(#"[{"trigger":{"url-filter":"(a"},"action":{"type":"block"}}]"#, "unbalanced"),
        Bad(#"[{"trigger":{"url-filter":"a)"},"action":{"type":"block"}}]"#, "unbalanced"),
        Bad(#"[{"trigger":{"url-filter":"a[bc"},"action":{"type":"block"}}]"#, "unterminated"),
        Bad(#"[{"trigger":{"url-filter":"bücher"},"action":{"type":"block"}}]"#, "non-ASCII"),
        Bad(#"[{"trigger":{"url-filter":"a","url-filter-is-case-sensitive":"yes"},"action":{"type":"block"}}]"#, "boolean"),
        Bad(#"[{"trigger":{"url-filter":"a","resource-type":["xhr"]},"action":{"type":"block"}}]"#, "illegal resource-type"),
        Bad(#"[{"trigger":{"url-filter":"a","resource-type":[]},"action":{"type":"block"}}]"#, "non-empty"),
        Bad(#"[{"trigger":{"url-filter":"a","load-type":["second-party"]},"action":{"type":"block"}}]"#, "illegal load-type"),
        Bad(#"[{"trigger":{"url-filter":"a","load-context":["iframe"]},"action":{"type":"block"}}]"#, "illegal load-context"),
        Bad(#"[{"trigger":{"url-filter":"a","if-domain":["*a.com"],"unless-domain":["*b.com"]},"action":{"type":"block"}}]"#, "only one of"),
        Bad(#"[{"trigger":{"url-filter":"a","if-domain":[]},"action":{"type":"block"}}]"#, "non-empty"),
        Bad(#"[{"trigger":{"url-filter":"a","if-domain":["Example.com"]},"action":{"type":"block"}}]"#, "invalid if-domain"),
        Bad(#"[{"trigger":{"url-filter":"a","if-domain":["*.example.com"]},"action":{"type":"block"}}]"#, "invalid if-domain"),
        Bad(#"[{"trigger":{"url-filter":"a","if-domain":["example.com/path"]},"action":{"type":"block"}}]"#, "invalid if-domain"),
        Bad(#"[{"trigger":{"url-filter":"a","unless-domain":["bücher.de"]},"action":{"type":"block"}}]"#, "invalid unless-domain"),
        Bad(#"[{"trigger":{"url-filter":"a"},"action":{"type":"nuke"}}]"#, "illegal action type"),
        Bad(#"[{"trigger":{"url-filter":"a"},"action":{}}]"#, "action type missing"),
        Bad(#"[{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none"}}]"#, "requires a selector"),
        Bad(#"[{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":"  "}}]"#, "requires a selector"),
        Bad(#"[{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":"div:has-text(x)"}}]"#, "selector WebKit would drop"),
        Bad(#"[{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".a, div:foo"}}]"#, "selector WebKit would drop"),
        Bad(#"[{"trigger":{"url-filter":"a"},"action":{"type":"block","selector":".x"}}]"#, "must not have a selector"),
        Bad(#"[{"trigger":{"url-filter":"a"},"action":{"type":"notify"}}]"#, "notification"),
    ]

    @Test(arguments: bad) func rejects(_ b: Bad) {
        let problems = RuleListValidator.validate(json: b.json)
        #expect(!problems.isEmpty)
        #expect(problems.contains { $0.localizedCaseInsensitiveContains(b.problem) }, "\(problems)")
    }

    @Test func rejectsMoreRulesThanWebKitAllows() {
        let rule = #"{"trigger":{"url-filter":"a"},"action":{"type":"block"}}"#
        let json = "[" + [String](repeating: rule, count: 150_001).joined(separator: ",") + "]"
        #expect(RuleListValidator.validate(json: json).contains { $0.contains("exceed") })
    }

    @Test(arguments: [
        ("abc", []), ("^a.*b$", []), ("a+b?c*", []), ("(ab)+", []), ("[^a-z0-9_.%-]", []), ("a\\.b\\?", []),
        ("a|b", ["alternation | is unsupported"]), ("a{2}", ["counted repetition {} is unsupported"]),
    ] as [(String, [String])])
    func regexSubsetChecker(_ pattern: String, _ problems: [String]) {
        #expect(RuleListValidator.regexProblems(pattern) == problems)
    }
}

@Suite struct CSSSelectorValidatorTests {
    @Test(arguments: [
        ".ad", "#ad", "div", "*", "div.ad#x", "a[href]", "a[href=\"x\"]", "a[href='x']", "a[href^=\"http://ads.\"]", "a[href$=\".gif\" i]",
        "a[data-x=y]", ".a > .b", ".a + .b", ".a ~ .b", ".a .b", ".a>.b+.c~.d", ".a, .b", "div:not(.x)", "div:not(.x, .y)", ":is(.a, .b) > i",
        ":where(.a)", "li:nth-child(2n+1)", "li:nth-child(odd)", "li:nth-child(-n + 3)", "li:nth-child(2 of .x)", "li:nth-last-of-type(2)",
        "p:first-child", "p:last-of-type", "div:empty", ":root", "a:hover", "input:checked", "div:has(> a)", "div:has(+ .ad)",
        "div:has(a, b)", "div:not(:has(a))", "div:has(:not(a))", ":is(div:has(a))", ".dark\\:border-gray-700", ".w-\\[300px\\]", "\\31 23",
        ".ad::before", ".ad:after", ".résumé", "a:lang(en)", "a:dir(rtl)", "[class*='ad-']",
    ])
    func accepts(_ selector: String) {
        #expect(CSSSelectorValidator.isValid(selector), "\(selector)")
    }

    @Test(arguments: [
        "", " ", ",", ".a,", ",.a", "> .a", ".a >", ".a > > .b", "#1ad", ".1ad", "div:foo", "div:has-text(x)", "div:contains(x)", "div:xpath(//a)",
        "div:matches-css(x: y)", "div:upward(1)", "div:-abp-has(a)", "div:style(x: y)", "div:remove()", "div:not()", "div:nth-child(foo)", "a:lang()",
        "a[href", "a[href=]", "a[href@=\"x\"]", "a[xlink|href]", "ns|a", "div{x:y}", ".a;.b", ".a /* c */ b", "div:has(a:has(b))", "div:has(:not(:has(a)))",
        ".a::first-line", "::slotted(a)", "a >>> b", "a:hover:", "a:", "..a", "#", ".", "a[", "a:not(b",
    ])
    func rejects(_ selector: String) {
        #expect(!CSSSelectorValidator.isValid(selector), "\(selector)")
    }

    @Test func classifiesRejections() {
        #expect(CSSSelectorValidator.rejection(for: ".ad") == nil)
        #expect(CSSSelectorValidator.rejection(for: "div:has-text(x)") == .extendedSelector)
        #expect(CSSSelectorValidator.rejection(for: "div:-abp-contains(x)") == .extendedSelector)
        #expect(CSSSelectorValidator.rejection(for: "div:foo") == .invalidSelector)
        #expect(CSSSelectorValidator.rejection(for: ".a {color: red}") == .cssInjection)
    }
}
