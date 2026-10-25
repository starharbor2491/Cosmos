import Foundation
import CosmosCore

/// One browser profile found on disk.
public struct BrowserProfile: Hashable, Identifiable, Sendable {
    public var browser: BrowserKind
    /// The name the browser shows for the profile ("Person 1", "default-release", ...).
    public var name: String
    public var directory: URL
    public var isDefault: Bool
    /// Which kinds of data the profile has (or, when `accessDenied`, is assumed to have).
    public var dataKinds: Set<BrowserDataKind>
    /// Row counts from cheap `COUNT(*)` queries. Approximate: the importer filters more strictly (http/https only, ...).
    public var approximateCounts: [BrowserDataKind: Int]
    /// The profile exists but macOS refuses to let us read it (Safari without Full Disk Access).
    public var accessDenied: Bool

    public var id: String { browser.rawValue + ":" + directory.path }

    public init(browser: BrowserKind, name: String, directory: URL, isDefault: Bool = false,
                dataKinds: Set<BrowserDataKind> = [], approximateCounts: [BrowserDataKind: Int] = [:], accessDenied: Bool = false) {
        self.browser = browser; self.name = name; self.directory = directory; self.isDefault = isDefault
        self.dataKinds = dataKinds; self.approximateCounts = approximateCounts; self.accessDenied = accessDenied
    }
}

/// A bookmark or a folder of bookmarks, as read from any browser.
public struct BookmarkNode: Hashable, Sendable {
    public enum Kind: String, Sendable { case folder, url }

    public var kind: Kind
    public var title: String
    /// Set for `.url` nodes.
    public var url: URL?
    public var dateAdded: Date?
    /// Set for `.folder` nodes, in the browser's order.
    public var children: [BookmarkNode]

    public init(kind: Kind, title: String, url: URL? = nil, dateAdded: Date? = nil, children: [BookmarkNode] = []) {
        self.kind = kind; self.title = title; self.url = url; self.dateAdded = dateAdded; self.children = children
    }

    public static func folder(_ title: String, dateAdded: Date? = nil, children: [BookmarkNode] = []) -> BookmarkNode {
        BookmarkNode(kind: .folder, title: title, dateAdded: dateAdded, children: children)
    }

    public static func bookmark(_ title: String, url: URL, dateAdded: Date? = nil) -> BookmarkNode {
        BookmarkNode(kind: .url, title: title, url: url, dateAdded: dateAdded)
    }

    public var isFolder: Bool { kind == .folder }

    /// Bookmarks (URL leaves) in this subtree, the node itself included.
    public var bookmarkCount: Int { kind == .url ? 1 : children.reduce(0) { $0 + $1.bookmarkCount } }

    /// Folders in this subtree, the node itself included.
    public var folderCount: Int { kind == .folder ? 1 + children.reduce(0) { $0 + $1.folderCount } : 0 }
}

public extension Sequence where Element == BookmarkNode {
    var bookmarkCount: Int { reduce(0) { $0 + $1.bookmarkCount } }
    var folderCount: Int { reduce(0) { $0 + $1.folderCount } }
}

/// What to read from a profile.
public struct BrowserImportOptions: Sendable {
    public var history: Bool
    public var bookmarks: Bool
    /// Only history last visited at or after this date.
    public var since: Date?
    /// Keep only this many history entries (the most recently visited).
    public var limit: Int?
    /// Where temporary database copies are made; defaults to the system temporary directory.
    public var workDirectory: URL?
    /// The clock used to clamp future dates (tests pin it).
    public var now: Date

    public init(history: Bool = true, bookmarks: Bool = true, since: Date? = nil, limit: Int? = nil,
                workDirectory: URL? = nil, now: Date = Date()) {
        self.history = history; self.bookmarks = bookmarks; self.since = since; self.limit = limit
        self.workDirectory = workDirectory; self.now = now
    }
}

/// What a read did, for the import summary screen.
public struct BrowserImportReport: Equatable, Sendable {
    public var browser: BrowserKind
    public var profileName: String
    /// History rows that matched the query (http/https, within `since`).
    public var historyRowsRead = 0
    /// Rows dropped for a malformed URL or an unusable date.
    public var historyRowsSkipped = 0
    /// Rows folded into an earlier entry for the same page (they differed only by `#fragment`/host case).
    public var historyRowsMerged = 0
    public var historyImported = 0
    public var bookmarksImported = 0
    public var bookmarkFoldersImported = 0
    /// Bookmarks left out because they are not web pages (`javascript:`, `chrome://`, `place:` ...).
    public var bookmarksSkipped = 0
    public var warnings: [String] = []

    public init(browser: BrowserKind, profileName: String) {
        self.browser = browser; self.profileName = profileName
    }
}

public struct BrowserImportData: Sendable {
    /// Newest visit first.
    public var history: [HistoryEntry]
    public var bookmarks: [BookmarkNode]
    public var report: BrowserImportReport
}

/// Why a browser profile could not be read.
public enum BrowserImportError: Error, Equatable, Sendable {
    /// macOS blocked the read (Safari's data needs Full Disk Access).
    case permissionDenied(path: String)
    case fileNotFound(path: String)
    /// The file exists but is not in the expected format (corrupt database, bad JSON/plist).
    case unreadable(path: String, reason: String)
}

extension BrowserImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let path):
            return "Cosmos isn't allowed to read \(path). Open System Settings \u{2192} Privacy & Security \u{2192} Full Disk Access, "
                + "switch on Cosmos (or the app you started it from, such as Terminal), then quit and reopen it and try again."
        case .fileNotFound(let path):
            return "There is nothing to import at \(path)."
        case .unreadable(let path, let reason):
            return "Cosmos couldn't read \(path): \(reason)"
        }
    }
}
