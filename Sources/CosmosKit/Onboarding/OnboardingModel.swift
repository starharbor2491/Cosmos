import AppKit
import SwiftUI
import CosmosCore
import CosmosImport

/// What the welcome is doing: the step it is on, where its galaxy is and in what colours, and what the person has chosen
/// so far. The view draws it; everything it does to the browser goes through here.
@MainActor
@Observable
final class OnboardingModel {
    let store: BrowserStore
    let window: WindowState
    let steps: [OnboardingStep]
    /// Setup was already done when this opened (Help ▸ Welcome to Cosmos, or File ▸ Import): a visit, not a first run.
    let isVisit: Bool
    private(set) var step: OnboardingStep
    /// Which way the last move went: forward brings the next step up from below, back brings the last one down.
    private(set) var forward = true
    /// The way the camera last travelled across the window (unit length): the steps move with it, so the words and the
    /// sky behind them go the same way.
    private(set) var travel = CGVector(dx: 0, dy: -1)

    /// The welcome's clock: seconds since the galaxy began to gather. `frozen` holds it at one moment (pictures, tests).
    private(set) var began: Date
    var frozen: Double?
    func time(at date: Date = .now) -> Double { frozen ?? date.timeIntervalSince(began) }

    /// The galaxy's pictures, once baked (`prepare`). The clock starts then, so the gathering is never held up by them.
    private(set) var sprites: GalaxySprites?

    private var cameraMove: (from: GalaxyCamera, to: GalaxyCamera, at: Double)
    private var paletteMove: (from: [RGBA], to: [RGBA], at: Double)
    private var pulsedAt: Double?
    /// When Enter Cosmos was chosen, on the clock.
    var enteredAt: Double?
    /// The way in grows the last step's window to fill the screen (see `OnboardingFlow.entryGrow`).
    var grows = false
    /// The welcome's size, as the view last laid it out.
    @ObservationIgnored var windowSize = CGSize.zero
    /// The pointer over the window, -1...1 each way, for the sky's parallax. Read by the galaxy each frame, not watched:
    /// moving the pointer redraws nothing else.
    @ObservationIgnored private(set) var pointer = CGPoint.zero
    /// Something on screen is moving that wants every frame (see `GalaxyView.lively`).
    private(set) var lively = true
    @ObservationIgnored private var calming: Task<Void, Never>?

    /// Opens on `start`: the opening for a first run or Help ▸ Welcome, just the import for File ▸ Import.
    init(store: BrowserStore, window: WindowState, start: OnboardingStep = .welcome) {
        self.store = store
        self.window = window
        // An import marks setup done, but a welcome left part-way and opened again at launch is still the first run.
        isVisit = store.settings.hasCompletedOnboarding && !store.settings.welcomePending
        steps = start == .bring ? [.bring] : OnboardingFlow.steps(canImport: !store.isIncognito)
        step = start
        hadSpaces = !store.workspace.isPristine
        let theme = store.workspace.space(window.focusedSpaceID)?.theme ?? .nebula
        sky = theme
        // On for a first run; a visit finds it as the person left it (the Dock wearing the sky's icon, or not).
        matchIcon = isVisit ? Settings.AppIconStyle(sky: theme) == store.settings.appIcon : true
        began = Self.start(for: start)
        cameraMove = start == .welcome ? (OnboardingFlow.formationCamera, start.camera, OnboardingFlow.cameraSettles)
                                       : (start.camera, start.camera, 0)
        let colours = Galaxy.palette(for: theme)
        paletteMove = (colours, colours, 0)
        preview = WindowState(focusedSpaceID: window.focusedSpaceID, sidebarWidth: window.sidebarWidth)
        preview.selection = window.selection
        // Under a panel, a window's sidebar takes no swipes (see `SidebarView`).
        preview.overlay = .welcome
    }

    /// When the clock reads zero: now for the opening; earlier for a welcome opened part-way in, whose galaxy is whole.
    private static func start(for step: OnboardingStep) -> Date {
        step == .welcome ? .now : Date.now.addingTimeInterval(-(Galaxy.formation + 2))
    }

    /// Bakes the galaxy's pictures off the main thread, then starts the clock.
    func prepare() async {
        guard sprites == nil else { return }
        let art = await Task.detached(priority: .userInitiated) { GalaxyArt.bake() }.value
        sprites = GalaxySprites(art: art)
        if frozen == nil { began = Self.start(for: step) }
        stir(for: step == .welcome ? OnboardingFlow.openingEnds + 0.5 : 1.5)
    }

    /// For pictures: the galaxy's pictures made at once.
    func prepareNow() { sprites = GalaxySprites(art: GalaxyArt.bake()) }

    /// The pointer moved: the layers follow it smoothly, at every frame, until it rests. (Under Reduce Motion they don't
    /// follow it at all.)
    func pointerMoved(to point: CGPoint) {
        guard !Motion.reduced else { return }
        pointer = point
        stir(for: 0.8)
    }

    /// Something starts moving: the galaxy draws every frame until `seconds` from now (or later, if something else is
    /// still moving), then eases back to half rate. One waiting task serves every stir.
    private func stir(for seconds: Double) {
        calmAt = max(calmAt, ProcessInfo.processInfo.systemUptime + seconds)
        if !lively { lively = true }
        guard calming == nil else { return }
        calming = Task { @MainActor [weak self] in
            while let wait = self.map({ $0.calmAt - ProcessInfo.processInfo.systemUptime }), wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
            }
            self?.lively = false
            self?.calming = nil
        }
    }
    @ObservationIgnored private var calmAt: TimeInterval = 0

    // MARK: The galaxy

    func camera(at t: Double) -> GalaxyCamera {
        GalaxyCamera.moving(from: cameraMove.from, to: cameraMove.to, elapsed: t - cameraMove.at)
    }

    func palette(at t: Double) -> [RGBA] {
        OnboardingFlow.palette(from: paletteMove.from, to: paletteMove.to, elapsed: t - paletteMove.at)
    }

    /// The sky's colours once any change has finished (for controls tinted by it, which don't follow frame by frame).
    var settledPalette: [RGBA] { paletteMove.to }

    /// From this width the steps that sit to one side do, with the galaxy (or a preview) on the other.
    static let wideWindow: CGFloat = 1100

    /// A frame for a window of `size`. One too narrow for words beside the galaxy has them over it: there the galaxy goes
    /// down toward its corner and steps back.
    func frame(at t: Double, in size: CGSize) -> GalaxyFrame {
        var frame = frame(at: t)
        if size.width < Self.wideWindow, step.placement != .centre {
            frame.camera.x = 0.5 + (frame.camera.x - 0.5) * 1.3
            frame.camera.y = min(1.02, frame.camera.y + 0.42)
            frame.camera.light *= 0.6
        }
        return frame
    }

    func frame(at t: Double) -> GalaxyFrame {
        let mix = Galaxy.smoothstep(0, 1.1, t - paletteMove.at)
        let pulse = pulsedAt.map { p in Galaxy.smoothstep(0, 0.08, t - p) * exp(-max(0, t - p) * 2.4) } ?? 0
        var frame = GalaxyFrame(camera: camera(at: t), from: paletteMove.from, to: paletteMove.to, mix: mix, pulse: pulse)
        if let entered = enteredAt, !Motion.reduced {
            frame.zoom = OnboardingFlow.entryZoom(at: t - entered)
            frame.bloom = OnboardingFlow.entryBloom(at: t - entered)
        }
        return frame
    }

    /// How much of the welcome is still over the browser, 1 to 0, on the way in.
    func cover(at t: Double) -> Double { enteredAt.map { OnboardingFlow.entryCover(at: t - $0) } ?? 1 }

    /// How much of the words is left on the way in.
    func words(at t: Double) -> Double { enteredAt.map { OnboardingFlow.entryWords(at: t - $0) } ?? 1 }

    /// The galaxy brightens for a moment: it answers a choice.
    private func pulse() {
        pulsedAt = time()
        stir(for: 1.5)
    }

    // MARK: Moving between steps

    var counted: [OnboardingStep] { OnboardingFlow.counted(steps) }
    /// Back goes as far as the first step after the opening, which plays once.
    var canGoBack: Bool { !isBusy && (OnboardingFlow.previous(before: step, in: steps).map { $0 != .welcome } ?? false) }
    /// A browser is being brought over: the welcome stays where it is until that lands (or, if it hangs, for long enough
    /// that it can't be mistaken for quick: then the welcome lets the person go on and the import finishes behind).
    var isBusy: Bool { (running != nil || signIns == .running) && !stalled }
    private(set) var stalled = false
    @ObservationIgnored private var stallWatch: Task<Void, Never>?
    /// How long an import may take before the welcome lets the person move on anyway.
    @ObservationIgnored var patience: Duration = .seconds(25)

    private func watchForStall() {
        stalled = false
        stallWatch?.cancel()
        stallWatch = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.patience ?? .seconds(25))
            guard !Task.isCancelled, let self, self.running != nil || self.signIns == .running else { return }
            self.stalled = true
        }
    }

    /// Return, or the step's main button.
    func primary() {
        guard !isBusy else { return }
        if step == .moves, demoBarOpen { demoBarOpen = false }
        if let next = OnboardingFlow.next(after: step, in: steps) { go(to: next, forward: true) }
        else if steps == [.bring] { close() }
        else { enter() }
    }

    func back() {
        guard canGoBack, let previous = OnboardingFlow.previous(before: step, in: steps) else { return }
        go(to: previous, forward: false)
    }

    /// Back to a step already passed (its mark in the progress bar).
    func revisit(_ target: OnboardingStep) {
        guard target != .welcome, let i = steps.firstIndex(of: target), let j = steps.firstIndex(of: step), i < j else { return }
        go(to: target, forward: false)
    }

    /// Esc, or Skip: a first run goes to the last step (where the way in is) rather than throwing the setup away; a
    /// visit closes.
    func skip() {
        if step == .moves, demoBarOpen { demoBarOpen = false; return }
        if isVisit || steps == [.bring] { if !isBusy { close() }; return }
        guard !isBusy, step != .ready, steps.contains(.ready) else { return }
        go(to: .ready, forward: true)
    }

    private func go(to target: OnboardingStep, forward: Bool) {
        guard enteredAt == nil, !isBusy, target != step else { return }
        let now = time()
        let from = camera(at: now)
        // Reduce Motion: the camera cuts to where it is going instead of travelling there.
        cameraMove = Motion.reduced ? (target.camera, target.camera, now) : (from, target.camera, now)
        let dx = target.camera.x - from.x, dy = target.camera.y - from.y, length = hypot(dx, dy)
        travel = length > 0.05 ? CGVector(dx: dx / length, dy: dy / length) : CGVector(dx: 0, dy: forward ? -1 : 1)
        self.forward = forward
        step = target
        if target == .sky {
            followSpace()
            // The Sky step says whether the Dock follows the sky: from here on it does what the step says.
            followIcon()
        }
        stir(for: 1.6)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: Self.spokenTitle(target), .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// What VoiceOver says as a step comes up.
    static func spokenTitle(_ step: OnboardingStep) -> String {
        switch step {
        case .welcome: "Welcome to Cosmos"
        case .bring: "Bring your browser along"
        case .sky: "Choose a sky"
        case .features: "Make it yours"
        case .moves: "Three moves to know"
        case .ready: "You’re all set"
        }
    }

    // MARK: Bring

    /// The browsers found on this Mac, once looked for (set directly only for pictures of the welcome).
    var sources: [ImportSource] = []
    var sourcesLoaded = false
    private(set) var running: String?
    var results: [String: ImportOutcome] = [:]
    private(set) var failures: [String: String] = [:]
    /// There were spaces here before the welcome opened, so Arc's can go alongside them or in their place.
    let hadSpaces: Bool
    /// Arc's spaces in place of the ones here (asked only when there are some).
    var replacing = false
    enum SignIns: Equatable { case notAsked, running, done(String) }
    var signIns = SignIns.notAsked
    var imported: Bool { !results.isEmpty }

    func loadSources() async {
        guard !sourcesLoaded else { return }
        sources = await ImportCoordinator.sources(for: store)
        sourcesLoaded = true
    }

    /// When spaces came across, on the clock: the Bring step then shows them in the window they will be in.
    var landedAt: Double?

    func run(_ source: ImportSource) {
        guard running == nil else { return }
        running = source.id
        failures[source.id] = nil
        watchForStall()
        Task { @MainActor in
            do {
                results[source.id] = try await source.run(store, window, replacing)
                followSpace()
                if source.bringsSpaces { landedAt = time() }
                pulse()
            } catch is CancellationError {
            } catch {
                failures[source.id] = error.localizedDescription
            }
            running = nil
        }
    }

    /// Arc's saved passwords and site sign-ins, after its spaces, from the folder they came from: macOS asks the person
    /// before Cosmos may read Arc's key.
    func bringSignIns() {
        guard signIns == .notAsked, running == nil else { return }
        let folder = results.values.compactMap(\.arcFolder).first ?? ArcImporter.defaultDirectory
        signIns = .running
        watchForStall()
        Task { @MainActor in
            signIns = .done(await ImportCoordinator.importArcSignIns(into: store, from: folder))
            pulse()
        }
    }

    // MARK: Sky

    static let skies = SpaceTheme.presets
    private(set) var sky: SpaceTheme
    /// The Dock icon follows the sky, for the four skies that have one.
    private(set) var matchIcon: Bool
    var spaceTitle: String { store.workspace.space(window.focusedSpaceID)?.title ?? "this space" }

    /// The sky's colour, deep enough to carry white: switches that are on, the glass's tint. A grey sky's is a quiet
    /// slate; a pale one's is deepened.
    var tint: RGBA {
        let hsb = sky.accent.hsb
        guard hsb.s > 0.06 else { return RGBA(0.42, 0.47, 0.58) }
        return RGBA.fromHSB(h: hsb.h, s: max(0.5, hsb.s), b: min(0.78, max(0.6, hsb.b)))
    }

    func choose(_ theme: SpaceTheme) {
        guard theme != sky else { return }
        recolour(to: theme)
        store.updateSpace(window.focusedSpaceID) { $0.theme = theme }
        followIcon()
        pulse()
    }

    /// The step shows `preview` beside it (on a wide window): the Sky step's in the sky being tried, the Bring step's once
    /// spaces came across, the last step's as it will open (when it opens on its empty page: a page left open is not
    /// drawn).
    var showsPreview: Bool {
        switch step {
        case .sky: true
        case .bring: landedAt != nil
        case .ready: window.selectedItemID == nil
        default: false
        }
    }

    /// The window the welcome shows off (the Sky step, and the Bring step once spaces came across): a copy of this
    /// window's state, so the real sidebar and landing can be drawn in it without anything behind the welcome changing.
    let preview: WindowState

    /// The sky of the space being looked at, which an import may have changed.
    private func followSpace() {
        preview.focusedSpaceID = window.focusedSpaceID
        preview.selection = window.selection
        let theme = store.workspace.space(window.focusedSpaceID)?.theme ?? sky
        guard theme != sky else { return }
        recolour(to: theme)
    }

    private func recolour(to theme: SpaceTheme) {
        let now = time()
        paletteMove = (palette(at: now), Galaxy.palette(for: theme), now)
        sky = theme
        stir(for: 1.5)
    }

    /// The sky beside the one picked (arrow keys).
    func chooseNeighbour(_ offset: Int) {
        let skies = Self.skies
        let i = skies.firstIndex { $0.name == sky.name } ?? 0
        choose(skies[(i + offset + skies.count) % skies.count])
    }

    /// What the Match the App Icon row says, as it stands.
    var matchIconLine: String {
        let kept = store.settings.appIcon.name
        guard matchIcon else { return "The Dock keeps \(kept) whatever the sky." }
        guard Settings.AppIconStyle(sky: sky) != nil else { return "\(sky.name) has no icon of its own, so the Dock keeps \(kept)." }
        return "While Cosmos is open, its Dock icon wears \(sky.name)’s colours."
    }

    func setMatchIcon(_ on: Bool) {
        matchIcon = on
        followIcon()
    }

    private func followIcon() {
        if matchIcon, let icon = Settings.AppIconStyle(sky: sky) { store.settings.appIcon = icon }
    }

    // MARK: Features

    /// The features worth deciding on the first day; the rest are on and stay out of the way.
    static let offered: [Feature] = [.adBlocking, .peek, .boosts, .radialMenu, .utilities, .menuBarBrowser]

    func isOn(_ feature: Feature) -> Bool { store.settings.isOn(feature) }

    func toggle(_ feature: Feature) {
        store.settings.set(feature, on: !isOn(feature))
        pulse()
    }

    // MARK: Moves

    enum Move: CaseIterable { case commandBar, swipe, sidebar }
    var done: Set<Move> = []
    /// The practice window the moves are tried in.
    var demoBarOpen = false
    private(set) var demoSidebar = true
    private(set) var demoSpace = 0
    /// Which way it last went: 1 to the next space (the old one leaves to the left), -1 back.
    private(set) var demoDirection = 1
    /// How far the fingers have moved its sidebar toward the next space, in points.
    private(set) var demoDrag: CGFloat = 0

    func perform(_ move: Move, direction: Int = 1) {
        switch move {
        case .commandBar:
            demoBarOpen.toggle()
            demoQuery = ""
        case .sidebar: demoSidebar.toggle()
        case .swipe:
            demoDirection = direction > 0 ? 1 : -1
            demoSpace = 1 - demoSpace
            demoOpened = nil
        }
        if done.insert(move).inserted { pulse() }
    }

    /// What has been typed into the practice Command Bar, and which of its results is picked.
    var demoQuery = "" { didSet { demoSelection = 0 } }
    private(set) var demoSelection = 0
    /// The tab the practice window shows (the first of its space's, until one is opened from the Command Bar).
    private(set) var demoOpened: String?

    /// The practice Command Bar's tabs for what is typed (it offers a search for the words after them).
    var demoResults: [PracticeTab] {
        let query = demoQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Array(demoTabs.prefix(3)) }
        return Array(demoTabs.filter { $0.title.localizedCaseInsensitiveContains(query) }.prefix(3))
    }

    /// The practice window's two spaces' tabs (its own made-up ones: nothing of the person's is tried on).
    struct PracticeTab: Equatable { let symbol: String; let title: String }
    static let practiceTabs: [[PracticeTab]] = [
        [PracticeTab(symbol: "newspaper.fill", title: "Morning reading"), PracticeTab(symbol: "fork.knife", title: "Recipes to try"),
         PracticeTab(symbol: "airplane", title: "Weekend trip"), PracticeTab(symbol: "music.note", title: "Evening playlist")],
        [PracticeTab(symbol: "doc.richtext.fill", title: "Design review"), PracticeTab(symbol: "chart.bar.fill", title: "Q4 roadmap"),
         PracticeTab(symbol: "bubble.left.and.bubble.right.fill", title: "Team chat"), PracticeTab(symbol: "calendar", title: "This week")],
    ]

    /// Every practice tab, the space on show's first: the order the practice Command Bar lists them in.
    var demoTabs: [PracticeTab] { Self.practiceTabs[demoSpace] + Self.practiceTabs[1 - demoSpace] }

    func moveDemoSelection(_ by: Int) {
        let count = demoResults.count + (demoQuery.isEmpty ? 0 : 1)
        guard count > 0 else { return }
        demoSelection = (demoSelection + by + count) % count
    }

    /// Return in the practice Command Bar (or a click on a row): the picked tab opens in the practice window; a search
    /// opens as a page of results.
    func openDemoResult(at index: Int? = nil) {
        if let index { demoSelection = index }
        let results = demoResults
        demoOpened = demoSelection < results.count ? results[demoSelection].title : "Results for “\(demoQuery)”"
        demoBarOpen = false
        demoQuery = ""
        done.insert(.commandBar)
        pulse()
    }

    func dragDemo(by dx: CGFloat) { demoDrag += dx }

    /// The fingers lifted: far enough, and the practice window moves to the other space.
    func endDemoDrag() {
        if abs(demoDrag) > 36 { perform(.swipe, direction: demoDrag < 0 ? 1 : -1) }
        demoDrag = 0
    }

    // MARK: Ready

    private(set) var isDefault = DefaultBrowser.isDefault

    func makeDefault() {
        DefaultBrowser.request { [weak self] ok in
            self?.isDefault = ok || DefaultBrowser.isDefault
            if self?.isDefault == true { self?.pulse() }
        }
    }

    /// Enter Cosmos: the words go, the camera dollies into the core, its light fills the window and clears to the
    /// browser, which settles into place. Under Reduce Motion the welcome only fades.
    func enter() {
        guard enteredAt == nil else { return }
        completeFirstRun()
        let now = time()
        enteredAt = now
        if !Motion.reduced {
            let from = camera(at: now)
            cameraMove = (from, GalaxyCamera(x: 0.5, y: 0.5, scale: from.scale, light: 1), now)
        }
        stir(for: OnboardingFlow.entryDuration + 0.5)
        // The empty window of a first run (a live page is left as it is): from the last step of a wide window, the
        // window beside the words grows into it; otherwise it waits under the light, a little large and soft, and
        // settles as the light clears.
        let empty = !Motion.reduced && !isVisit && window.selectedItemID == nil
        grows = empty && step == .ready && windowSize.width >= Self.wideWindow
        if empty, !grows { window.arriving = true }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(OnboardingFlow.arrivalStarts))
            guard let self else { return }
            withAnimation(Motion.reduced ? nil : .smooth(duration: 0.85)) { self.window.arriving = false }
            // The browser lands: a step down, felt on a Force Touch trackpad.
            self.store.haptics.levelChange()
            try? await Task.sleep(for: .seconds(OnboardingFlow.entryDuration - OnboardingFlow.arrivalStarts))
            self.finish()
        }
    }

    /// Closes at once (a visit's Esc, File ▸ Import's Done).
    func close() {
        completeFirstRun()
        finish()
    }

    private func completeFirstRun() {
        store.settings.hasCompletedOnboarding = true
        store.settings.welcomePending = false
    }

    /// The welcome goes. A first run lands on the window itself, whose empty page offers the search the Moves step
    /// taught (⌘T); nothing pops over the arrival.
    private func finish() {
        window.arriving = false
        guard window.overlay == .welcome || window.overlay == .importBrowser else { return }
        window.overlay = nil
    }

    // MARK: Keys

    /// A key while the welcome is up: whether it was the welcome's, so nothing behind the welcome sees it. Keys are known
    /// by their letter or, on a layout without Latin letters, by where they sit on the keyboard. A held key repeats
    /// only where repeating makes sense (trying skies).
    func handleKey(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool = false) -> Bool {
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        switch (keyCode, mods) {
        case (53, []):                                          // Esc
            if !isRepeat { skip() }
            return true
        case (36, []), (76, []):                                // Return, Enter
            if !isRepeat { step == .moves && demoBarOpen ? openDemoResult() : primary() }
            return true
        case (125, []) where step == .moves && demoBarOpen, (126, []) where step == .moves && demoBarOpen:
            moveDemoSelection(keyCode == 125 ? 1 : -1)
            return true
        case (123, []) where step == .sky, (124, []) where step == .sky:
            // Held, the skies go by at a pace the eye can follow.
            let now = ProcessInfo.processInfo.systemUptime
            if !isRepeat || now - lastSkyKey > 0.16 {
                lastSkyKey = now
                chooseNeighbour(keyCode == 124 ? 1 : -1)
            }
            return true
        case (123, [.command, .option]) where step == .moves, (124, [.command, .option]) where step == .moves:
            if !isRepeat { perform(.swipe, direction: keyCode == 124 ? 1 : -1) }
            return true
        default: break
        }
        guard mods.contains(.command) else { return false }
        let latin = characters.unicodeScalars.allSatisfy(\.isASCII)
        let typesLetters = characters.contains { $0.isASCII && $0.isLetter }
        // The practice Command Bar's field edits as any field does (select all, copy, paste, cut, undo, delete a word),
        // on any layout.
        let edits: [(String, UInt16)] = [("a", 0), ("c", 8), ("v", 9), ("x", 7), ("z", 6)]
        if step == .moves, demoBarOpen, !mods.contains(.control),
           edits.contains(where: { characters == $0.0 || (!typesLetters && keyCode == $0.1) }) || [51, 117, 123, 124].contains(keyCode) {
            return false
        }
        func key(_ letter: String, _ code: UInt16) -> Bool { characters == letter || (!latin && keyCode == code) }
        if key("[", 33) { if !isRepeat { back() }; return true }
        if step == .moves, mods == .command, key("t", 17) { if !isRepeat { perform(.commandBar) }; return true }
        if step == .moves, mods == .command, key("s", 1) { if !isRepeat { perform(.sidebar) }; return true }
        // Quitting, closing, hiding, minimising and Settings work as ever, known by letter or by place on the keyboard
        // (some layouts put punctuation there); anything else meant for the browser behind waits until the welcome is
        // done.
        let passes = [("q", UInt16(12)), ("w", 13), ("h", 4), ("m", 46), (",", 43), ("`", 50)]
        return !passes.contains { characters == $0.0 || (!typesLetters && keyCode == $0.1) }
    }
    @ObservationIgnored private var lastSkyKey: TimeInterval = 0
}

extension Settings.AppIconStyle {
    /// The icon drawn in this sky's colours, for the four skies that have one.
    init?(sky: SpaceTheme) {
        guard let style = Self.allCases.first(where: { $0.name == sky.name }) else { return nil }
        self = style
    }
}
