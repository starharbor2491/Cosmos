import AppKit
import Testing
@testable import CosmosKit

/// What the sidebar's swipe view makes of a stream of two-finger scroll samples: which belong to a sideways swipe (taken)
/// and which to a scroll (left alone), and what it reports.
@MainActor
@Suite struct SwipeViewTests {
    private final class Log { var moves: [CGFloat] = []; var ends = 0 }

    private func view(_ log: Log) -> SwipeCatcher.SwipeView {
        let v = SwipeCatcher.SwipeView()
        v.onMove = { log.moves.append($0) }
        v.onEnd = { log.ends += 1 }
        return v
    }

    @Test func aSidewaysSwipeIsTakenReportedAndEnded() {
        let log = Log(), v = view(log)
        #expect(v.handle(.init(phase: .began)) == false, "nothing is known yet")
        #expect(v.handle(.init(phase: .changed, deltaX: -10)))
        #expect(v.handle(.init(phase: .changed, deltaX: -12)))
        #expect(v.handle(.init(phase: .ended)))
        #expect(log.moves == [-10, -12])
        #expect(log.ends == 1)
    }

    @Test func aScrollDownTheListIsLeftAlone() {
        let log = Log(), v = view(log)
        v.handle(.init(phase: .began))
        #expect(v.handle(.init(phase: .changed, deltaX: 1, deltaY: 14)) == false)
        #expect(v.handle(.init(phase: .changed, deltaX: 2, deltaY: 14)) == false)
        v.handle(.init(phase: .ended))
        #expect(log.moves.isEmpty && log.ends == 0)
    }

    @Test func aSwipeThatBeginsOutsideTheViewIsNotItsOwn() {
        let log = Log(), v = view(log)
        v.handle(.init(phase: .began, inside: false))
        #expect(v.handle(.init(phase: .changed, deltaX: -30)) == false)
        #expect(log.moves.isEmpty)
    }

    @Test func aMouseWheelHasNoPhaseAndScrollsTheListAsUsual() {
        let log = Log(), v = view(log)
        #expect(v.handle(.init(phase: [], deltaX: -30)) == false)
        #expect(log.moves.isEmpty)
    }

    /// The fingers' direction is what counts, whatever the "natural scrolling" setting says.
    @Test func fingersMovingLeftAreNegativeWithOrWithoutNaturalScrolling() {
        for inverted in [true, false] {
            let log = Log(), v = view(log)
            v.handle(.init(phase: .began, inverted: inverted))
            // With natural scrolling off the system reports the opposite sign for the same finger movement.
            v.handle(.init(phase: .changed, deltaX: inverted ? -20 : 20, inverted: inverted))
            #expect(log.moves == [-20], "inverted: \(inverted)")
        }
    }

    @Test func theMomentumAfterASwipeIsSwallowedUntilItEnds() {
        let log = Log(), v = view(log)
        v.handle(.init(phase: .began))
        v.handle(.init(phase: .changed, deltaX: -20))
        v.handle(.init(phase: .ended))
        #expect(v.handle(.init(phase: [], momentumPhase: .changed, deltaX: -5)), "it would scroll or swipe on its own")
        #expect(v.handle(.init(phase: [], momentumPhase: .ended)) == false, "the last one carries nothing and is let through")
        #expect(v.handle(.init(phase: [], momentumPhase: .changed, deltaX: -5)) == false, "the next gesture's momentum is its own")
        #expect(log.ends == 1)
    }

    @Test func aCancelledSwipeStillEndsSoThePageCanSpringBack() {
        let log = Log(), v = view(log)
        v.handle(.init(phase: .began))
        v.handle(.init(phase: .changed, deltaX: -20))
        v.handle(.init(phase: .cancelled))
        #expect(log.ends == 1)
    }

    @Test func eachSwipeDecidesForItself() {
        let log = Log(), v = view(log)
        v.handle(.init(phase: .began))
        v.handle(.init(phase: .changed, deltaX: 0, deltaY: 20))   // a scroll
        v.handle(.init(phase: .ended))
        v.handle(.init(phase: .began))
        #expect(v.handle(.init(phase: .changed, deltaX: -20)), "the next one is sideways")
        #expect(log.moves == [-20])
    }
}
