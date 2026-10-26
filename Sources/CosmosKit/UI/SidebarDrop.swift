import SwiftUI
import UniformTypeIdentifiers
import CosmosCore

/// Where an in-flight drag would land, drawn as a line / ring on the row it is over.
struct DropIndicator: Equatable {
    enum Zone { case before, after, into }
    var id: UUID
    var zone: Zone
}

enum SidebarDrop {
    /// What an in-app drag carries, visible to this app only, so a tab dropped on a text field or another app can never
    /// arrive as stray text. (Declared in Info.plist by `scripts/build-app.sh`. The drop targets don't depend on matching
    /// it: they ask the store whether a drag started here.)
    static let itemType = UTType(exportedAs: "app.cosmos.sidebar-item", conformingTo: .data)
    static let types: [UTType] = [itemType, .url]

    /// The drag of one sidebar item: the private type for moving it inside Cosmos and, for a tab, its address as a link
    /// for everything else (a text field gets the address, Finder a web location).
    static func provider(for id: UUID, url: URL?, title: String?) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: itemType.identifier, visibility: .ownProcess) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
        if let url { provider.registerObject(url as NSURL, visibility: .all) }
        provider.suggestedName = title
        return provider
    }
}

/// The marker drawn on a row while a drag hovers it.
struct DropMarker: View {
    let indicator: DropIndicator?
    let id: UUID
    let axis: Axis
    @Environment(\.palette) private var palette

    var body: some View {
        if let indicator, indicator.id == id {
            switch indicator.zone {
            case .into:
                RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).strokeBorder(palette.accent, lineWidth: 2).padding(-1)
            case .before:
                marker(alignment: axis == .vertical ? .top : .leading)
            case .after:
                marker(alignment: axis == .vertical ? .bottom : .trailing)
            }
        }
    }

    private func marker(alignment: Alignment) -> some View {
        ZStack(alignment: alignment) {
            Color.clear
            Capsule().fill(palette.accent)
                .frame(width: axis == .vertical ? nil : 3, height: axis == .vertical ? 3 : nil)
                .padding(axis == .vertical ? .horizontal : .vertical, 4)
                .offset(x: axis == .horizontal ? (alignment == .leading ? -3 : 3) : 0, y: axis == .vertical ? (alignment == .top ? -1.5 : 1.5) : 0)
        }
    }
}

/// Shared drop handling: resolves what is being dragged (an internal sidebar item or an external URL) and applies it.
@MainActor
enum DropActions {
    static func externalURL(_ info: DropInfo, completion: @escaping @MainActor (URL) -> Void) -> Bool {
        guard let provider = info.itemProviders(for: [.url]).first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in completion(url) }
        }
        return true
    }

    /// Final index for inserting `dragged` before child position `index` of `parent`.
    static func finalIndex(_ ws: Workspace, dragged: UUID, parent: UUID, insertBefore index: Int) -> Int {
        guard let old = ws.item(parent)?.childIDs.firstIndex(of: dragged) else { return index }
        return old < index ? index - 1 : index
    }
}

/// Drops onto an individual row (tab, folder, favorite tile).
struct RowDropDelegate: DropDelegate {
    let store: BrowserStore
    let window: WindowState
    let targetID: UUID
    let axis: Axis
    let rowSize: CGFloat
    @Binding var indicator: DropIndicator?

    private func zone(_ info: DropInfo) -> DropIndicator.Zone {
        let pos = axis == .vertical ? info.location.y : info.location.x
        let t = pos / rowSize
        guard let target = store.workspace.item(targetID) else { return .after }
        let allowsInto = target.isFolder || (target.isTab && store.draggingItemID != nil && store.workspace.item(store.draggingItemID!)?.isTab == true
                                              && axis == .vertical && store.workspace.section(of: targetID) != .favorites)
        if allowsInto, t > 0.28, t < 0.72 { return .into }
        return t < 0.5 ? .before : .after
    }

    func validateDrop(info: DropInfo) -> Bool {
        // A drag that started in Cosmos is recorded by the store; anything else is a link from another app.
        if let d = store.draggingItemID { return d != targetID && !store.workspace.isAncestor(d, of: targetID) }
        return info.hasItemsConforming(to: [.url])
    }

    func dropEntered(info: DropInfo) { moveIndicator(DropIndicator(id: targetID, zone: zone(info))) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        moveIndicator(DropIndicator(id: targetID, zone: zone(info)))
        return DropProposal(operation: .move)
    }

    /// Updates the marker, with a tick under the finger each time it snaps to a new place.
    private func moveIndicator(_ new: DropIndicator) {
        if indicator != new { store.haptics.alignment() }
        indicator = new
    }
    func dropExited(info: DropInfo) { if indicator?.id == targetID { indicator = nil } }

    func performDrop(info: DropInfo) -> Bool {
        let z = zone(info)
        defer { indicator = nil; store.endDrag() }
        let ws = store.workspace
        guard let target = ws.item(targetID) else { return false }

        // Where would a drop land?
        func destination(_ z: DropIndicator.Zone) -> (parent: UUID, index: Int)? {
            switch z {
            case .into:
                if target.isFolder { return (targetID, 0) }
                return nil
            case .before, .after:
                guard let pid = target.parentID, let idx = ws.item(pid)?.childIDs.firstIndex(of: targetID) else { return nil }
                // Dropping "after" an open folder puts the item at the top of its contents.
                if z == .after, case .folder(let f) = target.content, f.isExpanded { return (targetID, 0) }
                // A pane of a split can't be a drop target for siblings; treat it as the split itself.
                if ws.item(pid)?.isSplit == true, let gp = ws.item(pid)?.parentID, let gi = ws.item(gp)?.childIDs.firstIndex(of: pid) {
                    return (gp, z == .before ? gi : gi + 1)
                }
                return (pid, z == .before ? idx : idx + 1)
            }
        }

        if let dragged = store.draggingItemID {
            if z == .into, target.isTab, ws.item(dragged)?.isTab == true {
                store.splitWith(targetID, dragged: dragged, in: window)
                store.haptics.levelChange()
                return true
            }
            guard let dest = destination(z) else { return false }
            let idx = DropActions.finalIndex(ws, dragged: dragged, parent: dest.parent, insertBefore: dest.index)
            store.dropMove(dragged, under: dest.parent, at: idx)
            store.haptics.levelChange()
            return true
        }
        return DropActions.externalURL(info) { url in
            guard let dest = destination(z == .into && !target.isFolder ? .after : z) else { return }
            store.dropNewTab(url: url, under: dest.parent, at: dest.index, in: window)
        }
    }
}

/// Drops onto a whole section (its empty space, or the end of the list).
struct ContainerDropDelegate: DropDelegate {
    let store: BrowserStore
    let window: WindowState
    let rootID: UUID
    var atStart = false
    @Binding var indicator: DropIndicator?

    func validateDrop(info: DropInfo) -> Bool { store.draggingItemID != nil || info.hasItemsConforming(to: [.url]) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { indicator = nil }

    func performDrop(info: DropInfo) -> Bool {
        defer { indicator = nil; store.endDrag() }
        let ws = store.workspace
        let count = ws.item(rootID)?.childIDs.count ?? 0
        if let dragged = store.draggingItemID {
            let idx = atStart ? 0 : count
            store.dropMove(dragged, under: rootID, at: DropActions.finalIndex(ws, dragged: dragged, parent: rootID, insertBefore: idx))
            store.haptics.levelChange()
            return true
        }
        return DropActions.externalURL(info) { url in
            store.dropNewTab(url: url, under: rootID, at: atStart ? 0 : count, in: window)
        }
    }
}

extension BrowserStore {
    /// Starts dragging a sidebar item: remembers what is in flight (the drop targets read it) and returns the payload.
    /// A drag that is cancelled never reports back, so this also watches the mouse button and clears itself once it is up.
    func beginDrag(_ id: UUID) -> NSItemProvider {
        draggingItemID = id
        haptics.generic()
        Task { @MainActor [weak self] in
            var upSince: Date?
            while let self, self.draggingItemID == id {
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    if let since = upSince, Date().timeIntervalSince(since) > 0.5 { self.endDrag() }
                    else if upSince == nil { upSince = Date() }
                } else {
                    upSince = nil
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let item = workspace.item(id)
        let url = item?.isTab == true ? (runtime(forItem: id, in: nil)?.url ?? item?.tab?.url) : nil
        return SidebarDrop.provider(for: id, url: url.flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil }, title: item.map { _ in title(forItem: id, in: nil) })
    }

    func endDrag() { draggingItemID = nil }

    /// Moves a dragged item, fixing up the pinned "home" URL when it crosses between sections.
    func dropMove(_ id: UUID, under parent: UUID, at index: Int?) {
        let from = workspace.section(of: id)
        let toRoot = workspace.rootID(of: parent)
        let to: Workspace.Section? = toRoot.flatMap { root in
            guard case .container(let kind)? = workspace.item(root)?.content else { return nil }
            switch kind {
            case .favorites: return .favorites
            case .pinned(let s): return .pinned(spaceID: s)
            case .unpinned(let s): return .unpinned(spaceID: s)
            }
        }
        guard to != nil else { return }
        let wasLoose: Bool = { if case .unpinned? = from { return true }; return false }()
        let becomesLoose: Bool = { if case .unpinned? = to { return true }; return false }()
        let moved = edit { ws -> Bool in
            let ok = ws.move(id, under: parent, at: index)
            guard ok else { return false }
            for t in ws.tabs(under: id) {
                if wasLoose && !becomesLoose { ws.updateTab(t.id) { $0.homeURL = $0.url } }
                if !wasLoose && becomesLoose { ws.updateTab(t.id) { $0.homeURL = nil } }
            }
            return true
        }
        // A tab dragged into another space belongs to that space's profile now.
        if moved, let f = from, let t = to, spaceOf(f) != spaceOf(t) { discardRuntimes(under: id) }
    }

    private func spaceOf(_ s: Workspace.Section) -> UUID? {
        switch s { case .favorites: return nil; case .pinned(let id), .unpinned(let id): return id }
    }

    func dropNewTab(url: URL, under parent: UUID, at index: Int, in window: WindowState) {
        guard let id = edit({ $0.addTab(url: url, under: parent, at: index) }) else { return }
        if case .pinned? = workspace.section(of: id) { edit { $0.updateTab(id) { $0.homeURL = url } } }
        if workspace.section(of: id) == .favorites { edit { $0.updateTab(id) { $0.homeURL = url } } }
        select(id, in: window)
    }

    /// Display title for a sidebar item: your name for it, else the live page title, else what was saved.
    func title(forItem id: UUID, in window: WindowState?) -> String {
        guard let item = workspace.item(id) else { return "" }
        if let t = item.title, !t.isEmpty { return t }
        if case .tab(let data) = item.content {
            let live = runtime(forItem: id, in: window)
            let raw = (live?.title.isEmpty == false ? live?.title : nil) ?? data.pageTitle
            let url = live?.url ?? data.url
            if let raw, !raw.isEmpty { return TidyTitles.tidy(title: raw, url: url) }
            if let host = url?.host { return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
            return url == nil ? "New Tab" : (url?.absoluteString ?? "New Tab")
        }
        return item.displayTitle
    }

    func beginNewSpace(in window: WindowState) {
        let theme = SpaceTheme.presets[workspace.spaces.count % SpaceTheme.presets.count]
        let icons = SpaceIcon.suggested
        let id = addSpace(title: "Space \(workspace.spaces.count + 1)", icon: icons[workspace.spaces.count % icons.count], theme: theme,
                          profileID: workspace.space(window.focusedSpaceID)?.profileID, in: window)
        window.overlay = .themeEditor(id)
    }
}
