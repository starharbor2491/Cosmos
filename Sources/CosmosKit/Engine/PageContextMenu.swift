import AppKit
import CosmosCore
import CosmosEngine

/// The right-click menu of a page. The engine draws none of its own: the page agent says what the click was on, and Cosmos
/// makes the menu from that, then shows it as the ring or as a menu. Every item names the action it stands for
/// (`cosmos.<action>`), which is how the ring places it.
extension TabRuntime {
    /// What a menu item does, carried on the item: the ring can be open while the page moves on, so nothing is read from
    /// the page when the item runs.
    final class MenuCommand: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    @objc func runMenuCommand(_ sender: NSMenuItem) { (sender.representedObject as? MenuCommand)?.run() }

    func menuItem(_ action: RadialAction, title: String? = nil, enabled: Bool = true, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title ?? action.title, action: #selector(runMenuCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = MenuCommand(run)
        item.identifier = NSUserInterfaceItemIdentifier("cosmos.\(action.rawValue)")
        item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
        item.isEnabled = enabled
        return item
    }

    /// The menu for what the last right click was on.
    func contextMenu() -> NSMenu {
        let c = context
        let menu = NSMenu()
        menu.autoenablesItems = false
        var sections: [[NSMenuItem]] = []

        if let link = c.link {
            var s: [NSMenuItem] = []
            if Self.isWebLink(link) {
                s.append(menuItem(.openLink) { [weak self] in self?.load(link) })
                s.append(menuItem(.openLinkInNewTab, title: "Open Link in New Tab") { [weak self] in self.map { $0.host?.tab($0, open: link, as: .newTabForeground) } })
                s.append(menuItem(.openLinkInPeek, title: "Open Link in Peek") { [weak self] in self.map { $0.host?.tab($0, open: link, as: .peek) } })
                s.append(menuItem(.openLinkInSplit, title: "Open Link in Split View") { [weak self] in self.map { $0.host?.tab($0, open: link, as: .split) } })
                s.append(menuItem(.downloadLinkedFile) { [weak self] in self.map { $0.host?.tab($0, open: link, as: .download) } })
            }
            s.append(menuItem(.copyLink) { Self.copy(link.absoluteString) })
            sections.append(s)
        }
        if let image = c.image {
            var s: [NSMenuItem] = []
            if Self.isWebLink(image) || image.scheme == "data" {
                s.append(menuItem(.openImageInNewTab) { [weak self] in self.map { $0.host?.tab($0, open: image, as: .newTabForeground) } })
            }
            s.append(menuItem(.downloadImage) { [weak self] in self?.page.download(image) })
            s.append(menuItem(.copyImage) { Self.copyImage(at: image) })
            sections.append(s)
        }
        if c.isMedia {
            var s: [NSMenuItem] = []
            s.append(menuItem(.toggleMediaControls, title: "Show or Hide Controls") { [weak self] in self?.evaluate("window.__cosmosMedia && __cosmosMedia('controls')", in: .agent) })
            s.append(menuItem(.toggleLoop) { [weak self] in self?.evaluate("window.__cosmosMedia && __cosmosMedia('loop')", in: .agent) })
            if let media = c.media, Self.isWebLink(media) {
                s.append(menuItem(.downloadMedia) { [weak self] in self?.page.download(media) })
                s.append(menuItem(.copyMediaLink) { Self.copy(media.absoluteString) })
            }
            sections.append(s)
        }
        let selection = c.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.editable {
            sections.append([
                menuItem(.cut) { [weak self] in self?.page.perform(.cut) },
                menuItem(.copy) { [weak self] in self?.page.perform(.copy) },
                menuItem(.paste) { [weak self] in self?.page.perform(.paste) },
                menuItem(.selectAll) { [weak self] in self?.page.perform(.selectAll) },
            ])
        } else if !selection.isEmpty {
            sections.append([menuItem(.copy) { [weak self] in self?.page.perform(.copy) }])
        }
        if !selection.isEmpty {
            let short = selection.count > 24 ? String(selection.prefix(22)) + "…" : selection
            var s = [menuItem(.lookUp, title: "Look Up “\(short)”") { [weak self] in self?.lookUp(selection) }]
            if let host {
                let engine = SearchCatalog.bundled.engine(host.settings.searchEngineID)
                if let search = engine.searchURL(for: selection) {
                    s.append(menuItem(.searchWeb, title: "Search \(engine.name) for “\(short)”") { [weak self] in
                        self.map { $0.host?.tab($0, open: search, as: .newTabForeground) }
                    })
                }
            }
            sections.append(s)
        }
        if sections.isEmpty {
            sections.append([
                menuItem(.back, enabled: canGoBack) { [weak self] in self?.goBack() },
                menuItem(.forward, enabled: canGoForward) { [weak self] in self?.goForward() },
                isLoading ? menuItem(.stop) { [weak self] in self?.stop() } : menuItem(.reload) { [weak self] in self?.reload() },
            ])
            sections.append([menuItem(.selectAll) { [weak self] in self?.page.perform(.selectAll) }])
        }
        if let shared = c.link ?? c.image ?? (selection.isEmpty ? url : nil) {
            sections.append([menuItem(.share) { [weak self] in self?.share(shared) }])
        }
        if let ext = extensionSection(selection: selection) { sections.append(ext) }

        for (i, section) in sections.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            section.forEach(menu.addItem)
        }
        return menu
    }

    /// The items extensions added for what the click was on.
    private func extensionSection(selection: String) -> [NSMenuItem]? {
        guard let host else { return nil }
        let c = context
        // As in Chrome: `page` only when the click is on nothing more particular, `all` always.
        var contexts: Set<String> = ["all"]
        if c.link != nil { contexts.insert("link") }
        if c.image != nil { contexts.insert("image") }
        if c.isMedia { contexts.formUnion(["video", "audio"]) }
        if !selection.isEmpty { contexts.insert("selection") }
        if c.editable { contexts.insert("editable") }
        if contexts == ["all"] { contexts.insert("page") }
        let items = host.extensionMenuItems(for: self, contexts: contexts)
        guard !items.isEmpty else { return nil }
        let click = ExtensionClickContext(pageURL: url, linkURL: c.link, srcURL: c.image ?? c.media, selectionText: selection.isEmpty ? nil : selection, editable: c.editable)
        return items.map { entry in
            let item = NSMenuItem(title: entry.title.replacingOccurrences(of: "%s", with: selection), action: #selector(runMenuCommand(_:)), keyEquivalent: "")
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier("extension.\(entry.id)")
            item.representedObject = MenuCommand { [weak self] in self.map { $0.host?.tab($0, performExtensionItem: entry, context: click) } }
            return item
        }
    }

    /// Shows the menu for the right click the agent just reported: as the ring when the settings, the site and the window
    /// allow it, otherwise as a menu at the pointer. Holding ⌥ on the click asks for the menu.
    func showContextMenu() {
        guard let window = view.window else { return }
        let menu = contextMenu()
        guard !menu.items.isEmpty else { return }
        let at = contextMenuLocation(in: window)
        if presentRadialMenu(menu, at: at.point, modifiers: at.modifiers) { return }
        menu.popUp(positioning: nil, at: view.convert(at.point, from: nil), in: view)
    }

    /// Where the menu for the last right click goes, in the window's space, and the modifier keys held for it. The click
    /// says so itself; for a menu that came from the keyboard it is the page's report of where it was, and failing that
    /// wherever the mouse is.
    func contextMenuLocation(in window: NSWindow) -> (point: NSPoint, modifiers: NSEvent.ModifierFlags) {
        if let click = page.recentContextClick() { return (click.location, click.modifiers) }
        guard let p = context.point else { return (window.mouseLocationOutsideOfEventStream, NSEvent.modifierFlags) }
        let zoom = page.zoom
        return (view.convert(NSPoint(x: p.x * zoom, y: view.isFlipped ? p.y * zoom : view.bounds.height - p.y * zoom), to: nil), NSEvent.modifierFlags)
    }

    /// Puts the radial menu up in place of the menu, if the settings, the site and the window allow it. Returns whether it
    /// did.
    func presentRadialMenu(_ menu: NSMenu, at windowPoint: NSPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        // In element fullscreen (a video taking the screen) the ring would be drawn over the video's own controls.
        guard let host, let window = view.window, !page.isInElementFullscreen,
              !modifiers.contains(.option), !NSWorkspace.shared.isVoiceOverEnabled else { return false }
        let c = context
        let kind = RadialContext.detect(link: c.link != nil, image: c.image != nil, selection: !c.selection.isEmpty,
                                        editable: c.editable, media: c.isMedia)
        let size = window.contentView?.bounds.size ?? window.frame.size
        return host.tab(self, showRadialMenu: menu, context: kind, center: CGPoint(x: windowPoint.x, y: size.height - windowPoint.y), windowSize: size)
    }

    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Copies the picture itself. Fetched afresh: the engine keeps its copy to itself.
    static func copyImage(at url: URL) {
        Task {
            let data: Data?
            if url.scheme == "data" { data = try? Data(contentsOf: url) } else { data = try? await URLSession.shared.data(from: url).0 }
            guard let data, let image = NSImage(data: data) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
    }

    private func lookUp(_ text: String) {
        let at = context.point.map { NSPoint(x: $0.x * page.zoom, y: $0.y * page.zoom) } ?? view.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        view.showDefinition(for: NSAttributedString(string: text), at: at)
    }

    private func share(_ url: URL) {
        let picker = NSSharingServicePicker(items: [url])
        let at = view.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        picker.show(relativeTo: NSRect(origin: at, size: NSSize(width: 1, height: 1)), of: view, preferredEdge: .maxY)
    }
}
