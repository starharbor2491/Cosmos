import SwiftUI
import AppKit
import CosmosCore

/// One slice of the ring as a shape: between two radii and two angles (clockwise from twelve o'clock).
struct AnnularSector: Shape {
    var startAngle: Double
    var endAngle: Double
    var innerRadius: Double
    var outerRadius: Double

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        func point(_ angle: Double, _ radius: Double) -> CGPoint { CGPoint(x: c.x + sin(angle) * radius, y: c.y - cos(angle) * radius) }
        let steps = max(4, Int(((endAngle - startAngle) * outerRadius / 3).rounded(.up)))
        var path = Path()
        path.move(to: point(startAngle, outerRadius))
        for i in 1...steps { path.addLine(to: point(startAngle + (endAngle - startAngle) * Double(i) / Double(steps), outerRadius)) }
        for i in 0...steps { path.addLine(to: point(endAngle - (endAngle - startAngle) * Double(i) / Double(steps), innerRadius)) }
        path.closeSubpath()
        return path
    }
}

/// The radial menu: a ring of slices around the pointer, the hovered one named in the hub. A click on a slice, a flick
/// toward it with the right button held, a number key or the arrow keys and Return all choose it; Esc, the hub or a click
/// outside the ring go back or close.
struct RadialMenuView: View {
    let session: RadialSession
    @Environment(\.palette) private var palette
    @Local private var shown = false

    private let gap = 0.032

    var body: some View {
        let ring = session.ring
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.14)
                .contentShape(Rectangle())
                .onTapGesture(count: 1, coordinateSpace: .local) { session.click(at: $0) }
                .onContinuousHover(coordinateSpace: .local) { phase in
                    if case .active(let point) = phase { session.pointerMoved(to: point) }
                }

            ringBody(ring)
                .frame(width: RadialGeometry.outerRadius * 2, height: RadialGeometry.outerRadius * 2)
                .scaleEffect(shown ? 1 : 0.72)
                .opacity(shown ? 1 : 0)
                .position(session.center)
                .allowsHitTesting(false)
        }
        .background(RadialInputMonitor(session: session))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Radial menu")
        .onAppear { withAnimation(Motion.spring) { shown = true } }
    }

    @ViewBuilder
    private func ringBody(_ ring: [RadialEntry]) -> some View {
        let count = ring.count
        let width = RadialGeometry.sliceAngle(count: count)
        let middle = (RadialGeometry.innerRadius + RadialGeometry.outerRadius) / 2
        ZStack {
            ForEach(Array(ring.enumerated()), id: \.element.id) { index, entry in
                let lit = session.hovered == index
                let centre = RadialGeometry.centerAngle(of: index, count: count)
                let sector = AnnularSector(startAngle: centre - width / 2 + gap / 2, endAngle: centre + width / 2 - gap / 2,
                                           innerRadius: RadialGeometry.innerRadius - 2, outerRadius: RadialGeometry.outerRadius)
                sector.fill(lit ? palette.accentFill : palette.panel)
                    .background(sector.fill(.regularMaterial))
                    .overlay(sector.stroke(palette.stroke, lineWidth: 0.8))
                    .shadow(color: palette.shadow.opacity(lit ? 0.5 : 0.25), radius: lit ? 10 : 5, y: 2)
                    .scaleEffect(lit ? 1.035 : 1)
                    .animation(Motion.quick, value: lit)
                let offset = RadialGeometry.offset(of: index, count: count, radius: middle)
                VStack(spacing: 3) {
                    // An item with no icon of its own is told apart by its name instead.
                    if let symbol = entry.symbol {
                        Image(systemName: symbol).font(.system(size: 19, weight: .semibold)).frame(height: 22)
                    }
                    // Every slice is named, so the ring can be read instead of recalled (a busier ring uses smaller type).
                    Text(Self.short(entry.title)).font(.system(size: entry.symbol == nil ? 11 : (count > 6 ? 9 : 9.5), weight: .semibold))
                        .multilineTextAlignment(.center).lineLimit(entry.symbol == nil ? 3 : 2).minimumScaleFactor(0.75)
                }
                .frame(width: count > 6 ? 62 : 72)
                .foregroundStyle(lit ? palette.onAccent : palette.text)
                .animation(Motion.quick, value: lit)
                .opacity(entry.isEnabled ? 1 : 0.35)
                .overlay(alignment: .topTrailing) {
                    if entry.isGroup { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(lit ? palette.onAccent : palette.secondary).offset(x: -8, y: 2) }
                }
                .offset(x: offset.x, y: offset.y)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(entry.title)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { session.choose(index) }
            }
            hub
        }
    }

    private var hub: some View {
        let hovered = session.hovered.flatMap { session.ring.indices.contains($0) ? session.ring[$0] : nil }
        return ZStack {
            Circle().fill(palette.panel).background(Circle().fill(.regularMaterial)).overlay(Circle().strokeBorder(palette.stroke, lineWidth: 0.8))
                .frame(width: RadialGeometry.innerRadius * 2, height: RadialGeometry.innerRadius * 2)
                .shadow(color: palette.shadow.opacity(0.3), radius: 6, y: 2)
            VStack(spacing: 2) {
                if let hovered {
                    Text(hovered.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.text)
                        .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.8)
                } else if session.depth > 0 {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .bold)).foregroundStyle(palette.secondary)
                    Text(session.levels.last?.title ?? "Back").font(.system(size: 10, weight: .medium)).foregroundStyle(palette.secondary).lineLimit(1)
                } else {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(palette.tertiary)
                }
            }
            .frame(width: RadialGeometry.innerRadius * 2 - 18)
        }
    }

    /// Slices are narrow: long titles fit better without their lead-in.
    private static func short(_ title: String) -> String {
        // "Open Link" stays whole: without its noun it would just say "Link".
        for prefix in ["Open Link in ", "Open Image in ", "Open Frame in ", "Open in "] where title.hasPrefix(prefix) && title.count > prefix.count { return String(title.dropFirst(prefix.count)) }
        return title
    }
}

/// While a ring is open: the keyboard belongs to it, and so does the right button that is still down (flick to a slice
/// and let go). Events it does not use go on to whoever they were for.
private struct RadialInputMonitor: NSViewRepresentable {
    let session: RadialSession

    func makeNSView(context: Context) -> Watcher {
        let view = Watcher()
        view.session = session
        view.install()
        return view
    }

    func updateNSView(_ view: Watcher, context: Context) { view.session = session }

    static func dismantleNSView(_ view: Watcher, coordinator: ()) { view.uninstall() }

    final class Watcher: NSView {
        weak var session: RadialSession?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown, .rightMouseDragged, .rightMouseUp, .scrollWheel]) { [weak self] event in
                guard let self, let session = self.session, let window = self.window, event.window === window else { return event }
                nonisolated(unsafe) let seen = event
                let used = MainActor.assumeIsolated { self.input(from: seen, in: window).map { session.receive($0) } ?? false }
                return used ? nil : event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        /// The event as the ring reads it; nil for events that are not its business.
        @MainActor
        private func input(from event: NSEvent, in window: NSWindow) -> RadialInput? {
            let height = window.contentView?.bounds.height ?? window.frame.height
            let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
            switch event.type {
            case .rightMouseDown: return .rightDown
            case .rightMouseDragged: return .rightDragged(point)
            case .rightMouseUp: return .rightUp(point)
            case .scrollWheel: return .scroll
            case .keyDown:
                let others = event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false
                return RadialKeyCommand.from(keyCode: event.keyCode, shift: event.modifierFlags.contains(.shift),
                                             otherModifiers: others, characters: event.charactersIgnoringModifiers).map(RadialInput.key)
            default: return nil
            }
        }
    }
}

/// What a key does while a ring is open, apart from the ring itself.
enum RadialKeyCommand: Equatable {
    case back
    case chooseHovered
    case step(Int)
    case choose(Int)

    /// `otherModifiers` is true when ⌘, ⌃ or ⌥ is down: those keys belong to the app's own shortcuts.
    static func from(keyCode: UInt16, shift: Bool, otherModifiers: Bool, characters: String?) -> RadialKeyCommand? {
        switch keyCode {
        case 53: return .back                          // esc
        case 36, 76, 49: return .chooseHovered         // return, enter, space
        case 124, 125: return .step(1)                 // right, down
        case 123, 126: return .step(-1)                // left, up
        case 48: return .step(shift ? -1 : 1)          // tab, shift-tab
        default:
            guard !otherModifiers, let digit = characters.flatMap({ Int($0) }), (1...RadialLayout.maxSlices).contains(digit) else { return nil }
            return .choose(digit - 1)
        }
    }
}
