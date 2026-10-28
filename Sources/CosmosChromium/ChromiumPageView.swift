import AppKit
import CosmosEngine

/// Shows a Chromium page and hands it the mouse and keyboard. Chromium draws the page in its own (windowless) process
/// and streams frames; this view puts the newest one on its layer and turns AppKit events into DevTools input events.
final class ChromiumPageView: NSView, NSTextInputClient {
    weak var page: ChromiumPage?
    private var tracking: NSTrackingArea?
    private var cursor: NSCursor = .arrow
    private var markedText = ""
    private var keyDownCommands: [String]?
    private var keyDownText: String?
    private(set) var lastContextClick: ContextClick?
    /// What the drag over the page carries, while it is over the page.
    private var dragging: [String: Any]?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL, .string, .html])
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.contentsGravity = .topLeft
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    // MARK: Frames

    func show(_ image: CGImage, scale: CGFloat) {
        layer?.contentsScale = scale
        layer?.contents = image
    }

    /// What is on screen now, for snapshots and the automation harness (`cacheDisplay` does not see layer contents).
    var currentImage: CGImage? {
        guard let contents = layer?.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
        return (contents as! CGImage)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Only reached by `cacheDisplay` (snapshots): the layer shows frames itself.
        NSColor.white.setFill()
        dirtyRect.fill()
        guard let image = currentImage, let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = layer?.contentsScale ?? 2
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        context.restoreGState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        page?.viewVisibilityChanged()
    }

    override func viewDidHide() { super.viewDidHide(); page?.viewVisibilityChanged() }
    override func viewDidUnhide() { super.viewDidUnhide(); page?.viewVisibilityChanged() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        page?.viewGeometryChanged()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        page?.viewGeometryChanged()
    }

    var isShowing: Bool { window != nil && !isHiddenOrHasHiddenAncestor }
    var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    // MARK: Accessibility

    /// The page area is the page's scroll area for VoiceOver; the page itself is in it, read from Chromium once an
    /// assistive app first looks (`ChromiumAccessibility`).
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .scrollArea }

    override func accessibilityChildren() -> [Any]? {
        guard let page else { return [] }
        let accessibility = page.accessibilityWanted()
        accessibility.touched()
        return accessibility.root.map { [$0] } ?? []
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? { page?.accessibility?.element(at: point) ?? self }

    override var accessibilityFocusedUIElement: Any? {
        guard window?.firstResponder === self, let focused = page?.accessibility?.focusedElement else { return self }
        return focused
    }

    // MARK: Cursor

    func setCursor(_ css: String) {
        cursor = Self.cursor(forCSS: css)
        window?.invalidateCursorRects(for: self)
        if let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) { cursor.set() }
    }

    static func cursor(forCSS css: String) -> NSCursor {
        switch css {
        case "pointer": return .pointingHand
        case "text", "vertical-text": return .iBeam
        case "crosshair": return .crosshair
        case "move", "all-scroll", "grab": return .openHand
        case "grabbing": return .closedHand
        case "not-allowed", "no-drop": return .operationNotAllowed
        case "ew-resize", "col-resize", "e-resize", "w-resize": return .resizeLeftRight
        case "ns-resize", "row-resize", "n-resize", "s-resize": return .resizeUpDown
        case "context-menu": return .contextualMenu
        case "copy": return .dragCopy
        case "alias": return .dragLink
        default: return .arrow
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    // MARK: Mouse

    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let zoom = page?.zoom ?? 1
        return CGPoint(x: p.x / zoom, y: p.y / zoom)
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var m: KeyMapping.Modifiers = []
        if flags.contains(.option) { m.insert(.alt) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.command) { m.insert(.meta) }
        if flags.contains(.shift) { m.insert(.shift) }
        return m.rawValue
    }

    private var pressedButtons = 0

    private func mouse(_ type: String, _ event: NSEvent, button: String, buttonBit: Int) {
        if type == "mousePressed" { pressedButtons |= buttonBit } else if type == "mouseReleased" { pressedButtons &= ~buttonBit }
        let p = point(event)
        var params: [String: Any] = ["type": type, "x": p.x, "y": p.y, "modifiers": Self.modifiers(event.modifierFlags),
                                     "button": button, "buttons": pressedButtons]
        if type != "mouseMoved" { params["clickCount"] = event.clickCount }
        page?.input("Input.dispatchMouseEvent", params)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.control) { noteContextClick(event) }
        mouse("mousePressed", event, button: "left", buttonBit: 1)
    }
    override func mouseUp(with event: NSEvent) { mouse("mouseReleased", event, button: "left", buttonBit: 1) }
    override func mouseDragged(with event: NSEvent) { mouse("mouseMoved", event, button: "left", buttonBit: 1) }
    override func mouseMoved(with event: NSEvent) { mouse("mouseMoved", event, button: "none", buttonBit: 0) }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        noteContextClick(event)
        mouse("mousePressed", event, button: "right", buttonBit: 2)
    }
    override func rightMouseUp(with event: NSEvent) { mouse("mouseReleased", event, button: "right", buttonBit: 2) }
    override func rightMouseDragged(with event: NSEvent) { mouse("mouseMoved", event, button: "right", buttonBit: 2) }
    override func otherMouseDown(with event: NSEvent) { mouse("mousePressed", event, button: "middle", buttonBit: 4) }
    override func otherMouseUp(with event: NSEvent) { mouse("mouseReleased", event, button: "middle", buttonBit: 4) }
    override func otherMouseDragged(with event: NSEvent) { mouse("mouseMoved", event, button: "middle", buttonBit: 4) }

    /// How hard the trackpad is pressed: stage 2 is a Force Click.
    private var pressureStage = 0

    override func pressureChange(with event: NSEvent) {
        if event.stage == 2 && pressureStage < 2 { page?.forceClicked() }
        pressureStage = event.stage
    }

    override func mouseExited(with event: NSEvent) {
        // Far outside the page, so hover effects end.
        page?.input("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": -1, "y": -1, "button": "none", "buttons": 0])
    }

    override func scrollWheel(with event: NSEvent) {
        let zoom = page?.zoom ?? 1
        let lines: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 40
        let dx = -event.scrollingDeltaX * lines / zoom
        let dy = -event.scrollingDeltaY * lines / zoom
        guard dx != 0 || dy != 0 else { return }
        page?.accessibility?.refreshSoon(after: 0.3)
        let p = point(event)
        page?.input("Input.dispatchMouseEvent", ["type": "mouseWheel", "x": p.x, "y": p.y, "deltaX": dx, "deltaY": dy,
                                                 "modifiers": Self.modifiers(event.modifierFlags), "button": "none", "buttons": pressedButtons])
    }

    /// The last right (or control) click, if it was recent enough to be the one a context menu is for: a menu from the
    /// keyboard's menu key is not tied to a click from half a minute ago.
    func recentContextClick(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> ContextClick? {
        guard let click = lastContextClick, now - click.uptime < 1.5 else { return nil }
        return click
    }

    private func noteContextClick(_ event: NSEvent) {
        lastContextClick = ContextClick(location: event.locationInWindow, modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
                                        uptime: event.timestamp)
    }

    // MARK: Drops

    /// What a drag from another app carries, as Chromium takes it: files, links, text. Nil for a drag that started in
    /// Cosmos itself (a sidebar tab): pages never get those.
    static func dragData(from pasteboard: NSPasteboard, fromInsideCosmos: Bool) -> [String: Any]? {
        guard !fromInsideCosmos else { return nil }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        let files = urls.filter(\.isFileURL).map(\.path)
        var items: [[String: Any]] = []
        let links = urls.filter { !$0.isFileURL }.map(\.absoluteString)
        if !links.isEmpty { items.append(["mimeType": "text/uri-list", "data": links.joined(separator: "\r\n")]) }
        if let text = pasteboard.string(forType: .string) { items.append(["mimeType": "text/plain", "data": text]) }
        if let html = pasteboard.string(forType: .html) { items.append(["mimeType": "text/html", "data": html]) }
        guard !files.isEmpty || !items.isEmpty else { return nil }
        // Copy, link or move: the page chooses.
        var data: [String: Any] = ["items": items, "dragOperationsMask": 1 | 2 | 16]
        if !files.isEmpty { data["files"] = files }
        return data
    }

    func sendDrag(_ type: String, data: [String: Any], at point: CGPoint) {
        let zoom = page?.zoom ?? 1
        page?.input("Input.dispatchDragEvent", ["type": type, "x": point.x / zoom, "y": point.y / zoom, "data": data,
                                                "modifiers": Self.modifiers(NSEvent.modifierFlags)])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // A drag from another app has no source in Cosmos.
        dragging = Self.dragData(from: sender.draggingPasteboard, fromInsideCosmos: sender.draggingSource != nil)
        guard let dragging else { return [] }
        sendDrag("dragEnter", data: dragging, at: convert(sender.draggingLocation, from: nil))
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let dragging else { return [] }
        sendDrag("dragOver", data: dragging, at: convert(sender.draggingLocation, from: nil))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let dragging { sendDrag("dragCancel", data: dragging, at: .zero) }
        dragging = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let dragging else { return false }
        sendDrag("drop", data: dragging, at: convert(sender.draggingLocation, from: nil))
        self.dragging = nil
        return true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        keyDownCommands = []
        keyDownText = nil
        let wasComposing = hasMarkedText()
        interpretKeyEvents([event])
        let commands = KeyMapping.commands(fromSelectors: keyDownCommands ?? [])
        let text = keyDownText
        keyDownCommands = nil
        keyDownText = nil
        // A key the input method used (composing kana, choosing a candidate) is not the page's.
        if wasComposing || hasMarkedText() { return }
        send(event, type: text == nil ? "rawKeyDown" : "keyDown", text: text, commands: commands)
        // Tab moves the focus, arrows and space scroll: what VoiceOver reads may have changed.
        page?.accessibility?.refreshSoon(after: 0.3)
    }

    override func keyUp(with event: NSEvent) {
        if hasMarkedText() { return }
        send(event, type: "keyUp", text: nil, commands: [])
    }

    override func flagsChanged(with event: NSEvent) {
        guard let key = KeyMapping.keys[event.keyCode], let name = key.named else { return }
        let down: Bool = switch name {
        case "Shift": event.modifierFlags.contains(.shift)
        case "Control": event.modifierFlags.contains(.control)
        case "Alt": event.modifierFlags.contains(.option)
        case "Meta": event.modifierFlags.contains(.command)
        case "CapsLock": event.modifierFlags.contains(.capsLock)
        default: false
        }
        page?.input("Input.dispatchKeyEvent", ["type": down ? "rawKeyDown" : "keyUp", "key": name, "code": key.code,
                                               "windowsVirtualKeyCode": key.windowsCode, "modifiers": Self.modifiers(event.modifierFlags)])
    }

    private func send(_ event: NSEvent, type: String, text: String?, commands: [String]) {
        let key = KeyMapping.keys[event.keyCode]
        var params: [String: Any] = [
            "type": type,
            "modifiers": Self.modifiers(event.modifierFlags),
            "key": KeyMapping.domKey(keyCode: event.keyCode, characters: event.characters, ignoringModifiers: event.charactersIgnoringModifiers,
                                     control: event.modifierFlags.contains(.control)),
            "code": key?.code ?? "",
            "windowsVirtualKeyCode": key?.windowsCode ?? 0,
            "nativeVirtualKeyCode": Int(event.keyCode),
            "autoRepeat": type != "keyUp" && event.isARepeat,
            "isKeypad": key?.code.hasPrefix("Numpad") ?? false,
        ]
        var text = text
        // Return types a line break and submits forms; the Mac's key bindings only name the command.
        if type != "keyUp", text == nil, key?.named == "Enter" { text = "\r"; params["type"] = "keyDown" }
        if let text { params["text"] = text; params["unmodifiedText"] = event.charactersIgnoringModifiers ?? text }
        if !commands.isEmpty { params["commands"] = commands }
        page?.input("Input.dispatchKeyEvent", params)
    }

    override func doCommand(by selector: Selector) {
        if keyDownCommands != nil { keyDownCommands?.append(NSStringFromSelector(selector)) }
        else { page?.runEditingCommand(KeyMapping.commands(fromSelectors: [NSStringFromSelector(selector)])) }
    }

    // Edit menu items (and ⌘C, ⌘V, ... through them).
    @objc func copy(_ sender: Any?) { page?.perform(.copy) }
    @objc func cut(_ sender: Any?) { page?.perform(.cut) }
    @objc func paste(_ sender: Any?) { page?.perform(.paste) }
    @objc override func selectAll(_ sender: Any?) { page?.perform(.selectAll) }
    @objc func undo(_ sender: Any?) { page?.perform(.undo) }
    @objc func redo(_ sender: Any?) { page?.perform(.redo) }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if keyDownCommands != nil && markedText.isEmpty {
            keyDownText = (keyDownText ?? "") + text
        } else {
            markedText = ""
            page?.input("Input.insertText", ["text": text])
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        page?.input("Input.imeSetComposition", ["text": markedText, "selectionStart": selectedRange.location,
                                                "selectionEnd": selectedRange.location + selectedRange.length])
    }

    func unmarkText() {
        guard !markedText.isEmpty else { return }
        page?.input("Input.insertText", ["text": markedText])
        markedText = ""
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: (markedText as NSString).length) }
    func hasMarkedText() -> Bool { !markedText.isEmpty }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// Where the input method's candidate window goes: under the caret the page reported, or the middle of the view.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let caret = page?.caretRect ?? CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 18)
        let inWindow = convert(caret, to: nil)
        return window?.convertToScreen(inWindow) ?? inWindow
    }
}
