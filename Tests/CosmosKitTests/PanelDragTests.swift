import AppKit
import SwiftUI
import Testing
@testable import CosmosKit
@testable import CosmosCore

/// The menu-bar panel moves when it is taken by its edge: the strips of sky around the page and the gaps in the toolbar. The
/// page and the controls keep their own clicks.
@MainActor
@Suite struct PanelDragTests {
    private func rig() -> (NSWindow, PanelDragArea.PanelDragView) {
        let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        let view = PanelDragArea.PanelDragView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView = view
        return (window, view)
    }

    private func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func draggingMovesThePanelByHowFarThePointerWent() {
        let (window, view) = rig()
        view.mouseDown(with: mouse(.leftMouseDown, 10, 190, in: window))
        view.mouseDragged(with: mouse(.leftMouseDragged, 40, 170, in: window))
        #expect(window.frame.origin == NSPoint(x: 330, y: 280))
        // The panel followed, so the pointer is at the same place in it; the next movement is from there.
        view.mouseDragged(with: mouse(.leftMouseDragged, 40, 170, in: window))
        #expect(window.frame.origin == NSPoint(x: 360, y: 260))
    }

    @Test func aDragThatDidNotStartOnTheEdgeDoesNothing() {
        let (window, view) = rig()
        view.mouseDragged(with: mouse(.leftMouseDragged, 90, 90, in: window))
        #expect(window.frame.origin == NSPoint(x: 300, y: 300))
    }

    @Test func aReleasedPointerLeavesThePanelAlone() {
        let (window, view) = rig()
        view.mouseDown(with: mouse(.leftMouseDown, 10, 190, in: window))
        view.mouseUp(with: mouse(.leftMouseUp, 10, 190, in: window))
        view.mouseDragged(with: mouse(.leftMouseDragged, 90, 90, in: window))
        #expect(window.frame.origin == NSPoint(x: 300, y: 300))
    }

    @Test func thePanelCannotBeDraggedOffTheScreenForGood() throws {
        let (window, view) = rig()
        let screens = NSScreen.screens.map(\.visibleFrame)
        let all = try #require(screens.dropFirst().reduce(screens.first) { $0?.union($1) })
        view.mouseDown(with: mouse(.leftMouseDown, 10, 190, in: window))
        view.mouseDragged(with: mouse(.leftMouseDragged, 100_000, 190, in: window))
        #expect(window.frame.minX <= all.maxX - MenuBarPlacement.grip, "some of it is left to take hold of")
        view.mouseDragged(with: mouse(.leftMouseDragged, 10, 100_000, in: window))
        #expect(window.frame.maxY <= all.maxY, "not up under the menu bar")
    }

    /// What is under the pointer in the real panel: the strip along the top edge moves it; the page does not.
    @Test func theEdgesOfThePanelAreItsHandleAndThePageIsNot() throws {
        let rig = Rig()
        rig.store.settings.menuBar.homeAddress = "about:blank"
        let session = MenuBarSession(store: rig.store)
        session.prepare()
        let host = NSHostingView(rootView: MenuBarBrowserView(store: rig.store, session: session))
        let size = rig.store.settings.menuBar.layout.size
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        func isHandle(_ view: NSView?) -> Bool { view is PanelDragArea.PanelDragView }
        // Window coordinates run up from the bottom.
        #expect(isHandle(host.hitTest(NSPoint(x: size.width / 2, y: size.height - 3))), "the strip along the top")
        #expect(isHandle(host.hitTest(NSPoint(x: 3, y: size.height / 2))), "the strip down the left")
        #expect(isHandle(host.hitTest(NSPoint(x: size.width - 3, y: size.height / 2))), "the strip down the right")
        #expect(!isHandle(host.hitTest(NSPoint(x: size.width / 2, y: size.height / 2))), "the page is the page's")
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
        let size = rig.store.settings.menuBar.layout.size
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
