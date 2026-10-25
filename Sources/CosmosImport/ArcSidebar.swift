import Foundation

// Small, lenient models of the parts of `StorableSidebar.json` the importer needs. Ids are already converted to
// UUIDs (see `ArcID`); everything else is kept as Arc wrote it and judged later by `ArcWorkspaceBuilder`.

/// Which profile a space or a Favorites container belongs to. Arc writes `{"default": true}` for the profile that
/// existed before the user made any, and a custom case carrying the profile id for the others.
enum ArcProfileKey: Hashable {
    case `default`
    case custom(UUID)

    init(_ value: Any?) {
        guard let (name, payload) = ArcJSON.enumCase(value), name != "default" else { self = .default; return }
        if let id = ArcJSON.firstString(in: payload) { self = .custom(ArcID.uuid(id)) } else { self = .default }
    }
}

struct ArcTab {
    var url: String?
    var title: String?
    var lastActiveAt: Date?
    var isMuted: Bool
}

struct ArcSplit {
    var focusID: UUID?
    /// Pane id to width factor. Arc may list only some of the panes.
    var factors: [UUID: Double]
    var orientation: String?
}

enum ArcContainerKind {
    case topApps(ArcProfileKey)
    case space(UUID)
    case other
}

enum ArcItemData {
    case tab(ArcTab)
    case folder
    case split(ArcSplit)
    case container(ArcContainerKind)
    case easel
    case unknown(String)
}

struct ArcItem {
    var id: UUID
    var parentID: UUID?
    var childIDs: [UUID]
    var title: String?
    var createdAt: Date?
    var data: ArcItemData
}

struct ArcSpace {
    var id: UUID
    var title: String?
    var iconType: Any?
    var windowTheme: Any?
    var profile: ArcProfileKey
    var pinnedRoot: UUID?
    var unpinnedRoot: UUID?
}

struct ArcSidebar {
    var items: [UUID: ArcItem] = [:]
    /// In the order of the space bar.
    var spaces: [ArcSpace] = []
    /// Roots whose children are the Favorites, default profile first.
    var favoritesRoots: [UUID] = []

    /// `root` is the decoded `StorableSidebar.json`. The local `sidebar.containers` is authoritative; Arc's sync
    /// mirror (`firebaseSyncState`) is only used for what the local container lacks, and for the order of the spaces.
    static func parse(_ root: [String: Any], notes: ImportNotes) -> ArcSidebar {
        var itemRecords: [ArcJSON.Record] = []
        var spaceRecords: [ArcJSON.Record] = []
        var topApps: [(profile: ArcProfileKey, root: UUID)] = []

        let containers = ArcJSON.list(ArcJSON.dict(root["sidebar"])?["containers"]) ?? []
        for case let container as [String: Any] in containers {
            itemRecords += ArcJSON.records(container["items"])
            spaceRecords += ArcJSON.records(container["spaces"])
            topApps += parseTopApps(container["topAppsContainerIDs"])
        }

        let syncData = ArcJSON.dict(ArcJSON.dict(root["firebaseSyncState"])?["syncData"])
        if itemRecords.isEmpty, let mirror = syncData {
            itemRecords = unwrapSync(ArcJSON.records(mirror["items"]))
            if !itemRecords.isEmpty { notes.warn("Sidebar items were read from Arc's sync mirror because the local sidebar had none") }
        }
        if spaceRecords.isEmpty, let mirror = syncData {
            spaceRecords = unwrapSync(ArcJSON.records(mirror["spaceModels"]))
            if !spaceRecords.isEmpty { notes.warn("Spaces were read from Arc's sync mirror because the local sidebar had none") }
        }

        var sidebar = ArcSidebar()
        for record in itemRecords {
            guard let item = parseItem(record) else { notes.skip("unreadableItem"); continue }
            if sidebar.items[item.id] != nil { notes.warn("Duplicate item id ignored"); continue }
            sidebar.items[item.id] = item
        }

        var spaces: [ArcSpace] = []
        var seenSpaces = Set<UUID>()
        for record in spaceRecords {
            guard let space = parseSpace(record) else { notes.skip("unreadableSpace"); continue }
            if !seenSpaces.insert(space.id).inserted { notes.warn("Duplicate space id ignored"); continue }
            spaces.append(space)
        }
        sidebar.spaces = order(spaces, root: root)

        // Favorites: every topApps container, default profile first, without duplicates.
        for item in sidebar.items.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            if case .container(.topApps(let profile)) = item.data { topApps.append((profile, item.id)) }
        }
        var seenRoots = Set<UUID>()
        let defaults = topApps.filter { $0.profile == .default }, others = topApps.filter { $0.profile != .default }
        for entry in defaults + others where seenRoots.insert(entry.root).inserted { sidebar.favoritesRoots.append(entry.root) }
        if sidebar.favoritesRoots.count > 1 { notes.warn("More than one Favorites container found; merged into one") }
        return sidebar
    }

    // MARK: Items

    static func parseItem(_ record: ArcJSON.Record) -> ArcItem? {
        let d = record.value
        guard let raw = (d["id"] as? String) ?? record.key, !raw.isEmpty else { return nil }
        let childIDs = (ArcJSON.list(d["childrenIds"]) ?? ArcJSON.list(d["childrenIDs"]) ?? []).compactMap { ArcID.optional($0) }
        return ArcItem(id: ArcID.uuid(raw), parentID: ArcID.optional(d["parentID"]), childIDs: childIDs,
                       title: ArcJSON.string(d["title"]), createdAt: ArcJSON.date(d["createdAt"]), data: parseData(d["data"]))
    }

    private static func parseData(_ value: Any?) -> ArcItemData {
        guard let (name, payload) = ArcJSON.enumCase(value) else { return .unknown("missing") }
        let p = ArcJSON.dict(payload) ?? [:]
        switch name {
        case "tab":
            let status = (p["savedMuteStatus"] as? String)?.lowercased() ?? ""
            return .tab(ArcTab(url: p["savedURL"] as? String, title: ArcJSON.string(p["savedTitle"]),
                               lastActiveAt: ArcJSON.date(p["timeLastActiveAt"]), isMuted: status == "mute" || status == "muted"))
        case "list":
            return .folder
        case "splitView":
            var factors: [UUID: Double] = [:]
            for (k, v) in ArcJSON.pairs(p["itemWidthFactors"]) {
                if let id = ArcID.optional(k), let f = ArcJSON.number(v) { factors[id] = f }
            }
            return .split(ArcSplit(focusID: ArcID.optional(p["focusItemID"]), factors: factors, orientation: ArcJSON.string(p["layoutOrientation"])))
        case "itemContainer":
            guard let (type, typePayload) = ArcJSON.enumCase(p["containerType"]) else { return .container(.other) }
            switch type {
            case "spaceItems":
                if let id = ArcID.optional(ArcJSON.unwrap(typePayload)) { return .container(.space(id)) }
                return .container(.other)
            case "topApps":
                return .container(.topApps(ArcProfileKey(ArcJSON.unwrap(typePayload))))
            default:
                return .container(.other)
            }
        case "easel":
            return .easel
        default:
            return .unknown(ArcJSON.safeCaseName(name))
        }
    }

    /// `topAppsContainerIDs` is a dictionary keyed by profile: `[{"default": true}, "<rootID>"]`.
    private static func parseTopApps(_ value: Any?) -> [(profile: ArcProfileKey, root: UUID)] {
        guard let a = value as? [Any] else { return [] }
        var out: [(profile: ArcProfileKey, root: UUID)] = []
        var i = 0
        while i < a.count {
            if !(a[i] is String), i + 1 < a.count, let id = ArcID.optional(a[i + 1]) {
                out.append((ArcProfileKey(a[i]), id)); i += 2
            } else if let id = ArcID.optional(a[i]) {
                out.append((.default, id)); i += 1
            } else {
                i += 1
            }
        }
        return out
    }

    // MARK: Spaces

    private static func parseSpace(_ record: ArcJSON.Record) -> ArcSpace? {
        let d = record.value
        guard let raw = (d["id"] as? String) ?? record.key, !raw.isEmpty else { return nil }
        let info = ArcJSON.dict(d["customInfo"])
        var roots = sectionRoots(d["containerIDs"])
        let newer = sectionRoots(d["newContainerIDs"])
        if roots.pinned == nil { roots.pinned = newer.pinned }
        if roots.unpinned == nil { roots.unpinned = newer.unpinned }
        return ArcSpace(id: ArcID.uuid(raw), title: ArcJSON.string(d["title"]), iconType: info?["iconType"], windowTheme: info?["windowTheme"],
                        profile: ArcProfileKey(d["profile"]), pinnedRoot: roots.pinned, unpinnedRoot: roots.unpinned)
    }

    /// `containerIDs` is `["pinned", id, "unpinned", id]`; `newContainerIDs` uses enum keys: `[{"pinned": {}}, id, ...]`.
    private static func sectionRoots(_ value: Any?) -> (pinned: UUID?, unpinned: UUID?) {
        var result: (pinned: UUID?, unpinned: UUID?) = (nil, nil)
        for (key, id) in ArcJSON.pairs(value) {
            let name = (key as? String) ?? ArcJSON.enumCase(key)?.name
            guard let uuid = ArcID.optional(id) else { continue }
            if name == "pinned", result.pinned == nil { result.pinned = uuid }
            if name == "unpinned", result.unpinned == nil { result.unpinned = uuid }
        }
        return result
    }

    /// The order of the space bar. Arc's local container stores spaces as a dictionary (no meaningful order), but both
    /// sync mirrors keep `orderedSpaceIDs`; the most recently changed one wins. Spaces it does not mention follow in
    /// their stored order.
    private static func order(_ spaces: [ArcSpace], root: [String: Any]) -> [ArcSpace] {
        var candidates: [(stamp: Double, ids: [UUID])] = []
        let firebase = ArcJSON.dict(ArcJSON.dict(ArcJSON.dict(root["firebaseSyncState"])?["syncData"])?["orderedSpaceIDs"])
        if let ids = ArcJSON.list(firebase?["value"]) {
            candidates.append((ArcJSON.number(firebase?["lastChangeDate"]) ?? -.infinity, ids.compactMap { ArcID.optional($0) }))
        }
        let cloud = ArcJSON.dict(root["sidebarSyncState"])
        if let ids = ArcJSON.list(ArcJSON.dict(ArcJSON.dict(cloud?["container"])?["value"])?["orderedSpaceIDs"]) {
            candidates.append((ArcJSON.number(cloud?["lastSuccessfulSyncDate"]) ?? -.infinity, ids.compactMap { ArcID.optional($0) }))
        }
        guard let best = candidates.max(by: { $0.stamp < $1.stamp }) else { return spaces }
        let byID = Dictionary(spaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered: [ArcSpace] = []
        var placed = Set<UUID>()
        for id in best.ids { if let s = byID[id], placed.insert(id).inserted { ordered.append(s) } }
        return ordered + spaces.filter { !placed.contains($0.id) }
    }

    /// Sync records are wrapped as `{value, lastChangeDate, lastChangedDevice}`.
    private static func unwrapSync(_ records: [ArcJSON.Record]) -> [ArcJSON.Record] {
        records.map { record in
            if let inner = record.value["value"] as? [String: Any] { return (key: record.key, value: inner) }
            return record
        }
    }
}
