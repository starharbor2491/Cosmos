import AppKit
import SwiftUI
import WebKit
import CosmosCore

/// Lays out the live web views for the selected item: one page, or 2–4 panes side by side with draggable dividers.
/// Pages sit in rounded, softly shadowed cards over the space's theme.
final class WebContentHostView: NSView {
    struct Pane {
        let runtime: TabRuntime
        let isFocused: Bool
    }

    private(set) var panes: [Pane] = []
    private var containers: [ObjectIdentifier: PaneContainer] = [:]
    private var dividers: [DividerView] = []
    private var orientation: SplitData.Orientation = .horizontal
    private var weights: [Double] = []
    private var accent: NSColor = .controlAccentColor
    private var lastFocusedID: ObjectIdentifier?
    var onWeightsChanged: (([Double]) -> Void)?

    static let corner: CGFloat = 11
    static let gap: CGFloat = 8

    override var isFlipped: Bool { true }

    func update(panes newPanes: [Pane], orientation: SplitData.Orientation, weights newWeights: [Double], accent: NSColor, wantsFocus: Bool) {
        self.accent = accent
        self.orientation = orientation
        let ids = Set(newPanes.map { ObjectIdentifier($0.runtime) })
        for (id, c) in containers where !ids.contains(id) { c.removeFromSuperview(); containers[id] = nil }
        for p in newPanes {
            let id = ObjectIdentifier(p.runtime)
            if containers[id] == nil {
                let c = PaneContainer(webView: p.runtime.webView)
                containers[id] = c
                addSubview(c)
            }
            containers[id]?.setFocused(p.isFocused && newPanes.count > 1, accent: accent)
        }
        panes = newPanes
        weights = Self.normalised(newWeights, count: newPanes.count)
        rebuildDividers()
        needsLayout = true
        layoutSubtreeIfNeeded()

        if wantsFocus, let focused = newPanes.first(where: \.isFocused) ?? newPanes.first {
            let fid = ObjectIdentifier(focused.runtime)
            if fid != lastFocusedID {
                lastFocusedID = fid
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window else { return }
                    if window.firstResponder is NSTextView || window.firstResponder is NSTextField { if window.attachedSheet == nil, window.firstResponder !== focused.runtime.webView { /* leave text entry alone */ } }
                    window.makeFirstResponder(focused.runtime.webView)
                }
            }
        } else if newPanes.isEmpty {
            lastFocusedID = nil
        }
    }

    static func normalised(_ w: [Double], count: Int) -> [Double] {
        guard count > 0 else { return [] }
        var out = w.count == count && w.allSatisfy({ $0 > 0.05 }) ? w : Array(repeating: 1, count: count)
        let sum = out.reduce(0, +)
        out = out.map { $0 / sum }
        return out
    }

    private func rebuildDividers() {
        dividers.forEach { $0.removeFromSuperview() }
        dividers = []
        guard panes.count > 1 else { return }
        for i in 0..<(panes.count - 1) {
            let d = DividerView(index: i)
            d.onDrag = { [weak self] idx, delta in self?.dragDivider(idx, delta: delta) }
            d.onEnd = { [weak self] in if let w = self?.weights { self?.onWeightsChanged?(w) } }
            addSubview(d, positioned: .above, relativeTo: nil)
            dividers.append(d)
        }
    }

    private func dragDivider(_ index: Int, delta: CGFloat) {
        let total = orientation == .horizontal ? bounds.width : bounds.height
        guard total > 0, index + 1 < weights.count else { return }
        let d = Double(delta / total)
        let minW = 0.15
        var a = weights[index] + d, b = weights[index + 1] - d
        if a < minW { b -= (minW - a); a = minW }
        if b < minW { a -= (minW - b); b = minW }
        weights[index] = a; weights[index + 1] = b
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        guard !panes.isEmpty else { return }
        let n = panes.count
        let gap = n > 1 ? Self.gap : 0
        let total = (orientation == .horizontal ? bounds.width : bounds.height) - gap * CGFloat(n - 1)
        var offset: CGFloat = 0
        for (i, p) in panes.enumerated() {
            let len = max(60, total * CGFloat(weights.indices.contains(i) ? weights[i] : 1 / Double(n)))
            let frame = orientation == .horizontal
                ? NSRect(x: offset, y: 0, width: len, height: bounds.height)
                : NSRect(x: 0, y: offset, width: bounds.width, height: len)
            containers[ObjectIdentifier(p.runtime)]?.frame = frame
            if i < dividers.count {
                dividers[i].orientation = orientation
                dividers[i].frame = orientation == .horizontal
                    ? NSRect(x: offset + len - 2, y: 0, width: gap + 4, height: bounds.height)
                    : NSRect(x: 0, y: offset + len - 2, width: bounds.width, height: gap + 4)
            }
            offset += len + gap
        }
    }
}

/// A rounded card holding one web view.
final class PaneContainer: NSView {
    private let webView: WKWebView
    private let shadowHost = NSView()
    private let card = NSView()

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        shadowHost.wantsLayer = true
        shadowHost.layer?.cornerRadius = WebContentHostView.corner
        shadowHost.layer?.cornerCurve = .continuous
        shadowHost.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        shadowHost.layer?.shadowColor = NSColor.black.cgColor
        shadowHost.layer?.shadowOpacity = 0.28
        shadowHost.layer?.shadowRadius = 10
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -2)
        addSubview(shadowHost)
        card.wantsLayer = true
        card.layer?.cornerRadius = WebContentHostView.corner
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        addSubview(card)
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        card.addSubview(webView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        shadowHost.frame = bounds
        card.frame = bounds
        webView.frame = card.bounds
    }

    func setFocused(_ focused: Bool, accent: NSColor) {
        card.layer?.borderWidth = focused ? 2 : 0.5
        card.layer?.borderColor = (focused ? accent.withAlphaComponent(0.85) : NSColor.white.withAlphaComponent(0.14)).cgColor
    }
}

final class DividerView: NSView {
    let index: Int
    var orientation: SplitData.Orientation = .horizontal
    var onDrag: ((Int, CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var lastPoint: NSPoint = .zero

    init(index: Int) { self.index = index; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: orientation == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) { lastPoint = superview?.convert(event.locationInWindow, from: nil) ?? .zero }
    override func mouseDragged(with event: NSEvent) {
        guard let p = superview?.convert(event.locationInWindow, from: nil) else { return }
        let delta = orientation == .horizontal ? p.x - lastPoint.x : p.y - lastPoint.y
        lastPoint = p
        onDrag?(index, delta)
    }
    override func mouseUp(with event: NSEvent) { onEnd?() }
}

struct WebContentRepresentable: NSViewRepresentable {
    let runtimes: [TabRuntime]
    let focusedID: UUID?
    let orientation: SplitData.Orientation
    let weights: [Double]
    let accent: NSColor
    let wantsFocus: Bool
    let revision: Int
    let onWeights: ([Double]) -> Void

    func makeNSView(context: Context) -> WebContentHostView {
        let v = WebContentHostView()
        v.onWeightsChanged = onWeights
        return v
    }

    func updateNSView(_ host: WebContentHostView, context: Context) {
        host.onWeightsChanged = onWeights
        host.update(panes: runtimes.map { .init(runtime: $0, isFocused: $0.itemID == focusedID) },
                    orientation: orientation, weights: weights, accent: accent, wantsFocus: wantsFocus)
    }
}
