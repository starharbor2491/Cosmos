import Foundation
import Testing
import CosmosCore
@testable import CosmosImport

@Suite struct SafariImporterTests {
    typealias F = SafariFixture
    let now = browserDate(1_750_000_000)

    func options(history: Bool = true, bookmarks: Bool = true, since: Date? = nil, limit: Int? = nil, work: URL? = nil) -> BrowserImportOptions {
        BrowserImportOptions(history: history, bookmarks: bookmarks, since: since, limit: limit, workDirectory: work, now: now)
    }

    func standardItems() -> [F.Item] {
        let cd = { (unix: Double) in BrowserEpoch.safariSeconds(unix: unix) }
        return [
            F.Item(url: "https://apple.com/", visitCount: 2, visits: [
                F.Visit(time: cd(1_700_000_000.5), title: "Apple (old title)"), F.Visit(time: cd(1_700_100_000.25), title: "Apple"),
            ]),
            F.Item(url: "http://Example.org/p#x", visitCount: 1, visits: [F.Visit(time: cd(1_700_050_000), title: nil)]),
            F.Item(url: "https://counted.example/", visitCount: 1, visits: [   // item says 1 visit, but three visit rows exist
                F.Visit(time: cd(1_700_000_001), title: ""), F.Visit(time: cd(1_700_000_002), title: ""), F.Visit(time: cd(1_700_000_003), title: "Counted"),
            ]),
            F.Item(url: "https://failed.example/", visitCount: 1, visits: [F.Visit(time: cd(1_700_000_010), title: "Failed", loadSuccessful: false)]),
            F.Item(url: "file:///Users/someone/a.html", visitCount: 1, visits: [F.Visit(time: cd(1_700_000_020), title: "Local")]),
            F.Item(url: "about:blank", visitCount: 1, visits: [F.Visit(time: cd(1_700_000_021), title: nil)]),
            F.Item(url: "https://nevervisited.example/", visitCount: 0, visits: []),
        ]
    }

    func makeDirectory(_ tmp: BrowserTempDir) throws -> URL {
        let dir = try tmp.makeDirectory("Safari")
        try F.makeHistory(at: dir.appendingPathComponent("History.db"), items: standardItems())
        return dir
    }

    @Test func readsVisitsWithCoreDataTimestamps() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let read = try SafariImporter.readHistory(directory: try makeDirectory(tmp), options: options())
        let apple = try #require(read.entries.first { $0.url.host == "apple.com" })
        #expect(apple.title == "Apple")                              // newest non-empty title
        #expect(apple.visitCount == 2)
        #expect(apple.typedCount == 0)
        #expect(abs(apple.firstVisit.timeIntervalSince1970 - 1_700_000_000.5) < 1e-6)
        #expect(abs(apple.lastVisit.timeIntervalSince1970 - 1_700_100_000.25) < 1e-6)
    }

    @Test func filtersNonWebFailedAndEmptyItems() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let read = try SafariImporter.readHistory(directory: try makeDirectory(tmp), options: options())
        #expect(Set(read.entries.map(\.url.absoluteString)) == ["https://apple.com/", "http://example.org/p", "https://counted.example/"])
        #expect(read.entries.first { $0.url.host == "example.org" }?.title == "")
        #expect(read.entries.first { $0.url.host == "counted.example" }?.visitCount == 3)   // max(history_items.visit_count, visits)
        #expect(read.entries.map(\.url.host) == ["apple.com", "example.org", "counted.example"])
    }

    @Test func sinceAndLimit() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let dir = try makeDirectory(tmp)
        let since = try SafariImporter.readHistory(directory: dir, options: options(since: browserDate(1_700_040_000)))
        #expect(since.entries.map(\.url.host) == ["apple.com", "example.org"])
        let limited = try SafariImporter.readHistory(directory: dir, options: options(limit: 1))
        #expect(limited.entries.map(\.url.host) == ["apple.com"])
    }

    @Test func parsesBookmarksPlistAndSkipsReadingListAndHistoryProxy() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        try F.makeBookmarks(at: tmp.sub("Bookmarks.plist"), children: [
            ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History", "WebBookmarkIdentifier": "History", "WebBookmarkUUID": "x"],
            F.list("BookmarksBar", [F.leaf("Apple", "https://apple.com/"), F.list("Dev", [F.leaf("Swift", "https://swift.org/")]), F.leaf("Bookmarklet", "javascript:alert(1)")]),
            F.list("BookmarksMenu", [F.leaf("Menu", "https://menu.example/")]),
            F.list("com.apple.ReadingList", [F.readingListItem]),
            F.list("Empty", []),
        ])
        let read = try SafariImporter.readBookmarks(directory: tmp.url)
        #expect(read.nodes.map(\.title) == ["Favorites", "Bookmarks Menu"])
        #expect(read.nodes[0].children.map(\.title) == ["Apple", "Dev"])
        #expect(read.nodes[0].children[1].children.first?.url?.absoluteString == "https://swift.org/")
        #expect(read.nodes[1].children.map(\.title) == ["Menu"])
        #expect(read.skipped == 1)
        #expect(read.nodes.bookmarkCount == 3)
    }

    @Test func notAPlistIsAnError() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        try "not a plist".write(to: tmp.sub("Bookmarks.plist"), atomically: true, encoding: .utf8)
        #expect(throws: BrowserImportError.self) { try SafariImporter.readBookmarks(directory: tmp.url) }
    }

    // MARK: Full Disk Access

    @Test func blockedHistoryMapsToPermissionDeniedWithAnActionableMessage() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let dir = try makeDirectory(tmp)
        let file = dir.appendingPathComponent("History.db")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        let work = try tmp.makeDirectory("work")
        do {
            _ = try SafariImporter.readHistory(directory: dir, options: options(work: work))
            Issue.record("expected permissionDenied")
        } catch let error as BrowserImportError {
            #expect(error == .permissionDenied(path: file.path))
            #expect(error.errorDescription?.contains("Full Disk Access") == true)
        }
        #expect(tmp.names(in: "work").isEmpty)
    }

    @Test func blockedBookmarksMapToPermissionDenied() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let file = tmp.sub("Bookmarks.plist")
        try F.makeBookmarks(at: file, children: [F.list("BookmarksBar", [F.leaf("A", "https://a.example/")])])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        #expect(throws: BrowserImportError.permissionDenied(path: file.path)) { try SafariImporter.readBookmarks(directory: tmp.url) }
    }

    @Test func aBlockedDirectoryIsReportedAsDeniedByDiscoveryAndImport() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let dir = try makeDirectory(tmp)
        try F.makeBookmarks(at: dir.appendingPathComponent("Bookmarks.plist"), children: [F.list("BookmarksBar", [F.leaf("A", "https://a.example/")])])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)   // like TCC on ~/Library/Safari

        let profiles = BrowserProfileDiscovery.profiles(of: .safari, root: dir)
        let profile = try #require(profiles.first)
        #expect(profile.accessDenied)
        #expect(profile.dataKinds == [.history, .bookmarks])
        #expect(profile.approximateCounts.isEmpty)

        for opts in [options(), options(history: true, bookmarks: false), options(history: false, bookmarks: true)] {
            do {
                _ = try BrowserImporter.read(profile, options: opts)
                Issue.record("expected permissionDenied")
            } catch let error as BrowserImportError {
                guard case .permissionDenied = error else { Issue.record("wrong error \(error)"); continue }
            }
        }
    }
}
