import AppKit

/// One thing on a page as an assistive app reads it: Chromium's accessibility tree of a document
/// (`Accessibility.getFullAXTree`), with what no one reads left out (ignored nodes, wrappers without a name, the boxes
/// text is laid out in) and what those held moved up to their parent.
struct AXPageNode: Equatable {
    var id: String
    /// Chromium's role: "heading", "link", "StaticText"…
    var role: String
    var name: String
    var value: String? = nil
    var description: String? = nil
    /// Chromium's properties as text: "level" "2", "focused" "true", "url" "https://…".
    var properties: [String: String] = [:]
    var backendNodeID: Int? = nil
    var children: [AXPageNode] = []
    /// Set by `ChromiumAccessibility`: the session and document (frame) the node is in, and where it is in the page, in
    /// CSS pixels of the page's viewport.
    var session: String? = nil
    var frame: String? = nil
    var rect: CGRect? = nil

    /// Roles that only lay things out: left out when they have no name of their own.
    private static let wrappers: Set<String> = ["generic", "Section", "LayoutTable", "LayoutTableRow", "LayoutTableCell", "LayoutTableColumn", "none", "presentation"]
    /// Left out with whatever they hold.
    private static let unread: Set<String> = ["InlineTextBox", "LineBreak"]

    static func tree(_ nodes: [[String: Any]]) -> AXPageNode? {
        var byID: [String: [String: Any]] = [:]
        for n in nodes { if let id = n["nodeId"] as? String { byID[id] = n } }
        guard let rootID = nodes.first(where: { $0["parentId"] == nil })?["nodeId"] as? String ?? nodes.first?["nodeId"] as? String else { return nil }
        var seen: Set<String> = []

        func text(_ v: Any?) -> String? {
            guard let v = v as? [String: Any], let value = v["value"] else { return nil }
            switch v["type"] as? String {
            case "boolean", "booleanOrUndefined": return (value as? Bool) == true ? "true" : "false"
            case "integer", "number": return (value as? NSNumber)?.stringValue
            default: return value as? String
            }
        }
        func build(_ id: String) -> [AXPageNode] {
            guard let n = byID[id], seen.insert(id).inserted else { return [] }
            let role = text(n["role"]) ?? "generic"
            if unread.contains(role) { return [] }
            let children = (n["childIds"] as? [String] ?? []).flatMap(build)
            let name = text(n["name"]) ?? ""
            if n["ignored"] as? Bool == true || (wrappers.contains(role) && name.isEmpty) { return children }
            if role == "StaticText" && name.isEmpty { return [] }
            var properties: [String: String] = [:]
            for p in n["properties"] as? [[String: Any]] ?? [] {
                if let key = p["name"] as? String, let value = text(p["value"]) { properties[key] = value }
            }
            return [AXPageNode(id: id, role: role, name: name, value: text(n["value"]).flatMap { $0.isEmpty ? nil : $0 },
                               description: text(n["description"]).flatMap { $0.isEmpty ? nil : $0 }, properties: properties,
                               backendNodeID: n["backendDOMNodeId"] as? Int, children: children)]
        }
        return build(rootID).first
    }

    /// The role, subrole and (for roles AppKit has no words for) role description VoiceOver gets.
    var macRole: (role: NSAccessibility.Role, subrole: NSAccessibility.Subrole?, description: String?) {
        func custom(_ r: String) -> NSAccessibility.Role { NSAccessibility.Role(rawValue: r) }
        func sub(_ s: String) -> NSAccessibility.Subrole { NSAccessibility.Subrole(rawValue: s) }
        switch role {
        case "RootWebArea", "WebArea": return (custom("AXWebArea"), nil, "HTML content")
        case "heading": return (custom("AXHeading"), nil, "heading")
        case "link": return (.link, nil, nil)
        case "button", "ToggleButton", "DisclosureTriangle": return (.button, nil, nil)
        case "PopUpButton": return (.popUpButton, nil, nil)
        case "StaticText", "ListMarker": return (.staticText, nil, nil)
        case "image", "img", "Canvas", "SvgRoot", "graphics-document": return (.image, nil, nil)
        case "textbox", "searchbox":
            if properties["multiline"] == "true" { return (.textArea, nil, nil) }
            return (.textField, role == "searchbox" ? .searchField : nil, nil)
        case "checkbox", "menuitemcheckbox": return (.checkBox, nil, nil)
        case "switch": return (.checkBox, .switch, nil)
        case "radio", "menuitemradio": return (.radioButton, nil, nil)
        case "combobox": return (.comboBox, nil, nil)
        case "listbox", "list", "DescriptionList", "directory": return (.list, nil, nil)
        case "option", "ListBoxOption": return (.staticText, nil, "option")
        case "table", "grid", "treegrid": return (.table, nil, nil)
        case "row": return (.row, nil, nil)
        case "cell", "gridcell", "columnheader", "rowheader": return (.cell, nil, nil)
        case "slider": return (.slider, nil, nil)
        case "progressbar", "meter": return (.progressIndicator, nil, nil)
        case "spinbutton": return (.incrementor, nil, nil)
        case "menu": return (.menu, nil, nil)
        case "menubar": return (.menuBar, nil, nil)
        case "menuitem": return (.menuItem, nil, nil)
        case "tab": return (.radioButton, sub("AXTabButton"), "tab")
        case "tablist": return (.tabGroup, nil, nil)
        case "tree": return (.outline, nil, nil)
        case "treeitem": return (.row, .outlineRow, nil)
        case "separator", "splitter": return (.splitter, nil, nil)
        case "dialog", "alertdialog": return (.group, sub("AXApplicationDialog"), "dialog")
        case "alert": return (.group, sub("AXApplicationAlert"), "alert")
        case "status": return (.group, sub("AXApplicationStatus"), "status")
        case "navigation": return (.group, sub("AXLandmarkNavigation"), "navigation")
        case "main": return (.group, sub("AXLandmarkMain"), "main")
        case "banner": return (.group, sub("AXLandmarkBanner"), "banner")
        case "contentinfo": return (.group, sub("AXLandmarkContentInfo"), "content information")
        case "complementary": return (.group, sub("AXLandmarkComplementary"), "complementary")
        case "search": return (.group, sub("AXLandmarkSearch"), "search")
        case "region": return (.group, sub("AXLandmarkRegion"), "region")
        case "article": return (.group, sub("AXDocumentArticle"), "article")
        default: return (.group, nil, nil)
        }
    }

    /// What a press does something to: VoiceOver offers "press" only on these.
    var isPressable: Bool {
        ["link", "button", "ToggleButton", "DisclosureTriangle", "PopUpButton", "checkbox", "menuitemcheckbox", "switch", "radio",
         "menuitemradio", "option", "ListBoxOption", "tab", "menuitem", "treeitem", "combobox", "StaticText", "image"].contains(role)
    }
}

/// A page's thing as AppKit's accessibility hands it to VoiceOver. The elements are kept from one reading of the tree
/// to the next, so VoiceOver keeps its place while the page changes.
final class ChromiumAXElement: NSAccessibilityElement {
    private(set) var node: AXPageNode
    fileprivate(set) var kids: [ChromiumAXElement] = []
    fileprivate weak var parentElement: ChromiumAXElement?
    fileprivate weak var controller: ChromiumAccessibility?

    fileprivate init(node: AXPageNode, controller: ChromiumAccessibility) {
        self.node = node
        self.controller = controller
        super.init()
    }

    fileprivate func update(_ node: AXPageNode) { self.node = node }

    /// Where it is in the page area, in points; nil when it is not laid out.
    var rectInView: CGRect? {
        guard let r = node.rect else { return nil }
        // AppKit asks on the main thread.
        let zoom = MainActor.assumeIsolated { controller?.page?.zoom ?? 1 }
        return CGRect(x: r.minX * zoom, y: r.minY * zoom, width: r.width * zoom, height: r.height * zoom)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { node.macRole.role }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { node.macRole.subrole }
    override func accessibilityRoleDescription() -> String? {
        let mac = node.macRole
        return node.properties["roledescription"] ?? mac.description ?? mac.role.description(with: mac.subrole)
    }
    override func accessibilityLabel() -> String? { node.macRole.role == .staticText ? nil : node.name }
    override func accessibilityHelp() -> String? { node.description }

    override func accessibilityValue() -> Any? {
        switch node.macRole.role {
        case .staticText: return node.name
        case .checkBox, .radioButton:
            switch node.properties["checked"] ?? node.properties["pressed"] ?? node.properties["selected"] {
            case "true": return 1
            case "mixed": return 2
            default: return 0
            }
        case .slider, .progressIndicator, .incrementor: return node.properties["valuetext"] ?? node.value.flatMap(Double.init).map { $0 as Any } ?? node.value
        default:
            if node.role == "heading", let level = node.properties["level"].flatMap(Int.init) { return level }
            return node.value
        }
    }

    override func accessibilityURL() -> URL? { node.properties["url"].flatMap(URL.init(string:)) }
    override func isAccessibilityEnabled() -> Bool { node.properties["disabled"] != "true" }
    override func isAccessibilityFocused() -> Bool { node.properties["focused"] == "true" }
    override func isAccessibilitySelected() -> Bool { node.properties["selected"] == "true" }
    override func isAccessibilityExpanded() -> Bool { node.properties["expanded"] == "true" }
    override func isAccessibilityRequired() -> Bool { node.properties["required"] == "true" }

    override func setAccessibilityFocused(_ focused: Bool) {
        if focused { MainActor.assumeIsolated { controller?.focus(self) } }
    }

    override func accessibilityParent() -> Any? { parentElement ?? MainActor.assumeIsolated { controller?.page?.pageView } }

    override func accessibilityChildren() -> [Any]? {
        MainActor.assumeIsolated { controller?.touched() }
        return kids
    }

    override func accessibilityFrame() -> NSRect {
        guard let view = MainActor.assumeIsolated({ controller?.page?.pageView }), let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(rectInView ?? view.bounds, to: nil))
    }

    override func accessibilityPerformPress() -> Bool {
        guard let controller, node.backendNodeID != nil else { return false }
        MainActor.assumeIsolated { controller.press(self) }
        return true
    }

    /// VoiceOver offers what an element answers to: no "press" on a paragraph.
    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(accessibilityPerformPress) { return node.isPressable }
        return super.responds(to: selector)
    }

    /// The deepest element at `point` (on screen), the last drawn first.
    fileprivate func hit(_ point: NSPoint) -> ChromiumAXElement? {
        for kid in kids.reversed() { if let found = kid.hit(point) { return found } }
        return node.rect != nil && accessibilityFrame().contains(point) ? self : nil
    }

    fileprivate func first(where test: (ChromiumAXElement) -> Bool) -> ChromiumAXElement? {
        if test(self) { return self }
        for kid in kids { if let found = kid.first(where: test) { return found } }
        return nil
    }
}

/// What VoiceOver reads on a Chromium page. Headless Chromium has no window to hang its accessibility tree on, so Cosmos
/// asks for the tree over DevTools once an assistive app first looks at the page, lays it out in the page area (frames
/// from other sites, which have trees of their own, included) and reads it again when the page changes, scrolls, or the
/// app looks again a second later.
@MainActor
final class ChromiumAccessibility {
    /// Weak: a reading under way outlives a tab that closes meanwhile.
    private(set) weak var page: ChromiumPage?
    private(set) var root: ChromiumAXElement?
    private var elements: [String: ChromiumAXElement] = [:]
    private var reading = false
    private var readAgain = false
    /// Waiting for the reading under way, and the one after it, to finish.
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var scheduled: Task<Void, Never>?
    private var lastRead = Date.distantPast
    /// The page finished loading: VoiceOver hears so once it is read, and starts reading it.
    private var announceLoad = false
    private var focused: ChromiumAXElement?

    init(page: ChromiumPage) {
        self.page = page
        if let session = page.sessionID { page.browser.connection?.post("Accessibility.enable", session: session) }
    }

    // MARK: Reading

    /// The page changed (or scrolled): read it again shortly, if anyone can see it.
    func refreshSoon(after delay: Double = 0.2) {
        guard scheduled == nil, page?.pageView.window != nil else { return }
        scheduled = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.scheduled = nil
            await self?.refresh()
        }
    }

    func pageLoaded() {
        announceLoad = true
        refreshSoon(after: 0)
    }

    /// An assistive app looked: the tree it reads is at most a second old.
    func touched() {
        guard !reading, Date().timeIntervalSince(lastRead) > 1 else { return }
        Task { await refresh() }
    }

    /// Reads the tree now; with a reading under way, waits for it and for one more that starts after this call.
    func refresh() async {
        if reading {
            readAgain = true
            await withCheckedContinuation { waiting.append($0) }
            return
        }
        reading = true
        repeat {
            readAgain = false
            if let session = page?.sessionID, let tree = await tree(in: session, frame: nil, offset: .zero, rects: nil, depth: 0) {
                lastRead = Date()
                apply(tree)
            }
        } while readAgain
        reading = false
        let done = waiting
        waiting = []
        done.forEach { $0.resume() }
    }

    private func send(_ method: String, _ params: [String: Any] = [:], _ session: String) async -> [String: Any]? {
        try? await page?.browser.connection?.send(method, params, session: session)
    }

    /// The tree of one document: the page's (`frame` nil) or a frame's, `offset` from the page's top left.
    private func tree(in session: String, frame: String?, offset: CGPoint, rects known: [String: [Int: CGRect]]?, depth: Int) async -> AXPageNode? {
        guard let r = await send("Accessibility.getFullAXTree", frame.map { ["frameId": $0] } ?? [:], session),
              let nodes = r["nodes"] as? [[String: Any]], let root = AXPageNode.tree(nodes) else { return nil }
        let rects: [String: [Int: CGRect]]
        if let known { rects = known } else { rects = await layout(in: session) }
        let document = frame ?? nodes.first?["frameId"] as? String
        return await place(root, session: session, frame: document, offset: offset, rects: rects, depth: depth)
    }

    /// Where each node of each document of a session is, in that document's viewport (in CSS pixels: the snapshot has
    /// device pixels).
    private func layout(in session: String) async -> [String: [Int: CGRect]] {
        _ = await send("DOM.getDocument", ["depth": 0], session)
        guard let r = await send("DOMSnapshot.captureSnapshot", ["computedStyles": []], session),
              let strings = r["strings"] as? [String], let documents = r["documents"] as? [[String: Any]] else { return [:] }
        guard let scale = page?.layoutScale else { return [:] }
        var all: [String: [Int: CGRect]] = [:]
        for d in documents {
            guard let f = d["frameId"] as? Int, strings.indices.contains(f), let nodes = d["nodes"] as? [String: Any],
                  let backend = nodes["backendNodeId"] as? [Int], let layout = d["layout"] as? [String: Any],
                  let index = layout["nodeIndex"] as? [Int], let bounds = layout["bounds"] as? [[Double]] else { continue }
            let sx = d["scrollOffsetX"] as? Double ?? 0, sy = d["scrollOffsetY"] as? Double ?? 0
            var rects: [Int: CGRect] = [:]
            for (i, n) in index.enumerated() where i < bounds.count && backend.indices.contains(n) && bounds[i].count == 4 {
                let b = bounds[i]
                let rect = CGRect(x: (b[0] - sx) / scale, y: (b[1] - sy) / scale, width: b[2] / scale, height: b[3] / scale)
                rects[backend[n]] = rects[backend[n]].map { $0.union(rect) } ?? rect
            }
            all[strings[f]] = rects
        }
        return all
    }

    private func place(_ node: AXPageNode, session: String, frame: String?, offset: CGPoint, rects: [String: [Int: CGRect]], depth: Int) async -> AXPageNode {
        var node = node
        node.session = session
        node.frame = frame
        if let b = node.backendNodeID, let frame, let r = rects[frame]?[b] { node.rect = r.offsetBy(dx: offset.x, dy: offset.y) }
        var children: [AXPageNode] = []
        for child in node.children { children.append(await place(child, session: session, frame: frame, offset: offset, rects: rects, depth: depth)) }
        if node.role == "Iframe", children.isEmpty, depth < 4, let b = node.backendNodeID,
           let content = await frameContent(owner: b, session: session, offset: offset, rects: rects, depth: depth) {
            children = [content]
        }
        node.children = children
        if node.rect == nil { node.rect = children.compactMap(\.rect).reduce(nil) { (sum: CGRect?, r: CGRect) in sum?.union(r) ?? r } }
        return node
    }

    /// What an iframe shows: a document of the same process (and session), or of a frame from another site, with a
    /// session of its own.
    private func frameContent(owner: Int, session: String, offset: CGPoint, rects: [String: [Int: CGRect]], depth: Int) async -> AXPageNode? {
        guard let described = await send("DOM.describeNode", ["backendNodeId": owner], session),
              let child = (described["node"] as? [String: Any])?["frameId"] as? String,
              let model = (await send("DOM.getBoxModel", ["backendNodeId": owner], session))?["model"] as? [String: Any],
              let quad = model["content"] as? [Double], quad.count >= 2 else { return nil }
        let inner = CGPoint(x: offset.x + quad[0], y: offset.y + quad[1])
        if let other = page?.session(forFrame: child) {
            return await tree(in: other, frame: nil, offset: inner, rects: nil, depth: depth + 1)
        }
        return await tree(in: session, frame: child, offset: inner, rects: rects, depth: depth + 1)
    }

    /// Hands the tree to AppKit, keeping the elements VoiceOver already knows.
    private func apply(_ tree: AXPageNode) {
        var next: [String: ChromiumAXElement] = [:]
        func element(_ node: AXPageNode, parent: ChromiumAXElement?) -> ChromiumAXElement {
            let key = "\(node.session ?? "")/\(node.frame ?? "")/\(node.id)"
            let e: ChromiumAXElement
            if let old = elements[key], next[key] == nil { e = old; e.update(node) } else { e = ChromiumAXElement(node: node, controller: self) }
            next[key] = e
            e.parentElement = parent
            e.kids = node.children.map { element($0, parent: e) }
            return e
        }
        let top = element(tree, parent: nil)
        elements = next
        root = top
        NSAccessibility.post(element: top, notification: .layoutChanged)
        let nowFocused = top.first { $0.node.properties["focused"] == "true" && $0 !== top }
        if nowFocused !== focused {
            focused = nowFocused
            if let nowFocused { NSAccessibility.post(element: nowFocused, notification: .focusedUIElementChanged) }
        }
        if announceLoad {
            announceLoad = false
            NSAccessibility.post(element: top, notification: NSAccessibility.Notification(rawValue: "AXLoadComplete"))
        }
    }

    // MARK: Answers

    func element(at point: NSPoint) -> ChromiumAXElement? { root?.hit(point) }

    var focusedElement: ChromiumAXElement? { focused }

    /// A real click in the middle of it, once it is in sight (the page, and the frames it is in, scroll to it; from a
    /// frame of another site's process the page scrolls a moment later).
    func press(_ element: ChromiumAXElement) {
        guard let session = element.node.session, let backend = element.node.backendNodeID else { return }
        Task {
            let before = element.node.rect
            _ = await send("DOM.scrollIntoViewIfNeeded", ["backendNodeId": backend], session)
            guard let size = page?.pageView.bounds.size, let zoom = page?.zoom else { return }
            let viewport = CGRect(x: 0, y: 0, width: size.width / zoom, height: size.height / zoom)
            for _ in 0..<20 {
                await refresh()
                if let r = element.node.rect, viewport.contains(CGPoint(x: r.midX, y: r.midY)) { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let r = element.node.rect, let main = page?.sessionID else { return }
            if r != before {
                // Chromium sends a click to the frame it last drew at that spot: wait for the page to be drawn where it
                // is now (or a moment, for a page that is not being drawn).
                _ = await send("Runtime.evaluate", ["expression": "new Promise(r => { let n = 3; const f = () => --n ? requestAnimationFrame(f) : r(); requestAnimationFrame(f); setTimeout(r, 300); })",
                                                    "awaitPromise": true], main)
            }
            let x = r.midX, y = r.midY
            page?.input("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": x, "y": y, "button": "none", "buttons": 0])
            page?.input("Input.dispatchMouseEvent", ["type": "mousePressed", "x": x, "y": y, "button": "left", "buttons": 1, "clickCount": 1])
            page?.input("Input.dispatchMouseEvent", ["type": "mouseReleased", "x": x, "y": y, "button": "left", "buttons": 0, "clickCount": 1])
        }
    }

    /// VoiceOver moved into a field: the page puts its cursor there, and the keyboard goes to the page.
    func focus(_ element: ChromiumAXElement) {
        guard let session = element.node.session, let backend = element.node.backendNodeID else { return }
        if let view = page?.pageView { view.window?.makeFirstResponder(view) }
        Task {
            _ = await send("DOM.focus", ["backendNodeId": backend], session)
            refreshSoon()
        }
    }
}
