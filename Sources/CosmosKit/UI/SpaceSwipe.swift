import SwiftUI
import AppKit

/// Reports a two-finger horizontal swipe made anywhere over its area: every movement while the fingers are down,
/// then the lift. Vertical scrolling and mouse wheels pass through untouched.
struct SwipeCatcher: NSViewRepresentable {
    /// Horizontal movement since the last event, positive when the fingers move right (whatever the "natural
    /// scrolling" setting says).
    let onMove: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = SwipeView()
        v.onMove = onMove
        v.onEnd = onEnd
        v.install()
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? SwipeView)?.onMove = onMove
        (nsView as? SwipeView)?.onEnd = onEnd
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) { (nsView as? SwipeView)?.uninstall() }

    /// What the swipe logic needs of one scroll event, so a test (or the automation harness) can feed it exactly that.
    struct Sample {
        var phase: NSEvent.Phase
        var momentumPhase: NSEvent.Phase = []
        var deltaX: CGFloat = 0
        var deltaY: CGFloat = 0
        /// "Natural" scrolling: the content follows the fingers.
        var inverted = true
        /// The fingers came down inside the view (only read when a gesture begins).
        var inside = true
    }

    final class SwipeView: NSView {
        var onMove: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?
        private var monitor: Any?

        private enum Gesture { case idle, undecided(CGFloat, CGFloat), horizontal, vertical }
        private var gesture = Gesture.idle
        /// Momentum events that follow a swipe are swallowed too, so they don't scroll anything.
        private var swallowMomentum = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }
            let sample = Sample(phase: event.phase, momentumPhase: event.momentumPhase, deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                                inverted: event.isDirectionInvertedFromDevice, inside: bounds.contains(convert(event.locationInWindow, from: nil)))
            return handle(sample) ? nil : event
        }

        /// Whether the swipe took the event (the scroll view must not see it).
        @discardableResult
        func handle(_ sample: Sample) -> Bool {
            // Only trackpad gestures have phases; a mouse wheel scrolls the list as usual.
            guard sample.phase != [] || sample.momentumPhase != [] else { return false }

            if sample.momentumPhase != [] {
                if sample.momentumPhase.contains(.ended) || sample.momentumPhase.contains(.cancelled) { swallowMomentum = false }
                return swallowMomentum
            }

            if sample.phase.contains(.began) || sample.phase.contains(.mayBegin) {
                gesture = sample.inside ? .undecided(0, 0) : .idle
                swallowMomentum = false
            }

            let dx = sample.inverted ? sample.deltaX : -sample.deltaX
            if case .undecided(let ax, let ay) = gesture {
                let (nx, ny) = (ax + abs(sample.deltaX), ay + abs(sample.deltaY))
                // Decide once the fingers have moved a few points: mostly sideways is ours, anything else is a scroll.
                gesture = nx + ny < 4 ? .undecided(nx, ny) : (nx > ny * 1.2 ? .horizontal : .vertical)
            }

            var consumed = false
            if case .horizontal = gesture {
                consumed = true
                if sample.phase.contains(.changed) || sample.phase.contains(.began) { onMove?(dx) }
            }
            if sample.phase.contains(.ended) || sample.phase.contains(.cancelled) {
                if case .horizontal = gesture { onEnd?(); swallowMomentum = true }
                gesture = .idle
            }
            return consumed
        }

        func uninstall() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
