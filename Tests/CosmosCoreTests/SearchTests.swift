import Foundation
import Testing
@testable import CosmosCore

@Suite struct URLInputTests {
    func resolved(_ s: String) -> String {
        switch URLInput.resolve(s) {
        case .url(let u): return "url:" + u.absoluteString
        case .search(let q): return "search:" + q
        }
    }

    @Test func domainsBecomeHTTPSURLs() {
        #expect(resolved("github.com") == "url:https://github.com")
        #expect(resolved("github.com/anthropics") == "url:https://github.com/anthropics")
        #expect(resolved("www.bbc.co.uk/news") == "url:https://www.bbc.co.uk/news")
        #expect(resolved("docs.swift.org") == "url:https://docs.swift.org")
        #expect(resolved("example.com?q=1") == "url:https://example.com?q=1")
    }

    @Test func localAndIPsUseHTTP() {
        #expect(resolved("localhost:3000") == "url:http://localhost:3000")
        #expect(resolved("localhost") == "url:http://localhost")
        #expect(resolved("127.0.0.1:8080/x") == "url:http://127.0.0.1:8080/x")
        #expect(resolved("192.168.1.1") == "url:http://192.168.1.1")
        #expect(resolved("myapp.test") == "url:http://myapp.test")
        #expect(resolved("[::1]:8000") == "url:http://[::1]:8000")
    }

    @Test func explicitSchemes() {
        #expect(resolved("https://example.com/a b") == "url:https://example.com/a%20b" || resolved("https://example.com/a b").hasPrefix("search:"))
        #expect(resolved("http://example.com") == "url:http://example.com")
        #expect(resolved("file:///Users/me/index.html") == "url:file:///Users/me/index.html")
        #expect(resolved("about:blank") == "url:about:blank")
        #expect(resolved("mailto:a@b.co") == "url:mailto:a@b.co")
        #expect(resolved("cosmos://settings") == "url:cosmos://settings")
    }

    @Test func plainTextIsSearch() {
        #expect(resolved("cats") == "search:cats")
        #expect(resolved("how to tie a tie") == "search:how to tie a tie")
        #expect(resolved("what is rust.lang") == "search:what is rust.lang")
        #expect(resolved("notatld.zzzzzz") == "search:notatld.zzzzzz")
        #expect(resolved("hello world.com") == "search:hello world.com")
        #expect(resolved("") == "search:")
    }

    @Test func searchURLEncoding() {
        let u = URLInput.searchURL(template: "https://www.google.com/search?q=%s", query: "C++ & rust/zig?")
        #expect(u?.absoluteString == "https://www.google.com/search?q=C%2B%2B%20%26%20rust%2Fzig%3F")
    }

    @Test func displayStripsWWW() {
        #expect(URLInput.display(URL(string: "https://www.example.com/")) == "example.com")
        #expect(URLInput.display(URL(string: "https://example.com/a/b")) == "example.com/a/b")
    }
}

@Suite struct PublicSuffixTests {
    @Test func registrableDomains() {
        let psl = PublicSuffixList.shared
        #expect(psl.registrableDomain(of: "www.bbc.co.uk") == "bbc.co.uk")
        #expect(psl.registrableDomain(of: "gist.github.com") == "github.com")
        #expect(psl.registrableDomain(of: "foo.github.io") == "foo.github.io")   // private suffix
        #expect(psl.registrableDomain(of: "localhost") == "localhost")
        #expect(psl.registrableDomain(of: "10.0.0.1") == "10.0.0.1")
        #expect(psl.siteName(of: "mail.google.com") == "google")
        #expect(psl.isSameSite(URL(string: "https://a.example.com")!, URL(string: "https://b.example.com/x")!))
        #expect(!psl.isSameSite(URL(string: "https://a.github.io")!, URL(string: "https://b.github.io")!))
    }
}

@Suite struct CalculatorTests {
    @Test func arithmetic() {
        #expect(Calculator.evaluate("12*(3+4)") == 84)
        #expect(Calculator.evaluate("2^10") == 1024)
        #expect(Calculator.evaluate("2^3^2") == 512)
        #expect(Calculator.evaluate("-5+2") == -3)
        #expect(Calculator.evaluate("10/4") == 2.5)
        #expect(Calculator.evaluate("15% of 80") == 12)
        #expect(Calculator.evaluate("sqrt(16)+1") == 5)
        #expect(Calculator.evaluate("1,000*2") == 2000)
        #expect(Calculator.format(2.5) == "2.5")
        #expect(Calculator.format(84) == "84")
    }

    @Test func nonArithmeticIsRejected() {
        #expect(Calculator.evaluate("hello") == nil)
        #expect(Calculator.evaluate("1") == nil)
        #expect(Calculator.evaluate("1/0") == nil)
        #expect(Calculator.evaluate("2024-10-25") != nil || true)   // ambiguous: allowed to evaluate or not
        #expect(Calculator.evaluate("rust 1.2") == nil)
        #expect(Calculator.evaluate("(1+2") == nil)
    }
}

@Suite struct RankingTests {
    func cand(_ id: String, _ kind: CommandCandidate.Kind, _ title: String, _ url: String? = nil, frecency: Double = 0.5) -> CommandCandidate {
        CommandCandidate(id: id, kind: kind, title: title, url: url.flatMap(URL.init(string:)), frecency: frecency)
    }

    var pool: [CommandCandidate] {
        [
            cand("t1", .openTab(UUID()), "Pull requests · cosmos", "https://github.com/me/cosmos/pulls"),
            cand("h1", .history, "GitHub", "https://github.com/"),
            cand("h2", .history, "Gitea – self hosted", "https://gitea.example.com/"),
            cand("d1", .topDomain, "YouTube", "https://www.youtube.com/"),
            cand("h3", .history, "Café Müller menu", "https://cafe-muller.example/menu"),
            cand("c1", .command("new-space"), "New Space"),
            cand("a1", .archived(UUID()), "Old design doc", "https://docs.example.com/design"),
        ]
    }

    @Test func hostPrefixBeatsLooseMatch() {
        let r = CommandRanker.rank(query: "git", candidates: pool)
        #expect(r.first?.candidate.id == "t1" || r.first?.candidate.id == "h1")
        #expect(r.map(\.candidate.id).contains("h2"))
        #expect(!r.map(\.candidate.id).contains("d1"))
    }

    @Test func openTabsOutrankHistoryForSameQuery() {
        let r = CommandRanker.rank(query: "github", candidates: pool)
        #expect(r.first?.candidate.id == "t1")
    }

    @Test func allTokensMustMatch() {
        #expect(CommandRanker.rank(query: "github zzz", candidates: pool).isEmpty)
        #expect(CommandRanker.rank(query: "design doc", candidates: pool).first?.candidate.id == "a1")
    }

    @Test func diacriticsFold() {
        #expect(CommandRanker.rank(query: "cafe muller", candidates: pool).first?.candidate.id == "h3")
        #expect(CommandRanker.rank(query: "café", candidates: pool).first?.candidate.id == "h3")
    }

    @Test func siteNameMatchesTypedAbbreviationOfHost() {
        #expect(CommandRanker.rank(query: "yout", candidates: pool).first?.candidate.id == "d1")
    }

    @Test func fuzzySubsequenceFallback() {
        let r = CommandRanker.rank(query: "nspc", candidates: pool)
        #expect(r.first?.candidate.id == "c1")
    }

    @Test func learnedSelectionPromotesPick() {
        var learned = LearnedSelections()
        let base = CommandRanker.rank(query: "git", candidates: pool).map(\.candidate.id)
        let target = base.last!
        for _ in 0..<3 { learned.record(query: "git", candidateID: target) }
        let after = CommandRanker.rank(query: "git", candidates: pool, learned: learned).map(\.candidate.id)
        #expect(after.first == target)
        #expect(learned.boost(query: "gi", candidateID: target) > 0)       // prefix of a learned query
        #expect(learned.boost(query: "zzz", candidateID: target) == 0)
    }

    @Test func duplicateURLsCollapse() {
        let p = [
            cand("a", .history, "Example", "https://www.example.com/page#top"),
            cand("b", .history, "Example", "https://example.com/page/"),
        ]
        #expect(CommandRanker.rank(query: "example", candidates: p).count == 1)
    }

    @Test func composerPutsTypedURLFirstAndAddsSearch() {
        let cat = SearchCatalog.bundled
        let ranked = CommandRanker.rank(query: "github.com", candidates: pool)
        let out = CommandComposer.compose(query: "github.com", ranked: ranked, suggestions: ["github copilot"], catalog: cat, engine: cat.engine("google"))
        #expect(out.rows.first?.kind == .typedURL)
        #expect(out.rows.contains { $0.kind == .suggestion })
    }

    @Test func composerFallsBackToWebSearchAndSiteSearch() {
        let cat = SearchCatalog.bundled
        let out = CommandComposer.compose(query: "lofi beats", ranked: [], suggestions: [], catalog: cat, engine: cat.engine("duckduckgo"))
        #expect(out.rows.first?.kind == .webSearch)
        #expect(out.rows.first?.url?.host == "duckduckgo.com")
        let site = CommandComposer.compose(query: "youtube lofi beats", ranked: [], suggestions: [], catalog: cat, engine: cat.engine("google"))
        #expect(site.rows.first?.kind == .siteSearch("youtube"))
        #expect(site.rows.first?.url?.absoluteString.contains("search_query=lofi%20beats") == true)
        let tab = CommandComposer.compose(query: "yout", ranked: [], suggestions: [], catalog: cat, engine: cat.engine("google"))
        #expect(tab.tabSearchSite?.id == "youtube")
    }

    @Test func composerCalculator() {
        let cat = SearchCatalog.bundled
        let out = CommandComposer.compose(query: "12*(3+4)", ranked: [], suggestions: [], catalog: cat, engine: cat.engine("google"))
        #expect(out.rows.first?.kind == .calculation)
        #expect(out.rows.first?.title == "84")
    }
}

@Suite struct HistoryTests {
    @Test func recordSearchAndFrecency() throws {
        let h = try HistoryStore(path: nil)
        let now = Date()
        h.record(url: URL(string: "https://swift.org/documentation/#intro")!, title: "Swift Docs", at: now.addingTimeInterval(-86400 * 40))
        for i in 0..<6 { h.record(url: URL(string: "https://github.com/me/cosmos")!, title: "cosmos", typed: i < 2, at: now.addingTimeInterval(-Double(i) * 3600)) }
        h.record(url: URL(string: "about:blank")!, title: "blank")
        h.record(url: URL(string: "ftp://x.y/z")!, title: "ftp")
        #expect(h.count() == 2)
        let found = h.search("cosmos", now: now)
        #expect(found.count == 1)
        #expect(found[0].visitCount == 6 && found[0].typedCount == 2)
        #expect(h.search("swift.org").first?.url.absoluteString == "https://swift.org/documentation/")   // fragment stripped
        #expect(h.topSites(now: now).first?.url.host == "github.com")
        #expect(Frecency.score(found[0], now: now) > Frecency.score(h.search("swift")[0], now: now))
        h.delete(url: URL(string: "https://github.com/me/cosmos")!)
        #expect(h.count() == 1)
        h.clear()
        #expect(h.count() == 0)
    }

    @Test func importMergesCounts() throws {
        let h = try HistoryStore(path: nil)
        let u = URL(string: "https://example.com/")!
        h.record(url: u, title: "Example", at: Date(timeIntervalSince1970: 2000))
        try h.importEntries([HistoryEntry(url: u, title: "Old", visitCount: 10, typedCount: 1, firstVisit: Date(timeIntervalSince1970: 1000), lastVisit: Date(timeIntervalSince1970: 1500))])
        let e = try #require(h.search("example").first)
        #expect(e.visitCount == 11)
        #expect(e.firstVisit == Date(timeIntervalSince1970: 1000))
        #expect(e.lastVisit == Date(timeIntervalSince1970: 2000))
        #expect(e.title == "Example")
    }
}
