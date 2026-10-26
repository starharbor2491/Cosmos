import SwiftUI
import AppKit
import CosmosCore

/// Find in page (⌘F): a small floating field in the page's top-right corner.
struct FindBar: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette
    @Local private var focusToken = 0

    var body: some View {
        let rt = store.currentRuntime(in: window)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(palette.secondary)
            FindField(text: Binding(get: { window.findQuery }, set: { window.findQuery = $0; run(rt, backwards: false, fresh: true) }),
                      textColor: palette.isDark ? .white : .black,
                      placeholderColor: NSColor(palette.placeholder),
                      onNext: { run(rt, backwards: false, fresh: false) },
                      onPrevious: { run(rt, backwards: true, fresh: false) },
                      onClose: { close() })
                .frame(width: 190, height: 22)
            if !window.findHadMatch && !window.findQuery.isEmpty {
                Text("No matches").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.red.opacity(0.9))
            }
            ToolbarButton(symbol: "chevron.up", size: 11, help: "Previous (⇧⌘G)") { run(rt, backwards: true, fresh: false) }
            ToolbarButton(symbol: "chevron.down", size: 11, help: "Next (⌘G)") { run(rt, backwards: false, fresh: false) }
            ToolbarButton(symbol: "xmark", size: 10.5, help: "Close (Esc)") { close() }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous))
        .background(RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous).fill(palette.panel))
        .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous).strokeBorder(palette.stroke, lineWidth: 0.6))
        .shadow(color: palette.shadow, radius: 16, y: 5)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func run(_ rt: TabRuntime?, backwards: Bool, fresh: Bool) {
        guard let rt else { return }
        let q = window.findQuery
        if q.isEmpty { window.findHadMatch = true; rt.clearFind(); return }
        rt.find(q, backwards: backwards) { found in window.findHadMatch = found }
    }

    private func close() {
        store.currentRuntime(in: window)?.clearFind()
        window.overlay = nil
        window.findQuery = ""
        window.findHadMatch = true
        if let rt = store.currentRuntime(in: window) { rt.webView.window?.makeFirstResponder(rt.webView) }
    }
}

private struct FindField: NSViewRepresentable {
    @Binding var text: String
    let textColor: NSColor
    /// The system's placeholder grey all but vanishes on a themed bar, so the prompt is drawn in the hint colour (solid: the
    /// field paints a placeholder opaque whatever alpha it has).
    let placeholderColor: NSColor
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 13)
        f.placeholderAttributedString = NSAttributedString(string: "Find in page", attributes: [.foregroundColor: placeholderColor, .font: NSFont.systemFont(ofSize: 13)])
        f.delegate = context.coordinator
        f.stringValue = text
        DispatchQueue.main.async {
            f.window?.makeFirstResponder(f)
            f.currentEditor()?.selectAll(nil)
        }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        f.textColor = textColor
        if f.currentEditor() == nil, f.stringValue != text { f.stringValue = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FindField
        init(_ p: FindField) { parent = p }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            parent.text = f.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                if NSEvent.modifierFlags.contains(.shift) { parent.onPrevious() } else { parent.onNext() }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onClose()
                return true
            default: return false
            }
        }
    }
}
