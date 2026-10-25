import Foundation
import CosmosCore

public struct BrowserBookmarksRead: Sendable {
    public var nodes: [BookmarkNode]
    /// Bookmarks that are not web pages (`javascript:` bookmarklets, `chrome://` pages, ...).
    public var skipped: Int
}

/// Chrome, Arc, Brave, Edge, Vivaldi, Opera and Chromium share one profile layout: a `History` SQLite database
/// and a `Bookmarks` JSON file in the profile directory.
public enum ChromiumImporter {
    public static func historyFile(in profileDirectory: URL) -> URL { profileDirectory.appendingPathComponent("History") }
    public static func bookmarksFile(in profileDirectory: URL) -> URL { profileDirectory.appendingPathComponent("Bookmarks") }

    /// Reads `urls` (with the first visit from `visits` when present). Works from a private copy of the database.
    public static func readHistory(profileDirectory: URL, options: BrowserImportOptions = BrowserImportOptions()) throws -> BrowserHistoryRead {
        let file = historyFile(in: profileDirectory)
        return try DatabaseSnapshot.withDatabase(copyOf: file, workDirectory: options.workDirectory) { db in
            let tables = try BrowserSQL.tableNames(db)
            guard tables.contains("urls") else { throw BrowserImportError.unreadable(path: file.path, reason: "no `urls` table") }
            let firstVisit = tables.contains("visits") ? "(SELECT MIN(v.visit_time) FROM visits v WHERE v.url = u.id)" : "NULL"
            let visible = try BrowserSQL.columnNames(of: "urls", in: db).contains("hidden") ? " AND u.hidden = 0" : ""
            let select = """
                SELECT u.id, u.url, u.title, u.visit_count, u.typed_count, u.last_visit_time, \(firstVisit)
                FROM urls u WHERE \(HistorySQL.webOnly("u.url"))\(visible) AND u.last_visit_time >= ?3 AND u.id > ?1
                """
            let since = Int64(options.since.map(BrowserTimestamp.chromiumMicroseconds(from:)) ?? 1)
            var collector = HistoryCollector(now: options.now)
            func add(_ r: SQLiteDatabase.Row) {
                collector.add(url: r[1].string, title: r[2].string, visitCount: Int(r[3].int64 ?? 1), typedCount: Int(r[4].int64 ?? 0),
                              firstVisit: r[6].int64.map(BrowserTimestamp.chromium(microseconds:)),
                              lastVisit: r[5].int64.map(BrowserTimestamp.chromium(microseconds:)))
            }
            if let limit = options.limit {
                guard limit > 0 else { return collector.result(limit: 0) }
                for r in try db.query(select + " ORDER BY u.last_visit_time DESC LIMIT ?2", [.int(0), .int(Int64(limit)), .int(since)]) { add(r) }
            } else {
                try BrowserSQL.forEachPage(db, select + " ORDER BY u.id LIMIT ?2", params: [.int(since)]) { $0.forEach(add) }
            }
            return collector.result(limit: options.limit)
        }
    }

    /// Reads `roots.bookmark_bar|other|synced` into one top-level folder each (empty ones are left out).
    public static func readBookmarks(profileDirectory: URL, now: Date = Date()) throws -> BrowserBookmarksRead {
        let file = bookmarksFile(in: profileDirectory)
        let data = try BrowserFileAccess.readData(file)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let roots = root["roots"] as? [String: Any] else {
            throw BrowserImportError.unreadable(path: file.path, reason: "not a Chromium Bookmarks file")
        }
        var skipped = 0
        var nodes: [BookmarkNode] = []
        for (key, title) in [("bookmark_bar", "Bookmarks Bar"), ("other", "Other Bookmarks"), ("synced", "Mobile Bookmarks")] {
            guard let dict = roots[key] as? [String: Any],
                  let node = parse(dict, now: now, skipped: &skipped, depth: 0), node.isFolder, !node.children.isEmpty else { continue }
            var named = node
            named.title = title
            named.dateAdded = nil
            nodes.append(named)
        }
        return BrowserBookmarksRead(nodes: nodes, skipped: skipped)
    }

    /// Row counts for the profile picker: `COUNT(*)` on `urls`, and the bookmark leaves in the JSON.
    static func approximateCounts(profileDirectory: URL, workDirectory: URL?) -> [BrowserDataKind: Int] {
        var out: [BrowserDataKind: Int] = [:]
        if let n = try? DatabaseSnapshot.withDatabase(copyOf: historyFile(in: profileDirectory), workDirectory: workDirectory, { db in
            try BrowserSQL.scalarInt(db, "SELECT COUNT(*) FROM urls")
        }) { out[.history] = n }
        if let read = try? readBookmarks(profileDirectory: profileDirectory) { out[.bookmarks] = read.nodes.bookmarkCount }
        return out
    }

    private static let maxDepth = 100

    private static func parse(_ dict: [String: Any], now: Date, skipped: inout Int, depth: Int) -> BookmarkNode? {
        let title = (dict["name"] as? String) ?? ""
        let added = microseconds(dict["date_added"]).map { BrowserTimestamp.chromium(microseconds: $0) }
        let dateAdded = BrowserTimestamp.sanitized(added, now: now)
        switch dict["type"] as? String {
        case "url":
            guard let url = BookmarkURL.web(dict["url"] as? String) else { skipped += 1; return nil }
            return .bookmark(title, url: url, dateAdded: dateAdded)
        case "folder":
            guard depth < maxDepth else { return nil }
            let children = (dict["children"] as? [[String: Any]] ?? []).compactMap { parse($0, now: now, skipped: &skipped, depth: depth + 1) }
            return .folder(title, dateAdded: dateAdded, children: children)
        default:
            return nil
        }
    }

    /// `date_added` is a decimal string in current Chromium, a number in some forks.
    private static func microseconds(_ value: Any?) -> Int64? {
        if let s = value as? String { return Int64(s) }
        if let n = value as? NSNumber { return n.int64Value }
        return nil
    }
}

enum BookmarkURL {
    /// The URL when it is a web page worth pinning; `nil` for `javascript:`, `chrome://`, `place:`, `file:` and so on.
    static func web(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
