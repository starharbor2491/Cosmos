import Foundation
import Testing
@testable import CosmosKit
@testable import CosmosCore

/// A browser whose files were truncated by a full disk, hand edited, or written by a newer version must still open,
/// with a usable workspace, instead of crashing at launch (where the user cannot do anything about it).
@MainActor
@Suite struct CorruptDataTests {
    static let files = ["workspace.json", "archive.json", "boosts.json", "link-routing.json", "settings.json",
                        "command-bar-learning.json", "session.json", "history.sqlite"]

    /// A valid workspace as JSON, to break in specific ways.
    static func validWorkspaceObject() throws -> [String: Any] {
        let data = try JSONEncoder.cosmos.encode(Workspace.fresh())
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }

    static func brokenContents() throws -> [(String, Data)] {
        let valid = try validWorkspaceObject()
        let good = json(valid)
        var noSpaces = valid; noSpaces["spaces"] = []
        var noProfiles = valid; noProfiles["profiles"] = []
        var noItems = valid; noItems["items"] = []
        var strayProfile = valid
        if var spaces = valid["spaces"] as? [[String: Any]] { spaces[0]["profileID"] = UUID().uuidString; strayProfile["spaces"] = spaces }
        var cycle = valid
        if var items = valid["items"] as? [[String: Any]] {
            let a = UUID().uuidString, b = UUID().uuidString
            let tab: (String, String) -> [String: Any] = { id, other in
                ["id": id, "parentID": other, "childIDs": [other], "createdAt": "2026-01-01T00:00:00Z",
                 "content": ["kind": "folder", "folder": ["isExpanded": true]]]
            }
            items += [tab(a, b), tab(b, a)]
            cycle["items"] = items
        }
        return [
            ("empty", Data()),
            ("garbage", Data("not json at all".utf8)),
            ("nul bytes", Data(repeating: 0, count: 4096)),
            ("null", Data("null".utf8)),
            ("empty object", Data("{}".utf8)),
            ("empty array", Data("[]".utf8)),
            ("truncated", good.prefix(good.count / 2)),
            ("deeply nested", Data(String(repeating: "[", count: 200_000).utf8)),
            ("huge", Data(repeating: UInt8(ascii: " "), count: 8_000_000) + good),
            ("no spaces", json(noSpaces)),
            ("no profiles", json(noProfiles)),
            ("no items", json(noItems)),
            ("space on a profile that is gone", json(strayProfile)),
            ("folders that contain each other", json(cycle)),
        ]
    }

    func openBrokenStore(file: String, contents: Data) throws -> BrowserStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try contents.write(to: dir.appendingPathComponent(file))
        return BrowserStore(directory: dir, engine: FakeEngine())
    }

    /// Everything a window needs on its first frame.
    func useIt(_ store: BrowserStore) {
        let window = store.makeWindowState()
        store.register(window)
        #expect(store.workspace.spaces.isEmpty == false)
        #expect(store.workspace.space(window.focusedSpaceID) != nil)
        #expect(store.workspace.problems().isEmpty, "\(store.workspace.problems().prefix(3))")
        store.newTab(url: URL(string: "https://example.com/after-corruption"), in: window)
        store.closeTab(window.selectedItemID ?? UUID(), in: window)
        _ = store.environment(forProfile: store.workspace.space(window.focusedSpaceID)?.profileID)
    }

    static let damage = ["empty", "garbage", "nul bytes", "null", "empty object", "empty array", "truncated", "deeply nested", "huge",
                         "no spaces", "no profiles", "no items", "space on a profile that is gone", "folders that contain each other"]

    @Test(.serialized, arguments: damage) func everyFileSurvives(_ kind: String) throws {
        let contents = try #require(try Self.brokenContents().first { $0.0 == kind }).1
        for file in Self.files {
            let store = try openBrokenStore(file: file, contents: contents)
            useIt(store)
            if !store.workspace.problems().isEmpty { Issue.record("\(file) as \(kind)") }
        }
    }

    /// A file that is there but cannot be read (cut short by a full disk, or written by a newer Cosmos) must not be replaced
    /// by an empty one at the next save: its last good copy comes back, and failing that it is put aside, not overwritten.
    @Test func anUnreadableArchiveComesBackFromItsCopyOrIsKept() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = BrowserStore(directory: dir, engine: FakeEngine())
        let item = SidebarItem(title: "Kept", content: .tab(TabData(url: URL(string: "https://kept.example"))))
        first.archive.add(ArchivedItem(reason: .closed, spaceID: nil, items: [item]))
        first.boosts = BoostLibrary(boosts: [Boost(name: "Mine", hostPatterns: ["a.com"], css: "p{}")])
        first.markDirty(.archive); first.markDirty(.boosts)
        first.saveNow()
        // A later save makes the dated copy of what was there.
        first.markDirty(.archive); first.markDirty(.boosts)
        first.saveNow()

        let broken = Data("{\"entries\": [".utf8)
        try broken.write(to: dir.appendingPathComponent("archive.json"))
        try broken.write(to: dir.appendingPathComponent("boosts.json"))
        let backups = dir.appendingPathComponent("Backups")
        for name in try FileManager.default.contentsOfDirectory(atPath: backups.path) where name.hasPrefix("boosts.") {
            try FileManager.default.removeItem(at: backups.appendingPathComponent(name))
        }

        let reopened = BrowserStore(directory: dir, engine: FakeEngine())
        #expect(reopened.archive.entries.first?.items.first?.title == "Kept", "the last good copy came back")
        #expect(reopened.boosts.boosts.isEmpty)
        reopened.boosts = BoostLibrary()
        reopened.saveNow()
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("boosts.") && $0 != "boosts.json" }
        #expect(kept.count == 1, "the file that could not be read is still there to recover")
        #expect(try kept.first.map { try Data(contentsOf: dir.appendingPathComponent($0)) } == broken)
    }

    /// A sidebar wider than the window cannot be dragged back: its handle is off screen.
    @Test(arguments: [1e9, -50, 0, 3]) func anAbsurdSidebarWidthInTheSessionFileIsBroughtBackIntoRange(_ width: Double) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = BrowserStore(directory: dir, engine: FakeEngine())
        let session = ["windows": [["focusedSpaceID": first.workspace.spaces[0].id.uuidString, "selection": [String](),
                                    "sidebarVisible": true, "sidebarWidth": width]]]
        try Self.json(session).write(to: dir.appendingPathComponent("session.json"))
        let reopened = BrowserStore(directory: dir, engine: FakeEngine())
        #expect(WindowState.sidebarWidthRange.contains(reopened.makeWindowState(restoring: 0).sidebarWidth))
    }

    @Test func aNonNumberSidebarWidthInSettingsIsBroughtBackIntoRange() {
        let store = BrowserStore(directory: nil, engine: FakeEngine())
        store.settings.sidebarWidth = .nan
        #expect(WindowState.sidebarWidthRange.contains(store.makeWindowState().sidebarWidth))
    }
}
