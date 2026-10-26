import Foundation
import Testing
import CosmosCore
@testable import CosmosImport

// Tests of the Arc importer against a synthetic profile (see ArcFixture). Swift Testing's #expect wraps its argument
// in a closure, so nothing here calls a mutating method on a local var inside one: values are computed first.

struct TestFailure: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

private func uuid(_ n: Int) -> UUID { UUID(uuidString: ArcFixture.id(n))! }
private func ids(_ items: [SidebarItem]) -> [UUID] { items.map(\.id) }
private func close(_ a: RGBA, _ b: RGBA) -> Bool { abs(a.r - b.r) < 1e-9 && abs(a.g - b.g) < 1e-9 && abs(a.b - b.b) < 1e-9 && abs(a.a - b.a) < 1e-9 }
private func close(_ a: [Double], _ b: [Double]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-9 } }

private func splitData(_ ws: Workspace, _ n: Int) throws -> SplitData {
    let item = try #require(ws.item(uuid(n)))
    guard case .split(let data) = item.content else { throw TestFailure("item \(n) is not a split") }
    return data
}

private func folderExpanded(_ ws: Workspace, _ n: Int) throws -> Bool {
    let item = try #require(ws.item(uuid(n)))
    guard case .folder(let data) = item.content else { throw TestFailure("item \(n) is not a folder") }
    return data.isExpanded
}

@Suite struct ArcImporterTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func importFixture(files: ArcFixture.Files = .all, sidebar: [String: Any]? = nil) throws -> ArcImportResult {
        let dir = try ArcFixture.makeProfile(files: files, sidebar: sidebar)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try ArcImporter.importProfile(at: dir, now: now)
    }

    // MARK: Locating and rejecting profiles

    @Test func profileDetectionAndDefaultDirectory() throws {
        let dir = try ArcFixture.makeProfile(files: [])
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = try ArcFixture.tempDirectory()
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(ArcImporter.hasProfile(at: dir))
        #expect(!ArcImporter.hasProfile(at: empty))
        #expect(ArcImporter.defaultDirectory.path.hasSuffix("Library/Application Support/Arc"))
    }

    @Test func missingSidebarFileThrows() throws {
        let empty = try ArcFixture.tempDirectory()
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: ArcImportError.profileNotFound) { try ArcImporter.importProfile(at: empty) }
    }

    @Test func malformedSidebarFilesThrow() throws {
        let dir = try ArcFixture.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("StorableSidebar.json")
        try Data("{ not json".utf8).write(to: file)
        #expect(throws: ArcImportError.malformed(file: "StorableSidebar.json", reason: "not valid JSON")) { try ArcImporter.importProfile(at: dir) }
        try Data("[1, 2]".utf8).write(to: file)
        #expect(throws: ArcImportError.malformed(file: "StorableSidebar.json", reason: "the top level is not an object")) { try ArcImporter.importProfile(at: dir) }
    }

    @Test func aProfileWithoutSpacesThrows() throws {
        let sidebar: [String: Any] = ["version": 1, "sidebar": ["containers": [["items": [Any](), "spaces": [Any]()]]]]
        let dir = try ArcFixture.makeProfile(files: [], sidebar: sidebar)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: ArcImportError.noSpaces) { try ArcImporter.importProfile(at: dir) }
    }

    // MARK: Spaces, profiles, themes

    @Test func spacesFollowTheSyncMirrorOrderAndKeepTheirDetails() throws {
        let ws = try importFixture().workspace
        #expect(ws.spaces.map(\.title) == ["Personal", "Work"])
        #expect(ws.spaces[0].id == ArcID.uuid(ArcFixture.s1))
        #expect(ws.spaces[1].id == uuid(2))
        #expect(ws.spaces[0].icon == .symbol("globe.americas.fill"))
        #expect(ws.spaces[1].icon == .emoji("🚀"))
        #expect(ws.spaces[0].pinnedRootID == ArcID.uuid(ArcFixture.s1Pinned))
        #expect(ws.spaces[1].unpinnedRootID == uuid(6))
        #expect(ws.problems().isEmpty)
    }

    @Test func profilesComeFromTheProfileFileOrAreNamedGenerically() throws {
        let named = try importFixture().workspace
        #expect(named.profiles.map(\.name) == ["Personal", "Work Profile"])
        #expect(named.profile(named.spaces[0].profileID)?.isDefault == true)
        #expect(named.profile(named.spaces[1].profileID)?.name == "Work Profile")

        let unnamed = try importFixture(files: [])
        #expect(unnamed.workspace.profiles.map(\.name) == ["Personal", "Profile 2"])
        #expect(unnamed.report.warnings.contains { $0.contains("profile") })
    }

    @Test func themesAreDerivedFromArcGradients() throws {
        let ws = try importFixture().workspace
        let personal = ws.spaces[0].theme, work = ws.spaces[1].theme

        #expect(personal.name == "Imported")
        #expect(personal.starfield == 0.5)
        #expect(personal.angle == 135)
        #expect(personal.appearance == .dark)
        #expect(personal.intensity == 1)
        #expect(personal.grain == 0)
        #expect(personal.colors.count == 2)
        #expect(close(personal.colors[0], RGBA(0.2, 0.3, 0.8)))                      // overlay alpha 0: untouched
        #expect(close(personal.colors[1], RGBA(0.475, 0.375, 0.8)))                  // a quarter of the way to the overlay

        #expect(work.appearance == .light)
        #expect(work.intensity == 0.6)
        #expect(work.grain == 0.4)
        #expect(work.colors.count == 3)
        #expect(close(work.colors[0], RGBA(0.3, 0.475, 0.65)))                       // overlay alpha 0.5: an eighth of the way
        #expect(close(work.colors[1], RGBA(0, 0.5, 0.5)))                            // extended sRGB clamped
        #expect(close(work.colors[2], RGBA(0.9, 0.9, 1)))
    }

    @Test func themeFallbacksAndLimits() {
        let notes = ImportNotes()
        let none = ArcSpaceStyle.theme(from: nil, notes: notes)
        #expect(none.name == "Imported")
        #expect(none.starfield == 0.5)

        func gradient(_ colors: [[String: Any]]) -> [String: Any] {
            ["background": ["single": ["_0": ["style": ["color": ["_0": ["blendedGradient": ["_0": ["baseColors": colors]]]]]]]]]
        }
        let seven = (0..<7).map { ArcFixture.color(Double($0) / 10, 0, 0) }
        let sampled = ArcSpaceStyle.theme(from: gradient(seven), notes: notes)
        #expect(sampled.colors.count == 4)
        #expect(sampled.colors.first?.r == 0)
        #expect(sampled.colors.last?.r == 0.6)
        #expect(sampled.intensity == SpaceTheme.nebula.intensity)

        let palette: [String: Any] = ["primaryColorPalette": ["midTone": ArcFixture.color(0.4, 0.4, 0.4)]]
        let fromPalette = ArcSpaceStyle.theme(from: palette, notes: notes)
        #expect(fromPalette.colors.count == 1)
        #expect(fromPalette.angle == 135)
        #expect(!notes.warnings.isEmpty)
    }

    @Test func iconsMapToSymbolsAndEmoji() {
        let notes = ImportNotes()
        #expect(ArcSpaceStyle.icon(from: ["icon": "sunny"], notes: notes) == .symbol("sun.max.fill"))
        #expect(ArcSpaceStyle.icon(from: ["icon": "pizza"], notes: notes) == .emoji("🍕"))
        #expect(ArcSpaceStyle.icon(from: ["icon": "star.fill"], notes: notes) == .symbol("star.fill"))
        #expect(ArcSpaceStyle.icon(from: ["emoji": "🪐"], notes: notes) == .emoji("🪐"))
        #expect(ArcSpaceStyle.icon(from: ["emoji_v2": [128640]], notes: notes) == .emoji("🚀"))
        #expect(ArcSpaceStyle.icon(from: ["emoji_v2": ["_0": 128640]], notes: notes) == .emoji("🚀"))
        #expect(notes.warnings.isEmpty)
        #expect(ArcSpaceStyle.icon(from: ["icon": "notARealIcon"], notes: notes) == .symbol("moon.stars.fill"))
        #expect(ArcSpaceStyle.icon(from: nil, notes: notes) == .symbol("moon.stars.fill"))
        #expect(notes.warnings.count == 1)
    }

    // MARK: Tree

    @Test func favoritesAreTabsOnlyAndRememberTheirHome() throws {
        let r = try importFixture()
        let favorites = r.workspace.favorites
        #expect(ids(favorites) == [uuid(11), uuid(12), uuid(14)])                    // the folder's tab took the folder's place
        #expect(favorites.allSatisfy { $0.isTab })
        #expect(favorites.allSatisfy { $0.tab?.homeURL != nil && $0.tab?.homeURL == $0.tab?.url })
        #expect(r.report.warnings.contains { $0.contains("folder in Favorites") })
    }

    @Test func pinnedSectionKeepsFoldersSplitsAndOrder() throws {
        let ws = try importFixture().workspace
        let space = ws.spaces[0]
        // 20 Dev folder, 30 split, 40 split + its fifth pane beside it, 51 the single pane of a dissolved split, 70 Loop folder.
        #expect(ids(ws.pinned(in: space)) == [uuid(20), uuid(30), uuid(40), uuid(45), uuid(51), uuid(70)])
        #expect(ids(ws.children(of: uuid(20))) == [uuid(21), uuid(22), uuid(23)])
        #expect(ids(ws.children(of: uuid(22))) == [uuid(24), uuid(25)])
        #expect(ws.item(uuid(20))?.title == "Dev")
        #expect(ws.item(uuid(22))?.title == "Docs")
        #expect(ws.item(uuid(24))?.parentID == uuid(22))
        let pinnedTabs = ws.tabs(under: space.pinnedRootID)
        #expect(!pinnedTabs.isEmpty)
        #expect(pinnedTabs.allSatisfy { $0.tab?.homeURL == $0.tab?.url })
        #expect(ws.section(of: uuid(24)) == .pinned(spaceID: space.id))
    }

    @Test func folderExpansionComesFromTheWindowFile() throws {
        let withWindows = try importFixture().workspace
        #expect(try folderExpanded(withWindows, 20))
        #expect(try !folderExpanded(withWindows, 22))
        #expect(try !folderExpanded(withWindows, 70))

        let without = try importFixture(files: []).workspace
        #expect(try folderExpanded(without, 20))
    }

    @Test func todayFlattensFoldersAndHasNoHomeURL() throws {
        let ws = try importFixture().workspace
        let space = ws.spaces[0]
        #expect(ids(ws.unpinned(in: space)) == [uuid(80), uuid(82), uuid(83), uuid(84)])
        #expect(ws.unpinned(in: space).allSatisfy { $0.tab?.homeURL == nil })
        #expect(ws.item(uuid(81)) == nil)
        #expect(ws.item(uuid(80))?.tab?.url?.absoluteString == "https://example.com/today")    // the duplicate record lost
        let report = try importFixture().report
        #expect(report.warnings.contains { $0.contains("folder in Today") })
    }

    @Test func splitViewsMapOrientationFocusAndWeights() throws {
        let ws = try importFixture().workspace
        let two = try splitData(ws, 30)
        #expect(two.orientation == .horizontal)
        #expect(two.focusedChildID == uuid(32))
        #expect(close(two.weights, [0.3, 0.7]))                                      // only the first pane was listed
        #expect(ids(ws.children(of: uuid(30))) == [uuid(31), uuid(32)])

        let five = try splitData(ws, 40)
        #expect(five.orientation == .vertical)
        #expect(five.focusedChildID == uuid(43))
        #expect(close(five.weights, [0.25, 0.25, 0.25, 0.25]))
        #expect(ids(ws.children(of: uuid(40))) == [uuid(41), uuid(42), uuid(43), uuid(44)])
        #expect(ws.item(uuid(45))?.parentID == ws.spaces[0].pinnedRootID)            // the fifth pane sits next to the split
        #expect(ws.item(uuid(45))?.isTab == true)

        #expect(ws.item(uuid(50)) == nil)                                            // a one-pane split is just its tab
        #expect(ws.item(uuid(51))?.parentID == ws.spaces[0].pinnedRootID)
    }

    @Test func brokenReferencesNeverBreakTheTree() throws {
        let r = try importFixture()
        let ws = r.workspace
        #expect(ws.problems().isEmpty)
        #expect(ws.item(uuid(71))?.childIDs == [])                                   // the cycle's back edge was dropped
        #expect(ws.item(uuid(70))?.childIDs == [uuid(71)])
        #expect(ws.item(uuid(94)) == nil)                                            // the orphan was not imported
        #expect(ws.item(uuid(99)) == nil)
        #expect(ws.item(uuid(93))?.parentID == ws.spaces[1].unpinnedRootID)          // attached through its parent link
        #expect(ids(ws.pinned(in: ws.spaces[1])) == [uuid(90), uuid(91)])
        #expect(ids(ws.unpinned(in: ws.spaces[1])) == [uuid(92), uuid(93)])          // 91 was listed twice and kept once
        let text = r.report.warnings.joined(separator: "\n")
        #expect(text.contains("missing item"))
        #expect(text.contains("reachable more than once"))
        #expect(text.contains("Duplicate item id"))
        #expect(text.contains("parent link"))
    }

    @Test func easelsAndUnknownItemsAreSkippedAndCounted() throws {
        let r = try importFixture()
        #expect(r.report.skipped["easel"] == 1)
        #expect(r.report.skipped["unknown:somethingNew"] == 1)
        #expect(r.report.skipped["tabWithoutValidURL"] == 1)
        #expect(r.report.skipped["unreachableItem"] == 1)
        #expect(r.report.skipped["archive.easel"] == 1)
        #expect(r.report.skipped["archive.tabWithoutValidURL"] == 1)
        #expect(r.report.skipped["archive.internalPage"] == 1)
        #expect(r.report.skipped["linkRule"] == 1)
        #expect(r.report.skippedTotal == 8)
        #expect(r.workspace.items.values.allSatisfy { if case .unsupported = $0.content { return false } else { return true } })
    }

    // MARK: Tabs

    @Test func tabFieldsAreConverted() throws {
        let ws = try importFixture().workspace
        let tab = try #require(ws.item(uuid(23)))
        #expect(tab.title == "Renamed")                                              // user-chosen title
        #expect(tab.tab?.pageTitle == "Page 23")                                     // the page's own title
        #expect(tab.tab?.isMuted == true)
        #expect(tab.createdAt == Date(timeIntervalSinceReferenceDate: ArcFixture.base + 23))
        #expect(tab.tab?.lastActiveAt == Date(timeIntervalSinceReferenceDate: ArcFixture.base + 5000))
        #expect(tab.createdAt.timeIntervalSince1970 == ArcFixture.base + 23 + 978_307_200)   // 2001 epoch to Unix

        let plain = try #require(ws.item(uuid(21)))
        #expect(plain.title == nil)
        #expect(plain.tab?.isMuted == false)
        #expect(plain.tab?.url?.absoluteString == "https://example.com/dev")
        #expect(plain.tab?.lastActiveAt == nil)

        let fromWindows = try #require(ws.item(uuid(82)))                           // no own date: Arc's window file has one
        #expect(fromWindows.tab?.lastActiveAt == Date(timeIntervalSinceReferenceDate: ArcFixture.base + 7777))
    }

    @Test func idsAreStableAndCaseInsensitive() {
        let upper = "AAAAAAAA-0000-4000-8000-000000000001"
        #expect(ArcID.uuid(upper) == ArcID.uuid(upper.lowercased()))
        #expect(ArcID.uuid(upper).uuidString == upper)
        let derived = ArcID.uuid(ArcFixture.s1)
        #expect(derived == ArcID.uuid(ArcFixture.s1))
        #expect(derived != ArcID.uuid(ArcFixture.s1Pinned))
        #expect(Array(derived.uuidString)[14] == "5")                               // a name-based (v5 style) UUID
    }

    // MARK: Other files

    @Test func archiveIsMappedNewestFirst() throws {
        let r = try importFixture()
        #expect(r.archive.map(\.id) == [uuid(202), uuid(205), uuid(201)])
        #expect(r.archive.allSatisfy { $0.reason == .imported && $0.items.count == 1 && $0.items[0].parentID == nil && $0.items[0].childIDs.isEmpty })
        let kept = r.archive[2]
        #expect(kept.spaceID == ArcID.uuid(ArcFixture.s1))
        #expect(kept.url?.absoluteString == "https://example.com/archived-1")
        #expect(kept.title == "Kept")
        #expect(kept.archivedAt == Date(timeIntervalSinceReferenceDate: ArcFixture.archivedAt1))
        #expect(r.archive[0].spaceID == nil)                                        // Little Arc has no space
        #expect(r.archive[1].spaceID == nil)                                        // its space no longer exists
        #expect(r.report.warnings.contains { $0.contains("no longer exists") })

        let without = try importFixture(files: [])
        #expect(without.archive.isEmpty)
    }

    @Test func focusedSpaceComesFromTheWindowFile() throws {
        #expect(try importFixture().focusedSpaceID == uuid(2))
        #expect(try importFixture(files: []).focusedSpaceID == nil)
    }

    @Test func linkRoutingIsMapped() throws {
        let r = try importFixture()
        let routing = try #require(r.linkRouting)
        #expect(routing.defaultDestination == .probe)
        #expect(routing.rules.count == 2)
        #expect(routing.rules[0].matches == [.urlContains("meet.example")])
        #expect(routing.rules[0].destination == .mostRecentSpace)
        #expect(routing.rules[1].matches == [.urlContains("git"), .host("github.com")])
        #expect(routing.rules[1].destination == .space(uuid(2)))
        #expect(routing.destination(for: URL(string: "https://meet.example/room")!) == .mostRecentSpace)
        #expect(routing.destination(for: URL(string: "https://github.com/x")!) == .space(uuid(2)))
        #expect(routing.destination(for: URL(string: "https://elsewhere.org")!) == .probe)
        #expect(try importFixture(files: []).linkRouting == nil)
    }

    @Test func linkMatchKindsMapToCosmosMatches() {
        let notes = ImportNotes()
        func routing(_ kind: String, _ text: String) -> LinkRouting? {
            let rule: [String: Any] = ["id": ArcFixture.id(1), "destination": ["littleArc": ["_0": ["mostRecent": [String: Any]()]]],
                                       "sourceComponents": [["componentType": ["urlMatch": ["_0": [kind: [String: Any]()], "_1": text]]]]]
            return ArcLinkRouting.parse(["rules": [rule]], spaceIDs: [], firstSpaceByProfile: [:], notes: notes)
        }
        #expect(routing("startsWith", "https://a.example")?.rules.first?.matches == [.urlPrefix("https://a.example")])
        #expect(routing("endsWith", ".pdf")?.rules.first?.matches == [.urlSuffix(".pdf")])
        #expect(routing("matches", "Example.com")?.rules.first?.matches == [.host("example.com")])
        #expect(routing("matches", "^https://.*$")?.rules.isEmpty == true)
        #expect(routing("somethingElse", "x")?.rules.isEmpty == true)
        #expect(notes.skipped["linkRule"] == 2)
    }

    @Test func internalPagesAreWarnedAboutInTheSidebar() throws {
        let sidebar = ArcFixture.miniSidebar(urls: ["https://a.example/", "chrome-extension://abc/page.html", "arc://settings"])
        let r = try importFixture(files: [], sidebar: sidebar)
        #expect(r.report.unpinnedTabs == 3)
        #expect(r.report.warnings.contains { $0.contains("internal pages") && $0.hasSuffix("(x2)") })
    }

    @Test func absurdlyDeepNestingIsCutOffInsteadOfOverflowingTheStack() throws {
        let sidebar = ArcFixture.miniSidebar(urls: ["https://a.example/"], nestedFolders: 150)
        let r = try importFixture(files: [], sidebar: sidebar)
        #expect(r.workspace.problems().isEmpty)
        #expect((r.report.skipped["tooDeeplyNested"] ?? 0) == 1)
        #expect(r.report.folders == 40)
        #expect(r.report.tabs == 0)
    }

    @Test func aDamagedSideFileDoesNotBlockTheImport() throws {
        let dir = try ArcFixture.makeProfile(files: [.archive])
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{ broken".utf8).write(to: dir.appendingPathComponent("StorableWindows.json"))
        let r = try ArcImporter.importProfile(at: dir, now: now)
        #expect(r.workspace.problems().isEmpty)
        #expect(r.focusedSpaceID == nil)
        #expect(r.report.warnings.contains("StorableWindows.json could not be read and was skipped"))
        #expect(r.archive.count == 3)
    }

    @Test func boostsFilesAreReportedNotSilentlyIgnored() throws {
        let dir = try ArcFixture.makeProfile(files: [])
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{\"version\": 1}".utf8).write(to: dir.appendingPathComponent("StorableBoostsData.json"))
        let r = try ArcImporter.importProfile(at: dir, now: now)
        #expect(r.boosts.isEmpty)
        #expect(r.report.skipped["boostsFile"] == 1)
        #expect(r.report.warnings.contains { $0.contains("Boost") })
    }

    @Test func theSyncMirrorIsUsedWhenTheLocalSidebarIsEmpty() throws {
        func wrapped(_ record: [String: Any]) -> Any { ["value": record, "lastChangeDate": 1.0, "lastChangedDevice": ArcFixture.id(0)] }
        let pinned = ArcFixture.id(501), unpinned = ArcFixture.id(502), spaceID = ArcFixture.id(500)
        var root = ArcFixture.container(pinned, spaceID: spaceID)
        root.children = []
        var today = ArcFixture.container(unpinned, spaceID: spaceID)
        today.children = [ArcFixture.id(503)]
        let tab = ArcFixture.tab(503, parent: unpinned)
        let items = ArcFixture.flat([(pinned, wrapped(root.json)), (unpinned, wrapped(today.json)), (tab.id, wrapped(tab.json))])
        let space = ArcFixture.spaceRecord(id: spaceID, title: "Mirror", icon: ["icon": "moon"], profile: ["default": true], pinned: pinned, unpinned: unpinned, theme: [:])
        let sidebar: [String: Any] = ["sidebar": ["containers": [["global": [String: Any]()]]],
                                      "firebaseSyncState": ["syncData": ["items": items, "spaceModels": ArcFixture.flat([(spaceID, wrapped(space))])]]]
        let r = try importFixture(files: [], sidebar: sidebar)
        #expect(r.workspace.spaces.map(\.title) == ["Mirror"])
        #expect(r.report.tabs == 1)
        #expect(r.report.unpinnedTabs == 1)
        #expect(r.report.warnings.contains { $0.contains("sync mirror") })
        #expect(r.workspace.problems().isEmpty)
    }

    // MARK: Report and persistence

    @Test func reportNumbersMatchTheFixture() throws {
        let report = try importFixture().report
        #expect(report.spaces == 2)
        #expect(report.profiles == 2)
        #expect(report.favorites == 3)
        #expect(report.pinnedTabs == 14)
        #expect(report.unpinnedTabs == 6)
        #expect(report.tabs == 23)
        #expect(report.folders == 4)                                                 // Dev, Docs, Loop, Loop back
        #expect(report.splitViews == 2)
        #expect(report.archivedItems == 3)
        #expect(report.linkRules == 2)
        #expect(report.boosts == 0)
    }

    @Test func reportsContainNoPersonalData() throws {
        let report = try importFixture().report
        let text = ([report.summary] + report.warnings + report.skipped.keys).joined(separator: "\n")
        for secret in ["example", "Renamed", "Dev", "Docs", "Loop", "Work", "Personal", "Kept", "Easel", "meet.", "github"] {
            #expect(!text.contains(secret), "report leaked \(secret)")
        }
        #expect(report.summary.contains("Tabs: 23"))
        #expect(report.summary.contains("Skipped:"))
        let decoded = try JSONDecoder().decode(ImportReport.self, from: JSONEncoder().encode(report))
        #expect(decoded == report)
    }

    @Test func reportSummaryListsSkippedKindsInOrder() {
        let report = ImportReport(spaces: 1, warnings: ["a"], skipped: ["z": 2, "easel": 3])
        #expect(report.summary.contains("Skipped: easel x3, z x2"))
        #expect(report.summary.contains("Warnings: 1"))
        #expect(ImportReport().summary.contains("Spaces: 0"))
        #expect(!ImportReport().summary.contains("Skipped"))
    }

    @Test func importedDataRoundTripsThroughCosmosJSON() throws {
        let r = try importFixture()
        let workspace = try JSONDecoder.cosmos.decode(Workspace.self, from: JSONEncoder.cosmos.encode(r.workspace))
        #expect(workspace == r.workspace)
        let archive = ArchiveData(entries: r.archive)
        #expect(try JSONDecoder.cosmos.decode(ArchiveData.self, from: JSONEncoder.cosmos.encode(archive)) == archive)
        let routing = try #require(r.linkRouting)
        #expect(try JSONDecoder.cosmos.decode(LinkRouting.self, from: JSONEncoder.cosmos.encode(routing)) == routing)
    }

    @Test func importingTwiceGivesTheSameResult() throws {
        let dir = try ArcFixture.makeProfile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try ArcImporter.importProfile(at: dir, now: now)
        let b = try ArcImporter.importProfile(at: dir, now: now)
        #expect(a == b)
    }

    @Test func writeCreatesTheDataFilesAndProtectsExistingOnes() throws {
        let r = try importFixture()
        let out = try ArcFixture.tempDirectory()
        defer { try? FileManager.default.removeItem(at: out) }

        let files = try r.write(to: out)
        #expect(files == ArcImportResult.fileNames)
        #expect(try JSONFileStore<Workspace>(url: out.appendingPathComponent("workspace.json")).load() == r.workspace)
        #expect(try JSONFileStore<ArchiveData>(url: out.appendingPathComponent("archive.json")).load()?.entries.count == 3)
        #expect(try JSONFileStore<BoostLibrary>(url: out.appendingPathComponent("boosts.json")).load() == BoostLibrary())
        #expect(try JSONFileStore<LinkRouting>(url: out.appendingPathComponent("link-routing.json")).load() == r.linkRouting)

        #expect(throws: ArcImportError.workspaceExists) { try r.write(to: out) }
        try r.write(to: out, force: true)
        #expect(JSONFileStore<Workspace>(url: out.appendingPathComponent("workspace.json")).backups().count == 1)
    }

    @Test func writeSkipsLinkRoutingWhenTheProfileHasNone() throws {
        let r = try importFixture(files: [])
        let out = try ArcFixture.tempDirectory()
        defer { try? FileManager.default.removeItem(at: out) }
        let files = try r.write(to: out)
        #expect(files == ["workspace.json", "archive.json", "boosts.json"])
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("link-routing.json").path))
    }

    // MARK: Real profile (opt in)

    /// Imports the real `~/Library/Application Support/Arc` read-only. Prints counts only.
    /// Run with `COSMOS_REAL_ARC=1 scripts/test.sh --filter realProfile`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COSMOS_REAL_ARC"] == "1", "set COSMOS_REAL_ARC=1 to import the real Arc profile (read-only)"))
    func realProfileIsStructurallyHealthy() throws {
        let directory = ArcImporter.defaultDirectory
        try #require(ArcImporter.hasProfile(at: directory), "no Arc profile on this machine")
        let result = try ArcImporter.importProfile(at: directory)
        let ws = result.workspace
        #expect(ws.problems().isEmpty)
        #expect(result.report.spaces > 0)
        #expect(result.report.tabs > 0)
        #expect(ws.spaces.count == result.report.spaces)
        let decoded = try JSONDecoder.cosmos.decode(Workspace.self, from: JSONEncoder.cosmos.encode(ws))
        #expect(decoded == ws)
        #expect(result.archive.allSatisfy { $0.reason == .imported })
        print("[real Arc profile]\n" + result.report.summary)
    }
}
