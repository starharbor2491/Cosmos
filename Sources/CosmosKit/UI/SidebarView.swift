import SwiftUI
import AppKit
import CosmosCore

/// The vertical sidebar: toolbar, URL pill, a strip of pages that slides (the Library, then each space with its
/// Favorites, Pinned and Today sections) and the spaces bar.
struct SidebarView: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette

    @Local private var renaming: UUID?
    @Local private var indicator: DropIndicator?
    @Local private var hoveringToday = false
    /// Which pages are on screen and where while the strip slides (see `SidebarSlide`), and the fingers that move it.
    @Local var slide: SidebarSlide
    @Local var swipe = SwipeTracker()

    init(store: BrowserStore, window: WindowState) {
        self.store = store
        self.window = window
        _slide = Local(wrappedValue: SidebarSlide(shown: window.sidebarPage))
    }

    var pages: [SidebarPage] { SidebarPage.all(spaces: store.workspace.spaces.map(\.id)) }

    var body: some View {
        VStack(spacing: 0) {
            // The Library is a rail of its own: the address and the page's controls go quiet above it (and stay in place,
            // so nothing below them moves).
            VStack(spacing: 0) {
                SidebarToolbar(store: store, window: window, compact: window.libraryOpen)
                Group {
                    URLPill(store: store, window: window)
                        .padding(.horizontal, Metrics.Sidebar.gutter)
                        .padding(.bottom, Metrics.Space.s)
                    ExtensionButtons(store: store, window: window)
                }
                .opacity(window.libraryOpen ? 0 : 1)
                .allowsHitTesting(!window.libraryOpen)
                .disabled(window.libraryOpen)
                .accessibilityHidden(window.libraryOpen)
            }
            .animation(Motion.slide, value: window.libraryOpen)

            SidebarPager(slide: slide, width: window.sidebarWidth) { page in
                switch page {
                case .library:
                    LibraryPage(store: store, window: window)
                case .space(let id):
                    if let space = store.workspace.space(id) {
                        SpacePage(store: store, window: window, space: space, renaming: $renaming, indicator: $indicator)
                    }
                }
            }
            SpacesBar(store: store, window: window)
        }
        .frame(width: window.sidebarWidth)
        .environment(\.palette, palette)
        .background(SwipeCatcher(onMove: swipeMoved, onEnd: swipeEnded))
        .onChange(of: window.sidebarPage) { _, page in slideTo(page) }
        .onChange(of: pages) { _, pages in slide.repair(pages: pages, current: window.sidebarPage) }
        .recordsSpatialFrames()
    }
}

/// One space's page of the sidebar: its Favorites, name, Pinned tabs and Today.
struct SpacePage: View {
    let store: BrowserStore
    let window: WindowState
    let space: Space
    @Binding var renaming: UUID?
    @Binding var indicator: DropIndicator?
    /// The highlight under the selected tab glides between rows of this page; each page has its own so two pages that
    /// are on screen together while the strip slides never share one.
    @Namespace private var selectionNamespace

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            // Lazy: a space with thousands of tabs builds the rows on screen, not all of them.
            LazyVStack(alignment: .leading, spacing: Metrics.Space.s) {
                FavoritesGrid(store: store, window: window, indicator: $indicator)
                SpaceHeader(store: store, window: window, space: space)
                PinnedSection(store: store, window: window, space: space, renaming: $renaming, indicator: $indicator)
                TodaySection(store: store, window: window, space: space, renaming: $renaming, indicator: $indicator)
            }
            .padding(.horizontal, Metrics.Sidebar.gutter)
            .padding(.bottom, Metrics.Space.m)
        }
        .environment(\.selectionNamespace, selectionNamespace)
        .animation(Motion.standard, value: window.selectedItemID)
    }
}

// MARK: - Toolbar

struct ToolbarButton: View {
    let symbol: String
    var size: CGFloat = 13.5
    /// The side of the square the button is pressed in.
    var box: CGFloat = Metrics.Height.button
    var enabled = true
    /// A turn the icon makes when something happens (reload).
    var rotation: Double = 0
    /// The icon bounces when this changes (a download started).
    var bounce = 0
    var help: String
    let action: () -> Void
    @Environment(\.palette) private var palette
    @Local private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .symbolSwap()
                .symbolBounce(value: bounce)
                .rotationEffect(.degrees(rotation))
                .frame(width: box, height: box)
                .background(RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous).fill(hover && enabled ? palette.hover : .clear))
                .contentShape(Rectangle())
                .animation(Motion.quick, value: hover)
        }
        .spatial("toolbar.button")
        .buttonStyle(PressableStyle(scale: 0.88))
        .foregroundStyle(enabled ? palette.secondary : palette.tertiary.opacity(0.6))
        .disabled(!enabled)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct SidebarToolbar: View {
    let store: BrowserStore
    let window: WindowState
    /// Only the button that hides the sidebar is left (over the Library).
    var compact = false
    @Local private var reloadTurns = 0.0

    var body: some View {
        let rt = store.currentRuntime(in: window)
        HStack(spacing: 0) {
            // Leave room for the traffic lights.
            Color.clear.frame(width: 74, height: 1)
            ToolbarButton(symbol: "sidebar.left", help: "Hide Sidebar (⌘S)") { store.leaveLibrary(in: window); window.sidebarVisible = false; window.sidebarPeeking = false }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                ToolbarButton(symbol: "chevron.left", enabled: rt?.canGoBack ?? false, help: "Back (⌘[)") { rt?.goBack() }
                ToolbarButton(symbol: "chevron.right", enabled: rt?.canGoForward ?? false, help: "Forward (⌘])") { rt?.goForward() }
                ToolbarButton(symbol: (rt?.isLoading ?? false) ? "xmark" : "arrow.clockwise", enabled: rt != nil, rotation: reloadTurns,
                              help: (rt?.isLoading ?? false) ? "Stop (⌘.)" : "Reload (⌘R)") {
                    if rt?.isLoading == true { rt?.stop() } else {
                        withAnimation(Motion.spring) { reloadTurns += 360 }
                        rt?.reload()
                    }
                }
            }
            .opacity(compact ? 0 : 1)
            .allowsHitTesting(!compact)
            .disabled(compact)
            .accessibilityHidden(compact)
        }
        .padding(.trailing, Metrics.Sidebar.gutter)
        .frame(height: Metrics.Height.toolbar)
    }
}

// MARK: - URL pill

struct URLPill: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette
    @Local private var hover = false
    @Local private var copied = false

    var body: some View {
        let rt = store.currentRuntime(in: window)
        let url = store.currentURL(in: window)
        Button {
            window.overlay = .commandBar(url == nil ? .newTab : .currentTab)
            window.commandBarFocusToken += 1
        } label: {
            ZStack {
                HStack(spacing: 6) {
                    Button {
                        window.overlay = .siteControls
                    } label: {
                        Image(systemName: Self.symbol(for: url, rt: rt))
                            .font(.system(size: 11, weight: .semibold))
                            .symbolSwap()
                            .foregroundStyle(palette.tertiary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(url == nil)
                    .help("Site Controls")
                    Spacer(minLength: 0)
                }
                Text(url == nil ? "Search or enter address" : URLInput.hostForDisplay(url))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(url == nil ? palette.tertiary : palette.text)
                    .lineLimit(1)
                    .padding(.horizontal, 22)
                HStack {
                    Spacer(minLength: 0)
                    if hover || copied, url != nil {
                        Button { copyLink(url) } label: {
                            Image(systemName: copied ? "checkmark" : "link")
                                .font(.system(size: 11, weight: .semibold))
                                .symbolSwap()
                                .foregroundStyle(copied ? palette.accent : palette.secondary)
                        }
                        .buttonStyle(PressableStyle(scale: 0.85)).help("Copy Link (⇧⌘C)")
                        .transition(Motion.pop)
                    }
                }
            }
            .padding(.horizontal, Metrics.Sidebar.inset)
            .frame(height: Metrics.Height.field)
            .background(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).fill(hover ? palette.hoverStrong : palette.hover))
            .overlay(alignment: .bottom) {
                if let rt {
                    LoadingBar(isLoading: rt.isLoading, progress: rt.progress).id(rt.itemID)
                        .padding(.horizontal, 8).padding(.bottom, 1)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).strokeBorder(palette.stroke, lineWidth: 0.5))
            .contentShape(Rectangle())
            .spatial("pill")
            .animation(Motion.quick, value: hover)
            .animation(Motion.quick, value: copied)
        }
        .buttonStyle(PressableStyle(scale: 0.985))
        .onHover { hover = $0 }
        .help("Open Command Bar (⌘L)")
    }

    private func copyLink(_ url: URL?) {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        window.showToast("Link copied", symbol: "link")
        store.haptics.generic()
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }

    static func symbol(for url: URL?, rt: TabRuntime?) -> String {
        guard let url else { return "magnifyingglass" }
        if rt?.loadFailed == true { return "exclamationmark.triangle.fill" }
        switch url.scheme {
        case "https": return "lock.fill"
        case "http": return "lock.open.fill"
        case "file": return "doc"
        default: return "globe"
        }
    }
}

// MARK: - Section chrome

struct SpaceHeader: View {
    let store: BrowserStore
    let window: WindowState
    let space: Space
    @Environment(\.palette) private var palette
    @Local private var hover = false

    var body: some View {
        HStack(spacing: Metrics.Sidebar.gap) {
            SpaceIconView(icon: space.icon, size: 13)
                .frame(width: Metrics.Icon.row)
                .foregroundStyle(palette.secondary)
                .spatial("header.icon")
            Text(space.title)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                .spatial("header.title")
            Spacer(minLength: 0)
            Menu {
                SpaceMenuItems(store: store, window: window, space: space)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(palette.tertiary)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, Metrics.Sidebar.inset)
        .frame(height: Metrics.Height.header)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

struct SpaceIconView: View {
    let icon: SpaceIcon
    var size: CGFloat = 14

    var body: some View {
        switch icon {
        case .emoji(let e): Text(e).font(.system(size: size))
        case .symbol(let s): Image(systemName: s).font(.system(size: size, weight: .semibold))
        }
    }
}

struct SpaceMenuItems: View {
    let store: BrowserStore
    let window: WindowState
    let space: Space

    var body: some View {
        Button("Edit Theme…") { window.overlay = .themeEditor(space.id) }
        Button("Rename Space…") { window.overlay = .themeEditor(space.id) }
        if store.workspace.profiles.count > 1 {
            Menu("Change Profile") {
                ForEach(store.workspace.profiles) { p in
                    Button { store.changeProfile(ofSpace: space.id, to: p.id) } label: {
                        Label(p.name, systemImage: p.id == space.profileID ? "checkmark" : "person.crop.circle")
                    }
                }
            }
        }
        Divider()
        Button("Move Space Up") { store.moveSpace(space.id, by: -1) }.disabled(store.workspace.spaceIndex(space.id) == 0)
        Button("Move Space Down") { store.moveSpace(space.id, by: 1) }.disabled(store.workspace.spaceIndex(space.id) == store.workspace.spaces.count - 1)
        Divider()
        Button("Reset Pinned Tabs") { store.resetPinned(in: window) }
        Button("Collapse All Folders") { store.setAllFolders(expanded: false, in: window) }
        Button("Expand All Folders") { store.setAllFolders(expanded: true, in: window) }
        Divider()
        Button("Delete Space", role: .destructive) { store.deleteSpace(space.id, in: window) }.disabled(store.workspace.spaces.count < 2)
    }
}

struct SectionDivider: View {
    let title: String
    var trailing: String?
    var trailingAction: (() -> Void)?
    @Environment(\.palette) private var palette
    @Local private var hover = false

    /// Wide enough for "Archive All" at this size.
    private static let actionWidth: CGFloat = 64

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(palette.tertiary)
                .spatial("divider.title")
            // The rule runs to the row's edge; the action makes room for itself by shortening it while you hover.
            Rectangle().fill(palette.stroke).frame(height: 0.5)
                .padding(.leading, Metrics.Sidebar.gap)
                .spatial("divider.rule")
            if let trailing {
                Button(action: { trailingAction?() }) {
                    Text(trailing).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(palette.secondary).fixedSize()
                }
                .buttonStyle(.plain)
                .frame(width: hover ? Self.actionWidth : 0, alignment: .trailing)
                .clipped()
                .opacity(hover ? 1 : 0)
                .padding(.leading, hover ? Metrics.Sidebar.gap : 0)
            }
        }
        .animation(Motion.quick, value: hover)
        .padding(.horizontal, Metrics.Sidebar.inset)
        .frame(height: Metrics.Height.header)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}
