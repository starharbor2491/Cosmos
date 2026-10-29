import AppKit
import CosmosCore
import CosmosEngine

/// The extensions of the default profile (the only one Chromium loads them into). Chromium runs them with its own
/// `chrome.*` APIs, from a copy of each with Cosmos's scripts ahead of the extension's own (`ExtensionStage`). Cosmos's
/// pages are not Chrome tabs, so what an extension asks of tabs and windows Cosmos answers, by tab ids of its own and
/// within the extension's permissions; what Chrome would draw in its toolbar and menus (the button, its badge and popup,
/// `contextMenus` items, `commands` shortcuts) is mirrored here so Cosmos can draw it, and Cosmos's clicks go back to the
/// extension.
@MainActor
final class ChromiumExtensionHost: EngineExtensions {
    /// Weak: Cosmos keeps the extensions (`EngineProfile.extensions`) and their tasks, which can outlast the profile.
    private(set) weak var profile: ChromiumProfile?
    var onChange: (() -> Void)?
    var onNotification: ((String, EngineNotification) -> Void)?
    var onNotificationClosed: ((String, String) -> Void)?
    var tabsHost: ExtensionTabsHost?

    /// What an extension may reach, from its manifest.
    struct Permissions {
        var api: Set<String> = []
        /// Its host permissions. As in Chrome, the sites its content scripts run on are not among them: they let those
        /// scripts run, not the extension read a tab's address or put scripts in it.
        var hosts: [ExtensionMatchPattern] = []

        init(_ manifest: [String: Any]) {
            let listed = manifest["permissions"] as? [String] ?? []
            api = Set(listed.filter { !$0.contains("://") && $0 != "<all_urls>" })
            let patterns = (manifest["host_permissions"] as? [String] ?? []) + listed.filter { $0.contains("://") || $0 == "<all_urls>" }
            hosts = patterns.compactMap(ExtensionMatchPattern.init)
        }

        /// The permission (any of them) an API needs, as Chrome asks for it: without it the extension has no such API.
        /// The shim only makes an API that the manifest asks for, but the extension's scripts can post to Cosmos directly.
        static func needed(for api: String) -> [String]? {
            switch api {
            case "menuCreate", "menuUpdate", "menuRemove", "menuRemoveAll": ["contextMenus", "menus"]
            case "notification", "notificationClosed": ["notifications"]
            case "sidePanelOptions", "sidePanelBehavior", "sidePanelOpen": ["sidePanel"]
            case "authFlow": ["identity"]
            case _ where api.hasPrefix("scripting."): ["scripting"]
            default: nil
            }
        }

        func allows(_ api: String) -> Bool { Self.needed(for: api).map { !self.api.isDisjoint(with: $0) } ?? true }

        func reaches(_ url: URL) -> Bool { hosts.contains { $0.matches(url) } }
        /// Every site (`<all_urls>`, `*://*/*`), which capturing a tab needs without activeTab.
        var reachesEverySite: Bool { hosts.contains { $0.host == "*" && ($0.scheme == "<all>" || $0.scheme == "*") } }
    }

    struct Loaded {
        let id: String
        let folder: URL
        /// The copy Chromium loaded (ExtensionStage).
        var staged: URL
        var permissions: Permissions
        /// The extension's name, as its notifications say who they are from.
        var name = ""
        var title: String
        var icon: Data?
        var popup: String
        var enabled = true
        var badge: [Int: String] = [:]
        var badgeColor: [Int: RGBA] = [:]
        var tabTitle: [Int: String] = [:]
        var tabIcon: [Int: Data] = [:]
        var tabPopup: [Int: String] = [:]
        var tabEnabled: [Int: Bool] = [:]
        var menus: [ExtensionMenuItem] = []
        /// `chrome.sidePanel`: the panel's page and whether it is on, by tab; whether the button opens it.
        var sidePanelPath: [Int: String] = [:]
        var sidePanelEnabled: [Int: Bool] = [:]
        var opensSidePanelOnAction = false
        var commands: [ExtensionCommand] = []
        /// What applies to every tab (tab id -1 in these tables).
        static let everyTab = -1
    }

    private var folders: [URL] = []
    private var loaded: [String: Loaded] = [:]
    /// Extension service workers Cosmos is attached to: session → extension id.
    private var workers: [String: String] = [:]
    /// The workers whose Cosmos script has run (Cosmos attaches as a worker starts, before its first line).
    private var readyWorkers: Set<String> = []
    /// Those waiting for an extension's worker to be ready, by extension id.
    private var workerWaiters: [String: [() -> Void]] = [:]
    /// Cosmos's `chrome.tabs` id of each page, and the `frameId` of each frame of Chromium's that is not a main frame.
    private let tabNumbers = NSMapTable<ChromiumPage, NSNumber>.weakToStrongObjects()
    private var lastTabNumber = 0
    private var frameNumbers: [String: Int] = [:]
    /// activeTab: the tabs a click on an extension's button, menu item or shortcut gave it, with the site each was on then.
    private var activeTabs: [String: [Int: String]] = [:]
    /// What the extensions last heard of each tab, to tell them what changed.
    private struct Seen: Equatable {
        var windowID: Int, index: Int, isActive: Bool, isPinned: Bool
        var url: String?, title: String, isLoading: Bool
    }
    private var lastSeen: [Int: Seen] = [:]
    private var diffScheduled = false

    init(profile: ChromiumProfile) { self.profile = profile }

    // MARK: Loading

    func browserStarted() async {
        workers = [:]
        readyWorkers = []
        for folder in folders { _ = try? await loadIntoChromium(folder) }
    }

    func browserStopped() {
        workers = [:]
        readyWorkers = []
    }

    func load(folder: URL) async throws -> String {
        if !folders.contains(folder) { folders.append(folder) }
        let wasLoaded = loaded.values.contains { $0.folder == folder }
        guard let profile, await profile.start() else { throw CDPError(code: -3, message: "Chromium is not running") }
        // Starting Chromium loads every folder, this one too: a second load now would replace the worker it just started.
        if !wasLoaded, let id = loaded.first(where: { $0.value.folder == folder })?.key { return id }
        return try await loadIntoChromium(folder)
    }

    static let shim: String? = resource("extension-shim")
    static let contentShim: String? = resource("extension-content")
    private static func resource(_ name: String) -> String? {
        Bundle.module.url(forResource: name, withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    private func loadIntoChromium(_ folder: URL) async throws -> String {
        guard let c = profile?.connection, let stages = profile?.extensionStages else { throw CDPError.closed }
        guard let shim = Self.shim, let content = Self.contentShim else { throw CDPError(code: -4, message: "Cosmos's extension scripts are missing") }
        // The copy's folder is named after the extension's own, so its id (which Chromium makes from the folder's path) is
        // the same each time Cosmos starts, and its storage with it.
        let staged = stages.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        try ExtensionStage.stage(folder, to: staged, scripts: .init(worker: shim, content: content, page: shim))
        let r = try await c.send("Extensions.loadUnpacked", ["path": staged.path])
        guard let id = r["id"] as? String else { throw CDPError(code: -4, message: "Chromium did not load the extension") }
        // The bridge's key is no secret (it is in Cosmos's source): an extension that copies it has the bridge's id, took
        // its place and would be taken for it. Cosmos's own goes back in.
        guard id != ChromiumResources.bridgeExtensionID else {
            if let bridge = ChromiumResources.bridgeExtension { _ = try? await c.send("Extensions.loadUnpacked", ["path": bridge.path]) }
            throw CDPError(code: -4, message: "The extension claims to be part of Cosmos.")
        }
        let manifest = Self.manifest(folder)
        var item = loaded[id] ?? Loaded(id: id, folder: folder, staged: staged, permissions: Permissions(manifest), title: "", icon: nil, popup: "")
        item.staged = staged
        item.permissions = Permissions(manifest)
        let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any] ?? [:]
        item.title = action["default_title"] as? String ?? manifest["name"] as? String ?? ""
        let name = manifest["name"] as? String ?? ""
        item.name = name.isEmpty || name.hasPrefix("__MSG_") ? item.title : name
        item.popup = action["default_popup"] as? String ?? ""
        if let panel = (manifest["side_panel"] as? [String: Any])?["default_path"] as? String { item.sidePanelPath[Loaded.everyTab] = panel }
        item.icon = Self.iconData(action["default_icon"] ?? manifest["icons"], folder: folder)
        item.commands = Self.commands(manifest, extensionID: id)
        loaded[id] = item
        // The tabs there already are not new to the extension.
        if lastSeen.isEmpty { lastSeen = seen(tabs) }
        onChange?()
        return id
    }

    func unload(id: String) async {
        let item = loaded.removeValue(forKey: id)
        if let item { folders.removeAll { $0 == item.folder } }
        _ = try? await profile?.connection?.send("Extensions.uninstall", ["id": id])
        if let item { try? FileManager.default.removeItem(at: item.staged) }
        activeTabs[id] = nil
        onChange?()
    }

    static func manifest(_ folder: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// The best icon for a toolbar button (about 32 pixels) from a manifest's icon entry.
    static func iconData(_ entry: Any?, folder: URL) -> Data? {
        var path: String?
        if let s = entry as? String { path = s }
        if let sizes = entry as? [String: Any] {
            let ranked = sizes.compactMap { k, v -> (Int, String)? in (Int(k)).flatMap { size in (v as? String).map { (abs(size - 32), $0) } } }
            path = ranked.min { $0.0 < $1.0 }?.1
        }
        guard let path else { return nil }
        return file(path, in: folder).flatMap { try? Data(contentsOf: $0) }
    }

    /// A file of the extension's, inside its folder, not merely beside it (`/x/ext-other` starts with `/x/ext` too).
    static func file(_ path: String, in folder: URL) -> URL? {
        let file = folder.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path).standardizedFileURL
        let inside = folder.standardizedFileURL.path.hasSuffix("/") ? folder.standardizedFileURL.path : folder.standardizedFileURL.path + "/"
        return file.path.hasPrefix(inside) ? file : nil
    }

    static func commands(_ manifest: [String: Any], extensionID: String) -> [ExtensionCommand] {
        guard let commands = manifest["commands"] as? [String: Any] else { return [] }
        return commands.compactMap { name, value in
            guard let d = value as? [String: Any], let keys = d["suggested_key"] as? [String: Any],
                  let shortcut = (keys["mac"] ?? keys["default"]) as? String else { return nil }
            return ExtensionCommand(extensionID: extensionID, name: name, shortcut: shortcut, description: d["description"] as? String ?? name)
        }.sorted { $0.name < $1.name }
    }

    // MARK: Service workers

    /// Cosmos is attached to an extension's worker, which is running: Cosmos's script in it (the first the worker ran)
    /// gets its binding, and says what it had to say.
    func serviceWorkerAttached(target: String, session: String, url: String) {
        guard let c = profile?.connection else { return }
        let worker = URL(string: url)
        let id = worker?.scheme == "chrome-extension" ? worker?.host ?? "" : ""
        guard loaded[id] != nil else {
            c.post("Runtime.runIfWaitingForDebugger", session: session)
            return
        }
        workers[session] = id
        c.post("Runtime.addBinding", ["name": "__cosmosExt"], session: session)
        c.post("Runtime.enable", session: session)
        c.post("Runtime.evaluate", ["expression": "self.__cosmosReady && __cosmosReady()"], session: session)
        c.post("Runtime.runIfWaitingForDebugger", session: session)
    }

    private func workerReady(_ session: String, extension id: String) {
        readyWorkers.insert(session)
        workerWaiters.removeValue(forKey: id)?.forEach { $0() }
    }

    private func isReady(_ id: String) -> Bool { workers.contains { $0.value == id && readyWorkers.contains($0.key) } }

    /// A worker of the extension to talk to: the one Cosmos is attached to, or, when the extension's has not started (or
    /// Cosmos is not attached to it yet), the one Chromium starts now, within five seconds. As Chrome starts the worker for
    /// a click on the button, so does Cosmos.
    private func awaitWorker(of id: String) async -> Bool {
        if isReady(id) { return true }
        // Only when there is none: one that is starting would be replaced.
        if !workers.values.contains(id), let session = tabs.first?.page.sessionID {
            profile?.connection?.post("ServiceWorker.startWorker", ["scopeURL": "chrome-extension://\(id)/"], session: session)
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            var resumed = false
            let once = { if !resumed { resumed = true; c.resume() } }
            workerWaiters[id, default: []].append(once)
            Task { try? await Task.sleep(for: .seconds(5)); once() }
        }
        return isReady(id)
    }

    func handle(_ event: CDPEvent) {
        guard let session = event.sessionID, let id = workers[session], event.method == "Runtime.bindingCalled",
              let payload = event.params["payload"] as? String,
              let m = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return }
        report(m, from: id, session: session)
    }

    private func report(_ m: [String: Any], from id: String, session: String) {
        guard var item = loaded[id], item.permissions.allows(m["kind"] as? String ?? "") else { return }
        let tab = (m["tabId"] as? Int) ?? Loaded.everyTab
        switch m["kind"] as? String {
        case "call":
            answerCall(m, extension: id, session: session)
            return
        case "ready":
            workerReady(session, extension: id)
            return
        case "badge": item.badge[tab] = m["text"] as? String ?? ""
        case "badgeColor": item.badgeColor[tab] = Self.color(m["color"])
        case "title": item.tabTitle[tab] = m["title"] as? String ?? ""
        case "popup": item.tabPopup[tab] = m["popup"] as? String ?? ""
        case "enabled": item.tabEnabled[tab] = m["value"] as? Bool ?? true
        case "icon":
            if let dataURL = m["dataURL"] as? String, let comma = dataURL.firstIndex(of: ",") {
                item.tabIcon[tab] = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
            } else if let path = m["path"] as? String {
                item.tabIcon[tab] = Self.iconData(path, folder: item.folder)
            }
        case "menuCreate":
            guard let d = m["item"] as? [String: Any], let itemID = d["id"] as? String else { return }
            item.menus.removeAll { $0.itemID == itemID }
            if (d["visible"] as? Bool) != false, (d["type"] as? String) != "separator" {
                item.menus.append(ExtensionMenuItem(extensionID: id, itemID: itemID, title: d["title"] as? String ?? "",
                                                    contexts: d["contexts"] as? [String] ?? ["page"], parentID: d["parentId"] as? String))
            }
        case "menuUpdate":
            guard let itemID = m["id"] as? String, let changes = m["changes"] as? [String: Any],
                  let i = item.menus.firstIndex(where: { $0.itemID == itemID }) else { return }
            if let title = changes["title"] as? String { item.menus[i].title = title }
            if let contexts = changes["contexts"] as? [String] { item.menus[i].contexts = contexts }
            if (changes["visible"] as? Bool) == false { item.menus.remove(at: i) }
        case "menuRemove":
            let itemID = m["id"] as? String
            item.menus.removeAll { $0.itemID == itemID || $0.parentID == itemID }
        case "menuRemoveAll":
            item.menus.removeAll()
        case "notification":
            let note = EngineNotification(id: m["id"] as? String ?? "", title: m["title"] as? String ?? "", body: m["message"] as? String ?? "",
                                          source: item.name, icon: Self.iconData(m["iconUrl"], folder: item.folder), buttons: m["buttons"] as? [String] ?? [])
            onNotification?(id, note)
            return
        case "notificationClosed":
            onNotificationClosed?(id, m["id"] as? String ?? "")
            return
        case "sidePanelOptions":
            if let path = m["path"] as? String { item.sidePanelPath[tab] = path }
            if let enabled = m["enabled"] as? Bool { item.sidePanelEnabled[tab] = enabled }
        case "sidePanelBehavior":
            item.opensSidePanelOnAction = m["openOnAction"] as? Bool ?? false
        case "sidePanelOpen":
            onSidePanelRequest?(id, (m["tabId"] as? Int).flatMap(page(forTab:)))
            return
        case "authFlow":
            startAuthFlow(m, from: id)
            return
        default:
            return
        }
        loaded[id] = item
        onChange?()
    }

    static func color(_ value: Any?) -> RGBA? {
        if let a = value as? [Any], a.count >= 3, let r = a[0] as? Double, let g = a[1] as? Double, let b = a[2] as? Double {
            let alpha: Double = a.count > 3 ? (a[3] as? Double ?? 255) : 255
            return RGBA(r / 255.0, g / 255.0, b / 255.0, alpha / 255.0)
        }
        if let s = value as? String, s.hasPrefix("#") {
            var hex = String(s.dropFirst().prefix(6))
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            if hex.count == 6, let v = UInt32(hex, radix: 16) { return RGBA(hex: v) }
        }
        return nil
    }

    // MARK: Tabs

    /// The `chrome.tabs` id of `page`, given the first time it is asked for.
    func tabNumber(of page: ChromiumPage) -> Int {
        if let n = tabNumbers.object(forKey: page) { return n.intValue }
        lastTabNumber += 1
        tabNumbers.setObject(NSNumber(value: lastTabNumber), forKey: page)
        return lastTabNumber
    }

    /// A frame's `frameId`: 0 for the page's own.
    private func frameNumber(_ frame: String, in page: ChromiumPage) -> Int {
        if frame == page.mainFrame { return 0 }
        if let n = frameNumbers[frame] { return n }
        let n = frameNumbers.count + 1
        frameNumbers[frame] = n
        return n
    }

    private typealias Tab = (tab: ExtensionTab, page: ChromiumPage, id: Int)

    private var tabs: [Tab] {
        (tabsHost?.extensionTabs ?? []).compactMap { t in (t.page as? ChromiumPage).map { (t, $0, tabNumber(of: $0)) } }
    }

    private func tab(_ id: Int) -> Tab? { tabs.first { $0.id == id } }

    /// The page of a `chrome.tabs` id: one of Cosmos's tabs, or a page that is not (an extension's popup).
    private func page(forTab id: Int) -> ChromiumPage? {
        if let t = tab(id) { return t.page }
        let pages = tabNumbers.keyEnumerator().allObjects.compactMap { $0 as? ChromiumPage }
        return pages.first { tabNumbers.object(forKey: $0)?.intValue == id }
    }

    private var focusedWindow: Int? { tabsHost?.extensionWindows.first(where: \.isFocused)?.id }

    /// What an extension may read of a tab (its address and title): with the "tabs" permission, a host permission for
    /// the tab's site, the activeTab a click gave it, or for its own pages.
    private func mayRead(_ page: ChromiumPage, extension id: String, tab: Int) -> Bool {
        guard let item = loaded[id] else { return false }
        if item.permissions.api.contains("tabs") { return true }
        if let url = page.state.url, url.scheme == "chrome-extension", url.host == id { return true }
        return mayReach(page.state.url, extension: id, tab: tab)
    }

    /// Where an extension may run a script (and see into): a site its host permissions name, or, through activeTab, the
    /// site of the tab a click gave it, until the tab goes elsewhere.
    private func mayReach(_ url: URL?, extension id: String, tab: Int?) -> Bool {
        guard let item = loaded[id], let url, ["http", "https", "file", "ftp"].contains(url.scheme ?? "") else { return false }
        if item.permissions.reaches(url) { return true }
        if let tab, let origin = activeTabs[id]?[tab], origin == ChromiumProfile.origin(of: url) { return true }
        return false
    }

    /// A click on the extension's button, one of its menu items or one of its shortcuts, over `page`: with the
    /// activeTab permission, the extension may reach the tab's site now.
    private func grantActiveTab(_ id: String, page: ChromiumPage) {
        guard loaded[id]?.permissions.api.contains("activeTab") == true, let origin = page.state.url.flatMap(ChromiumProfile.origin(of:)) else { return }
        activeTabs[id, default: [:]][tabNumber(of: page)] = origin
    }

    /// A tab as the extension `id` may see it.
    /// A tab as the extension `id` sees it: with its address and title where it may read them, or always (`scrubbed`
    /// false) for the tab its own content script is in, as Chrome's `sender.tab` is.
    private func object(of t: Tab, for id: String, scrubbed: Bool = true) -> [String: Any] {
        var o: [String: Any] = ["id": t.id, "index": t.tab.index, "windowId": t.tab.windowID, "active": t.tab.isActive,
                                "highlighted": t.tab.isActive, "selected": t.tab.isActive, "pinned": t.tab.isPinned, "incognito": false,
                                "discarded": false, "autoDiscardable": true, "frozen": false, "groupId": -1, "audible": false,
                                "mutedInfo": ["muted": false], "status": t.page.state.isLoading ? "loading" : "complete",
                                "width": Int(t.page.view.bounds.width), "height": Int(t.page.view.bounds.height)]
        if !scrubbed || mayRead(t.page, extension: id, tab: t.id) {
            o["url"] = t.page.state.url?.absoluteString ?? ""
            o["title"] = t.page.state.title
        }
        return o
    }

    private func window(_ w: ExtensionWindow, populate: Bool, for id: String) -> [String: Any] {
        var o: [String: Any] = ["id": w.id, "focused": w.isFocused, "incognito": false, "alwaysOnTop": false, "type": "normal",
                                "state": "normal", "left": Int(w.frame.minX), "top": Int(w.frame.minY),
                                "width": Int(w.frame.width), "height": Int(w.frame.height)]
        if populate { o["tabs"] = tabs.filter { $0.tab.windowID == w.id }.map { object(of: $0, for: id) } }
        return o
    }

    private struct Refusal: Error { let message: String }

    /// An address an extension may open: a website, about:blank, or a page of its own (given relative to its root).
    private func address(_ text: String?, extension id: String) throws -> URL {
        guard let text, !text.isEmpty else { return URL(string: "about:blank")! }
        let root = URL(string: "chrome-extension://\(id)/")!
        guard let url = URL(string: text, relativeTo: root)?.absoluteURL else { throw Refusal(message: "Invalid url: \(text)") }
        switch url.scheme {
        case "http", "https": return url
        case "about" where url.absoluteString == "about:blank": return url
        case "chrome-extension" where url.host == id: return url
        default: throw Refusal(message: "Cannot open \(text).")
        }
    }

    /// Answers one call from the extension's scripts (`chrome.tabs.query` and the like), in the worker that made it.
    private func answerCall(_ m: [String: Any], extension id: String, session: String) {
        guard let callID = m["id"] as? Int, let api = m["api"] as? String else { return }
        let args = m["args"] as? [Any] ?? []
        let from = m["from"] as? String
        Task {
            let expression: String
            do {
                let value = try await answer(api, args, from: from, extension: id)
                expression = "__cosmosAnswer(\(callID), true, \(value.map { Self.json($0) ?? "null" } ?? "undefined"))"
            } catch {
                let message = (error as? Refusal)?.message ?? (error as? CDPError)?.message ?? "\(api) failed."
                expression = "__cosmosAnswer(\(callID), false, \(ChromiumResources.jsString(message)))"
            }
            profile?.connection?.post("Runtime.evaluate", ["expression": expression], session: session)
        }
    }

    static func json(_ value: Any) -> String? {
        if value is NSNull { return "null" }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func answer(_ api: String, _ args: [Any], from: String?, extension id: String) async throws -> Any? {
        if let needed = Permissions.needed(for: api), loaded[id]?.permissions.allows(api) != true {
            throw Refusal(message: "\(api) needs the \"\(needed[0])\" permission.")
        }
        func number(_ i: Int) -> Int? { i < args.count ? args[i] as? Int : nil }
        func dictionary(_ i: Int) -> [String: Any] { i < args.count ? args[i] as? [String: Any] ?? [:] : [:] }
        func found(_ tabID: Int?) throws -> Tab {
            if let tabID {
                guard let t = tab(tabID) else { throw Refusal(message: "No tab with id: \(tabID).") }
                return t
            }
            guard let t = tabs.first(where: { $0.tab.isActive && $0.tab.windowID == focusedWindow }) ?? tabs.first(where: \.tab.isActive)
            else { throw Refusal(message: "No current tab.") }
            return t
        }
        func windowObject(_ windowID: Int?, populate: Bool) throws -> [String: Any] {
            let all = tabsHost?.extensionWindows ?? []
            guard let w = all.first(where: { $0.id == (windowID == -2 ? focusedWindow : windowID) }) ?? (windowID == nil ? all.first(where: \.isFocused) ?? all.first : nil)
            else { throw Refusal(message: "No window with id: \(windowID ?? -1).") }
            return window(w, populate: populate, for: id)
        }
        switch api {
        case "tabs.query":
            return query(dictionary(0), extension: id).map { object(of: $0, for: id) }
        case "tabs.get":
            guard let n = number(0) else { throw Refusal(message: "No tab with id: \(args.first ?? "").") }
            return object(of: try found(n), for: id)
        case "tabs.getCurrent":
            // The tab the calling page of the extension's is in; nothing for any other address (and none for its worker).
            guard let from, from.hasPrefix("chrome-extension://\(id)/") else { return nil }
            return tabs.first { $0.page.state.url?.absoluteString == from }.map { object(of: $0, for: id) }
        case "tabs.create":
            let props = dictionary(0)
            let url = try address(props["url"] as? String, extension: id)
            guard let page = tabsHost?.openExtensionTab(url, windowID: props["windowId"] as? Int, active: props["active"] as? Bool ?? true) as? ChromiumPage
            else { throw Refusal(message: "The tab could not be opened.") }
            var o = tab(tabNumber(of: page)).map { object(of: $0, for: id) } ?? ["id": tabNumber(of: page), "index": 0, "active": props["active"] as? Bool ?? true]
            o["pendingUrl"] = url.absoluteString
            return o
        case "tabs.update":
            let t = try found(number(0))
            let props = dictionary(1)
            if let u = props["url"] as? String { t.page.load(try address(u, extension: id)) }
            if props["active"] as? Bool == true || props["highlighted"] as? Bool == true { tabsHost?.activateExtensionTab(t.page) }
            return object(of: t, for: id)
        case "tabs.remove":
            for n in (args.first as? [Any] ?? []).compactMap({ $0 as? Int }) { if let t = tab(n) { tabsHost?.closeExtensionTab(t.page) } }
            return nil
        case "tabs.reload":
            try found(number(0)).page.reload(fromOrigin: dictionary(1)["bypassCache"] as? Bool ?? false)
            return nil
        case "tabs.goBack":
            try found(number(0)).page.goBack()
            return nil
        case "tabs.goForward":
            try found(number(0)).page.goForward()
            return nil
        case "tabs.duplicate":
            let t = try found(number(0))
            guard let url = t.page.state.url, let page = tabsHost?.openExtensionTab(url, windowID: t.tab.windowID, active: true) as? ChromiumPage
            else { throw Refusal(message: "The tab could not be duplicated.") }
            return tab(tabNumber(of: page)).map { object(of: $0, for: id) }
        case "tabs.highlight":
            let info = dictionary(0)
            let indices = (info["tabs"] as? [Int]) ?? [(info["tabs"] as? Int)].compactMap { $0 }
            let windowID = info["windowId"] as? Int ?? focusedWindow
            if let first = indices.first, let t = tabs.first(where: { $0.tab.windowID == windowID && $0.tab.index == first }) {
                tabsHost?.activateExtensionTab(t.page)
            }
            return try windowObject(windowID, populate: true)
        case "tabs.captureVisibleTab":
            let windowID = number(0) ?? focusedWindow
            guard let t = tabs.first(where: { $0.tab.isActive && $0.tab.windowID == windowID }) else { throw Refusal(message: "No tab to capture.") }
            let granted = activeTabs[id]?[t.id] != nil && mayReach(t.page.state.url, extension: id, tab: t.id)
            guard loaded[id]?.permissions.reachesEverySite == true || granted else {
                throw Refusal(message: "Either the '<all_urls>' or 'activeTab' permission is required.")
            }
            let options = dictionary(1)
            guard let image = await t.page.snapshot(width: t.page.view.bounds.width), let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) else { throw Refusal(message: "The tab could not be captured.") }
            let jpeg = (options["format"] as? String) == "jpeg"
            let quality = Double(options["quality"] as? Int ?? 92) / 100
            guard let data = bitmap.representation(using: jpeg ? .jpeg : .png, properties: jpeg ? [.compressionFactor: quality] : [:])
            else { throw Refusal(message: "The tab could not be captured.") }
            return "data:image/\(jpeg ? "jpeg" : "png");base64," + data.base64EncodedString()
        case "tabs.sendMessage":
            return try await send(args.count > 1 ? args[1] : NSNull(), toTab: number(0), options: dictionary(2), from: from, extension: id)
        case "tabs.getZoom":
            return try found(number(0)).page.zoom
        case "tabs.setZoom":
            let t = try found(number(0))
            let factor = args.count > 1 ? (args[1] as? Double ?? 0) : 0
            t.page.zoom = factor == 0 ? 1 : factor
            return nil
        case "tabs.detectLanguage":
            let t = try found(number(0))
            let lang = await t.page.evaluate("document.documentElement.lang || ''", in: .agent) as? String ?? ""
            return lang.isEmpty ? "und" : String(lang.split(separator: "-").first ?? "und")
        case "windows.getAll":
            let populate = dictionary(0)["populate"] as? Bool == true
            return (tabsHost?.extensionWindows ?? []).map { window($0, populate: populate, for: id) }
        case "windows.get":
            return try windowObject(number(0), populate: dictionary(1)["populate"] as? Bool == true)
        case "windows.getCurrent", "windows.getLastFocused":
            return try windowObject(nil, populate: dictionary(0)["populate"] as? Bool == true)
        case "windows.create":
            let data = dictionary(0)
            let urls = (data["url"] as? [String]) ?? [(data["url"] as? String)].compactMap { $0 }
            let url = try address(urls.first, extension: id)
            let type = data["type"] as? String ?? "normal"
            let size = (data["width"] as? Int).flatMap { w in (data["height"] as? Int).map { CGSize(width: w, height: $0) } }
            guard let page = tabsHost?.openExtensionWindow(url, popup: type == "popup" || type == "panel", size: size) as? ChromiumPage
            else { throw Refusal(message: "The window could not be opened.") }
            for more in urls.dropFirst() { _ = tabsHost?.openExtensionTab(try address(more, extension: id), windowID: nil, active: false) }
            var o = (try? windowObject(nil, populate: false)) ?? ["id": -1, "focused": true]
            o["type"] = type
            o["tabs"] = [tab(tabNumber(of: page)).map { object(of: $0, for: id) } ?? ["id": tabNumber(of: page), "index": 0, "active": true]]
            return o
        case "windows.update":
            return try windowObject(number(0), populate: false)
        case "windows.remove":
            return nil
        case "scripting.executeScript":
            return try await executeScript(dictionary(0), extension: id)
        case "scripting.insertCSS", "scripting.removeCSS":
            try await css(dictionary(0), remove: api == "scripting.removeCSS", extension: id)
            return nil
        case "action.openPopup":
            return nil
        default:
            throw Refusal(message: "\(api) is not available in Cosmos.")
        }
    }

    private func query(_ info: [String: Any], extension id: String) -> [Tab] {
        let focused = focusedWindow
        return tabs.filter { t in
            if let v = info["active"] as? Bool, t.tab.isActive != v { return false }
            if let v = info["highlighted"] as? Bool, t.tab.isActive != v { return false }
            if let v = info["pinned"] as? Bool, t.tab.isPinned != v { return false }
            if let v = info["currentWindow"] as? Bool, (t.tab.windowID == focused) != v { return false }
            if let v = info["lastFocusedWindow"] as? Bool, (t.tab.windowID == focused) != v { return false }
            if let w = info["windowId"] as? Int, t.tab.windowID != (w == -2 ? focused : w) { return false }
            if let i = info["index"] as? Int, t.tab.index != i { return false }
            if let s = info["status"] as? String, s != (t.page.state.isLoading ? "loading" : "complete") { return false }
            // Cosmos does not keep these: no tab is audible, muted, discarded, grouped or in another kind of window.
            for key in ["audible", "muted", "discarded"] where info[key] as? Bool == true { return false }
            if let type = info["windowType"] as? String, type != "normal" { return false }
            if let group = info["groupId"] as? Int, group != -1 { return false }
            // An address or title is matched only where the extension may read it.
            if info["url"] != nil || info["title"] != nil {
                guard mayRead(t.page, extension: id, tab: t.id) else { return false }
                if let title = info["title"] as? String, !ExtensionMatchPattern.glob(title, matches: t.page.state.title) { return false }
                let patterns = (info["url"] as? [String]) ?? [(info["url"] as? String)].compactMap { $0 }
                if !patterns.isEmpty {
                    guard let u = t.page.state.url, patterns.compactMap(ExtensionMatchPattern.init).contains(where: { $0.matches(u) }) else { return false }
                }
            }
            return true
        }
    }

    // MARK: Content scripts and scripting

    /// An extension's world in a frame of `page` was made, as its content scripts start: Cosmos's script in it is told
    /// which tab this is (from outside the page, which cannot reach the world).
    func contentWorldCreated(in page: ChromiumPage, extensionID id: String, session: String, contextID: Int, frameID: String) {
        guard loaded[id] != nil else { return }
        tell(page, extension: id, world: (session, contextID, frameID))
    }

    private func tell(_ page: ChromiumPage, extension id: String, world: (session: String, id: Int, frameID: String)) {
        let n = tabNumber(of: page)
        // The extension's world is there because Chromium ran its content scripts in the page: the tab is no secret to it.
        let info: [String: Any] = ["tab": tab(n).map { object(of: $0, for: id, scrubbed: false) } ?? NSNull(), "frameId": frameNumber(world.frameID, in: page)]
        guard let json = Self.json(info) else { return }
        profile?.connection?.post("Runtime.evaluate", ["expression": "(self.__cosmosSetTab ? __cosmosSetTab(\(json)) : (self.__cosmosTab = \(json)), 1)",
                                                       "contextId": world.id], session: world.session)
    }

    /// `chrome.tabs.sendMessage`: every frame of the tab (or the one asked for) where the extension's content scripts run
    /// is given it; the first answer is the answer.
    private func send(_ message: Any, toTab tabID: Int?, options: [String: Any], from: String?, extension id: String) async throws -> Any? {
        let nobody = Refusal(message: "Could not establish connection. Receiving end does not exist.")
        guard let tabID, let page = page(forTab: tabID), let c = profile?.connection else { throw nobody }
        let frame = options["frameId"] as? Int
        let worlds = page.extensionWorlds(of: id).filter { frame == nil || frameNumber($0.frameID, in: page) == frame }
        let sender: [String: Any] = ["id": id, "origin": "chrome-extension://\(id)", "url": from ?? "chrome-extension://\(id)/"]
        guard let m = Self.json(message), let s = Self.json(sender) else { throw Refusal(message: "The message could not be sent.") }
        let expression = "__cosmosDeliver(\(m), \(s))"
        let answer = await Self.first(of: worlds.map { w in
            { () async -> [String: Any]? in
                let r = try? await c.send("Runtime.evaluate", ["expression": expression, "contextId": w.id, "awaitPromise": true, "returnByValue": true],
                                          session: w.session)
                guard let text = (r?["result"] as? [String: Any])?["value"] as? String,
                      let d = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], d["heard"] as? Bool == true else { return nil }
                return d
            }
        })
        guard let answer else { throw nobody }
        return answer["value"] is NSNull ? nil : answer["value"]
    }

    /// The first of `works` to end with something, as soon as it does (nil once all have ended with nothing); the others
    /// are not waited for (a listener that never answers does not hold up the rest).
    private static func first<T>(of works: [() async -> T?]) async -> T? {
        guard !works.isEmpty else { return nil }
        let race = Race(works.count)
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            for work in works {
                Task { @MainActor in
                    let r = await work()
                    guard !race.done else { return }
                    race.left -= 1
                    if r != nil || race.left == 0 { race.done = true; c.resume(returning: r) }
                }
            }
        }
    }

    /// The frames of the tab `target` names that the extension may reach: the main frame, all of them, or those by id.
    private func frames(_ target: [String: Any], extension id: String) throws -> (page: ChromiumPage, worlds: [(session: String, id: Int, frameID: String)]) {
        guard let tabID = target["tabId"] as? Int, let page = page(forTab: tabID) else {
            throw Refusal(message: "No tab with id: \((target["tabId"] as? Int) ?? -1).")
        }
        var picked = page.frameWorlds
        if let ids = target["frameIds"] as? [Int] { picked = picked.filter { ids.contains(frameNumber($0.frameID, in: page)) } }
        else if target["allFrames"] as? Bool != true { picked = picked.filter { $0.frameID == page.mainFrame } }
        let allowed = picked.filter { mayReach(page.url(ofFrame: $0.frameID), extension: id, tab: tabID) }
        guard !allowed.isEmpty else {
            throw Refusal(message: "Cannot access contents of the page. Extension manifest must request permission to access the respective host.")
        }
        return (page, allowed)
    }

    /// The world a script goes into in one frame: the page's own (MAIN), or the extension's, where its content scripts
    /// run (one is made for it where none do).
    private func world(for id: String, in page: ChromiumPage, frame: (session: String, id: Int, frameID: String), main: Bool) async -> Int? {
        if main { return frame.id }
        if let w = page.extensionWorlds(of: id).first(where: { $0.session == frame.session && $0.frameID == frame.frameID }) { return w.id }
        let r = try? await profile?.connection?.send("Page.createIsolatedWorld", ["frameId": frame.frameID, "worldName": "Cosmos for \(id)"],
                                                     session: frame.session)
        return r?["executionContextId"] as? Int
    }

    /// The text of the extension's files, one after another.
    private func files(_ paths: [String], extension id: String) throws -> String {
        guard let folder = loaded[id]?.staged else { throw Refusal(message: "The extension is not loaded.") }
        return try paths.map { path in
            guard let file = Self.file(path, in: folder), let text = try? String(contentsOf: file, encoding: .utf8) else {
                throw Refusal(message: "Could not load file: '\(path)'.")
            }
            return text
        }.joined(separator: "\n;\n")
    }

    private func executeScript(_ injection: [String: Any], extension id: String) async throws -> [[String: Any]] {
        let (page, worlds) = try frames(injection["target"] as? [String: Any] ?? [:], extension: id)
        guard let c = profile?.connection else { throw Refusal(message: "Chromium is not running.") }
        // A function's source and its arguments, called as Chrome calls it; Cosmos takes no other script text.
        let code: String
        if let function = injection["func"] as? String {
            code = "(\(function))(...\(Self.json(injection["args"] as? [Any] ?? []) ?? "[]"))"
        } else if let paths = injection["files"] as? [String], !paths.isEmpty {
            code = try files(paths, extension: id)
        } else {
            throw Refusal(message: "Exactly one of 'func' and 'files' must be specified.")
        }
        let main = injection["world"] as? String == "MAIN"
        var results: [[String: Any]] = []
        for frame in worlds {
            guard let context = await world(for: id, in: page, frame: frame, main: main) else { continue }
            let r = try? await c.send("Runtime.evaluate", ["expression": code, "contextId": context, "awaitPromise": true, "returnByValue": true],
                                      session: frame.session)
            if let exception = r?["exceptionDetails"] as? [String: Any], frame.frameID == page.mainFrame {
                throw Refusal(message: ((exception["exception"] as? [String: Any])?["description"] as? String) ?? "The script failed.")
            }
            var item: [String: Any] = ["frameId": frameNumber(frame.frameID, in: page)]
            if let value = (r?["result"] as? [String: Any])?["value"] { item["result"] = value }
            results.append(item)
        }
        return results
    }

    /// `scripting.insertCSS` and `removeCSS`: a style sheet of the extension's in the frames, put in from its world.
    private func css(_ injection: [String: Any], remove: Bool, extension id: String) async throws {
        let (page, worlds) = try frames(injection["target"] as? [String: Any] ?? [:], extension: id)
        let text: String
        if let given = injection["css"] as? String { text = given }
        else if let paths = injection["files"] as? [String], !paths.isEmpty { text = try files(paths, extension: id) }
        else { throw Refusal(message: "Exactly one of 'css' and 'files' must be specified.") }
        let key = ChromiumResources.jsString(id), css = ChromiumResources.jsString(text)
        let expression = remove
            ? "for (const s of document.querySelectorAll('style[data-cosmos-extension]')) if (s.dataset.cosmosExtension === \(key) && s.textContent === \(css)) s.remove()"
            : "{ const s = document.createElement('style'); s.dataset.cosmosExtension = \(key); s.textContent = \(css); (document.head || document.documentElement).appendChild(s); }"
        for frame in worlds {
            guard let context = await world(for: id, in: page, frame: frame, main: false) else { continue }
            _ = try? await profile?.connection?.send("Runtime.evaluate", ["expression": expression, "contextId": context], session: frame.session)
        }
    }

    private final class Race {
        var done = false
        var left: Int
        init(_ n: Int) { left = n }
    }

    // MARK: What changed

    func tabsDidChange() { scheduleDiff() }

    /// One of the profile's pages changed (its address, title, loading).
    func pageChanged(_ page: ChromiumPage) { scheduleDiff() }

    private func scheduleDiff() {
        guard !diffScheduled, !loaded.isEmpty else { return }
        diffScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.diffScheduled = false
            self?.diff()
        }
    }

    private func seen(_ tabs: [Tab]) -> [Int: Seen] {
        Dictionary(tabs.map { t in
            (t.id, Seen(windowID: t.tab.windowID, index: t.tab.index, isActive: t.tab.isActive, isPinned: t.tab.isPinned,
                        url: t.page.state.url?.absoluteString, title: t.page.state.title, isLoading: t.page.state.isLoading))
        }, uniquingKeysWith: { a, _ in a })
    }

    /// Tells each extension what changed in Cosmos's tabs since it last heard, as `chrome.tabs` events.
    private func diff() {
        let now = tabs
        let seen = seen(now)
        let before = lastSeen
        lastSeen = seen
        // activeTab lasts until its tab goes to another site, or goes.
        for (id, grants) in activeTabs {
            for (tab, origin) in grants where seen[tab]?.url.flatMap(URL.init(string:)).flatMap(ChromiumProfile.origin(of:)) != origin {
                activeTabs[id]?[tab] = nil
            }
        }
        for id in loaded.keys {
            var events: [(String, [Any])] = []
            for t in now {
                guard let s = seen[t.id] else { continue }
                guard let old = before[t.id] else {
                    events.append(("tabs.onCreated", [object(of: t, for: id)]))
                    if s.isActive { events.append(("tabs.onActivated", [["tabId": t.id, "windowId": s.windowID]])) }
                    continue
                }
                var change: [String: Any] = [:]
                if old.isLoading != s.isLoading { change["status"] = s.isLoading ? "loading" : "complete" }
                if old.isPinned != s.isPinned { change["pinned"] = s.isPinned }
                let readable = mayRead(t.page, extension: id, tab: t.id)
                if readable, old.url != s.url { change["url"] = s.url ?? "" }
                if readable, old.title != s.title { change["title"] = s.title }
                if !change.isEmpty { events.append(("tabs.onUpdated", [t.id, change, object(of: t, for: id)])) }
                if s.isActive && !old.isActive { events.append(("tabs.onActivated", [["tabId": t.id, "windowId": s.windowID]])) }
                // Its content scripts are told the tab as it is now.
                if old.url != s.url || old.title != s.title {
                    for world in t.page.extensionWorlds(of: id) { tell(t.page, extension: id, world: world) }
                }
            }
            for (gone, old) in before where seen[gone] == nil {
                events.append(("tabs.onRemoved", [gone, ["windowId": old.windowID, "isWindowClosing": false]]))
            }
            guard !events.isEmpty, isReady(id) else { continue }
            for (name, args) in events {
                guard let json = Self.json(args) else { continue }
                Task { await fire("__cosmosTabsEvent(\(ChromiumResources.jsString(name)), \(json))", in: id) }
            }
        }
    }

    // MARK: EngineExtensions

    func actions(for page: EnginePage?) -> [ExtensionAction] {
        let tab = (page as? ChromiumPage).map(tabNumber(of:))
        func pick<T>(_ table: [Int: T]) -> T? { tab.flatMap { table[$0] } ?? table[Loaded.everyTab] }
        return loaded.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }.map { item in
            ExtensionAction(extensionID: item.id, title: pick(item.tabTitle) ?? item.title, icon: pick(item.tabIcon) ?? item.icon,
                            badgeText: pick(item.badge) ?? "", badgeColor: pick(item.badgeColor), isEnabled: pick(item.tabEnabled) ?? true,
                            hasPopup: !(pick(item.tabPopup) ?? item.popup).isEmpty)
        }
    }

    /// The button: the extension's popup when it has one for this tab (its page, which Cosmos shows under the button),
    /// otherwise its `action.onClicked`.
    func performAction(_ extensionID: String, on page: EnginePage) async -> EnginePage? {
        guard let item = loaded[extensionID] else { return nil }
        let chromiumPage = page as? ChromiumPage
        if let chromiumPage { grantActiveTab(extensionID, page: chromiumPage) }
        // `setPanelBehavior({ openPanelOnActionClick: true })`: the button opens the side panel, which Cosmos draws.
        if item.opensSidePanelOnAction {
            onSidePanelRequest?(extensionID, page)
            return nil
        }
        let tab = chromiumPage.map(tabNumber(of:))
        let popup = tab.flatMap { item.tabPopup[$0] } ?? item.tabPopup[Loaded.everyTab] ?? item.popup
        if !popup.isEmpty, let url = URL(string: "chrome-extension://\(extensionID)/\(popup.hasPrefix("/") ? String(popup.dropFirst()) : popup)") {
            return profile?.openPage(url)
        }
        await fire("__cosmosFireAction(\(tab.map(String.init) ?? "null"))", in: extensionID)
        return nil
    }

    func menuItems(for page: EnginePage?) -> [ExtensionMenuItem] {
        loaded.values.sorted { $0.title < $1.title }.flatMap(\.menus)
    }

    func performMenuItem(_ item: ExtensionMenuItem, context: ExtensionClickContext, on page: EnginePage) async {
        guard let page = page as? ChromiumPage else { return }
        grantActiveTab(item.extensionID, page: page)
        let tab = tabNumber(of: page)
        var info: [String: Any] = ["menuItemId": item.itemID, "editable": context.editable, "frameId": 0]
        if let p = item.parentID { info["parentMenuItemId"] = p }
        if let u = context.pageURL?.absoluteString { info["pageUrl"] = u }
        if let u = context.linkURL?.absoluteString { info["linkUrl"] = u }
        if let u = context.srcURL?.absoluteString { info["srcUrl"] = u; info["mediaType"] = "image" }
        if let s = context.selectionText, !s.isEmpty { info["selectionText"] = s }
        guard let json = Self.json(info) else { return }
        await fire("__cosmosFireMenu(\(json), \(tab))", in: item.extensionID)
    }

    var commands: [ExtensionCommand] { loaded.values.flatMap(\.commands) }

    func performCommand(_ command: ExtensionCommand, on page: EnginePage?) async -> EnginePage? {
        if command.name == "_execute_action" || command.name == "_execute_browser_action" {
            guard let page else { return nil }
            return await performAction(command.extensionID, on: page)
        }
        let chromiumPage = page as? ChromiumPage
        if let chromiumPage { grantActiveTab(command.extensionID, page: chromiumPage) }
        let tab = chromiumPage.map(tabNumber(of:))
        await fire("__cosmosFireCommand(\(ChromiumResources.jsString(command.name)), \(tab.map(String.init) ?? "null"))", in: command.extensionID)
        return nil
    }

    // MARK: Side panels

    var onSidePanelRequest: ((String, EnginePage?) -> Void)?

    func openSidePanel(_ extensionID: String, for page: EnginePage?) async -> EnginePage? {
        guard let item = loaded[extensionID] else { return nil }
        let tab = (page as? ChromiumPage).map(tabNumber(of:))
        let path = tab.flatMap { item.sidePanelPath[$0] } ?? item.sidePanelPath[Loaded.everyTab]
        let enabled = tab.flatMap { item.sidePanelEnabled[$0] } ?? item.sidePanelEnabled[Loaded.everyTab] ?? true
        guard enabled, let path, let url = URL(string: "chrome-extension://\(extensionID)/\(path.hasPrefix("/") ? String(path.dropFirst()) : path)") else { return nil }
        return profile?.openPage(url)
    }

    // MARK: Signing in

    /// One `identity.launchWebAuthFlow` that needs the user: its page, until it reaches the extension's address or closes.
    private final class AuthFlow { var finished = false }

    /// The sign-in page opens in a window of its own, as a site's popup does; when it heads for the extension's own
    /// address (`https://<id>.chromiumapp.org/`), that address is the answer, and the window closes.
    private func startAuthFlow(_ m: [String: Any], from id: String) {
        guard let flow = m["flow"] as? Int, let back = m["redirect"] as? String, !back.isEmpty,
              let url = (m["url"] as? String).flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme ?? "") else {
            if let flow = m["flow"] as? Int { Task { await finishAuthFlow(flow, of: id, url: nil, error: "Authorization page could not be loaded.") } }
            return
        }
        let state = AuthFlow()
        let request = NewPageRequest(url: url, features: ["width=520", "height=680"], fromExtension: true)
        guard let page = profile?.openPage(url, request: request) else {
            Task { await finishAuthFlow(flow, of: id, url: nil, error: "Authorization page could not be loaded.") }
            return
        }
        // Taken before it goes anywhere: the address is the extension's own, not a site's.
        page.onNavigation = { [weak self, weak page] next in
            guard !state.finished, next.absoluteString.hasPrefix(back) else { return false }
            state.finished = true
            Task {
                await self?.finishAuthFlow(flow, of: id, url: next.absoluteString, error: nil)
                if let page { if let d = page.delegate { d.pageRequestsClose(page) } else { page.close() } }
            }
            return true
        }
        page.onClose = { [weak self] in
            guard !state.finished else { return }
            state.finished = true
            Task { await self?.finishAuthFlow(flow, of: id, url: nil, error: "The user did not approve access.") }
        }
    }

    private func finishAuthFlow(_ flow: Int, of extensionID: String, url: String?, error: String?) async {
        let answer = url.map(ChromiumResources.jsString) ?? "null"
        await fire("__cosmosFinishAuthFlow(\(flow), \(answer), \(ChromiumResources.jsString(error ?? "")))", in: extensionID)
    }

    func notification(_ id: String, of extensionID: String, did action: NotificationAction) async {
        let (name, index): (String, Int) = switch action {
        case .clicked: ("clicked", 0)
        case .button(let i): ("button", i)
        case .closed: ("closed", 0)
        }
        await fire("__cosmosFireNotification(\(ChromiumResources.jsString(id)), '\(name)', \(index))", in: extensionID)
    }

    /// Runs one of the shim's fire functions in a worker of the extension that can still reach its APIs. A worker that
    /// cannot (Chromium replaced it, and it lingers because Cosmos is attached) answers 'dead' and is let go; one that
    /// answers false is alive but not the one; the next is asked either way.
    private func fire(_ expression: String, in extensionID: String) async {
        guard let c = profile?.connection, await awaitWorker(of: extensionID) else { return }
        for session in workers.filter({ $0.value == extensionID && readyWorkers.contains($0.key) }).map(\.key) {
            let r = try? await c.send("Runtime.evaluate", ["expression": expression, "awaitPromise": true, "returnByValue": true, "userGesture": true],
                                      session: session)
            let value = (r?["result"] as? [String: Any])?["value"]
            if value as? Bool == true { return }
            // Alive, but not the worker this is for (a sign-in another worker started): ask the next one.
            if value as? Bool == false { continue }
            workers[session] = nil
            readyWorkers.remove(session)
            c.post("Target.detachFromTarget", ["sessionId": session])
        }
    }
}
