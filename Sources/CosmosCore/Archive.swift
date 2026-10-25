import Foundation

/// How long an unpinned tab may sit untouched before it is archived. Arc offers the same five choices
/// and archives after 12 hours by default.
public enum ArchiveInterval: String, Codable, CaseIterable, Sendable {
    case hours12, hours24, days7, days30, never

    public var seconds: TimeInterval? {
        switch self {
        case .hours12: return 12 * 3600
        case .hours24: return 24 * 3600
        case .days7: return 7 * 86400
        case .days30: return 30 * 86400
        case .never: return nil
        }
    }

    public var label: String {
        switch self {
        case .hours12: return "After 12 hours"
        case .hours24: return "After 24 hours"
        case .days7: return "After 7 days"
        case .days30: return "After 30 days"
        case .never: return "Never"
        }
    }
}

public enum ArchiveReason: String, Codable, Sendable {
    /// Idle too long.
    case auto
    /// Closed by the user (⌘W on a Today tab archives it).
    case closed
    /// "Clear Unpinned Tabs".
    case cleared
    /// Brought in by an importer (Arc's archive).
    case imported
}

/// A tab (or folder / split with its children) that left the sidebar but can be found and restored.
public struct ArchivedItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var archivedAt: Date
    public var reason: ArchiveReason
    /// The space it came from, so Restore can put it back (or in the current space if that is gone).
    public var spaceID: UUID?
    /// The removed subtree, root first.
    public var items: [SidebarItem]

    public init(id: UUID = UUID(), archivedAt: Date = Date(), reason: ArchiveReason, spaceID: UUID?, items: [SidebarItem]) {
        self.id = id
        self.archivedAt = archivedAt
        self.reason = reason
        self.spaceID = spaceID
        self.items = items
    }

    public var root: SidebarItem? { items.first }
    public var title: String { root?.displayTitle ?? "Untitled" }
    public var url: URL? { items.first(where: \.isTab)?.tab?.url }
    public var tabCount: Int { items.filter(\.isTab).count }
}

public struct ArchiveData: Codable, Equatable, Sendable {
    public var interval: ArchiveInterval
    public var entries: [ArchivedItem]
    /// Hard cap so the file cannot grow without bound; oldest entries fall off first.
    public var limit: Int

    public init(interval: ArchiveInterval = .hours12, entries: [ArchivedItem] = [], limit: Int = 5000) {
        self.interval = interval
        self.entries = entries
        self.limit = limit
    }

    public mutating func add(_ entry: ArchivedItem) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    public mutating func remove(_ id: UUID) { entries.removeAll { $0.id == id } }

    public func search(_ query: String) -> [ArchivedItem] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter { e in
            e.items.contains { item in
                item.displayTitle.lowercased().contains(q) || (item.tab?.url?.absoluteString.lowercased().contains(q) ?? false)
            }
        }
    }
}

public extension Workspace {
    /// Top-level Today items (a tab, or a split whose panes are all idle) that have been idle for `interval`.
    /// `exempt` protects tabs that must not vanish: the selected tab, anything playing audio, anything loading.
    func idleUnpinnedItems(in spaceID: UUID, interval: ArchiveInterval, now: Date = Date(), exempt: Set<UUID> = []) -> [UUID] {
        guard let secs = interval.seconds, let space = space(spaceID) else { return [] }
        let cutoff = now.addingTimeInterval(-secs)
        return unpinned(in: space).compactMap { child in
            let tabs = tabs(under: child.id)
            guard !tabs.isEmpty, !tabs.contains(where: { exempt.contains($0.id) }) else { return nil }
            let newest = tabs.map { $0.tab?.lastActiveAt ?? $0.createdAt }.max() ?? child.createdAt
            return newest < cutoff ? child.id : nil
        }
    }

    /// Removes `ids` from the sidebar and returns them as archive entries.
    mutating func archive(_ ids: [UUID], reason: ArchiveReason, now: Date = Date()) -> [ArchivedItem] {
        ids.compactMap { id in
            let space = spaceID(of: id)
            let removed = remove(id)
            return removed.isEmpty ? nil : ArchivedItem(archivedAt: now, reason: reason, spaceID: space, items: removed)
        }
    }
}
