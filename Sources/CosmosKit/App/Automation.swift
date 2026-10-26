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
            switch step["name"] as? String ?? "" {
            case "commandBar": st.overlay = .commandBar(step["mode"] as? String == "current" ? .currentTab : .newTab)
            case "archive": st.overlay = .archive
            case "history": st.overlay = .history
            case "downloads": st.overlay = .downloads
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
                note("  space=\(s.workspace.space(st.focusedSpaceID)?.title ?? "?") overlay=\(Self.describe(st.overlay)) section=\(section) split=\(split) sidebar=\(st.sidebarVisible) tab=\(rt?.title.prefix(24) ?? "-") url=\(rt?.url?.host ?? "-") tabs=\(s.workspace.allTabs().count) archived=\(s.archive.entries.count) windows=\(delegate?.controllers.count ?? 0) probes=\(delegate?.probeCount ?? 0) blocker=\(s.blocker.map { "\($0.installedRuleCount) rules\($0.isUpdating ? ", updating" : "")" } ?? "off")")
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
        guard let window = controller?.window else { note("  chord: no window"); return }
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
