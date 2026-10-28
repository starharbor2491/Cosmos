import CoreGraphics

/// Follows a two-finger horizontal swipe across the sidebar: how far the content should be pulled, when the swipe has
/// gone far enough to count, and what happens when the fingers lift. Pure, so the feel can be tested.
///
/// `delta` is the fingers' horizontal movement: negative when they move left, which goes to the next space.
struct SwipeTracker {
    enum Tick { case none, armed, disarmed }

    /// How much of the fingers' movement counts: the page follows a little behind them, so a swipe is a deliberate thing and
    /// a brush against the trackpad does not slide the sidebar.
    static let damping: CGFloat = 0.8

    /// How far the fingers must travel (after damping) before lifting them counts.
    var commitDistance: CGFloat = 70
    /// The most the content can be pulled along when the swipe is allowed: one page.
    var maxTravel: CGFloat = 96
    var canGoPrevious = true
    var canGoNext = true

    private var travelled: CGFloat = 0
    private var armed = false

    private var allowed: Bool { travelled < 0 ? canGoNext : canGoPrevious }

    /// Where the content should sit right now: when there is a page in that direction it comes in under the fingers (a
    /// little behind them, see `damping`); when there is not, the content barely moves.
    var offset: CGFloat {
        allowed ? max(-maxTravel, min(maxTravel, travelled)) : Self.band(travelled, limit: 28, stiffness: 0.55)
    }

    /// Adds one scroll event. The result says when to tick under the finger.
    mutating func update(delta: CGFloat) -> Tick {
        travelled += delta * Self.damping
        let nowArmed = allowed && abs(travelled) >= commitDistance
        defer { armed = nowArmed }
        if nowArmed && !armed { return .armed }
        if !nowArmed && armed { return .disarmed }
        return .none
    }

    /// The fingers lifted: +1 for the next space, -1 for the previous, nil to spring back. Resets the tracker.
    mutating func finish() -> Int? {
        defer { reset() }
        guard armed else { return nil }
        return travelled < 0 ? 1 : -1
    }

    mutating func reset() {
        travelled = 0
        armed = false
    }

    /// Rubber-band curve: close to 1:1 at first, approaching `limit` the further you pull.
    static func band(_ x: CGFloat, limit: CGFloat, stiffness: CGFloat) -> CGFloat {
        let magnitude = (1 - 1 / (abs(x) * stiffness / limit + 1)) * limit
        return x < 0 ? -magnitude : magnitude
    }
}
