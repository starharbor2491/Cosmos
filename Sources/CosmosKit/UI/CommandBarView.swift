import SwiftUI
import AppKit
import CosmosCore

/// The Command Bar: one field that opens URLs, searches, switches tabs and runs commands.
struct CommandBarView: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette
    @Local private var modelBox: ModelBox?
    @Namespace private var highlightNamespace

    final class ModelBox {
        let model: CommandBarModel
        init(_ m: CommandBarModel) { model = m }
    }

    var body: some View {
        let model = modelBox?.model
        VStack(spacing: 0) {
            if let model { content(model) }
        }
        .frame(width: 640)
        .onAppear { if modelBox == nil, case .commandBar(let mode)? = window.overlay { modelBox = ModelBox(CommandBarModel(store: store, window: window, mode: mode)) } }
    }

    @ViewBuilder
    private func content(_ model: CommandBarModel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let site = model.site {
                    HStack(spacing: 6) {
                        FaviconView(store: store, url: URL(string: "https://\(site.domain)"), size: 15)
                        Text(site.name).font(.system(size: 13, weight: .semibold))
                        Button { _ = model.backspaceOnEmpty() } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                            .buttonStyle(.plain)
                    }
                    .foregroundStyle(palette.text)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(palette.accent.opacity(0.28)))
                    .overlay(Capsule().strokeBorder(palette.accent.opacity(0.5), lineWidth: 0.5))
                } else {
                    Image(systemName: model.mode == .newTab ? "plus.magnifyingglass" : "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(palette.secondary)
                }
                CommandField(model: model, window: window, textColor: palette.isDark ? .white : NSColor(red: 0.08, green: 0.07, blue: 0.14, alpha: 1),
                             placeholderColor: palette.isDark ? NSColor.white.withAlphaComponent(0.4) : NSColor.black.withAlphaComponent(0.36))
                    .frame(height: 28)
                if model.tabHint != nil, model.site == nil {
                    HStack(spacing: 5) {
                        Text("Tab").font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: Metrics.Radius.chip, style: .continuous).fill(palette.hover.opacity(1.8)))
                        Text("to search \(model.tabHint?.name ?? "")").font(.system(size: 12))
                    }
                    .foregroundStyle(palette.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)

            if !model.rows.isEmpty {
                Rectangle().fill(palette.stroke).frame(height: 0.5)
                VStack(spacing: 2) {
                    if model.text.trimmingCharacters(in: .whitespaces).isEmpty, model.site == nil {
                        SectionLabel(text: "Jump back in")
                    }
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        CommandRow(store: store, row: row, selected: index == model.selected, query: model.text, namespace: highlightNamespace)
                            .contentShape(Rectangle())
                            .onTapGesture { model.activate(row, newTabOverride: NSEvent.modifierFlags.contains(.command)) }
                            .onHover { inside in if inside, model.selected != index, NSEvent.pressedMouseButtons == 0 { model.selected = index } }
                    }
                }
                .padding(8)
                .animation(Motion.quick, value: model.selected)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.Radius.panel, style: .continuous))
        .background(RoundedRectangle(cornerRadius: Metrics.Radius.panel, style: .continuous).fill(palette.panel))
        .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.panel, style: .continuous).strokeBorder(palette.stroke, lineWidth: 0.8))
        .shadow(color: palette.shadow, radius: 36, y: 14)
        .animation(.easeOut(duration: 0.12), value: model.rows.count)
    }

    struct SectionLabel: View {
        let text: String
        @Environment(\.palette) private var palette
        var body: some View {
            Text(text.uppercased())
                .font(.system(size: 10.5, weight: .bold)).tracking(0.8)
                .foregroundStyle(palette.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
        }
    }
}

private struct CommandRow: View {
    let store: BrowserStore
    let row: CommandCandidate
    let selected: Bool
    let query: String
    /// The highlight is one shape shared by all rows, so it glides to the row you move to.
    let namespace: Namespace.ID
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 11) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(palette.text)
                    .lineLimit(1).truncationMode(.tail)
                if let sub = row.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let hint {
                Text(hint)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(selected ? palette.text : palette.tertiary)
            }
            if selected {
                Image(systemName: "return").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
                    .fill(palette.accent.opacity(palette.isDark ? 0.34 : 0.22))
                    .matchedGeometryEffect(id: "command.selection", in: namespace)
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch row.kind {
        case .openTab, .sidebarItem, .archived, .history, .topDomain, .typedURL:
            FaviconView(store: store, url: row.url, size: 20)
        case .command, .space, .calculation, .webSearch, .suggestion, .siteSearch:
            Image(systemName: row.symbol ?? "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: Metrics.Radius.chip, style: .continuous).fill(palette.accent.opacity(0.16)))
        }
    }

    private var hint: String? {
        switch row.kind {
        case .openTab: return "Switch to Tab"
        case .sidebarItem: return "Open"
        case .archived: return "Restore"
        case .command: return "Command"
        case .space: return "Space"
        case .calculation: return "Copy"
        case .typedURL: return "Go"
        default: return nil
        }
    }
}

// MARK: - Text field

/// A borderless NSTextField that reports arrow / return / tab / escape to the model and shows inline completion.
struct CommandField: NSViewRepresentable {
    let model: CommandBarModel
    let window: WindowState
    let textColor: NSColor
    let placeholderColor: NSColor

    func makeCoordinator() -> Coordinator { Coordinator(model: model, window: window) }

    func makeNSView(context: Context) -> KeyField {
        let f = KeyField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 19, weight: .regular)
        f.textColor = textColor
        f.cell?.usesSingleLineMode = true
        f.cell?.isScrollable = true
        f.lineBreakMode = .byClipping
        f.delegate = context.coordinator
        f.onCommandReturn = { [weak model] in model?.activateSelected(newTabOverride: true) }
        f.stringValue = model.text
        context.coordinator.field = f
        context.coordinator.applyPlaceholder(f, color: placeholderColor)
        DispatchQueue.main.async {
            guard let win = f.window else { return }
            win.makeFirstResponder(f)
            if model.selectAllInitially { f.currentEditor()?.selectAll(nil) }
            else { f.currentEditor()?.selectedRange = NSRange(location: f.stringValue.utf16.count, length: 0) }
        }
        return f
    }

    func updateNSView(_ f: KeyField, context: Context) {
        let c = context.coordinator
        c.model = model
        f.textColor = textColor
        c.applyPlaceholder(f, color: placeholderColor)

        // Refocus when asked (⌘L pressed while the bar is already open).
        if c.lastFocusToken != window.commandBarFocusToken {
            c.lastFocusToken = window.commandBarFocusToken
            DispatchQueue.main.async {
                f.window?.makeFirstResponder(f)
                f.currentEditor()?.selectAll(nil)
            }
        }

        guard let editor = f.currentEditor() as? NSTextView, !editor.hasMarkedText() else {
            if f.currentEditor() == nil, f.stringValue != model.text { f.stringValue = model.text }
            return
        }
        var desired = model.text
        var completionLength = 0
        if model.allowInline, let comp = model.inlineCompletion, comp.count > model.text.count,
           comp.lowercased().hasPrefix(model.text.lowercased()) {
            // Keep what the user typed, append the rest of the host.
            let suffix = String(comp.dropFirst(model.text.count))
            desired = model.text + suffix
            completionLength = suffix.utf16.count
        }
        if editor.string != desired {
            editor.string = desired
            let typedLength = (desired as NSString).length - completionLength
            editor.setSelectedRange(NSRange(location: typedLength, length: completionLength))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var model: CommandBarModel
        let window: WindowState
        weak var field: KeyField?
        var lastFocusToken: Int
        private var lastPlaceholder = ""

        init(model: CommandBarModel, window: WindowState) {
            self.model = model; self.window = window
            lastFocusToken = window.commandBarFocusToken
        }

        func applyPlaceholder(_ f: NSTextField, color: NSColor) {
            let text = model.site.map { "Search \($0.name)" } ?? (model.mode == .newTab ? "Search or enter a URL…" : "Search or enter address…")
            guard text != lastPlaceholder else { return }
            lastPlaceholder = text
            f.placeholderAttributedString = NSAttributedString(string: text, attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 19)])
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            // What the user has typed is the part before any selected inline completion.
            var typed = f.stringValue
            if let editor = f.currentEditor() as? NSTextView {
                let sel = editor.selectedRange
                if sel.length > 0, NSMaxRange(sel) == (editor.string as NSString).length {
                    typed = (editor.string as NSString).substring(to: sel.location)
                }
            }
            model.allowInline = typed.count > model.text.count
            model.textChanged(typed)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveDown(_:)): model.move(1); return true
            case #selector(NSResponder.moveUp(_:)): model.move(-1); return true
            case #selector(NSResponder.insertNewline(_:)):
                model.activateSelected(newTabOverride: NSEvent.modifierFlags.contains(.command))
                return true
            case #selector(NSResponder.insertTab(_:)):
                model.tab()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                model.close()
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                if textView.string.isEmpty, model.backspaceOnEmpty() { return true }
                // Deleting a shown completion should just remove it.
                if textView.selectedRange.length > 0, NSMaxRange(textView.selectedRange) == (textView.string as NSString).length,
                   model.inlineCompletion != nil {
                    model.allowInline = false
                    textView.deleteBackward(nil)
                    model.textChanged(textView.string)
                    return true
                }
                model.allowInline = false
                return false
            case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveToEndOfLine(_:)):
                // Accepting a completion with → or ⌘→.
                if textView.selectedRange.length > 0, NSMaxRange(textView.selectedRange) == (textView.string as NSString).length {
                    let full = textView.string
                    textView.setSelectedRange(NSRange(location: (full as NSString).length, length: 0))
                    model.allowInline = false
                    model.textChanged(full)
                    return true
                }
                return false
            default: return false
            }
        }
    }
}

final class KeyField: NSTextField {
    var onCommandReturn: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
