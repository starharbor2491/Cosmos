import Foundation
import Testing
@testable import CosmosCore

/// A damaged file can describe a tree that loops. The model has to answer questions about it (and `repair()` has to be
/// able to fix it) without recursing forever.
@Suite struct WorkspaceCycleTests {
    private func corrupted(_ damage: (inout [[String: Any]], _ ids: [String]) -> Void) throws -> Workspace {
        var ws = Workspace.fresh()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let space = ws.spaces[0]
        let madeFolder = ws.addFolder(title: "F", under: space.pinnedRootID, now: t0)
        let folder = try #require(madeFolder)
        _ = ws.addTab(url: URL(string: "https://example.com"), under: folder, now: t0)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder.cosmos.encode(ws)) as? [String: Any])
        var items = try #require(json["items"] as? [[String: Any]])
        damage(&items, items.compactMap { $0["id"] as? String })
        json["items"] = items
        return try JSONDecoder.cosmos.decode(Workspace.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func anItemThatListsItselfAsAChildDoesNotHangTheWalk() throws {
        let ws = try corrupted { items, _ in
            let i = items.firstIndex { ($0["content"] as? [String: Any])?["kind"] as? String == "folder" }!
            items[i]["childIDs"] = [items[i]["id"] as! String]
        }
        let root = ws.spaces[0].pinnedRootID
        #expect(ws.descendants(of: root).count < 10)
        #expect(ws.tabs(under: root).count < 10)
    }

    @Test func aTwoItemLoopDoesNotHangTheWalk() throws {
        let ws = try corrupted { items, _ in
            let folder = items.firstIndex { ($0["content"] as? [String: Any])?["kind"] as? String == "folder" }!
            let tab = items.firstIndex { ($0["content"] as? [String: Any])?["kind"] as? String == "tab" }!
            items[tab]["childIDs"] = [items[folder]["id"] as! String]
        }
        _ = ws.descendants(of: ws.spaces[0].pinnedRootID)
        var fixed = ws
        fixed.repair()
        #expect(fixed.problems().isEmpty)
    }

    @Test func aVeryDeepChainIsWalkedWithoutOverflowingTheStack() throws {
        var ws = Workspace.fresh()
        var parent = ws.spaces[0].pinnedRootID
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for _ in 0..<20_000 {
            let made = ws.addFolder(title: "d", under: parent, now: t0)
            parent = try #require(made)
        }
        #expect(ws.descendants(of: ws.spaces[0].pinnedRootID).count == 20_000)
    }

    @Test func restoringASubtreeThatPointsOutsideItselfKeepsTheTreeHealthy() throws {
        var ws = Workspace.fresh()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let space = ws.spaces[0]
        let madeKeep = ws.addTab(url: URL(string: "https://keep.example"), under: space.unpinnedRootID, now: t0)
        let madeGone = ws.addTab(url: URL(string: "https://gone.example"), under: space.unpinnedRootID, now: t0)
        let keep = try #require(madeKeep), gone = try #require(madeGone)
        var subtree = ws.remove(gone)
        // A damaged archive: the item claims itself, a live item and a stranger as children.
        subtree[0].childIDs = [subtree[0].id, keep, UUID()]
        let back = ws.restore(subtree, under: space.unpinnedRootID)
        #expect(back != nil)
        #expect(ws.problems().isEmpty, "\(ws.problems())")
        #expect(ws.item(keep)?.parentID == space.unpinnedRootID, "a live item is not adopted by the restored one")
        _ = ws.descendants(of: space.unpinnedRootID)
    }
}
