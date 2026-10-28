import AppKit
import WebKit
import CosmosCore

/// Drives the running app from a JSON script (`--automation script.json` or `COSMOS_AUTOMATION`), so the UI can be
/// exercised and photographed without screen-recording permission: snapshots are composed from the window's own views.
///
/// A script is a JSON array of steps like `{"do":"open","url":"https://example.com"}`; see `run(_:)` for the verbs.
/// Results and errors go to `<script>.log` next to the script.
@MainActor
final class Automation {
    private weak var delegate: CosmosAppDelegate?
    private let script: [[String: Any]]
    private let logURL: URL
    private var log = ""

    init(delegate: CosmosAppDelegate, scriptURL: URL) {
        self.delegate = delegate
        logURL = scriptURL.appendingPathExtension("log")
        if let data = try? Data(contentsOf: scriptURL), let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            script = parsed
        } else {
            script = []
        }
    }

    func start() {
        Task { @MainActor in
            note("start: \(script.count) steps")
            for (i, step) in script.enumerated() {
                let verb = step["do"] as? String ?? "?"
                note("[\(i)] \(verb)")
                await run(step)
            }
            note("done")
        }
    }

    private func note(_ line: String) {
        log += line + "\n"
        try? log.write(to: logURL, atomically: true, encoding: .utf8)
    }

    private var controller: BrowserWindowController? { delegate?.active }
    private var store: BrowserStore? { controller?.store }
    private var state: WindowState? { controller?.state }

    private func sleep(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    private func run(_ step: [String: Any]) async {
        guard let verb = step["do"] as? String else { return }
        let url = (step["url"] as? String).flatMap(URL.init(string:))
        switch verb {
        case "wait":
            await sleep(step["seconds"] as? Double ?? 1)
        case "waitLoaded":
            let deadline = Date().addingTimeInterval(step["timeout"] as? Double ?? 20)
            await sleep(0.3)
            while Date() < deadline {
                if let s = store, let st = state, let rt = s.currentRuntime(in: st), !rt.isLoading { break }
                await sleep(0.25)
            }
            await sleep(step["settle"] as? Double ?? 0.6)
        case "open":
            if let url, let s = store, let st = state { s.newTab(url: url, in: st) }
        case "navigate":
            if let url, let s = store, let st = state { s.navigateCurrent(to: url, in: st) }
        case "overlay":
            guard let st = state else { return }
            let name = step["name"] as? String ?? ""
            switch name {
            case "commandBar": st.overlay = .commandBar(step["mode"] as? String == "current" ? .currentTab : .newTab)
            case "archive", "history", "downloads", "resources":
                // These live in the Library now; the names still work in scripts.
                if let s = store, name == "archive" { s.openLibrary(.history, timeline: .archived, in: st) }
                else if let s = store, let section = LibrarySection(rawValue: name) { s.openLibrary(section, in: st) }
            case "boosts": st.overlay = .boosts
            case "welcome": st.overlay = .welcome
            case "shortcuts": st.overlay = .shortcuts
            case "siteControls": st.overlay = .siteControls
            case "find": st.overlay = .find
            case "theme": st.overlay = .themeEditor(st.focusedSpaceID)
            default: st.overlay = nil
            }
        case "closeOverlay":
            state?.overlay = nil
        case "type":
            if let text = step["text"] as? String, let tv = controller?.window?.firstResponder as? NSTextView {
                tv.insertText(text, replacementRange: tv.selectedRange)
            } else { note("  type: no text view has focus") }
        case "key":
            if let name = step["name"] as? String, let tv = controller?.window?.firstResponder as? NSTextView {
                let sel: Selector? = ["return": #selector(NSResponder.insertNewline(_:)), "tab": #selector(NSResponder.insertTab(_:)),
                                      "escape": #selector(NSResponder.cancelOperation(_:)), "down": #selector(NSResponder.moveDown(_:)),
                                      "up": #selector(NSResponder.moveUp(_:)), "backspace": #selector(NSResponder.deleteBackward(_:))][name]
                if let sel { tv.doCommand(by: sel) } else { note("  key: unknown \(name)") }
            } else { note("  key: no text view has focus") }
        case "space":
            if let s = store, let st = state { s.switchSpace(number: (step["index"] as? Int ?? 1), in: st) }
        case "library":
            // Slides the sidebar to the Library, the page left of the first space ("back": true returns to the space).
            if let s = store, let st = state {
                if step["section"] as? String == "archive" { s.openLibrary(.history, timeline: .archived, in: st) }
                else if let name = step["section"] as? String, let section = LibrarySection(rawValue: name) { s.openLibrary(section, in: st) }
                else { s.show(step["back"] as? Bool == true ? .space(st.focusedSpaceID) : .library, in: st) }
            }
        case "swipe":
            // Two fingers across the sidebar: "dx" points in all (negative goes left, to the next page), in "steps" scroll samples
            // with a pause between them. They are fed to the sidebar's swipe view as a trackpad's would be, past the part that
            // reads system events (which cannot be sent from here without mixing with the real trackpad).
            if let content = controller?.window?.contentView {
                var catchers: [SwipeCatcher.SwipeView] = []
                func collect(_ view: NSView) { if let v = view as? SwipeCatcher.SwipeView { catchers.append(v) }; view.subviews.forEach(collect) }
                collect(content)
                let total = step["dx"] as? Double ?? -120, steps = max(1, step["steps"] as? Int ?? 8)
                let pause = step["pause"] as? Double ?? 0.016
                for index in 0...(steps + 1) {
                    let phase: NSEvent.Phase = index == 0 ? .began : (index == steps + 1 ? .ended : .changed)
                    let delta = index == 0 || index == steps + 1 ? 0 : total / Double(steps)
                    for catcher in catchers { catcher.handle(SwipeCatcher.Sample(phase: phase, deltaX: delta)) }
                    await sleep(pause)
                    if index == steps, let hold = step["hold"] as? Double { await sleep(hold) }
                }
                note("  swipe: \(catchers.count) swipe view(s)")
            } else { note("  swipe: no window") }
        case "setTheme":
            // Gives the focused space a preset by name, to look at a theme without opening the editor.
            if let s = store, let st = state, let name = step["name"] as? String, let preset = SpaceTheme.presets.first(where: { $0.name == name }) {
                s.updateSpace(st.focusedSpaceID) { $0.theme = preset }
            }
        case "rightClick":
            // A right click at (x, y) in the page, measured from its top-left, as if the pointer were there.
            if let s = store, let st = state, let web = s.currentRuntime(in: st)?.webView, let window = web.window {
                let x = step["x"] as? Double ?? 0, y = step["y"] as? Double ?? 0
                let local = NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y)
                let point = web.convert(local, to: nil)
                let flags = NSEvent.ModifierFlags(rawValue: UInt(step["flags"] as? Int ?? 0))
                let types: [NSEvent.EventType] = step["left"] as? Bool == true ? [.leftMouseDown, .leftMouseUp] : [.rightMouseDown, .rightMouseUp]
                for type in types {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .rightMouseDown || type == .leftMouseDown ? 1 : 0) {
                        window.sendEvent(event)
                    }
                    if type == .rightMouseDown || type == .leftMouseDown { await sleep(step["hold"] as? Double ?? 0.05) }
                }
            } else { note("  rightClick: no page") }
        case "click":
            // A left click at (x, y) from the top-left of the window, sent through the application the way a real click arrives
            // (so event monitors see it too), as a person's click would be. "double" makes it a double click.
            if let window = controller?.window, let content = window.contentView {
                let x = step["x"] as? Double ?? 0, y = step["y"] as? Double ?? 0
                let point = content.convert(NSPoint(x: x, y: content.isFlipped ? y : content.bounds.height - y), to: nil)
                let count = step["double"] as? Bool == true ? 2 : 1
                if !window.isKeyWindow { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); await sleep(0.3) }
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0) {
                        NSApp.sendEvent(event)
                    }
                    await sleep(0.05)
                }
            } else { note("  click: no window") }
        case "radial":
            // Looks at or drives the open radial menu: "dump" lists the ring, "hover" and "choose" take a slice number.
            guard let session = state?.radial else { note("  radial: none open"); return }
            if step["dump"] as? Bool == true {
                note("  radial \(session.context.rawValue) depth=\(session.depth) center=\(Int(session.center.x)),\(Int(session.center.y)): " + session.ring.enumerated().map { "\($0.offset + 1)=\($0.element.title)\($0.element.isGroup ? " (+\($0.element.children.count))" : "")" }.joined(separator: " | "))
            }
            if let index = step["hover"] as? Int, session.ring.indices.contains(index) {
                let at = RadialGeometry.offset(of: index, count: session.ring.count, radius: 90)
                session.pointerMoved(to: CGPoint(x: session.center.x + at.x, y: session.center.y + at.y))
            }
            if let index = step["choose"] as? Int { session.choose(index) }
            if step["back"] as? Bool == true { session.back() }
        case "sidebar":
            state?.sidebarVisible = (step["visible"] as? Bool) ?? true
        case "peek":
            if let url, let s = store, let st = state { s.openPeek(url, from: st.selectedItemID, in: st) }
        case "external":
            if let url { delegate?.openExternal(url) }
        case "chord":
            if let combo = step["combo"] as? String { sendChord(combo) }
        case "boost":
            if let s = store, let host = step["host"] as? String {
                var f: ColorFilter?
                if let hue = step["hue"] as? Double { f = ColorFilter(hue: hue, invert: step["invert"] as? Bool ?? false) }
                s.boosts.boosts.append(Boost(name: "auto", hostPatterns: [host], css: step["css"] as? String ?? "", js: step["js"] as? String ?? "",
                                             zapSelectors: step["zap"] as? [String] ?? [], colorFilter: f, fontFamily: step["font"] as? String, zoom: step["zoom"] as? Double))
            }
        case "downloadsDir":
            if let s = store, let path = step["path"] as? String { s.downloads.directory = URL(fileURLWithPath: path) }
        case "reload":
            if let s = store, let st = state { s.currentRuntime(in: st)?.reload() }
        case "closePeek":
            if let s = store, let st = state { s.closePeek(in: st) }
        case "split":
            if let s = store, let st = state { s.addSplit(in: st, with: url) }
        case "select":
            if let n = step["favorite"] as? Int, let s = store, let st = state { s.selectFavorite(number: n, in: st) }
            if let n = step["tab"] as? Int, let s = store, let st = state, let space = s.workspace.space(st.focusedSpaceID) {
                let order = s.workspace.navigationOrder(in: space)
                if order.indices.contains(n) { s.select(order[n], in: st) }
            }
        case "menu":
            if let title = step["title"] as? String { performMenu(title) }
        case "resize":
            if let w = step["width"] as? Double, let h = step["height"] as? Double, let win = controller?.window {
                win.setFrame(NSRect(x: win.frame.minX, y: win.frame.minY, width: w, height: h), display: true)
            }
        case "eval":
            if let js = step["js"] as? String, let s = store, let st = state, let rt = s.currentRuntime(in: st) {
                let result: String = await withCheckedContinuation { cont in
                    rt.webView.evaluateJavaScript(js) { r, e in cont.resume(returning: e.map { "error: \($0.localizedDescription)" } ?? "\(r ?? "nil")") }
                }
                note("  eval → \(result.prefix(600))")
            }
        case "state":
            if let s = store, let st = state {
                let rt = s.currentRuntime(in: st)
                let section: String = {
                    guard let id = st.selectedItemID, let sec = s.workspace.section(of: id) else { return "none" }
                    switch sec { case .favorites: return "favorites"; case .pinned: return "pinned"; case .unpinned: return "today" }
                }()
                let split = st.selectedItemID.flatMap { s.workspace.item($0) }?.isSplit == true
                note("  space=\(s.workspace.space(st.focusedSpaceID)?.title ?? "?") library=\(st.libraryOpen ? st.librarySection.rawValue : "off") overlay=\(Self.describe(st.overlay)) section=\(section) split=\(split) sidebar=\(st.sidebarVisible) tab=\(rt?.title.prefix(24) ?? "-") url=\(rt?.url?.host ?? "-") tabs=\(s.workspace.allTabs().count) archived=\(s.archive.entries.count) windows=\(delegate?.controllers.count ?? 0) probes=\(delegate?.probeCount ?? 0) blocker=\(s.blocker.map { "\($0.installedRuleCount) rules\($0.isUpdating ? ", updating" : "")" } ?? "off")")
            }
        case "spatial":
            // Checks the sidebar's alignment rules on the frames the views reported (see SpatialProbe).
            await sleep(0.4)
            let checks = SpatialProbe.check(SpatialProbe.frames)
            for c in checks { note("  spatial \(c.passed ? "PASS" : "FAIL") \(c.name)\(c.detail.isEmpty ? "" : ": " + c.detail)") }
            note("  spatial: \(checks.filter(\.passed).count) of \(checks.count) rules hold")
        case "extensions":
            // Adds extensions without prompting: from "arc"/other browsers on this Mac, or from a folder path.
            guard let center = store?.extensionCenter else { note("  extensions: unavailable"); break }
            var added = 0, failed: [String] = []
            if let folder = step["folder"] as? String {
                do { try await center.install(from: URL(fileURLWithPath: folder), origin: "a folder") { _ in true }; added += 1 }
                catch { failed.append(error.localizedDescription) }
            } else {
                for ext in await center.discoverable() {
                    do { try await center.install(from: ext.directory, origin: ext.source, webStoreID: ext.id) { _ in true }; added += 1 }
                    catch { failed.append(error.localizedDescription) }
                }
            }
            note("  extensions: added \(added), failed \(failed.count) \(failed.prefix(3))")
        case "extensionAction":
            if let center = store?.extensionCenter, let s = store, let st = state {
                let enabled = center.items.filter(\.enabled)
                let index = step["index"] as? Int ?? 0
                if enabled.indices.contains(index) { center.performAction(enabled[index].id, runtime: s.currentRuntime(in: st), anchor: nil) }
                note("  extensionAction \(index) of \(enabled.count)")
            }
        case "allowlist":
            if let host = step["host"] as? String, let s = store {
                if step["off"] as? Bool == true { s.settings.adBlockAllowlist.removeAll { $0 == host } }
                else if !s.settings.adBlockAllowlist.contains(host) { s.settings.adBlockAllowlist.append(host) }
            }
        case "settings":
            delegate?.showSettings(tab: (step["tab"] as? String).flatMap(SettingsTab.init(rawValue:)) ?? .general)
        case "menuBar":
            // Drives the menu-bar browser: enable/disable it, set `home`, `layout` ("phone" or "desktop") or `remember`, then
            // open, close, pin, go (`text`) and state. Snapshot it with "window": "menubar".
            guard let s = store, let browser = delegate?.menuBar else { note("  menuBar: not available"); break }
            let action = step["action"] as? String ?? "state"
            switch action {
            case "enable": s.settings.menuBar.enabled = true
            case "disable": s.settings.menuBar.enabled = false
            case "configure":
                if let home = step["home"] as? String { s.settings.menuBar.homeAddress = home }
                if let layout = (step["layout"] as? String).flatMap(MenuBarSettings.Layout.init(rawValue:)) { s.settings.menuBar.layout = layout }
                if let remember = step["remember"] as? Bool { s.settings.menuBar.rememberPage = remember }
            case "open": browser.show()
            case "close": browser.hide()
            case "pin": browser.session.isPinned.toggle()
            case "resize":
                // Takes hold of an edge or corner of the panel (`edge`: left, right, top, bottom, topLeft, topRight, bottomLeft or
                // bottomRight) and drags it `dx`, `dy` points (right and down), through the application as a person's mouse would.
                if let panel = browser.panel, panel.isVisible {
                    let w = panel.frame.width, h = panel.frame.height, near = 2.0
                    let edge = step["edge"] as? String ?? "right"
                    let x: Double = edge.lowercased().contains("left") ? near : (edge.lowercased().contains("right") ? w - near : w / 2)
                    let y: Double = edge.lowercased().contains("bottom") ? near : (edge.lowercased().contains("top") ? h - near : h / 2)
                    let dx = step["dx"] as? Double ?? 0, dy = step["dy"] as? Double ?? 0
                    let start = NSPoint(x: x, y: y)
                    for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, NSPoint(x: x + dx, y: y - dy)), (.leftMouseUp, NSPoint(x: x + dx, y: y - dy))] {
                        if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                            NSApp.sendEvent(event)
                        }
                        await sleep(0.05)
                    }
                }
            case "go": browser.session.go(step["text"] as? String ?? "")
            default: break
            }
            let rt = browser.session.runtime
            note("  menuBar \(action): enabled=\(s.settings.menuBar.enabled) icon=\(browser.statusItem != nil) open=\(browser.isOpen) pinned=\(browser.session.isPinned) layout=\(s.settings.menuBar.layout.rawValue) loading=\(rt?.isLoading ?? false) host=\(rt?.url?.host ?? "-") panel=\(browser.panel.map { "\(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.frame.minX)),\(Int($0.frame.maxY))" } ?? "-")")
        case "scrollSettings":
            // Scrolls the Settings pane `y` points down (the pane is taller than the window), so a snapshot can show the rest.
            if let content = delegate?.settingsWindow?.contentView {
                var found: [NSScrollView] = []
                func collect(_ v: NSView) { if let s = v as? NSScrollView { found.append(s) }; v.subviews.forEach(collect) }
                collect(content)
                if let scroller = found.max(by: { $0.frame.height < $1.frame.height }) {
                    let room = max(0, (scroller.documentView?.frame.height ?? 0) - scroller.contentView.bounds.height)
                    scroller.contentView.scroll(to: NSPoint(x: 0, y: min(step["y"] as? Double ?? 0, room)))
                    scroller.reflectScrolledClipView(scroller.contentView)
                }
                note("  scrollSettings: \(found.count) scroll view(s)")
            }
        case "dropdown":
            // Opens the nth dropdown in the Settings window, top to bottom, or closes the open one when `index` is -1.
            let index = step["index"] as? Int ?? 0
            if index < 0 { delegate?.settingsDropdowns?.close() } else { delegate?.settingsDropdowns?.openRegistered(at: index) }
        case "closeSettings":
            delegate?.settingsWindow?.close()
        case "snapshot":
            if let path = step["path"] as? String { await snapshot(to: path, window: step["window"] as? String) }
        case "log":
            note("  " + (step["text"] as? String ?? ""))
        case "quit":
            NSApp.terminate(nil)
        default:
            note("  unknown verb \(verb)")
        }
    }

    /// Sends a synthetic key-down such as "cmd+t" or "ctrl+shift+=" through the normal event path.
    private func sendChord(_ combo: String) {
        guard controller?.window != nil else { note("  chord: no window"); return }
        var flags: NSEvent.ModifierFlags = []
        var key = ""
        for part in combo.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init) {
            switch part {
            case "cmd", "command": flags.insert(.command)
            case "ctrl", "control": flags.insert(.control)
            case "opt", "alt", "option": flags.insert(.option)
            case "shift": flags.insert(.shift)
            case "": key = "+"
            default: key = part
            }
        }
        let codes: [String: (UInt16, String)] = [
            "left": (123, String(UnicodeScalar(NSLeftArrowFunctionKey)!)), "right": (124, String(UnicodeScalar(NSRightArrowFunctionKey)!)),
            "down": (125, String(UnicodeScalar(NSDownArrowFunctionKey)!)), "up": (126, String(UnicodeScalar(NSUpArrowFunctionKey)!)),
            "tab": (48, "\t"), "return": (36, "\r"), "esc": (53, "\u{1b}"), "space": (49, " "),
            "=": (24, "="), "+": (24, "="), "-": (27, "-"), "[": (33, "["), "]": (30, "]"), ",": (43, ","), ".": (47, "."), "/": (44, "/"),
            "0": (29, "0"), "1": (18, "1"), "2": (19, "2"), "3": (20, "3"), "4": (21, "4"), "5": (23, "5"), "6": (22, "6"), "7": (26, "7"), "8": (28, "8"), "9": (25, "9"),
            "a": (0, "a"), "b": (11, "b"), "c": (8, "c"), "d": (2, "d"), "e": (14, "e"), "f": (3, "f"), "g": (5, "g"), "h": (4, "h"), "i": (34, "i"), "j": (38, "j"),
            "k": (40, "k"), "l": (37, "l"), "m": (46, "m"), "n": (45, "n"), "o": (31, "o"), "p": (35, "p"), "q": (12, "q"), "r": (15, "r"), "s": (1, "s"),
            "t": (17, "t"), "u": (32, "u"), "v": (9, "v"), "w": (13, "w"), "x": (7, "x"), "y": (16, "y"), "z": (6, "z"),
        ]
        guard let (code, _) = codes[key] else { note("  chord: unknown key \(key)"); return }
        // Build the event the way the system would (from a CGEvent), so `characters` / `charactersIgnoringModifiers`
        // come from the real keyboard layout rather than from what this script claims.
        guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true) else { return }
        var cgFlags: CGEventFlags = []
        if flags.contains(.command) { cgFlags.insert(.maskCommand) }
        if flags.contains(.control) { cgFlags.insert(.maskControl) }
        if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
        if flags.contains(.shift) { cgFlags.insert(.maskShift) }
        cg.flags = cgFlags
        guard let event = NSEvent(cgEvent: cg) else { return }
        note("  chord \(combo): chars=\(event.charactersIgnoringModifiers ?? "nil") flags=\(event.modifierFlags.intersection([.command, .control, .option, .shift]).rawValue)")
        NSApp.sendEvent(event)
    }

    private static func describe(_ o: Overlay?) -> String {
        guard let o else { return "none" }
        switch o {
        case .commandBar(let m): return m == .newTab ? "commandBar(new)" : "commandBar(current)"
        case .themeEditor: return "themeEditor"
        default: return "\(o)"
        }
    }

    private func performMenu(_ title: String) {
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.title == title { return item }
                if let sub = item.submenu, let hit = find(sub) { return hit }
            }
            return nil
        }
        guard let main = NSApp.mainMenu, let item = find(main), let action = item.action else { note("  menu: \(title) not found"); return }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    // MARK: Snapshots

    /// Renders the front window with `cacheDisplay`. Web content is drawn out of process and would come out blank, so
    /// each visible web view is first snapshotted and swapped for an image view of itself in the same slot, which keeps
    /// SwiftUI overlays (Command Bar, panels, Peek) layered above it as on screen.
    private func snapshot(to path: String, window which: String? = nil) async {
        let target: NSWindow?
        switch which {
        case "probe": target = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible })
        case "settings": target = delegate?.settingsWindow
        case "menubar": target = delegate?.menuBar?.panel
        default: target = controller?.window ?? NSApp.windows.first(where: { $0.isVisible })
        }
        guard let window = target, let content = window.contentView else {
            note("  snapshot: no window"); return
        }
        var webViews: [WKWebView] = []
        func collect(_ v: NSView) {
            if let w = v as? WKWebView, !w.isHidden, w.window != nil { webViews.append(w) }
            v.subviews.forEach(collect)
        }
        collect(content)

        var swaps: [(WKWebView, NSImageView)] = []
        for w in webViews {
            let snap: NSImage? = await withCheckedContinuation { cont in
                w.takeSnapshot(with: WKSnapshotConfiguration()) { img, _ in cont.resume(returning: img) }
            }
            guard let snap, let parent = w.superview else { continue }
            let iv = NSImageView(frame: w.frame)
            iv.image = snap
            iv.imageScaling = .scaleAxesIndependently
            iv.autoresizingMask = w.autoresizingMask
            parent.addSubview(iv, positioned: .above, relativeTo: w)
            w.isHidden = true
            swaps.append((w, iv))
        }
        defer { for (w, iv) in swaps { iv.removeFromSuperview(); w.isHidden = false } }

        content.layoutSubtreeIfNeeded()
        let bounds = content.bounds
        guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else { note("  snapshot: no bitmap"); return }
        content.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { note("  snapshot: encode failed"); return }
        do {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: path))
            note("  snapshot → \(path) (\(rep.pixelsWide)×\(rep.pixelsHigh), \(swaps.count) web views)")
        } catch {
            note("  snapshot: \(error.localizedDescription)")
        }
    }
}
