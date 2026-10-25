import Foundation

/// The whole sidebar world: profiles, spaces, and the flat item table.
///
/// `items` is `private(set)`: every structural change goes through the methods below, which keep the tree
/// consistent (parent/child links agree, splits never hold fewer than two panes, folders only live where Arc
/// allows them). `problems()` re-checks those invariants and is used by the importer and the tests.
public struct Workspace: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var profiles: [Profile]
    /// Order is the order of the space bar.
    public var spaces: [Space]
    /// The shared container whose children are the Favorites grid.
    public var favoritesRootID: UUID
    public private(set) var items: [UUID: SidebarItem]

    public static let maxSplitPanes = 4

    // MARK: Construction

    public init(profiles: [Profile], spaces: [Space], favoritesRootID: UUID, items: [SidebarItem]) {
        self.version = Workspace.currentVersion
        self.profiles = profiles
        self.spaces = spaces
        self.favoritesRootID = favoritesRootID
        self.items = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
    }

    /// A brand-new workspace for a first launch: one profile, one "Home" space, empty Favorites.
    public static func fresh(spaceTitle: String = "Home", theme: SpaceTheme = .nebula) -> Workspace {
        var ws = Workspace(profiles: [], spaces: [], favoritesRootID: UUID(), items: [])
        let profile = Profile(name: "Personal", isDefault: true)
        ws.profiles = [profile]
        ws.items[ws.favoritesRootID] = SidebarItem(id: ws.favoritesRootID, content: .container(.favorites))
        ws.addSpace(title: spaceTitle, icon: .symbol("moon.stars.fill"), theme: theme, profileID: profile.id)
        return ws
    }

    // MARK: Lookup

    public func item(_ id: UUID) -> SidebarItem? { items[id] }
    public func space(_ id: UUID) -> Space? { spaces.first { $0.id == id } }
    public func spaceIndex(_ id: UUID) -> Int? { spaces.firstIndex { $0.id == id } }
    public func profile(_ id: UUID) -> Profile? { profiles.first { $0.id == id } }

    public func children(of id: UUID) -> [SidebarItem] {
        (items[id]?.childIDs ?? []).compactMap { items[$0] }
    }

    public var favorites: [SidebarItem] { children(of: favoritesRootID) }

    public func pinned(in space: Space) -> [SidebarItem] { children(of: space.pinnedRootID) }
    public func unpinned(in space: Space) -> [SidebarItem] { children(of: space.unpinnedRootID) }

    public enum Section: Hashable, Sendable {
        case favorites
        case pinned(spaceID: UUID)
        case unpinned(spaceID: UUID)
    }

    /// The root container an item hangs under.
    public func rootID(of id: UUID) -> UUID? {
        var current = id
        var hops = 0
        while let item = items[current], hops < 10_000 {
            if item.isContainer { return current }
            guard let parent = item.parentID else { return nil }
            current = parent
            hops += 1
        }
        return nil
    }

    public func section(of id: UUID) -> Section? {
        guard let root = rootID(of: id), let item = items[root], case .container(let kind) = item.content else { return nil }
        switch kind {
        case .favorites: return .favorites
        case .pinned(let s): return .pinned(spaceID: s)
        case .unpinned(let s): return .unpinned(spaceID: s)
        }
    }

    /// The space an item belongs to (`nil` for Favorites, which are shared by every space).
    public func spaceID(of id: UUID) -> UUID? {
        switch section(of: id) {
        case .pinned(let s), .unpinned(let s): return s
        default: return nil
        }
    }

    public func isAncestor(_ ancestor: UUID, of id: UUID) -> Bool {
        var current = items[id]?.parentID
        var hops = 0
        while let c = current, hops < 10_000 {
            if c == ancestor { return true }
            current = items[c]?.parentID
            hops += 1
        }
        return false
    }

    /// All items below `id`, depth first, parent before children.
    public func descendants(of id: UUID) -> [SidebarItem] {
        var out: [SidebarItem] = []
        func walk(_ nid: UUID) {
            for c in items[nid]?.childIDs ?? [] {
                guard let child = items[c] else { continue }
                out.append(child)
                walk(c)
            }
        }
        walk(id)
        return out
    }

    /// The tabs under `id` (itself included when it is a tab), flattening folders and splits.
    public func tabs(under id: UUID) -> [SidebarItem] {
        guard let root = items[id] else { return [] }
        return ([root] + descendants(of: id)).filter(\.isTab)
    }

    public func allTabs() -> [SidebarItem] { items.values.filter(\.isTab) }

    /// Sidebar order for "Next/Previous Tab": favorites, pinned (expanded folders only), Today.
    public func navigationOrder(in space: Space) -> [UUID] {
        var out: [UUID] = []
        func walk(_ items: [SidebarItem], expandedOnly: Bool) {
            for item in items {
                switch item.content {
                case .tab: out.append(item.id)
                case .split: out.append(contentsOf: children(of: item.id).map(\.id))
                case .folder(let f):
                    if f.isExpanded || !expandedOnly { walk(children(of: item.id), expandedOnly: expandedOnly) }
                default: break
                }
            }
        }
        walk(favorites, expandedOnly: true)
        walk(pinned(in: space), expandedOnly: true)
        walk(unpinned(in: space), expandedOnly: true)
        return out
    }

    // MARK: Creating items

    @discardableResult
    public mutating func addSpace(title: String, icon: SpaceIcon = .symbol("moon.stars.fill"), theme: SpaceTheme = .nebula,
                                  profileID: UUID? = nil, at index: Int? = nil) -> UUID {
        let id = UUID(), pinnedRoot = UUID(), unpinnedRoot = UUID()
        items[pinnedRoot] = SidebarItem(id: pinnedRoot, content: .container(.pinned(spaceID: id)))
        items[unpinnedRoot] = SidebarItem(id: unpinnedRoot, content: .container(.unpinned(spaceID: id)))
        let space = Space(id: id, title: title, icon: icon, profileID: profileID ?? profiles.first(where: \.isDefault)?.id ?? profiles[0].id,
                          theme: theme, pinnedRootID: pinnedRoot, unpinnedRootID: unpinnedRoot)
        spaces.insert(space, at: min(max(index ?? spaces.count, 0), spaces.count))
        return id
    }

    /// Removes a space and everything in it. Returns the removed items (for archiving); refuses to remove the last space.
    @discardableResult
    public mutating func removeSpace(_ id: UUID) -> [SidebarItem]? {
        guard spaces.count > 1, let space = space(id) else { return nil }
        var removed: [SidebarItem] = []
        for root in [space.pinnedRootID, space.unpinnedRootID] {
            removed += descendants(of: root)
            for d in descendants(of: root) { items[d.id] = nil }
            items[root] = nil
        }
        spaces.removeAll { $0.id == id }
        return removed
    }

    @discardableResult
    public mutating func addTab(url: URL?, title: String? = nil, under parentID: UUID, at index: Int? = nil,
                                now: Date = Date()) -> UUID? {
        let item = SidebarItem(title: nil, createdAt: now,
                               content: .tab(TabData(url: url, pageTitle: title, lastActiveAt: now)))
        return attachNew(item, under: parentID, at: index)
    }

    @discardableResult
    public mutating func addFolder(title: String, under parentID: UUID, at index: Int? = nil, now: Date = Date()) -> UUID? {
        attachNew(SidebarItem(title: title, createdAt: now, content: .folder(FolderData())), under: parentID, at: index)
    }

    private mutating func attachNew(_ item: SidebarItem, under parentID: UUID, at index: Int?) -> UUID? {
        guard let parent = items[parentID], canAccept(item.content, under: parent) else { return nil }
        var item = item
        item.parentID = parentID
        items[item.id] = item
        insertChild(item.id, into: parentID, at: index)
        return item.id
    }

    // MARK: Structural rules

    /// What may live where (mirrors Arc): Favorites hold only tabs; folders live in Pinned (or in folders);
    /// splits hold 2...4 plain tabs and can't be nested or favorited; Today holds tabs and splits.
    public func canAccept(_ content: SidebarItem.Content, under parent: SidebarItem) -> Bool {
        switch (parent.content, content) {
        case (_, .container): return false
        case (.tab, _), (.unsupported, _): return false
        case (.container(.favorites), .tab): return true
        case (.container(.favorites), _): return false
        case (.container(.pinned), _): return true
        case (.container(.unpinned), .folder): return false
        case (.container(.unpinned), _): return true
        case (.folder, _): return true
        case (.split, .tab): return parent.childIDs.count < Workspace.maxSplitPanes
        case (.split, _): return false
        }
    }

    private mutating func insertChild(_ id: UUID, into parentID: UUID, at index: Int?) {
        guard var parent = items[parentID] else { return }
        parent.childIDs.removeAll { $0 == id }
        let i = min(max(index ?? parent.childIDs.count, 0), parent.childIDs.count)
        parent.childIDs.insert(id, at: i)
        if case .split(var s) = parent.content, s.weights.count != parent.childIDs.count {
            s.weights = Array(repeating: 1.0 / Double(parent.childIDs.count), count: parent.childIDs.count)
            parent.content = .split(s)
        }
        items[parentID] = parent
    }

    private mutating func detach(_ id: UUID) {
        guard let item = items[id], let pid = item.parentID, var parent = items[pid] else { return }
        if let idx = parent.childIDs.firstIndex(of: id) {
            parent.childIDs.remove(at: idx)
            if case .split(var s) = parent.content {
                if idx < s.weights.count { s.weights.remove(at: idx) }
                if s.focusedChildID == id { s.focusedChildID = parent.childIDs.first }
                parent.content = .split(s)
            }
        }
        items[pid] = parent
        items[id]?.parentID = nil
        dissolveSplitIfNeeded(pid)
    }

    /// A split with fewer than two panes is just a tab: replace it with its remaining child, in the same place.
    private mutating func dissolveSplitIfNeeded(_ splitID: UUID) {
        guard let split = items[splitID], split.isSplit, split.childIDs.count < 2,
              let gp = split.parentID, let grand = items[gp], let at = grand.childIDs.firstIndex(of: splitID) else { return }
        let remaining = split.childIDs.first
        var g = grand
        g.childIDs.remove(at: at)
        if let r = remaining {
            g.childIDs.insert(r, at: at)
            items[r]?.parentID = gp
        }
        items[gp] = g
        items[splitID] = nil
    }

    // MARK: Moving, removing, restoring

    /// Moves an item (and everything under it) to `index` (its final position) under `newParent`.
    @discardableResult
    public mutating func move(_ id: UUID, under newParentID: UUID, at index: Int? = nil) -> Bool {
        guard let item = items[id], let newParent = items[newParentID], !item.isContainer,
              newParentID != id, !isAncestor(id, of: newParentID), canAcceptMove(item, under: newParent) else { return false }
        let oldParent = item.parentID
        // Moving a tab out of the same split it is in would dissolve the split under our feet; handle by ordering.
        if oldParent == newParentID {
            insertChild(id, into: newParentID, at: index)
            return true
        }
        detach(id)
        // The destination may have been the dissolved split's grandparent; re-read it.
        guard items[newParentID] != nil else { return false }
        items[id]?.parentID = newParentID
        insertChild(id, into: newParentID, at: index)
        return true
    }

    private func canAcceptMove(_ item: SidebarItem, under parent: SidebarItem) -> Bool {
        if item.parentID == parent.id { return true }
        return canAccept(item.content, under: parent)
    }

    /// Removes an item and its subtree. Returns the removed items, root first, so callers can archive them.
    @discardableResult
    public mutating func remove(_ id: UUID) -> [SidebarItem] {
        guard let item = items[id], !item.isContainer else { return [] }
        let subtree = [item] + descendants(of: id)
        detach(id)
        for s in subtree { items[s.id] = nil }
        return subtree
    }

    /// Puts a removed subtree (root first) back, keeping its ids unless they collide.
    @discardableResult
    public mutating func restore(_ subtree: [SidebarItem], under parentID: UUID, at index: Int? = nil) -> UUID? {
        guard var root = subtree.first, let parent = items[parentID], canAccept(root.content, under: parent) else { return nil }
        var remap: [UUID: UUID] = [:]
        for s in subtree where items[s.id] != nil { remap[s.id] = UUID() }
        func mapped(_ id: UUID) -> UUID { remap[id] ?? id }
        for var s in subtree {
            let original = s.id
            s.id = mapped(original)
            s.childIDs = s.childIDs.map(mapped)
            if original == root.id { s.parentID = parentID } else { s.parentID = s.parentID.map(mapped) }
            items[s.id] = s
            if original == root.id { root = s }
        }
        insertChild(root.id, into: parentID, at: index)
        return root.id
    }

    // MARK: Editing

    public mutating func updateTab(_ id: UUID, _ change: (inout TabData) -> Void) {
        guard var item = items[id], case .tab(var t) = item.content else { return }
        change(&t)
        item.content = .tab(t)
        items[id] = item
    }

    public mutating func rename(_ id: UUID, to title: String?) {
        guard items[id] != nil else { return }
        items[id]?.title = title?.isEmpty == true ? nil : title
    }

    public mutating func setFolderExpanded(_ id: UUID, _ expanded: Bool) {
        guard case .folder = items[id]?.content else { return }
        items[id]?.content = .folder(FolderData(isExpanded: expanded))
    }

    public mutating func setSplit(_ id: UUID, _ change: (inout SplitData) -> Void) {
        guard case .split(var s)? = items[id]?.content else { return }
        change(&s)
        items[id]?.content = .split(s)
    }

    // MARK: Pinning & favorites

    /// Pins a Today tab or split to its space's Pinned section. Pinned tabs remember their URL as "home".
    @discardableResult
    public mutating func pin(_ id: UUID) -> Bool {
        guard let item = items[id], case .unpinned(let sid)? = section(of: id), let space = space(sid) else { return false }
        guard item.isTab || item.isSplit else { return false }
        for t in tabs(under: id) { updateTab(t.id) { $0.homeURL = $0.url } }
        return move(id, under: space.pinnedRootID, at: nil)
    }

    @discardableResult
    public mutating func unpin(_ id: UUID) -> Bool {
        guard items[id] != nil, case .pinned(let sid)? = section(of: id), let space = space(sid) else { return false }
        // A pinned tab inside a folder: unpinning moves it to the top of Today.
        for t in tabs(under: id) { updateTab(t.id) { $0.homeURL = nil } }
        return move(id, under: space.unpinnedRootID, at: 0)
    }

    @discardableResult
    public mutating func favorite(_ id: UUID) -> Bool {
        guard let item = items[id], item.isTab, section(of: id) != .favorites else { return false }
        updateTab(id) { $0.homeURL = $0.url }
        return move(id, under: favoritesRootID, at: nil)
    }

    /// Takes a tab out of Favorites into a space's Today section.
    @discardableResult
    public mutating func unfavorite(_ id: UUID, into spaceID: UUID) -> Bool {
        guard section(of: id) == .favorites, let space = space(spaceID) else { return false }
        updateTab(id) { $0.homeURL = nil }
        return move(id, under: space.unpinnedRootID, at: 0)
    }

    // MARK: Split view

    /// Puts tab `b` next to tab `a` in one split item that takes `a`'s place. Both must be plain tabs in the same
    /// section, or `a` may already be a pane of a split (then `b` joins it).
    @discardableResult
    public mutating func combineIntoSplit(_ a: UUID, _ b: UUID, orientation: SplitData.Orientation = .horizontal) -> UUID? {
        guard a != b, let ia = items[a], let ib = items[b], ia.isTab, ib.isTab else { return nil }
        // Already a pane of a split: add b as another pane.
        if let pid = ia.parentID, case .split? = items[pid]?.content {
            guard (items[pid]?.childIDs.count ?? 0) < Workspace.maxSplitPanes else { return nil }
            let at = (items[pid]?.childIDs.firstIndex(of: a) ?? 0) + 1
            return move(b, under: pid, at: at) ? pid : nil
        }
        guard let parentID = ia.parentID, let at = items[parentID]?.childIDs.firstIndex(of: a),
              let parent = items[parentID], canAccept(.split(SplitData()), under: parent) else { return nil }
        let split = SidebarItem(title: nil, createdAt: Date(), content: .split(SplitData(orientation: orientation, focusedChildID: a)))
        items[split.id] = split
        items[split.id]?.parentID = parentID
        insertChild(split.id, into: parentID, at: at)
        // Move a into the split first (it's already at `at`; moving it under the split detaches it from the parent).
        detach(a)
        items[a]?.parentID = split.id
        insertChild(a, into: split.id, at: nil)
        guard move(b, under: split.id, at: nil) else {
            // Undo: put a back where it was and drop the empty split.
            detach(a)
            items[a]?.parentID = parentID
            insertChild(a, into: parentID, at: at)
            detach(split.id)
            items[split.id] = nil
            return nil
        }
        return split.id
    }

    /// Takes a pane out of its split; it lands right after the split in the same section.
    @discardableResult
    public mutating func separateFromSplit(_ tabID: UUID) -> Bool {
        guard let item = items[tabID], let sid = item.parentID, case .split? = items[sid]?.content,
              let gid = items[sid]?.parentID, let gparent = items[gid] else { return false }
        let at = (gparent.childIDs.firstIndex(of: sid) ?? gparent.childIDs.count) + 1
        // If the split would dissolve, the remaining tab replaces it, so recompute the index afterwards.
        let before = gparent.childIDs.count
        detach(tabID)
        let after = items[gid]?.childIDs.count ?? before
        let idx = after < before ? min(at - 1, after) : min(at, after)
        items[tabID]?.parentID = gid
        insertChild(tabID, into: gid, at: idx + (after < before ? 1 : 0))
        return true
    }

    // MARK: Bulk operations

    /// "Clear Unpinned Tabs": removes everything in the space's Today section except `keep`. Returns the removed items.
    @discardableResult
    public mutating func clearUnpinned(in spaceID: UUID, keeping keep: Set<UUID> = []) -> [[SidebarItem]] {
        guard let space = space(spaceID) else { return [] }
        var removed: [[SidebarItem]] = []
        for child in children(of: space.unpinnedRootID) where !tabs(under: child.id).contains(where: { keep.contains($0.id) }) {
            removed.append(remove(child.id))
        }
        return removed
    }

    /// Resets pinned tabs of a space to their home URLs ("Reset all tabs in this Space"). Returns the ids changed.
    @discardableResult
    public mutating func resetPinned(in spaceID: UUID) -> [UUID] {
        guard let space = space(spaceID) else { return [] }
        var changed: [UUID] = []
        for t in tabs(under: space.pinnedRootID) where t.tab?.homeURL != nil && t.tab?.url != t.tab?.homeURL {
            updateTab(t.id) { $0.url = $0.homeURL }
            changed.append(t.id)
        }
        return changed
    }

    // MARK: Integrity

    /// Human-readable violations of the tree invariants. Empty means healthy.
    public func problems() -> [String] {
        var out: [String] = []
        if items[favoritesRootID].map({ if case .container(.favorites) = $0.content { return false } else { return true } }) ?? true {
            out.append("favorites root missing or wrong kind")
        }
        for s in spaces {
            if case .container(.pinned(let sid))? = items[s.pinnedRootID]?.content, sid == s.id {} else { out.append("space \(s.id) pinned root bad") }
            if case .container(.unpinned(let sid))? = items[s.unpinnedRootID]?.content, sid == s.id {} else { out.append("space \(s.id) unpinned root bad") }
            if profile(s.profileID) == nil { out.append("space \(s.id) has unknown profile") }
        }
        for (id, item) in items {
            if id != item.id { out.append("key mismatch \(id)") }
            for c in item.childIDs {
                guard let child = items[c] else { out.append("\(id) lists missing child \(c)"); continue }
                if child.parentID != id { out.append("child \(c) parent link disagrees with \(id)") }
            }
            if let p = item.parentID {
                if items[p]?.childIDs.contains(id) != true { out.append("\(id) not listed by parent \(p)") }
            } else if !item.isContainer {
                out.append("\(id) is a non-container with no parent")
            }
            if item.isSplit, item.childIDs.count < 2 { out.append("split \(id) has <2 panes") }
            if item.isSplit, item.childIDs.count > Workspace.maxSplitPanes { out.append("split \(id) has >\(Workspace.maxSplitPanes) panes") }
            if isAncestor(id, of: id) { out.append("cycle at \(id)") }
        }
        return out
    }

    /// Best-effort repair for imported or hand-edited data: drops dangling references, fixes parent links,
    /// dissolves undersized splits and re-homes orphans at the top of the first space's Today.
    public mutating func repair() {
        for (id, var item) in items {
            item.childIDs = item.childIDs.filter { items[$0] != nil }
            items[id] = item
        }
        for (id, item) in items {
            for c in item.childIDs where items[c]?.parentID != id { items[c]?.parentID = id }
        }
        for (id, item) in items where item.parentID != nil && items[item.parentID!] == nil { items[id]?.parentID = nil }
        for (id, item) in items where item.isSplit && item.childIDs.count < 2 { dissolveSplitIfNeeded(id) }
        if let home = spaces.first {
            for (id, item) in items where item.parentID == nil && !item.isContainer && items[id] != nil {
                items[id]?.parentID = home.unpinnedRootID
                insertChild(id, into: home.unpinnedRootID, at: 0)
            }
        }
    }
}

// MARK: - Codable (items as a stable, sorted array)

extension Workspace {
    private enum CodingKeys: String, CodingKey { case version, profiles, spaces, favoritesRootID, items }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Workspace.currentVersion
        profiles = try c.decode([Profile].self, forKey: .profiles)
        spaces = try c.decode([Space].self, forKey: .spaces)
        favoritesRootID = try c.decode(UUID.self, forKey: .favoritesRootID)
        let list = try c.decode([SidebarItem].self, forKey: .items)
        items = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(profiles, forKey: .profiles)
        try c.encode(spaces, forKey: .spaces)
        try c.encode(favoritesRootID, forKey: .favoritesRootID)
        // Dates are written with whole-second precision, so sort on that: otherwise items created within one second
        // would swap places after a decode/encode round trip and the file would churn in version control.
        func key(_ i: SidebarItem) -> (Double, String) { (i.createdAt.timeIntervalSince1970.rounded(.down), i.id.uuidString) }
        let sorted = items.values.sorted { key($0) < key($1) }
        try c.encode(sorted, forKey: .items)
    }
}
