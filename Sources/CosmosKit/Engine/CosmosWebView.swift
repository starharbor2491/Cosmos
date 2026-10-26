import AppKit
import WebKit

/// `WKWebView` plus the hooks Cosmos needs: a back-pointer to its tab and a tuned context menu.
public final class CosmosWebView: WKWebView {
    weak var runtime: TabRuntime?

    /// The click that is about to ask for a context menu, as the click itself says it: where it was in the window and
    /// which modifier keys were down. WebKit answers a moment later, after the page has had its say, and by then the
    /// keyboard may have changed and the page's idea of where the pointer was is only as good as its zoom arithmetic.
    struct Click {
        var location: NSPoint
        var modifiers: NSEvent.ModifierFlags
        var uptime: TimeInterval
    }

    private var lastClick: Click?

    func noteClick(_ event: NSEvent) {
        lastClick = Click(location: event.locationInWindow, modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask), uptime: event.timestamp)
    }

    /// The last right (or control) click, if it was recent enough to be the one a menu is being asked for.
    func recentClick() -> Click? {
        guard let lastClick, ProcessInfo.processInfo.systemUptime - lastClick.uptime < 1.5 else { return nil }
        return lastClick
    }

    public override func rightMouseDown(with event: NSEvent) {
        noteClick(event)
        super.rightMouseDown(with: event)
    }

    public override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { noteClick(event) }
        super.mouseDown(with: event)
    }

    public override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let runtime else { return }
        MainActor.assumeIsolated {
            runtime.customiseContextMenu(menu)
            // The ring stands in for the system menu, so this one is called off before it is drawn. Its items stay on
            // the menu: the ring runs them through it when one is chosen.
            if runtime.presentRadialMenu(menu) { menu.cancelTracking() }
        }
    }

    /// Plain scroll/click events should not steal the window drag; nothing to override beyond the menu today.
    public override var acceptsFirstResponder: Bool { true }

    // A tab dragged out of the sidebar carries its address as a link so other apps take it. Over the page WebKit would
    // load that link in this tab, so a drag that started in the sidebar is turned away here.
    private func isSidebarDrag(_ info: NSDraggingInfo) -> Bool {
        if info.draggingPasteboard.types?.contains(NSPasteboard.PasteboardType(SidebarDrop.itemType.identifier)) == true { return true }
        return MainActor.assumeIsolated { runtime?.host?.isDraggingSidebarItem == true }
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isSidebarDrag(sender) ? [] : super.draggingEntered(sender)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isSidebarDrag(sender) ? [] : super.draggingUpdated(sender)
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isSidebarDrag(sender) ? false : super.prepareForDragOperation(sender)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isSidebarDrag(sender) ? false : super.performDragOperation(sender)
    }
}

extension NSMenuItem {
    /// WebKit tags its stock items with identifiers like `WKMenuItemIdentifierOpenLinkInNewWindow`.
    var webKitIdentifier: String? { identifier?.rawValue }
}
