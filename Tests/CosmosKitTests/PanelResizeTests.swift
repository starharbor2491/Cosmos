import AppKit
import SwiftUI
import Testing
@testable import CosmosKit
@testable import CosmosCore

/// The menu-bar panel is resized by its edges and corners: the strips of sky around the page. The page and the controls keep
/// their own clicks.
@MainActor
@Suite struct PanelResizeTests {
    private typealias Edges = MenuBarPlacement.Edges

    private func rig() -> (NSWindow, PanelResizeArea.ResizeView) {
        let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 400, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        let view = PanelResizeArea.ResizeView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        window.contentView = view
        return (window, view)
    }

    private func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func theEdgesAndCornersTakeHoldAndTheMiddleDoesNot() {
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)
        func edges(_ x: CGFloat, _ y: CGFloat) -> Edges { PanelResizeArea.ResizeView.edges(at: NSPoint(x: x, y: y), in: bounds) }
        #expect(edges(200, 150).isEmpty, "the page is the page's")
        #expect(edges(2, 150) == .left)
        #expect(edges(398, 150) == .right)
        #expect(edges(200, 2) == .bottom)
        #expect(edges(200, 298) == .top)
        #expect(edges(3, 3) == [.left, .bottom])
        #expect(edges(397, 297) == [.right, .top])
        #expect(edges(10, 290) == [.left, .top], "a corner is a square, wider than the strips")
        #expect(edges(12, 150).isEmpty, "but only at the corner")
        #expect(edges(-1, 150).isEmpty && edges(200, 301).isEmpty, "outside the panel is not on it")
    }

    @Test func draggingTheRightEdgeWidensThePanelAndLeavesTheRestAlone() {
        let (window, view) = rig()
        view.mouseDown(with: mouse(.leftMouseDown, 398, 200, in: window))
        view.mouseDragged(with: mouse(.leftMouseDragged, 428, 200, in: window))
        #expect(window.frame.size.width == 430, "30 points wider")
        #expect(window.frame.minX == 300 && window.frame.minY == 300 && window.frame.height == 400)
    }

    @Test func draggingTheBottomLeftCornerMovesBothOfItsSides() {
        let (window, view) = rig()
        let before = window.frame
        view.mouseDown(with: mouse(.leftMouseDown, 3, 3, in: window))
        // To the left and down: wider and taller, the top right staying where it was.
        view.mouseDragged(with: mouse(.leftMouseDragged, -17, -22, in: window))
        #expect(window.frame.maxX == before.maxX && window.frame.maxY == before.maxY)
        #expect(window.frame.width == 420 && window.frame.height == 425, "20 to the left of where it was taken, 25 below")
    }

    @Test func thePanelNeverShrinksPastItsLeastSize() {
        let (window, view) = rig()
        view.mouseDown(with: mouse(.leftMouseDown, 398, 398, in: window))
        view.mouseDragged(with: mouse(.leftMouseDragged, -100_000, -100_000, in: window))
        #expect(window.frame.width == MenuBarPlacement.minimumSize.width && window.frame.height == MenuBarPlacement.minimumSize.height)
    }

    @Test func theSizeIsReportedWhenThePointerIsLetGoAndNotBefore() {
        let (window, view) = rig()
        var reported: [CGSize] = []
        view.onResized = { reported.append($0) }
        view.mouseDown(with: mouse(.leftMouseDown, 398, 200, in: window))
        view.mouseDragged(with: mouse(.leftMouseDragged, 418, 200, in: window))
        #expect(reported.isEmpty, "the setting is written once, not at every step of the drag")
        view.mouseUp(with: mouse(.leftMouseUp, 418, 200, in: window))
        #expect(reported == [CGSize(width: 420, height: 400)])
        view.mouseUp(with: mouse(.leftMouseUp, 418, 200, in: window))
        #expect(reported.count == 1, "a release with nothing held reports nothing")
    }

    @Test func aDragThatDidNotStartOnAnEdgeDoesNothing() {
        let (window, view) = rig()
        var reported: [CGSize] = []
        view.onResized = { reported.append($0) }
        view.mouseDown(with: mouse(.leftMouseDown, 200, 200, in: window))
        view.mouseDragged(with: mouse(.leftMouseDragged, 260, 260, in: window))
        view.mouseUp(with: mouse(.leftMouseUp, 260, 260, in: window))
        #expect(window.frame == NSRect(x: 300, y: 300, width: 400, height: 400))
        #expect(reported.isEmpty)
    }

    @Test func aReleasedPointerLeavesThePanelAlone() {
        let (window, view) = rig()
        view.mouseDown(with: mouse(.leftMouseDown, 398, 200, in: window))
        view.mouseUp(with: mouse(.leftMouseUp, 398, 200, in: window))
        view.mouseDragged(with: mouse(.leftMouseDragged, 450, 200, in: window))
        #expect(window.frame.width == 400)
    }

    /// What is under the pointer in the real panel: the strip along each edge resizes it; the page does not.
    @Test func theEdgesOfThePanelAreItsHandleAndThePageIsNot() throws {
        let rig = Rig()
        rig.store.settings.menuBar.homeAddress = "about:blank"
        let session = MenuBarSession(store: rig.store)
        session.prepare()
        let host = NSHostingView(rootView: MenuBarBrowserView(store: rig.store, session: session))
        let size = rig.store.settings.menuBar.size
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        func isHandle(_ view: NSView?) -> Bool { view is PanelResizeArea.ResizeView }
        // Window coordinates run up from the bottom.
        #expect(isHandle(host.hitTest(NSPoint(x: size.width / 2, y: size.height - 3))), "the strip along the top")
        #expect(isHandle(host.hitTest(NSPoint(x: 3, y: size.height / 2))), "the strip down the left")
        #expect(isHandle(host.hitTest(NSPoint(x: size.width - 3, y: size.height / 2))), "the strip down the right")
        #expect(isHandle(host.hitTest(NSPoint(x: size.width / 2, y: 3))), "the strip along the bottom")
        #expect(isHandle(host.hitTest(NSPoint(x: size.width - 3, y: 3))), "a corner")
        #expect(!isHandle(host.hitTest(NSPoint(x: size.width / 2, y: size.height / 2))), "the page is the page's")
        session.teardown()
    }

    /// A drag taken in the real panel reaches the session, which is how the new size gets to the settings.
    @Test func resizingTheRealPanelTellsTheSession() throws {
        let rig = Rig()
        rig.store.settings.menuBar.homeAddress = "about:blank"
        let session = MenuBarSession(store: rig.store)
        session.prepare()
        var reported: [CGSize] = []
        session.onResized = { reported.append($0) }
        let host = NSHostingView(rootView: MenuBarBrowserView(store: rig.store, session: session))
        let size = CGSize(width: 400, height: 500)
        let window = NSWindow(contentRect: NSRect(x: 300, y: 200, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        let handle = try #require(host.hitTest(NSPoint(x: size.width - 3, y: size.height / 2)))
        handle.mouseDown(with: mouse(.leftMouseDown, size.width - 3, size.height / 2, in: window))
        handle.mouseDragged(with: mouse(.leftMouseDragged, size.width + 17, size.height / 2, in: window))
        handle.mouseUp(with: mouse(.leftMouseUp, size.width + 17, size.height / 2, in: window))
        #expect(reported == [CGSize(width: 420, height: 500)])
        session.teardown()
    }

    private func pageHost(in view: NSView) -> NSView? {
        if view is RuntimeWebHost.RuntimeHostView { return view }
        for sub in view.subviews { if let found = pageHost(in: sub) { return found } }
        return nil
    }

    /// The controls are one slim row along the bottom, so the page sits above a bar's height of room and has only the
    /// strip of sky above it. (Move the bar to the top and the page ends up at the bottom.)
    @Test func theControlsAreOneCompactRowAlongTheBottom() throws {
        let rig = Rig()
        rig.store.settings.menuBar.homeAddress = "about:blank"
        let session = MenuBarSession(store: rig.store)
        session.prepare()
        let host = NSHostingView(rootView: MenuBarBrowserView(store: rig.store, session: session))
        let size = rig.store.settings.menuBar.size
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        let page = try #require(pageHost(in: host))
        let rect = host.convert(page.bounds, from: page)
        let fromTop = host.isFlipped ? rect.minY : size.height - rect.maxY
        let fromBottom = host.isFlipped ? size.height - rect.maxY : rect.minY
        #expect(fromTop > 0 && fromTop <= Metrics.Space.m, "only a strip of sky above the page: \(fromTop)")
        #expect(abs(fromBottom - Metrics.Height.compactBar) < 1, "the page ends where the bar begins: \(fromBottom)")
        #expect(Metrics.Height.compactBar < Metrics.Height.bar && Metrics.Height.compactButton < Metrics.Height.button)
        session.teardown()
    }
}
