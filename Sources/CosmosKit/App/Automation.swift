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
                note("  space=\(s.workspace.space(st.focusedSpaceID)?.title ?? "?") overlay=\(String(describing: st.overlay)) tab=\(rt?.title ?? "-") url=\(rt?.url?.host ?? "-") loading=\(rt?.isLoading ?? false) tabs=\(s.workspace.allTabs().count)")
            }
        case "snapshot":
            if let path = step["path"] as? String { await snapshot(to: path) }
        case "log":
            note("  " + (step["text"] as? String ?? ""))
        case "quit":
            NSApp.terminate(nil)
        default:
            note("  unknown verb \(verb)")
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
    private func snapshot(to path: String) async {
        guard let window = controller?.window ?? NSApp.windows.first(where: { $0.isVisible }), let content = window.contentView else {
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
