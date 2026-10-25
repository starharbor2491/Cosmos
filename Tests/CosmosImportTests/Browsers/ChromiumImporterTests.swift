import Foundation
import Testing
import CosmosCore
@testable import CosmosImport

@Suite struct ChromiumHistoryTests {
    let now = browserDate(1_750_000_000)

    func options(history: Bool = true, bookmarks: Bool = true, since: Date? = nil, limit: Int? = nil, work: URL? = nil) -> BrowserImportOptions {
        BrowserImportOptions(history: history, bookmarks: bookmarks, since: since, limit: limit, workDirectory: work, now: now)
    }

    func standardRows() -> [ChromiumRow] {
        let t = { (s: Int64) in BrowserEpoch.chromiumMicros(unix: s) }
        return [
            ChromiumRow(url: "https://example.com/a", title: "Example A", visitCount: 5, typedCount: 2, lastVisit: t(1_700_000_500),
                        visits: [t(1_700_000_300), t(1_700_000_000), t(1_700_000_500)]),
            ChromiumRow(url: "http://Example.com/b#frag", title: "B old", visitCount: 3, typedCount: 1, lastVisit: t(1_700_001_000)),
            ChromiumRow(url: "http://example.com/b", title: "B newer", visitCount: 2, lastVisit: BrowserEpoch.chromiumMicros(unix: 1_700_002_000, micros: 654_321)),
            ChromiumRow(url: "chrome://settings", title: "Settings", lastVisit: t(1_700_000_100)),
            ChromiumRow(url: "about:blank", lastVisit: t(1_700_000_100)),
            ChromiumRow(url: "chrome-extension://abcdef/page.html", lastVisit: t(1_700_000_100)),
            ChromiumRow(url: "file:///Users/someone/doc.html", lastVisit: t(1_700_000_100)),
            ChromiumRow(url: "javascript:void(0)", lastVisit: t(1_700_000_100)),
            ChromiumRow(url: "", lastVisit: t(1_700_000_100)),
            ChromiumRow(url: "https://ads.example.net/frame", title: "Ad frame", lastVisit: t(1_700_000_100), hidden: 1),
            ChromiumRow(url: "https://never.example/", title: "Never visited", visitCount: 0, lastVisit: 0),
            ChromiumRow(url: "https://future.example/", title: "Clock skew", lastVisit: t(2_500_000_000)),
            ChromiumRow(url: "https://ancient.example/", title: "Garbage date", lastVisit: t(315_532_800)),
        ]
    }

    func makeProfile(_ tmp: BrowserTempDir, rows: [ChromiumRow]? = nil) throws -> URL {
        try ChromiumFixture.makeProfile(at: tmp.sub("Default", isDirectory: true), rows: rows ?? standardRows())
    }

    @Test func readsFieldsWithExactTimestamps() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let read = try ChromiumImporter.readHistory(profileDirectory: try makeProfile(tmp), options: options())
        let a = try #require(read.entries.first { $0.url.absoluteString == "https://example.com/a" })
        #expect(a.title == "Example A")
        #expect(a.visitCount == 5)
        #expect(a.typedCount == 2)
        #expect(a.lastVisit == browserDate(1_700_000_500))
        #expect(a.firstVisit == browserDate(1_700_000_000))   // MIN(visits.visit_time), not last_visit_time
    }

    @Test func keepsOnlyWebPagesAndDropsGarbage() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let read = try ChromiumImporter.readHistory(profileDirectory: try makeProfile(tmp), options: options())
        let urls = Set(read.entries.map(\.url.absoluteString))
        #expect(urls == ["https://example.com/a", "http://example.com/b", "https://future.example/"])
        for e in read.entries { #expect(["http", "https"].contains(e.url.scheme)) }
        // chrome://, about:, extension, file:, javascript:, empty and hidden frames never reach Swift; the 1980 date does and is skipped
        #expect(read.rowsSkipped == 1)
    }

    @Test func mergesPagesThatDifferOnlyByFragmentAndHostCase() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let read = try ChromiumImporter.readHistory(profileDirectory: try makeProfile(tmp), options: options())
        let b = try #require(read.entries.first { $0.url.absoluteString == "http://example.com/b" })
        #expect(b.visitCount == 5)            // 3 + 2
        #expect(b.typedCount == 1)
        #expect(b.title == "B newer")         // title of the most recent visit
        #expect(b.firstVisit == browserDate(1_700_001_000))
        #expect(abs(b.lastVisit.timeIntervalSince1970 - 1_700_002_000.654321) < 1e-6)
        #expect(read.rowsMerged == 1)
        #expect(read.entries.filter { $0.url.host == "example.com" && $0.url.path == "/b" }.count == 1)
    }

    @Test func clampsFutureDatesAndSortsNewestFirst() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let read = try ChromiumImporter.readHistory(profileDirectory: try makeProfile(tmp), options: options())
        let future = try #require(read.entries.first { $0.url.host == "future.example" })
        #expect(future.lastVisit == now)
        #expect(future.firstVisit <= future.lastVisit)
        #expect(read.entries.map(\.lastVisit) == read.entries.map(\.lastVisit).sorted(by: >))
        #expect(read.entries.first?.url.host == "future.example")
    }

    @Test func sinceAndLimit() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let profile = try makeProfile(tmp)
        let since = try ChromiumImporter.readHistory(profileDirectory: profile, options: options(since: browserDate(1_700_001_500)))
        #expect(Set(since.entries.map(\.url.host)) == ["example.com", "future.example"])
        #expect(since.entries.allSatisfy { $0.lastVisit >= browserDate(1_700_001_500) })
        let limited = try ChromiumImporter.readHistory(profileDirectory: profile, options: options(limit: 2))
        #expect(limited.entries.map(\.url.host) == ["future.example", "example.com"])
        let none = try ChromiumImporter.readHistory(profileDirectory: profile, options: options(limit: 0))
        #expect(none.entries.isEmpty)
    }

    @Test func worksWithoutAVisitsTable() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let dir = try tmp.makeDirectory("Default")
        try ChromiumFixture.makeHistory(at: dir.appendingPathComponent("History"), rows: standardRows(), withVisitsTable: false)
        let read = try ChromiumImporter.readHistory(profileDirectory: dir, options: options())
        let a = try #require(read.entries.first { $0.url.absoluteString == "https://example.com/a" })
        #expect(a.firstVisit == a.lastVisit)
    }

    @Test func pagesThroughLargeHistories() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let rows = (0..<12_345).map { ChromiumRow(url: "https://site\($0).example/", title: "T\($0)", lastVisit: BrowserEpoch.chromiumMicros(unix: 1_600_000_000 + Int64($0))) }
        let read = try ChromiumImporter.readHistory(profileDirectory: try makeProfile(tmp, rows: rows), options: options())
        #expect(read.entries.count == 12_345)
        #expect(read.rowsRead == 12_345)
        #expect(read.entries.first?.url.host == "site12344.example")
    }

    // MARK: Never touching the original

    func listing(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

    @Test func readsWhileTheBrowserHoldsAnExclusiveLock() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let profile = try makeProfile(tmp)
        let history = profile.appendingPathComponent("History")

        let browser = try SQLiteDatabase(path: history.path)    // plays the running browser
        try browser.execute("BEGIN EXCLUSIVE")
        defer { try? browser.execute("ROLLBACK") }

        let bytesBefore = try Data(contentsOf: history)
        let namesBefore = listing(profile)
        let work = try tmp.makeDirectory("work")
        let read = try ChromiumImporter.readHistory(profileDirectory: profile, options: options(work: work))

        #expect(read.entries.count == 3)
        #expect(try Data(contentsOf: history) == bytesBefore)   // original untouched
        #expect(listing(profile) == namesBefore)                // no -wal/-shm/-journal created beside it
        #expect(tmp.names(in: "work").isEmpty)                  // temporary copy deleted
    }

    @Test func recoversFromAHotRollbackJournalOnTheCopyOnly() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let rows = (0..<3000).map {
            ChromiumRow(url: "https://page\($0).example/", title: "original title \($0) " + String(repeating: "x", count: 200),
                        lastVisit: BrowserEpoch.chromiumMicros(unix: 1_700_000_000 + Int64($0)))
        }
        let profile = try makeProfile(tmp, rows: rows)
        let history = profile.appendingPathComponent("History")

        // The browser is mid-transaction with a tiny page cache that must spill: dirty pages are written into the
        // database file after the originals went into the journal, so the file on disk is half-written.
        let committed = try Data(contentsOf: history)
        let browser = try SQLiteDatabase(path: history.path)
        try browser.execute("PRAGMA cache_size=8")
        try browser.execute("PRAGMA cache_spill=1")
        try browser.execute("BEGIN")
        try browser.execute("UPDATE urls SET title = 'HALF-WRITTEN ' || id || '" + String(repeating: "y", count: 200) + "'")
        defer { try? browser.execute("ROLLBACK") }
        let journal = try Data(contentsOf: URL(fileURLWithPath: history.path + "-journal"))
        try #require((journal.first ?? 0) != 0, "the journal header is only valid (hot) once pages were written to the database")
        try #require(try Data(contentsOf: history) != committed, "the fixture should have spilled dirty pages into the file")

        let work = try tmp.makeDirectory("work")
        let read = try ChromiumImporter.readHistory(profileDirectory: profile, options: options(work: work))
        #expect(read.entries.count == 3000)
        #expect(read.entries.allSatisfy { $0.title.hasPrefix("original title") })
        #expect(tmp.names(in: "work").isEmpty)
    }

    @Test func removesItsCopyEvenWhenTheDatabaseIsCorrupt() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let dir = try tmp.makeDirectory("Default")
        try Data(repeating: 0x41, count: 8192).write(to: dir.appendingPathComponent("History"))
        let work = try tmp.makeDirectory("work")
        do {
            _ = try ChromiumImporter.readHistory(profileDirectory: dir, options: options(work: work))
            Issue.record("expected an error")
        } catch let error as BrowserImportError {
            guard case .unreadable(let path, _) = error else { Issue.record("wrong error \(error)"); return }
            #expect(path == dir.appendingPathComponent("History").path)
        }
        #expect(tmp.names(in: "work").isEmpty)
    }

    @Test func missingAndUnreadableFilesThrowTypedErrors() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let dir = try tmp.makeDirectory("Default")
        let history = dir.appendingPathComponent("History")
        #expect(throws: BrowserImportError.fileNotFound(path: history.path)) { try ChromiumImporter.readHistory(profileDirectory: dir, options: options()) }
        try ChromiumFixture.makeHistory(at: history, rows: standardRows())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: history.path)
        #expect(throws: BrowserImportError.permissionDenied(path: history.path)) { try ChromiumImporter.readHistory(profileDirectory: dir, options: options()) }
    }
}

@Suite struct ChromiumBookmarksTests {
    typealias F = ChromiumFixture

    @Test func parsesRootsFoldersAndDates() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let added = "\(BrowserEpoch.chromiumMicros(unix: 1_700_000_000))"
        try F.makeBookmarks(
            at: tmp.sub("Bookmarks"),
            bar: [
                F.bookmark("First", "https://first.example/", added: added),
                F.folder("Dev", [
                    F.bookmark("Docs", "https://docs.example/a?b=c#d"),
                    F.folder("Deep", [F.bookmark("Leaf", "http://leaf.example/")], added: added),
                ]),
                F.bookmark("Bookmarklet", "javascript:alert(1)"),
                F.bookmark("Settings", "chrome://settings"),
                F.bookmark("Last", "https://last.example/", added: Int64(BrowserEpoch.chromiumMicros(unix: 1_700_000_100))),
            ],
            other: [F.bookmark("Other one", "https://other.example/")])
        let read = try ChromiumImporter.readBookmarks(profileDirectory: tmp.url, now: browserDate(1_750_000_000))

        #expect(read.nodes.map(\.title) == ["Bookmarks Bar", "Other Bookmarks"])     // empty "synced" root is left out
        let bar = read.nodes[0]
        #expect(bar.children.map(\.title) == ["First", "Dev", "Last"])                // order kept; non-web bookmarks dropped
        #expect(read.skipped == 2)
        #expect(bar.children[0].url?.absoluteString == "https://first.example/")
        #expect(bar.children[0].dateAdded == browserDate(1_700_000_000))
        #expect(bar.children[1].dateAdded == nil)                                      // "0" means unknown
        #expect(bar.children[2].dateAdded == browserDate(1_700_000_100))                      // numeric date_added also accepted
        let dev = bar.children[1]
        #expect(dev.isFolder)
        #expect(dev.children.map(\.title) == ["Docs", "Deep"])
        #expect(dev.children[0].url?.absoluteString == "https://docs.example/a?b=c#d")   // fragments are kept for bookmarks
        #expect(dev.children[1].dateAdded == browserDate(1_700_000_000))
        #expect(dev.children[1].children.first?.url?.scheme == "http")
        #expect(read.nodes.bookmarkCount == 5)
        #expect(read.nodes.folderCount == 4)
    }

    @Test func mobileBookmarksComeFromTheSyncedRoot() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        try F.makeBookmarks(at: tmp.sub("Bookmarks"), synced: [F.bookmark("Phone", "https://phone.example/")])
        let read = try ChromiumImporter.readBookmarks(profileDirectory: tmp.url)
        #expect(read.nodes.map(\.title) == ["Mobile Bookmarks"])
    }

    @Test func emptyProfileGivesNoNodes() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        try F.makeBookmarks(at: tmp.sub("Bookmarks"))
        let read = try ChromiumImporter.readBookmarks(profileDirectory: tmp.url)
        #expect(read.nodes.isEmpty)
        #expect(read.skipped == 0)
    }

    @Test func badFilesThrowTypedErrors() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let file = tmp.sub("Bookmarks")
        #expect(throws: BrowserImportError.fileNotFound(path: file.path)) { try ChromiumImporter.readBookmarks(profileDirectory: tmp.url) }
        try "{ not json".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: BrowserImportError.self) { try ChromiumImporter.readBookmarks(profileDirectory: tmp.url) }
        try "{\"version\": 1}".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: BrowserImportError.self) { try ChromiumImporter.readBookmarks(profileDirectory: tmp.url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        #expect(throws: BrowserImportError.permissionDenied(path: file.path)) { try ChromiumImporter.readBookmarks(profileDirectory: tmp.url) }
    }
}
