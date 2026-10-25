import SwiftUI
import AppKit
import CosmosCore

/// The vertical sidebar: toolbar, URL pill, Favorites, the space's Pinned and Today sections and the spaces bar.
struct SidebarView: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette

    @Local private var renaming: UUID?
    @Local private var indicator: DropIndicator?
    @Local private var hoveringToday = false

    private var space: Space { store.workspace.space(window.focusedSpaceID) ?? store.workspace.spaces[0] }

    var body: some View {
        VStack(spacing: 0) {
            SidebarToolbar(store: store, window: window)
            URLPill(store: store, window: window)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    FavoritesGrid(store: store, window: window, indicator: $indicator)
                    SpaceHeader(store: store, window: window, space: space)
                    PinnedSection(store: store, window: window, space: space, renaming: $renaming, indicator: $indicator)
                    TodaySection(store: store, window: window, space: space, renaming: $renaming, indicator: $indicator)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            SpacesBar(store: store, window: window)
        }
        .frame(width: window.sidebarWidth)
        .environment(\.palette, palette)
    }
}

// MARK: - Toolbar

struct ToolbarButton: View {
    let symbol: String
    var size: CGFloat = 13.5
    var enabled = true
    var help: String
    let action: () -> Void
    @Environment(\.palette) private var palette
    @Local private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover && enabled ? palette.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? palette.secondary : palette.tertiary.opacity(0.6))
        .disabled(!enabled)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct SidebarToolbar: View {
    let store: BrowserStore
    let window: WindowState

    var body: some View {
        let rt = store.currentRuntime(in: window)
        HStack(spacing: 0) {
            // Leave room for the traffic lights.
            Color.clear.frame(width: 74, height: 1)
            ToolbarButton(symbol: "sidebar.left", help: "Hide Sidebar (⌘S)") { window.sidebarVisible = false; window.sidebarPeeking = false }
            Spacer(minLength: 0)
            ToolbarButton(symbol: "chevron.left", enabled: rt?.canGoBack ?? false, help: "Back (⌘[)") { rt?.goBack() }
            ToolbarButton(symbol: "chevron.right", enabled: rt?.canGoForward ?? false, help: "Forward (⌘])") { rt?.goForward() }
            ToolbarButton(symbol: (rt?.isLoading ?? false) ? "xmark" : "arrow.clockwise", enabled: rt != nil,
                          help: (rt?.isLoading ?? false) ? "Stop (⌘.)" : "Reload (⌘R)") {
                if rt?.isLoading == true { rt?.stop() } else { rt?.reload() }
            }
        }
        .padding(.trailing, 6)
        .frame(height: 40)
    }
}

// MARK: - URL pill

struct URLPill: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette
    @Local private var hover = false

    var body: some View {
        let rt = store.currentRuntime(in: window)
        let url = store.currentURL(in: window)
        Button {
            window.overlay = .commandBar(url == nil ? .newTab : .currentTab)
            window.commandBarFocusToken += 1
        } label: {
            ZStack {
                HStack(spacing: 6) {
                    Image(systemName: Self.symbol(for: url, rt: rt))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.tertiary)
                    Spacer(minLength: 0)
                }
                Text(url == nil ? "Search or enter address" : URLInput.hostForDisplay(url))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(url == nil ? palette.tertiary : palette.text)
                    .lineLimit(1)
                    .padding(.horizontal, 22)
                HStack {
                    Spacer(minLength: 0)
                    if hover, url != nil {
                        Button {
                            if let url { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string); window.showToast("Link copied", symbol: "link") }
                        } label: {
                            Image(systemName: "link").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.secondary)
                        }
                        .buttonStyle(.plain).help("Copy Link (⇧⌘C)")
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? palette.hover.opacity(1.6) : palette.hover))
            .overlay(alignment: .bottom) {
                if let rt, rt.isLoading {
                    GeometryReader { g in
                        Capsule().fill(palette.accent).frame(width: g.size.width * max(0.06, rt.progress), height: 2)
                            .animation(.easeOut(duration: 0.2), value: rt.progress)
                    }
                    .frame(height: 2).padding(.horizontal, 8).clipped()
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.stroke, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Open Command Bar (⌘L)")
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
        HStack(spacing: 6) {
            SpaceIconView(icon: space.icon, size: 13)
                .foregroundStyle(palette.secondary)
            Text(space.title)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
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
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .frame(height: 24)
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

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(palette.tertiary)
            Rectangle().fill(palette.stroke).frame(height: 0.5)
            if let trailing {
                Button(action: { trailingAction?() }) {
                    Text(trailing).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(palette.secondary)
                }
                .buttonStyle(.plain)
                .opacity(hover ? 1 : 0)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}
