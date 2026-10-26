import Foundation
import Testing
@testable import CosmosCore

/// Text that comes from outside (the Command Bar field, a pasted blob, a page's own title) must never crash the
/// browser or hold the main thread for long, whatever it contains.
@Suite struct InputFuzzTests {
    @Test func deeplyNestedArithmeticDoesNotOverflowTheStack() {
        for text in [String(repeating: "(", count: 200_000) + "1" + String(repeating: ")", count: 200_000),
                     String(repeating: "-", count: 500_000) + "1",
                     String(repeating: "sqrt(", count: 100_000) + "4" + String(repeating: ")", count: 100_000),
                     String(repeating: "2^", count: 300_000) + "1"] {
            #expect(Calculator.evaluate(text) == nil)
        }
    }

    @Test func ordinaryArithmeticStillWorksAtASensibleLength() {
        #expect(Calculator.evaluate("12*(3+4)") == 84)
        #expect(Calculator.evaluate("-(-(-(2)))") == -2)
        #expect(Calculator.evaluate("2^2^3") == 256)
        #expect(Calculator.evaluate(String(repeating: "(", count: 30) + "1+1" + String(repeating: ")", count: 30)) == 2)
    }

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

    static let pieces = ["", " ", "  ", "http://", "https://", "file:///", "data:", "javascript:", "about:", "mailto:", "[::1]", "[", "]", ":", ":0", ":99999999999999999999",
                         "..", ".", "-", "@", "/", "?", "#", "%", "%zz", "%00", "\u{0}", "\n", "\t", "é", "e\u{301}", "日本", "🙂", "\u{202E}", "localhost", "example.com",
                         "xn--", "com", "1", "999", "0.0.0.0", "1.2.3.4", "(", ")", "+", "*", "^", "%", "sqrt(", "pi", "e", "x", "of", "×", "÷", "|", "&", "=", "<", ">", "\"", "'"]

    static func randomText(_ rng: inout SplitMix64) -> String {
        (0..<Int.random(in: 0...14, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
    }

    @Test(arguments: Array(1...8) as [UInt64]) func randomTextNeverTrapsAnyParser(seed: UInt64) {
        var rng = SplitMix64(state: seed &* 0xD6E8_FEB8_6659_FD93)
        let hosts = ["youtube.com", "github.com", "mail.google.com", "app.slack.com", "notion.so", "docs.google.com", "example.com"]
        let catalog = SearchCatalog.bundled
        for _ in 0..<4000 {
            let text = Self.randomText(&rng)
            _ = URLInput.resolve(text)
            _ = URLInput.display(URL(string: text))
            _ = URLInput.hostForDisplay(URL(string: text))
            _ = URLInput.isIPAddress(text)
            _ = Calculator.evaluate(text)
            _ = TidyTitles.tidy(title: text, url: URL(string: "https://\(hosts.randomElement(using: &rng)!)/"))
            _ = catalog.siteSearch(matching: text)
            _ = catalog.siteSearchCompletions(for: text)
            for engine in catalog.engines { _ = engine.searchURL(for: text) }
            let candidate = CommandCandidate(id: "x", kind: .history, title: text, url: URL(string: text), keywords: [text])
            _ = CommandRanker.matchScore(CommandRanker.tokens(text), candidate)
            _ = Boost.hostMatches(pattern: text, host: "www.example.com")
            for match in [LinkRule.Match.host(text), .urlContains(text), .urlPrefix(text), .urlSuffix(text)] {
                _ = match.matches(URL(string: "https://www.example.com/a?b=c") ?? URL(fileURLWithPath: "/"))
            }
            _ = LearnedSelections.normalise(text)
        }
    }

    /// A page chooses its own title, and the sidebar tidies it on the main thread every time it changes.
    @Test func aHugeAdversarialTitleIsTidiedQuickly() {
        let hosts = ["youtube.com", "github.com", "mail.google.com", "app.slack.com", "outlook.live.com", "docs.google.com", "example.com"]
        let n = 6000
        let titles = [String(repeating: " | ", count: n), String(repeating: "a - b@c ", count: n), String(repeating: " ", count: n * 5) + "x",
                      String(repeating: "(1) ", count: n), "* " + String(repeating: "x | ", count: n), String(repeating: "- ", count: n * 3) + "@"]
        for host in hosts {
            for title in titles {
                let start = Date()
                _ = TidyTitles.tidy(title: title, url: URL(string: "https://\(host)/"))
                #expect(Date().timeIntervalSince(start) < 1, "\(host): \(title.prefix(8))… took \(Date().timeIntervalSince(start)) s")
            }
        }
    }
}
