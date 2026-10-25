import Foundation
import Testing
import CosmosCore
@testable import CosmosImport

@Suite struct FirefoxImporterTests {
    typealias F = FirefoxFixture
    let now = browserDate(1_750_000_000)

    func options(history: Bool = true, bookmarks: Bool = true, since: Date? = nil, limit: Int? = nil, work: URL? = nil) -> BrowserImportOptions {
        BrowserImportOptions(history: history, bookmarks: bookmarks, since: since, limit: limit, workDirectory: work, now: now)
    }

    func standardPlaces() -> [F.Place] {
        let m = { (s: Int64, us: Int64) in BrowserEpoch.firefoxMicros(unix: s, micros: us) }
        return [
            F.Place(url: "https://mozilla.org/", title: "Mozilla", visitCount: 4, typed: 1, lastVisit: m(1_700_000_000, 123_456),
                    visits: [(m(1_699_999_000, 0), 1), (m(1_699_999_500, 0), 2), (m(1_700_000_000, 123_456), 2)]),
            F.Place(url: "http://Example.org/page#section", title: nil, visitCount: 1, lastVisit: m(1_700_000_900, 0), visits: [(m(1_700_000_900, 0), 1)]),
            F.Place(url: "https://bookmark-only.example/", title: "Never visited", visitCount: 0, lastVisit: nil),
            F.Place(url: "place:type=6&sort=14&maxResults=10", title: "Recent Tags", visitCount: 1, lastVisit: m(1_700_000_100, 0)),
            F.Place(url: "about:newtab", visitCount: 1, lastVisit: m(1_700_000_100, 0)),
            F.Place(url: "moz-extension://abc/options.html", visitCount: 1, lastVisit: m(1_700_000_100, 0)),
            F.Place(url: "file:///Users/someone/a.html", visitCount: 1, lastVisit: m(1_700_000_100, 0)),
            F.Place(url: "https://hidden.example/redirect", title: "Redirect source", visitCount: 1, hidden: 1, lastVisit: m(1_700_000_100, 0)),
            F.Place(url: "https://future.example/", title: "Future", visitCount: 1, lastVisit: m(4_000_000_000, 0)),
        ]
    }

    func makeProfile(_ tmp: BrowserTempDir, places: [F.Place]? = nil, bookmarks: [F.BookmarkRow] = []) throws -> URL {
        let dir = try tmp.makeDirectory("Profiles/abcd1234.default-release")
        _ = try F.create(at: dir.appendingPathComponent("places.sqlite"), places: places ?? standardPlaces(), bookmarks: bookmarks)
        return dir
    }

    @Test func readsHistoryWithExactMicrosecondDates() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let read = try FirefoxImporter.readHistory(profileDirectory: try makeProfile(tmp), options: options())
        let moz = try #require(read.entries.first { $0.url.host == "mozilla.org" })
        #expect(moz.title == "Mozilla")
        #expect(moz.visitCount == 4)
        #expect(moz.typedCount == 2)                              // two visits of type TRANSITION_TYPED beat the 0/1 flag
        #expect(abs(moz.lastVisit.timeIntervalSince1970 - 1_700_000_000.123456) < 1e-6)
        #expect(moz.firstVisit == browserDate(1_699_999_000))
    }

    @Test func filtersPlaceURIsInternalPagesHiddenAndUnvisitedRows() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let read = try FirefoxImporter.readHistory(profileDirectory: try makeProfile(tmp), options: options())
        // Fragments and host case are normalised; a NULL title becomes "".
        #expect(Set(read.entries.map(\.url.absoluteString)) == ["https://mozilla.org/", "http://example.org/page", "https://future.example/"])
        #expect(read.entries.first { $0.url.host == "example.org" }?.title == "")
        #expect(read.entries.first { $0.url.host == "future.example" }?.lastVisit == now)
        #expect(read.entries.map(\.lastVisit) == read.entries.map(\.lastVisit).sorted(by: >))
    }

    @Test func sinceAndLimit() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let profile = try makeProfile(tmp)
        let since = try FirefoxImporter.readHistory(profileDirectory: profile, options: options(since: browserDate(1_700_000_500)))
        #expect(Set(since.entries.map(\.url.host)) == ["example.org", "future.example"])
        let limited = try FirefoxImporter.readHistory(profileDirectory: profile, options: options(limit: 1))
        #expect(limited.entries.map(\.url.host) == ["future.example"])
    }

    @Test func bookmarkTreeSkipsTagsPlaceQueriesAndSeparators() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let places = [
            F.Place(url: "https://mozilla.org/", title: "Mozilla", lastVisit: nil),                // id 1
            F.Place(url: "https://docs.example/", title: "Docs place title", lastVisit: nil),      // id 2
            F.Place(url: "place:parent=toolbar_____&queryType=1", title: "Smart", lastVisit: nil), // id 3
            F.Place(url: "https://menu.example/", title: "Menu item", lastVisit: nil),             // id 4
            F.Place(url: "javascript:void(0)", title: "Bookmarklet", lastVisit: nil),              // id 5
        ]
        let added = BrowserEpoch.firefoxMicros(unix: 1_700_000_000)
        let bookmarks = F.roots + [
            .init(id: 10, type: 1, fk: 1, parent: 3, position: 0, title: "Mozilla", dateAdded: added, guid: "bm10"),
            .init(id: 11, type: 2, fk: nil, parent: 3, position: 1, title: "Dev", dateAdded: added, guid: "fo11"),
            .init(id: 12, type: 1, fk: 2, parent: 11, position: 0, title: nil, dateAdded: added, guid: "bm12"),   // falls back to the place title
            .init(id: 13, type: 3, fk: nil, parent: 3, position: 2, title: nil, guid: "sep13"),
            .init(id: 14, type: 1, fk: 3, parent: 3, position: 3, title: "Smart", guid: "bm14"),
            .init(id: 15, type: 1, fk: 4, parent: 2, position: 0, title: "Menu item", guid: "bm15"),
            .init(id: 16, type: 1, fk: 5, parent: 3, position: 4, title: "Bookmarklet", guid: "bm16"),
            // tags live under the tags root as folders of bookmark rows pointing at the same places
            .init(id: 20, type: 2, fk: nil, parent: 4, position: 0, title: "work", guid: "tag20"),
            .init(id: 21, type: 1, fk: 1, parent: 20, position: 0, title: nil, guid: "tag21"),
        ]
        let read = try FirefoxImporter.readBookmarks(profileDirectory: try makeProfile(tmp, places: places, bookmarks: bookmarks))

        #expect(read.nodes.map(\.title) == ["Bookmarks Menu", "Bookmarks Toolbar"])   // empty unfiled/mobile and tags are left out
        #expect(read.skipped == 2)                                                      // the place: query and the bookmarklet
        let toolbar = read.nodes[1]
        #expect(toolbar.children.map(\.title) == ["Mozilla", "Dev"])
        #expect(toolbar.children[0].dateAdded == browserDate(1_700_000_000))
        #expect(toolbar.children[1].children.map(\.title) == ["Docs place title"])
        #expect(read.nodes[0].children.map(\.title) == ["Menu item"])
        #expect(read.nodes.bookmarkCount == 3)
    }

    @Test func readsHistoryAndBookmarksFromOneSnapshot() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let bookmarks = F.roots + [.init(id: 10, type: 1, fk: 1, parent: 3, position: 0, title: "Mozilla", guid: "bm10")]
        let profile = try makeProfile(tmp, bookmarks: bookmarks)
        let both = try FirefoxImporter.read(profileDirectory: profile, options: options())
        #expect(both.history?.entries.count == 3)
        #expect(both.bookmarks?.nodes.bookmarkCount == 1)
        let onlyHistory = try FirefoxImporter.read(profileDirectory: profile, options: options(bookmarks: false))
        #expect(onlyHistory.bookmarks == nil)
    }

    @Test func readsRowsStillInTheWALWhileFirefoxHoldsTheWriteLock() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let dir = try tmp.makeDirectory("Profiles/abcd1234.default-release")
        let firefox = try F.create(at: dir.appendingPathComponent("places.sqlite"), places: standardPlaces())   // WAL mode, stays open
        try firefox.execute("PRAGMA wal_autocheckpoint=0")
        try firefox.run("""
            INSERT INTO moz_places (id, url, title, visit_count, last_visit_date, guid) VALUES (500, 'https://wal-only.example/', 'In the WAL', 3, ?, 'walonly')
            """, [.int(BrowserEpoch.firefoxMicros(unix: 1_700_005_000))])
        try firefox.execute("BEGIN IMMEDIATE")
        defer { try? firefox.execute("ROLLBACK") }

        let wal = dir.appendingPathComponent("places.sqlite-wal")
        let walSize = (try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? UInt64) ?? 0
        try #require(walSize > 0, "the new row should only be in the WAL")
        let namesBefore = tmp.names(in: "Profiles/abcd1234.default-release")
        let work = try tmp.makeDirectory("work")

        let read = try FirefoxImporter.readHistory(profileDirectory: dir, options: options(work: work))
        let walOnly = try #require(read.entries.first { $0.url.host == "wal-only.example" })
        #expect(walOnly.title == "In the WAL")
        #expect(walOnly.visitCount == 3)
        #expect(tmp.names(in: "Profiles/abcd1234.default-release") == namesBefore)
        #expect(tmp.names(in: "work").isEmpty)
    }

    @Test func missingPlacesFileIsATypedError() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let dir = try tmp.makeDirectory("Profiles/x.default")
        #expect(throws: BrowserImportError.fileNotFound(path: dir.appendingPathComponent("places.sqlite").path)) {
            try FirefoxImporter.readHistory(profileDirectory: dir, options: options())
        }
    }
}
