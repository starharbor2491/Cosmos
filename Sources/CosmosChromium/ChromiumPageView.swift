import AppKit
import CosmosEngine

/// Where a Chromium page is. CEF draws the page in a view of its own inside this one, filling it, and that view takes
/// the mouse, keyboard, input methods, drags, the pointer's shape, `<select>` menus and VoiceOver itself. This view only
/// hears of right clicks and Force Clicks on their way to it: Cosmos's own context menu and Look Up need them.
final class ChromiumPageView: NSView {
    weak var page: ChromiumPage?
    private(set) var lastContextClick: ContextClick?
    private var monitor: Any?
    /// How hard the trackpad is pressed: stage 2 is a Force Click.
    private var pressureStage = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    // Cosmos gives the page the keyboard by making this view the first responder (after the Command Bar or the Find bar
    // closes, on a tab switch); CEF's view takes it from here, once AppKit is done making this one first.
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        if let browser = page?.cefBrowser { DispatchQueue.main.async { browser.focus() } }
        return true
    }

    // CEF's view (and the DevTools' one) fill this view.
    override func layout() {
        super.layout()
        for view in subviews where view.frame != bounds { view.frame = bounds }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if window != nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .pressure]) { [weak self] event in
                self?.saw(event)
                return event
            }
        }
        page?.viewVisibilityChanged()
    }

    override func viewDidHide() { super.viewDidHide(); page?.viewVisibilityChanged() }
    override func viewDidUnhide() { super.viewDidUnhide(); page?.viewVisibilityChanged() }

    var isShowing: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

    /// An event on its way to the page (CEF's view, under this one).
    func saw(_ event: NSEvent) {
        guard event.window === window, let content = window?.contentView,
              let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow),
              hit === self || hit.isDescendant(of: self) else { return }
        switch event.type {
        case .rightMouseDown: noteContextClick(event)
        case .leftMouseDown where event.modifierFlags.contains(.control): noteContextClick(event)
        case .pressure:
            if event.stage == 2 && pressureStage < 2 { page?.forceClicked() }
            pressureStage = event.stage
        default: break
        }
    }

    /// The last right (or control) click, if it was recent enough to be the one a context menu is for: a menu from the
    /// keyboard's menu key is not tied to a click from half a minute ago.
    func recentContextClick(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> ContextClick? {
        guard let click = lastContextClick, now - click.uptime < 1.5 else { return nil }
        return click
    }

    private func noteContextClick(_ event: NSEvent) {
        lastContextClick = ContextClick(location: event.locationInWindow, modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
                                        uptime: event.timestamp)
    }
}
