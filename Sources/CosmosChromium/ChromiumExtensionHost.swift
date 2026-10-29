import AppKit
import CosmosCore
import CosmosEngine

/// The extensions of one profile. Chromium runs them with its own, complete `chrome.*` APIs; what Chromium would draw in
/// its toolbar and menus (the action button, its badge and popup, `contextMenus` items, `commands` shortcuts) is
/// mirrored here so Cosmos can draw it, and Cosmos's clicks go back to the extension.
@MainActor
final class ChromiumExtensionHost: EngineExtensions {
    /// Weak: Cosmos keeps the extensions (`EngineProfile.extensions`) and their tasks, which can outlast the profile.
    private(set) weak var profile: ChromiumProfile?
    var onChange: (() -> Void)?
    var onNotification: ((String, EngineNotification) -> Void)?
    var onNotificationClosed: ((String, String) -> Void)?

    struct Loaded {
        let id: String
        let folder: URL
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
    /// Chromium's tab ids of Cosmos's pages, and the tab targets `Extensions.triggerAction` wants.
    private var tabIDs: [String: Int] = [:]
    private var tabTargets: [String: String] = [:]
    /// Tab targets being asked which page they hold: session → tab target.
    private var askingTab: [String: String] = [:]
    private var awaitingPopup: (extensionID: String, continuation: CheckedContinuation<EnginePage?, Never>)?
    /// For tests: called just before a tab target is asked which page it holds.
    var willAskTab: (() -> Void)?

    init(profile: ChromiumProfile) { self.profile = profile }

    // MARK: Loading

    func browserStarted() async {
        workers = [:]
        tabIDs = [:]
        tabTargets = [:]
        for folder in folders { _ = try? await loadIntoChromium(folder) }
    }

    func browserStopped() {
        workers = [:]
        awaitingPopup?.continuation.resume(returning: nil)
        awaitingPopup = nil
    }

    func load(folder: URL) async throws -> String {
        if !folders.contains(folder) { folders.append(folder) }
        guard let profile, await profile.start() else { throw CDPError(code: -3, message: "Chromium is not running") }
        return try await loadIntoChromium(folder)
    }

    private func loadIntoChromium(_ folder: URL) async throws -> String {
        guard let c = profile?.connection else { throw CDPError.closed }
        let r = try await c.send("Extensions.loadUnpacked", ["path": folder.path])
        guard let id = r["id"] as? String else { throw CDPError(code: -4, message: "Chromium did not load the extension") }
        let manifest = Self.manifest(folder)
        var item = loaded[id] ?? Loaded(id: id, folder: folder, title: "", icon: nil, popup: "")
        let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any] ?? [:]
        item.title = action["default_title"] as? String ?? manifest["name"] as? String ?? ""
        let name = manifest["name"] as? String ?? ""
        item.name = name.isEmpty || name.hasPrefix("__MSG_") ? item.title : name
        item.popup = action["default_popup"] as? String ?? ""
        if let panel = (manifest["side_panel"] as? [String: Any])?["default_path"] as? String { item.sidePanelPath[Loaded.everyTab] = panel }
        item.icon = Self.iconData(action["default_icon"] ?? manifest["icons"], folder: folder)
        item.commands = Self.commands(manifest, extensionID: id)
        loaded[id] = item
        onChange?()
        return id
    }

    func unload(id: String) async {
        if let item = loaded.removeValue(forKey: id) { folders.removeAll { $0 == item.folder } }
        _ = try? await profile?.connection?.send("Extensions.uninstall", ["id": id])
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
        let file = folder.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path).standardizedFileURL
        // Inside the folder, not merely beside it (`/x/ext-other` starts with `/x/ext` too).
        let inside = folder.standardizedFileURL.path.hasSuffix("/") ? folder.standardizedFileURL.path : folder.standardizedFileURL.path + "/"
        guard file.path.hasPrefix(inside) else { return nil }
        return try? Data(contentsOf: file)
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

    func serviceWorkerAttached(target: String, session: String, url: String) {
        guard let c = profile?.connection else { return }
        let id = URL(string: url)?.host ?? ""
        guard loaded[id] != nil, let shim = Self.shim else {
            c.post("Runtime.runIfWaitingForDebugger", session: session)
            return
        }
        workers[session] = id
        // Cosmos attaches to a worker once it has started (see ChromiumRuntime), so the shim goes in now, after the
        // worker's first lines: what they did through the APIs the shim watches is not reported.
        c.post("Runtime.addBinding", ["name": "__cosmosExt"], session: session)
        c.post("Runtime.enable", session: session)
        c.post("Runtime.evaluate", ["expression": shim], session: session)
        c.post("Runtime.runIfWaitingForDebugger", session: session)
    }

    static let shim: String? = {
        guard let url = Bundle.module.url(forResource: "extension-shim", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    func handle(_ event: CDPEvent) {
        guard let session = event.sessionID else { return }
        if event.method == "Target.attachedToTarget", let tab = askingTab[session] {
            // A tab target told us which page it holds.
            if let child = (event.params["targetInfo"] as? [String: Any])?["targetId"] as? String,
               let childSession = event.params["sessionId"] as? String {
                tabTargets[child] = tab
                profile?.connection?.post("Target.detachFromTarget", ["sessionId": childSession], session: session)
            }
            return
        }
        guard let id = workers[session] else { return }
        switch event.method {
        case "Runtime.bindingCalled":
            guard let payload = event.params["payload"] as? String,
                  let m = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return }
            report(m, from: id)
        default:
            break
        }
    }

    func targetDestroyed(_ target: String?) {
        guard let target else { return }
        tabIDs[target] = nil
        tabTargets[target] = nil
    }

    private func report(_ m: [String: Any], from id: String) {
        guard var item = loaded[id] else { return }
        let tab = (m["tabId"] as? Int) ?? Loaded.everyTab
        switch m["kind"] as? String {
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

    private func tabID(of page: ChromiumPage) async -> Int? {
        guard let target = page.targetID else { return nil }
        if let known = tabIDs[target] { return known }
        let id = await profile?.bridgeEvaluate("cosmosTabID(\(ChromiumResources.jsString(target)))") as? Int
        if let id { tabIDs[target] = id }
        return id
    }

    /// The tab target holding `page` (what `Extensions.triggerAction` wants): each tab target is asked which page it
    /// holds until one says this one. Chromium names the page before it answers, so its answer, however late, ends the
    /// wait: a busy Chromium does not lose the click.
    private func tabTarget(of page: ChromiumPage) async -> String? {
        guard let target = page.targetID, let c = profile?.connection else { return nil }
        if let known = tabTargets[target] { return known }
        let tabs = ((try? await c.send("Target.getTargets", ["filter": [["type": "tab"]]]))?["targetInfos"] as? [[String: Any]] ?? [])
            .compactMap { $0["targetId"] as? String }
        for tab in tabs where !tabTargets.values.contains(tab) {
            guard let session = (try? await c.send("Target.attachToTarget", ["targetId": tab, "flatten": true]))?["sessionId"] as? String else { continue }
            askingTab[session] = tab
            willAskTab?()
            _ = try? await c.send("Target.setAutoAttach", ["autoAttach": true, "waitForDebuggerOnStart": false, "flatten": true], session: session)
            askingTab[session] = nil
            c.post("Target.detachFromTarget", ["sessionId": session])
            if let found = tabTargets[target] { return found }
        }
        return tabTargets[target]
    }

    // MARK: EngineExtensions

    func actions(for page: EnginePage?) -> [ExtensionAction] {
        let tab = (page as? ChromiumPage)?.targetID.flatMap { tabIDs[$0] }
        func pick<T>(_ table: [Int: T]) -> T? { tab.flatMap { table[$0] } ?? table[Loaded.everyTab] }
        return loaded.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }.map { item in
            ExtensionAction(extensionID: item.id, title: pick(item.tabTitle) ?? item.title, icon: pick(item.tabIcon) ?? item.icon,
                            badgeText: pick(item.badge) ?? "", badgeColor: pick(item.badgeColor), isEnabled: pick(item.tabEnabled) ?? true,
                            hasPopup: !(pick(item.tabPopup) ?? item.popup).isEmpty)
        }
    }

    func performAction(_ extensionID: String, on page: EnginePage) async -> EnginePage? {
        // `setPanelBehavior({ openPanelOnActionClick: true })`: the button opens the side panel, which Cosmos draws.
        if loaded[extensionID]?.opensSidePanelOnAction == true {
            onSidePanelRequest?(extensionID, page)
            return nil
        }
        guard let page = page as? ChromiumPage, let c = profile?.connection else { return nil }
        _ = await tabID(of: page)
        guard let tab = await tabTarget(of: page) else { return nil }
        awaitingPopup?.continuation.resume(returning: nil)
        return await withCheckedContinuation { continuation in
            awaitingPopup = (extensionID, continuation)
            Task {
                _ = try? await c.send("Extensions.triggerAction", ["id": extensionID, "targetId": tab])
                // An extension without a popup gets its onClicked event instead, and no page comes.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if let waiting = self.awaitingPopup, waiting.extensionID == extensionID {
                    self.awaitingPopup = nil
                    waiting.continuation.resume(returning: nil)
                }
            }
        }
    }

    func claimsPopup(url: String) -> Bool {
        guard let waiting = awaitingPopup else { return false }
        return url.hasPrefix("chrome-extension://\(waiting.extensionID)/")
    }

    func popupAttached(_ page: ChromiumPage) {
        guard let waiting = awaitingPopup else { page.close(); return }
        awaitingPopup = nil
        waiting.continuation.resume(returning: page)
    }

    func menuItems(for page: EnginePage?) -> [ExtensionMenuItem] {
        loaded.values.sorted { $0.title < $1.title }.flatMap(\.menus)
    }

    func performMenuItem(_ item: ExtensionMenuItem, context: ExtensionClickContext, on page: EnginePage) async {
        guard let page = page as? ChromiumPage else { return }
        let tab = await tabID(of: page)
        var info: [String: Any] = ["menuItemId": item.itemID, "editable": context.editable, "frameId": 0]
        if let p = item.parentID { info["parentMenuItemId"] = p }
        if let u = context.pageURL?.absoluteString { info["pageUrl"] = u }
        if let u = context.linkURL?.absoluteString { info["linkUrl"] = u }
        if let u = context.srcURL?.absoluteString { info["srcUrl"] = u; info["mediaType"] = "image" }
        if let s = context.selectionText, !s.isEmpty { info["selectionText"] = s }
        guard let json = try? JSONSerialization.data(withJSONObject: info) else { return }
        await fire("__cosmosFireMenu(\(String(decoding: json, as: UTF8.self)), \(tab.map(String.init) ?? "null"))", in: item.extensionID)
    }

    var commands: [ExtensionCommand] { loaded.values.flatMap(\.commands) }

    func performCommand(_ command: ExtensionCommand, on page: EnginePage?) async {
        if command.name == "_execute_action" || command.name == "_execute_browser_action" {
            if let page { _ = await performAction(command.extensionID, on: page) }
            return
        }
        let tab = await (page as? ChromiumPage).asyncMap { await tabID(of: $0) } ?? nil
        await fire("__cosmosFireCommand(\(ChromiumResources.jsString(command.name)), \(tab.map(String.init) ?? "null"))", in: command.extensionID)
    }

    // MARK: Side panels

    var onSidePanelRequest: ((String, EnginePage?) -> Void)?

    func openSidePanel(_ extensionID: String, for page: EnginePage?) async -> EnginePage? {
        guard let item = loaded[extensionID] else { return nil }
        let tab = await (page as? ChromiumPage).asyncMap { await tabID(of: $0) } ?? nil
        let path = tab.flatMap { item.sidePanelPath[$0] } ?? item.sidePanelPath[Loaded.everyTab]
        let enabled = tab.flatMap { item.sidePanelEnabled[$0] } ?? item.sidePanelEnabled[Loaded.everyTab] ?? true
        guard enabled, let path, let url = URL(string: "chrome-extension://\(extensionID)/\(path.hasPrefix("/") ? String(path.dropFirst()) : path)") else { return nil }
        return profile?.openPage(url)
    }

    /// The page of a `chrome.tabs` id, among the pages Cosmos has asked about.
    private func page(forTab tab: Int) -> ChromiumPage? {
        tabIDs.first { $0.value == tab }.flatMap { profile?.page(forTarget: $0.key) }
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
        page.onDocumentRequest = { [weak self, weak page] next in
            guard !state.finished, next.absoluteString.hasPrefix(back) else { return }
            state.finished = true
            page?.stop()
            Task {
                await self?.finishAuthFlow(flow, of: id, url: next.absoluteString, error: nil)
                if let page { if let d = page.delegate { d.pageRequestsClose(page) } else { page.close() } }
            }
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
        guard let c = profile?.connection else { return }
        for session in workers.filter({ $0.value == extensionID }).map(\.key) {
            let r = try? await c.send("Runtime.evaluate", ["expression": expression, "awaitPromise": true, "returnByValue": true, "userGesture": true],
                                      session: session)
            let value = (r?["result"] as? [String: Any])?["value"]
            if value as? Bool == true { return }
            // Alive, but not the worker this is for (a sign-in another worker started): ask the next one.
            if value as? Bool == false { continue }
            workers[session] = nil
            c.post("Target.detachFromTarget", ["sessionId": session])
        }
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
