import Foundation
import Testing
@testable import CosmosBlocking

/// Sites that spread malware or phish, from public lists: Cosmos warns before a page from one opens (its stand-in for
/// Safe Browsing, which needs Google's keys).
@Suite struct DangerousSitesTests {
    @Test func hostsListsAreRead() {
        let text = """
        # Title: Online Malicious Hosts Blocklist
        0.0.0.0 bad.example
        127.0.0.1 Worse.Example
        ||filter.example^
        plain.example
        ! a comment
        0.0.0.0 0.0.0.0
        not a host at all
        """
        let sites = DangerousSites.parse(text, reason: .malware)
        #expect(sites.count == 4)
        #expect(sites.reason(for: URL(string: "https://bad.example/download")!) == .malware)
        #expect(sites.reason(for: URL(string: "http://worse.example/")!) == .malware, "hosts are matched without case")
        #expect(sites.reason(for: URL(string: "https://filter.example/")!) == .malware)
        #expect(sites.reason(for: URL(string: "https://plain.example/")!) == .malware)
        #expect(sites.reason(for: URL(string: "https://good.example/")!) == nil)
    }

    /// A listed site's subdomains are the same site; the domain above a listed subdomain is not.
    @Test func subdomainsOfAListedSiteAreListedButNotTheOtherWayRound() {
        let sites = DangerousSites.parse("0.0.0.0 phish.example\n0.0.0.0 evil.weebly.com", reason: .phishing)
        #expect(sites.reason(for: URL(string: "https://login.phish.example/")!) == .phishing)
        #expect(sites.reason(for: URL(string: "https://evil.weebly.com/")!) == .phishing)
        #expect(sites.reason(for: URL(string: "https://weebly.com/")!) == nil)
        #expect(sites.reason(for: URL(string: "https://other.weebly.com/")!) == nil)
        #expect(sites.reason(for: URL(string: "about:blank")!) == nil)
    }

    @Test func listsAreDownloadedTwiceADayAndKeptWhenTheNetworkFails() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-danger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = DangerousSiteLists.catalog.map(\.url.lastPathComponent)
        let fetcher = FakeFetcher([names[0]: .body("0.0.0.0 malware.example", etag: "a"), names[1]: .body("0.0.0.0 phish.example", etag: "b")])
        let clock = TestClock()
        let lists = DangerousSiteLists(directory: dir, fetcher: fetcher, now: clock.now)
        #expect(await lists.cached().count == 0, "nothing until something is downloaded")

        let sites = await lists.refresh()
        #expect(sites.reason(for: URL(string: "https://malware.example/")!) == .malware)
        #expect(sites.reason(for: URL(string: "https://phish.example/")!) == .phishing)
        #expect(fetcher.calls.count == 2)

        clock.advance(hours: 6)
        _ = await lists.refresh()
        #expect(fetcher.calls.count == 2, "not before twelve hours")

        clock.advance(hours: 7)
        fetcher.setAll(.fail)
        let offline = await lists.refresh()
        #expect(fetcher.calls.count == 4)
        #expect(fetcher.calls.last?.etag != nil, "asked whether it changed")
        #expect(offline.count == 2, "what was there is kept")
        #expect(await DangerousSiteLists(directory: dir, fetcher: fetcher, now: clock.now).cached().count == 2, "and is there after a restart")
    }
}
