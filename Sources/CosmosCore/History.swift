import Foundation

public struct HistoryEntry: Hashable, Identifiable, Sendable {
    public var url: URL
    public var title: String
    public var visitCount: Int
    public var typedCount: Int
    public var firstVisit: Date
    public var lastVisit: Date
    public var id: String { url.absoluteString }

    public init(url: URL, title: String, visitCount: Int = 1, typedCount: Int = 0, firstVisit: Date = Date(), lastVisit: Date = Date()) {
        self.url = url; self.title = title; self.visitCount = visitCount; self.typedCount = typedCount
        self.firstVisit = firstVisit; self.lastVisit = lastVisit
    }
}

/// "Frecency": how likely a URL is the one the user wants, from how often and how recently they used it.
/// Arc's own ranker feeds on the same signals (last navigation time, typed count, visit count).
public enum Frecency {
    public static let halfLife: TimeInterval = 14 * 86400

    /// 0...~1.5, monotone in visits and typed visits, exponentially decaying with age.
    public static func score(visitCount: Int, typedCount: Int, lastVisit: Date, now: Date = Date()) -> Double {
        let age = max(0, now.timeIntervalSince(lastVisit))
        let recency = pow(0.5, age / halfLife)
        let frequency = min(1.0, log2(Double(visitCount) + 1) / 7)   // saturates around 127 visits
        let typed = min(0.5, Double(typedCount) * 0.1)
        return 0.55 * recency + 0.45 * frequency + typed * recency
    }

    public static func score(_ e: HistoryEntry, now: Date = Date()) -> Double {
        score(visitCount: e.visitCount, typedCount: e.typedCount, lastVisit: e.lastVisit, now: now)
    }
}

/// Browsing history in SQLite: one row per URL with visit counters (what the Command Bar and ⌘Y need).
public final class HistoryStore: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let lock = NSLock()

    /// `path == nil` keeps the database in memory (tests, incognito-like use).
    public init(path: String?) throws {
        if let path { try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true) }
        db = try SQLiteDatabase(path: path ?? ":memory:")
        try db.execute("PRAGMA journal_mode=WAL")
        // A deleted row is overwritten rather than left readable in its page.
        try db.execute("PRAGMA secure_delete=ON")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS history (
                url TEXT PRIMARY KEY,
                title TEXT NOT NULL DEFAULT '',
                visit_count INTEGER NOT NULL DEFAULT 1,
                typed_count INTEGER NOT NULL DEFAULT 0,
                first_visit REAL NOT NULL,
                last_visit REAL NOT NULL,
                profile TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS history_last ON history(last_visit DESC);
            """)
    }

    private static func key(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.fragment = nil
        return c?.string
    }

    public func record(url: URL, title: String?, typed: Bool = false, at date: Date = Date()) {
        guard let key = Self.key(url) else { return }
        lock.lock(); defer { lock.unlock() }
        try? db.run("""
            INSERT INTO history (url, title, visit_count, typed_count, first_visit, last_visit)
            VALUES (?, ?, 1, ?, ?, ?)
            ON CONFLICT(url) DO UPDATE SET
                visit_count = visit_count + 1,
                typed_count = typed_count + ?,
                last_visit = excluded.last_visit,
                title = CASE WHEN excluded.title != '' THEN excluded.title ELSE title END
            """, [.text(key), .text(title ?? ""), .int(typed ? 1 : 0), .double(date.timeIntervalSince1970), .double(date.timeIntervalSince1970), .int(typed ? 1 : 0)])
    }

    public func updateTitle(url: URL, title: String) {
        guard let key = Self.key(url), !title.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        try? db.run("UPDATE history SET title = ? WHERE url = ?", [.text(title), .text(key)])
    }

    /// Bulk insert (importers). Existing rows are merged: counts add, dates widen.
    public func importEntries(_ entries: [HistoryEntry]) throws {
        lock.lock(); defer { lock.unlock() }
        try db.transaction {
            for e in entries {
                guard let key = Self.key(e.url) else { continue }
                try db.run("""
                    INSERT INTO history (url, title, visit_count, typed_count, first_visit, last_visit)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(url) DO UPDATE SET
                        visit_count = visit_count + excluded.visit_count,
                        typed_count = typed_count + excluded.typed_count,
                        first_visit = MIN(first_visit, excluded.first_visit),
                        last_visit = MAX(last_visit, excluded.last_visit),
                        title = CASE WHEN title = '' THEN excluded.title ELSE title END
                    """, [.text(key), .text(e.title), .int(Int64(e.visitCount)), .int(Int64(e.typedCount)),
                          .double(e.firstVisit.timeIntervalSince1970), .double(e.lastVisit.timeIntervalSince1970)])
            }
        }
    }

    private func entries(from rows: [SQLiteDatabase.Row]) -> [HistoryEntry] {
        rows.compactMap { r in
            guard r.count >= 6, let u = r[0].string.flatMap(URL.init(string:)), let vc = r[2].int64, let tc = r[3].int64,
                  let fv = r[4].double, let lv = r[5].double else { return nil }
            return HistoryEntry(url: u, title: r[1].string ?? "", visitCount: Int(vc), typedCount: Int(tc),
                                firstVisit: Date(timeIntervalSince1970: fv), lastVisit: Date(timeIntervalSince1970: lv))
        }
    }

    private let columns = "url, title, visit_count, typed_count, first_visit, last_visit"

    public func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return Int((try? db.query("SELECT COUNT(*) FROM history").first?.first?.int64) ?? 0)
    }

    public func recent(limit: Int = 200, offset: Int = 0) -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        let rows = (try? db.query("SELECT \(columns) FROM history ORDER BY last_visit DESC LIMIT ? OFFSET ?", [.int(Int64(limit)), .int(Int64(offset))])) ?? []
        return entries(from: rows)
    }

    /// Substring match on URL or title, best frecency first. Fine for a local DB of up to ~10^6 rows when `limit` is small.
    public func search(_ text: String, limit: Int = 50, now: Date = Date()) -> [HistoryEntry] {
        let needle = "%" + text.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        lock.lock()
        let rows = (try? db.query("""
            SELECT \(columns) FROM history WHERE url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\'
            ORDER BY last_visit DESC LIMIT 500
            """, [.text(needle), .text(needle)])) ?? []
        lock.unlock()
        return entries(from: rows).sorted { Frecency.score($0, now: now) > Frecency.score($1, now: now) }.prefix(limit).map { $0 }
    }

    /// The highest-frecency pages: candidates for the Command Bar when the field is empty or short.
    public func topSites(limit: Int = 200, now: Date = Date()) -> [HistoryEntry] {
        lock.lock()
        let rows = (try? db.query("SELECT \(columns) FROM history ORDER BY visit_count DESC, last_visit DESC LIMIT 1500")) ?? []
        lock.unlock()
        return entries(from: rows).sorted { Frecency.score($0, now: now) > Frecency.score($1, now: now) }.prefix(limit).map { $0 }
    }

    public func delete(url: URL) {
        guard let key = Self.key(url) else { return }
        lock.lock(); defer { lock.unlock() }
        try? db.run("DELETE FROM history WHERE url = ?", [.text(key)])
        forgetWrittenCopies()
    }

    /// The hosts of every page in the history, lower-cased.
    public func hosts() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let rows = (try? db.query("SELECT url FROM history")) ?? []
        return Set(rows.compactMap { $0.first?.string.flatMap(URL.init(string:))?.host?.lowercased() })
    }

    /// The database logs a change before it makes it, and the log would still hold the address of a row that was deleted
    /// until the next checkpoint: fold it into the file and empty it.
    private func forgetWrittenCopies() {
        try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// Clears everything, or only entries last visited at/after `since`.
    public func clear(since: Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let since { try? db.run("DELETE FROM history WHERE last_visit >= ?", [.double(since.timeIntervalSince1970)]) }
        else { try? db.run("DELETE FROM history") }
        forgetWrittenCopies()
    }
}
