import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CosmosCore

// MARK: - Sections

struct FavoritesGrid: View {
    let store: BrowserStore
    let window: WindowState
    @Binding var indicator: DropIndicator?
    @Environment(\.palette) private var palette

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Metrics.Space.s), count: Metrics.Sidebar.favoriteColumns)

    var body: some View {
        let favorites = store.workspace.favorites
        let dragging = store.draggingItemID != nil
        Group {
            if favorites.isEmpty {
                if dragging {
                    RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous)
                        .strokeBorder(palette.faint, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .overlay(Text("Drop here to add a Favorite").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.tertiary))
                        .frame(height: Metrics.Height.tile)
                }
            } else {
                LazyVGrid(columns: columns, spacing: Metrics.Space.s) {
                    ForEach(favorites) { item in
                        FavoriteTile(store: store, window: window, item: item, indicator: $indicator)
                    }
                }
            }
        }
        .onDrop(of: SidebarDrop.types, delegate: ContainerDropDelegate(store: store, window: window, rootID: store.workspace.favoritesRootID, indicator: $indicator))
    }
}

struct FavoriteTile: View {
    let store: BrowserStore
    let window: WindowState
    let item: SidebarItem
    @Binding var indicator: DropIndicator?
    @Environment(\.palette) private var palette
    @Local private var hover = false

    var body: some View {
        let selected = window.selectedItemID == item.id
        let rt = store.runtime(forItem: item.id, in: window)
        let _ = store.runtimeRevision
        let url = rt?.url ?? item.tab?.url
        Button {
            store.select(item.id, in: window)
        } label: {
            ZStack(alignment: .topTrailing) {
                FaviconView(store: store, url: url, size: Metrics.Icon.tile, fetch: true)
                    .opacity(rt == nil && !selected ? 0.82 : 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let rt {
                    if rt.isLoading { OrbitSpinner(size: 11, color: palette.text).padding(5) }
                    else if rt.isAudible || rt.isMuted {
                        Image(systemName: rt.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 8.5, weight: .bold)).foregroundStyle(palette.secondary).padding(5)
                    }
                }
            }
            .frame(height: Metrics.Height.tile)
            .background(RowBackground(selected: selected, hover: hover, radius: Metrics.Radius.tile, resting: true))
            .overlay(DropMarker(indicator: indicator, id: item.id, axis: .horizontal))
            .contentShape(Rectangle())
            .spatial("tile")
        }
        .buttonStyle(PressableStyle(scale: 0.94))
        .onHover { hover = $0 }
        .help(store.title(forItem: item.id, in: window))
        .contextMenu { ItemContextMenu(store: store, window: window, itemID: item.id) }
        .onDrag({ store.beginDrag(item.id) }, preview: {
            DragPreview(store: store, url: url, title: store.title(forItem: item.id, in: window)).environment(\.palette, palette)
        })
        .onDrop(of: SidebarDrop.types, delegate: RowDropDelegate(store: store, window: window, targetID: item.id, axis: .horizontal, rowSize: Metrics.Sidebar.tileWidth(sidebarWidth: window.sidebarWidth), indicator: $indicator))
    }
}

struct PinnedSection: View {
    let store: BrowserStore
    let window: WindowState
    let space: Space
    @Binding var renaming: UUID?
    @Binding var indicator: DropIndicator?
    @Environment(\.palette) private var palette

    var body: some View {
        let rows = SidebarRows.flatten(store.workspace, root: space.pinnedRootID, expandedOnly: true)
        let dragging = store.draggingItemID != nil
        LazyVStack(spacing: Metrics.Space.hair) {
            if rows.isEmpty {
                if dragging {
                    RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
                        .strokeBorder(palette.faint, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .overlay(Text("Drop here to pin").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.tertiary))
                        .frame(height: Metrics.Height.row)
                }
            } else {
                ForEach(rows) { row in
                    SidebarItemView(store: store, window: window, itemID: row.id, depth: row.depth, renaming: $renaming, indicator: $indicator)
                        .transition(Motion.row)
                }
            }
            Color.clear.frame(height: dragging ? Metrics.Space.m : Metrics.Space.hair)
        }
        .animation(Motion.spring, value: rows.map(\.id))
        .onDrop(of: SidebarDrop.types, delegate: ContainerDropDelegate(store: store, window: window, rootID: space.pinnedRootID, indicator: $indicator))
    }
}

struct TodaySection: View {
    let store: BrowserStore
    let window: WindowState
    let space: Space
    @Binding var renaming: UUID?
    @Binding var indicator: DropIndicator?
    @Environment(\.palette) private var palette

    var body: some View {
        let rows = store.workspace.unpinned(in: space)
        LazyVStack(spacing: Metrics.Space.hair) {
            SectionDivider(title: "Today", trailing: "Archive All") { store.clearUnpinned(in: window) }
            NewTabRow(store: store, window: window)
            ForEach(rows) { item in
                SidebarItemView(store: store, window: window, itemID: item.id, depth: 0, renaming: $renaming, indicator: $indicator)
                    .transition(Motion.row)
            }
            Color.clear.frame(height: Metrics.Space.xl)
        }
        .animation(Motion.spring, value: rows.map(\.id))
        .onDrop(of: SidebarDrop.types, delegate: ContainerDropDelegate(store: store, window: window, rootID: space.unpinnedRootID, atStart: true, indicator: $indicator))
    }
}

struct NewTabRow: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette
    @Local private var hover = false

    var body: some View {
        Button {
            window.overlay = .commandBar(.newTab)
            window.commandBarFocusToken += 1
        } label: {
            HStack(spacing: Metrics.Sidebar.gap) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: Metrics.Icon.row, height: Metrics.Icon.row)
                    .spatial("row.icon.d0")
                Text("New Tab").font(.system(size: 13, weight: .medium))
                    .spatial("row.title.d0")
                Spacer()
            }
            .foregroundStyle(hover ? palette.text : palette.secondary)
            .padding(.horizontal, Metrics.Sidebar.inset)
            .frame(height: Metrics.Height.row)
            .background(RowBackground(selected: false, hover: hover, radius: Metrics.Radius.row))
            .contentShape(Rectangle())
            .spatial("row")
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .onHover { hover = $0 }
    }
}

// MARK: - Rows

enum SidebarRows {
    struct Row: Identifiable { let id: UUID; let depth: Int }

    /// Visible rows under `root`, depth first. Collapsed folders hide their children.
    static func flatten(_ ws: Workspace, root: UUID, expandedOnly: Bool) -> [Row] {
        var out: [Row] = []
        func walk(_ id: UUID, depth: Int) {
            for child in ws.children(of: id) {
                out.append(Row(id: child.id, depth: depth))
                if case .folder(let f) = child.content, f.isExpanded || !expandedOnly { walk(child.id, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return out
    }
}

/// Dispatches to the right row view for an item.
struct SidebarItemView: View {
    let store: BrowserStore
    let window: WindowState
    let itemID: UUID
    let depth: Int
    @Binding var renaming: UUID?
    @Binding var indicator: DropIndicator?

    var body: some View {
        if let item = store.workspace.item(itemID) {
            switch item.content {
            case .tab: TabRow(store: store, window: window, item: item, depth: depth, renaming: $renaming, indicator: $indicator)
            case .folder(let f): FolderRow(store: store, window: window, item: item, folder: f, depth: depth, renaming: $renaming, indicator: $indicator)
            case .split: SplitRow(store: store, window: window, item: item, renaming: $renaming, indicator: $indicator)
            default: EmptyView()
            }
        }
    }
}

struct RenameField: View {
    let initial: String
    let commit: (String?) -> Void
    @Local private var text: String
    @FocusState private var focused: Bool

    init(initial: String, commit: @escaping (String?) -> Void) {
        self.initial = initial; self.commit = commit; _text = Local(wrappedValue: initial)
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .focused($focused)
            .onSubmit { commit(text) }
            .onExitCommand { commit(nil) }
            .onAppear { focused = true }
            .onChange(of: focused) { _, now in if !now { commit(text) } }
    }
}

struct TabRow: View {
    let store: BrowserStore
    let window: WindowState
    let item: SidebarItem
    let depth: Int
    @Binding var renaming: UUID?
    @Binding var indicator: DropIndicator?
    var inSplit = false
    @Environment(\.palette) private var palette
    @Local private var hover = false

    private var splitBorder: CGFloat { inSplit ? Metrics.Space.hair : 0 }

    var body: some View {
        let _ = store.runtimeRevision
        let rt = store.runtime(forItem: item.id, in: window)
        let selected = window.selectedItemID == item.id
        let focusedPane = inSplit && store.currentTabItemID(in: window) == item.id && window.selectedItemID != nil && store.workspace.item(item.id)?.parentID == window.selectedItemID
        let pinned: Bool = { if case .pinned? = store.workspace.section(of: item.id) { return true }; return false }()
        let asleep = rt == nil && pinned
        let url = rt?.url ?? item.tab?.url

        HStack(spacing: Metrics.Sidebar.gap) {
            FaviconView(store: store, url: url, size: Metrics.Icon.row, fetch: true)
                .opacity(asleep ? 0.65 : 1)
                .spatial(inSplit ? "split.icon" : "row.icon.d\(depth)")
            if renaming == item.id {
                RenameField(initial: store.title(forItem: item.id, in: window)) { new in
                    if let new { store.rename(item.id, to: new) }
                    renaming = nil
                }
            } else {
                Text(store.title(forItem: item.id, in: window))
                    .font(.system(size: 13, weight: selected || focusedPane ? .semibold : .medium))
                    .foregroundStyle(asleep ? palette.secondary.opacity(0.85) : palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .spatial(inSplit ? "split.title" : "row.title.d\(depth)")
            }
            Spacer(minLength: 2)
            trailing(rt: rt, pinned: pinned)
        }
        // A split group pads its panes by its own border, so they give that much back to keep icons in the column.
        .padding(.leading, Metrics.Sidebar.inset - splitBorder + CGFloat(depth) * Metrics.Sidebar.indent)
        .padding(.trailing, Metrics.Sidebar.inset - splitBorder)
        .frame(height: Metrics.Height.row)
        .background(RowBackground(selected: selected && !inSplit, hover: hover, radius: Metrics.Radius.row, plainSelected: focusedPane))
        .overlay(DropMarker(indicator: indicator, id: item.id, axis: .vertical))
        .contentShape(Rectangle())
        .spatial(inSplit ? "split.row" : "row")
        .pressEffect()
        // One gesture: with a separate double-tap recognizer SwiftUI holds every single click back to see if a second
        // is coming. The click count says whether this was the second.
        .onTapGesture {
            store.select(item.id, in: window)
            if pinned, NSApp.currentEvent?.clickCount == 2 { renaming = item.id }
        }
        .onHover { hover = $0 }
        .help(item.tab?.url?.absoluteString ?? "")
        .contextMenu { ItemContextMenu(store: store, window: window, itemID: item.id, renaming: $renaming) }
        .onDrag({ store.beginDrag(item.id) }, preview: {
            DragPreview(store: store, url: url, title: store.title(forItem: item.id, in: window)).environment(\.palette, palette)
        })
        .onDrop(of: SidebarDrop.types, delegate: RowDropDelegate(store: store, window: window, targetID: item.id, axis: .vertical, rowSize: Metrics.Height.row, indicator: $indicator))
    }

    @ViewBuilder
    private func trailing(rt: TabRuntime?, pinned: Bool) -> some View {
        if rt?.isLoading == true && !hover {
            OrbitSpinner(size: 13, color: palette.text)
        } else if hover {
            if let rt, rt.isAudible || rt.isMuted {
                RowIconButton(symbol: rt.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", help: rt.isMuted ? "Unmute Tab" : "Mute Tab") { store.toggleMute(item.id, in: window) }
            }
            RowIconButton(symbol: "xmark", help: pinned || store.workspace.section(of: item.id) == .favorites ? "Put to Sleep (⌘W)" : "Archive Tab (⌘W)") {
                store.closeTab(item.id, in: window)
            }
        } else if let rt, rt.isAudible || rt.isMuted {
            Button { store.toggleMute(item.id, in: window) } label: {
                Image(systemName: rt.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(palette.secondary)
            }.buttonStyle(.plain)
        } else if rt?.isCapturing == true {
            Image(systemName: "video.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.red)
        }
    }
}

struct RowIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.palette) private var palette
    @Local private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .symbolSwap()
                .foregroundStyle(hover ? palette.text : palette.secondary)
                .frame(width: Metrics.Icon.row + 2, height: Metrics.Icon.row + 2)
                .background(Circle().fill(hover ? palette.hoverStrong : .clear))
                // Drawn small, but pressable across a 28 pt square (the neighbours' squares touch, never overlap).
                .contentShape(Rectangle().inset(by: -(Metrics.Height.button - Metrics.Icon.row - 2) / 2))
                .animation(Motion.quick, value: hover)
        }
        .buttonStyle(PressableStyle(scale: 0.88))
        .transition(Motion.pop)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct FolderRow: View {
    let store: BrowserStore
    let window: WindowState
    let item: SidebarItem
    let folder: FolderData
    let depth: Int
    @Binding var renaming: UUID?
    @Binding var indicator: DropIndicator?
    @Environment(\.palette) private var palette
    @Local private var hover = false

    var body: some View {
        HStack(spacing: Metrics.Sidebar.gap) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(folder.isExpanded ? 90 : 0))
                .foregroundStyle(palette.tertiary)
                .frame(width: Metrics.Sidebar.chevron)
                .spatial("folder.chevron.d\(depth)")
            Image(systemName: folder.isExpanded ? "folder.fill" : "folder")
                .font(.system(size: 13))
                .foregroundStyle(palette.secondary)
                .frame(width: Metrics.Icon.row)
                .spatial("row.icon.d\(depth + 1)")
            if renaming == item.id {
                RenameField(initial: item.title ?? "Folder") { new in
                    if let new { store.rename(item.id, to: new) }
                    renaming = nil
                }
            } else {
                Text(item.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .spatial("row.title.d\(depth + 1)")
            }
            Spacer(minLength: 2)
            if !folder.isExpanded {
                Text("\(store.workspace.tabs(under: item.id).count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.tertiary)
            }
        }
        .padding(.leading, Metrics.Sidebar.inset + CGFloat(depth) * Metrics.Sidebar.indent)
        .padding(.trailing, Metrics.Sidebar.inset)
        .frame(height: Metrics.Height.row)
        .background(RowBackground(selected: false, hover: hover, radius: Metrics.Radius.row))
        .overlay(DropMarker(indicator: indicator, id: item.id, axis: .vertical))
        .contentShape(Rectangle())
        .spatial("row")
        .pressEffect()
        .onTapGesture { withAnimation(Motion.spring) { store.folderToggle(item.id) } }
        .onHover { hover = $0 }
        .contextMenu { ItemContextMenu(store: store, window: window, itemID: item.id, renaming: $renaming) }
        .onDrag({ store.beginDrag(item.id) }, preview: {
            DragPreview(store: store, url: nil, title: item.displayTitle, symbol: "folder.fill").environment(\.palette, palette)
        })
        .onDrop(of: SidebarDrop.types, delegate: RowDropDelegate(store: store, window: window, targetID: item.id, axis: .vertical, rowSize: Metrics.Height.row, indicator: $indicator))
    }
}

/// Two to four tabs shown side by side in the page appear as one grouped row.
struct SplitRow: View {
    let store: BrowserStore
    let window: WindowState
    let item: SidebarItem
    @Binding var renaming: UUID?
    @Binding var indicator: DropIndicator?
    @Environment(\.palette) private var palette

    var body: some View {
        let selected = window.selectedItemID == item.id
        let panes = store.workspace.children(of: item.id)
        VStack(spacing: Metrics.Space.hair) {
            ForEach(panes) { pane in
                TabRow(store: store, window: window, item: pane, depth: 0, renaming: $renaming, indicator: $indicator, inSplit: true)
            }
        }
        .padding(Metrics.Space.hair)
        .background(
            RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous)
                .fill(selected ? palette.selected.opacity(0.6) : palette.hover)
        )
        .overlay(alignment: .leading) {
            Capsule().fill(palette.accent.opacity(selected ? 0.95 : 0.5)).frame(width: 2.5).padding(.vertical, 8).offset(x: -1)
        }
        .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous).strokeBorder(selected ? palette.stroke : .clear, lineWidth: 0.8))
    }
}

// MARK: - Context menu

struct ItemContextMenu: View {
    let store: BrowserStore
    let window: WindowState
    let itemID: UUID
    var renaming: Binding<UUID?>?

    var body: some View {
        if let item = store.workspace.item(itemID) {
            let section = store.workspace.section(of: itemID)
            switch item.content {
            case .tab: tabMenu(item, section)
            case .folder:
                Button("Rename Folder") { renaming?.wrappedValue = itemID }
                Button("New Folder Inside") { store.edit { _ = $0.addFolder(title: "New Folder", under: itemID) } }
                Divider()
                Button("Put All Tabs to Sleep") { store.discardRuntimes(under: itemID) }
                Button("Delete Folder", role: .destructive) { store.archiveItems([itemID], reason: .cleared, in: window) }
            default: EmptyView()
            }
        }
    }

    @ViewBuilder
    private func tabMenu(_ item: SidebarItem, _ section: Workspace.Section?) -> some View {
        let isFavorite = section == .favorites
        let isPinned: Bool = { if case .pinned? = section { return true }; return false }()
        let inSplit = item.parentID.flatMap { store.workspace.item($0)?.isSplit } ?? false
        Button(isPinned || isFavorite ? "Unpin Tab" : "Pin Tab") { store.togglePin(itemID, in: window) }
        Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") { store.toggleFavorite(itemID, in: window) }
        if inSplit {
            Button("Separate from Split View") { store.separateFromSplit(itemID, in: window) }
        } else {
            Button("Add Split View") { store.select(itemID, in: window); store.addSplit(in: window) }
        }
        Divider()
        Button("Rename…") { renaming?.wrappedValue = itemID }
        Button("Duplicate") { store.duplicate(itemID, in: window) }
        if let url = item.tab?.url {
            Button("Copy Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
        }
        if item.tab?.homeURL != nil, item.tab?.homeURL != item.tab?.url {
            Button("Reset to Original URL") { store.resetTab(itemID, in: window) }
        }
        if store.runtime(forItem: itemID, in: window) != nil {
            let muted = store.runtime(forItem: itemID, in: window)?.isMuted ?? false
            Button(muted ? "Unmute Tab" : "Mute Tab") { store.toggleMute(itemID, in: window) }
        }
        if store.workspace.spaces.count > 1 {
            Menu("Move to Space") {
                ForEach(store.workspace.spaces.filter { $0.id != window.focusedSpaceID }) { s in
                    Button { store.moveTab(itemID, toSpace: s.id, in: window) } label: { Text(s.title) }
                }
            }
        }
        Divider()
        Button(isPinned || isFavorite ? "Put to Sleep" : "Archive Tab") { store.closeTab(itemID, in: window) }
    }
}

// MARK: - Spaces bar

struct SpacesBar: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Metrics.Space.hair) {
            DownloadsButton(store: store, window: window)
            Spacer(minLength: 0)
            ForEach(store.workspace.spaces) { space in
                SpaceButton(store: store, window: window, space: space)
            }
            Spacer(minLength: 0)
            ToolbarButton(symbol: "plus", help: "New Space") { store.beginNewSpace(in: window) }
        }
        .padding(.horizontal, Metrics.footerInset)
        .frame(height: Metrics.Height.bar)
        .overlay(alignment: .top) { Rectangle().fill(palette.stroke).frame(height: 0.5).padding(.horizontal, Metrics.Sidebar.gutter) }
    }
}

struct SpaceButton: View {
    let store: BrowserStore
    let window: WindowState
    let space: Space
    @Environment(\.palette) private var palette
    @Local private var hover = false

    var body: some View {
        let selected = space.id == window.focusedSpaceID
        Button {
            withAnimation(Motion.glide) { store.switchSpace(to: space.id, in: window) }
        } label: {
            SpaceIconView(icon: space.icon, size: 14)
                .symbolBounce(value: selected)
                .foregroundStyle(selected ? palette.text : palette.secondary)
                .frame(width: 30, height: Metrics.Height.button)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
                        .fill(selected ? palette.selected : (hover ? palette.hover : .clear))
                )
                .overlay(alignment: .bottom) {
                    if selected { Capsule().fill(Color(space.theme.accent)).frame(width: 10, height: 2.5).offset(y: 5).transition(.scale.combined(with: .opacity)) }
                }
                .animation(Motion.spring, value: selected)
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .onHover { hover = $0 }
        .help(space.title)
        .contextMenu { SpaceMenuItems(store: store, window: window, space: space) }
    }
}

struct DownloadsButton: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette

    var body: some View {
        let d = store.downloads
        ZStack {
            ToolbarButton(symbol: "arrow.down.circle", bounce: d.items.count, help: "Downloads (⇧⌘J)") { window.overlay = window.overlay == .downloads ? nil : .downloads }
                .spatial("footer.glyph")
            if d.hasActive {
                Circle().trim(from: 0, to: max(0.05, d.overallFraction)).stroke(palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 22, height: 22).allowsHitTesting(false)
            }
        }
        .opacity(d.items.isEmpty ? 0.55 : 1)
    }
}
