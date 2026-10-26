import Foundation
import Testing
@testable import CosmosCore

@Suite struct LinkRuleHostTests {
    @Test(arguments: [
        ("github.com", "github.com"),
        ("  GitHub.com  ", "github.com"),
        ("https://github.com/anthropics/claude-code?tab=readme#top", "github.com"),
        ("http://www.example.org", "example.org"),
        ("www.nytimes.com/section/world", "nytimes.com"),
        ("user:pass@host.example:8080/path", "host.example"),
        ("localhost", "localhost"),
        ("192.168.1.10:3000", "192.168.1.10"),
        ("münchen.de", "münchen.de"),
        ("docs.example.co.uk.", "docs.example.co.uk"),
    ] as [(String, String)]) func anAddressBecomesTheHostItMatches(input: String, host: String) {
        #expect(LinkRule.normalizedHost(input) == host)
    }

    @Test(arguments: ["", "   ", "two words.com", "http://", "/just/a/path", "a..b", "-bad.com", "bad-.com", ".", "https://:80", "exa mple.com/x"])
    func somethingThatIsNotAHostIsRefused(input: String) {
        #expect(LinkRule.normalizedHost(input) == nil)
    }

    @Test func theNormalisedHostMatchesTheLinksItWasTypedFor() throws {
        let host = try #require(LinkRule.normalizedHost("https://www.GitHub.com/anthropics"))
        let rule = LinkRule(matches: [.host(host)], destination: .mostRecentSpace)
        #expect(rule.applies(to: URL(string: "https://github.com/x")!))
        #expect(rule.applies(to: URL(string: "https://gist.github.com/x")!))
        #expect(!rule.applies(to: URL(string: "https://notgithub.com/x")!))
    }

    @Test func aHugeInputIsRefusedQuickly() {
        #expect(LinkRule.normalizedHost(String(repeating: "a", count: 100_000)) == nil)
        #expect(LinkRule.normalizedHost(String(repeating: "a.", count: 5_000) + "com") == nil)
    }
}
