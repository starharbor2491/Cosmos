import SwiftUI
import AppKit
import CosmosCore

/// The window's SwiftUI root: themed backdrop, sidebar, page area and every overlay.
struct BrowserRootView: View {
    let store: BrowserStore
    let window: WindowState

    private var space: Space { store.workspace.space(window.focusedSpaceID) ?? store.workspace.spaces[0] }

    var body: some View {
        let palette = Palette(theme: space.theme)
        ZStack(alignment: .topLeading) {
            ThemeBackground(theme: space.theme)
                .id(space.id)
                .transition(.opacity)

            HStack(spacing: 0) {
                if window.sidebarVisible {
                    SidebarView(store: store, window: window)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    SidebarResizeHandle(window: window, store: store)
                }
                ContentArea(store: store, window: window)
            }

            if !window.sidebarVisible { SidebarRevealLayer(store: store, window: window) }

            OverlayLayer(store: store, window: window)
        }
        .environment(\.palette, palette)
        .animation(.easeInOut(duration: 0.45), value: space.id)
        .animation(.easeInOut(duration: 0.2), value: window.sidebarVisible)
        .animation(.easeOut(duration: 0.16), value: window.overlay)
        .preferredColorScheme(palette.isDark ? .dark : .light)
        .frame(minWidth: 760, minHeight: 480)
    }
}

// MARK: - Content area

struct ContentArea: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette

    var body: some View {
        let _ = store.runtimeRevision
        let selected = window.selectedItemID.flatMap { store.workspace.item($0) }
        let panes = Self.panes(store: store, window: window, selected: selected)
        let split: (SplitData.Orientation, [Double], UUID?)? = {
            if case .split(let s)? = selected?.content { return (s.orientation, s.weights, s.focusedChildID) }
            return nil
        }()
        let splitID = selected?.isSplit == true ? selected?.id : nil

        VStack(spacing: 0) {
            if !window.sidebarVisible { CompactTopBar(store: store, window: window) }
            ZStack {
                if panes.isEmpty {
                    EmptyStateView(store: store, window: window)
                } else {
                    WebContentRepresentable(
                        runtimes: panes,
                        focusedID: split?.2 ?? panes.first?.itemID,
                        orientation: split?.0 ?? .horizontal,
                        weights: split?.1 ?? [],
                        accent: NSColor(palette.accentRaw),
                        wantsFocus: window.overlay == nil && window.peek == nil,
                        revision: store.runtimeRevision,
                        onWeights: { w in if let splitID { store.edit { $0.setSplit(splitID) { $0.weights = w } } } }
                    )
                }

                if window.overlay == .find { FindBar(store: store, window: window).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(14) }
                if let peek = window.peek { PeekOverlay(store: store, window: window, peek: peek) }
                StatusBubble(store: store, window: window)
                ToastView(window: window)
            }
            .padding(EdgeInsets(top: window.sidebarVisible ? 8 : 0, leading: window.sidebarVisible ? 0 : 8, bottom: 8, trailing: 8))
            .background(alignment: .top) { if window.sidebarVisible { WindowDragArea().frame(height: 8) } }
        }
    }

    static func panes(store: BrowserStore, window: WindowState, selected: SidebarItem?) -> [TabRuntime] {
        guard let selected else { return [] }
        switch selected.content {
        case .tab: return [store.runtime(forItem: selected.id, in: window)].compactMap { $0 }
        case .split: return selected.childIDs.compactMap { store.runtime(forItem: $0, in: window) }
        default: return []
        }
    }
}

/// Toolbar shown above the page while the sidebar is hidden.
struct CompactTopBar: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette

    var body: some View {
        let rt = store.currentRuntime(in: window)
        HStack(spacing: 2) {
            Color.clear.frame(width: window.isFullScreen ? 6 : 74, height: 1)
            ToolbarButton(symbol: "sidebar.left", help: "Show Sidebar (⌘S)") { window.sidebarVisible = true }
            ToolbarButton(symbol: "chevron.left", enabled: rt?.canGoBack ?? false, help: "Back") { rt?.goBack() }
            ToolbarButton(symbol: "chevron.right", enabled: rt?.canGoForward ?? false, help: "Forward") { rt?.goForward() }
            ToolbarButton(symbol: (rt?.isLoading ?? false) ? "xmark" : "arrow.clockwise", enabled: rt != nil, help: "Reload") {
                if rt?.isLoading == true { rt?.stop() } else { rt?.reload() }
            }
            URLPill(store: store, window: window).frame(maxWidth: 440).padding(.horizontal, 8)
            Spacer(minLength: 0)
        }
        .padding(.trailing, 8)
        .frame(height: 40)
        .background(WindowDragArea())
    }
}

struct StatusBubble: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette

    var body: some View {
        let text = store.currentRuntime(in: window)?.hoverURL?.absoluteString
        VStack {
            Spacer()
            HStack {
                if let text, store.settings.showStatusBubble {
                    Text(text)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(palette.text)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous).strokeBorder(palette.stroke, lineWidth: 0.5))
                        .frame(maxWidth: 520, alignment: .leading)
                        .padding(8)
                        .transition(.opacity)
                }
                Spacer()
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: text)
    }
}

struct ToastView: View {
    let window: WindowState
    @Environment(\.palette) private var palette

    var body: some View {
        VStack {
            Spacer()
            if let toast = window.toast {
                HStack(spacing: 8) {
                    Image(systemName: toast.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.accent)
                    Text(toast.text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(palette.text)
                    if let title = toast.actionTitle {
                        Button(title) { toast.action?(); window.toast = nil }
                            .buttonStyle(.plain).font(.system(size: 12.5, weight: .bold)).foregroundStyle(palette.accent)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.stroke, lineWidth: 0.5))
                .shadow(color: palette.shadow, radius: 14, y: 4)
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: window.toast)
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: WebContentHostView.corner, style: .continuous)
                .fill(palette.isDark ? Color.black.opacity(0.22) : Color.white.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: WebContentHostView.corner, style: .continuous).strokeBorder(palette.stroke, lineWidth: 0.5))
            VStack(spacing: 18) {
                CosmosLogo(size: 84)
                Text("Cosmos")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.text)
                Text("A calm place to explore the web.")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.secondary)
                VStack(alignment: .leading, spacing: 9) {
                    Tip(keys: "⌘T", text: "Open the Command Bar")
                    Tip(keys: "⌘L", text: "Search or enter an address")
                    Tip(keys: "⌥⌘←  ⌥⌘→", text: "Travel between spaces")
                    Tip(keys: "⌘D", text: "Pin a tab")
                    Tip(keys: "⌃⇧=", text: "Split the view")
                }
                .padding(.top, 6)
                if store.isFirstLaunch || !store.settings.hasCompletedOnboarding {
                    Button { window.overlay = .welcome } label: {
                        Label("Import from Arc…", systemImage: "arrow.down.doc")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Capsule().fill(palette.accent.opacity(0.9)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
            }
        }
    }

    struct Tip: View {
        let keys: String
        let text: String
        @Environment(\.palette) private var palette
        var body: some View {
            HStack(spacing: 12) {
                Text(keys)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.text)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: Metrics.Radius.chip, style: .continuous).fill(palette.hover.opacity(1.6)))
                    .frame(minWidth: 96, alignment: .trailing)
                Text(text).font(.system(size: 13)).foregroundStyle(palette.secondary)
            }
        }
    }
}

/// The Cosmos mark: a planet with a tilted ring and a few stars.
struct CosmosLogo: View {
    var size: CGFloat = 80

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(red: 0.62, green: 0.50, blue: 1.0), Color(red: 0.36, green: 0.22, blue: 0.86), Color(red: 0.95, green: 0.45, blue: 0.72)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.56, height: size * 0.56)
                .shadow(color: Color(red: 0.55, green: 0.40, blue: 1).opacity(0.6), radius: size * 0.16)
            Ellipse()
                .stroke(LinearGradient(colors: [.white.opacity(0.9), Color(red: 0.8, green: 0.75, blue: 1).opacity(0.35)], startPoint: .leading, endPoint: .trailing), lineWidth: size * 0.045)
                .frame(width: size * 1.02, height: size * 0.3)
                .rotationEffect(.degrees(-22))
            Circle().fill(.white).frame(width: size * 0.07, height: size * 0.07).offset(x: size * 0.4, y: -size * 0.3)
            Circle().fill(.white.opacity(0.7)).frame(width: size * 0.045, height: size * 0.045).offset(x: -size * 0.42, y: size * 0.28)
            Circle().fill(.white.opacity(0.5)).frame(width: size * 0.035, height: size * 0.035).offset(x: size * 0.1, y: size * 0.42)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Sidebar chrome

/// Drag handle on the sidebar's right edge.
struct SidebarResizeHandle: View {
    let window: WindowState
    let store: BrowserStore
    @Local private var startWidth: Double?

    var body: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if startWidth == nil { startWidth = window.sidebarWidth }
                        window.sidebarWidth = min(420, max(190, (startWidth ?? 248) + value.translation.width))
                    }
                    .onEnded { _ in startWidth = nil; store.settings.sidebarWidth = window.sidebarWidth }
            )
            .onTapGesture(count: 2) { window.sidebarWidth = 248; store.settings.sidebarWidth = 248 }
            .padding(.leading, -6)
            .zIndex(5)
    }
}

/// While the sidebar is hidden, touching the left edge slides it over the page.
struct SidebarRevealLayer: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette
    @Local private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if store.settings.revealSidebarOnHover && !window.sidebarPeeking {
                Color.clear.frame(width: 6).frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { hideTask?.cancel(); window.sidebarPeeking = true } }
            }
            if window.sidebarPeeking {
                SidebarView(store: store, window: window)
                    .background(.regularMaterial)
                    .background(ThemeBackground(theme: (store.workspace.space(window.focusedSpaceID) ?? store.workspace.spaces[0]).theme, animated: false).opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.page, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.page, style: .continuous).strokeBorder(palette.stroke, lineWidth: 0.5))
                    .shadow(color: palette.shadow, radius: 24, x: 4, y: 0)
                    .padding(.vertical, 8).padding(.leading, 8)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .onHover { inside in
                        hideTask?.cancel()
                        if !inside {
                            hideTask = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(350))
                                if !Task.isCancelled { window.sidebarPeeking = false }
                            }
                        }
                    }
            }
        }
        .animation(.easeOut(duration: 0.18), value: window.sidebarPeeking)
    }
}

/// A region that drags the window (the window has no title bar of its own) and zooms it on double click.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { super.mouseDown(with: event) }
        }
    }
}
