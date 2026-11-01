import SwiftUI
import AppKit
import CosmosCore

// MARK: - Bring

/// The browsers on this Mac, each a card with an Import button; what came across replaces the button.
struct BringStep: View {
    let model: OnboardingModel
    @Environment(\.onboardingCompact) private var compact

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(title: "Bring your browser along",
                      line: "Spaces, tabs and history come across in a moment. Nothing leaves this Mac.")
                .rise(0)
            Group {
                if !model.sourcesLoaded {
                    VStack(spacing: 10) { LoadingCard(); LoadingCard() }
                } else if model.sources.isEmpty {
                    Text(model.store.isIncognito ? "A private window keeps nothing, so bringing a browser along happens in a regular window."
                                                 : "There are no other browsers on this Mac to bring along. You can start fresh.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .glassCard()
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 10) {
                            ForEach(model.sources) { source in SourceCard(model: model, source: source) }
                        }
                    }
                    .frame(maxHeight: compact ? 260 : 380)
                    .fixedSize(horizontal: false, vertical: model.sources.count <= (compact ? 3 : 4))
                }
            }
            .padding(.top, compact ? 18 : 28)
            .rise(1)
        }
        .task { await model.loadSources() }
    }
}

private struct SourceCard: View {
    let model: OnboardingModel
    let source: ImportSource

    var body: some View {
        let result = model.results[source.id]
        let failure = model.failures[source.id]
        let running = model.running == source.id
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                AppIconView(icon: source.icon, symbol: source.symbol)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Text(result?.summary ?? failure ?? (running ? "Bringing it over…" : source.detail))
                        .font(.system(size: 13))
                        .foregroundStyle(failure != nil ? Color(red: 1, green: 0.62, blue: 0.6) : .white.opacity(result != nil ? 0.82 : 0.56))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 12)
                ZStack {
                    if running {
                        ProgressView().controlSize(.small).tint(.white).transition(.opacity)
                    } else if result != nil {
                        DoneMark().transition(.opacity)
                    } else {
                        PillButton(title: source.isAvailable ? "Import" : "Choose…", enabled: model.running == nil) { model.run(source) }
                            .transition(.opacity)
                    }
                }
                .frame(minWidth: 80, alignment: .trailing)
            }
            if source.bringsSpaces, model.hadSpaces, result == nil {
                AddOrReplace(model: model)
                    .padding(.top, 12)
                    .padding(.leading, 54)
            }
            if let result, result.offersSignIns {
                SignInsRow(model: model)
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let result, result.extensions > 0 {
                Text("Arc’s \(result.extensions) extension\(result.extensions == 1 ? "" : "s") can come too, from Settings ▸ Extensions.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 10)
                    .padding(.leading, 54)
            }
        }
        .padding(14)
        .glassCard(lit: result != nil)
        .animation(Motion.spring, value: result != nil)
        .animation(Motion.standard, value: running)
        .accessibilityElement(children: .contain)
    }
}

/// Where Arc's spaces go when there are spaces here already: alongside them, or in their place (after a backup).
private struct AddOrReplace: View {
    let model: OnboardingModel
    @Namespace private var glide

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                option("Alongside mine", replacing: false)
                option("Instead of mine", replacing: true)
            }
            .padding(2)
            .background(Capsule().fill(.white.opacity(0.08)))
            if model.replacing {
                Text("Cosmos keeps recent copies of your spaces in its Backups folder.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .transition(.opacity)
            }
        }
        .animation(Motion.standard, value: model.replacing)
    }

    private func option(_ title: String, replacing: Bool) -> some View {
        let selected = model.replacing == replacing
        return TapTarget(label: title, feel: .step, traits: selected ? [.isButton, .isSelected] : .isButton, action: { model.replacing = replacing }) { state in
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(selected ? 1 : (state.hover ? 0.85 : 0.6)))
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background {
                    if selected { Capsule().fill(.white.opacity(0.18)).matchedGeometryEffect(id: "choice", in: glide) }
                }
                .welcomeFocus(state.focused, radius: 12)
        }
    }
}

/// After Arc's spaces: its saved passwords and site sign-ins, which macOS asks about first.
private struct SignInsRow: View {
    let model: OnboardingModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(0.1)))
                .padding(.leading, 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("Passwords and sign-ins").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                Text(caption).font(.system(size: 12)).foregroundStyle(.white.opacity(0.56)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            switch model.signIns {
            case .notAsked: PillButton(title: "Import") { model.bringSignIns() }
            case .running: ProgressView().controlSize(.small).tint(.white)
            case .done: DoneMark()
            }
        }
        .padding(.vertical, 10)
        .padding(.trailing, 4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
    }

    private var caption: String {
        switch model.signIns {
        case .notAsked: "Stay signed in to your sites. macOS asks to share “Arc Safe Storage” with Cosmos: choose Allow."
        case .running: "Waiting for macOS…"
        case .done(let summary): summary
        }
    }
}

/// A browser's own icon, or a symbol in a tile when it has none here.
private struct AppIconView: View {
    let icon: NSImage?
    let symbol: String

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.1)))
            }
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }
}

/// A check in a disc that draws itself when it appears.
private struct DoneMark: View {
    @Local private var drawn = false
    @Environment(\.onboardingStill) private var still

    var body: some View {
        ZStack {
            Circle().fill(.white).frame(width: 26, height: 26)
            Path { p in
                p.move(to: CGPoint(x: 7.5, y: 13.5))
                p.addLine(to: CGPoint(x: 11.5, y: 17.5))
                p.addLine(to: CGPoint(x: 19, y: 9))
            }
            .trim(from: 0, to: drawn || still ? 1 : 0)
            .stroke(Color.black.opacity(0.85), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            .frame(width: 26, height: 26)
        }
        .scaleEffect(drawn || still ? 1 : 0.6)
        .onAppear { withAnimation(Motion.reduced ? nil : .spring(duration: 0.5, bounce: 0.3)) { drawn = true } }
        .accessibilityLabel("Done")
    }
}

/// A card's shape while the browsers are being looked for: a soft light passing over it.
private struct LoadingCard: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 8) {
                    Capsule().fill(.white.opacity(0.1)).frame(width: 120, height: 10)
                    Capsule().fill(.white.opacity(0.06)).frame(width: 260, height: 8)
                }
                Spacer()
            }
            .padding(14)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.07), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.4)
                        .offset(x: (phase * 1.4 - 0.4) * geo.size.width)
                }
            }
            .glassCard()
        }
        .accessibilityLabel("Looking for browsers")
    }
}

// MARK: - Sky

/// The space's sky, from the eight; the galaxy behind takes its colours, and the Dock icon can follow.
struct SkyStep: View {
    let model: OnboardingModel
    @Environment(\.onboardingCompact) private var compact
    @Environment(\.onboardingSide) private var side

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(title: "Choose a sky",
                      line: "Every space has a sky of its own. This one is for \(model.spaceTitle). Try them with ← and →.")
                .rise(0)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 16) {
                ForEach(OnboardingModel.skies, id: \.name) { theme in
                    SkyTile(theme: theme, selected: theme.name == model.sky.name, height: compact ? 56 : side ? 64 : 78) { model.choose(theme) }
                }
            }
            .padding(.top, compact ? 18 : 28)
            .rise(1)
            MatchIconRow(model: model)
                .padding(.top, compact ? 14 : 22)
                .rise(2)
        }
    }
}

private struct SkyTile: View {
    let theme: SpaceTheme
    let selected: Bool
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        TapTarget(label: theme.name, scale: 0.97, feel: .step, traits: selected ? [.isButton, .isSelected] : .isButton, action: action) { state in
            VStack(spacing: 8) {
                ThemeBackground(theme: theme, animated: false)
                    .frame(height: height)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.6))
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(.white.opacity(selected ? 0.95 : 0), lineWidth: 2))
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.black.opacity(0.85))
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(.white))
                                .padding(9)
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }
                    }
                    .scaleEffect(state.hover && !selected ? 1.03 : 1)
                    .shadow(color: .black.opacity(0.3), radius: state.hover ? 14 : 8, y: state.hover ? 6 : 3)
                    .welcomeFocus(state.focused, radius: 15)
                Text(theme.name)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.62))
            }
            .animation(Motion.spring, value: selected)
            .animation(Motion.quick, value: state.hover)
        }
    }
}

/// The real thing, smaller: this window's own sidebar (its spaces, its tabs) and the page it opens on, in its sky. On the
/// Sky step it changes as each sky is tried; on the Bring step it shows what came across, uncovered from the top down.
/// Drawn from the welcome's copy of the window's state (`OnboardingModel.preview`), takes no clicks and listens for no
/// swipes, so nothing behind the welcome changes.
struct WindowPreview: View {
    let model: OnboardingModel
    /// When to uncover it, on the welcome's clock (nil: shown whole).
    var uncoveredFrom: Double?
    /// The size it is laid out at before being drawn smaller: a small window, so its words can be read, or (on the last
    /// step) the real window's, so it can grow into it.
    var canvas = Self.size
    static let size = CGSize(width: 760, height: 480)
    static let aspect = size.width / size.height

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        GeometryReader { geo in
            let scale = min(1, geo.size.width / canvas.width)
            WindowPicture(model: model)
                .frame(width: canvas.width, height: canvas.height)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 1))
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: canvas.width * scale, height: canvas.height * scale, alignment: .topLeading)
                .modifier(Uncover(model: model, from: uncoveredFrom))
                .shadow(color: .black.opacity(0.5), radius: 34, y: 16)
        }
        .aspectRatio(canvas.width / canvas.height, contentMode: .fit)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(uncoveredFrom == nil ? "Preview of \(model.spaceTitle) in \(model.sky.name)" : "Preview of what came across")
    }
}

/// The window as the browser draws it, from the welcome's copy of its state: the sky, this window's own sidebar (its
/// spaces, its tabs), the gap its resize handle keeps, the page it opens on and, if switched on, the utilities rail.
struct WindowPicture: View {
    let model: OnboardingModel

    var body: some View {
        let preview = model.preview
        let theme = model.store.workspace.space(preview.focusedSpaceID)?.theme ?? model.sky
        let palette = Palette(theme: theme)
        ZStack {
            ThemeBackground(theme: theme, animated: false)
            HStack(spacing: 0) {
                SidebarView(store: model.store, window: preview)
                Color.clear.frame(width: 8)
                EmptyStateView(store: model.store, window: preview, offersImport: false)
                    .padding(.vertical, Metrics.Space.s)
                    .padding(.trailing, Metrics.Space.s)
                if model.window.railShown { UtilitiesRail(store: model.store, window: preview) }
            }
        }
        .environment(\.palette, palette)
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
        .environment(\.appIconStyle, model.store.settings.appIcon)
        .animation(Motion.glide, value: theme)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A soft edge sweeping down from the top, uncovering what is under it, timed on the welcome's clock (so a picture of
/// any moment shows that moment).
private struct Uncover: ViewModifier {
    let model: OnboardingModel
    let from: Double?
    @Local private var done = false

    func body(content: Content) -> some View {
        if let from, !Motion.reduced {
            TimelineView(.animation(minimumInterval: nil, paused: done || model.frozen != nil)) { context in
                let p = OnboardingFlow.appear(at: model.time(at: context.date), from: from, over: Self.duration)
                content.mask {
                    LinearGradient(stops: [.init(color: .white, location: p * 1.25 - 0.25), .init(color: .clear, location: p * 1.25)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .offset(y: (1 - p) * 14)
            }
            .task(id: from) {
                done = false
                try? await Task.sleep(for: .seconds(max(0, from + Self.duration - model.time())))
                if !Task.isCancelled { done = true }
            }
        } else {
            content
        }
    }

    static let duration = 1.2
}

/// Whether the Dock icon follows the sky: the four skies with an icon of their own say which.
private struct MatchIconRow: View {
    let model: OnboardingModel

    var body: some View {
        let shown = model.store.settings.appIcon
        TapTarget(label: "Match the app icon", feel: .step, traits: .isButton, action: { model.setMatchIcon(!model.matchIcon) }) { state in
            HStack(spacing: 14) {
                Image(nsImage: AppIcon.image(shown))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 46, height: 46)
                    .id(shown)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Match the app icon").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Text(model.matchIconLine)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.56))
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 12)
                GlowSwitch(isOn: model.matchIcon)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassCard()
            .welcomeFocus(state.focused, radius: 16)
            .animation(Motion.spring, value: shown)
        }
        .accessibilityValue(model.matchIcon ? "On" : "Off")
    }
}

// MARK: - Features

/// The six features worth deciding on the first day, each a card that switches when clicked.
struct FeaturesStep: View {
    let model: OnboardingModel
    @Environment(\.onboardingCompact) private var compact
    @Environment(\.onboardingSide) private var side

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(title: "Make it yours",
                      line: "Turn on what you’d like now. Every feature can be switched later in Settings\u{00A0}▸\u{00A0}Features.")
                .rise(0)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: side ? 2 : 3), spacing: 12) {
                ForEach(Array(OnboardingModel.offered.enumerated()), id: \.element) { i, feature in
                    FeatureCard(feature: feature, isOn: model.isOn(feature), compact: compact) { model.toggle(feature) }
                        .rise(1 + i / (side ? 2 : 3))
                }
            }
            .padding(.top, compact ? 18 : 28)
        }
    }
}

private struct FeatureCard: View {
    let feature: Feature
    let isOn: Bool
    let compact: Bool
    let action: () -> Void
    @Environment(\.onboardingTint) private var tint

    var body: some View {
        TapTarget(label: Self.title(feature), scale: 0.98, feel: .step, action: action) { state in
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: feature.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isOn ? .white : .white.opacity(0.6))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(isOn ? tint.opacity(0.55) : .white.opacity(0.08)))
                    Spacer()
                    GlowSwitch(isOn: isOn)
                }
                .padding(.bottom, compact ? 10 : 18)
                Text(Self.title(feature)).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text(Self.line(feature))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(compact ? 2 : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: compact ? 112 : 146, alignment: .topLeading)
            .glassCard(lit: isOn)
            .scaleEffect(state.hover ? 1.015 : 1)
            .welcomeFocus(state.focused, radius: 16)
            .animation(Motion.quick, value: state.hover)
            .animation(Motion.standard, value: isOn)
        }
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(Self.line(feature))
    }

    static func title(_ feature: Feature) -> String {
        switch feature {
        case .adBlocking: "Ad and tracker blocking"
        case .utilities: "Utilities rail"
        case .menuBarBrowser: "Menu-bar browser"
        default: feature.title
        }
    }

    /// What it is, said for someone meeting it for the first time.
    static func line(_ feature: Feature) -> String {
        switch feature {
        case .adBlocking: "Ads and trackers stop before they load."
        case .peek: "Links from pinned tabs open in a quick look over the page."
        case .boosts: "Restyle any site with your own colours, fonts and tweaks."
        case .radialMenu: "Right-click for a ring of the actions you use most."
        case .utilities: "Translate, zoom, downloads and passwords in a column on the right."
        case .menuBarBrowser: "A small browser one click away, under an icon in the menu bar."
        default: feature.detail
        }
    }
}

// MARK: - Moves

/// Three moves, tried in a practice window that answers them.
struct MovesStep: View {
    let model: OnboardingModel
    @Environment(\.onboardingCompact) private var compact

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(title: "Three moves to know",
                      line: "Try them here. This practice window answers; nothing else changes.")
                .rise(0)
            MiniBrowser(model: model)
                .frame(height: compact ? 210 : 290)
                .padding(.top, compact ? 16 : 26)
                .rise(1)
            HStack(spacing: 12) {
                MoveCard(keys: ["⌘", "T"], title: "Open the Command Bar", line: "Type to find a tab, then ↩.", done: model.done.contains(.commandBar)) {
                    model.perform(.commandBar)
                }
                MoveCard(keys: ["⌥", "⌘", "→"], symbol: "hand.draw", title: "Swipe between spaces", line: "Two fingers across the window.",
                         done: model.done.contains(.swipe)) {
                    model.perform(.swipe)
                }
                MoveCard(keys: ["⌘", "S"], title: "Hide the sidebar", line: "Give the page the whole window.", done: model.done.contains(.sidebar)) {
                    model.perform(.sidebar)
                }
            }
            .padding(.top, 14)
            .rise(2)
        }
    }
}

private struct MoveCard: View {
    let keys: [String]
    var symbol: String?
    let title: String
    let line: String
    let done: Bool
    let action: () -> Void

    var body: some View {
        TapTarget(label: title, scale: 0.98, action: action) { state in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                            .frame(height: 24).padding(.trailing, 4)
                    }
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                        Text(key)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(minWidth: 24, minHeight: 24)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.12)))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.6))
                    }
                    Spacer()
                    ZStack {
                        Circle().strokeBorder(.white.opacity(done ? 0 : 0.22), lineWidth: 1.2)
                        if done {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white)
                                .transition(.scale(scale: 0.4).combined(with: .opacity))
                        }
                    }
                    .frame(width: 18, height: 18)
                }
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white).padding(.top, 12)
                Text(line).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).padding(.top, 2)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(radius: 14, lit: done)
            .scaleEffect(state.hover ? 1.015 : 1)
            .welcomeFocus(state.focused, radius: 14)
            .animation(Motion.spring, value: done)
            .animation(Motion.quick, value: state.hover)
        }
        .accessibilityValue(done ? "Tried" : "Not tried yet")
        .accessibilityHint(line)
    }
}

// MARK: - Ready

/// The last thing, laid out like the opening it answers: the icon picked, the default browser, and the way in.
struct ReadyStep: View {
    let model: OnboardingModel
    @Environment(\.onboardingCompact) private var compact
    @Environment(\.onboardingSide) private var side

    var body: some View {
        if side { besideTheWindow } else { centred }
    }

    private var line: String {
        (model.imported ? "Your spaces are ready." : "Your first space is ready.")
            + " One more thing, if you like: let links from Mail, Messages and every other app open here."
    }

    /// Beside the window as it will open: the words, the default-browser card and the way in.
    private var besideTheWindow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: AppIcon.image(model.store.settings.appIcon))
                .resizable()
                .interpolation(.high)
                .frame(width: compact ? 56 : 72, height: compact ? 56 : 72)
                .shadow(color: Color(model.settledPalette[2]).opacity(0.45), radius: 26)
                .padding(.bottom, compact ? 12 : 18)
                .rise(0)
            StepTitle(title: "You’re all set", line: line)
                .rise(0)
            defaultCard
                .padding(.top, compact ? 18 : 26)
                .rise(1)
            PrimaryButton(title: "Enter Cosmos", emphasised: true) { model.primary() }
                .padding(.top, compact ? 20 : 30)
                .rise(1)
        }
    }

    private var centred: some View {
        VStack(spacing: 0) {
            Image(nsImage: AppIcon.image(model.store.settings.appIcon))
                .resizable()
                .interpolation(.high)
                .frame(width: compact ? 76 : 112, height: compact ? 76 : 112)
                .shadow(color: Color(model.settledPalette[2]).opacity(0.45), radius: 34)
                .rise(0)
            Text("You’re all set")
                .font(.system(size: compact ? 38 : 50, weight: .semibold, design: .rounded))
                .kerning(-1.1)
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 14)
                .rise(1)
            Text(line)
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.64))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 520)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .rise(1)
            defaultCard
                .frame(width: 460)
                .padding(.top, compact ? 18 : 28)
                .rise(2)
            PrimaryButton(title: "Enter Cosmos", emphasised: true) { model.primary() }
                .padding(.top, compact ? 20 : 30)
                .rise(3)
        }
        .frame(maxWidth: .infinity)
    }

    /// Cosmos as the default browser: a button that asks macOS, then a note that it is.
    private var defaultCard: some View {
        HStack(spacing: 12) {
            Image(systemName: model.isDefault ? "checkmark.seal.fill" : "link")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(0.1)))
                .symbolSwap()
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isDefault ? "Cosmos is your default browser" : "Make Cosmos your default browser")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(model.isDefault ? "Links from other apps open here." : "macOS asks you to confirm.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.56))
            }
            Spacer(minLength: 12)
            if model.isDefault { DoneMark() } else { PillButton(title: "Make Default") { model.makeDefault() } }
        }
        .padding(12)
        .glassCard(lit: model.isDefault)
        .animation(Motion.spring, value: model.isDefault)
    }
}
