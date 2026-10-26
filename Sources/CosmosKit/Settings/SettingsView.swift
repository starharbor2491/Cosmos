import SwiftUI
import AppKit
import CosmosCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, sidebar, blocking, extensions, privacy, links, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .sidebar: "Sidebar"
        case .blocking: "Blocking"
        case .extensions: "Extensions"
        case .privacy: "Privacy"
        case .links: "Links"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .sidebar: "sidebar.left"
        case .blocking: "shield.lefthalf.filled"
        case .extensions: "puzzlepiece.extension"
        case .privacy: "hand.raised"
        case .links: "arrow.triangle.branch"
        case .about: "sparkles"
        }
    }
}

/// An in-window question, shown instead of a system alert so it looks like the rest of Settings.
@MainActor
@Observable
final class SettingsModel {
    struct Dialog: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var message: String
        var bullets: [String] = []
        var confirmTitle: String
        var destructive = false
    }

    private(set) var dialog: Dialog?
    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?

    /// Shows the question and waits for the answer. A question that arrives while another is open cancels the first.
    func confirm(_ dialog: Dialog) async -> Bool {
        resolve(false)
        self.dialog = dialog
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ answer: Bool) {
        dialog = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: answer)
    }
}

/// The Settings window (⌘,): the current space's sky behind a column of sections and one pane at a time. Every control
/// in it is drawn by Cosmos (see SettingsControls.swift).
struct SettingsView: View {
    let store: BrowserStore
    @Local private var tab: SettingsTab
    @Local private var model = SettingsModel()
    private let dropdowns: DropdownHost
    @Namespace private var navGlide
    @FocusState private var dialogFocused: Bool

    /// The whole window, title bar included: the sky runs edge to edge under the window buttons.
    static let size = CGSize(width: 840, height: 648)
    /// The coordinates dropdown fields report their frames in, and their lists are placed in.
    static let coordinateSpace = "settings.root"

    /// `dropdowns` is the window's layer for open dropdown lists; whoever owns the window may keep it to open one.
    @MainActor
    init(store: BrowserStore, tab: SettingsTab = .general, dropdowns: DropdownHost? = nil) {
        self.store = store
        let dropdowns = dropdowns ?? DropdownHost()
        self.dropdowns = dropdowns
        dropdowns.haptics = store.haptics
        _tab = Local(wrappedValue: tab)
    }

    private var theme: SpaceTheme {
        let focused = (store.activeWindow ?? store.windows.first)?.focusedSpaceID
        return focused.flatMap { store.workspace.space($0)?.theme } ?? store.workspace.spaces.first?.theme ?? .nebula
    }

    var body: some View {
        let palette = Palette(theme: theme)
        ZStack {
            ThemeBackground(theme: theme, animated: false)
            HStack(spacing: 0) {
                nav(palette)
                content(palette)
            }
            // While a question is open nothing behind it can be reached, with the pointer, Tab or VoiceOver.
            .disabled(model.dialog != nil)
            .accessibilityHidden(model.dialog != nil)
            DropdownLayer(host: dropdowns)
            if let dialog = model.dialog {
                dialogLayer(dialog, palette)
            }
        }
        .coordinateSpace(name: Self.coordinateSpace)
        .onPreferenceChange(DropdownFrameKey.self) { frames in
            MainActor.assumeIsolated { dropdowns.setFrames(frames) }
        }
        // A list left open when the pane changes or a question appears would point at nothing.
        .onChange(of: tab) { dropdowns.close() }
        .onChange(of: model.dialog?.id) { dropdowns.close() }
        .environment(\.palette, palette)
        .environment(\.haptics, store.haptics)
        .environment(\.dropdownHost, dropdowns)
        .preferredColorScheme(palette.isDark ? .dark : .light)
        .frame(width: Self.size.width, height: Self.size.height)
        .ignoresSafeArea()
        .animation(Motion.quick, value: model.dialog?.id)
        // A question still open when the window closes is answered "no", so whoever asked is not left waiting.
        .onDisappear { model.resolve(false) }
    }

    // MARK: Navigation

    private func nav(_ palette: Palette) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Space.hair) {
            HStack(spacing: Metrics.Space.m) {
                CosmosLogo(size: 26)
                Text("Settings").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(palette.text)
            }
            .padding(.horizontal, Metrics.Space.m)
            .padding(.top, 52)
            .padding(.bottom, Metrics.Space.m)

            ForEach(SettingsTab.allCases) { item in
                let selected = item == tab
                TapTarget(label: item.title, scale: 0.97, feel: .step, traits: .isButton, action: { tab = item }) { state in
                    HStack(spacing: Metrics.Sidebar.gap) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: Metrics.Icon.row)
                            .foregroundStyle(selected ? palette.text : palette.secondary)
                        Text(item.title).font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? palette.text : palette.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Metrics.Space.m)
                    .frame(height: Metrics.Height.field)
                    .background {
                        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
                        if selected {
                            shape.fill(palette.selected).shadow(color: palette.shadow.opacity(0.3), radius: 3, y: 1)
                                .overlay(shape.strokeBorder(palette.stroke, lineWidth: 0.8))
                                .matchedGeometryEffect(id: "settings.nav", in: navGlide)
                        } else if state.hover {
                            shape.fill(palette.hover)
                        }
                    }
                    .focusRing(state.focused, radius: Metrics.Radius.row, palette: palette)
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.Space.s)
        .frame(width: Metrics.Control.navWidth)
        .animation(Motion.standard, value: tab)
    }

    // MARK: Panes

    private func content(_ palette: Palette) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.page, style: .continuous)
        return pane
            .id(tab)
            .transition(.opacity.combined(with: .offset(y: 8)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: shape)
            .background(shape.fill(palette.panel))
            .clipShape(shape)
            .overlay(shape.strokeBorder(palette.stroke, lineWidth: 0.8))
            .padding(.trailing, Metrics.Space.m)
            .padding(.vertical, Metrics.Space.m)
            .animation(Motion.standard, value: tab)
    }

    @ViewBuilder
    private var pane: some View {
        switch tab {
        case .general: GeneralPane(store: store)
        case .sidebar: SidebarPane(store: store)
        case .blocking: BlockingPane(store: store)
        case .extensions: ExtensionsPane(store: store, model: model)
        case .privacy: PrivacyPane(store: store, model: model)
        case .links: LinksPane(store: store)
        case .about: AboutPane(store: store)
        }
    }

    // MARK: Dialog

    private func dialogLayer(_ dialog: SettingsModel.Dialog, _ palette: Palette) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.panel, style: .continuous)
        return ZStack {
            Color.black.opacity(0.42)
                .contentShape(Rectangle())
                .onTapGesture { model.resolve(false) }
                .transition(.opacity)
            VStack(alignment: .leading, spacing: Metrics.Space.m) {
                Text(dialog.title).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(palette.text)
                if !dialog.message.isEmpty {
                    Text(dialog.message).font(.system(size: 13)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !dialog.bullets.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(dialog.bullets, id: \.self) { line in
                            HStack(alignment: .top, spacing: Metrics.Space.s) {
                                Circle().fill(palette.accent).frame(width: 5, height: 5).padding(.top, 6)
                                Text(line).font(.system(size: 13)).foregroundStyle(palette.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                HStack(spacing: Metrics.Space.s) {
                    Spacer(minLength: 0)
                    ActionButton(title: "Cancel", kind: .secondary) { model.resolve(false) }
                    ActionButton(title: dialog.confirmTitle, kind: dialog.destructive ? .destructive : .primary) { model.resolve(true) }
                }
                .padding(.top, Metrics.Space.xs)
            }
            .padding(Metrics.Space.xl)
            .frame(width: Metrics.Control.dialogWidth)
            .background(.regularMaterial, in: shape)
            .background(shape.fill(palette.panel))
            .overlay(shape.strokeBorder(palette.stroke, lineWidth: 0.8))
            .shadow(color: palette.shadow, radius: 36, y: 14)
            .focusable()
            .focused($dialogFocused)
            .focusEffectDisabled()
            .onKeyPress(.escape) { model.resolve(false); return .handled }
            .onAppear { dialogFocused = true }
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
    }
}
