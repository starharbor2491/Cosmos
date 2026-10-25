import AppKit
import WebKit
import CosmosCore

// MARK: - Live pages

extension BrowserStore {
    func runtime(forItem id: UUID, in window: WindowState?) -> TabRuntime? {
        runtimes[RuntimeKey(item: id, profile: profileID(forItem: id, in: window))]
    }

    /// The page behind a sidebar tab, created on first use. `configuration` is WebKit's own, for `window.open` children.
    @discardableResult
    func ensureRuntime(forItem id: UUID, in window: WindowState?, configuration: WKWebViewConfiguration? = nil, load: Bool = true) -> TabRuntime? {
        guard let item = workspace.item(id), item.isTab else { return nil }
        let pid = profileID(forItem: id, in: window)
        let key = RuntimeKey(item: id, profile: pid)
        if let existing = runtimes[key] { return existing }
        let env = environment(forProfile: pid)
        let rt = TabRuntime(itemID: id, profileID: pid, configuration: configuration ?? env.makeConfiguration(), host: self)
        runtimes[key] = rt
        runtimeRevision += 1
        extensionCenter?.tabOpened(rt)
        if configuration == nil, load, let url = item.tab?.url { rt.load(url) }
        return rt
    }

    func discardRuntime(forItem id: UUID) {
        for key in runtimes.keys where key.item == id {
            if let rt = runtimes[key] { extensionCenter?.tabClosed(rt) }
            runtimes[key]?.tearDown()
            runtimes[key] = nil
        }
        runtimeRevision += 1
    }

    func discardRuntimes(under id: UUID) {
        for t in workspace.tabs(under: id) { discardRuntime(forItem: t.id) }
    }

    /// Items currently on screen in some window (these must never be discarded or archived).
    var visibleTabIDs: Set<UUID> {
        var out = Set<UUID>()
        for w in windows {
            for (_, sel) in w.selection { out.formUnion(workspace.tabs(under: sel).map(\.id)) }
        }
        return out
    }

    func discardIdleRuntimes() {
        guard settings.memorySaverMinutes > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(settings.memorySaverMinutes) * 60)
        let keep = visibleTabIDs
        for (key, rt) in runtimes where !keep.contains(key.item) {
            guard rt.lastActivity < cutoff, !rt.isAudible, !rt.isLoading, !rt.isCapturing,
                  !BehaviorConfig.shared.keepsAlive(rt.url) else { continue }
            discardRuntime(forItem: key.item)
        }
    }

    // MARK: Selection

    func currentTabItemID(in window: WindowState) -> UUID? {
        guard let sel = window.selectedItemID, let item = workspace.item(sel) else { return nil }
        switch item.content {
        case .tab: return sel
        case .split(let s): return s.focusedChildID ?? item.childIDs.first
        default: return nil
        }
    }

    func currentRuntime(in window: WindowState) -> TabRuntime? {
        currentTabItemID(in: window).flatMap { runtime(forItem: $0, in: window) }
    }

    func currentURL(in window: WindowState) -> URL? {
        guard let id = currentTabItemID(in: window) else { return nil }
        return runtime(forItem: id, in: window)?.url ?? workspace.item(id)?.tab?.url
    }

    func select(_ id: UUID, in window: WindowState) {
        guard let item = workspace.item(id), !item.isContainer else { return }
        // A pane of a split selects its split and focuses that pane.
        var target = id
        if let pid = item.parentID, workspace.item(pid)?.isSplit == true {
            target = pid
            edit { $0.setSplit(pid) { $0.focusedChildID = id } }
        }
        if let sid = workspace.spaceID(of: target), sid != window.focusedSpaceID { switchSpace(to: sid, in: window) }

        let previousTabs = window.selectedItemID.map { workspace.tabs(under: $0).map(\.id) } ?? []
        let previousRuntime = extensionCenter == nil ? nil : currentRuntime(in: window)
        window.selectedItemID = target
        window.noteSelected(target)
        if case .commandBar = window.overlay { window.overlay = nil }

        let now = Date()
        for t in workspace.tabs(under: target) {
            ensureRuntime(forItem: t.id, in: window)
        }
        if let focused = currentTabItemID(in: window) {
            edit { $0.updateTab(focused) { $0.lastActiveAt = now } }
            runtime(forItem: focused, in: window)?.lastActivity = now
            runtime(forItem: focused, in: window)?.exitPictureInPicture()
            if let center = extensionCenter, let now = runtime(forItem: focused, in: window), now !== previousRuntime {
                center.tabActivated(now, previous: previousRuntime)
            }
        }
        // Leaving a tab that is playing video: float it (Auto Picture-in-Picture).
        if settings.autoPictureInPicture {
            let nowTabs = Set(workspace.tabs(under: target).map(\.id))
            for old in previousTabs where !nowTabs.contains(old) {
                if let rt = runtime(forItem: old, in: window), rt.hasPlayingVideo, !BehaviorConfig.shared.disallowsAutoPiP(rt.url) {
                    rt.enterPictureInPicture()
                }
            }
        }
        window.statusText = nil
        saveSession()
    }

    func deselect(in window: WindowState) {
        window.selectedItemID = nil
        saveSession()
    }

    // MARK: Opening

    @discardableResult
    func newTab(url: URL?, in window: WindowState, activate: Bool = true, spaceID: UUID? = nil) -> UUID? {
        let sid = spaceID ?? window.focusedSpaceID
        guard let space = workspace.space(sid) else { return nil }
        guard let id = edit({ $0.addTab(url: url, under: space.unpinnedRootID, at: 0) }) else { return nil }
        if activate {
            select(id, in: window)
        } else {
            ensureRuntime(forItem: id, in: window)
        }
        return id
    }

    /// Navigates the current tab, or opens a new one when nothing is selected.
    func navigateCurrent(to url: URL, in window: WindowState) {
        if let rt = currentRuntime(in: window) {
            rt.load(url)
        } else if let id = currentTabItemID(in: window), let rt = ensureRuntime(forItem: id, in: window, load: false) {
            rt.load(url)
        } else {
            newTab(url: url, in: window)
        }
    }

    func openFromCommandBar(_ url: URL, mode: CommandBarMode, typed: Bool, in window: WindowState) {
        if typed { window.pendingTypedNavigation = true }
        switch mode {
        case .newTab: newTab(url: url, in: window)
        case .currentTab: navigateCurrent(to: url, in: window)
        }
        window.overlay = nil
    }

    // MARK: Closing & archiving

    func closeSelected(in window: WindowState) {
        guard let id = currentTabItemID(in: window) else {
            if window.selectedItemID == nil { closeWindowRequested(window) }
            return
        }
        closeTab(id, in: window)
    }

    func closeTab(_ id: UUID, in window: WindowState?) {
        guard workspace.item(id) != nil else { return }
        let selected = window?.selectedItemID
        let neighbour = window.flatMap { neighbourAfterClosing(id, in: $0) }
        switch workspace.section(of: id) {
        case .favorites, .pinned:
            // Pinned tabs and Favorites aren't closed, they go to sleep (and come back at their last address).
            discardRuntime(forItem: id)
            if let window, selected == id || workspace.item(id)?.parentID == selected { selectFallback(neighbour, in: window) }
        default:
            archiveItems([id], reason: .closed, in: window)
            if let window { selectFallback(neighbour, in: window) }
        }
    }

    /// Where selection goes when `id` disappears: the next row, else the previous, else the last-used tab.
    func neighbourAfterClosing(_ id: UUID, in window: WindowState) -> UUID? {
        guard let space = workspace.space(window.focusedSpaceID) else { return nil }
        let order = workspace.navigationOrder(in: space)
        let removing = Set(workspace.tabs(under: id).map(\.id))
        // If a pane of a split is closing, the split itself stays selected.
        if let pid = workspace.item(id)?.parentID, workspace.item(pid)?.isSplit == true,
           (workspace.item(pid)?.childIDs.count ?? 0) > 2 { return pid }
        if let idx = order.firstIndex(of: id) {
            let rest = order.enumerated().filter { !removing.contains($0.element) }
            if let after = rest.first(where: { $0.offset > idx }) { return after.element }
            if let before = rest.last(where: { $0.offset < idx }) { return before.element }
        }
        return window.recent.first { $0 != id && workspace.item($0) != nil && !removing.contains($0) }
    }

    func selectFallback(_ candidate: UUID?, in window: WindowState) {
        if let c = candidate, workspace.item(c) != nil { select(c, in: window) }
        else if let sel = window.selectedItemID, workspace.item(sel) != nil { return }
        else { deselect(in: window) }
    }

    func archiveItems(_ ids: [UUID], reason: ArchiveReason, in window: WindowState?) {
        let toRemove = ids.filter { workspace.item($0) != nil }
        for id in toRemove { discardRuntimes(under: id) }
        let removed = edit { $0.archive(toRemove, reason: reason) }
        guard !removed.isEmpty else { return }
        if isIncognito { return }
        // A blank "New Tab" that never loaded anything isn't worth keeping.
        let entries = removed.filter { !($0.root?.isTab == true && $0.url == nil) }
        for e in entries.reversed() { archive.add(e) }
        if reason == .closed { recentlyClosed.insert(contentsOf: entries.map(\.id), at: 0) }
        // Selection that vanished with its item.
        for w in windows {
            for (space, sel) in w.selection where workspace.item(sel) == nil { w.selection[space] = nil }
        }
    }

    func clearUnpinned(in window: WindowState) {
        guard let space = workspace.space(window.focusedSpaceID) else { return }
        let keep = Set(window.selectedItemID.map { workspace.tabs(under: $0).map(\.id) } ?? [])
        let ids = workspace.unpinned(in: space).map(\.id).filter { id in workspace.tabs(under: id).allSatisfy { !keep.contains($0.id) } }
        guard !ids.isEmpty else { window.showToast("Nothing to clear", symbol: "tray"); return }
        archiveItems(ids, reason: .cleared, in: window)
        window.showToast("Archived \(ids.count) tab\(ids.count == 1 ? "" : "s")", symbol: "archivebox.fill")
    }

    func reopenLastClosed(in window: WindowState) {
        guard let entry = archive.entries.first(where: { $0.reason == .closed }) ?? archive.entries.first(where: { $0.reason != .imported }) else {
            window.showToast("No recently closed tabs", symbol: "clock.arrow.circlepath"); return
        }
        restore(entry, in: window)
    }

    func restore(_ entry: ArchivedItem, in window: WindowState) {
        let spaceID = entry.spaceID.flatMap { workspace.space($0) }?.id ?? window.focusedSpaceID
        guard let space = workspace.space(spaceID) else { return }
        let isFolder = entry.root?.isFolder == true
        let parent = isFolder ? space.pinnedRootID : space.unpinnedRootID
        guard let rid = edit({ $0.restore(entry.items, under: parent, at: isFolder ? nil : 0) }) else { return }
        archive.remove(entry.id)
        recentlyClosed.removeAll { $0 == entry.id }
        select(rid, in: window)
    }

    func deleteArchived(_ id: UUID) { archive.remove(id) }

    func clearArchive() { archive.entries.removeAll() }

    func runAutoArchive() {
        guard !isIncognito, archive.interval != .never else { return }
        var exempt = visibleTabIDs
        for (key, rt) in runtimes where rt.isAudible || rt.isLoading || rt.isCapturing { exempt.insert(key.item) }
        var all: [UUID] = []
        for space in workspace.spaces {
            all += workspace.idleUnpinnedItems(in: space.id, interval: archive.interval, exempt: exempt)
        }
        if !all.isEmpty { archiveItems(all, reason: .auto, in: nil) }
    }

    func closeWindowRequested(_ window: WindowState) {
        NSApp.keyWindow?.performClose(nil)
    }

    // MARK: Editing the tree

    func togglePin(_ id: UUID, in window: WindowState) {
        switch workspace.section(of: id) {
        case .pinned: edit { $0.unpin(id) }
        case .unpinned: edit { $0.pin(id) }
        case .favorites:
            if let sid = workspace.spaces.first(where: { $0.id == window.focusedSpaceID })?.id { edit { $0.unfavorite(id, into: sid) } }
        case nil: break
        }
    }

    func toggleFavorite(_ id: UUID, in window: WindowState) {
        if workspace.section(of: id) == .favorites {
            edit { $0.unfavorite(id, into: window.focusedSpaceID) }
        } else if workspace.item(id)?.isTab == true {
            edit { $0.favorite(id) }
        }
    }

    func moveItem(_ id: UUID, under parent: UUID, at index: Int?) {
        let before = workspace.item(id)?.parentID
        let moved = edit { $0.move(id, under: parent, at: index) }
        // Crossing profiles (e.g. a tab dragged to another space) needs a fresh page in the new profile.
        if moved, before != parent { discardRuntimes(under: id) }
    }

    func newFolder(in window: WindowState, title: String = "New Folder") {
        guard let space = workspace.space(window.focusedSpaceID) else { return }
        edit { _ = $0.addFolder(title: title, under: space.pinnedRootID) }
    }

    func rename(_ id: UUID, to title: String?) { edit { $0.rename(id, to: title) } }

    func duplicate(_ id: UUID, in window: WindowState) {
        guard let item = workspace.item(id), let tab = item.tab, let space = workspace.space(window.focusedSpaceID) else { return }
        let url = runtime(forItem: id, in: window)?.url ?? tab.url
        newTab(url: url, in: window, spaceID: space.id)
    }

    func resetTab(_ id: UUID, in window: WindowState) {
        guard let home = workspace.item(id)?.tab?.homeURL else { return }
        edit { $0.updateTab(id) { $0.url = home } }
        if let rt = runtime(forItem: id, in: window) { rt.load(home) }
    }

    func resetPinned(in window: WindowState) {
        let changed = edit { $0.resetPinned(in: window.focusedSpaceID) }
        for id in changed {
            if let rt = runtime(forItem: id, in: window), let home = workspace.item(id)?.tab?.homeURL { rt.load(home) }
        }
        window.showToast(changed.isEmpty ? "Pinned tabs are already at home" : "Reset \(changed.count) pinned tab\(changed.count == 1 ? "" : "s")", symbol: "arrow.counterclockwise")
    }

    func toggleMute(_ id: UUID, in window: WindowState) {
        guard let rt = runtime(forItem: id, in: window) else { return }
        rt.isMuted.toggle()
        edit { $0.updateTab(id) { $0.isMuted = rt.isMuted } }
    }

    func folderToggle(_ id: UUID) {
        guard case .folder(let f)? = workspace.item(id)?.content else { return }
        edit { $0.setFolderExpanded(id, !f.isExpanded) }
    }

    func setAllFolders(expanded: Bool, in window: WindowState) {
        guard let space = workspace.space(window.focusedSpaceID) else { return }
        let folders = workspace.descendants(of: space.pinnedRootID).filter(\.isFolder)
        edit { ws in for f in folders { ws.setFolderExpanded(f.id, expanded) } }
    }

    // MARK: Split view

    func addSplit(in window: WindowState, with url: URL? = nil) {
        guard let current = currentTabItemID(in: window) else { return }
        // Choose what goes in the new pane: the given link, or a blank tab ready for the command bar.
        guard let space = workspace.space(window.focusedSpaceID),
              let newID = edit({ $0.addTab(url: url, under: space.unpinnedRootID, at: 0) }) else { return }
        guard edit({ $0.combineIntoSplit(current, newID) }) != nil else {
            edit { _ = $0.remove(newID) }
            window.showToast("A split view holds up to four tabs", symbol: "rectangle.split.2x2")
            return
        }
        if let sid = workspace.item(newID)?.parentID { select(sid, in: window) }
        focusPane(newID, in: window)
        if url == nil { window.overlay = .commandBar(.currentTab) }
    }

    func focusPane(_ id: UUID, in window: WindowState) {
        guard let pid = workspace.item(id)?.parentID, workspace.item(pid)?.isSplit == true else { return }
        edit { $0.setSplit(pid) { $0.focusedChildID = id } }
        ensureRuntime(forItem: id, in: window)
        runtime(forItem: id, in: window)?.webView.window?.makeFirstResponder(runtime(forItem: id, in: window)?.webView)
    }

    func closeFocusedPane(in window: WindowState) {
        guard let id = currentTabItemID(in: window), let pid = workspace.item(id)?.parentID, workspace.item(pid)?.isSplit == true else { return }
        let neighbour = workspace.item(pid)?.childIDs.first { $0 != id }
        archiveItems([id], reason: .closed, in: window)
        guard let n = neighbour, let item = workspace.item(n) else { return }
        // Still a split (three or four panes before) -> select the split, else the lone remaining tab.
        if let pid = item.parentID, workspace.item(pid)?.isSplit == true { select(pid, in: window) } else { select(n, in: window) }
    }

    func separateFromSplit(_ id: UUID, in window: WindowState) {
        if edit({ $0.separateFromSplit(id) }) { select(id, in: window) }
    }

    func splitWith(_ otherID: UUID, dragged: UUID, in window: WindowState) {
        guard edit({ $0.combineIntoSplit(otherID, dragged) }) != nil else {
            window.showToast("Can't split these tabs", symbol: "rectangle.split.2x1"); return
        }
        if let sid = workspace.item(dragged)?.parentID { select(sid, in: window) }
    }

    // MARK: Spaces

    func switchSpace(to id: UUID, in window: WindowState) {
        guard id != window.focusedSpaceID, let target = workspace.spaceIndex(id) else { return }
        let from = workspace.spaceIndex(window.focusedSpaceID) ?? 0
        window.spaceDirection = target >= from ? 1 : -1
        window.focusedSpaceID = id
        if let sel = window.selection[id], workspace.item(sel) != nil {
            for t in workspace.tabs(under: sel) { ensureRuntime(forItem: t.id, in: window) }
        } else {
            window.selection[id] = nil
        }
        saveSession()
    }

    func cycleSpace(_ delta: Int, in window: WindowState) {
        guard let idx = workspace.spaceIndex(window.focusedSpaceID), workspace.spaces.count > 1 else { return }
        let n = workspace.spaces.count
        switchSpace(to: workspace.spaces[(idx + delta + n) % n].id, in: window)
    }

    func switchSpace(number: Int, in window: WindowState) {
        guard number >= 1, number <= workspace.spaces.count else { return }
        switchSpace(to: workspace.spaces[number - 1].id, in: window)
    }

    @discardableResult
    func addSpace(title: String, icon: SpaceIcon, theme: SpaceTheme, profileID: UUID?, in window: WindowState?) -> UUID {
        let id = edit { $0.addSpace(title: title, icon: icon, theme: theme, profileID: profileID) }
        if let window { switchSpace(to: id, in: window) }
        return id
    }

    func updateSpace(_ id: UUID, _ change: (inout Space) -> Void) {
        edit { ws in
            guard let i = ws.spaceIndex(id) else { return }
            change(&ws.spaces[i])
        }
    }

    func deleteSpace(_ id: UUID, in window: WindowState) {
        guard workspace.spaces.count > 1, let space = workspace.space(id) else { return }
        // Keep what's in it: tabs go to the archive rather than vanishing.
        let ids = workspace.unpinned(in: space).map(\.id) + workspace.pinned(in: space).map(\.id)
        archiveItems(ids, reason: .cleared, in: nil)
        let wasFocused = window.focusedSpaceID == id
        let neighbour = workspace.spaces.first { $0.id != id }?.id
        edit { _ = $0.removeSpace(id) }
        for w in windows {
            w.selection[id] = nil
            if w.focusedSpaceID == id, let n = neighbour { w.focusedSpaceID = n }
        }
        if wasFocused { saveSession() }
    }

    func moveSpace(_ id: UUID, by delta: Int) {
        edit { ws in
            guard let i = ws.spaceIndex(id) else { return }
            let j = min(max(i + delta, 0), ws.spaces.count - 1)
            guard i != j else { return }
            ws.spaces.insert(ws.spaces.remove(at: i), at: j)
        }
    }

    func moveTab(_ id: UUID, toSpace spaceID: UUID, in window: WindowState) {
        guard let space = workspace.space(spaceID), workspace.item(id) != nil else { return }
        let wasSelected = window.selectedItemID == id
        moveItem(id, under: space.unpinnedRootID, at: 0)
        if wasSelected { window.selection[window.focusedSpaceID] = nil; switchSpace(to: spaceID, in: window); select(id, in: window) }
    }

    func changeProfile(ofSpace id: UUID, to profileID: UUID) {
        guard let space = workspace.space(id), space.profileID != profileID else { return }
        updateSpace(id) { $0.profileID = profileID }
        for t in workspace.tabs(under: space.pinnedRootID) + workspace.tabs(under: space.unpinnedRootID) { discardRuntime(forItem: t.id) }
    }

    @discardableResult
    func addProfile(named name: String) -> UUID {
        let p = Profile(name: name)
        edit { $0.profiles.append(p) }
        return p.id
    }
}

// MARK: - Tab host

extension BrowserStore {
    func window(showing itemID: UUID) -> WindowState? {
        windows.first { w in w.selection.values.contains { workspace.tabs(under: $0).contains { $0.id == itemID } } }
    }

    public func tabDidChange(_ tab: TabRuntime) {
        guard !tab.isEphemeral, case .tab(let data)? = workspace.item(tab.itemID)?.content else { return }
        let url = tab.url
        let urlChanged = url != nil && url != data.url && url?.scheme != "about" && !(tab.loadFailed && url == data.url)
        let title = tab.title
        let titleChanged = !title.isEmpty && title != data.pageTitle
        if urlChanged || titleChanged { extensionCenter?.tabChanged(tab) }
        guard urlChanged || titleChanged || (tab.isMuted != data.isMuted && tab.isMuted) else { return }
        edit { ws in
            ws.updateTab(tab.itemID) {
                if urlChanged { $0.url = url }
                if titleChanged { $0.pageTitle = title }
            }
        }
    }

    public func tabDidFinishLoading(_ tab: TabRuntime) {
        extensionCenter?.tabChanged(tab, loading: true)
        guard !isIncognito, let url = tab.url else { return }
        let w = window(showing: tab.itemID)
        let typed = w?.pendingTypedNavigation ?? false
        if typed { w?.pendingTypedNavigation = false }
        history.record(url: url, title: tab.title, typed: typed)
        history.updateTitle(url: url, title: tab.title)
    }

    public func tabIsPinnedOrFavorite(_ tab: TabRuntime) -> Bool {
        switch workspace.section(of: tab.itemID) {
        case .favorites, .pinned: return true
        default: return false
        }
    }

    public func tab(_ tab: TabRuntime, open url: URL, as disposition: LinkDisposition) {
        guard let w = window(showing: tab.itemID) ?? activeWindow else { return }
        switch disposition {
        case .currentTab: tab.load(url)
        case .newTabForeground: newTab(url: url, in: w)
        case .newTabBackground:
            newTab(url: url, in: w, activate: false)
            w.showToast("Opened in the background", symbol: "arrow.up.right.square")
        case .peek: openPeek(url, from: tab.itemID, in: w)
        case .split: addSplit(in: w, with: url)
        case .download:
            tab.webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    download.delegate = self.downloads
                    self.downloads.began(download, from: tab.webView)
                }
            }
        }
    }

    public func tab(_ tab: TabRuntime, createChildWith configuration: WKWebViewConfiguration, features: WKWindowFeatures) -> WKWebView? {
        guard let w = window(showing: tab.itemID) ?? activeWindow else { return nil }
        // Script-sized windows (OAuth consent, payment sheets) get their own small window, like a real popup.
        let isPopup = features.width != nil || features.height != nil
        if isPopup {
            let rt = TabRuntime(itemID: UUID(), profileID: tab.profileID, configuration: configuration, host: self)
            rt.isEphemeral = true
            onPopupWindow?(rt, features)
            return rt.webView
        }
        guard let id = newTab(url: nil, in: w, activate: true),
              let rt = ensureRuntime(forItem: id, in: w, configuration: configuration, load: false) else { return nil }
        return rt.webView
    }

    public func tabRequestsClose(_ tab: TabRuntime) {
        if tab.isEphemeral {
            for w in windows where w.peek?.runtime === tab { closePeek(in: w) }
            NSApp.windows.first { $0.contentView?.subviews.contains(tab.webView) == true }?.close()
            return
        }
        closeTab(tab.itemID, in: window(showing: tab.itemID) ?? activeWindow)
    }

    public func tabRequestsEscape(_ tab: TabRuntime) {
        guard let w = window(showing: tab.itemID) ?? activeWindow else { return }
        if w.peek?.runtime === tab { closePeek(in: w) }
        else if w.overlay == .find { w.overlay = nil }
    }

    public func tab(_ tab: TabRuntime, boostZoomFor host: String) -> Double? {
        boosts.boosts(for: host, profileID: tab.profileID).compactMap(\.zoom).first
    }

    public func tab(_ tab: TabRuntime, remember allowed: Bool?, forPermission key: String) {
        guard !isIncognito else { return }
        settings.permissionDecisions[key] = allowed
    }
}

// MARK: - Peek

extension BrowserStore {
    func openPeek(_ url: URL, from itemID: UUID?, in window: WindowState) {
        closePeek(in: window)
        let pid = itemID.flatMap { profileID(forItem: $0, in: window) } ?? workspace.space(window.focusedSpaceID)?.profileID
        let env = environment(forProfile: isIncognito ? nil : pid)
        let rt = TabRuntime(itemID: UUID(), profileID: isIncognito ? nil : pid, configuration: env.makeConfiguration(), host: self)
        rt.isEphemeral = true
        rt.load(url)
        window.peek = PeekSession(runtime: rt, openedFrom: itemID)
        window.overlay = nil
    }

    func closePeek(in window: WindowState) {
        guard let peek = window.peek else { return }
        peek.runtime.tearDown()
        window.peek = nil
    }

    /// "Open in Space" (⌘O): keep the Peek's page as a real tab, without reloading it.
    func promotePeek(in window: WindowState) {
        guard let peek = window.peek, let space = workspace.space(window.focusedSpaceID) else { return }
        let rt = peek.runtime
        let url = rt.url
        guard let id = edit({ $0.addTab(url: url, title: rt.title, under: space.unpinnedRootID, at: 0) }) else { return }
        rt.isEphemeral = false
        rt.adopt(itemID: id)
        runtimes[RuntimeKey(item: id, profile: rt.profileID)] = rt
        runtimeRevision += 1
        window.peek = nil
        select(id, in: window)
    }
}

/// Which tab-level behaviours are special for which sites (never suspend mail, no auto-PiP in meetings, ...).
final class BehaviorConfig: @unchecked Sendable {
    static let shared = BehaviorConfig()

    private let keepAliveHosts: [String] = [
        "mail.google.com", "calendar.google.com", "outlook.office.com", "outlook.live.com", "app.slack.com", "web.whatsapp.com",
        "web.telegram.org", "discord.com", "x.com", "twitter.com", "notion.so", "linear.app", "meet.google.com", "teams.microsoft.com",
        "music.youtube.com", "open.spotify.com", "music.apple.com", "figma.com", "docs.google.com",
    ]
    private let noPiPHosts: [String] = ["app.slack.com", "meet.google.com", "teams.microsoft.com", "zoom.us", "discord.com"]

    func keepsAlive(_ url: URL?) -> Bool { match(url, keepAliveHosts) }
    func disallowsAutoPiP(_ url: URL?) -> Bool { match(url, noPiPHosts) }

    private func match(_ url: URL?, _ hosts: [String]) -> Bool {
        guard let h = url?.host?.lowercased() else { return false }
        return hosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }
}
