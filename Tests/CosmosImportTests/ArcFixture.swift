import Foundation

/// Writes a synthetic Arc profile that follows Arc's real encoding conventions (observed in a real profile, with
/// invented content): `[ID: Value]` dictionaries as flat key/value arrays, dates as seconds since 2001, enums with
/// payloads as one-key objects, non-UUID ids for the default space, a sync mirror that carries the space order.
///
/// The sidebar it produces contains, on purpose: two spaces and two profiles, favorites (one inside a folder),
/// pinned folders nested two deep, a two-pane split with a partial width list, a five-pane split, a one-pane split,
/// an easel, an unknown item kind, a tab without a URL, a dangling child id, a cycle, a duplicate item record, an
/// item listed by two parents, an unlisted child, an orphan and a folder inside Today.
enum ArcFixture {
    static let base: Double = 800_000_000

    static let s1 = "thebrowser.company.defaultPersonalSpaceID"
    static let s1Pinned = "thebrowser.company.defaultPersonalSpacePinnedContainerID"
    static let s1Unpinned = "thebrowser.company.defaultPersonalSpaceUnpinnedContainerID"
    static let s2 = id(2), s2Pinned = id(5), s2Unpinned = id(6)
    static let profile2 = id(3)
    static let favoritesRoot = id(10)

    /// Uppercase UUID strings, as Arc writes them.
    static func id(_ n: Int) -> String { String(format: "AAAAAAAA-0000-4000-8000-%012X", n) }

    // MARK: Items

    struct Node {
        var id: String
        var parent: String?
        var children: [String] = []
        var title: String?
        var created: Double?
        var data: [String: Any]

        var json: [String: Any] {
            var d: [String: Any] = [
                "id": id, "parentID": parent ?? NSNull(), "childrenIds": children, "title": title ?? NSNull(),
                "isUnread": false, "originatingDevice": ArcFixture.id(0), "data": data,
            ]
            if let created { d["createdAt"] = created }
            return d
        }
    }

    static func tab(_ n: Int, parent: String?, url: String? = nil, pageTitle: String? = nil, title: String? = nil, mute: Bool = false,
                    active: Double? = nil, noURL: Bool = false) -> Node {
        var payload: [String: Any] = ["savedMuteStatus": mute ? "mute" : "allowAudio", "activeTabBeforeCreationID": id(0)]
        if !noURL { payload["savedURL"] = url ?? "https://example.com/\(n)" }
        payload["savedTitle"] = pageTitle ?? "Page \(n)"
        if let active { payload["timeLastActiveAt"] = active }
        return Node(id: id(n), parent: parent, title: title, created: base + Double(n), data: ["tab": payload])
    }

    static func folder(_ n: Int, parent: String?, title: String?, children: [String]) -> Node {
        Node(id: id(n), parent: parent, children: children, title: title, created: base + Double(n), data: ["list": [String: Any]()])
    }

    static func split(_ n: Int, parent: String?, panes: [String], focus: String?, orientation: String = "horizontal", factors: [(String, Double)]) -> Node {
        var payload: [String: Any] = ["layoutOrientation": orientation, "timeLastActiveAt": base, "customInfo": NSNull(),
                                      "itemWidthFactors": factors.flatMap { [$0.0 as Any, $0.1 as Any] }]
        if let focus { payload["focusItemID"] = focus }
        return Node(id: id(n), parent: parent, children: panes, created: base + Double(n), data: ["splitView": payload])
    }

    static func easel(_ n: Int, parent: String?) -> Node {
        Node(id: id(n), parent: parent, title: "Easel", created: base + Double(n),
             data: ["easel": ["easelID": id(0), "title": "Easel", "shareStatus": "private", "creatorID": "x", "timeLastActiveAt": base]])
    }

    static func container(_ rawID: String, spaceID: String) -> Node {
        Node(id: rawID, parent: nil, created: base, data: ["itemContainer": ["containerType": ["spaceItems": ["_0": spaceID]]]])
    }

    static func topAppsContainer(_ rawID: String) -> Node {
        Node(id: rawID, parent: nil, created: base, data: ["itemContainer": ["containerType": ["topApps": ["_0": ["default": true]]]]])
    }

    static func flat(_ pairs: [(String, Any)]) -> [Any] { pairs.flatMap { [$0.0 as Any, $0.1] } }

    /// All items of the fixture sidebar. Root children are filled in by `itemRecords()`.
    static func nodes() -> [Node] {
        let p = s1Pinned, u = s1Unpinned
        var all: [Node] = []

        // Favorites
        all += [topAppsContainer(favoritesRoot), tab(11, parent: favoritesRoot), tab(12, parent: favoritesRoot)]
        all += [folder(13, parent: favoritesRoot, title: "Fav folder", children: [id(14)]), tab(14, parent: id(13))]

        // Space 1, Pinned
        all += [container(s1Pinned, spaceID: s1)]
        all += [folder(20, parent: p, title: "Dev", children: [id(21), id(22), id(23), id(99)])]                 // id(99) does not exist
        all += [tab(21, parent: id(20), url: "https://example.com/dev")]
        all += [folder(22, parent: id(20), title: "Docs", children: [id(24).lowercased(), id(25)])]               // lower-case reference
        all += [tab(23, parent: id(20), title: "Renamed", mute: true, active: base + 5000), tab(24, parent: id(22)), tab(25, parent: id(22))]
        all += [split(30, parent: p, panes: [id(31), id(32)], focus: id(32), factors: [(id(31), 0.3)]), tab(31, parent: id(30)), tab(32, parent: id(30))]
        all += [split(40, parent: p, panes: (41...45).map { id($0) }, focus: id(43), orientation: "vertical", factors: (41...45).map { (id($0), 0.2) })]
        all += (41...45).map { tab($0, parent: id(40)) }
        all += [split(50, parent: p, panes: [id(51)], focus: id(51), factors: []), tab(51, parent: id(50))]
        all += [easel(60, parent: p)]
        all += [Node(id: id(61), parent: p, created: base + 61, data: ["somethingNew": ["_0": "x"]])]
        all += [tab(62, parent: p, noURL: true)]
        all += [folder(70, parent: p, title: "Loop", children: [id(71)]), folder(71, parent: id(70), title: "Loop back", children: [id(70)])]   // cycle

        // Space 1, Today
        all += [container(s1Unpinned, spaceID: s1), tab(80, parent: u, url: "https://example.com/today")]
        all += [folder(81, parent: u, title: "Today folder", children: [id(82), id(83)])]                         // folders are not allowed here
        all += [tab(82, parent: id(81)), tab(83, parent: id(81)), tab(84, parent: u)]

        // Space 2
        all += [container(s2Pinned, spaceID: s2), container(s2Unpinned, spaceID: s2)]
        all += [tab(90, parent: s2Pinned), tab(91, parent: s2Pinned), tab(92, parent: s2Unpinned)]
        all += [tab(93, parent: s2Unpinned)]                                                                        // listed by nobody; parentID names its section
        all += [tab(94, parent: "not-an-item")]                                                                    // orphan
        return all
    }

    /// Children of the roots, which are not derivable from the nodes themselves because several are deliberately wrong.
    static func rootChildren() -> [String: [String]] {
        [
            favoritesRoot: [id(11), id(12), id(13)],
            s1Pinned: [id(20), id(30), id(40), id(50), id(60), id(61), id(62), id(70)],
            s1Unpinned: [id(80), id(81), id(84)],
            s2Pinned: [id(90), id(91)],
            s2Unpinned: [id(92), id(91)],                                                                     // 91 is also listed by s2Pinned
        ]
    }

    static func itemRecords() -> [Any] {
        let children = rootChildren()
        var records: [(String, Any)] = []
        for var node in nodes() {
            if let kids = children[node.id] { node.children = kids }
            records.append((node.id, node.json))
        }
        // A second record for the same id (Arc never does this; the importer must keep the first).
        records.append((id(80), tab(80, parent: s1Unpinned, url: "https://example.com/duplicate").json))
        return flat(records)
    }

    // MARK: Spaces

    static func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> [String: Any] {
        ["red": r, "green": g, "blue": b, "alpha": a, "colorSpace": "extendedSRGB"]
    }

    static func windowTheme(base: [[String: Any]], overlay: [[String: Any]], intensity: Double, noise: Double, appearance: String) -> [String: Any] {
        let gradient: [String: Any] = ["baseColors": base, "overlayColors": overlay, "wheel": ["analogous": [String: Any]()],
                                       "modifiers": ["intensityFactor": intensity, "noiseFactor": noise, "overlay": "grain"], "translucencyStyle": "light"]
        return [
            "background": ["single": ["_0": ["style": ["color": ["_0": ["blendedGradient": ["_0": gradient]]]],
                                             "contentOverBackgroundAppearance": appearance, "isVibrant": true]]],
            "primaryColorPalette": ["midTone": color(0.5, 0.5, 0.5), "shaded": color(0.3, 0.3, 0.3), "shadedDark": color(0.1, 0.1, 0.1), "tintedLight": color(0.9, 0.9, 0.9)],
        ]
    }

    static func spaceRecord(id: String, title: String, icon: [String: Any], profile: [String: Any], pinned: String, unpinned: String,
                            theme: [String: Any]) -> [String: Any] {
        [
            "id": id, "title": title, "profile": profile,
            "containerIDs": ["unpinned", unpinned, "pinned", pinned],
            "newContainerIDs": [["unpinned": ["_0": ["shared": [String: Any]()]]], unpinned, ["pinned": [String: Any]()], pinned],
            "customInfo": ["iconType": icon, "windowTheme": theme],
        ]
    }

    static func spaces() -> [Any] {
        let personal = spaceRecord(
            id: s1, title: "Personal", icon: ["icon": "planet"], profile: ["default": true], pinned: s1Pinned, unpinned: s1Unpinned,
            theme: windowTheme(base: [color(0.2, 0.3, 0.8), color(0.6, 0.3, 0.8)], overlay: [color(0, 0, 0, 0), color(0.1, 0.6, 0.8)],
                               intensity: 1, noise: 0, appearance: "dark"))
        let work = spaceRecord(
            id: s2, title: "Work", icon: ["emoji": "🚀"], profile: ["custom": ["_0": profile2]], pinned: s2Pinned, unpinned: s2Unpinned,
            theme: windowTheme(base: [color(0.2, 0.4, 0.6), color(-0.1, 0.5, 0.5), color(0.9, 0.9, 1.4)], overlay: [color(1, 1, 1, 0.5)],
                               intensity: 0.6, noise: 0.4, appearance: "light"))
        // Stored order is the reverse of the real order: only the sync mirror knows the order of the space bar.
        return flat([(s2, work), (s1, personal)])
    }

    static func sidebar() -> [String: Any] {
        [
            "version": 1,
            "sidebar": ["containers": [["global": [String: Any]()],
                                       ["items": itemRecords(), "spaces": spaces(), "topAppsContainerIDs": [["default": true], favoritesRoot]]]],
            "firebaseSyncState": ["syncData": ["orderedSpaceIDs": ["value": [s1, s2], "lastChangeDate": 1000.0, "lastChangedDevice": id(0)],
                                               "items": [Any](), "spaceModels": [Any](), "dataEra": 0],
                                  "lastSyncedTimestamp": base],
            "sidebarSyncState": ["container": ["value": ["orderedSpaceIDs": [s2, s1]]], "lastSuccessfulSyncDate": 500.0],
        ]
    }

    // MARK: Other files

    /// A one-space sidebar whose Today section holds one tab per URL, optionally wrapped in `folders` nested pinned folders
    /// with the first tab at the bottom.
    static func miniSidebar(urls: [String], nestedFolders: Int = 0) -> [String: Any] {
        let spaceID = id(500), pinned = id(501), unpinned = id(502)
        var nodes = [container(pinned, spaceID: spaceID), container(unpinned, spaceID: spaceID)]
        if nestedFolders > 0 {
            nodes[0].children = [id(700)]
            for i in 0..<nestedFolders {
                let isLast = i == nestedFolders - 1
                nodes.append(folder(700 + i, parent: i == 0 ? pinned : id(699 + i), title: "Level \(i)", children: [isLast ? id(600) : id(701 + i)]))
            }
            nodes.append(tab(600, parent: id(700 + nestedFolders - 1), url: urls.first))
        } else {
            nodes[1].children = urls.indices.map { id(600 + $0) }
            for (i, url) in urls.enumerated() { nodes.append(tab(600 + i, parent: unpinned, url: url)) }
        }
        let space = spaceRecord(id: spaceID, title: "Mini", icon: ["icon": "moon"], profile: ["default": true], pinned: pinned, unpinned: unpinned, theme: [:])
        return ["version": 1, "sidebar": ["containers": [["global": [String: Any]()],
                                                         ["items": flat(nodes.map { ($0.id, $0.json) }), "spaces": flat([(spaceID, space)]),
                                                          "topAppsContainerIDs": [Any]()]]]]
    }

    static func windows() -> [String: Any] {
        ["version": 1, "lastFocusedSpaceID": s2,
         "windows": [["id": id(0), "focusedSpaceID": s2, "expandedItems": [id(20)], "sidebarMode": "anchored", "sidebarWidth": 227,
                      "itemLastActiveDates": flat([(id(82), base + 7777.0)]), "itemCreatedDates": [Any]()]]]
    }

    static let archivedAt1 = base + 100_000, archivedAt2 = base + 200_000, archivedAt3 = base + 150_000

    static func archiveItems() -> [String: Any] {
        func entry(source: [String: Any], at: Double, item: Node) -> (String, Any) {
            (item.id, ["archivedAt": at, "reason": "manual", "source": source, "sidebarItem": item.json])
        }
        let records: [(String, Any)] = [
            entry(source: ["space": ["_0": s1]], at: archivedAt1, item: tab(201, parent: nil, url: "https://example.com/archived-1", title: "Kept")),
            entry(source: ["littleArc": [String: Any]()], at: archivedAt2, item: tab(202, parent: nil, url: "https://example.com/archived-2")),
            entry(source: ["space": ["_0": s1]], at: archivedAt1, item: easel(203, parent: nil)),
            entry(source: ["space": ["_0": s1]], at: archivedAt1, item: tab(204, parent: nil, noURL: true)),
            entry(source: ["space": ["_0": id(999)]], at: archivedAt3, item: tab(205, parent: nil, url: "https://example.com/archived-5")),
            entry(source: ["space": ["_0": s1]], at: archivedAt1, item: tab(206, parent: nil, url: "arc://newtab")),
        ]
        return ["version": 1, "items": flat(records)]
    }

    static func linkRouting() -> [String: Any] {
        func rule(_ n: Int, components: [[String: Any]], destination: [String: Any]) -> [String: Any] {
            ["id": id(300 + n), "sourceComponents": components, "destination": destination]
        }
        func urlMatch(_ kind: String, _ text: String) -> [String: Any] {
            ["id": id(0), "componentType": ["urlMatch": ["_0": [kind: [String: Any]()], "_1": text]]]
        }
        return [
            "version": 1,
            "defaultDestination": ["littleArc": ["_0": ["mostRecent": [String: Any]()]]],
            "rules": [
                rule(1, components: [urlMatch("contains", "meet.example")], destination: ["space": ["_0": ["mostRecent": [String: Any]()]]]),
                rule(2, components: [urlMatch("contains", "git"), urlMatch("matches", "github.com")],
                     destination: ["space": ["_0": ["profile": ["_0": profile2]]]]),
                rule(3, components: [["id": id(0), "componentType": ["sourceApp": ["_0": "com.example.app"]]]],
                     destination: ["littleArc": ["_0": ["mostRecent": [String: Any]()]]]),
            ],
        ]
    }

    static func profiles() -> [String: Any] {
        ["version": 1, "profiles": flat([(profile2, ["id": profile2, "name": "Work Profile"] as [String: Any])])]
    }

    // MARK: Writing

    struct Files: OptionSet {
        let rawValue: Int
        static let windows = Files(rawValue: 1), archive = Files(rawValue: 2), linkRouting = Files(rawValue: 4), profiles = Files(rawValue: 8)
        static let all: Files = [.windows, .archive, .linkRouting, .profiles]
    }

    static func write(_ json: Any, as name: String, in dir: URL) throws {
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: dir.appendingPathComponent(name))
    }

    /// A temp directory holding the fixture profile. Remove it with `FileManager.removeItem` (or let the OS).
    static func makeProfile(files: Files = .all, sidebar: [String: Any]? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-arc-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write(sidebar ?? self.sidebar(), as: "StorableSidebar.json", in: dir)
        if files.contains(.windows) { try write(windows(), as: "StorableWindows.json", in: dir) }
        if files.contains(.archive) { try write(archiveItems(), as: "StorableArchiveItems.json", in: dir) }
        if files.contains(.linkRouting) { try write(linkRouting(), as: "StorableLinkRouting.json", in: dir) }
        if files.contains(.profiles) { try write(profiles(), as: "StorableProfiles.json", in: dir) }
        return dir
    }

    static func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-arc-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
