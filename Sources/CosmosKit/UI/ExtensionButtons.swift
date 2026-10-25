import SwiftUI
import AppKit

/// Remembers the AppKit view behind a SwiftUI button so an extension's popup can open next to it.
final class AnchorBox {
    weak var view: NSView?
}

struct AnchorCapture: NSViewRepresentable {
    let box: AnchorBox
    func makeNSView(context: Context) -> NSView { let v = NSView(); box.view = v; return v }
    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}

/// A row of toolbar buttons, one per enabled extension that has one, under the address pill.
struct ExtensionButtons: View {
    let store: BrowserStore
    let window: WindowState

    var body: some View {
        if let center = store.extensionCenter {
            let runtime = store.currentRuntime(in: window)
            let actions = center.actions(for: runtime)
            if !actions.isEmpty {
                HStack(spacing: 2) {
                    ForEach(actions) { action in
                        ExtensionActionButton(center: center, display: action, runtime: runtime)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
    }
}

struct ExtensionActionButton: View {
    let center: ExtensionCenter
    let display: ExtensionActionDisplay
    let runtime: TabRuntime?
    @Environment(\.palette) private var palette
    @Local private var hover = false
    @Local private var anchor = AnchorBox()

    var body: some View {
        Button {
            center.performAction(display.id, runtime: runtime, anchor: anchor.view)
        } label: {
            ZStack(alignment: .topTrailing) {
                if let icon = display.icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 17, height: 17)
                } else {
                    Image(systemName: "puzzlepiece.extension").font(.system(size: 13, weight: .medium))
                }
                if !display.badge.isEmpty {
                    Text(display.badge)
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(Capsule().fill(palette.accent))
                        .offset(x: 6, y: -5)
                }
            }
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover && display.isEnabled ? palette.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(display.isEnabled ? palette.secondary : palette.tertiary.opacity(0.6))
        .background(AnchorCapture(box: anchor))
        .disabled(!display.isEnabled)
        .onHover { hover = $0 }
        .help(display.label)
    }
}
