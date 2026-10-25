import Foundation
import CosmosCore

/// Firefox keeps history and bookmarks together in the profile's `places.sqlite` (WAL mode, usually open).
public enum FirefoxImporter {
    public static func placesFile(in profileDirectory: URL) -> URL { profileDirectory.appendingPathComponent("places.sqlite") }

    public static func readHistory(profileDirectory: URL, options: BrowserImportOptions = BrowserImportOptions()) throws -> BrowserHistoryRead {
        try read(profileDirectory: profileDirectory, options: BrowserImportOptions(history: true, bookmarks: false, since: options.since,
                                                                                  limit: options.limit, workDirectory: options.workDirectory, now: options.now)).history ?? .empty
    }

    public static func readBookmarks(profileDirectory: URL, options: BrowserImportOptions = BrowserImportOptions()) throws -> BrowserBookmarksRead {
        try read(profileDirectory: profileDirectory, options: BrowserImportOptions(history: false, bookmarks: true, workDirectory: options.workDirectory,
                                                                                  now: options.now)).bookmarks ?? BrowserBookmarksRead(nodes: [], skipped: 0)
    }

    /// Reads what `options` asks for from one snapshot of `places.sqlite`.
    public static func read(profileDirectory: URL, options: BrowserImportOptions) throws -> (history: BrowserHistoryRead?, bookmarks: BrowserBookmarksRead?) {
        let file = placesFile(in: profileDirectory)
        return try DatabaseSnapshot.withDatabase(copyOf: file, workDirectory: options.workDirectory) { db in
            let tables = try BrowserSQL.tableNames(db)
            guard tables.contains("moz_places") else { throw BrowserImportError.unreadable(path: file.path, reason: "no `moz_places` table") }
            let history = options.history ? try historyRows(db, tables: tables, options: options) : nil
            let bookmarks = options.bookmarks && tables.contains("moz_bookmarks") ? try bookmarkTree(db, now: options.now) : nil
            return (history, bookmarks)
        }
    }

    static func approximateCounts(profileDirectory: URL, workDirectory: URL?) -> [BrowserDataKind: Int] {
        var out: [BrowserDataKind: Int] = [:]
        _ = try? DatabaseSnapshot.withDatabase(copyOf: placesFile(in: profileDirectory), workDirectory: workDirectory) { db in
            out[.history] = try? BrowserSQL.scalarInt(db, "SELECT COUNT(*) FROM moz_places WHERE visit_count > 0 AND last_visit_date IS NOT NULL")
            out[.bookmarks] = try? BrowserSQL.scalarInt(db, """
                SELECT COUNT(*) FROM moz_bookmarks WHERE type = 1 AND fk IS NOT NULL AND parent NOT IN
                    (SELECT id FROM moz_bookmarks WHERE parent = (SELECT id FROM moz_bookmarks WHERE guid = 'tags________'))
                """)
        }
        return out
    }

    // MARK: History

    private static func historyRows(_ db: SQLiteDatabase, tables: Set<String>, options: BrowserImportOptions) throws -> BrowserHistoryRead {
        let visits = tables.contains("moz_historyvisits")
        let typed = visits ? "MAX(p.typed, (SELECT COUNT(*) FROM moz_historyvisits t WHERE t.place_id = p.id AND t.visit_type = 2))" : "p.typed"
        let first = visits ? "(SELECT MIN(f.visit_date) FROM moz_historyvisits f WHERE f.place_id = p.id)" : "NULL"
        let select = """
            SELECT p.id, p.url, p.title, p.visit_count, \(typed), p.last_visit_date, \(first)
            FROM moz_places p
            WHERE p.visit_count > 0 AND p.hidden = 0 AND \(HistorySQL.webOnly("p.url")) AND p.last_visit_date >= ?3 AND p.id > ?1
            """
        let since = Int64(options.since.map(BrowserTimestamp.unixMicroseconds(from:)) ?? 1)
        var collector = HistoryCollector(now: options.now)
        func add(_ r: SQLiteDatabase.Row) {
            collector.add(url: r[1].string, title: r[2].string, visitCount: Int(r[3].int64 ?? 1), typedCount: Int(r[4].int64 ?? 0),
                          firstVisit: r[6].int64.map(BrowserTimestamp.unix(microseconds:)),
                          lastVisit: r[5].int64.map(BrowserTimestamp.unix(microseconds:)))
        }
        if let limit = options.limit {
            guard limit > 0 else { return collector.result(limit: 0) }
            for r in try db.query(select + " ORDER BY p.last_visit_date DESC LIMIT ?2", [.int(0), .int(Int64(limit)), .int(since)]) { add(r) }
        } else {
            try BrowserSQL.forEachPage(db, select + " ORDER BY p.id LIMIT ?2", params: [.int(since)]) { $0.forEach(add) }
        }
        return collector.result(limit: options.limit)
    }

    // MARK: Bookmarks

    private struct Row {
        var id: Int64, type: Int64, parent: Int64
        var title: String, url: String?, guid: String
        var dateAdded: Int64?
    }

    private static let rootGUID = "root________"
    private static let tagsGUID = "tags________"
    private static let rootNames = [
        "toolbar_____": "Bookmarks Toolbar", "menu________": "Bookmarks Menu",
        "unfiled_____": "Other Bookmarks", "mobile______": "Mobile Bookmarks",
    ]

    private static func bookmarkTree(_ db: SQLiteDatabase, now: Date) throws -> BrowserBookmarksRead {
        let rows = try db.query("""
            SELECT b.id, b.type, b.parent, COALESCE(b.title, p.title, ''), p.url, b.guid, b.dateAdded
            FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk ORDER BY b.parent, b.position
            """).compactMap { r -> Row? in
            guard r.count >= 7, let id = r[0].int64, let type = r[1].int64, let parent = r[2].int64, let guid = r[5].string else { return nil }
            return Row(id: id, type: type, parent: parent, title: r[3].string ?? "", url: r[4].string, guid: guid, dateAdded: r[6].int64)
        }
        let byParent = Dictionary(grouping: rows, by: \.parent)
        guard let root = rows.first(where: { $0.guid == rootGUID }) else { return BrowserBookmarksRead(nodes: [], skipped: 0) }

        var skipped = 0
        var seen: Set<Int64> = [root.id]
        func node(_ row: Row, depth: Int) -> BookmarkNode? {
            let added = BrowserTimestamp.sanitized(row.dateAdded.map { BrowserTimestamp.unix(microseconds: $0) }, now: now)
            switch row.type {
            case 1:
                guard let url = BookmarkURL.web(row.url) else { skipped += 1; return nil }
                return .bookmark(row.title, url: url, dateAdded: added)
            case 2:
                guard depth < 100, seen.insert(row.id).inserted else { return nil }
                return .folder(row.title, dateAdded: added, children: (byParent[row.id] ?? []).compactMap { node($0, depth: depth + 1) })
            default:
                return nil   // separators
            }
        }
        var nodes: [BookmarkNode] = []
        for top in byParent[root.id] ?? [] where top.guid != tagsGUID && top.type == 2 {
            guard var folder = node(top, depth: 1), !folder.children.isEmpty else { continue }
            folder.title = rootNames[top.guid] ?? folder.title
            folder.dateAdded = nil
            nodes.append(folder)
        }
        return BrowserBookmarksRead(nodes: nodes, skipped: skipped)
    }
}
