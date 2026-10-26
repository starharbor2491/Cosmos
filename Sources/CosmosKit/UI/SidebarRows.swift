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

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        let favorites = store.workspace.favorites
        let dragging = store.draggingItemID != nil
        Group {
            if favorites.isEmpty {
                if dragging {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .overlay(Text("Drop here to add a Favorite").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.tertiary))
                        .frame(height: 44)
                }
            } else {
                LazyVGrid(columns: columns, spacing: 6) {
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
                FaviconView(store: store, url: url, size: 24, cornerRadius: 6, fetch: true)
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
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? palette.selected : (hover ? palette.hover.opacity(1.8) : palette.hover))
                    .shadow(color: selected ? palette.shadow.opacity(0.5) : .clear, radius: 4, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(selected ? palette.stroke : .clear, lineWidth: 0.8))
            .overlay(DropMarker(indicator: indicator, id: item.id, axis: .horizontal))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(store.title(forItem: item.id, in: window))
        .contextMenu { ItemContextMenu(store: store, window: window, itemID: item.id) }
        .onDrag { store.beginDrag(item.id) }
        .onDrop(of: SidebarDrop.types, delegate: RowDropDelegate(store: store, window: window, targetID: item.id, axis: .horizontal, rowSize: 80, indicator: $indicator))
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
        VStack(spacing: 2) {
            if rows.isEmpty {
                if dragging {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(palette.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .overlay(Text("Drop here to pin").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.tertiary))
                        .frame(height: 34)
                }
            } else {
                ForEach(rows) { row in
                    SidebarItemView(store: store, window: window, itemID: row.id, depth: row.depth, renaming: $renaming, indicator: $indicator)
                }
            }
            Color.clear.frame(height: dragging ? 14 : 2)
        }
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
        VStack(spacing: 2) {
            SectionDivider(title: "Today", trailing: "Archive All") { store.clearUnpinned(in: window) }
            NewTabRow(store: store, window: window)
            ForEach(rows) { item in
                SidebarItemView(store: store, window: window, itemID: item.id, depth: 0, renaming: $renaming, indicator: $indicator)
            }
            Color.clear.frame(height: 24)
        }
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
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 18, height: 18)
                Text("New Tab").font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .foregroundStyle(hover ? palette.text : palette.secondary)
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? palette.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    var body: some View {
        let _ = store.runtimeRevision
        let rt = store.runtime(forItem: item.id, in: window)
        let selected = window.selectedItemID == item.id
        let focusedPane = inSplit && store.currentTabItemID(in: window) == item.id && window.selectedItemID != nil && store.workspace.item(item.id)?.parentID == window.selectedItemID
        let pinned: Bool = { if case .pinned? = store.workspace.section(of: item.id) { return true }; return false }()
        let asleep = rt == nil && pinned
        let url = rt?.url ?? item.tab?.url

        HStack(spacing: 8) {
            FaviconView(store: store, url: url, size: 18, fetch: true)
                .opacity(asleep ? 0.65 : 1)
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
            }
            Spacer(minLength: 2)
            trailing(rt: rt, pinned: pinned)
        }
        .padding(.leading, 8 + CGFloat(depth) * 14)
        .padding(.trailing, 6)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected && !inSplit ? palette.selected : (focusedPane ? palette.selected : (hover ? palette.hover : .clear)))
                .shadow(color: selected && !inSplit ? palette.shadow.opacity(0.4) : .clear, radius: 3, y: 1)
        )
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(selected && !inSplit ? palette.stroke : .clear, lineWidth: 0.8))
        .overlay(DropMarker(indicator: indicator, id: item.id, axis: .vertical))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if pinned { renaming = item.id } }
        .onTapGesture { store.select(item.id, in: window) }
        .onHover { hover = $0 }
        .help(item.tab?.url?.absoluteString ?? "")
        .contextMenu { ItemContextMenu(store: store, window: window, itemID: item.id, renaming: $renaming) }
        .onDrag { store.beginDrag(item.id) }
        .onDrop(of: SidebarDrop.types, delegate: RowDropDelegate(store: store, window: window, targetID: item.id, axis: .vertical, rowSize: 32, indicator: $indicator))
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
                .foregroundStyle(hover ? palette.text : palette.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(hover ? palette.hover.opacity(2) : .clear))
        }
        .buttonStyle(.plain)
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
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(folder.isExpanded ? 90 : 0))
                .foregroundStyle(palette.tertiary)
                .frame(width: 12)
            Image(systemName: folder.isExpanded ? "folder.fill" : "folder")
                .font(.system(size: 13))
                .foregroundStyle(palette.secondary)
                .frame(width: 18)
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
            }
            Spacer(minLength: 2)
            if !folder.isExpanded {
                Text("\(store.workspace.tabs(under: item.id).count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.tertiary)
            }
        }
        .padding(.leading, 6 + CGFloat(depth) * 14)
        .padding(.trailing, 8)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? palette.hover : .clear))
        .overlay(DropMarker(indicator: indicator, id: item.id, axis: .vertical))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.16)) { store.folderToggle(item.id) } }
        .onHover { hover = $0 }
        .contextMenu { ItemContextMenu(store: store, window: window, itemID: item.id, renaming: $renaming) }
        .onDrag { store.beginDrag(item.id) }
        .onDrop(of: SidebarDrop.types, delegate: RowDropDelegate(store: store, window: window, targetID: item.id, axis: .vertical, rowSize: 32, indicator: $indicator))
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
        VStack(spacing: 1) {
            ForEach(panes) { pane in
                TabRow(store: store, window: window, item: pane, depth: 0, renaming: $renaming, indicator: $indicator, inSplit: true)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(selected ? palette.selected.opacity(0.6) : palette.hover)
        )
        .overlay(alignment: .leading) {
            Capsule().fill(palette.accent.opacity(selected ? 0.95 : 0.5)).frame(width: 2.5).padding(.vertical, 8).offset(x: -1)
        }
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(selected ? palette.stroke : .clear, lineWidth: 0.8))
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
        HStack(spacing: 2) {
            DownloadsButton(store: store, window: window)
            Spacer(minLength: 0)
            ForEach(store.workspace.spaces) { space in
                SpaceButton(store: store, window: window, space: space)
            }
            Spacer(minLength: 0)
            ToolbarButton(symbol: "plus", help: "New Space") { store.beginNewSpace(in: window) }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(SwipeCatcher { delta in store.cycleSpace(delta, in: window) })
        .overlay(alignment: .top) { Rectangle().fill(palette.stroke).frame(height: 0.5).padding(.horizontal, 10) }
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
            withAnimation(.easeInOut(duration: 0.4)) { store.switchSpace(to: space.id, in: window) }
        } label: {
            SpaceIconView(icon: space.icon, size: 14)
                .foregroundStyle(selected ? palette.text : palette.secondary)
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? palette.selected : (hover ? palette.hover : .clear))
                )
                .overlay(alignment: .bottom) {
                    if selected { Capsule().fill(Color(space.theme.accent)).frame(width: 10, height: 2.5).offset(y: 5) }
                }
        }
        .buttonStyle(.plain)
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
            ToolbarButton(symbol: "arrow.down.circle", help: "Downloads (⇧⌘J)") { window.overlay = window.overlay == .downloads ? nil : .downloads }
            if d.hasActive {
                Circle().trim(from: 0, to: max(0.05, d.overallFraction)).stroke(palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 22, height: 22).allowsHitTesting(false)
            }
        }
        .opacity(d.items.isEmpty ? 0.55 : 1)
    }
}

/// Catches horizontal two-finger swipes over its area (swipe the spaces bar to change space).
struct SwipeCatcher: NSViewRepresentable {
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = SwipeView()
        v.onSwipe = onSwipe
        v.install()
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? SwipeView)?.onSwipe = onSwipe }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) { (nsView as? SwipeView)?.uninstall() }

    final class SwipeView: NSView {
        var onSwipe: ((Int) -> Void)?
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var fired = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p), abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
                if event.phase == .began { self.accumulated = 0; self.fired = false }
                self.accumulated += event.scrollingDeltaX
                if !self.fired, abs(self.accumulated) > 60 {
                    self.fired = true
                    self.onSwipe?(self.accumulated < 0 ? 1 : -1)
                }
                if event.phase == .ended || event.momentumPhase == .ended { self.accumulated = 0; self.fired = false }
                return nil
            }
        }

        func uninstall() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
