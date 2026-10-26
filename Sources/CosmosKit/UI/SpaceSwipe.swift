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
            // Only trackpad gestures have phases; a mouse wheel scrolls the list as usual.
            guard event.phase != [] || event.momentumPhase != [] else { return event }

            if event.momentumPhase != [] {
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { swallowMomentum = false }
                return swallowMomentum ? nil : event
            }

            if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                let p = convert(event.locationInWindow, from: nil)
                gesture = bounds.contains(p) ? .undecided(0, 0) : .idle
                swallowMomentum = false
            }

            let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            if case .undecided(let ax, let ay) = gesture {
                let (nx, ny) = (ax + abs(event.scrollingDeltaX), ay + abs(event.scrollingDeltaY))
                // Decide once the fingers have moved a few points: mostly sideways is ours, anything else is a scroll.
                gesture = nx + ny < 4 ? .undecided(nx, ny) : (nx > ny * 1.2 ? .horizontal : .vertical)
            }

            var consumed = false
            if case .horizontal = gesture {
                consumed = true
                if event.phase.contains(.changed) || event.phase.contains(.began) { onMove?(dx) }
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                if case .horizontal = gesture { onEnd?(); swallowMomentum = true }
                gesture = .idle
            }
            return consumed ? nil : event
        }

        func uninstall() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
