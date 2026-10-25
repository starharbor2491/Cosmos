import Foundation
import CosmosCore
@testable import CosmosImport

/// A scratch directory removed by `remove()` (call it in a `defer`: ARC may release the object early).
final class BrowserTempDir {
    let url: URL

    init(_ label: String = "cosmos-browsers") throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func sub(_ path: String, isDirectory: Bool = false) -> URL { url.appendingPathComponent(path, isDirectory: isDirectory) }

    @discardableResult
    func makeDirectory(_ path: String) throws -> URL {
        let u = sub(path, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func remove() {
        // Fixtures chmod files and folders to 000 to provoke permission errors; make everything removable first.
        func unlock(_ u: URL) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: u.path)
            for child in (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [] { unlock(child) }
        }
        unlock(url)
        try? FileManager.default.removeItem(at: url)
    }

    func names(in path: String = "") -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent(path).path)) ?? []).sorted()
    }
}

/// Independent re-implementations of the browsers' epochs, so the tests do not share a bug with the code under test.
enum BrowserEpoch {
    static func chromiumMicros(unix seconds: Int64, micros: Int64 = 0) -> Int64 { (seconds + 11_644_473_600) * 1_000_000 + micros }
    static func firefoxMicros(unix seconds: Int64, micros: Int64 = 0) -> Int64 { seconds * 1_000_000 + micros }
    static func safariSeconds(unix seconds: Double) -> Double { seconds - 978_307_200 }
}

func browserDate(_ unix: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(unix)) }

// MARK: - Chromium

struct ChromiumRow {
    var url: String
    var title: String = ""
    var visitCount = 1
    var typedCount = 0
    var lastVisit: Int64
    var hidden = 0
    /// `visits.visit_time` values (Chromium microseconds).
    var visits: [Int64] = []
}

enum ChromiumFixture {
    /// The real `urls` / `visits` / `meta` schema of Chromium 15x (as found in Arc's `History`).
    static func makeHistory(at url: URL, rows: [ChromiumRow], withVisitsTable: Bool = true) throws {
        let db = try SQLiteDatabase(path: url.path)
        try db.execute("""
            CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
            CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT,url LONGVARCHAR,title LONGVARCHAR,visit_count INTEGER DEFAULT 0 NOT NULL,typed_count INTEGER DEFAULT 0 NOT NULL,last_visit_time INTEGER NOT NULL,hidden INTEGER DEFAULT 0 NOT NULL);
            """)
        if withVisitsTable {
            try db.execute("""
                CREATE TABLE visits(id INTEGER PRIMARY KEY AUTOINCREMENT,url INTEGER NOT NULL,visit_time INTEGER NOT NULL,from_visit INTEGER,external_referrer_url TEXT,transition INTEGER DEFAULT 0 NOT NULL,segment_id INTEGER,visit_duration INTEGER DEFAULT 0 NOT NULL,incremented_omnibox_typed_score BOOLEAN DEFAULT FALSE NOT NULL,opener_visit INTEGER,originator_cache_guid TEXT,originator_visit_id INTEGER,originator_from_visit INTEGER,originator_opener_visit INTEGER,is_known_to_sync BOOLEAN DEFAULT FALSE NOT NULL,consider_for_ntp_most_visited BOOLEAN DEFAULT FALSE NOT NULL,visited_link_id INTEGER DEFAULT 0 NOT NULL,app_id TEXT);
                CREATE INDEX visits_url_index ON visits (url);
                """)
        }
        try db.transaction {
            for r in rows {
                try db.run("INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time, hidden) VALUES (?, ?, ?, ?, ?, ?)",
                           [.text(r.url), .text(r.title), .int(Int64(r.visitCount)), .int(Int64(r.typedCount)), .int(r.lastVisit), .int(Int64(r.hidden))])
                guard withVisitsTable, !r.visits.isEmpty else { continue }
                let id = try BrowserSQL.scalarInt(db, "SELECT last_insert_rowid()")
                for v in r.visits { try db.run("INSERT INTO visits (url, visit_time) VALUES (?, ?)", [.int(Int64(id)), .int(v)]) }
            }
        }
    }

    // MARK: Bookmarks JSON

    static func bookmark(_ name: String, _ url: String, added: Any = "0") -> [String: Any] {
        ["type": "url", "name": name, "url": url, "date_added": added, "guid": UUID().uuidString, "id": "1"]
    }

    static func folder(_ name: String, _ children: [[String: Any]], added: Any = "0") -> [String: Any] {
        ["type": "folder", "name": name, "children": children, "date_added": added, "date_modified": "0", "guid": UUID().uuidString, "id": "1"]
    }

    static func makeBookmarks(at url: URL, bar: [[String: Any]] = [], other: [[String: Any]] = [], synced: [[String: Any]] = []) throws {
        let json: [String: Any] = [
            "checksum": "00000000000000000000000000000000", "version": 1,
            "roots": [
                "bookmark_bar": folder("Bookmarks bar", bar), "other": folder("Other bookmarks", other), "synced": folder("Mobile bookmarks", synced),
            ],
        ]
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
    }

    static func makeLocalState(at url: URL, profiles: [String: String], lastUsed: String? = nil) throws {
        var profile: [String: Any] = ["info_cache": profiles.mapValues { ["name": $0, "gaia_name": ""] }]
        if let lastUsed { profile["last_used"] = lastUsed }
        try JSONSerialization.data(withJSONObject: ["profile": profile]).write(to: url)
    }

    /// A complete profile directory: `History` plus `Bookmarks`.
    @discardableResult
    static func makeProfile(at dir: URL, rows: [ChromiumRow], bar: [[String: Any]]? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try makeHistory(at: dir.appendingPathComponent("History"), rows: rows)
        if let bar { try makeBookmarks(at: dir.appendingPathComponent("Bookmarks"), bar: bar) }
        return dir
    }
}

// MARK: - Firefox

enum FirefoxFixture {
    struct Place {
        var url: String
        var title: String?
        var visitCount = 1
        var hidden = 0
        var typed = 0
        var lastVisit: Int64?
        /// `(visit_date, visit_type)` rows in `moz_historyvisits`.
        var visits: [(Int64, Int)] = []
    }

    /// `(id, type, fk, parent, position, title, dateAdded, guid)` for `moz_bookmarks`.
    struct BookmarkRow {
        var id: Int, type: Int, fk: Int?, parent: Int, position: Int, title: String?, dateAdded: Int64 = 0, guid: String
    }

    /// The real places schema (the columns the importer cares about plus the usual neighbours), in WAL mode as Firefox runs it.
    static func create(at url: URL, places: [Place], bookmarks: [BookmarkRow] = [], placeIDs: [Int]? = nil) throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: url.path)
        try db.execute("PRAGMA journal_mode=WAL")
        try db.execute("""
            CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, rev_host LONGVARCHAR, visit_count INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0 NOT NULL, typed INTEGER DEFAULT 0 NOT NULL, frecency INTEGER DEFAULT -1 NOT NULL, last_visit_date INTEGER, guid TEXT, foreign_count INTEGER DEFAULT 0 NOT NULL, url_hash INTEGER DEFAULT 0 NOT NULL, description TEXT, preview_image_url TEXT, site_name TEXT, origin_id INTEGER, recalc_frecency INTEGER NOT NULL DEFAULT 0, alt_frecency INTEGER, recalc_alt_frecency INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE moz_historyvisits (id INTEGER PRIMARY KEY, from_visit INTEGER, place_id INTEGER, visit_date INTEGER, visit_type INTEGER, session INTEGER, source INTEGER DEFAULT 0 NOT NULL, triggeringPlaceId INTEGER);
            CREATE INDEX moz_historyvisits_placedateindex ON moz_historyvisits (place_id, visit_date);
            CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER DEFAULT NULL, parent INTEGER, position INTEGER, title LONGVARCHAR, keyword_id INTEGER, folder_type TEXT, dateAdded INTEGER, lastModified INTEGER, guid TEXT, syncStatus INTEGER NOT NULL DEFAULT 0, syncChangeCounter INTEGER NOT NULL DEFAULT 1);
            """)
        try db.transaction {
            for (i, p) in places.enumerated() {
                let id = placeIDs?[i] ?? (i + 1)
                try db.run("""
                    INSERT INTO moz_places (id, url, title, visit_count, hidden, typed, last_visit_date, guid) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.int(Int64(id)), .text(p.url), p.title.map { .text($0) } ?? .null, .int(Int64(p.visitCount)), .int(Int64(p.hidden)),
                          .int(Int64(p.typed)), p.lastVisit.map { .int($0) } ?? .null, .text("guid\(id)")])
                for (n, v) in p.visits.enumerated() {
                    try db.run("INSERT INTO moz_historyvisits (id, place_id, visit_date, visit_type) VALUES (?, ?, ?, ?)",
                               [.int(Int64(id * 100 + n)), .int(Int64(id)), .int(v.0), .int(Int64(v.1))])
                }
            }
            for b in bookmarks {
                try db.run("INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, dateAdded, guid) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                           [.int(Int64(b.id)), .int(Int64(b.type)), b.fk.map { .int(Int64($0)) } ?? .null, .int(Int64(b.parent)),
                            .int(Int64(b.position)), b.title.map { .text($0) } ?? .null, .int(b.dateAdded), .text(b.guid)])
            }
        }
        return db
    }

    /// Firefox's fixed roots, as found in a fresh profile.
    static let roots: [BookmarkRow] = [
        .init(id: 1, type: 2, fk: nil, parent: 0, position: 0, title: "", guid: "root________"),
        .init(id: 2, type: 2, fk: nil, parent: 1, position: 0, title: "menu", guid: "menu________"),
        .init(id: 3, type: 2, fk: nil, parent: 1, position: 1, title: "toolbar", guid: "toolbar_____"),
        .init(id: 4, type: 2, fk: nil, parent: 1, position: 2, title: "tags", guid: "tags________"),
        .init(id: 5, type: 2, fk: nil, parent: 1, position: 3, title: "unfiled", guid: "unfiled_____"),
        .init(id: 6, type: 2, fk: nil, parent: 1, position: 4, title: "mobile", guid: "mobile______"),
    ]

    static func makeProfilesINI(at url: URL, profiles: [(name: String, path: String, isDefault: Bool)], installDefault: String? = nil) throws {
        var text = ""
        if let installDefault { text += "[Install2656FF1E876E9973]\nDefault=\(installDefault)\nLocked=1\n\n" }
        for (i, p) in profiles.enumerated() {
            text += "[Profile\(i)]\nName=\(p.name)\nIsRelative=1\nPath=\(p.path)\n" + (p.isDefault ? "Default=1\n" : "") + "\n"
        }
        text += "[General]\nStartWithLastProfile=1\nVersion=2\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Safari

enum SafariFixture {
    struct Visit { var time: Double; var title: String?; var loadSuccessful = true }
    struct Item { var url: String; var visitCount: Int; var visits: [Visit] }

    /// The real `history_items` / `history_visits` schema (macOS 14). `time` is Core Data seconds.
    static func makeHistory(at url: URL, items: [Item]) throws {
        let db = try SQLiteDatabase(path: url.path)
        try db.execute("""
            CREATE TABLE history_items (id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL UNIQUE, domain_expansion TEXT NULL, visit_count INTEGER NOT NULL, daily_visit_counts BLOB NOT NULL, weekly_visit_counts BLOB NULL, autocomplete_triggers BLOB NULL, should_recompute_derived_visit_counts INTEGER NOT NULL, visit_count_score INTEGER NOT NULL, status_code INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE history_visits (id INTEGER PRIMARY KEY AUTOINCREMENT, history_item INTEGER NOT NULL REFERENCES history_items(id) ON DELETE CASCADE, visit_time REAL NOT NULL, title TEXT NULL, load_successful BOOLEAN NOT NULL DEFAULT 1, http_non_get BOOLEAN NOT NULL DEFAULT 0, synthesized BOOLEAN NOT NULL DEFAULT 0, redirect_source INTEGER NULL, redirect_destination INTEGER NULL, origin INTEGER NOT NULL DEFAULT 0, generation INTEGER NOT NULL DEFAULT 0, attributes INTEGER NOT NULL DEFAULT 0, score INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX history_visits__history_item ON history_visits (history_item, visit_time);
            """)
        try db.transaction {
            for item in items {
                try db.run("INSERT INTO history_items (url, visit_count, daily_visit_counts, should_recompute_derived_visit_counts, visit_count_score) VALUES (?, ?, ?, 0, 0)",
                           [.text(item.url), .int(Int64(item.visitCount)), .blob(Data())])
                let id = try BrowserSQL.scalarInt(db, "SELECT last_insert_rowid()")
                for v in item.visits {
                    try db.run("INSERT INTO history_visits (history_item, visit_time, title, load_successful) VALUES (?, ?, ?, ?)",
                               [.int(Int64(id)), .double(v.time), v.title.map { .text($0) } ?? .null, .int(v.loadSuccessful ? 1 : 0)])
                }
            }
        }
    }

    static func leaf(_ title: String, _ url: String) -> [String: Any] {
        ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": url, "URIDictionary": ["title": title], "WebBookmarkUUID": UUID().uuidString]
    }

    static func list(_ title: String, _ children: [[String: Any]]) -> [String: Any] {
        ["WebBookmarkType": "WebBookmarkTypeList", "Title": title, "Children": children, "WebBookmarkUUID": UUID().uuidString]
    }

    static func makeBookmarks(at url: URL, children: [[String: Any]]) throws {
        let root: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeList", "Title": "", "Children": children, "WebBookmarkFileVersion": 1]
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url)
    }

    static var readingListItem: [String: Any] {
        ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://later.example/read", "URIDictionary": ["title": "Later"],
         "ReadingList": ["DateAdded": Date(), "PreviewText": "..."], "WebBookmarkUUID": UUID().uuidString]
    }
}
