import Foundation

/// The welcome, step by step. Pure: which steps there are, the order, where the camera looks for each, and the opening's
/// choreography as functions of time, so it can be tested and any frame drawn on its own.
public enum OnboardingStep: String, CaseIterable, Sendable, Identifiable {
    /// The galaxy gathers and the name comes up.
    case welcome
    /// Bring another browser's spaces, tabs, history and sign-ins across.
    case bring
    /// A sky for the first space.
    case sky
    /// Which features to have.
    case features
    /// Three moves to try: the Command Bar, a swipe between spaces, hiding the sidebar.
    case moves
    /// Default browser, and into Cosmos.
    case ready

    public var id: String { rawValue }

    public enum Placement: Sendable { case leading, centre, trailing }

    /// Where the step's words sit in a wide window: to one side, with the galaxy on the other, or in the middle.
    public var placement: Placement {
        switch self {
        case .bring, .sky, .ready: .leading
        case .features: .trailing
        case .welcome, .moves: .centre
        }
    }

    /// Where the galaxy sits while this step is up. The welcome has it below the name; between, it moves from side to
    /// side opposite the words (see `placement`), as if the window were travelling past it; at the end it is whole again,
    /// to fall into.
    public var camera: GalaxyCamera {
        switch self {
        case .welcome: GalaxyCamera(x: 0.5, y: 0.74, scale: 0.66, light: 1)
        case .bring: GalaxyCamera(x: 0.8, y: 0.5, scale: 0.56, light: 0.72)
        case .sky: GalaxyCamera(x: 0.5, y: 1.02, scale: 0.8, light: 0.62)
        case .features: GalaxyCamera(x: 0.2, y: 0.5, scale: 0.56, light: 0.72)
        case .moves: GalaxyCamera(x: 0.9, y: 0.86, scale: 0.42, light: 0.45)
        case .ready: GalaxyCamera(x: 0.5, y: 0.8, scale: 0.62, light: 0.9)
        }
    }
}

public enum OnboardingFlow {
    /// The steps, in order. A private window cannot keep an import, so it has no Bring step.
    public static func steps(canImport: Bool) -> [OnboardingStep] {
        OnboardingStep.allCases.filter { canImport || $0 != .bring }
    }

    public static func next(after step: OnboardingStep, in steps: [OnboardingStep]) -> OnboardingStep? {
        guard let i = steps.firstIndex(of: step), i + 1 < steps.count else { return nil }
        return steps[i + 1]
    }

    public static func previous(before step: OnboardingStep, in steps: [OnboardingStep]) -> OnboardingStep? {
        guard let i = steps.firstIndex(of: step), i > 0 else { return nil }
        return steps[i - 1]
    }

    /// The steps the progress bar counts: all but the opening.
    public static func counted(_ steps: [OnboardingStep]) -> [OnboardingStep] { steps.filter { $0 != .welcome } }

    // MARK: The opening

    /// While the galaxy gathers the camera holds it in the middle; then it sinks below where the name comes up.
    public static let formationCamera = GalaxyCamera(x: 0.5, y: 0.52, scale: 0.58, light: 1)
    public static let cameraSettles = 1.8

    /// The mark's bars sweep in one after another, top to bottom.
    public static let markStarts = 1.75
    public static let barGap = 0.045
    public static let barSweep = 0.7
    /// Then the name, one letter after another.
    public static let titleStarts = 2.2
    public static let letterGap = 0.06
    public static let letterRise = 0.8
    public static let lineStarts = 2.95
    public static let buttonStarts = 3.4
    /// By then everything in the opening is in place.
    public static let openingEnds = 4.1

    /// How far bar `index` of the mark has swept in at `time`, 0...1 (eased).
    public static func bar(_ index: Int, at time: Double) -> Double {
        appear(at: time, from: markStarts + Double(index) * barGap, over: barSweep)
    }

    /// How far letter `index` of the name has come in at `time`, 0...1 (eased).
    public static func letter(_ index: Int, at time: Double) -> Double {
        appear(at: time, from: titleStarts + Double(index) * letterGap, over: letterRise)
    }

    /// How far the name's bars have closed up into whole letters (after the last letter is in).
    public static func fuse(at time: Double) -> Double { appear(at: time, from: fuseStarts, over: 0.8) }
    public static let fuseStarts = 3.3

    /// How far the line under the name has come in.
    public static func line(at time: Double) -> Double { appear(at: time, from: lineStarts, over: 0.8) }

    /// How far the button has come in.
    public static func button(at time: Double) -> Double { appear(at: time, from: buttonStarts, over: 0.7) }

    /// 0 before `start`, 1 after `start + duration`, eased out between (fast, then settling).
    public static func appear(at time: Double, from start: Double, over duration: Double) -> Double {
        let t = min(1, max(0, (time - start) / duration))
        return 1 - pow(1 - t, 4)
    }

    // MARK: The way in

    /// After Enter Cosmos: the words go, the camera dollies into the galaxy's core, its light fills the window, and the
    /// light clears to the browser, which settles into place under it.
    public static let entryDuration = 1.6
    /// When the browser behind starts to settle (it waits, slightly large and soft, under the light).
    public static let arrivalStarts = 1.0

    /// How much of the words is left: they go first, before the camera moves far.
    public static func entryWords(at elapsed: Double) -> Double { 1 - Galaxy.smoothstep(0, 0.3, elapsed) }

    /// How much larger the galaxy is drawn `elapsed` seconds into the way in: slow at first, then rushing to the core.
    public static func entryZoom(at elapsed: Double) -> Double {
        let t = min(1, max(0, elapsed / 1.15))
        return 1 + 8 * pow(t, 2.6)
    }

    /// The core's light filling the window as the camera reaches it, 0...1.
    /// From the last step of a wide window: how far the window beside the words has grown to fill the screen (it is the
    /// browser, drawn, and hands over to it as the welcome clears). Eased in and out, done before the light clears.
    public static func entryGrow(at elapsed: Double) -> Double {
        let x = Galaxy.smoothstep(0.05, 1.0, elapsed)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    public static func entryBloom(at elapsed: Double) -> Double { Galaxy.smoothstep(0.55, 1.1, elapsed) }

    /// How much of the welcome is still there, 1 to 0: it holds through the fall and the light, then clears.
    public static func entryCover(at elapsed: Double) -> Double {
        1 - Galaxy.smoothstep(arrivalStarts + 0.05, entryDuration, elapsed)
    }

    // MARK: Colour

    /// Colours `elapsed` seconds into a change from one palette to another: eased over about a second.
    public static func palette(from: [RGBA], to: [RGBA], elapsed: Double) -> [RGBA] {
        let k = Galaxy.smoothstep(0, 1.1, elapsed)
        guard k < 1 else { return to }
        return zip(from, to).map { $0.mixed(with: $1, k) }
    }
}
