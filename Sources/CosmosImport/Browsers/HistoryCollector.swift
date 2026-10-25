import Foundation
import CosmosCore

/// What a family importer found in a history database.
public struct BrowserHistoryRead: Sendable {
    /// Newest visit first.
    public var entries: [HistoryEntry]
    public var rowsRead: Int
    public var rowsSkipped: Int
    public var rowsMerged: Int

    static let empty = BrowserHistoryRead(entries: [], rowsRead: 0, rowsSkipped: 0, rowsMerged: 0)
}

/// Cleans, de-duplicates and merges raw history rows from any browser.
struct HistoryCollector {
    let now: Date
    private var entries: [String: HistoryEntry] = [:]
    /// When the visit that supplied each entry's current title happened: the newest non-empty title wins.
    private var titleDates: [String: Date] = [:]
    private(set) var rowsRead = 0
    private(set) var rowsSkipped = 0
    private(set) var rowsMerged = 0

    init(now: Date) { self.now = now }

    /// Pages are keyed without their `#fragment` and with a lower-case scheme and host (the same identity
    /// `HistoryStore` uses); non-web schemes and unparseable URLs are dropped.
    static func normalized(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              var c = URL(string: raw).flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) ?? URLComponents(string: raw),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty else { return nil }
        c.scheme = scheme
        c.host = host.lowercased()
        c.fragment = nil
        return c.url
    }

    mutating func add(url raw: String?, title: String?, visitCount: Int, typedCount: Int, firstVisit: Date?, lastVisit: Date?) {
        rowsRead += 1
        let first = BrowserTimestamp.sanitized(firstVisit, now: now)
        guard let url = Self.normalized(raw), let last = BrowserTimestamp.sanitized(lastVisit, now: now) ?? first else {
            rowsSkipped += 1
            return
        }
        let entry = HistoryEntry(url: url, title: (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                 visitCount: max(visitCount, 1), typedCount: max(typedCount, 0),
                                 firstVisit: min(first ?? last, last), lastVisit: last)
        let key = url.absoluteString
        guard var existing = entries[key] else {
            entries[key] = entry
            titleDates[key] = entry.title.isEmpty ? .distantPast : entry.lastVisit
            return
        }
        rowsMerged += 1
        existing.visitCount += entry.visitCount
        existing.typedCount += entry.typedCount
        existing.firstVisit = min(existing.firstVisit, entry.firstVisit)
        if !entry.title.isEmpty, entry.lastVisit > (titleDates[key] ?? .distantPast) {
            existing.title = entry.title
            titleDates[key] = entry.lastVisit
        }
        existing.lastVisit = max(existing.lastVisit, entry.lastVisit)
        entries[key] = existing
    }

    func result(limit: Int?) -> BrowserHistoryRead {
        var sorted = entries.values.sorted { $0.lastVisit != $1.lastVisit ? $0.lastVisit > $1.lastVisit : $0.url.absoluteString < $1.url.absoluteString }
        if let limit, limit >= 0, sorted.count > limit { sorted.removeLast(sorted.count - limit) }
        return BrowserHistoryRead(entries: sorted, rowsRead: rowsRead, rowsSkipped: rowsSkipped, rowsMerged: rowsMerged)
    }
}

/// SQL shared by the importers: only web pages, and (when asked) only those visited since a date.
enum HistorySQL {
    static func webOnly(_ column: String) -> String { "(\(column) LIKE 'http://%' OR \(column) LIKE 'https://%')" }
}
