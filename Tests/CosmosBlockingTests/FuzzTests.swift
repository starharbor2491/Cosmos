import Foundation
import Testing
@testable import CosmosBlocking

/// Deterministic (seeded) mutation fuzzing: broken variants of every syntax form must never crash the parser or
/// compiler, and whatever does compile must pass the validator.
@Suite struct FuzzTests {
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let seeds: [String] = [
        "||ads.example.com^", "||ads.example.com^$third-party,script,domain=a.com|~b.a.com", "|http://example.com/ad.gif|", "/banner/*/img^",
        "@@||example.com/ok.js$script,important", "@@||site.test^$document", "@@$generichide,domain=a.com|b.com", "||x.test^$popup,badfilter",
        #"/^https?:\/\/ads\d+\.[a-z]{2,3}\//$script"#, #"/ads\d+(\.js)?$/$match-case"#, "||x.test^$redirect=noop.js", "||x.test^$csp=script-src 'none'",
        "||x.test^$removeparam=utm_source", "||x.test^$all", "||x.test^$~script,~image,xhr", "$popup,domain=a.com", "0.0.0.0 ads.example.com",
        "##.ad-banner", "###ad", "example.com,~sub.example.com##.sponsored > a:not(.keep)", "example.com#@#.sponsored", "a.com##div:has(> .ad)",
        "a.com##li:nth-child(2n+1)", "a.com##div:has-text(Ad)", "a.com#?#div:has(span)", "a.com##+js(aopr, x)", "a.com##^script:has-text(x)",
        "a.com#$#body { overflow: auto !important; }", "a.*##.ad", "a.com##a[href^=\"http://ads.\" i]", "a.com##.dark\\:x", "a.com##:is(.a, .b) ~ i",
        "!#if env_safari && !ext_ublock", "!#else", "!#endif", "[Adblock Plus 2.0]", "! comment", "# hosts comment",
    ]

    static func mutate(_ seed: String, _ rng: inout SplitMix64) -> String {
        var chars = Array(seed)
        let alphabet = Array("|^*$@#?~,./:=-_[]()\\\"' {}!+&%0aAbz\u{00e9}\u{1F600}\t")
        let operations = Int.random(in: 1...4, using: &rng)
        for _ in 0..<operations {
            switch Int.random(in: 0..<6, using: &rng) {
            case 0 where !chars.isEmpty:
                let i = Int.random(in: 0..<chars.count, using: &rng)
                chars.remove(at: i)
            case 1:
                chars.insert(alphabet.randomElement(using: &rng)!, at: Int.random(in: 0...chars.count, using: &rng))
            case 2 where !chars.isEmpty:
                chars[Int.random(in: 0..<chars.count, using: &rng)] = alphabet.randomElement(using: &rng)!
            case 3 where !chars.isEmpty:
                chars.removeSubrange(Int.random(in: 0..<chars.count, using: &rng)...)
            case 4 where chars.count > 2:
                let i = Int.random(in: 0..<chars.count - 1, using: &rng)
                chars.swapAt(i, i + 1)
            default:
                chars.append(contentsOf: seed.prefix(Int.random(in: 0...6, using: &rng)))
            }
        }
        return String(chars)
    }

    @Test func mutatedLinesNeverCrashAndCompileToValidRules() {
        var rng = SplitMix64(state: 0xC05_0505)
        var lines: [String] = []
        for seed in Self.seeds {
            lines.append(seed)
            for _ in 0..<250 { lines.append(Self.mutate(seed, &rng)) }
        }
        // Each line alone, to prove the parser never traps.
        for line in lines { _ = FilterParser.parseLine(line) }

        var options = ContentRuleCompiler.Options()
        options.maxRulesPerList = 25
        let text = lines.joined(separator: "\n")
        let result = ContentBlocker.compile(lists: [("fuzz", text)], options: options)
        #expect(!result.lists.isEmpty)
        for list in result.lists {
            #expect(list.ruleCount <= 25)
            let problems = RuleListValidator.validate(json: list.json)
            #expect(problems.isEmpty, "\(list.name): \(problems.prefix(5))")
        }
        let r = result.report
        #expect(r.parsed == r.compiled + r.skippedTotal, "every recognised filter line must be compiled or counted as skipped")
        #expect(r.lines == lines.count)
    }

    @Test func randomBytesNeverCrashTheParser() {
        var rng = SplitMix64(state: 7)
        for _ in 0..<2000 {
            let length = Int.random(in: 0..<80, using: &rng)
            let scalars = (0..<length).compactMap { _ in UnicodeScalar(UInt32.random(in: 0x01...0x2FF, using: &rng)) }
            let line = String(String.UnicodeScalarView(scalars))
            _ = FilterParser.parseLine(line)
            _ = ContentBlocker.compile(name: "r", text: line)
        }
    }
}
