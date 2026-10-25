import AppKit
import WebKit

/// `WKWebView` plus the hooks Cosmos needs: a back-pointer to its tab and a tuned context menu.
public final class CosmosWebView: WKWebView {
    weak var runtime: TabRuntime?

    public override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let runtime else { return }
        MainActor.assumeIsolated { runtime.customiseContextMenu(menu) }
    }

    /// Plain scroll/click events should not steal the window drag; nothing to override beyond the menu today.
    public override var acceptsFirstResponder: Bool { true }
}

extension NSMenuItem {
    /// WebKit tags its stock items with identifiers like `WKMenuItemIdentifierOpenLinkInNewWindow`.
    var webKitIdentifier: String? { identifier?.rawValue }
}
