import SwiftUI
import AppKit

// A Settings dropdown opens its list here instead of in place. The list belongs to the window, so the scrolling pane
// can't clip it and the rows below the field can't draw over it, and opening one never moves anything else.

/// The keys an open list answers to.
enum ListKey { case up, down, escape, commit, leave }

/// Where a list goes, relative to the field that opened it.
enum DropdownPlacement {
    static let rowGap: CGFloat = 2

    /// The list's height for `rows` rows.
    static func height(rows: Int) -> CGFloat {
        CGFloat(rows) * Metrics.Height.button + CGFloat(max(rows - 1, 0)) * rowGap + 2 * Metrics.Space.xs
    }

    /// The list's top-left: under the field with its right edge, above it when the window has no room below, and
    /// inside `bounds` whatever happens.
    static func origin(anchor: CGRect, size: CGSize, bounds: CGRect, gap: CGFloat = Metrics.Space.xs, margin: CGFloat = Metrics.Space.m) -> CGPoint {
        let inner = bounds.insetBy(dx: margin, dy: margin)
        let x = min(max(anchor.maxX - size.width, inner.minX), max(inner.minX, inner.maxX - size.width))
        let below = anchor.maxY + gap
        let above = anchor.minY - gap - size.height
        let y: CGFloat
        if below + size.height <= inner.maxY { y = below }
        else if above >= inner.minY { y = above }
        else { y = min(max(below, inner.minY), max(inner.minY, inner.maxY - size.height)) }
        return CGPoint(x: x, y: y)
    }
}

/// The one list that can be open in a Settings window, and the keys that drive it.
@MainActor
@Observable
final class DropdownHost {
    struct Presented {
        var id: UUID
        var labels: [String]
        var selected: Int?
        var width: CGFloat
        var choose: (Int) -> Void
    }

    private(set) var presented: Presented?
    var highlight: Int?
    private(set) var frames: [UUID: CGRect] = [:]
    @ObservationIgnored private var openers: [UUID: () -> Void] = [:]
    @ObservationIgnored var haptics: Haptics?

    func isOpen(_ id: UUID) -> Bool { presented?.id == id }

    func present(_ list: Presented) {
        highlight = list.selected
        withAnimation(Motion.standard) { presented = list }
    }

    func close() {
        guard presented != nil else { return }
        highlight = nil
        withAnimation(Motion.standard) { presented = nil }
    }

    func close(ifOpen id: UUID) {
        if isOpen(id) { close() }
    }

    func setFrames(_ new: [UUID: CGRect]) { frames = new }

    // Fields tell the host how to open them so a script can open one by position.
    func register(_ id: UUID, open: @escaping () -> Void) { openers[id] = open }
    func unregister(_ id: UUID) { openers[id] = nil }

    /// Opens the `index`th registered field, counting top to bottom. Used by the automation script.
    func openRegistered(at index: Int) {
        let ordered = openers.keys.sorted { (frames[$0]?.minY ?? 0, frames[$0]?.minX ?? 0) < (frames[$1]?.minY ?? 0, frames[$1]?.minX ?? 0) }
        guard ordered.indices.contains(index) else { return }
        openers[ordered[index]]?()
    }

    func move(_ delta: Int) {
        guard let presented, !presented.labels.isEmpty else { return }
        let next = min(max((highlight ?? presented.selected ?? 0) + delta, 0), presented.labels.count - 1)
        if next != highlight { haptics?.alignment() }
        highlight = next
    }

    func choose(_ index: Int) {
        guard let presented, presented.labels.indices.contains(index) else { return }
        presented.choose(index)
        close()
    }

    /// A key while a list is open; returns whether the key was used up. With nothing open every key is left alone.
    func handle(_ key: ListKey) -> Bool {
        guard presented != nil else { return false }
        switch key {
        case .down: move(1); return true
        case .up: move(-1); return true
        case .escape: close(); return true
        case .commit:
            if let highlight { choose(highlight) } else { close() }
            return true
        case .leave: close(); return false
        }
    }
}

private struct DropdownHostKey: EnvironmentKey { static let defaultValue: DropdownHost? = nil }

extension EnvironmentValues {
    var dropdownHost: DropdownHost? {
        get { self[DropdownHostKey.self] }
        set { self[DropdownHostKey.self] = newValue }
    }
}

/// Each field reports where it is, in the Settings window's own coordinates.
struct DropdownFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// The open list, drawn over the whole Settings window. A click outside it closes it, as does scrolling and Esc.
struct DropdownLayer: View {
    let host: DropdownHost
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { window in
            if let list = host.presented, let anchor = host.frames[list.id] {
                let natural = DropdownPlacement.height(rows: list.labels.count)
                let height = min(natural, window.size.height - 2 * Metrics.Space.m)
                let size = CGSize(width: list.width, height: height)
                let origin = DropdownPlacement.origin(anchor: anchor, size: size, bounds: CGRect(origin: .zero, size: window.size))
                let flipped = origin.y < anchor.minY
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { host.close() }
                        .accessibilityHidden(true)
                    rows(list, scrolls: natural > height)
                        .frame(width: size.width, height: size.height)
                        .background(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).fill(.regularMaterial))
                        .background(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).fill(palette.panel))
                        .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).strokeBorder(palette.stroke, lineWidth: 0.8))
                        .shadow(color: palette.shadow.opacity(0.5), radius: 14, y: 6)
                        .offset(x: origin.x, y: origin.y)
                        .transition(.scale(scale: 0.96, anchor: flipped ? .bottomTrailing : .topTrailing).combined(with: .opacity))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Only here while the list is, so the monitor is too. A list that scrolls itself keeps the wheel.
                .background(ListKeyMonitor(active: true, onKey: host.handle, onScroll: { if natural <= height { host.close() } }))
            }
        }
    }

    private func rows(_ list: DropdownHost.Presented, scrolls: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: DropdownPlacement.rowGap) {
                    ForEach(Array(list.labels.enumerated()), id: \.offset) { index, label in
                        let selected = index == list.selected
                        TapTarget(label: label, scale: 0.985, feel: .step, action: { host.choose(index) }) { state in
                            HStack {
                                Text(label).font(.system(size: 13, weight: selected ? .semibold : .medium)).lineLimit(1)
                                Spacer(minLength: 0)
                                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(palette.accentText) }
                            }
                            .foregroundStyle(palette.text)
                            .padding(.horizontal, Metrics.Space.m)
                            .frame(height: Metrics.Height.button)
                            .background(RoundedRectangle(cornerRadius: Metrics.Radius.chip, style: .continuous).fill(state.hover || host.highlight == index ? palette.hoverStrong : .clear))
                            .focusRing(state.focused, radius: Metrics.Radius.chip, palette: palette)
                        }
                        .onHover { if $0 { host.highlight = index } }
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .id(index)
                    }
                }
                .padding(Metrics.Space.xs)
            }
            .scrollDisabled(!scrolls)
            .onChange(of: host.highlight) { _, new in
                if scrolls, let new { proxy.scrollTo(new) }
            }
        }
    }
}

/// While `active`, takes the keys an open list answers to before anything else sees them, and closes the list when the
/// pane behind it scrolls. Clicks are not watched here: the layer's own backdrop catches those.
private struct ListKeyMonitor: NSViewRepresentable {
    let active: Bool
    let onKey: (ListKey) -> Bool
    let onScroll: () -> Void

    func makeNSView(context: Context) -> Watcher { Watcher() }

    func updateNSView(_ view: Watcher, context: Context) {
        view.onKey = onKey
        view.onScroll = onScroll
        view.setActive(active)
    }

    final class Watcher: NSView {
        var onKey: ((ListKey) -> Bool)?
        var onScroll: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func setActive(_ on: Bool) {
            if on, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
                    guard let self, let window = self.window, event.window === window else { return event }
                    if event.type == .scrollWheel {
                        // The list floats over the pane, so a scroll that reaches the pane would leave it behind.
                        if abs(event.scrollingDeltaY) > 0 { self.onScroll?() }
                        return event
                    }
                    let key: ListKey? = switch event.keyCode {
                    case 125: .down
                    case 126: .up
                    case 53: .escape
                    case 36, 76, 49: .commit
                    case 48: .leave
                    default: nil
                    }
                    guard let key else { return event }
                    return self.onKey?(key) == true ? nil : event
                }
            } else if !on, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
