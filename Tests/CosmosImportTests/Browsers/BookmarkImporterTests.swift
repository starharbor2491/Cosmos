import Foundation
import Testing
import CosmosCore
@testable import CosmosImport

@Suite struct BookmarkImporterTests {
    func bm(_ title: String, _ url: String, added: Date? = nil) -> BookmarkNode { .bookmark(title, url: URL(string: url)!, dateAdded: added) }

    /// `Bar{A,Dev{B,C},D},E`: titles in order, folders with their children in braces.
    func outline(_ ws: Workspace, _ parent: UUID) -> String {
        ws.children(of: parent).map { $0.isFolder ? "\($0.displayTitle){\(outline(ws, $0.id))}" : $0.displayTitle }.joined(separator: ",")
    }

    func folderDepth(_ ws: Workspace, _ parent: UUID, _ depth: Int = 0) -> Int {
        ws.children(of: parent).filter(\.isFolder).map { folderDepth(ws, $0.id, depth + 1) }.max() ?? depth
    }

    func pinnedRoot(_ ws: Workspace, _ spaceID: UUID) throws -> UUID { try #require(ws.space(spaceID)).pinnedRootID }

    @Test func foldersBecomeFoldersAndBookmarksBecomePinnedTabsInOrder() throws {
        var ws = Workspace.fresh()
        let added = browserDate(1_700_000_000)
        let tree: [BookmarkNode] = [
            .folder("Bar", children: [
                bm("A", "https://a.example/", added: added),
                .folder("Dev", dateAdded: added, children: [bm("B", "https://b.example/"), bm("C", "https://c.example/")]),
                bm("D", "https://d.example/"),
            ]),
            bm("E", "https://e.example/"),
        ]
        let id = BookmarkImporter.populate(&ws, with: tree)

        let space = try #require(ws.space(id))
        #expect(space.title == "Imported")
        #expect(ws.spaces.count == 2)
        #expect(outline(ws, space.pinnedRootID) == "Bar{A,Dev{B,C},D},E")
        #expect(ws.unpinned(in: space).isEmpty)
        #expect(ws.problems().isEmpty)

        let tabs = ws.tabs(under: space.pinnedRootID)
        #expect(tabs.count == 5)
        for t in tabs {
            #expect(ws.section(of: t.id) == .pinned(spaceID: id))
            #expect(t.tab?.homeURL == t.tab?.url)                     // "reset tab" returns to the bookmarked page
            #expect(t.tab?.lastActiveAt == nil)
        }
        let a = try #require(tabs.first { $0.displayTitle == "A" })
        #expect(a.tab?.url?.absoluteString == "https://a.example/")
        #expect(a.tab?.pageTitle == "A")
        #expect(a.createdAt == added)
        let folders = ws.descendants(of: space.pinnedRootID).filter(\.isFolder)
        #expect(folders.count == 2)
        #expect(folders.allSatisfy { if case .folder(let f) = $0.content { return !f.isExpanded } else { return false } })
        #expect(folders.first { $0.title == "Dev" }?.createdAt == added)
    }

    @Test func titlelessBookmarksAndFoldersGetSensibleNames() throws {
        var ws = Workspace.fresh()
        let id = BookmarkImporter.populate(&ws, with: [.folder("  ", children: [bm("", "https://host.example/path")])])
        let root = try pinnedRoot(ws, id)
        let folder = try #require(ws.children(of: root).first)
        #expect(folder.displayTitle == "Untitled Folder")
        #expect(ws.children(of: folder.id).first?.displayTitle == "host.example")
        #expect(ws.problems().isEmpty)
    }

    @Test func reusesTheSpaceAndAppendsAfterWhatIsThere() throws {
        var ws = Workspace.fresh()
        let existing = ws.spaces[0]
        let added = ws.addTab(url: URL(string: "https://mine.example/"), title: "Mine", under: existing.unpinnedRootID)
        let mine = try #require(added)
        ws.pin(mine)
        let id = BookmarkImporter.populate(&ws, with: [bm("X", "https://x.example/")], intoSpaceTitled: "Home")
        #expect(id == existing.id)
        #expect(ws.spaces.count == 1)
        #expect(outline(ws, existing.pinnedRootID) == "Mine,X")
        #expect(ws.problems().isEmpty)
    }

    @Test func spaceTitlesMatchIgnoringCase() throws {
        var ws = Workspace.fresh()
        let first = BookmarkImporter.populate(&ws, with: [bm("A", "https://a.example/")], intoSpaceTitled: "From Chrome")
        let second = BookmarkImporter.populate(&ws, with: [bm("B", "https://b.example/")], intoSpaceTitled: "from chrome ")
        #expect(first == second)
        #expect(ws.spaces.count == 2)
        #expect(outline(ws, try pinnedRoot(ws, first)) == "A,B")
    }

    @Test func importingTwiceDoesNotDuplicate() throws {
        var ws = Workspace.fresh()
        let tree: [BookmarkNode] = [.folder("Bar", children: [bm("A", "https://a.example/"), .folder("Dev", children: [bm("B", "https://b.example/")])]), bm("C", "https://c.example/")]
        let id = BookmarkImporter.populate(&ws, with: tree)
        let before = ws.items.count
        let again = BookmarkImporter.populateWithSummary(&ws, with: tree)
        #expect(again.spaceID == id)
        #expect(again.createdSpace == false)
        #expect(again.tabsAdded == 0)
        #expect(again.foldersAdded == 0)
        #expect(again.duplicatesSkipped == 3)
        #expect(ws.items.count == before)
        #expect(outline(ws, try pinnedRoot(ws, id)) == "Bar{A,Dev{B}},C")
    }

    @Test func sameNamedSiblingFoldersStayDistinctAndStayIdempotent() throws {
        var ws = Workspace.fresh()
        let tree: [BookmarkNode] = [.folder("Misc", children: [bm("A", "https://a.example/")]), .folder("Misc", children: [bm("B", "https://b.example/")])]
        let id = BookmarkImporter.populate(&ws, with: tree)
        let root = try pinnedRoot(ws, id)
        #expect(outline(ws, root) == "Misc{A},Misc{B}")
        BookmarkImporter.populate(&ws, with: tree)
        #expect(outline(ws, root) == "Misc{A},Misc{B}")
    }

    @Test func repeatedURLsAreKeptOncePerFolder() throws {
        var ws = Workspace.fresh()
        let summary = BookmarkImporter.populateWithSummary(&ws, with: [
            bm("One", "https://dup.example/"), bm("Two", "https://dup.example/"),
            .folder("F", children: [bm("Three", "https://dup.example/")]),
        ])
        #expect(summary.tabsAdded == 2)
        #expect(summary.duplicatesSkipped == 1)
        #expect(outline(ws, try pinnedRoot(ws, summary.spaceID)) == "One,F{Three}")
    }

    @Test func foldersDeeperThanSixLevelsFoldIntoTheirParent() throws {
        var ws = Workspace.fresh()
        // f1{ a1, f2{ a2, f3{ ... f9{ a9 } } } }
        var node: BookmarkNode = .folder("f9", children: [bm("a9", "https://a9.example/")])
        for level in stride(from: 8, through: 1, by: -1) {
            node = .folder("f\(level)", children: [bm("a\(level)", "https://a\(level).example/"), node])
        }
        let summary = BookmarkImporter.populateWithSummary(&ws, with: [node])
        let root = try pinnedRoot(ws, summary.spaceID)

        #expect(folderDepth(ws, root) == 6)
        #expect(summary.foldersAdded == 6)
        #expect(summary.tabsAdded == 9)
        #expect(summary.warnings.count == 1)
        #expect(summary.warnings[0].contains("3 folders"))
        #expect(outline(ws, root) == "f1{a1,f2{a2,f3{a3,f4{a4,f5{a5,f6{a6,a7,a8,a9}}}}}}")   // order preserved, nothing lost
        #expect(ws.problems().isEmpty)
    }

    @Test func aHugeFolderIsKeptWhole() throws {
        var ws = Workspace.fresh()
        let children = (0..<800).map { bm("Page \($0)", "https://example.com/\($0)") }
        let summary = BookmarkImporter.populateWithSummary(&ws, with: [.folder("Everything", children: children)])
        let folder = try #require(ws.children(of: try pinnedRoot(ws, summary.spaceID)).first)
        #expect(ws.children(of: folder.id).map(\.displayTitle) == (0..<800).map { "Page \($0)" })
        #expect(summary.tabsDropped == 0)
        #expect(summary.warnings.isEmpty)
        #expect(ws.problems().isEmpty)
    }

    @Test func theTotalCapStopsAtTheLimitWithAWarning() throws {
        var ws = Workspace.fresh()
        let folders = (0..<4).map { f in
            BookmarkNode.folder("F\(f)", children: (0..<30).map { bm("p\(f)-\($0)", "https://example.com/\(f)/\($0)") })
        }
        let summary = BookmarkImporter.populateWithSummary(&ws, with: folders, maxTabs: 50)
        #expect(summary.tabsAdded == 50)
        #expect(summary.tabsDropped == 70)
        #expect(summary.warnings.count == 1)
        #expect(summary.warnings[0].contains("50") && summary.warnings[0].contains("120"))
        let root = try pinnedRoot(ws, summary.spaceID)
        #expect(ws.tabs(under: root).count == 50)
        #expect(ws.tabs(under: root).first?.displayTitle == "p0-0")        // the first ones win
        #expect(ws.problems().isEmpty)
    }

    @Test func theDefaultCapIsTwentyThousandTabs() throws {
        #expect(BookmarkImporter.maxTabs == 20_000)
        #expect(BookmarkImporter.maxFolderDepth == 6)
        var ws = Workspace.fresh()
        let folders = (0..<41).map { f in
            BookmarkNode.folder("F\(f)", children: (0..<500).map { bm("p", "https://example.com/\(f)/\($0)") })
        }
        let summary = BookmarkImporter.populateWithSummary(&ws, with: folders)
        #expect(summary.tabsAdded == 20_000)
        #expect(summary.tabsDropped == 500)
        #expect(summary.warnings.first?.contains("20000") == true)
        #expect(ws.allTabs().count == 20_000)
        #expect(ws.problems().isEmpty)
    }

    @Test func aWorkspaceWithoutProfilesStillGetsASpace() throws {
        let fav = UUID()
        var ws = Workspace(profiles: [], spaces: [], favoritesRootID: fav, items: [SidebarItem(id: fav, content: .container(.favorites))])
        let id = BookmarkImporter.populate(&ws, with: [bm("A", "https://a.example/")])
        #expect(ws.profiles.count == 1)
        #expect(ws.space(id)?.profileID == ws.profiles[0].id)
        #expect(ws.problems().isEmpty)
    }

    @Test func emptyInputStillReturnsAHealthySpace() throws {
        var ws = Workspace.fresh()
        let id = BookmarkImporter.populate(&ws, with: [], intoSpaceTitled: "Safari")
        #expect(ws.space(id)?.title == "Safari")
        #expect(ws.children(of: try pinnedRoot(ws, id)).isEmpty)
        #expect(ws.problems().isEmpty)
    }

    @Test func emptyFoldersSurvive() throws {
        var ws = Workspace.fresh()
        let id = BookmarkImporter.populate(&ws, with: [.folder("Later", children: [])])
        #expect(outline(ws, try pinnedRoot(ws, id)) == "Later{}")
    }

    @Test func importsWhatTheChromiumReaderProduces() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let F = ChromiumFixture.self
        try F.makeBookmarks(at: tmp.sub("Bookmarks"),
                            bar: [F.bookmark("Top", "https://top.example/"), F.folder("Dev", [F.bookmark("Docs", "https://docs.example/")])],
                            other: [F.bookmark("Misc", "https://misc.example/")])
        let read = try ChromiumImporter.readBookmarks(profileDirectory: tmp.url)
        var ws = Workspace.fresh()
        let id = BookmarkImporter.populate(&ws, with: read.nodes, intoSpaceTitled: "Arc")
        #expect(outline(ws, try pinnedRoot(ws, id)) == "Bookmarks Bar{Top,Dev{Docs}},Other Bookmarks{Misc}")
        #expect(ws.problems().isEmpty)
    }
}
