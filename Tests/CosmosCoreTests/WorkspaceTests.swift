import Foundation
import Testing
@testable import CosmosCore

@Suite struct WorkspaceTests {
    func makeWS() -> (WSBox, Space) {
        let ws = WSBox()
        return (ws, ws.spaces[0])
    }

    @Test func freshWorkspaceIsHealthy() {
        let (ws, space) = makeWS()
        #expect(ws.problems().isEmpty)
        #expect(ws.spaces.count == 1)
        #expect(ws.children(of: space.pinnedRootID).isEmpty)
        #expect(ws.section(of: space.unpinnedRootID) == .unpinned(spaceID: space.id))
    }

    @Test func addTabsAndSections() throws {
        let (ws, space) = makeWS()
        let a = try #require(ws.addTab(url: URL(string: "https://a.com"), under: space.unpinnedRootID, at: 0))
        let b = try #require(ws.addTab(url: URL(string: "https://b.com"), under: space.unpinnedRootID, at: 0))
        #expect(ws.unpinned(in: space).map(\.id) == [b, a])
        #expect(ws.section(of: a) == .unpinned(spaceID: space.id))
        #expect(ws.spaceID(of: a) == space.id)
        #expect(ws.problems().isEmpty)
    }

    @Test func foldersOnlyInPinned() throws {
        let (ws, space) = makeWS()
        #expect(ws.addFolder(title: "x", under: space.unpinnedRootID) == nil)
        #expect(ws.addFolder(title: "x", under: ws.favoritesRootID) == nil)
        let f = try #require(ws.addFolder(title: "Work", under: space.pinnedRootID))
        let t = try #require(ws.addTab(url: URL(string: "https://w.com"), under: f))
        #expect(ws.section(of: t) == .pinned(spaceID: space.id))
        #expect(ws.problems().isEmpty)
    }

    @Test func pinUnpinKeepsHomeURL() throws {
        let (ws, space) = makeWS()
        let t = try #require(ws.addTab(url: URL(string: "https://home.example"), under: space.unpinnedRootID))
        #expect(ws.pin(t))
        #expect(ws.section(of: t) == .pinned(spaceID: space.id))
        #expect(ws.item(t)?.tab?.homeURL?.absoluteString == "https://home.example")
        ws.updateTab(t) { $0.url = URL(string: "https://home.example/deep/page") }
        #expect(ws.resetPinned(in: space.id) == [t])
        #expect(ws.item(t)?.tab?.url?.absoluteString == "https://home.example")
        #expect(ws.unpin(t))
        #expect(ws.item(t)?.tab?.homeURL == nil)
        #expect(ws.unpinned(in: space).first?.id == t)
        #expect(ws.problems().isEmpty)
    }

    @Test func favoritesAcceptOnlyTabs() throws {
        let (ws, space) = makeWS()
        let t = try #require(ws.addTab(url: URL(string: "https://fav.example"), under: space.unpinnedRootID))
        #expect(ws.favorite(t))
        #expect(ws.favorites.map(\.id) == [t])
        #expect(ws.spaceID(of: t) == nil)
        let f = try #require(ws.addFolder(title: "F", under: space.pinnedRootID))
        #expect(!ws.move(f, under: ws.favoritesRootID))
        #expect(ws.unfavorite(t, into: space.id))
        #expect(ws.favorites.isEmpty)
        #expect(ws.problems().isEmpty)
    }

    @Test func moveWithinSameParentReorders() throws {
        let (ws, space) = makeWS()
        let ids = try (0..<4).map { try #require(ws.addTab(url: URL(string: "https://\($0).com"), under: space.pinnedRootID)) }
        #expect(ws.move(ids[0], under: space.pinnedRootID, at: 3))
        #expect(ws.pinned(in: space).map(\.id) == [ids[1], ids[2], ids[3], ids[0]])
        #expect(ws.move(ids[3], under: space.pinnedRootID, at: 0))
        #expect(ws.pinned(in: space).map(\.id) == [ids[3], ids[1], ids[2], ids[0]])
        #expect(ws.problems().isEmpty)
    }

    @Test func cannotMoveFolderIntoItself() throws {
        let (ws, space) = makeWS()
        let outer = try #require(ws.addFolder(title: "outer", under: space.pinnedRootID))
        let inner = try #require(ws.addFolder(title: "inner", under: outer))
        #expect(!ws.move(outer, under: inner))
        #expect(!ws.move(outer, under: outer))
        #expect(ws.move(inner, under: space.pinnedRootID, at: 0))
        #expect(ws.problems().isEmpty)
    }

    @Test func removeReturnsSubtreeAndRestoreRoundTrips() throws {
        let (ws, space) = makeWS()
        let f = try #require(ws.addFolder(title: "F", under: space.pinnedRootID))
        let t1 = try #require(ws.addTab(url: URL(string: "https://1.com"), under: f))
        _ = try #require(ws.addTab(url: URL(string: "https://2.com"), under: f))
        let removed = ws.remove(f)
        #expect(removed.count == 3)
        #expect(ws.item(t1) == nil)
        #expect(ws.problems().isEmpty)
        let restored = try #require(ws.restore(removed, under: space.pinnedRootID))
        #expect(restored == f)
        #expect(ws.tabs(under: f).count == 2)
        #expect(ws.problems().isEmpty)
    }

    @Test func restoreRemapsCollidingIDs() throws {
        let (ws, space) = makeWS()
        let t = try #require(ws.addTab(url: URL(string: "https://x.com"), under: space.unpinnedRootID))
        let snapshot = [try #require(ws.item(t))]
        let again = try #require(ws.restore(snapshot, under: space.unpinnedRootID))
        #expect(again != t)
        #expect(ws.tabs(under: space.unpinnedRootID).count == 2)
        #expect(ws.problems().isEmpty)
    }

    @Test func splitCombineSeparateAndDissolve() throws {
        let (ws, space) = makeWS()
        let a = try #require(ws.addTab(url: URL(string: "https://a.com"), under: space.unpinnedRootID))
        let b = try #require(ws.addTab(url: URL(string: "https://b.com"), under: space.unpinnedRootID))
        let c = try #require(ws.addTab(url: URL(string: "https://c.com"), under: space.unpinnedRootID))
        let split = try #require(ws.combineIntoSplit(a, b))
        #expect(ws.item(split)?.childIDs == [a, b])
        #expect(ws.unpinned(in: space).count == 2)  // split + c
        #expect(ws.problems().isEmpty)
        // Third pane via an existing pane.
        #expect(ws.combineIntoSplit(a, c) == split)
        #expect(ws.item(split)?.childIDs == [a, c, b])
        #expect(ws.unpinned(in: space).map(\.id) == [split])
        // Separate one pane out; split keeps two.
        #expect(ws.separateFromSplit(c))
        #expect(ws.item(split)?.childIDs == [a, b])
        #expect(ws.unpinned(in: space).count == 2)
        // Removing one of two panes dissolves the split into the remaining tab.
        ws.remove(b)
        #expect(ws.item(split) == nil)
        #expect(ws.unpinned(in: space).map(\.id).contains(a))
        #expect(ws.problems().isEmpty)
    }

    @Test func splitIsCappedAtFourPanes() throws {
        let (ws, space) = makeWS()
        let tabs = try (0..<5).map { try #require(ws.addTab(url: URL(string: "https://\($0).com"), under: space.unpinnedRootID)) }
        let split = try #require(ws.combineIntoSplit(tabs[0], tabs[1]))
        #expect(ws.combineIntoSplit(tabs[0], tabs[2]) == split)
        #expect(ws.combineIntoSplit(tabs[0], tabs[3]) == split)
        #expect(ws.combineIntoSplit(tabs[0], tabs[4]) == nil)
        #expect(ws.item(split)?.childIDs.count == 4)
        #expect(ws.problems().isEmpty)
    }

    @Test func removeSpaceRefusesLast() throws {
        let (ws, space) = makeWS()
        #expect(ws.removeSpace(space.id) == nil)
        let second = ws.addSpace(title: "Work", theme: .aurora)
        let t = try #require(ws.addTab(url: URL(string: "https://w.com"), under: ws.space(second)!.unpinnedRootID))
        #expect(ws.removeSpace(second) != nil)
        #expect(ws.item(t) == nil)
        #expect(ws.problems().isEmpty)
    }

    @Test func clearUnpinnedKeepsSelected() throws {
        let (ws, space) = makeWS()
        let keep = try #require(ws.addTab(url: URL(string: "https://keep.com"), under: space.unpinnedRootID))
        _ = try #require(ws.addTab(url: URL(string: "https://drop.com"), under: space.unpinnedRootID))
        let removed = ws.clearUnpinned(in: space.id, keeping: [keep])
        #expect(removed.count == 1)
        #expect(ws.unpinned(in: space).map(\.id) == [keep])
    }

    @Test func codableRoundTrip() throws {
        let (ws, space) = makeWS()
        let f = try #require(ws.addFolder(title: "F", under: space.pinnedRootID))
        _ = ws.addTab(url: URL(string: "https://x.com"), title: "X", under: f)
        let a = try #require(ws.addTab(url: URL(string: "https://a.com"), under: space.unpinnedRootID))
        let b = try #require(ws.addTab(url: URL(string: "https://b.com"), under: space.unpinnedRootID))
        _ = ws.combineIntoSplit(a, b, orientation: .vertical)
        let data = try JSONEncoder.cosmos.encode(ws.value)
        let back = try JSONDecoder.cosmos.decode(Workspace.self, from: data)
        #expect(back.problems().isEmpty)
        #expect(back.items.count == ws.items.count)
        #expect(back.spaces == ws.spaces)
        // Stable output: encoding twice gives identical bytes (sorted items, sorted keys).
        #expect(try JSONEncoder.cosmos.encode(back) == data)
    }

    @Test func repairFixesDanglingReferences() throws {
        let (ws, space) = makeWS()
        let t = try #require(ws.addTab(url: URL(string: "https://x.com"), under: space.unpinnedRootID))
        // Corrupt by hand through decoding.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder.cosmos.encode(ws.value)) as! [String: Any]
        var items = json["items"] as! [[String: Any]]
        items.removeAll { ($0["id"] as? String) == t.uuidString }
        json["items"] = items
        let brokenValue = try JSONDecoder.cosmos.decode(Workspace.self, from: JSONSerialization.data(withJSONObject: json))
        var broken = brokenValue
        #expect(!broken.problems().isEmpty)
        broken.repair()
        #expect(broken.problems().isEmpty)
    }
}

@Suite struct ArchiveTests {
    @Test func idleTabsAreArchivedUnlessExempt() throws {
        let ws = WSBox()
        let space = ws.spaces[0]
        let now = Date()
        let old = try #require(ws.addTab(url: URL(string: "https://old.com"), under: space.unpinnedRootID, now: now.addingTimeInterval(-13 * 3600)))
        let fresh = try #require(ws.addTab(url: URL(string: "https://fresh.com"), under: space.unpinnedRootID, now: now.addingTimeInterval(-3600)))
        let playing = try #require(ws.addTab(url: URL(string: "https://music.com"), under: space.unpinnedRootID, now: now.addingTimeInterval(-20 * 3600)))
        let pinned = try #require(ws.addTab(url: URL(string: "https://pinned.com"), under: space.pinnedRootID, now: now.addingTimeInterval(-90 * 86400)))

        let due = ws.idleUnpinnedItems(in: space.id, interval: .hours12, now: now, exempt: [playing])
        #expect(due == [old])
        #expect(!due.contains(fresh) && !due.contains(pinned))
        #expect(ws.idleUnpinnedItems(in: space.id, interval: .never, now: now).isEmpty)
        #expect(Set(ws.idleUnpinnedItems(in: space.id, interval: .hours12, now: now)) == [old, playing])

        let entries = ws.archive(due, reason: .auto, now: now)
        #expect(entries.count == 1)
        #expect(entries[0].spaceID == space.id)
        #expect(ws.item(old) == nil)
        #expect(ws.problems().isEmpty)
    }

    @Test func archiveSearchAndLimit() {
        var data = ArchiveData(limit: 3)
        for i in 0..<5 {
            let item = SidebarItem(title: "Page \(i)", content: .tab(TabData(url: URL(string: "https://site\(i).com"))))
            data.add(ArchivedItem(reason: .closed, spaceID: nil, items: [item]))
        }
        #expect(data.entries.count == 3)
        #expect(data.search("page 4").count == 1)
        #expect(data.search("site3.com").count == 1)
        #expect(data.search("").count == 3)
    }
}

@Suite struct StoreTests {
    @Test func atomicSaveLoadAndBackups() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStore<Workspace>(url: dir.appendingPathComponent("workspace.json"), backupInterval: 0, keepBackups: 3)
        #expect(try store.load() == nil)
        let ws = WSBox()
        try store.save(ws.value, now: Date())
        for i in 0..<5 {
            _ = ws.addTab(url: URL(string: "https://\(i).com"), under: ws.spaces[0].unpinnedRootID)
            try store.save(ws.value, now: Date().addingTimeInterval(Double(i + 1)))
        }
        #expect(try store.load()?.items.count == ws.items.count)
        #expect(store.backups().count == 3)   // rotated
        // Corrupt the main file; restore from the newest good backup.
        try Data("not json".utf8).write(to: store.url)
        #expect((try? store.load()) == nil)
        let restored = try #require(try store.restoreLatestBackup())
        #expect(restored.problems().isEmpty)
        #expect(try store.load() != nil)
    }
}

@Suite struct WorkspaceMergeTests {
    @Test func mergeBringsSpacesTabsAndFavoritesAndIsIdempotent() throws {
        var mine = Workspace.fresh()
        let myTabOpt = mine.addTab(url: URL(string: "https://mine.example"), under: mine.spaces[0].unpinnedRootID)
        let myTab = try #require(myTabOpt)
        #expect(!mine.isPristine)

        var theirs = Workspace.fresh()
        let workID = theirs.addSpace(title: "Work", icon: .symbol("sparkles"), theme: .aurora, profileID: theirs.profiles[0].id)
        let work = try #require(theirs.space(workID))
        let pinnedOpt = theirs.addTab(url: URL(string: "https://work.example"), under: work.pinnedRootID)
        let pinned = try #require(pinnedOpt)
        let favOpt = theirs.addTab(url: URL(string: "https://fav.example"), under: work.unpinnedRootID)
        let fav = try #require(favOpt)
        let favorited = theirs.favorite(fav)
        #expect(favorited)

        mine.merge(theirs)
        #expect(mine.problems().isEmpty)
        #expect(mine.spaces.count == 3)
        #expect(mine.profiles.count == 1)
        #expect(mine.item(myTab) != nil)
        #expect(mine.item(pinned)?.parentID == work.pinnedRootID)
        #expect(mine.favorites.map(\.id) == [fav])

        let snapshot = mine
        mine.merge(theirs)
        #expect(mine == snapshot)
    }

    @Test func freshWorkspaceIsPristine() {
        #expect(Workspace.fresh().isPristine)
    }
}
