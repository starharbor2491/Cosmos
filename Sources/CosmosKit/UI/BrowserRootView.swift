import SwiftUI
import AppKit
import CosmosCore

/// The window's SwiftUI root: themed backdrop, sidebar, page area and every overlay.
struct BrowserRootView: View {
    let store: BrowserStore
    let window: WindowState

    private var space: Space { store.workspace.space(window.focusedSpaceID) ?? store.workspace.spaces[0] }

    private func theme(_ id: UUID) -> SpaceTheme { (store.workspace.space(id) ?? space).theme }

    /// While the sidebar is on screen the window goes by where its strip is (`SidebarLook`), so the sky and colours move
    /// toward the next space under the fingers; with it hidden, by the space the window is on.
    private var look: SidebarLook? { window.sidebarVisible || window.sidebarPeeking ? window.sidebarLook : nil }

    var body: some View {
        let look = self.look
        let floats = PaneFit.utilityFloats(window)
        ZStack(alignment: .topLeading) {
            sky(look)

            HStack(spacing: 0) {
                if window.sidebarVisible {
                    SidebarView(store: store, window: window)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    SidebarResizeHandle(window: window, store: store)
                }
                ContentArea(store: store, window: window)
                    .overlay(alignment: .topTrailing) {
                        // No room beside the page: over its edge instead.
                        if floats, window.railShown, let utility = window.utility {
                            UtilityPanel(store: store, window: window, utility: utility, floating: true)
                                .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
                                .padding(.trailing, Metrics.Space.s)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                if let panel = window.sidePanel {
                    ExtensionSidePanelView(store: store, window: window, panel: panel)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                if window.railShown {
                    if !floats, let utility = window.utility {
                        UtilityPanel(store: store, window: window, utility: utility)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    UtilitiesRail(store: store, window: window)
                }
            }
            // Under the welcome's light as it ends, the window waits a little large and soft, then settles into place.
            .scaleEffect(window.arriving ? 1.035 : 1)
            .blur(radius: window.arriving ? 10 : 0)

            if !window.sidebarVisible { SidebarRevealLayer(store: store, window: window) }

            OverlayLayer(store: store, window: window)

            if let radial = window.radial {
                RadialMenuView(session: radial)
                    .id(radial.id)
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .modifier(Colours(from: theme(look?.space ?? space.id), to: look?.other.map(theme), mix: Double(look?.mix ?? 0)))
        .environment(\.haptics, store.haptics)
        .environment(\.appIconStyle, store.settings.appIcon)
        .animation(Motion.standard, value: window.sidebarVisible)
        .animation(Motion.standard, value: window.sidePanel?.extensionID)
        .animation(Motion.standard, value: window.utility)
        .animation(Motion.standard, value: window.railShown)
        .animation(Motion.quick, value: window.overlay)
        .frame(minWidth: 760, minHeight: 480)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { window.contentWidth = g.size.width }
                .onChange(of: g.size.width) { _, width in window.contentWidth = width }
        })
    }
}

extension BrowserRootView {
    /// The window's backdrop. With the sidebar's strip between two spaces, the other space's sky over this one's, as clear
    /// as the strip is far from it (the strip settling animates it). With no sidebar, a change of space dissolves one sky
    /// into the next.
    private func sky(_ look: SidebarLook?) -> some View {
        // One layer for the sky on show, the same view whether the sidebar's look or the window's space says which it is,
        // so the sidebar going away (⌘S) changes nothing on screen.
        let shown = look?.space ?? space.id
        return ZStack {
            ThemeBackground(theme: theme(shown))
                .id(shown)
                .transition(.opacity)
            if let look, let other = look.other { ThemeBackground(theme: theme(other)).opacity(look.mix) }
        }
        .animation(look == nil ? Motion.glide : nil, value: shown)
    }

    /// The colours of everything over the sky: `mix` of the way from `from`'s to `to`'s. Animatable, so the colours follow
    /// the strip's settling frame by frame, as the sky does.
    private struct Colours: ViewModifier, Animatable {
        let from: SpaceTheme
        let to: SpaceTheme?
        var mix: Double

        var animatableData: Double {
            get { mix }
            set { mix = newValue }
        }

        func body(content: Content) -> some View {
            let palette = to.map { Palette(theme: from, $0, t: mix) } ?? Palette(theme: from)
            content
                .environment(\.palette, palette)
                .preferredColorScheme(palette.isDark ? .dark : .light)
        }
    }
}

/// What fits beside the page in a window, so that the page keeps at least `minimumPage`: the Library's wider sidebar
/// narrows (never below the user's own width), and a utility panel with no room beside the page floats over its edge.
@MainActor
enum PaneFit {
    static let minimumPage = 360.0

    /// What is always beside the page on the right: the utilities rail, an extension's side panel.
    static func besidePage(_ window: WindowState) -> Double {
        (window.railShown ? Double(UtilitiesRail.width) : 0)
            + (window.sidePanel != nil ? Double(ExtensionSidePanelView.width) + 2 * Double(Metrics.Space.s) : 0)
    }

    static func sidebarWidth(_ window: WindowState) -> Double {
        window.libraryOpen ? libraryWidth(window) : window.sidebarWidth
    }

    /// The sidebar's width while it shows the Library.
    static func libraryWidth(_ window: WindowState) -> Double {
        let room = window.contentWidth > 0 ? window.contentWidth - besidePage(window) - minimumPage : LibraryPage.width
        return max(window.sidebarWidth, min(LibraryPage.width, room))
    }

    static func utilityFloats(_ window: WindowState) -> Bool {
        guard window.contentWidth > 0, window.utility != nil else { return false }
        let sidebar = window.sidebarVisible ? sidebarWidth(window) : 0
        return window.contentWidth - sidebar - besidePage(window) - Double(UtilityPanel.width) < minimumPage
    }
}

// MARK: - Extension side panel

/// An extension's side panel (`chrome.sidePanel`), beside the page: its name, a close button, and its page.
struct ExtensionSidePanelView: View {
    let store: BrowserStore
    let window: WindowState
    let panel: WindowState.SidePanel
    @Environment(\.palette) private var palette

    static let width: CGFloat = 360

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.Space.s) {
                Text(panel.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(palette.text).lineLimit(1)
                Spacer(minLength: 0)
                ToolbarButton(symbol: "xmark", size: 11, box: Metrics.Height.compactButton, help: "Close side panel") {
                    panel.runtime.tearDown()
                    window.sidePanel = nil
                }
                .accessibilityLabel("Close side panel")
            }
            .frame(height: Metrics.Height.toolbar)
            WebContentRepresentable(runtimes: [panel.runtime], focusedID: nil, orientation: .horizontal, weights: [],
                                    accent: NSColor(palette.accentRaw), wantsFocus: false, revision: store.runtimeRevision, onWeights: { _ in })
        }
        .frame(width: Self.width)
        .padding(EdgeInsets(top: 0, leading: Metrics.Space.s, bottom: Metrics.Space.s, trailing: Metrics.Space.s))
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

                if !store.engineStatus.isReady { EngineStatusCard(store: store).transition(.opacity) }
                if window.overlay == .find { FindBar(store: store, window: window).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(14) }
                if let rt = panes.first(where: { $0.danger != nil }) { DangerBar(runtime: rt).transition(.opacity) }
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
        // A link under the pointer when the Library came up stays "hovered" (the page never hears the pointer leave).
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
        .animation(Motion.quick, value: text)
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
                    Image(systemName: toast.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.accentGlyph)
                    Text(toast.text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(palette.text)
                    if let title = toast.actionTitle {
                        Button(title) { toast.action?(); window.toast = nil }
                            .buttonStyle(.plain).font(.system(size: 12.5, weight: .bold)).foregroundStyle(palette.accentText)
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
        .animation(Motion.spring, value: window.toast)
    }
}

// MARK: - Engine status

/// Over the page area while there is no engine to draw pages: Chromium is being downloaded on the first launch, or could
/// not be.
/// Under the warning page Cosmos shows in place of a site on a malware or phishing list: back to safety, or on anyway.
struct DangerBar: View {
    let runtime: TabRuntime
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.red)
            Text(runtime.danger?.kind == .malware ? "This site may harm your Mac." : "This site may be pretending to be another.")
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(palette.text)
            Button { runtime.leaveDangerousSite() } label: {
                Text("Go Back").font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(Capsule().fill(palette.accentFill)).foregroundStyle(palette.onAccent)
            }
            .buttonStyle(.plain)
            Button { runtime.visitDangerousSiteAnyway() } label: {
                Text("Visit Anyway").font(.system(size: 12.5)).foregroundStyle(palette.secondary).padding(.horizontal, 6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .background(Capsule().fill(palette.panel))
        .overlay(Capsule().strokeBorder(palette.stroke, lineWidth: 0.6))
        .shadow(color: palette.shadow, radius: 16, y: 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 22)
    }
}

struct EngineStatusCard: View {
    let store: BrowserStore
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: WebContentHostView.corner, style: .continuous)
                .fill(palette.isDark ? Color.black.opacity(0.55) : Color.white.opacity(0.75))
                .overlay(RoundedRectangle(cornerRadius: WebContentHostView.corner, style: .continuous).strokeBorder(palette.stroke, lineWidth: 0.5))
            VStack(spacing: 14) {
                CosmosLogo(size: 64)
                switch store.engineStatus {
                case .preparing(let what, let progress):
                    Text(what).font(.system(size: 17, weight: .semibold)).foregroundStyle(palette.text)
                    if let progress {
                        ProgressView(value: progress).progressViewStyle(.linear).frame(width: 240).tint(palette.accent)
                        Text("\(Int(progress * 100))%").font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(palette.tertiary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                case .failed(let why):
                    Text("Cosmos has no Chromium to draw pages with").font(.system(size: 17, weight: .semibold)).foregroundStyle(palette.text)
                    Text(why + " Chromium is part of Cosmos: installing Cosmos again puts it back.")
                        .font(.system(size: 12.5)).foregroundStyle(palette.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                case .ready:
                    EmptyView()
                }
            }
            .padding(24)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let store: BrowserStore
    let window: WindowState
    /// The welcome's preview of this page leaves out the import button, which is gone once the welcome is done.
    var offersImport = true
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: WebContentHostView.corner, style: .continuous)
                .fill(palette.isDark ? Color.black.opacity(0.22) : Color.white.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: WebContentHostView.corner, style: .continuous).strokeBorder(palette.stroke, lineWidth: 0.5))
            VStack(spacing: 0) {
                CosmosLogo(size: 60)
                    .padding(.bottom, Metrics.Space.l)
                Text(Self.greeting(at: Date()))
                    .font(.system(size: 28, weight: .semibold))
                    .kerning(-0.5)
                    .foregroundStyle(palette.text)
                    .padding(.bottom, Metrics.Space.l)
                // The page starts where the welcome's practice did: the Command Bar.
                TapTarget(label: "Search or enter address", scale: 0.99, action: openCommandBar) { state in
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .semibold))
                        Text("Search or enter address").font(.system(size: 15))
                        Spacer(minLength: Metrics.Space.m)
                        Text("⌘T")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: Metrics.Radius.chip, style: .continuous).fill(palette.hoverStrong))
                    }
                    .foregroundStyle(palette.secondary)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: 440)
                    .frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.hover.opacity(state.hover ? 1.4 : 1)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.stroke, lineWidth: 0.7))
                    .shadow(color: palette.shadow.opacity(state.hover ? 0.3 : 0.15), radius: state.hover ? 14 : 8, y: 3)
                    .animation(Motion.quick, value: state.hover)
                }
                .padding(.horizontal, 24)
                HStack(spacing: 18) {
                    Tip(keys: "⌥⌘→", text: "Next space")
                    Tip(keys: "⌘D", text: "Pin a tab")
                    Tip(keys: "⌃⇧=", text: "Split view")
                }
                .padding(.top, 18)
                if offersImport, !store.settings.hasCompletedOnboarding {
                    Button { window.overlay = .importBrowser } label: {
                        Label("Import from Arc…", systemImage: "arrow.down.doc")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Capsule().fill(palette.accentFill))
                            .foregroundStyle(palette.onAccent)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 22)
                }
            }
        }
    }

    private func openCommandBar() {
        window.overlay = .commandBar(.newTab)
        window.commandBarFocusToken += 1
    }

    /// Good morning, afternoon or evening, by the clock.
    static func greeting(at date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    struct Tip: View {
        let keys: String
        let text: String
        @Environment(\.palette) private var palette
        var body: some View {
            HStack(spacing: 7) {
                Text(keys)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.text)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: Metrics.Radius.chip, style: .continuous).fill(palette.hoverStrong))
                Text(text).font(.system(size: 12.5)).foregroundStyle(palette.secondary)
            }
        }
    }
}

/// The Cosmos mark: the app icon, cropped to its tile so `size` is the tile's size.
struct CosmosLogo: View {
    var size: CGFloat = 80
    @Environment(\.appIconStyle) private var style

    var body: some View {
        Image(nsImage: AppIcon.image(style))
            .resizable()
            .interpolation(.high)
            .scaleEffect(AppIcon.canvas / AppIcon.tile)
            .frame(width: size, height: size)
            .clipped()
            .accessibilityHidden(true)
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
                        window.sidebarWidth = min(WindowState.sidebarWidthRange.upperBound, max(WindowState.sidebarWidthRange.lowerBound, (startWidth ?? 248) + value.translation.width))
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
    @Local private var revealTask: Task<Void, Never>?
    /// How long the pointer rests on the edge before the sidebar comes: one passing by on its way to the Dock or another
    /// window does not slide it over the page.
    static let dwell: Duration = .milliseconds(150)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if store.settings.revealSidebarOnHover && !window.sidebarPeeking {
                Color.clear.frame(width: 6).frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        revealTask?.cancel()
                        guard inside else { return }
                        revealTask = Task { @MainActor in
                            try? await Task.sleep(for: Self.dwell)
                            guard !Task.isCancelled else { return }
                            hideTask?.cancel()
                            window.sidebarPeeking = true
                        }
                    }
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
        .animation(Motion.quick, value: window.sidebarPeeking)
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
