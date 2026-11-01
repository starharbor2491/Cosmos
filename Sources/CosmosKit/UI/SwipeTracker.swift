import CoreGraphics
import Foundation

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

    /// A flick: fingers that lift while still moving at least this fast (points a second, as counted after damping), in
    /// the direction they have moved, go to the next page in that direction though short of `commitDistance`, as long
    /// as they moved `flickDistance`. Moving fast the other way at the end cancels a swipe that had gone far enough.
    static let flickSpeed: CGFloat = 600
    static let flickDistance: CGFloat = 16
    /// The fingers count as still moving when they lift this soon after their last movement.
    static let stillMoving: TimeInterval = 0.05

    private var travelled: CGFloat = 0
    private var armed = false
    /// Where the fingers had got, and when, over the last tenth of a second: how fast they were going.
    private var recent: [(time: TimeInterval, travelled: CGFloat)] = []

    private var allowed: Bool { travelled < 0 ? canGoNext : canGoPrevious }

    /// Where the content should sit right now: when there is a page in that direction it comes in under the fingers (a
    /// little behind them, see `damping`); when there is not, the content barely moves.
    var offset: CGFloat {
        allowed ? max(-maxTravel, min(maxTravel, travelled)) : Self.band(travelled, limit: 28, stiffness: 0.55)
    }

    /// Adds one scroll event, at `time` (seconds, any clock; with none, no flick can be told). The result says when to
    /// tick under the finger.
    mutating func update(delta: CGFloat, at time: TimeInterval? = nil) -> Tick {
        travelled += delta * Self.damping
        if let time {
            recent.append((time, travelled))
            recent.removeAll { time - $0.time > 0.1 }
        }
        let nowArmed = allowed && abs(travelled) >= commitDistance
        defer { armed = nowArmed }
        if nowArmed && !armed { return .armed }
        if !nowArmed && armed { return .disarmed }
        return .none
    }

    /// The fingers lifted (at `time`): +1 for the next space, -1 for the previous, nil to spring back. Resets the tracker.
    mutating func finish(at time: TimeInterval? = nil) -> Int? {
        defer { reset() }
        let speed = velocity(at: time)
        if abs(speed) >= Self.flickSpeed {
            // Fast the way they have gone: a flick there. Fast back the other way: whatever they had done is let go.
            guard (speed < 0) == (travelled < 0), abs(travelled) >= Self.flickDistance, allowed else { return nil }
            return travelled < 0 ? 1 : -1
        }
        guard armed else { return nil }
        return travelled < 0 ? 1 : -1
    }

    /// How fast the fingers were moving at `time`, over their last 50 ms (so a quick turn back is not averaged away),
    /// points a second; 0 when they had come to rest or nothing was timed.
    private func velocity(at time: TimeInterval?) -> CGFloat {
        guard let time, let last = recent.last, time - last.time <= Self.stillMoving,
              let first = recent.first(where: { last.time - $0.time <= 0.05 }), last.time > first.time else { return 0 }
        return (last.travelled - first.travelled) / CGFloat(last.time - first.time)
    }

    mutating func reset() {
        travelled = 0
        armed = false
        recent = []
    }

    /// Rubber-band curve: close to 1:1 at first, approaching `limit` the further you pull.
    static func band(_ x: CGFloat, limit: CGFloat, stiffness: CGFloat) -> CGFloat {
        let magnitude = (1 - 1 / (abs(x) * stiffness / limit + 1)) * limit
        return x < 0 ? -magnitude : magnitude
    }
}
