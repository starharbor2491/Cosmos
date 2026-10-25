import AppKit
import CosmosCore

/// The menu bar. Shortcuts follow Arc's own (see arc-teardown/appendix/keybinding-and-type-travel-ids.md) so muscle
/// memory carries over.
extension CosmosAppDelegate {
    private typealias Mods = NSEvent.ModifierFlags

    func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func top(_ title: String, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            build(menu)
            item.submenu = menu
            main.addItem(item)
        }

        top("Cosmos") { m in
            m.addItem(withTitle: "About Cosmos", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
            m.addItem(.separator())
            add(m, "Settings…", ",", [.command], global: { $0.showSettings() })
            m.addItem(.separator())
            add(m, "Import from Arc or Another Browser…", "", [], { $0.state.overlay = .welcome })
            add(m, "Set Cosmos as Default Browser", "", [], global: { d in
                DefaultBrowser.request { ok in d.active?.state.showToast(ok ? "Cosmos is now your default browser" : "Choose Cosmos in the system prompt", symbol: ok ? "checkmark.seal.fill" : "info.circle") }
            })
            m.addItem(.separator())
            m.addItem(withTitle: "Hide Cosmos", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            let others = m.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            others.keyEquivalentModifierMask = [.command, .option]
            m.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
            m.addItem(.separator())
            m.addItem(withTitle: "Quit Cosmos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        }

        top("File") { m in
            add(m, "New Tab", "t", [.command], { $0.state.overlay = .commandBar(.newTab); $0.state.commandBarFocusToken += 1 })
            add(m, "New Window", "n", [.command], global: { $0.newWindow() })
            add(m, "New Incognito Window", "n", [.command, .shift], global: { $0.newIncognitoWindow() })
            add(m, "New Probe Window", "n", [.command, .option], global: { d in d.openProbe(URL(string: "about:blank")!, store: d.store) })
            m.addItem(.separator())
            add(m, "New Space…", "", [], { $0.store.beginNewSpace(in: $0.state) })
            add(m, "New Folder", "n", [.command, .shift, .option], { $0.store.newFolder(in: $0.state) })
            m.addItem(.separator())
            add(m, "Open Command Bar", "l", [.command], { c in
                if case .commandBar = c.state.overlay { c.state.commandBarFocusToken += 1 }
                else { c.state.overlay = .commandBar(c.store.currentURL(in: c.state) == nil ? .newTab : .currentTab) }
            })
            m.addItem(.separator())
            add(m, "Archive Tab", "w", [.command], global: { d in
                if let key = NSApp.keyWindow, !(key.windowController is BrowserWindowController) { key.performClose(nil); return }
                if let c = d.active { c.store.closeSelected(in: c.state) }
            })
            add(m, "Close Window", "w", [.command, .shift], global: { d in
                if let key = NSApp.keyWindow { key.performClose(nil) } else { d.active?.window?.performClose(nil) }
            })
            add(m, "Restore Last Closed Tab", "t", [.command, .shift], { $0.store.reopenLastClosed(in: $0.state) })
            m.addItem(.separator())
            add(m, "Print…", "p", [.command], { $0.store.perform(.print, in: $0.state) })
        }

        top("Edit") { m in
            m.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
            let redo = m.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            redo.keyEquivalentModifierMask = [.command, .shift]
            m.addItem(.separator())
            m.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            m.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            m.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            let pm = m.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
            pm.keyEquivalentModifierMask = [.command, .shift]
            m.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            m.addItem(.separator())
            add(m, "Copy URL", "c", [.command, .shift], { $0.store.perform(.copyLink, in: $0.state) })
            add(m, "Copy URL as Markdown", "c", [.command, .shift, .option], { $0.store.perform(.copyLinkMarkdown, in: $0.state) })
            m.addItem(.separator())
            add(m, "Find…", "f", [.command], { $0.store.perform(.find, in: $0.state) })
            add(m, "Find Next", "g", [.command], { c in
                guard let rt = c.store.currentRuntime(in: c.state) else { return }
                rt.find(c.state.findQuery) { c.state.findHadMatch = $0 }
            })
            add(m, "Find Previous", "g", [.command, .shift], { c in
                guard let rt = c.store.currentRuntime(in: c.state) else { return }
                rt.find(c.state.findQuery, backwards: true) { c.state.findHadMatch = $0 }
            })
        }

        top("View") { m in
            add(m, "Toggle Sidebar", "s", [.command], { $0.store.perform(.toggleSidebar, in: $0.state) })
            m.addItem(.separator())
            add(m, "Reload Page", "r", [.command], { $0.store.perform(.reload, in: $0.state) })
            add(m, "Reload Ignoring Cache", "r", [.command, .shift], { $0.store.perform(.hardReload, in: $0.state) })
            add(m, "Stop Loading", ".", [.command], { $0.store.perform(.stopLoading, in: $0.state) })
            m.addItem(.separator())
            add(m, "Actual Size", "0", [.command], { $0.store.perform(.resetZoom, in: $0.state) })
            add(m, "Zoom In", "=", [.command], { $0.store.perform(.zoomIn, in: $0.state) })
            add(m, "Zoom Out", "-", [.command], { $0.store.perform(.zoomOut, in: $0.state) })
            m.addItem(.separator())
            add(m, "Picture in Picture", "p", [.command, .option], { $0.store.perform(.pictureInPicture, in: $0.state) })
            m.addItem(.separator())
            let fs = m.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            fs.keyEquivalentModifierMask = [.command, .control]
        }

        top("Spaces") { m in
            add(m, "Next Space", String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option], { $0.store.cycleSpace(1, in: $0.state) })
            add(m, "Previous Space", String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option], { $0.store.cycleSpace(-1, in: $0.state) })
            m.addItem(.separator())
            for n in 1...9 { add(m, "Space \(n)", String(n), [.control], enabled: { n <= $0.store.workspace.spaces.count }, { $0.store.switchSpace(number: n, in: $0.state) }) }
            m.addItem(.separator())
            add(m, "Edit Space Theme…", "", [], { $0.state.overlay = .themeEditor($0.state.focusedSpaceID) })
        }

        top("Tabs") { m in
            add(m, "Pin / Unpin Tab", "d", [.command], { $0.store.perform(.togglePin, in: $0.state) })
            add(m, "Add to / Remove from Favorites", "d", [.command, .option], { $0.store.perform(.toggleFavorite, in: $0.state) })
            add(m, "Archive All Today Tabs", "k", [.command, .shift], { $0.store.clearUnpinned(in: $0.state) })
            add(m, "Keep Peek Page as a Tab", "o", [.command], enabled: { $0.state.peek != nil }, { $0.store.promotePeek(in: $0.state) })
            m.addItem(.separator())
            add(m, "Next Tab", String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option], { $0.store.selectAdjacentTab(1, in: $0.state) })
            add(m, "Previous Tab", String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option], { $0.store.selectAdjacentTab(-1, in: $0.state) })
            add(m, "Recent Tab", "\t", [.control], { $0.store.selectRecent(1, in: $0.state) })
            add(m, "Older Recent Tab", "\t", [.control, .shift], { $0.store.selectRecent(2, in: $0.state) })
            m.addItem(.separator())
            add(m, "Add Split View", "+", [.control], { $0.store.perform(.addSplit, in: $0.state) })
            add(m, "Close Split Pane", "_", [.control], { $0.store.perform(.closeSplitPane, in: $0.state) })
            add(m, "Mute / Unmute Tab", "", [], { $0.store.perform(.muteTab, in: $0.state) })
            m.addItem(.separator())
            for n in 1...9 { add(m, "Favorite \(n)", String(n), [.command], enabled: { n <= $0.store.workspace.favorites.count }, { $0.store.selectFavorite(number: n, in: $0.state) }) }
        }

        top("History") { m in
            add(m, "Back", "[", [.command], { $0.store.perform(.goBack, in: $0.state) })
            add(m, "Forward", "]", [.command], { $0.store.perform(.goForward, in: $0.state) })
            m.addItem(.separator())
            add(m, "Show History", "y", [.command], { $0.store.perform(.showHistory, in: $0.state) })
            add(m, "Show Archive", "a", [.command, .shift], { $0.store.perform(.showArchive, in: $0.state) })
            add(m, "Show Downloads", "j", [.command, .shift], { $0.store.perform(.showDownloads, in: $0.state) })
        }

        top("Boosts") { m in
            add(m, "Boost This Site…", "b", [.command, .option], { $0.state.overlay = .boosts })
            add(m, "Site Controls", "", [], { $0.state.overlay = .siteControls })
        }

        top("Developer") { m in
            add(m, "View Source", "u", [.command, .option], { $0.store.perform(.viewSource, in: $0.state) })
            add(m, "Developer Tools", "i", [.command, .option], { $0.store.perform(.toggleDeveloperTools, in: $0.state) })
            add(m, "Open Page in Another Browser", "", [], { $0.store.perform(.openInDefaultBrowser, in: $0.state) })
        }

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        main.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        add(helpMenu, "Keyboard Shortcuts", "/", [.command], { $0.state.overlay = .shortcuts })
        add(helpMenu, "Welcome to Cosmos", "", [], { $0.state.overlay = .welcome })
        helpItem.submenu = helpMenu
        main.addItem(helpItem)
        NSApp.helpMenu = helpMenu
        return main
    }

    /// Adds an item that acts on the frontmost browser window (disabled when there is none).
    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ key: String, _ mods: NSEvent.ModifierFlags,
                     enabled: ((BrowserWindowController) -> Bool)? = nil, _ run: @escaping (BrowserWindowController) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = self
        item.representedObject = MenuAction(needsWindow: true, enabled: enabled) { c in if let c { run(c) } }
        menu.addItem(item)
        return item
    }

    /// Adds an item that works without a browser window.
    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ key: String, _ mods: NSEvent.ModifierFlags, global run: @escaping (CosmosAppDelegate) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = self
        item.representedObject = MenuAction(needsWindow: false, enabled: nil) { [weak self] _ in if let self { run(self) } }
        menu.addItem(item)
        return item
    }
}
