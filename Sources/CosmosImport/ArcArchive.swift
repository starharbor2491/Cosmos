import Foundation
import CosmosCore

/// `StorableArchiveItems.json`: tabs Arc archived. Each entry holds `archivedAt`, a `reason`, a `source` (the space it
/// came from, or `littleArc`) and the original sidebar item.
enum ArcArchive {
    /// Newest first. Every entry becomes an `ArchivedItem` with reason `.imported` and a one-node subtree. Archived
    /// Easels, folders and other non-tab items are counted as skipped.
    static func parse(_ root: Any?, spaceIDs: Set<UUID>, now: Date, notes: ImportNotes) -> [ArchivedItem] {
        guard let file = ArcJSON.dict(root) else { return [] }
        var entries: [ArchivedItem] = []
        var usedIDs = Set<UUID>()
        var orphaned = 0

        for record in ArcJSON.records(file["items"]) {
            guard let sidebarItem = ArcJSON.dict(record.value["sidebarItem"]),
                  let item = ArcSidebar.parseItem((key: record.key, value: sidebarItem)) else {
                notes.skip("archive.unreadable")
                continue
            }
            let tab: ArcTab
            switch item.data {
            case .tab(let t): tab = t
            case .easel: notes.skip("archive.easel"); continue
            case .folder: notes.skip("archive.folder"); continue
            case .split: notes.skip("archive.splitView"); continue
            case .container: notes.skip("archive.container"); continue
            case .unknown(let name): notes.skip("archive.unknown:\(name)"); continue
            }
            guard let url = ArcJSON.url(tab.url) else {
                notes.skip("archive.tabWithoutValidURL")
                continue
            }
            guard !ArcJSON.isInternal(url) else {
                notes.skip("archive.internalPage")
                continue
            }

            var id = item.id
            var n = 1
            while !usedIDs.insert(id).inserted {
                id = ArcID.uuid("\(item.id.uuidString)#\(n)")
                n += 1
            }

            var spaceID: UUID?
            if let (kind, payload) = ArcJSON.enumCase(record.value["source"]), kind == "space" {
                if let candidate = ArcID.optional(ArcJSON.firstString(in: payload)), spaceIDs.contains(candidate) {
                    spaceID = candidate
                } else {
                    orphaned += 1
                }
            }

            let node = SidebarItem(id: id, title: item.title, createdAt: item.createdAt ?? tab.lastActiveAt ?? now,
                                   content: .tab(TabData(url: url, pageTitle: tab.title, lastActiveAt: tab.lastActiveAt, isMuted: tab.isMuted)))
            entries.append(ArchivedItem(id: id, archivedAt: ArcJSON.date(record.value["archivedAt"]) ?? now, reason: .imported,
                                        spaceID: spaceID, items: [node]))
        }
        notes.warn("Archived items from a space that no longer exists were imported without a space", orphaned)
        return entries.sorted { $0.archivedAt != $1.archivedAt ? $0.archivedAt > $1.archivedAt : $0.id.uuidString < $1.id.uuidString }
    }
}
