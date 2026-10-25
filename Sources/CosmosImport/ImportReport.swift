import Foundation

/// What an import did, in numbers.
///
/// A report holds counts and fixed, generic messages only: never a title, URL, e-mail address or any other
/// browsing data. That makes it safe to print, log and attach to a bug report.
public struct ImportReport: Codable, Equatable, Sendable {
    public var spaces: Int
    public var profiles: Int
    /// Tabs in Favorites.
    public var favorites: Int
    /// Tabs in Pinned sections (folders and splits included).
    public var pinnedTabs: Int
    /// Tabs in Today sections (splits included).
    public var unpinnedTabs: Int
    public var folders: Int
    public var splitViews: Int
    public var archivedItems: Int
    public var linkRules: Int
    public var boosts: Int
    /// Things that were imported with a compromise (a folder flattened, an unknown value replaced by a default).
    /// Identical messages are merged into one line with a count.
    public var warnings: [String]
    /// What was left out, by kind: `["easel": 3, "unreachableItem": 1]`.
    public var skipped: [String: Int]

    public init(spaces: Int = 0, profiles: Int = 0, favorites: Int = 0, pinnedTabs: Int = 0, unpinnedTabs: Int = 0,
                folders: Int = 0, splitViews: Int = 0, archivedItems: Int = 0, linkRules: Int = 0, boosts: Int = 0,
                warnings: [String] = [], skipped: [String: Int] = [:]) {
        self.spaces = spaces
        self.profiles = profiles
        self.favorites = favorites
        self.pinnedTabs = pinnedTabs
        self.unpinnedTabs = unpinnedTabs
        self.folders = folders
        self.splitViews = splitViews
        self.archivedItems = archivedItems
        self.linkRules = linkRules
        self.boosts = boosts
        self.warnings = warnings
        self.skipped = skipped
    }

    /// Every tab that ended up in the sidebar.
    public var tabs: Int { favorites + pinnedTabs + unpinnedTabs }

    /// Everything that was left out, summed over kinds.
    public var skippedTotal: Int { skipped.values.reduce(0, +) }

    /// A few lines of counts for the terminal or an import-finished sheet. Contains no personal data.
    public var summary: String {
        var lines = [
            "Spaces: \(spaces), profiles: \(profiles)",
            "Tabs: \(tabs) (\(favorites) in Favorites, \(pinnedTabs) pinned, \(unpinnedTabs) in Today), folders: \(folders), split views: \(splitViews)",
            "Archive: \(archivedItems), link rules: \(linkRules), boosts: \(boosts)",
        ]
        if !skipped.isEmpty {
            let parts = skipped.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }
            lines.append("Skipped: " + parts.joined(separator: ", "))
        }
        if !warnings.isEmpty { lines.append("Warnings: \(warnings.count)") }
        return lines.joined(separator: "\n")
    }
}

/// Collects warnings and skip counts while an import runs. Warnings are de-duplicated and counted so that a
/// profile with thousands of similar oddities produces a handful of lines.
final class ImportNotes {
    private var order: [String] = []
    private var counts: [String: Int] = [:]
    private(set) var skipped: [String: Int] = [:]

    func warn(_ message: String, _ n: Int = 1) {
        guard n > 0 else { return }
        if counts[message] == nil { order.append(message) }
        counts[message, default: 0] += n
    }

    func skip(_ kind: String, _ n: Int = 1) {
        guard n > 0 else { return }
        skipped[kind, default: 0] += n
    }

    var warnings: [String] {
        order.map { message in
            let n = counts[message] ?? 1
            return n > 1 ? "\(message) (x\(n))" : message
        }
    }
}
