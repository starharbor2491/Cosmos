import Foundation
import Testing
import CosmosCore
@testable import CosmosImport

/// Other browsers' files are read while those browsers may be running, half written, or from a version we have never
/// seen. Whatever is in them, reading must end in data or an error.
@Suite struct BrowserImporterFuzzTests {
    typealias RNG = ImporterFuzzTests.SplitMix64

    static func damage(_ file: URL, _ rng: inout RNG) throws {
        var bytes = [UInt8](try Data(contentsOf: file))
        guard !bytes.isEmpty else { return }
        switch Int.random(in: 0..<5, using: &rng) {
        case 0: bytes = []
        case 1: bytes = Array(bytes.prefix(Int.random(in: 0..<bytes.count, using: &rng)))
        case 2: for _ in 0..<Int.random(in: 1...30, using: &rng) { bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
        case 3: bytes = Array(repeating: UInt8(ascii: "{"), count: 100_000)
        default: bytes = (0..<4096).map { _ in UInt8.random(in: 0...255, using: &rng) }
        }
        try Data(bytes).write(to: file)
    }

    static let chromiumRows = [
        ChromiumRow(url: "https://example.com/a", title: "A", visitCount: 3, typedCount: 1, lastVisit: BrowserEpoch.chromiumMicros(unix: 1_700_000_000), visits: [BrowserEpoch.chromiumMicros(unix: 1_700_000_000)]),
        ChromiumRow(url: "https://example.org/b?q=1#x", title: "", visitCount: 1, lastVisit: BrowserEpoch.chromiumMicros(unix: 1_700_000_100)),
        ChromiumRow(url: "javascript:alert(1)", title: "no", lastVisit: 1),
    ]

    @Test(arguments: Array(1...40) as [UInt64]) func chromiumFilesInAnyState(seed: UInt64) throws {
        var rng = RNG(state: seed &* 0x8CB9_2BA7_2F3D_8DD7)
        let temp = try BrowserTempDir()
        defer { temp.remove() }
        let bar: [[String: Any]] = [ChromiumFixture.bookmark("One", "https://example.com/1"), ChromiumFixture.folder("F", [ChromiumFixture.bookmark("Two", "https://example.com/2")])]
        let dir = try ChromiumFixture.makeProfile(at: temp.sub("p", isDirectory: true), rows: Self.chromiumRows, bar: bar)
        try Self.damage(dir.appendingPathComponent(["History", "Bookmarks"].randomElement(using: &rng)!), &rng)
        _ = try? ChromiumImporter.readHistory(profileDirectory: dir)
        if let read = try? ChromiumImporter.readBookmarks(profileDirectory: dir) {
            var ws = Workspace.fresh()
            _ = BookmarkImporter.populate(&ws, with: read.nodes)
            #expect(ws.problems().isEmpty)
        }
    }

    @Test(arguments: Array(1...40) as [UInt64]) func chromiumBookmarksWithAnyStructure(seed: UInt64) throws {
        var rng = RNG(state: seed &* 0xD1B5_4A32_D192_ED03)
        let temp = try BrowserTempDir()
        defer { temp.remove() }
        let dir = try temp.makeDirectory("p")
        let bar: [[String: Any]] = [ChromiumFixture.bookmark("One", "https://example.com/1"), ChromiumFixture.folder("F", [ChromiumFixture.bookmark("Two", "https://example.com/2")])]
        try ChromiumFixture.makeBookmarks(at: dir.appendingPathComponent("Bookmarks"), bar: bar)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("Bookmarks")))
        for _ in 0..<Int.random(in: 1...6, using: &rng) { json = ImporterFuzzTests.mutate(json, &rng) }
        try JSONSerialization.data(withJSONObject: json, options: .fragmentsAllowed).write(to: dir.appendingPathComponent("Bookmarks"))
        if let read = try? ChromiumImporter.readBookmarks(profileDirectory: dir) {
            var ws = Workspace.fresh()
            _ = BookmarkImporter.populate(&ws, with: read.nodes)
            #expect(ws.problems().isEmpty)
        }
    }

    @Test(arguments: Array(1...40) as [UInt64]) func firefoxPlacesInAnyState(seed: UInt64) throws {
        var rng = RNG(state: seed &* 0xAF25_1AF3_B0F0_25B5)
        let temp = try BrowserTempDir()
        defer { temp.remove() }
        let dir = try temp.makeDirectory("ff")
        let file = FirefoxImporter.placesFile(in: dir)
        _ = try FirefoxFixture.create(at: file, places: [.init(url: "https://example.com/a", title: "A", lastVisit: BrowserEpoch.firefoxMicros(unix: 1_700_000_000), visits: [(BrowserEpoch.firefoxMicros(unix: 1_700_000_000), 1)])],
                                      bookmarks: FirefoxFixture.roots + [.init(id: 10, type: 1, fk: 1, parent: 3, position: 0, title: "A", guid: "g10")])
        try Self.damage(file, &rng)
        _ = try? FirefoxImporter.read(profileDirectory: dir, options: BrowserImportOptions())
    }

    @Test(arguments: Array(1...40) as [UInt64]) func safariFilesInAnyState(seed: UInt64) throws {
        var rng = RNG(state: seed &* 0x9FB2_1C65_1E98_DF25)
        let temp = try BrowserTempDir()
        defer { temp.remove() }
        let dir = try temp.makeDirectory("safari")
        try SafariFixture.makeHistory(at: SafariImporter.historyFile(in: dir), items: [.init(url: "https://example.com/a", visitCount: 1, visits: [.init(time: 700_000_000, title: "A")])])
        try SafariFixture.makeBookmarks(at: SafariImporter.bookmarksFile(in: dir), children: [SafariFixture.leaf("A", "https://example.com/a"), SafariFixture.list("L", [SafariFixture.leaf("B", "https://example.com/b")])])
        try Self.damage([SafariImporter.historyFile(in: dir), SafariImporter.bookmarksFile(in: dir)].randomElement(using: &rng)!, &rng)
        _ = try? SafariImporter.readHistory(directory: dir)
        if let read = try? SafariImporter.readBookmarks(directory: dir) {
            var ws = Workspace.fresh()
            _ = BookmarkImporter.populate(&ws, with: read.nodes)
            #expect(ws.problems().isEmpty)
        }
    }

    @Test(arguments: Array(1...40) as [UInt64]) func extensionManifestsOfAnyShape(seed: UInt64) throws {
        var rng = RNG(state: seed &* 0xC2B2_AE3D_27D4_EB4F)
        let temp = try BrowserTempDir()
        defer { temp.remove() }
        let root = try temp.makeDirectory("Extensions")
        let version = try temp.makeDirectory("Extensions/abcdefghijklmnopabcdefghijklmnop/1.0")
        var manifest: Any = ["name": "Thing", "version": "1.0", "manifest_version": 3, "description": "d", "permissions": ["tabs"],
                             "icons": ["16": "a.png"], "default_locale": "en"] as [String: Any]
        for _ in 0..<Int.random(in: 0...5, using: &rng) { manifest = ImporterFuzzTests.mutate(manifest, &rng) }
        try JSONSerialization.data(withJSONObject: manifest, options: .fragmentsAllowed).write(to: version.appendingPathComponent("manifest.json"))
        _ = ChromiumExtensionScanner.scan(extensionsDirectory: root, browser: .chrome, profileName: "Default")
    }
}
