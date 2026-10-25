import Foundation
import Testing
import CosmosCore
@testable import CosmosImport

/// A fake home directory with several browsers installed.
struct FakeHome {
    let tmp: BrowserTempDir
    var home: URL { tmp.url }

    init() throws { tmp = try BrowserTempDir("cosmos-home") }

    func root(_ kind: BrowserKind) -> URL { kind.dataRoot(home: home) }

    func rows(_ n: Int) -> [ChromiumRow] {
        (0..<n).map { ChromiumRow(url: "https://site\($0).example/", title: "T\($0)", lastVisit: BrowserEpoch.chromiumMicros(unix: 1_700_000_000 + Int64($0))) }
    }

    /// Arc: `Default` (history + 2 bookmarks) and "Profile 1" (history only); a stray "Profile 2" with nothing in it.
    func installArc() throws {
        let root = root(.arc)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try ChromiumFixture.makeLocalState(at: root.appendingPathComponent("Local State"), profiles: ["Default": "Person 1", "Profile 1": "Work"], lastUsed: "Profile 1")
        try ChromiumFixture.makeProfile(at: root.appendingPathComponent("Default"), rows: rows(3), bar: [
            ChromiumFixture.bookmark("A", "https://a.example/"), ChromiumFixture.folder("F", [ChromiumFixture.bookmark("B", "https://b.example/")]),
        ])
        try ChromiumFixture.makeProfile(at: root.appendingPathComponent("Profile 1"), rows: rows(5))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Profile 2"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ShaderCache"), withIntermediateDirectories: true)
    }

    /// Opera keeps `History` and `Bookmarks` directly in its root.
    func installOpera() throws {
        let root = root(.opera)
        try ChromiumFixture.makeProfile(at: root, rows: rows(2), bar: [ChromiumFixture.bookmark("O", "https://o.example/")])
    }

    func installFirefox() throws {
        let profiles = root(.firefox)
        let places = try FirefoxFixture.create(at: try tmp.makeDirectory("Library/Application Support/Firefox/Profiles/aaa.default-release").appendingPathComponent("places.sqlite"),
                                               places: [FirefoxFixture.Place(url: "https://mozilla.org/", title: "M", lastVisit: BrowserEpoch.firefoxMicros(unix: 1_700_000_000)),
                                                        FirefoxFixture.Place(url: "https://b.example/", title: "B", visitCount: 0, lastVisit: nil)],
                                               bookmarks: FirefoxFixture.roots + [.init(id: 10, type: 1, fk: 2, parent: 3, position: 0, title: "B", guid: "bm10"),
                                                                                  .init(id: 20, type: 2, fk: nil, parent: 4, position: 0, title: "work", guid: "tag20"),
                                                                                  .init(id: 11, type: 1, fk: 2, parent: 20, position: 0, title: nil, guid: "tag11")])
        try places.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        _ = try tmp.makeDirectory("Library/Application Support/Firefox/Profiles/bbb.default")   // listed in profiles.ini but has no places.sqlite
        try FirefoxFixture.makeProfilesINI(at: profiles.deletingLastPathComponent().appendingPathComponent("profiles.ini"), profiles: [
            (name: "default", path: "Profiles/bbb.default", isDefault: false),
            (name: "default-release", path: "Profiles/aaa.default-release", isDefault: true),
        ], installDefault: "Profiles/aaa.default-release")
    }

    func installSafari() throws {
        let root = root(.safari)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try SafariFixture.makeHistory(at: root.appendingPathComponent("History.db"), items: [
            SafariFixture.Item(url: "https://apple.com/", visitCount: 1, visits: [SafariFixture.Visit(time: 700_000_000, title: "Apple")]),
        ])
        try SafariFixture.makeBookmarks(at: root.appendingPathComponent("Bookmarks.plist"), children: [
            SafariFixture.list("BookmarksBar", [SafariFixture.leaf("A", "https://a.example/"), SafariFixture.leaf("B", "https://b.example/")]),
        ])
    }
}

@Suite struct BrowserProfileDiscoveryTests {
    @Test func aMacWithNoBrowsersGivesNothingAndDoesNotThrow() throws {
        let home = try FakeHome()
        defer { home.tmp.remove() }
        #expect(BrowserProfileDiscovery.discover(home: home.home).isEmpty)
    }

    @Test func findsChromiumProfilesWithNamesCountsAndDefault() throws {
        let home = try FakeHome()
        defer { home.tmp.remove() }
        try home.installArc()
        let arc = BrowserProfileDiscovery.discover(home: home.home, browsers: [.arc])

        #expect(arc.map(\.browser) == [.arc, .arc])
        #expect(arc.map(\.name) == ["Work", "Person 1"])             // Local State's last_used profile comes first
        #expect(arc.map(\.isDefault) == [true, false])
        #expect(arc.map { $0.directory.lastPathComponent } == ["Profile 1", "Default"])   // "Profile 2" is empty, "ShaderCache" is not a profile
        let person = arc[1]
        #expect(person.dataKinds == [.history, .bookmarks])
        #expect(person.approximateCounts == [.history: 3, .bookmarks: 2])
        #expect(person.accessDenied == false)
        #expect(arc[0].dataKinds == [.history])
        #expect(arc[0].approximateCounts == [.history: 5])
        #expect(Set(arc.map(\.id)).count == 2)
    }

    @Test func countsCanBeSkipped() throws {
        let home = try FakeHome()
        defer { home.tmp.remove() }
        try home.installArc()
        let arc = BrowserProfileDiscovery.discover(home: home.home, browsers: [.arc], includeCounts: false)
        #expect(arc.count == 2)
        #expect(arc.allSatisfy { $0.approximateCounts.isEmpty })
    }

    @Test func operaKeepsItsProfileInTheRoot() throws {
        let home = try FakeHome()
        defer { home.tmp.remove() }
        try home.installOpera()
        let opera = BrowserProfileDiscovery.discover(home: home.home, browsers: [.opera])
        #expect(opera.count == 1)
        #expect(opera[0].directory == home.root(.opera))
        #expect(opera[0].approximateCounts == [.history: 2, .bookmarks: 1])
        #expect(opera[0].isDefault)
    }

    @Test func readsFirefoxProfilesIni() throws {
        let home = try FakeHome()
        defer { home.tmp.remove() }
        try home.installFirefox()
        let firefox = BrowserProfileDiscovery.discover(home: home.home, browsers: [.firefox])
        #expect(firefox.count == 1)                                  // the profile without places.sqlite is skipped
        let p = firefox[0]
        #expect(p.name == "default-release")
        #expect(p.isDefault)
        #expect(p.directory.lastPathComponent == "aaa.default-release")
        #expect(p.dataKinds == [.history, .bookmarks])
        #expect(p.approximateCounts == [.history: 1, .bookmarks: 1])   // the tag row does not count as a bookmark
    }

    @Test func parsesProfilesIniQuirks() {
        let ini = """
            ; comment
            [Profile1]
            Name=Work = Stuff
            IsRelative=0
            Path=/abs/path
            [General]
            """
        let sections = BrowserProfileDiscovery.parseINI(ini)
        #expect(sections.map(\.name) == ["Profile1", "General"])
        #expect(sections[0].values["Name"] == "Work = Stuff")
        #expect(sections[0].values["IsRelative"] == "0")
    }

    @Test func findsSafariAndEveryBrowserTogether() throws {
        let home = try FakeHome()
        defer { home.tmp.remove() }
        try home.installArc()
        try home.installSafari()
        try home.installFirefox()
        let all = BrowserProfileDiscovery.discover(home: home.home)
        #expect(all.map(\.browser) == [.arc, .arc, .firefox, .safari])   // BrowserKind order
        let safari = try #require(all.last)
        #expect(safari.approximateCounts == [.history: 1, .bookmarks: 2])
        #expect(safari.accessDenied == false)
    }
}

@Suite struct BrowserImporterTests {
    let now = browserDate(1_750_000_000)

    func options(history: Bool = true, bookmarks: Bool = true, work: URL? = nil) -> BrowserImportOptions {
        BrowserImportOptions(history: history, bookmarks: bookmarks, workDirectory: work, now: now)
    }

    @Test func readsAnArcProfileEndToEnd() throws {
        let home = try FakeHome()
        defer { home.tmp.remove() }
        try home.installArc()
        let profile = try #require(BrowserProfileDiscovery.discover(home: home.home, browsers: [.arc]).first { $0.name == "Person 1" })
        let work = try home.tmp.makeDirectory("work")
        let data = try BrowserImporter.read(profile, options: options(work: work))

        #expect(data.history.count == 3)
        #expect(data.bookmarks.map(\.title) == ["Bookmarks Bar"])
        #expect(data.report.browser == .arc)
        #expect(data.report.profileName == "Person 1")
        #expect(data.report.historyImported == 3)
        #expect(data.report.historyRowsRead == 3)
        #expect(data.report.bookmarksImported == 2)
        #expect(data.report.bookmarkFoldersImported == 2)       // the Bookmarks Bar root and "F"
        #expect(data.report.warnings.isEmpty)
        #expect(home.tmp.names(in: "work").isEmpty)
    }

    @Test func honoursTheHistoryAndBookmarksSwitches() throws {
        let home = try FakeHome()
        defer { home.tmp.remove() }
        try home.installArc()
        let profile = try #require(BrowserProfileDiscovery.discover(home: home.home, browsers: [.arc]).first { $0.name == "Person 1" })
        let historyOnly = try BrowserImporter.read(profile, options: options(bookmarks: false))
        #expect(historyOnly.history.count == 3)
        #expect(historyOnly.bookmarks.isEmpty)
        let bookmarksOnly = try BrowserImporter.read(profile, options: options(history: false))
        #expect(bookmarksOnly.history.isEmpty)
        #expect(bookmarksOnly.bookmarks.bookmarkCount == 2)
        #expect(bookmarksOnly.report.historyImported == 0)
    }

    @Test func acceptsTheOptionsAsATuple() throws {
        let home = try FakeHome()
        defer { home.tmp.remove() }
        try home.installArc()
        let profile = try #require(BrowserProfileDiscovery.discover(home: home.home, browsers: [.arc]).first { $0.name == "Person 1" })
        let data = try BrowserImporter.read(profile, options: (history: true, bookmarks: false, since: nil, limit: 2))
        #expect(data.history.count == 2)
        #expect(data.bookmarks.isEmpty)
        let plain = try BrowserImporter.read(profile)
        #expect(plain.history.count == 3)
    }

    @Test func aMissingBookmarksFileBecomesAWarning() throws {
        let home = try FakeHome()
        defer { home.tmp.remove() }
        try home.installArc()
        let profile = try #require(BrowserProfileDiscovery.discover(home: home.home, browsers: [.arc]).first { $0.name == "Work" })   // no Bookmarks file
        let data = try BrowserImporter.read(profile, options: options())
        #expect(data.history.count == 5)
        #expect(data.bookmarks.isEmpty)
        #expect(data.report.warnings.count == 1)
        #expect(data.report.warnings[0].contains("bookmarks"))
    }

    @Test func aCorruptHistoryStillLetsBookmarksThrough() throws {
        let home = try FakeHome()
        defer { home.tmp.remove() }
        try home.installArc()
        let profile = try #require(BrowserProfileDiscovery.discover(home: home.home, browsers: [.arc]).first { $0.name == "Person 1" })
        try Data(repeating: 0x42, count: 5000).write(to: profile.directory.appendingPathComponent("History"))
        let data = try BrowserImporter.read(profile, options: options())
        #expect(data.history.isEmpty)
        #expect(data.bookmarks.bookmarkCount == 2)
        #expect(data.report.warnings.count == 1)
    }

    @Test func throwsWhenNothingCouldBeRead() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let profile = BrowserProfile(browser: .chrome, name: "Ghost", directory: tmp.url, dataKinds: [.history, .bookmarks])
        #expect(throws: BrowserImportError.fileNotFound(path: tmp.sub("History").path)) { try BrowserImporter.read(profile, options: options()) }
    }

    @Test func readsFirefoxAndSafariProfiles() throws {
        let home = try FakeHome()
        defer { home.tmp.remove() }
        try home.installFirefox()
        try home.installSafari()
        let profiles = BrowserProfileDiscovery.discover(home: home.home, browsers: [.firefox, .safari])
        let firefox = try BrowserImporter.read(try #require(profiles.first { $0.browser == .firefox }), options: options())
        #expect(firefox.history.map(\.url.absoluteString) == ["https://mozilla.org/"])
        #expect(firefox.report.bookmarksImported == 1)
        let safari = try BrowserImporter.read(try #require(profiles.first { $0.browser == .safari }), options: options())
        #expect(safari.history.map(\.title) == ["Apple"])
        #expect(safari.bookmarks.map(\.title) == ["Favorites"])
        #expect(safari.report.bookmarksImported == 2)
    }

    @Test func importedHistoryFeedsTheHistoryStore() throws {
        let home = try FakeHome()
        defer { home.tmp.remove() }
        try home.installArc()
        let profile = try #require(BrowserProfileDiscovery.discover(home: home.home, browsers: [.arc]).first { $0.name == "Person 1" })
        let data = try BrowserImporter.read(profile, options: options())
        let store = try HistoryStore(path: nil)
        try store.importEntries(data.history)
        #expect(store.count() == 3)
        #expect(store.search("T1").first?.title == "T1")
    }
}
