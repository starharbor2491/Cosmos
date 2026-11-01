import SwiftUI
import AppKit
import CosmosCore

/// The welcome: deep space with the galaxy in it, and over it one step at a time (see `OnboardingModel`). It covers the
/// whole window; Enter Cosmos dollies into the galaxy's core and its light clears to the browser.
struct OnboardingView: View {
    @Local private var model: OnboardingModel
    /// The step's own height, measured, so a short window can draw it smaller (and lay it out smaller) to fit.
    @Local private var stepHeight: CGFloat = 0

    init(store: BrowserStore, window: WindowState, start: OnboardingStep = .welcome) {
        _model = Local(wrappedValue: OnboardingModel(store: store, window: window, start: start))
    }

    /// A welcome already set up (pictures of it at chosen moments).
    init(model: OnboardingModel) { _model = Local(wrappedValue: model) }

    static let galaxy = Galaxy()
    @Environment(\.onboardingSkyPicture) private var skyPicture

    var body: some View {
        // The way in is drawn from the welcome's clock, frame by frame, like the galaxy it falls into.
        TimelineView(.animation(minimumInterval: nil, paused: model.enteredAt == nil || model.frozen != nil)) { context in
            let t = model.time(at: context.date)
            scene(words: model.words(at: t), at: t)
                .opacity(model.cover(at: t))
        }
        .background(OnboardingKeys(model: model))
        .environment(\.colorScheme, .dark)
        .environment(\.onboardingStill, model.frozen != nil)
        .environment(\.onboardingTravel, model.travel)
        .environment(\.onboardingTint, Color(model.tint))
        .animation(Motion.slide, value: model.step)
        // What came across makes room for itself rather than jumping into place.
        .animation(Motion.slide, value: model.landedAt != nil)
        .task { await model.prepare() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to Cosmos")
    }

    private func scene(words: Double, at t: Double) -> some View {
        GeometryReader { geo in
            ZStack {
                sky(size: geo.size)
                Group {
                    if model.step == .welcome {
                        WelcomeHero(model: model)
                            .transition(.asymmetric(insertion: .opacity, removal: .modifier(active: Leave(active: true), identity: Leave(active: false))))
                    } else {
                        stepPage(size: geo.size)
                            .transition(.opacity)
                    }
                }
                // The words go first on the way in: toward the camera and out of focus.
                .scaleEffect(Motion.reduced ? 1 : 1 + 0.12 * (1 - words))
                .opacity(words)
                .blur(radius: Motion.reduced ? 0 : (1 - words) * 6)
                // The window can still be dragged by its top edge, as by a title bar.
                WindowDragStrip()
                    .frame(height: 22)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlayPreferenceValue(GrowFromKey.self) { from in
                if model.grows, let entered = model.enteredAt, let from {
                    GrowingWindow(model: model, from: from, progress: OnboardingFlow.entryGrow(at: t - entered))
                }
            }
            .contentShape(Rectangle())
            .onChange(of: geo.size, initial: true) { _, size in model.windowSize = size }
            .onContinuousHover { phase in
                guard case .active(let p) = phase, geo.size.width > 0, geo.size.height > 0 else { return }
                model.pointerMoved(to: CGPoint(x: p.x / geo.size.width * 2 - 1, y: p.y / geo.size.height * 2 - 1))
            }
        }
    }

    @ViewBuilder private func sky(size: CGSize) -> some View {
        if let skyPicture {
            Image(nsImage: skyPicture).resizable()
        } else if let sprites = model.sprites {
            GalaxyView(galaxy: Self.galaxy, sprites: sprites, time: model.frozen, start: model.began,
                       frame: { model.frame(at: $0, in: size) }, pointer: { model.pointer }, lively: model.lively)
        } else {
            // The moment before the galaxy's pictures are ready: the same dark it gathers in.
            Color(red: 0.012, green: 0.014, blue: 0.034)
        }
    }

    /// A step after the opening: the progress marks at the top, the step in the middle (or to one side of a wide window,
    /// with the galaxy or the Sky step's preview on the other), Back and the main button below. A short window gets the
    /// steps' compact layout, and only what still does not fit is drawn smaller.
    private func stepPage(size: CGSize) -> some View {
        let wide = size.width >= OnboardingModel.wideWindow
        // The last step sits to one side only beside the window it will open on.
        let placement = wide && (model.step != .ready || model.showsPreview) ? model.step.placement : .centre
        let centred = min(720, size.width - 80)
        let outer = placement == .centre ? centred : size.width - 2 * max(72, size.width * 0.07)
        // Beside a preview of the window the words take less room, so the preview can be big enough to read (the Bring
        // step's too, before there is one, so its cards do not re-wrap as one arrives).
        let narrow = model.showsPreview || model.step == .bring
        let column = placement == .centre ? centred : narrow ? min(480, size.width * 0.38) : min(600, size.width * 0.44)
        let compact = size.height < 680
        let room = max(240, size.height - (compact ? 150 : 180))
        let fit = stepHeight > 0 ? min(1, room / stepHeight) : 1
        // The preview beside the words: as wide as the room left, unless the window is too short for that. The last step's
        // is this window, drawn smaller.
        let aspect = model.step == .ready ? size.width / max(1, size.height) : WindowPreview.aspect
        let previewWidth = max(0, min(outer - column * fit - Self.asideGap, room * aspect))
        return VStack(spacing: 0) {
            ZStack {
                ProgressMarks(model: model)
                HStack {
                    Spacer()
                    if model.isVisit {
                        QuietButton(title: "Close") { model.close() }
                    } else if model.step != .ready {
                        QuietButton(title: "Skip Setup") { model.skip() }
                    }
                }
            }
            .frame(width: outer)
            .padding(.top, 24)
            Spacer(minLength: 12)
            HStack(spacing: 0) {
                if placement == .trailing { aside(previewWidth, window: size).frame(maxWidth: .infinity) }
                ZStack {
                    step
                        .id(model.step)
                        .transition(.asymmetric(insertion: .identity, removal: .modifier(active: Leave(active: true), identity: Leave(active: false))))
                }
                .frame(width: column)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { g in Color.clear.preference(key: StepHeightKey.self, value: g.size.height) })
                .onPreferenceChange(StepHeightKey.self) { height in MainActor.assumeIsolated { stepHeight = height } }
                .scaleEffect(fit)
                // The room it takes is what it is drawn at, so a step drawn smaller still sits against its edge.
                .frame(width: column * fit, height: stepHeight > 0 ? stepHeight * fit : nil)
                if placement == .leading { aside(previewWidth, window: size).frame(maxWidth: .infinity) }
            }
            .frame(width: outer)
            .environment(\.onboardingCompact, compact)
            .environment(\.onboardingSide, placement != .centre)
            Spacer(minLength: 12)
            Footer(model: model)
                .frame(width: outer)
                .padding(.bottom, 28)
        }
        .frame(width: size.width, height: size.height)
    }

    /// Beside a step that sits to one side: the window the welcome is setting up (the Sky step's, in the sky being tried;
    /// the Bring step's, once spaces came across, uncovered as they arrive); otherwise the galaxy, left clear.
    @ViewBuilder private func aside(_ width: CGFloat, window: CGSize) -> some View {
        if model.step == .sky {
            WindowPreview(model: model)
                .frame(width: width, height: width / WindowPreview.aspect)
                .padding(.leading, Self.asideGap)
                .rise(3)
        } else if model.step == .bring, let landed = model.landedAt {
            WindowPreview(model: model, uncoveredFrom: landed)
                .frame(width: width, height: width / WindowPreview.aspect)
                .padding(.leading, Self.asideGap)
        } else if model.step == .ready {
            WindowPreview(model: model, canvas: window)
                .frame(width: width, height: width * window.height / max(1, window.width))
                // On the way in a copy of it grows from here (`GrowingWindow`), so this one steps aside.
                .anchorPreference(key: GrowFromKey.self, value: .bounds) { $0 }
                .opacity(model.grows ? 0 : 1)
                .padding(.leading, Self.asideGap)
                .rise(2)
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private static let asideGap: CGFloat = 48

    @ViewBuilder private var step: some View {
        switch model.step {
        case .welcome: EmptyView()
        case .bring: BringStep(model: model)
        case .sky: SkyStep(model: model)
        case .features: FeaturesStep(model: model)
        case .moves: MovesStep(model: model)
        case .ready: ReadyStep(model: model)
        }
    }
}

/// Where the last step's window sits, for the way in to grow it from.
private struct GrowFromKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// The way in from the last step: the window beside the words, drawn at the real window's size, grows from where it sat
/// until it is the window, its corners squaring and its shadow going as it arrives; the welcome then clears to the
/// browser underneath, which looks the same.
private struct GrowingWindow: View {
    let model: OnboardingModel
    let from: Anchor<CGRect>
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            let start = geo[from], g = progress
            let width = start.width + (geo.size.width - start.width) * g
            let x = start.minX * (1 - g), y = start.minY * (1 - g)
            let scale = max(0.01, width / max(1, geo.size.width))
            // Corners and edge as the preview drew them (at the picture's own size), going as it arrives.
            let shape = RoundedRectangle(cornerRadius: 16 * (1 - g), style: .continuous)
            WindowPicture(model: model)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.white.opacity(0.22 * (1 - g)), lineWidth: 1))
                .scaleEffect(scale, anchor: .topLeading)
                .offset(x: x, y: y)
                .shadow(color: .black.opacity(0.5 * (1 - g)), radius: 34, y: 16)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct StepHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - The opening

/// The galaxy gathers; starlight condenses into the mark, which sweeps in bar by bar; then the name letter by letter,
/// the line, the button.
private struct WelcomeHero: View {
    let model: OnboardingModel
    @Local private var settled = false

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: nil, paused: settled || model.frozen != nil)) { context in
                let t = Motion.reduced && model.frozen == nil ? OnboardingFlow.openingEnds : model.time(at: context.date)
                let palette = model.palette(at: t)
                VStack(spacing: 0) {
                    BrandMark(palette: palette) { OnboardingFlow.bar($0, at: t) }
                        .frame(width: 96, height: 96)
                        .overlay { MarkSparks(time: t, palette: palette, side: 96).frame(width: 720, height: 480).allowsHitTesting(false) }
                        .padding(.bottom, 22)
                    Wordmark(time: t)
                    Text("A browser with room for everything you do.")
                        .font(.system(size: 19))
                        .foregroundStyle(.white.opacity(0.7))
                        .appearing(OnboardingFlow.line(at: t))
                        .padding(.top, 12)
                    PrimaryButton(title: "Get Started") { model.primary() }
                        .appearing(OnboardingFlow.button(at: t))
                        .allowsHitTesting(OnboardingFlow.button(at: t) > 0.2)
                        .padding(.top, 38)
                }
                .position(x: geo.size.width / 2, y: geo.size.height * 0.36)
            }
        }
        .task(id: model.began) {
            // Once everything is in place the opening stops redrawing itself (the galaxy goes on turning on its own).
            settled = false
            try? await Task.sleep(for: .seconds(max(0, OnboardingFlow.openingEnds + 0.3 - model.time())))
            if !Task.isCancelled { settled = true }
        }
    }
}

/// "Cosmos" built the way the mark is: SF Rounded, cut into horizontal pills (a bar about twice its gap), laid on the
/// letters' baseline and x-height so no sliver is left at an edge, the bars' ends rounded as the mark's are. Each
/// letter's bars sweep in from the left, top bar first, as the mark's did.
private struct Wordmark: View {
    let time: Double

    static let size: CGFloat = 84
    static let kerning: CGFloat = -1.4
    static let text = "Cosmos"
    static let font: NSFont = {
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }()
    /// Where each letter starts, kerned as the whole word is.
    static let offsets: [CGFloat] = (0..<text.count).map { i in
        NSAttributedString(string: String(text.prefix(i)), attributes: [.font: font, .kern: kerning]).size().width
    }
    static let width = NSAttributedString(string: text, attributes: [.font: font, .kern: kerning]).size().width
    static let height = ceil(font.ascender - font.descender)
    /// The bars: from the baseline (less the round letters' overshoot) up, six of them spanning the x-height exactly.
    static let overshoot = size * 0.014
    static let pitch = (font.xHeight + 2 * overshoot) / 5.66

    var body: some View {
        let pad: CGFloat = 6
        // Once every letter is in, the gaps close and the name reads whole; the mark above keeps its bars.
        let bar = Self.pitch * (0.66 + 0.36 * OnboardingFlow.fuse(at: time))
        LinearGradient(colors: [.white, .white.opacity(0.84)], startPoint: .top, endPoint: .bottom)
            .frame(width: Self.width + 2 * pad, height: Self.height + 2 * pad)
            .mask {
                Canvas { ctx, _ in
                    // Rounded bar ends: the cut letters are blurred a touch and cut back at half their alpha (which rounds
                    // every corner), then softened by a hair so the edges stay smooth.
                    ctx.addFilter(.blur(radius: 0.45))
                    ctx.addFilter(.alphaThreshold(min: 0.5, color: .white))
                    ctx.addFilter(.blur(radius: 1.4))
                    ctx.drawLayer { layer in
                        for (i, letter) in Self.text.enumerated() {
                            let p = OnboardingFlow.letter(i, at: time)
                            guard p > 0.001 else { continue }
                            let x = pad + Self.offsets[i]
                            let resolved = layer.resolve(Text(String(letter)).font(Font(Self.font)))
                            let size = resolved.measure(in: CGSize(width: 400, height: 400))
                            let baseline = pad + resolved.firstBaseline(in: size)
                            let rise = (1 - p) * 10
                            var bars = Path()
                            var k = 0
                            while true {
                                let bottom = baseline + Self.overshoot - Double(k) * Self.pitch + rise
                                guard bottom > 0 else { break }
                                // The top bar sweeps in first.
                                let lead = 0.35 * (1 - min(1, Double(k) / 9))
                                let q = min(1, max(0, p * 1.35 - lead))
                                let eased = 1 - pow(1 - q, 3)
                                if eased > 0 {
                                    bars.addRect(CGRect(x: x - 2, y: bottom - bar, width: (size.width + 4) * eased, height: bar))
                                }
                                k += 1
                            }
                            var c = layer
                            c.clip(to: bars)
                            c.draw(resolved, in: CGRect(x: x, y: pad + rise, width: size.width, height: size.height))
                        }
                    }
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 24, y: 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Cosmos")
            .accessibilityAddTraits(.isHeader)
    }
}

/// The Cosmos mark: a crescent of rounded bars (the geometry of `cosmos icon/logos/single-color/cosmos-menubar-glyph.svg`),
/// lit in the galaxy's colours. `progress` says how far each bar has swept in from its left end.
struct BrandMark: View {
    var palette: [RGBA]
    var progress: (Int) -> Double = { _ in 1 }

    typealias Bar = (index: Int, top: Double, height: Double, from: Double, to: Double)

    /// The bars, on the glyph's 1024 canvas: which bar, its band, and where it starts and ends across.
    static let bars: [Bar] = {
        var out: [Bar] = []
        for index in 0..<11 {
            let top = 171.0 + 64 * Double(index), height = 42.0
            let dy = top + height / 2 - 512
            let outer = sqrt(max(0, 350 * 350 - dy * dy)), inner = sqrt(max(0, 278.5 * 278.5 - dy * dy))
            let (left, right) = (526 - outer, 526 + outer)
            if inner == 0 { out.append((index, top, height, left, right)); continue }
            // The inner circle takes its share out of the middle; what is left either side of it is the crescent.
            let (cutLeft, cutRight) = (606 - inner, 606 + inner)
            if cutLeft > left { out.append((index, top, height, left, min(cutLeft, right))) }
            if cutRight < right { out.append((index, top, height, cutRight, right)) }
        }
        return out
    }()

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 1024
            let top = Color(palette[1].mixed(with: RGBA(1, 1, 1), 0.55)), bottom = Color(palette[3].mixed(with: RGBA(1, 1, 1), 0.3))
            let shading = GraphicsContext.Shading.linearGradient(Gradient(colors: [top, bottom]), startPoint: CGPoint(x: 0, y: 160 * s),
                                                                 endPoint: CGPoint(x: 0, y: 860 * s))
            func path(_ bar: Bar, _ p: Double) -> Path {
                let h = bar.height * s
                let w = max(h, (bar.to - bar.from) * s * p)
                return Path(roundedRect: CGRect(x: bar.from * s, y: bar.top * s, width: w, height: h), cornerRadius: h / 2)
            }
            var glow = ctx
            glow.addFilter(.blur(radius: 140 * s))
            for bar in Self.bars {
                let p = progress(bar.index)
                guard p > 0.001 else { continue }
                var g = glow
                g.opacity = 0.45 * p
                g.fill(path(bar, p), with: shading)
            }
            for bar in Self.bars {
                let p = progress(bar.index)
                guard p > 0.001 else { continue }
                var c = ctx
                c.opacity = min(1, p * 1.4)
                c.fill(path(bar, p), with: shading)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Starlight condensing into the mark: sparks drift in from around it (most from below, where the galaxy is) and land
/// along each bar just as the bar sweeps through, so the mark is drawn by the light arriving.
private struct MarkSparks: View {
    let time: Double
    let palette: [RGBA]
    /// The mark's side, in points; the sparks' canvas is larger and centred on it.
    let side: CGFloat

    struct Spark { let bar: BrandMark.Bar; let along, startX, startY, lead, size: Double }

    static let sparks: [Spark] = {
        var rng = SplitMix(0x5BA2_4C11)
        let bars = BrandMark.bars
        return (0..<170).map { _ in
            let bar = bars[Int(rng.unit() * Double(bars.count)) % bars.count]
            let angle = rng.unit() * 2 * .pi
            let reach = 140 + rng.unit() * 240
            return Spark(bar: bar, along: rng.unit(), startX: cos(angle) * reach * 1.3, startY: sin(angle) * reach * 0.8 + 90,
                         lead: 0.6 + rng.unit() * 0.5, size: 2 + pow(rng.unit(), 3) * 4)
        }
    }()

    var body: some View {
        Canvas { ctx, size in
            guard time > OnboardingFlow.markStarts - 1.3, time < OnboardingFlow.markStarts + 1.6 else { return }
            ctx.blendMode = .plusLighter
            let s = side / 1024
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let light = Color(palette[1].mixed(with: RGBA(1, 1, 1), 0.5))
            for spark in Self.sparks {
                // It lands as its bar's sweep passes the spot.
                let lands = OnboardingFlow.markStarts + Double(spark.bar.index) * OnboardingFlow.barGap + spark.along * OnboardingFlow.barSweep * 0.45
                let leaves = lands - spark.lead
                let p = min(1, max(0, (time - leaves) / spark.lead))
                guard p > 0, time < lands + 0.25 else { continue }
                let e = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
                let target = CGPoint(x: (spark.bar.from + (spark.bar.to - spark.bar.from) * spark.along) * s - side / 2,
                                     y: (spark.bar.top + spark.bar.height / 2) * s - side / 2)
                // A gentle curve on the way, not a straight line.
                let bend = sin(.pi * e) * 26
                let x = spark.startX + (target.x - spark.startX) * e + bend
                let y = spark.startY + (target.y - spark.startY) * e
                let after = max(0, time - lands)
                let alpha = Galaxy.smoothstep(0, 0.25, p) * (1 - Galaxy.smoothstep(0, 0.25, after))
                let d = spark.size * (1 + (1 - e) * 0.6)
                var c = ctx
                c.opacity = alpha * 0.9
                c.fill(Path(ellipseIn: CGRect(x: centre.x + x - d / 2, y: centre.y + y - d / 2, width: d, height: d)),
                       with: .radialGradient(Gradient(colors: [.white, light.opacity(0.6), .clear]), center: CGPoint(x: centre.x + x, y: centre.y + y),
                                             startRadius: 0, endRadius: d / 2))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Chrome

/// Where the welcome is: a mark for each step, the current one long and bright. A step already passed can be clicked
/// to go back to it.
private struct ProgressMarks: View {
    let model: OnboardingModel

    var body: some View {
        let steps = model.counted
        let current = steps.firstIndex(of: model.step) ?? 0
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.element) { i, step in
                Capsule()
                    .fill(.white.opacity(i == current ? 0.95 : (i < current ? 0.5 : 0.16)))
                    .frame(width: i == current ? 36 : 18, height: 4)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                    .onTapGesture { model.revisit(step) }
            }
        }
        .opacity(steps.count > 1 ? 1 : 0)
        .animation(Motion.spring, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(steps.count)")
    }
}

/// Back on the left, the step's main button on the right (the last step has its own, in the middle).
private struct Footer: View {
    let model: OnboardingModel

    var body: some View {
        HStack {
            if model.canGoBack {
                QuietButton(title: "Back", symbol: "chevron.left") { model.back() }
                    .transition(.opacity)
            }
            Spacer()
            if model.step != .ready {
                PrimaryButton(title: title, enabled: !model.isBusy) { model.primary() }
            }
        }
        .frame(height: 44)
        .animation(Motion.standard, value: model.canGoBack)
    }

    private var title: String {
        switch model.step {
        case .bring where model.isBusy: "Importing…"
        case .bring where model.steps == [.bring]: "Done"
        case .bring: model.imported ? "Continue" : "Start Fresh"
        default: "Continue"
        }
    }
}

/// The main button: white, with the Return key it answers to.
struct PrimaryButton: View {
    let title: String
    var emphasised = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        TapTarget(label: title, enabled: enabled, scale: 0.97, action: action) { state in
            HStack(spacing: 10) {
                Text(title).font(.system(size: 15, weight: .semibold)).contentTransition(.opacity)
                Text("↩").font(.system(size: 13, weight: .semibold)).opacity(0.38)
            }
            .foregroundStyle(Color.black.opacity(0.86))
            .padding(.horizontal, 24)
            .frame(height: 44)
            .background(Capsule().fill(.white.opacity(state.hover ? 1 : 0.94)))
            .shadow(color: .white.opacity(emphasised ? 0.4 : (state.hover ? 0.24 : 0.14)), radius: emphasised ? 28 : 18)
            .scaleEffect(state.hover ? 1.02 : 1)
            .animation(Motion.quick, value: state.hover)
            .welcomeFocus(state.focused, radius: 22)
        }
    }
}

/// A button that is only words: Back, Skip Setup.
struct QuietButton: View {
    let title: String
    var symbol: String?
    let action: () -> Void

    var body: some View {
        TapTarget(label: title, action: action) { state in
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(.system(size: 13.5, weight: .medium))
            }
            .foregroundStyle(.white.opacity(state.hover ? 0.95 : 0.6))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(.white.opacity(state.hover ? 0.08 : 0)))
            .animation(Motion.quick, value: state.hover)
            .welcomeFocus(state.focused, radius: 16)
        }
    }
}

/// A smaller button on a card: Import, Make Default.
struct PillButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        TapTarget(label: title, enabled: enabled, action: action) { state in
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 30)
                .background(Capsule().fill(.white.opacity(state.hover ? 0.22 : 0.14)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.6))
                .animation(Motion.quick, value: state.hover)
                .welcomeFocus(state.focused, radius: 15)
        }
    }
}

/// An on/off switch in the welcome's white-on-dark, lit in the sky's colour when on.
struct GlowSwitch: View {
    let isOn: Bool
    @Environment(\.onboardingTint) private var tint

    var body: some View {
        Capsule()
            .fill(isOn ? tint : .white.opacity(0.16))
            .frame(width: 36, height: 21)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 17, height: 17).padding(2).shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            }
            .animation(Motion.spring, value: isOn)
            .accessibilityHidden(true)
    }
}

/// The big words at the top of a step.
struct StepTitle: View {
    let title: String
    let line: String
    @Environment(\.onboardingCompact) private var compact

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            Text(title)
                .font(.system(size: compact ? 29 : 36, weight: .semibold, design: .rounded))
                .kerning(-0.5)
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Text(line)
                .font(.system(size: compact ? 14 : 15.5))
                .foregroundStyle(.white.opacity(0.62))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shadow(color: .black.opacity(0.35), radius: 16, y: 4)
    }
}

extension View {
    /// A pane of frosted glass over the galaxy, faintly tinted with the sky and lit along its top edge.
    func glassCard(radius: CGFloat = 16, lit: Bool = false) -> some View { modifier(GlassCard(radius: radius, lit: lit)) }

    /// Comes in by `progress` (0...1): up into place, into focus.
    func appearing(_ progress: Double) -> some View {
        opacity(progress).offset(y: (1 - progress) * 14).blur(radius: (1 - progress) * 7)
    }

    /// Rises into place a moment after the step appears, `order` steps behind the first part of it, from the way the
    /// camera is travelling.
    func rise(_ order: Int) -> some View { modifier(Rise(order: order)) }

    /// The keyboard's focus ring, in the welcome's white, while the keyboard is what is being used.
    func welcomeFocus(_ focused: Bool, radius: CGFloat) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
            .strokeBorder(.white.opacity(focused && InputMode.shared.keyboard ? 0.9 : 0), lineWidth: 2)
            .padding(-3))
    }
}

private struct GlassCard: ViewModifier {
    let radius: CGFloat
    let lit: Bool
    @Environment(\.onboardingTint) private var tint

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(LinearGradient(colors: [tint.opacity(lit ? 0.16 : 0.07), .white.opacity(lit ? 0.07 : 0.035)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing)))
            .background(shape.fill(.ultraThinMaterial).opacity(0.65))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(lit ? 0.38 : 0.2), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                                        lineWidth: lit ? 1 : 0.7))
            .clipShape(shape)
    }
}

/// See `rise`.
private struct Rise: ViewModifier {
    let order: Int
    @Local private var shown = false
    @Environment(\.onboardingStill) private var still
    @Environment(\.onboardingTravel) private var travel

    func body(content: Content) -> some View {
        let visible = shown || still
        let away = !visible && !Motion.reduced
        // From a little further off, along the way the camera is going.
        content
            .opacity(visible ? 1 : 0)
            .scaleEffect(away ? 0.965 : 1)
            .offset(away ? CGSize(width: -travel.dx * 22, height: -travel.dy * 22) : .zero)
            .onAppear {
                withAnimation(Motion.reduced ? .easeOut(duration: 0.2) : .spring(duration: 0.75, bounce: 0.06).delay(0.08 + Double(order) * 0.07)) {
                    shown = true
                }
            }
    }
}

/// A step going: the camera passes it, so it comes a little closer as it drifts the way the camera is travelling, and
/// fades.
private struct Leave: ViewModifier {
    let active: Bool
    @Environment(\.onboardingTravel) private var travel

    func body(content: Content) -> some View {
        let going = active && !Motion.reduced
        content
            .opacity(active ? 0 : 1)
            .scaleEffect(going ? 1.04 : 1)
            .offset(going ? CGSize(width: travel.dx * 30, height: travel.dy * 30) : .zero)
    }
}

private struct OnboardingStillKey: EnvironmentKey { static let defaultValue = false }
private struct OnboardingCompactKey: EnvironmentKey { static let defaultValue = false }
private struct OnboardingSideKey: EnvironmentKey { static let defaultValue = false }
private struct OnboardingTravelKey: EnvironmentKey { static let defaultValue = CGVector(dx: 0, dy: -1) }
private struct OnboardingTintKey: EnvironmentKey { static let defaultValue = Color.white }
private struct OnboardingSkyPictureKey: EnvironmentKey { static let defaultValue: NSImage? = nil }

extension EnvironmentValues {
    /// Pictures of the welcome draw the galaxy beforehand and pass it in: a picture of a window leaves out what the GPU
    /// draws.
    var onboardingSkyPicture: NSImage? {
        get { self[OnboardingSkyPictureKey.self] }
        set { self[OnboardingSkyPictureKey.self] = newValue }
    }

    /// The welcome is being drawn at one moment (a picture): everything shows as it ends up, nothing waits to appear.
    var onboardingStill: Bool {
        get { self[OnboardingStillKey.self] }
        set { self[OnboardingStillKey.self] = newValue }
    }

    /// The window is short: the steps use their compact layout (smaller type and pictures) rather than being shrunk.
    var onboardingCompact: Bool {
        get { self[OnboardingCompactKey.self] }
        set { self[OnboardingCompactKey.self] = newValue }
    }

    /// The step sits to one side of a wide window, in a narrower column.
    var onboardingSide: Bool {
        get { self[OnboardingSideKey.self] }
        set { self[OnboardingSideKey.self] = newValue }
    }

    /// Which way the welcome's camera last travelled (see `OnboardingModel.travel`).
    var onboardingTravel: CGVector {
        get { self[OnboardingTravelKey.self] }
        set { self[OnboardingTravelKey.self] = newValue }
    }

    /// The sky's colour, deep enough to carry white: switches that are on, the glass's tint.
    var onboardingTint: Color {
        get { self[OnboardingTintKey.self] }
        set { self[OnboardingTintKey.self] = newValue }
    }
}

// MARK: - Window

/// The top edge of the window, which drags it (a double click zooms it) while the welcome covers the title bar.
private struct WindowDragStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }
}

// MARK: - Keys

/// Hands the welcome every key pressed in its window while it is up (see `OnboardingModel.handleKey`).
private struct OnboardingKeys: NSViewRepresentable {
    let model: OnboardingModel

    func makeNSView(context: Context) -> KeyView { let v = KeyView(); v.model = model; return v }
    func updateNSView(_ v: KeyView, context: Context) { v.model = model }

    final class KeyView: NSView {
        var model: OnboardingModel?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let model = self.model, event.window === self.window else { return event }
                let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
                let taken = MainActor.assumeIsolated {
                    model.handleKey(characters, keyCode: event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat)
                }
                return taken ? nil : event
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
