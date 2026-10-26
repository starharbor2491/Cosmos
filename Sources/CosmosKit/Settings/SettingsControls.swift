import SwiftUI
import AppKit

// The controls Settings is built from. None of them is a system control: each is drawn here from shapes and text,
// so they take the space's colours, answer a press, tick under the finger and can be reached with the keyboard.

// MARK: - Environment

private struct HapticsKey: EnvironmentKey { static let defaultValue: Haptics? = nil }

private struct SettingTitleKey: EnvironmentKey { static let defaultValue = "" }

extension EnvironmentValues {
    /// The store's haptics, for controls that tick.
    var haptics: Haptics? {
        get { self[HapticsKey.self] }
        set { self[HapticsKey.self] = newValue }
    }

    /// The title of the row a control sits in. A control without a label of its own is named after it, so what a
    /// screen reader (or voice control) calls the control is what the row says.
    var settingTitle: String {
        get { self[SettingTitleKey.self] }
        set { self[SettingTitleKey.self] = newValue }
    }
}

// MARK: - Tap target

struct TapState {
    var hover = false
    var pressed = false
    var focused = false
}

/// What a button is, without being one: hover, press, keyboard activation (Return or Space while focused), a focus
/// ring drawn by the caller, and the accessibility traits a button has.
struct TapTarget<Content: View>: View {
    enum Feel { case tap, step, none }

    var label: String
    var enabled = true
    /// How far the control shrinks while pressed.
    var scale: CGFloat = 0.97
    var feel: Feel = .tap
    var traits: AccessibilityTraits = .isButton
    let action: () -> Void
    @ViewBuilder let content: (TapState) -> Content

    @Local private var hover = false
    @Local private var pressed = false
    @FocusState private var focused: Bool
    @Environment(\.haptics) private var haptics

    var body: some View {
        content(TapState(hover: hover && enabled, pressed: pressed && enabled, focused: focused))
            .scaleEffect(pressed && enabled ? scale : 1)
            .animation(Motion.quick, value: pressed)
            .opacity(enabled ? 1 : 0.4)
            // However small it is drawn, a control can be hit anywhere in a 28 pt square.
            .frame(minWidth: Metrics.Height.button, minHeight: Metrics.Height.button)
            .contentShape(Rectangle())
            .background(PressMonitor { pressed = $0 })
            .onHover { hover = $0 }
            .onTapGesture { activate() }
            .focusable(enabled)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.return) { activate(); return .handled }
            .onKeyPress(.space) { activate(); return .handled }
            .disabled(!enabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(traits)
            .accessibilityAction { activate() }
    }

    private func activate() {
        guard enabled else { return }
        switch feel {
        case .tap: haptics?.generic()
        case .step: haptics?.alignment()
        case .none: break
        }
        action()
    }
}

/// Whether the last thing the user did was press a key. A focus ring that appears on its own (the window handing focus
/// to its first control) is noise; one that follows Tab is a map.
@MainActor
@Observable
final class InputMode {
    static let shared = InputMode()
    private(set) var keyboard = false

    private init() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            let isKey = event.type == .keyDown
            MainActor.assumeIsolated { self?.keyboard = isKey }
            return event
        }
    }
}

extension View {
    /// The ring that shows keyboard focus (only while the keyboard is what the user is using).
    func focusRing(_ focused: Bool, radius: CGFloat, palette: Palette) -> some View {
        let visible = focused && InputMode.shared.keyboard
        return overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(palette.accent, lineWidth: 2).opacity(visible ? 0.9 : 0).padding(-2))
    }
}

// MARK: - Switch

struct SwitchControl: View {
    @Binding var isOn: Bool
    var label: String?
    @Environment(\.palette) private var palette
    @Environment(\.settingTitle) private var rowTitle

    var body: some View {
        TapTarget(label: label ?? rowTitle, scale: 1, feel: .step, traits: .isToggle, action: { isOn.toggle() }) { state in
            let width = Metrics.Control.switchWidth, height = Metrics.Control.switchHeight, knob = Metrics.Control.knob
            let knobWidth = state.pressed ? knob + 4 : knob
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? palette.accentFill : palette.text.opacity(0.2))
                Capsule().strokeBorder(palette.stroke, lineWidth: 0.5)
                Capsule().fill(isOn ? palette.onAccent : .white)
                    .frame(width: knobWidth, height: knob)
                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                    .padding(3)
            }
            .frame(width: width, height: height)
            .animation(Motion.spring, value: isOn)
            .animation(Motion.quick, value: state.pressed)
            .brightness(state.hover ? 0.05 : 0)
            .focusRing(state.focused, radius: height / 2, palette: palette)
        }
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: - Check box

struct CheckControl: View {
    @Binding var isOn: Bool
    var label: String?
    @Environment(\.palette) private var palette
    @Environment(\.settingTitle) private var rowTitle

    var body: some View {
        TapTarget(label: label ?? rowTitle, scale: 0.9, feel: .step, traits: .isToggle, action: { isOn.toggle() }) { state in
            let shape = RoundedRectangle(cornerRadius: Metrics.Radius.chip, style: .continuous)
            ZStack {
                shape.fill(isOn ? palette.accentFill : (state.hover ? palette.hoverStrong : palette.hover))
                shape.strokeBorder(isOn ? .clear : palette.faint, lineWidth: 1)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(palette.onAccent)
                    .scaleEffect(isOn ? 1 : 0.4).opacity(isOn ? 1 : 0)
            }
            .frame(width: Metrics.Control.check, height: Metrics.Control.check)
            .animation(Motion.spring, value: isOn)
            .focusRing(state.focused, radius: Metrics.Radius.chip, palette: palette)
        }
        .accessibilityValue(isOn ? "Checked" : "Unchecked")
    }
}

// MARK: - Options

struct Option<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var symbol: String?
    var id: Value { value }
}

/// A few choices side by side; the highlight glides from the old one to the new one.
struct SegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Option<Value>]
    @Namespace private var glide
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = option.value == selection
                TapTarget(label: option.label, scale: 0.96, feel: .step, traits: .isButton, action: { selection = option.value }) { state in
                    HStack(spacing: 6) {
                        if let symbol = option.symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                        Text(option.label).font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(selected ? palette.text : palette.secondary)
                    .padding(.horizontal, Metrics.Space.l)
                    .frame(height: Metrics.Height.button)
                    .frame(maxWidth: .infinity)
                    .background {
                        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
                        if selected {
                            shape.fill(palette.selected).shadow(color: palette.shadow.opacity(0.3), radius: 3, y: 1)
                                .overlay(shape.strokeBorder(palette.stroke, lineWidth: 0.8))
                                .matchedGeometryEffect(id: "segment", in: glide)
                        } else if state.hover {
                            shape.fill(palette.hover)
                        }
                    }
                    .focusRing(state.focused, radius: Metrics.Radius.control, palette: palette)
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(Metrics.Space.hair)
        .background(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).fill(palette.hover))
        .animation(Motion.standard, value: selection)
    }
}

/// A choice from a longer list. The list opens in place, under the field, instead of in a system menu. While it is open
/// the arrow keys move through it, Return or Space picks, Esc closes it, and so does a click anywhere else.
struct Dropdown<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Option<Value>]
    var label: String?
    var width: CGFloat = 232
    @Local private var open = false
    @Local private var highlight: Int?
    @Environment(\.palette) private var palette
    @Environment(\.haptics) private var haptics
    @Environment(\.settingTitle) private var rowTitle

    private var selectedLabel: String { options.first { $0.value == selection }?.label ?? "" }
    private var selectedIndex: Int? { options.firstIndex { $0.value == selection } }

    private func setOpen(_ on: Bool) {
        highlight = on ? selectedIndex : nil
        withAnimation(Motion.standard) { open = on }
    }

    private func choose(_ index: Int) {
        guard options.indices.contains(index) else { return }
        selection = options[index].value
        setOpen(false)
    }

    private func move(_ delta: Int) {
        guard !options.isEmpty else { return }
        guard open else { setOpen(true); return }
        let next = min(max((highlight ?? selectedIndex ?? 0) + delta, 0), options.count - 1)
        if next != highlight { haptics?.alignment() }
        highlight = next
    }

    /// Keys while the list is open; returns whether the key was used up.
    private func handle(_ key: ListKey) -> Bool {
        switch key {
        case .down: move(1); return true
        case .up: move(-1); return true
        case .escape: setOpen(false); return true
        case .commit:
            if let highlight { choose(highlight) } else { setOpen(false) }
            return true
        case .leave: setOpen(false); return false
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: Metrics.Space.xs) {
            TapTarget(label: label ?? rowTitle, scale: 0.985, feel: .step, action: { setOpen(!open) }) { state in
                HStack(spacing: Metrics.Space.s) {
                    Text(selectedLabel).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(palette.tertiary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .foregroundStyle(palette.text)
                .padding(.horizontal, Metrics.Space.m)
                .frame(width: width, height: Metrics.Control.height)
                .background(RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous).fill(state.hover || open ? palette.hoverStrong : palette.hover))
                .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous).strokeBorder(open ? palette.accent.opacity(0.8) : palette.stroke, lineWidth: open ? 1.2 : 0.8))
                .focusRing(state.focused, radius: Metrics.Radius.control, palette: palette)
            }
            .accessibilityValue("\(selectedLabel), \(open ? "expanded" : "collapsed")")

            if open {
                VStack(spacing: 2) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        let selected = option.value == selection
                        TapTarget(label: option.label, scale: 0.985, feel: .step, action: { choose(index) }) { state in
                            HStack {
                                Text(option.label).font(.system(size: 13, weight: selected ? .semibold : .medium)).lineLimit(1)
                                Spacer(minLength: 0)
                                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(palette.accentText) }
                            }
                            .foregroundStyle(palette.text)
                            .padding(.horizontal, Metrics.Space.m)
                            .frame(height: Metrics.Height.button)
                            .background(RoundedRectangle(cornerRadius: Metrics.Radius.chip, style: .continuous).fill(state.hover || highlight == index ? palette.hoverStrong : .clear))
                            .focusRing(state.focused, radius: Metrics.Radius.chip, palette: palette)
                        }
                        .onHover { if $0 { highlight = index } }
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(Metrics.Space.xs)
                .frame(width: width)
                .background(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).fill(palette.hover))
                .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).strokeBorder(palette.stroke, lineWidth: 0.8))
                .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
        }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .background(OpenListMonitor(active: open, onOutsideClick: { setOpen(false) }, onKey: handle))
    }
}

/// The keys an open list answers to.
enum ListKey { case up, down, escape, commit, leave }

/// While `active`, watches the mouse and keyboard for a list that is open: a click outside its frame closes it (and
/// still reaches whatever was clicked), and its keys are taken before anything else sees them. It sits behind the
/// list's own views, so its frame is the list's frame.
private struct OpenListMonitor: NSViewRepresentable {
    let active: Bool
    let onOutsideClick: () -> Void
    let onKey: (ListKey) -> Bool

    func makeNSView(context: Context) -> Watcher { Watcher() }

    func updateNSView(_ view: Watcher, context: Context) {
        view.onOutsideClick = onOutsideClick
        view.onKey = onKey
        view.setActive(active)
    }

    final class Watcher: NSView {
        var onOutsideClick: (() -> Void)?
        var onKey: ((ListKey) -> Bool)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func setActive(_ on: Bool) {
            if on, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                    guard let self, let window = self.window, event.window === window else { return event }
                    if event.type == .keyDown {
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
                    if !self.convert(self.bounds, to: nil).contains(event.locationInWindow) { self.onOutsideClick?() }
                    return event
                }
            } else if !on, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

// MARK: - Buttons

struct ActionButton: View {
    enum Kind { case primary, secondary, destructive, quiet }

    let title: String
    var symbol: String?
    var kind: Kind = .secondary
    var enabled = true
    /// Shows the orbit spinner instead of the icon and ignores taps.
    var busy = false
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        TapTarget(label: title, enabled: enabled && !busy, scale: 0.96, action: action) { state in
            let shape = RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
            HStack(spacing: 6) {
                if busy { OrbitSpinner(size: 13, color: foreground) }
                else if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .quiet ? Metrics.Space.s : Metrics.Space.l)
            .frame(height: Metrics.Control.height)
            .background(shape.fill(fill(state)))
            .overlay(shape.strokeBorder(kind == .secondary ? palette.stroke : .clear, lineWidth: 0.8))
            .focusRing(state.focused, radius: Metrics.Radius.control, palette: palette)
            .animation(Motion.quick, value: state.hover)
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: palette.onAccent
        case .destructive: palette.negative
        case .secondary: palette.text
        case .quiet: palette.accentText
        }
    }

    private func fill(_ state: TapState) -> Color {
        switch kind {
        case .primary: return palette.accentFill.opacity(state.hover ? 1 : 0.92)
        case .destructive: return palette.negative.opacity(state.hover ? 0.22 : 0.12)
        case .secondary: return state.hover ? palette.hoverStrong : palette.hover
        case .quiet: return state.hover ? palette.accent.opacity(0.14) : .clear
        }
    }
}

/// A small round icon button (remove, close).
struct IconButton: View {
    let symbol: String
    let label: String
    var destructive = false
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        TapTarget(label: label, scale: 0.88, action: action) { state in
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(state.hover ? (destructive ? palette.negative : palette.text) : palette.secondary)
                .frame(width: Metrics.Height.button, height: Metrics.Height.button)
                .background(Circle().fill(state.hover ? palette.hoverStrong : .clear))
                .focusRing(state.focused, radius: Metrics.Height.button / 2, palette: palette)
                .animation(Motion.quick, value: state.hover)
        }
    }
}

// MARK: - Text input

/// A one-line text field: a borderless AppKit field inside a rounded well that lights up when it has focus.
struct FieldInput: View {
    @Binding var text: String
    var placeholder: String
    var width: CGFloat?
    var onSubmit: () -> Void = {}
    @Local private var focused = false
    @Environment(\.palette) private var palette

    var body: some View {
        NativeField(text: $text, placeholder: placeholder, focused: $focused, onSubmit: onSubmit,
                    textColor: NSColor(palette.text), placeholderColor: NSColor(palette.tertiary), caretColor: NSColor(palette.accent))
            .frame(height: 20)
            .padding(.horizontal, Metrics.Space.m)
            .frame(width: width, height: Metrics.Control.height)
            .background(RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous).fill(palette.hover))
            .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
                .strokeBorder(focused ? palette.accent.opacity(0.9) : palette.stroke, lineWidth: focused ? 1.5 : 0.8))
            .animation(Motion.quick, value: focused)
            .accessibilityLabel(placeholder)
    }
}

private struct NativeField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @Binding var focused: Bool
    let onSubmit: () -> Void
    let textColor: NSColor
    let placeholderColor: NSColor
    let caretColor: NSColor

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 13.5)
        f.cell?.usesSingleLineMode = true
        f.cell?.isScrollable = true
        f.lineBreakMode = .byClipping
        f.delegate = context.coordinator
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
        f.textColor = textColor
        f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: placeholderColor, .font: NSFont.systemFont(ofSize: 13.5)])
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeField
        init(_ parent: NativeField) { self.parent = parent }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.focused = true
            ((obj.object as? NSTextField)?.currentEditor() as? NSTextView)?.insertionPointColor = parent.caretColor
        }
        func controlTextDidEndEditing(_ obj: Notification) { parent.focused = false }
        func controlTextDidChange(_ obj: Notification) {
            if let f = obj.object as? NSTextField { parent.text = f.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            return true
        }
    }
}

// MARK: - Layout

/// How solid each end of a scrolling pane is: 1 when the end is in view, fading to 0 over `fade` points as more content
/// lies past it. A pane has no scroll bar, so its edges dissolving is what says there is more.
struct ScrollEdges: Equatable {
    var top: Double
    var bottom: Double

    init(offset: CGFloat, contentHeight: CGFloat, viewport: CGFloat, fade: CGFloat = 28) {
        let above = max(0, offset)
        let below = max(0, contentHeight - offset - viewport)
        top = Double(1 - min(1, above / fade))
        bottom = Double(1 - min(1, below / fade))
    }
}

private struct PaneScrollKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// A pane: a title, what it is for, and its groups, scrolling as one column.
struct Pane<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder let content: () -> Content
    @Environment(\.palette) private var palette
    @Local private var edges = ScrollEdges(offset: 0, contentHeight: 0, viewport: 0)

    var body: some View {
        GeometryReader { viewport in
            scrolling
                .coordinateSpace(name: "pane.scroll")
                .onPreferenceChange(PaneScrollKey.self) { frame in
                    MainActor.assumeIsolated { edges = ScrollEdges(offset: -frame.minY, contentHeight: frame.height, viewport: viewport.size.height) }
                }
                .mask(
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(edges.top), .black], startPoint: .top, endPoint: .bottom).frame(height: 28)
                        Color.black
                        LinearGradient(colors: [.black, .black.opacity(edges.bottom)], startPoint: .top, endPoint: .bottom).frame(height: 28)
                    }
                )
        }
    }

    private var scrolling: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Metrics.Space.xl) {
                HStack(spacing: Metrics.Space.m) {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).fill(palette.accent.opacity(0.16)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(palette.text)
                        Text(subtitle).font(.system(size: 12.5)).foregroundStyle(palette.secondary)
                    }
                    Spacer(minLength: 0)
                }
                content()
            }
            .padding(.horizontal, Metrics.Space.xl + Metrics.Space.xs)
            .padding(.top, Metrics.Space.xl + Metrics.Space.xs)
            .padding(.bottom, Metrics.Space.xl + Metrics.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { g in Color.clear.preference(key: PaneScrollKey.self, value: g.frame(in: .named("pane.scroll"))) })
        }
    }
}

/// A titled card of rows, with an optional note underneath.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var note: String?
    @ViewBuilder let content: () -> Content
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            if let title {
                Text(title)
                    .font(.system(size: 10.5, weight: .bold, design: .rounded)).tracking(0.8).textCase(.uppercase)
                    .foregroundStyle(palette.tertiary)
                    .padding(.horizontal, Metrics.Space.xs)
            }
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous).fill(palette.hover))
                .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous).strokeBorder(palette.stroke, lineWidth: 0.8))
            if let note {
                Text(note)
                    .font(.system(size: 11.5)).foregroundStyle(palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metrics.Space.xs)
            }
        }
    }
}

extension View {
    /// The inset of anything custom inside a settings card (a field, a button row): the same 16 pt from the edge as
    /// the text of the rows above and below it.
    func cardInset() -> some View { padding(.horizontal, Metrics.Space.l).padding(.vertical, Metrics.Space.m) }
}

struct Hairline: View {
    @Environment(\.palette) private var palette
    var body: some View { Rectangle().fill(palette.stroke).frame(height: 0.5).padding(.leading, Metrics.Space.l) }
}

/// One setting: what it is on the left, its control on the right.
struct SettingRow<Trailing: View>: View {
    let title: String
    var detail: String?
    var symbol: String?
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.Space.m) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(palette.secondary).frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(palette.text)
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Metrics.Space.m)
            trailing().environment(\.settingTitle, title)
        }
        .padding(.horizontal, Metrics.Space.l)
        .padding(.vertical, Metrics.Space.m)
    }
}

/// Rows of items with hairlines between them.
struct DividedRows<Item, ID: Hashable, Row: View>: View {
    let items: [Item]
    let id: KeyPath<Item, ID>
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items, id: id) { item in
                row(item)
                if items.last.map({ $0[keyPath: id] != item[keyPath: id] }) ?? false { Hairline() }
            }
        }
    }
}

extension DividedRows where Item: Identifiable, ID == Item.ID {
    init(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) {
        self.init(items: items, id: \.id, row: row)
    }
}
