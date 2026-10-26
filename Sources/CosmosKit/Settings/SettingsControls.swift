import SwiftUI
import AppKit

// The controls Settings is built from. None of them is a system control: each is drawn here from shapes and text,
// so they take the space's colours, answer a press, tick under the finger and can be reached with the keyboard.

// MARK: - Environment

private struct HapticsKey: EnvironmentKey { static let defaultValue: Haptics? = nil }

extension EnvironmentValues {
    /// The store's haptics, for controls that tick.
    var haptics: Haptics? {
        get { self[HapticsKey.self] }
        set { self[HapticsKey.self] = newValue }
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
            .contentShape(Rectangle())
            .background(PressMonitor { pressed = $0 })
            .onHover { hover = $0 }
            .onTapGesture { activate() }
            .focusable(enabled)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.return) { activate(); return .handled }
            .onKeyPress(.space) { activate(); return .handled }
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
    var label: String
    @Environment(\.palette) private var palette

    var body: some View {
        TapTarget(label: label, scale: 1, feel: .step, traits: .isToggle, action: { isOn.toggle() }) { state in
            let width: CGFloat = 42, height: CGFloat = 24, knob: CGFloat = 18
            let knobWidth = state.pressed ? knob + 4 : knob
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? palette.accent : palette.text.opacity(0.2))
                Capsule().strokeBorder(palette.stroke, lineWidth: 0.5)
                Capsule().fill(.white)
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
    var label: String
    @Environment(\.palette) private var palette

    var body: some View {
        TapTarget(label: label, scale: 0.9, feel: .step, traits: .isToggle, action: { isOn.toggle() }) { state in
            let shape = RoundedRectangle(cornerRadius: Metrics.Radius.chip - 1, style: .continuous)
            ZStack {
                shape.fill(isOn ? palette.accent : (state.hover ? palette.hover.opacity(1.8) : palette.hover))
                shape.strokeBorder(isOn ? .clear : palette.tertiary, lineWidth: 1)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                    .scaleEffect(isOn ? 1 : 0.4).opacity(isOn ? 1 : 0)
            }
            .frame(width: 20, height: 20)
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
                    .padding(.horizontal, 14)
                    .frame(height: 28)
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
        .padding(3)
        .background(RoundedRectangle(cornerRadius: Metrics.Radius.control + 3, style: .continuous).fill(palette.hover))
        .animation(Motion.standard, value: selection)
    }
}

/// A choice from a longer list. The list opens in place, under the field, instead of in a system menu.
struct Dropdown<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Option<Value>]
    var label: String
    var width: CGFloat = 232
    @Local private var open = false
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .trailing, spacing: Metrics.Space.xs) {
            TapTarget(label: label, scale: 0.985, feel: .step, action: { withAnimation(Motion.standard) { open.toggle() } }) { state in
                HStack(spacing: Metrics.Space.s) {
                    Text(options.first { $0.value == selection }?.label ?? "").font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(palette.tertiary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .foregroundStyle(palette.text)
                .padding(.horizontal, Metrics.Space.m)
                .frame(width: width, height: 34)
                .background(RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous).fill(state.hover || open ? palette.hover.opacity(1.8) : palette.hover))
                .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous).strokeBorder(open ? palette.accent.opacity(0.8) : palette.stroke, lineWidth: open ? 1.2 : 0.8))
                .focusRing(state.focused, radius: Metrics.Radius.control, palette: palette)
            }
            .accessibilityValue(options.first { $0.value == selection }?.label ?? "")

            if open {
                VStack(spacing: 2) {
                    ForEach(options) { option in
                        let selected = option.value == selection
                        TapTarget(label: option.label, scale: 0.985, feel: .step, action: {
                            selection = option.value
                            withAnimation(Motion.standard) { open = false }
                        }) { state in
                            HStack {
                                Text(option.label).font(.system(size: 13, weight: selected ? .semibold : .medium)).lineLimit(1)
                                Spacer(minLength: 0)
                                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(palette.accent) }
                            }
                            .foregroundStyle(palette.text)
                            .padding(.horizontal, Metrics.Space.s + 2)
                            .frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: Metrics.Radius.chip + 1, style: .continuous).fill(state.hover ? palette.hover.opacity(1.8) : .clear))
                            .focusRing(state.focused, radius: Metrics.Radius.chip, palette: palette)
                        }
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(4)
                .frame(width: width)
                .background(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).fill(palette.hover))
                .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).strokeBorder(palette.stroke, lineWidth: 0.8))
                .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
        }
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
            .padding(.horizontal, kind == .quiet ? Metrics.Space.s : Metrics.Space.m + 2)
            .frame(height: 32)
            .background(shape.fill(fill(state)))
            .overlay(shape.strokeBorder(kind == .secondary ? palette.stroke : .clear, lineWidth: 0.8))
            .focusRing(state.focused, radius: Metrics.Radius.control, palette: palette)
            .animation(Motion.quick, value: state.hover)
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .destructive: Color(red: 1, green: 0.42, blue: 0.40)
        case .secondary: palette.text
        case .quiet: palette.accent
        }
    }

    private func fill(_ state: TapState) -> Color {
        switch kind {
        case .primary: return palette.accent.opacity(state.hover ? 1 : 0.9)
        case .destructive: return Color(red: 1, green: 0.35, blue: 0.33).opacity(state.hover ? 0.28 : 0.16)
        case .secondary: return state.hover ? palette.hover.opacity(1.8) : palette.hover
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
                .foregroundStyle(state.hover ? (destructive ? Color(red: 1, green: 0.42, blue: 0.40) : palette.text) : palette.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(state.hover ? palette.hover.opacity(1.8) : .clear))
                .focusRing(state.focused, radius: 13, palette: palette)
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
            .frame(width: width, height: 36)
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

/// A pane: a title, what it is for, and its groups, scrolling as one column.
struct Pane<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder let content: () -> Content
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Metrics.Space.l + Metrics.Space.s) {
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
            trailing()
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
