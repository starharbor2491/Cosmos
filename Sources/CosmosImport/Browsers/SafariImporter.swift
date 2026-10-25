import Foundation
import CosmosCore

/// Safari's data lives in `~/Library/Safari`, which macOS protects: the app needs Full Disk Access, otherwise every
/// read throws `BrowserImportError.permissionDenied`.
public enum SafariImporter {
    public static func historyFile(in directory: URL) -> URL { directory.appendingPathComponent("History.db") }
    public static func bookmarksFile(in directory: URL) -> URL { directory.appendingPathComponent("Bookmarks.plist") }

    /// Reads `history_items` and `history_visits` (Core Data seconds since 2001-01-01); the title is the newest non-empty one.
    public static func readHistory(directory: URL, options: BrowserImportOptions = BrowserImportOptions()) throws -> BrowserHistoryRead {
        let file = historyFile(in: directory)
        return try DatabaseSnapshot.withDatabase(copyOf: file, workDirectory: options.workDirectory) { db in
            let tables = try BrowserSQL.tableNames(db)
            guard tables.contains("history_items"), tables.contains("history_visits") else {
                throw BrowserImportError.unreadable(path: file.path, reason: "no `history_items`/`history_visits` tables")
            }
            let succeeded = try BrowserSQL.columnNames(of: "history_visits", in: db).contains("load_successful") ? " AND v.load_successful != 0" : ""
            let select = """
                SELECT i.id, i.url, i.visit_count, MIN(v.visit_time), MAX(v.visit_time), COUNT(v.id)
                FROM history_items i JOIN history_visits v ON v.history_item = i.id
                WHERE i.id > ?1 AND \(HistorySQL.webOnly("i.url"))\(succeeded)
                GROUP BY i.id HAVING MAX(v.visit_time) >= ?3
                """
            let since = options.since?.timeIntervalSinceReferenceDate ?? -1e12
            var titles: [Int64: String] = [:]
            for r in try db.query("""
                SELECT history_item, title, MAX(visit_time) FROM history_visits WHERE title IS NOT NULL AND title != '' GROUP BY history_item
                """) {
                if let id = r[0].int64, let t = r[1].string { titles[id] = t }
            }
            var collector = HistoryCollector(now: options.now)
            func add(_ r: SQLiteDatabase.Row) {
                let id = r[0].int64 ?? 0
                collector.add(url: r[1].string, title: titles[id], visitCount: max(Int(r[2].int64 ?? 0), Int(r[5].int64 ?? 1)), typedCount: 0,
                              firstVisit: r[3].double.map { BrowserTimestamp.coreData(seconds: $0) },
                              lastVisit: r[4].double.map { BrowserTimestamp.coreData(seconds: $0) })
            }
            if let limit = options.limit {
                guard limit > 0 else { return collector.result(limit: 0) }
                for r in try db.query(select + " ORDER BY MAX(v.visit_time) DESC LIMIT ?2", [.int(0), .int(Int64(limit)), .double(since)]) { add(r) }
            } else {
                try BrowserSQL.forEachPage(db, select + " ORDER BY i.id LIMIT ?2", params: [.double(since)]) { $0.forEach(add) }
            }
            return collector.result(limit: options.limit)
        }
    }

    /// Reads `Bookmarks.plist`. Favorites and the Bookmarks Menu come through as folders; Reading List and the
    /// History proxy are left out.
    public static func readBookmarks(directory: URL) throws -> BrowserBookmarksRead {
        let file = bookmarksFile(in: directory)
        let data = try BrowserFileAccess.readData(file)
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw BrowserImportError.unreadable(path: file.path, reason: "not a Safari Bookmarks.plist")
        }
        var skipped = 0
        var nodes: [BookmarkNode] = []
        for child in plist["Children"] as? [[String: Any]] ?? [] {
            guard var folder = parse(child, skipped: &skipped, depth: 0), folder.isFolder, !folder.children.isEmpty else { continue }
            switch child["Title"] as? String {
            case "BookmarksBar": folder.title = "Favorites"
            case "BookmarksMenu": folder.title = "Bookmarks Menu"
            default: break
            }
            nodes.append(folder)
        }
        return BrowserBookmarksRead(nodes: nodes, skipped: skipped)
    }

    static func approximateCounts(directory: URL, workDirectory: URL?) -> [BrowserDataKind: Int] {
        var out: [BrowserDataKind: Int] = [:]
        if let n = try? DatabaseSnapshot.withDatabase(copyOf: historyFile(in: directory), workDirectory: workDirectory, { db in
            try BrowserSQL.scalarInt(db, "SELECT COUNT(*) FROM history_items")
        }) { out[.history] = n }
        if let read = try? readBookmarks(directory: directory) { out[.bookmarks] = read.nodes.bookmarkCount }
        return out
    }

    private static func parse(_ dict: [String: Any], skipped: inout Int, depth: Int) -> BookmarkNode? {
        switch dict["WebBookmarkType"] as? String {
        case "WebBookmarkTypeLeaf":
            if dict["ReadingList"] != nil { return nil }
            let title = ((dict["URIDictionary"] as? [String: Any])?["title"] as? String) ?? (dict["Title"] as? String) ?? ""
            guard let url = BookmarkURL.web(dict["URLString"] as? String) else { skipped += 1; return nil }
            return .bookmark(title, url: url)
        case "WebBookmarkTypeList":
            let title = (dict["Title"] as? String) ?? ""
            guard depth < 100, title != "com.apple.ReadingList" else { return nil }
            let children = (dict["Children"] as? [[String: Any]] ?? []).compactMap { parse($0, skipped: &skipped, depth: depth + 1) }
            return .folder(title, children: children)
        default:
            return nil   // WebBookmarkTypeProxy: the History entry
        }
    }
}
