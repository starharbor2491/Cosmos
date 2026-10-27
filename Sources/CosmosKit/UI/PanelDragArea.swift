import SwiftUI
import AppKit
import CosmosCore

/// Behind the menu-bar panel's page: the strips around the page and the gaps in the toolbar take hold of the panel and
/// move it, like the edge of a window. The page and the controls are above it and keep their own clicks.
struct PanelDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PanelDragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class PanelDragView: NSView {
        /// Where in the window the pointer took hold.
        private var grab: NSPoint?

        /// A drag moves the panel by how far the pointer is from where it took hold, measured in the panel's own
        /// coordinates: as the panel follows, the pointer stays at the same place in it.
        override func mouseDown(with event: NSEvent) {
            grab = event.locationInWindow
        }

        /// A click that makes the panel key (it is pinned and something else has the keyboard) still takes hold of it.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let grab else { return }
            var frame = window.frame
            frame.origin.x += event.locationInWindow.x - grab.x
            frame.origin.y += event.locationInWindow.y - grab.y
            // Kept on the screen the pointer is over, so it can cross to another display but not end up in the dead space
            // between displays of different sizes.
            let pointer = window.convertPoint(toScreen: event.locationInWindow)
            let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? window.screen ?? NSScreen.main
            window.setFrame(screen.map { MenuBarPlacement.dragged(frame, visible: $0.visibleFrame) } ?? frame, display: true)
        }

        override func mouseUp(with event: NSEvent) {
            grab = nil
        }
    }
}
