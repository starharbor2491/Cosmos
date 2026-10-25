import Foundation
import CosmosCore

/// Turns the parsed Arc sidebar into a Cosmos `Workspace`.
///
/// The tree is rebuilt by walking down from each space's two roots and from Favorites, never by trusting
/// `parentID`: an item is imported once, at the first place the walk reaches it, so dangling child ids, cycles and
/// items listed by two parents cannot produce an inconsistent tree. Items nothing reaches are counted, not imported.
final class ArcWorkspaceBuilder {
    private enum Section { case favorites, pinned, unpinned }

    struct Output {
        var workspace: Workspace
        /// The Arc profile each imported space used, for resolving link-routing destinations.
        var profileKeys: [UUID: ArcProfileKey]
    }

    private let sidebar: ArcSidebar
    private let windows: ArcWindows
    private var profiles: ArcProfileTable
    private let notes: ImportNotes
    private let now: Date

    private var out: [UUID: SidebarItem] = [:]
    private var visited = Set<UUID>()
    private var depth = 0
    private static let maxDepth = 100
    /// Items that no `childrenIds` lists but whose `parentID` names a parent: attached there, after its listed children.
    private var unlisted: [UUID: [ArcItem]] = [:]

    init(sidebar: ArcSidebar, windows: ArcWindows, profiles: ArcProfileTable, notes: ImportNotes, now: Date) {
        self.sidebar = sidebar
        self.windows = windows
        self.profiles = profiles
        self.notes = notes
        self.now = now

        var listed = Set<UUID>()
        for item in sidebar.items.values { listed.formUnion(item.childIDs) }
        for item in sidebar.items.values where !listed.contains(item.id) {
            if case .container = item.data { continue }
            if let parent = item.parentID, sidebar.items[parent] != nil { unlisted[parent, default: []].append(item) }
        }
        for key in unlisted.keys {
            unlisted[key]?.sort { ($0.createdAt ?? .distantPast, $0.id.uuidString) < ($1.createdAt ?? .distantPast, $1.id.uuidString) }
        }
    }

    func build() -> Output {
        let favoritesRoot = sidebar.favoritesRoots.first ?? ArcID.uuid("cosmos.arc-import.favorites")
        out[favoritesRoot] = SidebarItem(id: favoritesRoot, createdAt: now, content: .container(.favorites))
        for root in sidebar.favoritesRoots { visited.insert(root) }
        for root in sidebar.favoritesRoots {
            for child in children(of: root) { convert(child, into: favoritesRoot, section: .favorites) }
        }

        var spaces: [Space] = []
        var profileKeys: [UUID: ArcProfileKey] = [:]
        var usedRoots: Set<UUID> = [favoritesRoot]
        for (index, arc) in sidebar.spaces.enumerated() {
            let pinned = claimRoot(arc.pinnedRoot, "pinned", space: arc, used: &usedRoots)
            let unpinned = claimRoot(arc.unpinnedRoot, "unpinned", space: arc, used: &usedRoots)
            out[pinned.id] = SidebarItem(id: pinned.id, createdAt: now, content: .container(.pinned(spaceID: arc.id)))
            out[unpinned.id] = SidebarItem(id: unpinned.id, createdAt: now, content: .container(.unpinned(spaceID: arc.id)))
            if pinned.usable { for child in children(of: pinned.id) { convert(child, into: pinned.id, section: .pinned) } }
            if unpinned.usable { for child in children(of: unpinned.id) { convert(child, into: unpinned.id, section: .unpinned) } }

            spaces.append(Space(id: arc.id, title: arc.title ?? "Space \(index + 1)",
                                icon: ArcSpaceStyle.icon(from: arc.iconType, notes: notes),
                                profileID: profiles.profileID(for: arc.profile, notes: notes),
                                theme: ArcSpaceStyle.theme(from: arc.windowTheme, notes: notes),
                                pinnedRootID: pinned.id, unpinnedRootID: unpinned.id))
            profileKeys[arc.id] = arc.profile
        }

        let unreachable = sidebar.items.values.filter { item in
            if case .container = item.data { return false }
            return !visited.contains(item.id)
        }.count
        notes.skip("unreachableItem", unreachable)

        let workspace = Workspace(profiles: profiles.profiles, spaces: spaces, favoritesRootID: favoritesRoot, items: Array(out.values))
        return Output(workspace: workspace, profileKeys: profileKeys)
    }

    // MARK: Roots

    /// A space's section root. Roots are never shared: if Arc points two spaces at one container, or names none, the
    /// section gets a fresh, empty root.
    private func claimRoot(_ preferred: UUID?, _ label: String, space: ArcSpace, used: inout Set<UUID>) -> (id: UUID, usable: Bool) {
        if let preferred, used.insert(preferred).inserted {
            visited.insert(preferred)
            return (preferred, true)
        }
        notes.warn(preferred == nil ? "A space had no \(label) container; an empty one was created"
                                    : "Two spaces shared a \(label) container; the second one starts empty")
        let id = ArcID.uuid("cosmos.arc-import.\(space.id.uuidString).\(label)")
        used.insert(id)
        return (id, false)
    }

    /// The ids to walk below `id`: its listed children that exist, then items that only name it as `parentID`.
    private func children(of id: UUID) -> [UUID] {
        guard let node = sidebar.items[id] else { return [] }
        var result: [UUID] = []
        for child in node.childIDs {
            if sidebar.items[child] != nil { result.append(child) } else { notes.warn("A reference to a missing item was ignored") }
        }
        for item in unlisted[id] ?? [] {
            result.append(item.id)
            notes.warn("An item listed only by its parent link was attached to that parent")
        }
        return result
    }

    /// Marks an item as imported. `nil` when it is not an item, is a container, or was already reached.
    private func claim(_ id: UUID) -> ArcItem? {
        guard let item = sidebar.items[id] else { return nil }
        if case .container = item.data {
            notes.skip("nestedContainer")
            return nil
        }
        guard visited.insert(id).inserted else {
            notes.warn("An item reachable more than once (a cycle or a shared child) was kept once")
            return nil
        }
        return item
    }

    private func attach(_ node: SidebarItem, to parentID: UUID) {
        var node = node
        node.parentID = parentID
        out[node.id] = node
        out[parentID]?.childIDs.append(node.id)
    }

    // MARK: Converting items

    private func convert(_ id: UUID, into parentID: UUID, section: Section) {
        guard let item = claim(id) else { return }
        guard depth < Self.maxDepth else {
            notes.skip("tooDeeplyNested")
            return
        }
        depth += 1
        defer { depth -= 1 }
        switch item.data {
        case .tab(let tab):
            if let node = makeTab(item, tab, section: section) { attach(node, to: parentID) }
        case .folder:
            convertFolder(item, into: parentID, section: section)
        case .split(let split):
            convertSplit(item, split, into: parentID, section: section)
        case .easel:
            notes.skip("easel")
        case .unknown(let name):
            notes.skip("unknown:\(name)")
        case .container:
            break
        }
    }

    private func makeTab(_ item: ArcItem, _ tab: ArcTab, section: Section) -> SidebarItem? {
        guard let url = ArcJSON.url(tab.url) else {
            notes.skip("tabWithoutValidURL")
            return nil
        }
        if ArcJSON.isInternal(url) { notes.warn("Tabs pointing at Arc or Chromium internal pages were imported but Cosmos cannot open them") }
        let lastActive = tab.lastActiveAt ?? windows.lastActive[item.id]
        let data = TabData(url: url, pageTitle: tab.title, lastActiveAt: lastActive, isMuted: tab.isMuted,
                           homeURL: section == .unpinned ? nil : url)
        return SidebarItem(id: item.id, title: item.title, createdAt: createdAt(item, fallback: lastActive), content: .tab(data))
    }

    private func createdAt(_ item: ArcItem, fallback: Date? = nil) -> Date {
        item.createdAt ?? windows.created[item.id] ?? fallback ?? now
    }

    /// Folders exist only in Pinned (that is where Arc and Cosmos allow them). Anywhere else the folder's contents
    /// take its place.
    private func convertFolder(_ item: ArcItem, into parentID: UUID, section: Section) {
        guard section == .pinned else {
            notes.warn(section == .unpinned ? "A folder in Today was flattened into its tabs" : "A folder in Favorites was flattened into its tabs")
            for child in children(of: item.id) { convert(child, into: parentID, section: section) }
            return
        }
        let expanded = windows.hasWindows ? windows.expandedItems.contains(item.id) : true
        attach(SidebarItem(id: item.id, title: item.title, createdAt: createdAt(item), content: .folder(FolderData(isExpanded: expanded))), to: parentID)
        for child in children(of: item.id) { convert(child, into: item.id, section: section) }
    }

    private func convertSplit(_ item: ArcItem, _ split: ArcSplit, into parentID: UUID, section: Section) {
        var panes: [SidebarItem] = []
        gatherPanes(under: item.id, section: section, into: &panes)

        guard panes.count >= 2, section != .favorites else {
            switch panes.count {
            case 0: notes.skip("emptySplitView")
            case 1: notes.warn("A split view with one usable pane became a plain tab")
            default: notes.warn("A split view in Favorites became separate tabs")
            }
            for pane in panes { attach(pane, to: parentID) }
            return
        }

        let kept = Array(panes.prefix(Workspace.maxSplitPanes))
        let extra = Array(panes.dropFirst(Workspace.maxSplitPanes))
        let focus = split.focusID.flatMap { id in kept.first { $0.id == id }?.id } ?? kept[0].id
        let orientation: SplitData.Orientation
        switch split.orientation?.lowercased() {
        case "vertical": orientation = .vertical
        case "horizontal", nil: orientation = .horizontal
        default:
            notes.warn("A split view had an unknown orientation; horizontal was used")
            orientation = .horizontal
        }
        let data = SplitData(orientation: orientation, focusedChildID: focus, weights: weights(for: kept.map(\.id), factors: split.factors))
        attach(SidebarItem(id: item.id, title: item.title, createdAt: createdAt(item), content: .split(data)), to: parentID)
        for pane in kept { attach(pane, to: item.id) }
        if !extra.isEmpty {
            notes.warn("Panes beyond the fourth of a split view were moved next to it", extra.count)
            for pane in extra { attach(pane, to: parentID) }
        }
    }

    /// Splits hold plain tabs; anything else inside one is flattened to its tabs.
    private func gatherPanes(under id: UUID, section: Section, into panes: inout [SidebarItem]) {
        guard depth < Self.maxDepth else { return }
        depth += 1
        defer { depth -= 1 }
        for childID in children(of: id) {
            guard let child = claim(childID) else { continue }
            switch child.data {
            case .tab(let tab):
                if let node = makeTab(child, tab, section: section) { panes.append(node) }
            case .folder, .split:
                notes.warn("A folder or split inside a split view was flattened into its tabs")
                gatherPanes(under: childID, section: section, into: &panes)
            case .easel:
                notes.skip("easel")
            case .unknown(let name):
                notes.skip("unknown:\(name)")
            case .container:
                break
            }
        }
    }

    /// Arc's `itemWidthFactors` may list only some panes (a two-pane split was seen with one entry). Listed panes keep
    /// their factor, unlisted ones share what is left, and the result is normalised to sum to 1.
    private func weights(for panes: [UUID], factors: [UUID: Double]) -> [Double] {
        let listed: [Double?] = panes.map { id in factors[id].flatMap { $0 > 0 ? $0 : nil } }
        let known = listed.compactMap { $0 }.reduce(0, +)
        let missing = listed.filter { $0 == nil }.count
        var raw: [Double]
        if missing == 0 {
            raw = listed.map { $0 ?? 0 }
        } else if known > 0, known < 1 {
            let share = (1 - known) / Double(missing)
            raw = listed.map { $0 ?? share }
        } else {
            raw = Array(repeating: 1, count: panes.count)
        }
        let sum = raw.reduce(0, +)
        return sum > 0 ? raw.map { $0 / sum } : Array(repeating: 1.0 / Double(panes.count), count: panes.count)
    }
}
