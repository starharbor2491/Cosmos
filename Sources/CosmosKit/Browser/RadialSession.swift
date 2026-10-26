import AppKit
import CosmosCore

/// One open radial menu: the ring (and the smaller rings it opens), where it sits in the window, which slice the pointer
/// is over, and the system menu items it stands in for. It keeps the system menu alive because WebKit's items run their
/// actions through it.
@MainActor
@Observable
public final class RadialSession: Identifiable {
    public struct Level: Equatable {
        public var title: String?
        public var entries: [RadialEntry]
    }

    public let id = UUID()
    public let context: RadialContext
    /// The ring's centre in the window's own space (y down, origin at the top-left).
    public private(set) var center: CGPoint
    /// Where the pointer was when the ring opened. A ring pushed back inside the window is not centred on it, so a
    /// flick with the button held is read from here.
    public let origin: CGPoint
    public private(set) var levels: [Level]
    /// The slice the pointer is over now.
    public private(set) var hovered: Int?
    /// Set when the ring opens: it knows how to take itself off the screen.
    @ObservationIgnored var onFinish: (() -> Void)?
    /// Whether the right button that opened it is still down: letting go over a slice then picks it.
    @ObservationIgnored var buttonIsDown = true

    @ObservationIgnored private let menu: NSMenu
    @ObservationIgnored private let items: [String: NSMenuItem]
    @ObservationIgnored private let haptics: Haptics?

    init(menu: NSMenu, context: RadialContext, center: CGPoint, windowSize: CGSize, custom: [RadialAction]?, haptics: Haptics?) {
        let built = RadialMenuBuilder.entries(from: menu)
        self.menu = menu
        self.items = built.items
        self.context = context
        self.haptics = haptics
        self.origin = center
        self.center = RadialGeometry.clamp(center: center, in: windowSize)
        levels = [Level(title: nil, entries: RadialLayout.ring(entries: built.entries, context: context, custom: custom))]
    }

    public var ring: [RadialEntry] { levels.last?.entries ?? [] }
    public var isEmpty: Bool { ring.isEmpty }
    public var depth: Int { levels.count - 1 }

    /// The pointer moved to `point` (the window's space); the slice under it lights up, with a tick when it changes.
    public func pointerMoved(to point: CGPoint, flickingFromOrigin: Bool = false) {
        let from = flickingFromOrigin ? origin : center
        let relative = CGPoint(x: point.x - from.x, y: point.y - from.y)
        // With the button held a flick reaches far past the ring; a pointer just moving about only lights what it is over.
        let reach = flickingFromOrigin ? RadialGeometry.reach : RadialGeometry.outerRadius
        let now = RadialGeometry.slice(at: relative, count: ring.count, reach: reach).flatMap { ring[$0].isEnabled ? $0 : nil }
        guard now != hovered else { return }
        hovered = now
        if now != nil { haptics?.alignment() }
    }

    /// Where the pointer is relative to the ring, for callers that only have window coordinates.
    func relative(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - center.x, y: point.y - center.y) }

    /// Whether `point` is inside the hub, where a release or a click does not choose anything.
    func isInHub(_ point: CGPoint, flickingFromOrigin: Bool = false) -> Bool {
        let from = flickingFromOrigin ? origin : center
        return hypot(Double(point.x - from.x), Double(point.y - from.y)) < RadialGeometry.innerRadius
    }

    /// A click at `point` (the window's space): on a slice it chooses it, on the hub it goes back, anywhere else it is a
    /// click away from the ring and closes it.
    public func click(at point: CGPoint) {
        let relative = relative(point)
        if let index = RadialGeometry.slice(at: relative, count: ring.count, reach: RadialGeometry.outerRadius) {
            choose(index)
        } else if hypot(Double(relative.x), Double(relative.y)) < RadialGeometry.innerRadius {
            back()
        } else {
            finish()
        }
    }

    /// Picks a slice: a group opens its own ring, anything else runs and the menu closes.
    public func choose(_ index: Int) {
        guard ring.indices.contains(index), ring[index].isEnabled else { return }
        let entry = ring[index]
        if entry.isGroup {
            levels.append(Level(title: entry.title, entries: entry.children))
            hovered = nil
            haptics?.alignment()
            return
        }
        guard let item = items[entry.id], let action = item.action else { finish(); return }
        let target = item.target
        haptics?.levelChange()
        finish()
        // After the ring is gone, from the next turn of the run loop: the action may put up its own UI.
        let keep = menu
        DispatchQueue.main.async {
            NSApp.sendAction(action, to: target, from: item)
            withExtendedLifetime(keep) {}
        }
    }

    /// Back out of a smaller ring; at the first ring, closes the menu.
    public func back() {
        if levels.count > 1 {
            levels.removeLast()
            hovered = nil
        } else {
            finish()
        }
    }

    /// Chooses the slice that is lit, if any.
    public func chooseHovered() {
        if let hovered { choose(hovered) }
    }

    /// What the mouse and keyboard do to an open ring, already read out of their events (see `RadialInputMonitor`).
    /// Returns whether the event is used up; one that is not goes on to whoever it was for. Points are in the window's
    /// space, y down.
    func receive(_ input: RadialInput) -> Bool {
        switch input {
        case .rightDown:
            finish()
            return true
        case .rightDragged(let point):
            pointerMoved(to: point, flickingFromOrigin: true)
            return false
        case .rightUp(let point):
            // The button that opened the ring: let go over a slice and it is chosen; let go in the hub and the ring stays.
            guard buttonIsDown else { return false }
            buttonIsDown = false
            pointerMoved(to: point, flickingFromOrigin: true)
            if hovered != nil, !isInHub(point, flickingFromOrigin: true) { chooseHovered() }
            return false
        case .scroll:
            finish()
            return false
        case .key(let command):
            switch command {
            case .back: back()
            case .chooseHovered:
                // With nothing lit, Return and Space are not the ring's.
                guard hovered != nil else { return false }
                chooseHovered()
            case .step(let delta): step(delta)
            case .choose(let index): choose(index)
            }
            return true
        }
    }

    /// Lights the next (or previous) slice, for the keyboard.
    public func step(_ delta: Int) {
        guard !ring.isEmpty else { return }
        let enabled = ring.indices.filter { ring[$0].isEnabled }
        guard !enabled.isEmpty else { return }
        guard let current = hovered, let at = enabled.firstIndex(of: current) else {
            hovered = delta > 0 ? enabled.first : enabled.last
            haptics?.alignment()
            return
        }
        hovered = enabled[(at + delta + enabled.count) % enabled.count]
        haptics?.alignment()
    }

    public func finish() { onFinish?() }
}

/// Turns a system menu into ring entries: submenus become groups, separators and hidden items go, and WebKit's items are
/// matched to the actions the layout can name.
enum RadialMenuBuilder {
    static func entries(from menu: NSMenu) -> (entries: [RadialEntry], items: [String: NSMenuItem]) {
        var items: [String: NSMenuItem] = [:]
        var usedActions: Set<RadialAction> = []

        func build(_ list: [NSMenuItem], path: String) -> [RadialEntry] {
            var out: [RadialEntry] = []
            for (index, item) in list.enumerated() {
                guard !item.isSeparatorItem, !item.isHidden else { continue }
                let title = item.title.trimmingCharacters(in: .whitespaces)
                let pathID = "\(path)\(index)"
                if let submenu = item.submenu {
                    let children = build(submenu.items, path: pathID + ".")
                    guard !children.isEmpty else { continue }
                    out.append(RadialEntry(id: pathID, title: title.isEmpty ? "More" : title, symbol: groupSymbol(item, title: title), isEnabled: item.isEnabled, children: children))
                    continue
                }
                guard !title.isEmpty else { continue }
                var action = RadialAction.resolve(identifier: item.identifier?.rawValue, title: title)
                if let found = action, !usedActions.insert(found).inserted { action = nil }
                let id = action?.rawValue ?? pathID
                items[id] = item
                out.append(RadialEntry(id: id, action: action, title: title, symbol: action?.symbol, isEnabled: item.isEnabled))
            }
            return out
        }
        let entries = build(menu.items, path: "m")
        return (entries, items)
    }

    /// An icon for a submenu: the ones WebKit adds to text fields are known by name, any other gets a plain arrow.
    private static func groupSymbol(_ item: NSMenuItem, title: String) -> String {
        let known = ["spelling": "textformat.abc", "substitutions": "arrow.left.arrow.right", "transformations": "textformat", "font": "textformat.size",
                     "speech": "speaker.wave.2", "paragraph direction": "text.alignleft", "selection direction": "text.alignright", "services": "gearshape"]
        if let match = known.first(where: { title.lowercased().contains($0.key) }) { return match.value }
        return "chevron.right.circle"
    }
}

/// A mouse or key event, read for the ring.
enum RadialInput: Equatable {
    /// A new right click: it closes the ring.
    case rightDown
    case rightDragged(CGPoint)
    case rightUp(CGPoint)
    case scroll
    case key(RadialKeyCommand)
}
