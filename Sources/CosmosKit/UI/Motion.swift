import SwiftUI
import AppKit

/// How things move. Three curves cover the interface, and all of them stand down when the user has turned on
/// Reduce Motion (state then changes at once).
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Hover, press release, small state flips.
    static var quick: Animation? { reduced ? nil : .snappy(duration: 0.16) }
    /// Panels, a highlight gliding between rows, lists reflowing.
    static var standard: Animation? { reduced ? nil : .smooth(duration: 0.26) }
    /// Things that land: a tab opening, a swipe settling.
    static var spring: Animation? { reduced ? nil : .spring(duration: 0.38, bounce: 0.22) }
    /// The whole window changing mood: crossing to another space's sky.
    static var glide: Animation? { reduced ? nil : .easeInOut(duration: 0.42) }

    /// A row entering or leaving a list: it grows out of (and shrinks into) the row above it.
    static let row: AnyTransition = .opacity.combined(with: .scale(scale: 0.94, anchor: .top))
    /// A control appearing on hover: pops in from its centre.
    static let pop: AnyTransition = .scale(scale: 0.7).combined(with: .opacity)
}

extension View {
    /// An SF Symbol that bounces when `value` changes, unless Reduce Motion is on.
    func symbolBounce<V: Equatable>(value: V) -> some View {
        symbolEffect(.bounce, value: value).symbolEffectsRemoved(Motion.reduced)
    }

    /// An SF Symbol that swaps for another with a transition, or at once under Reduce Motion.
    func symbolSwap() -> some View {
        contentTransition(Motion.reduced ? .identity : .symbolEffect(.replace))
    }
}

/// Shrinks slightly while pressed and springs back, so every control answers the click before the action lands.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

/// The same press feel for things that are not buttons (rows with their own tap and drag gestures). It watches the
/// mouse with a passive monitor instead of adding a gesture, so it can never get in the way of a drag.
private struct PressEffect: ViewModifier {
    let scale: CGFloat
    @Local private var pressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? scale : 1)
            .animation(Motion.quick, value: pressed)
            .background(PressMonitor { pressed = $0 })
    }
}

struct PressMonitor: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = MonitorView()
        v.onChange = onChange
        v.install()
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? MonitorView)?.onChange = onChange }
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) { (nsView as? MonitorView)?.uninstall() }

    final class MonitorView: NSView {
        var onChange: ((Bool) -> Void)?
        private var monitor: Any?
        private var downAt: NSPoint?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                switch event.type {
                case .leftMouseDown:
                    if self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.downAt = event.locationInWindow; self.onChange?(true) }
                case .leftMouseDragged:
                    // A drag has begun: let go of the press so the drag preview isn't taken from a shrunken row.
                    if let d = self.downAt, hypot(event.locationInWindow.x - d.x, event.locationInWindow.y - d.y) > 3 { self.downAt = nil; self.onChange?(false) }
                case .leftMouseUp:
                    if self.downAt != nil { self.downAt = nil; self.onChange?(false) }
                default: break
                }
                return event
            }
        }

        func uninstall() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

extension View {
    func pressEffect(_ scale: CGFloat = 0.985) -> some View { modifier(PressEffect(scale: scale)) }
}

// MARK: - Selection highlight

private struct SelectionNamespaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }

extension EnvironmentValues {
    /// Rows in a list share one namespace so the selection highlight can glide from the old row to the new one.
    var selectionNamespace: Namespace.ID? {
        get { self[SelectionNamespaceKey.self] }
        set { self[SelectionNamespaceKey.self] = newValue }
    }
}

/// The background of a sidebar row or tile: a hover wash, and the selection highlight, which is one shape that
/// glides between rows instead of switching off in one place and on in another.
struct RowBackground: View {
    var selected: Bool
    var hover: Bool
    var radius: CGFloat
    /// Tiles have a fill at rest; rows are clear until hovered.
    var resting = false
    /// A pane of a split view that has focus: highlighted, but not the one shape that glides.
    var plainSelected = false
    @Environment(\.palette) private var palette
    @Environment(\.selectionNamespace) private var namespace

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(wash)
            if plainSelected { shape.fill(palette.selected) }
            if selected {
                if let namespace {
                    highlight(shape).matchedGeometryEffect(id: "sidebar.selection", in: namespace)
                } else {
                    highlight(shape)
                }
            }
        }
        .animation(Motion.quick, value: hover)
    }

    private var wash: Color {
        if resting { return hover ? palette.hoverStrong : palette.hover }
        return hover ? palette.hover : .clear
    }

    private func highlight(_ shape: RoundedRectangle) -> some View {
        shape.fill(palette.selected)
            .shadow(color: palette.shadow.opacity(0.4), radius: 3, y: 1)
            .overlay(shape.strokeBorder(palette.stroke, lineWidth: 0.8))
    }
}

// MARK: - Drag preview

/// What follows the pointer while a tab or folder is dragged: its icon and name on a small card, not a snapshot of the row.
struct DragPreview: View {
    let store: BrowserStore
    let url: URL?
    let title: String
    var symbol: String?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Metrics.Sidebar.gap) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: Metrics.Icon.row, height: Metrics.Icon.row)
            } else {
                FaviconView(store: store, url: url, size: Metrics.Icon.row)
            }
            Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(palette.text)
        .padding(.horizontal, Metrics.Space.m)
        .frame(height: Metrics.Height.row)
        .frame(maxWidth: 220)
        .background(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).fill(palette.panel))
        .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).strokeBorder(palette.stroke, lineWidth: 0.8))
        .shadow(color: palette.shadow, radius: 10, y: 4)
        .padding(Metrics.Space.m)
    }
}
