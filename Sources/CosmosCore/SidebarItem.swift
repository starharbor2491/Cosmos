import Foundation

/// Every node in the sidebar is a `SidebarItem` in one flat table, linked by `parentID` / `childIDs`.
/// This is deliberately the same shape as Arc's `StorableSidebar` items (see arc-teardown/data-and-sync.md)
/// so that importing is a field-for-field mapping and nothing about the tree has to be re-derived.
public struct SidebarItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var parentID: UUID?
    public var childIDs: [UUID]
    /// A user-chosen title (folders, renamed tabs). `nil` means "use the page title".
    public var title: String?
    public var createdAt: Date
    public var content: Content

    public init(id: UUID = UUID(), parentID: UUID? = nil, childIDs: [UUID] = [], title: String? = nil,
                createdAt: Date = Date(), content: Content) {
        self.id = id
        self.parentID = parentID
        self.childIDs = childIDs
        self.title = title
        self.createdAt = createdAt
        self.content = content
    }

    public enum Content: Hashable, Sendable {
        case tab(TabData)
        case folder(FolderData)
        /// Up to four tabs shown side by side. The children are the panes, in order.
        case split(SplitData)
        /// A root: Favorites, or a space's Pinned / Today area. Never shown as a row itself.
        case container(ContainerKind)
        /// Something in an import we cannot represent (Arc Easels, ...). Kept so nothing is silently lost.
        case unsupported(kind: String)
    }

    public var isTab: Bool { if case .tab = content { return true } else { return false } }
    public var isFolder: Bool { if case .folder = content { return true } else { return false } }
    public var isSplit: Bool { if case .split = content { return true } else { return false } }
    public var isContainer: Bool { if case .container = content { return true } else { return false } }

    public var tab: TabData? { if case .tab(let t) = content { return t } else { return nil } }

    /// What the sidebar should show for this item right now.
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        switch content {
        case .tab(let t): return t.pageTitle?.nonEmpty ?? t.url?.host ?? "New Tab"
        case .folder: return "Folder"
        case .split: return "Split View"
        case .container: return ""
        case .unsupported(let k): return k.capitalized
        }
    }
}

public struct TabData: Codable, Hashable, Sendable {
    /// The URL the tab last showed (what we reopen at launch).
    public var url: URL?
    public var pageTitle: String?
    public var lastActiveAt: Date?
    public var isMuted: Bool
    /// For pinned tabs: where "Reset Tab to Original URL" goes. Captured when the tab is pinned.
    public var homeURL: URL?

    public init(url: URL? = nil, pageTitle: String? = nil, lastActiveAt: Date? = nil, isMuted: Bool = false, homeURL: URL? = nil) {
        self.url = url
        self.pageTitle = pageTitle
        self.lastActiveAt = lastActiveAt
        self.isMuted = isMuted
        self.homeURL = homeURL
    }
}

public struct FolderData: Codable, Hashable, Sendable {
    public var isExpanded: Bool
    public init(isExpanded: Bool = true) { self.isExpanded = isExpanded }
}

public struct SplitData: Codable, Hashable, Sendable {
    public enum Orientation: String, Codable, Sendable { case horizontal, vertical }
    public var orientation: Orientation
    /// The pane that has keyboard focus.
    public var focusedChildID: UUID?
    /// Relative pane widths (or heights), parallel to the item's `childIDs`; normalised to sum to 1 when read.
    public var weights: [Double]

    public init(orientation: Orientation = .horizontal, focusedChildID: UUID? = nil, weights: [Double] = []) {
        self.orientation = orientation
        self.focusedChildID = focusedChildID
        self.weights = weights
    }
}

public enum ContainerKind: Hashable, Sendable {
    case favorites
    case pinned(spaceID: UUID)
    case unpinned(spaceID: UUID)
}

// MARK: - Codable (explicit `kind` discriminator: stable, human-readable, diff-friendly)

extension SidebarItem.Content: Codable {
    private enum CodingKeys: String, CodingKey { case kind, tab, folder, split, container, spaceID, unsupportedKind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "tab": self = .tab(try c.decode(TabData.self, forKey: .tab))
        case "folder": self = .folder(try c.decodeIfPresent(FolderData.self, forKey: .folder) ?? FolderData())
        case "split": self = .split(try c.decode(SplitData.self, forKey: .split))
        case "favorites": self = .container(.favorites)
        case "pinned": self = .container(.pinned(spaceID: try c.decode(UUID.self, forKey: .spaceID)))
        case "unpinned": self = .container(.unpinned(spaceID: try c.decode(UUID.self, forKey: .spaceID)))
        default: self = .unsupported(kind: (try? c.decode(String.self, forKey: .unsupportedKind)) ?? "unknown")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tab(let t): try c.encode("tab", forKey: .kind); try c.encode(t, forKey: .tab)
        case .folder(let f): try c.encode("folder", forKey: .kind); try c.encode(f, forKey: .folder)
        case .split(let s): try c.encode("split", forKey: .kind); try c.encode(s, forKey: .split)
        case .container(.favorites): try c.encode("favorites", forKey: .kind)
        case .container(.pinned(let id)): try c.encode("pinned", forKey: .kind); try c.encode(id, forKey: .spaceID)
        case .container(.unpinned(let id)): try c.encode("unpinned", forKey: .kind); try c.encode(id, forKey: .spaceID)
        case .unsupported(let k): try c.encode("unsupported", forKey: .kind); try c.encode(k, forKey: .unsupportedKind)
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
