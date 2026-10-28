import AppKit
import WebKit
import CosmosCore

/// Everything you can do from the Command Bar by name ("Type Travel") and, for most, from the menus.
enum BrowserCommand: String, CaseIterable {
    case newSpace, editTheme, deleteSpace, nextSpace, previousSpace
    case toggleSidebar, clearUnpinned, reopenClosedTab, togglePin, toggleFavorite, newFolder
    case addSplit, closeSplitPane, separateSplit
    case reload, hardReload, stopLoading, goBack, goForward
    case copyLink, copyLinkMarkdown, find, print, zoomIn, zoomOut, resetZoom, muteTab, pictureInPicture, viewSource
    case showLibrary, showResources, showArchive, showHistory, showDownloads, showBoosts, showSettings, showShortcuts, showWelcome
    case newWindow, newIncognito, newProbe
    case resetPinned, collapseFolders, expandFolders, resetTab
    case setDefaultBrowser, importFromArc, toggleDeveloperTools, openInDefaultBrowser, manageExtensions, showSiteControls

    /// Whether the command is about what the Library is covering: the page that is showing, the tab that holds it, or the
    /// space it is in. It would happen out of sight, so the page comes back first. (Picture in Picture is not: the page can
    /// go to it from under the Library.)
    var needsThePageInView: Bool {
        switch self {
        case .reload, .hardReload, .stopLoading, .goBack, .goForward, .copyLink, .copyLinkMarkdown, .find, .print, .zoomIn, .zoomOut, .resetZoom,
             .muteTab, .viewSource, .toggleDeveloperTools, .openInDefaultBrowser, .showSiteControls, .showBoosts,
             .togglePin, .toggleFavorite, .addSplit, .closeSplitPane, .separateSplit, .resetTab,
             .editTheme, .deleteSpace, .clearUnpinned, .resetPinned, .newFolder, .collapseFolders, .expandFolders:
            return true
        default:
            return false
        }
    }

    var title: String {
        switch self {
        case .newSpace: return "New Space"
        case .editTheme: return "Edit Space Theme"
        case .deleteSpace: return "Delete Space"
        case .nextSpace: return "Next Space"
        case .previousSpace: return "Previous Space"
        case .toggleSidebar: return "Toggle Sidebar"
        case .clearUnpinned: return "Archive All Today Tabs"
        case .reopenClosedTab: return "Reopen Closed Tab"
        case .togglePin: return "Pin / Unpin Tab"
        case .toggleFavorite: return "Add to / Remove from Favorites"
        case .newFolder: return "New Folder"
        case .addSplit: return "Add Split View"
        case .closeSplitPane: return "Close Split Pane"
        case .separateSplit: return "Separate Tab from Split View"
        case .reload: return "Reload Page"
        case .hardReload: return "Reload Page Ignoring Cache"
        case .stopLoading: return "Stop Loading"
        case .goBack: return "Go Back"
        case .goForward: return "Go Forward"
        case .copyLink: return "Copy Link"
        case .copyLinkMarkdown: return "Copy Link as Markdown"
        case .find: return "Find in Page"
        case .print: return "Print Page"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .resetZoom: return "Actual Size"
        case .muteTab: return "Mute / Unmute Tab"
        case .pictureInPicture: return "Picture in Picture"
        case .viewSource: return "View Page Source"
        case .showLibrary: return "Open Library"
        case .showResources: return "Show System Resources"
        case .showArchive: return "Open Archive"
        case .showHistory: return "Open History"
        case .showDownloads: return "Open Downloads"
        case .showBoosts: return "Boosts"
        case .showSettings: return "Settings"
        case .showShortcuts: return "Keyboard Shortcuts"
        case .showWelcome: return "Welcome to Cosmos"
        case .newWindow: return "New Window"
        case .newIncognito: return "New Incognito Window"
        case .newProbe: return "New Probe Window"
        case .resetPinned: return "Reset Pinned Tabs"
        case .collapseFolders: return "Collapse All Folders"
        case .expandFolders: return "Expand All Folders"
        case .resetTab: return "Reset Tab to Original URL"
        case .setDefaultBrowser: return "Set Cosmos as Default Browser"
        case .importFromArc: return "Import from Arc or Another Browser"
        case .toggleDeveloperTools: return "Toggle Developer Tools"
        case .openInDefaultBrowser: return "Open Page in Another Browser"
        case .manageExtensions: return "Manage Extensions"
        case .showSiteControls: return "Site Controls"
        }
    }

    var symbol: String {
        switch self {
        case .newSpace, .editTheme, .deleteSpace, .nextSpace, .previousSpace: return "moon.stars"
        case .toggleSidebar: return "sidebar.left"
        case .clearUnpinned, .showArchive: return "archivebox"
        case .reopenClosedTab: return "arrow.uturn.backward"
        case .togglePin: return "pin"
        case .toggleFavorite: return "star"
        case .newFolder: return "folder.badge.plus"
        case .addSplit, .closeSplitPane, .separateSplit: return "rectangle.split.2x1"
        case .reload, .hardReload: return "arrow.clockwise"
        case .stopLoading: return "xmark"
        case .goBack: return "chevron.left"
        case .goForward: return "chevron.right"
        case .copyLink, .copyLinkMarkdown: return "link"
        case .find: return "magnifyingglass"
        case .print: return "printer"
        case .zoomIn, .zoomOut, .resetZoom: return "plus.magnifyingglass"
        case .muteTab: return "speaker.slash"
        case .pictureInPicture: return "pip"
        case .viewSource, .toggleDeveloperTools: return "chevron.left.forwardslash.chevron.right"
        case .showHistory: return "clock"
        case .showDownloads: return "arrow.down.circle"
        case .showLibrary: return "books.vertical"
        case .showResources: return "gauge.with.dots.needle.67percent"
        case .showBoosts: return "bolt.fill"
        case .showSettings: return "gearshape"
        case .showShortcuts: return "keyboard"
        case .showWelcome: return "sparkles"
        case .newWindow, .newIncognito, .newProbe: return "macwindow"
        case .resetPinned, .resetTab: return "arrow.counterclockwise"
        case .collapseFolders, .expandFolders: return "folder"
        case .setDefaultBrowser: return "checkmark.seal"
        case .importFromArc: return "square.and.arrow.down"
        case .manageExtensions: return "puzzlepiece.extension"
        case .showSiteControls: return "shield.lefthalf.filled"
        case .openInDefaultBrowser: return "arrow.up.forward.app"
        }
    }

    var keywords: [String] {
        switch self {
        case .newSpace: return ["create space", "add space"]
        case .editTheme: return ["theme", "color", "colour", "gradient", "rename space", "icon"]
        case .toggleSidebar: return ["hide sidebar", "show sidebar"]
        case .clearUnpinned: return ["clear", "archive", "close all"]
        case .addSplit: return ["split", "side by side"]
        case .showBoosts: return ["boost", "zap", "css", "dark mode", "custom"]
        case .showSettings: return ["preferences", "options"]
        case .showArchive: return ["closed tabs", "old tabs"]
        case .showLibrary: return ["archive", "history", "downloads", "utilities"]
        case .showResources: return ["memory", "cpu", "activity monitor", "task manager", "ram", "processor", "slow", "tabs using"]
        case .newIncognito: return ["private"]
        case .newProbe: return ["little arc", "mini window", "little"]
        case .importFromArc: return ["import", "chrome", "safari", "firefox", "bookmarks", "history", "migrate"]
        case .setDefaultBrowser: return ["default"]
        case .manageExtensions: return ["extension", "add-on", "addon", "plugin", "chrome web store", "ublock", "1password"]
        case .showSiteControls: return ["site control center", "permissions", "block ads", "trackers", "camera", "microphone", "this site"]
        case .find: return ["search page", "find in page"]
        case .toggleDeveloperTools: return ["devtools", "inspect", "console"]
        case .viewSource: return ["source"]
        case .pictureInPicture: return ["pip", "float video"]
        default: return []
        }
    }

    /// Shortcut hint shown on the row, when there is one.
    var shortcut: String? {
        switch self {
        case .toggleSidebar: return "⌘S"
        case .clearUnpinned: return "⇧⌘K"
        case .reopenClosedTab: return "⇧⌘T"
        case .togglePin: return "⌘D"
        case .addSplit: return "⌃⇧="
        case .closeSplitPane: return "⌃⇧-"
        case .reload: return "⌘R"
        case .hardReload: return "⇧⌘R"
        case .find: return "⌘F"
        case .print: return "⌘P"
        case .zoomIn: return "⌘+"
        case .zoomOut: return "⌘-"
        case .resetZoom: return "⌘0"
        case .showHistory: return "⌘Y"
        case .showDownloads: return "⇧⌘J"
        case .showSettings: return "⌘,"
        case .newWindow: return "⌘N"
        case .newIncognito: return "⇧⌘N"
        case .newProbe: return "⌥⌘N"
        case .nextSpace: return "⌥⌘→"
        case .previousSpace: return "⌥⌘←"
        case .copyLink: return "⇧⌘C"
        case .copyLinkMarkdown: return "⌥⇧⌘C"
        case .toggleDeveloperTools: return "⌥⌘I"
        case .viewSource: return "⌥⌘U"
        default: return nil
        }
    }

    var candidate: CommandCandidate {
        CommandCandidate(id: "cmd:\(rawValue)", kind: .command(rawValue), title: title, subtitle: shortcut, symbol: symbol, frecency: 1, keywords: keywords)
    }
}

extension BrowserStore {
    func perform(_ command: BrowserCommand, in window: WindowState) {
        if command.needsThePageInView { leaveLibrary(in: window) }
        let rt = currentRuntime(in: window)
        let curID = currentTabItemID(in: window)
        switch command {
        case .newSpace: beginNewSpace(in: window)
        case .editTheme: window.overlay = .themeEditor(window.focusedSpaceID)
        case .deleteSpace: deleteSpace(window.focusedSpaceID, in: window)
        case .nextSpace: cycleSpace(1, in: window)
        case .previousSpace: cycleSpace(-1, in: window)
        case .toggleSidebar:
            if window.sidebarVisible { leaveLibrary(in: window) }   // the rail goes with the sidebar (see `WindowState.sidebarVisible`)
            window.sidebarVisible.toggle(); window.sidebarPeeking = false; saveSession()
        case .clearUnpinned: clearUnpinned(in: window)
        case .reopenClosedTab: reopenLastClosed(in: window)
        case .togglePin: if let id = window.selectedItemID { togglePin(id, in: window) }
        case .toggleFavorite: if let id = curID { toggleFavorite(id, in: window) }
        case .newFolder: newFolder(in: window)
        case .addSplit: addSplit(in: window)
        case .closeSplitPane: closeFocusedPane(in: window)
        case .separateSplit: if let id = curID { separateFromSplit(id, in: window) }
        case .reload: rt?.reload()
        case .hardReload: rt?.reload(fromOrigin: true)
        case .stopLoading: rt?.stop()
        case .goBack: rt?.goBack()
        case .goForward: rt?.goForward()
        case .copyLink:
            if let url = currentURL(in: window) { copy(url.absoluteString); window.showToast("Link copied", symbol: "link") }
        case .copyLinkMarkdown:
            if let url = currentURL(in: window) {
                let title = (rt?.title.isEmpty == false ? rt?.title : nil) ?? url.host ?? "link"
                copy("[\(title)](\(url.absoluteString))"); window.showToast("Copied as Markdown", symbol: "link")
            }
        case .find: if rt != nil { window.overlay = .find; window.commandBarFocusToken += 1 }
        case .print: rt.map { printPage($0) }
        case .zoomIn: rt?.zoomIn()
        case .zoomOut: rt?.zoomOut()
        case .resetZoom: rt?.resetZoom()
        case .muteTab: if let id = curID { toggleMute(id, in: window) }
        case .pictureInPicture: rt?.enterPictureInPicture()
        case .viewSource: if let url = currentURL(in: window) { openViewSource(of: url, rt: rt, in: window) }
        case .showLibrary: show(.library, in: window)
        case .showResources: openLibrary(.resources, in: window)
        case .showArchive: openLibrary(.history, timeline: .archived, in: window)
        case .showHistory: openLibrary(.history, timeline: .everything, in: window)
        case .showDownloads: openLibrary(.downloads, in: window)
        case .showBoosts: window.overlay = .boosts
        case .showSettings: onShowSettings?()
        case .manageExtensions: onShowSettingsTab?(.extensions)
        case .showSiteControls: window.overlay = .siteControls
        case .showShortcuts: window.overlay = .shortcuts
        case .showWelcome, .importFromArc: window.overlay = .welcome
        case .newWindow: onNewWindow?()
        case .newIncognito: onOpenIncognito?()
        case .newProbe: onOpenProbe?(URL(string: "about:blank")!)
        case .resetPinned: resetPinned(in: window)
        case .collapseFolders: setAllFolders(expanded: false, in: window)
        case .expandFolders: setAllFolders(expanded: true, in: window)
        case .resetTab: if let id = curID { resetTab(id, in: window) }
        case .setDefaultBrowser: DefaultBrowser.request { ok in window.showToast(ok ? "Cosmos is now your default browser" : "Choose Cosmos in the system prompt", symbol: ok ? "checkmark.seal.fill" : "info.circle") }
        case .toggleDeveloperTools:
            rt?.showInspector()
        case .openInDefaultBrowser:
            if let url = currentURL(in: window) { openInOtherBrowser(url) }
        }
    }

    func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    func printPage(_ rt: TabRuntime) {
        let op = rt.webView.printOperation(with: NSPrintInfo.shared)
        op.view?.frame = rt.webView.bounds
        if let window = rt.webView.window { op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) } else { op.run() }
    }

    func openViewSource(of url: URL, rt: TabRuntime?, in window: WindowState) {
        rt?.webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, let html = result as? String else { return }
                let escaped = html.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                let page = "<!doctype html><meta charset=utf-8><title>Source of \(url.host ?? "page")</title><body style=\"margin:0;background:#14121f;color:#d7d3f0;font:12.5px/1.55 ui-monospace,Menlo,monospace\"><pre style=\"margin:0;padding:18px;white-space:pre-wrap;word-break:break-all\">\(escaped)</pre>"
                guard let id = self.newTab(url: nil, in: window), let rt = self.runtime(forItem: id, in: window) else { return }
                rt.webView.loadHTMLString(page, baseURL: nil)
            }
        }
    }

    func openInOtherBrowser(_ url: URL) {
        let me = Bundle.main.bundleIdentifier
        let candidates = NSWorkspace.shared.urlsForApplications(toOpen: url).filter { Bundle(url: $0)?.bundleIdentifier != me }
        if let app = candidates.first {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

extension TabRuntime {
    /// Opens Web Inspector for this page (WKWebView exposes it through the context menu / a private selector).
    func showInspector() {
        let sel = NSSelectorFromString("_inspector")
        if webView.responds(to: sel), let inspector = webView.perform(sel)?.takeUnretainedValue() as? NSObject {
            let show = NSSelectorFromString("show")
            if inspector.responds(to: show) { inspector.perform(show) }
        }
    }
}

enum DefaultBrowser {
    static var isDefault: Bool {
        guard let id = Bundle.main.bundleIdentifier, let url = URL(string: "https://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return Bundle(url: app)?.bundleIdentifier == id
    }

    /// Asks macOS to make Cosmos the handler for web links (the system shows its own confirmation).
    static func request(completion: @escaping (Bool) -> Void) {
        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "http") { error in
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "https") { error2 in
                DispatchQueue.main.async { completion(error == nil && error2 == nil) }
            }
        }
    }
}
