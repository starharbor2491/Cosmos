import Foundation
import Testing
import CosmosCore
@testable import CosmosImport

@Suite struct HistoryCollectorTests {
    @Test func lowercasesSchemeAndHostDropsFragmentsAndKeepsTheRest() {
        let cases: [(String, String)] = [
            ("HTTPS://Example.COM/Path?Q=1#frag", "https://example.com/Path?Q=1"),
            ("http://[::1]:3000/x#a", "http://[::1]:3000/x"),
            ("http://localhost:3000/a b?q=1#h", "http://localhost:3000/a%20b?q=1"),
            ("https://münchen.de/straße", "https://xn--mnchen-3ya.de/stra%C3%9Fe"),
            ("https://example.com:8080/a//b/../c", "https://example.com:8080/a//b/../c"),
            ("  https://example.com/?a=b&c=d%20e#  ", "https://example.com/?a=b&c=d%20e"),
        ]
        for (raw, expected) in cases { #expect(HistoryCollector.normalized(raw)?.absoluteString == expected, "\(raw)") }
    }

    @Test func rejectsNonWebAndMalformedURLs() {
        let rejected = ["", "   ", "about:blank", "chrome://history", "chrome-extension://abc/x.html", "file:///tmp/a.html", "data:text/html,hi",
                        "javascript:alert(1)", "view-source:https://example.com", "place:type=6", "ftp://example.com/", "http://", "http:///x", "https://exa mple.com/"]
        for raw in rejected { #expect(HistoryCollector.normalized(raw) == nil, "\(raw)") }
        #expect(HistoryCollector.normalized(nil) == nil)
    }

    @Test func fallsBackToTheFirstVisitWhenTheLastIsUnusableAndFixesInvertedRanges() throws {
        var c = HistoryCollector(now: browserDate(1_750_000_000))
        c.add(url: "https://a.example/", title: " A ", visitCount: 0, typedCount: -3, firstVisit: browserDate(1_700_000_000), lastVisit: browserDate(100))
        c.add(url: "https://b.example/", title: "B", visitCount: 2, typedCount: 0, firstVisit: browserDate(1_700_000_900), lastVisit: browserDate(1_700_000_100))
        c.add(url: "https://c.example/", title: "C", visitCount: 2, typedCount: 0, firstVisit: nil, lastVisit: nil)
        let read = c.result(limit: nil)
        #expect(read.rowsRead == 3)
        #expect(read.rowsSkipped == 1)
        let a = try #require(read.entries.first { $0.url.host == "a.example" })
        #expect(a.title == "A")
        #expect(a.visitCount == 1)       // at least one visit: the row exists
        #expect(a.typedCount == 0)
        #expect(a.lastVisit == browserDate(1_700_000_000))
        let b = try #require(read.entries.first { $0.url.host == "b.example" })
        #expect(b.firstVisit == b.lastVisit)   // never "first after last"
    }

    @Test func mergeKeepsTheLongestHistoryAndTheNewestNonEmptyTitle() throws {
        var c = HistoryCollector(now: browserDate(1_750_000_000))
        c.add(url: "https://a.example/p#1", title: "Old", visitCount: 2, typedCount: 1, firstVisit: browserDate(1_600_000_000), lastVisit: browserDate(1_650_000_000))
        c.add(url: "https://a.example/p#2", title: "", visitCount: 3, typedCount: 0, firstVisit: browserDate(1_640_000_000), lastVisit: browserDate(1_700_000_000))
        c.add(url: "https://A.example/p", title: "Mid", visitCount: 1, typedCount: 0, firstVisit: browserDate(1_610_000_000), lastVisit: browserDate(1_660_000_000))
        let read = c.result(limit: nil)
        let e = try #require(read.entries.first)
        #expect(read.entries.count == 1)
        #expect(read.rowsMerged == 2)
        #expect(e.visitCount == 6)
        #expect(e.typedCount == 1)
        #expect(e.firstVisit == browserDate(1_600_000_000))
        #expect(e.lastVisit == browserDate(1_700_000_000))
        #expect(e.title == "Mid")      // the newest visit had no title; the newest one that did is kept, never blanked
    }
}
