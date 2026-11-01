import AppKit
import CryptoKit
import SwiftUI
import Testing
import CosmosCore
@testable import CosmosKit

/// Pictures of the browser window and Settings for a person (or a reviewer) to look at, drawn in the test process in
/// windows off every screen, so nothing comes to the front. Pages are the fake engine's, so they are blank; the sidebar,
/// toolbars and panels are as drawn. Runs only with COSMOS_UI_SNAPSHOTS set to the folder the PNGs go to.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["COSMOS_UI_SNAPSHOTS"] != nil))
struct UISnapshotTests {
    private let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["COSMOS_UI_SNAPSHOTS"] ?? NSTemporaryDirectory(), isDirectory: true)

    init() { _ = NSApplication.shared }

    private func write(_ view: NSView, _ name: String) throws {
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
    }

    private func settle(_ ms: Int = 400) async { try? await Task.sleep(for: .milliseconds(ms)) }

    /// A store in a folder of its own with three spaces (one light) and a few tabs, and a window on it off screen.
    private func rig() -> (BrowserStore, WindowState, BrowserWindowController, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-snapshots-\(UUID().uuidString)", isDirectory: true)
        let store = BrowserStore(directory: dir, engine: FakeEngine(), passwordKey: { SymmetricKey(size: .bits256) })
        let state = WindowState(focusedSpaceID: store.workspace.spaces[0].id, sidebarWidth: store.settings.sidebarWidth)
        let controller = BrowserWindowController(store: store, state: state)
        let window = controller.window!
        window.setFrame(NSRect(x: -4000, y: -4000, width: 1280, height: 820), display: false)
        window.orderBack(nil)
        for (title, address) in [("Project plan", "https://example.com/plan"), ("Design notes", "https://example.org/notes"),
                                 ("Weather", "https://example.net/weather"), ("Recipes", "https://example.com/recipes")] {
            if let id = store.newTab(url: URL(string: address), in: state) { store.rename(id, to: title) }
        }
        _ = store.addSpace(title: "Work", icon: .symbol("briefcase.fill"), theme: .aurora, profileID: nil, in: state)
        _ = store.addSpace(title: "Reading", icon: .symbol("book.fill"), theme: .moondust, profileID: nil, in: state)
        store.switchSpace(to: store.workspace.spaces[0].id, in: state)
        return (store, state, controller, dir)
    }

    @Test func theWindowInItsStates() async throws {
        let (store, state, controller, dir) = rig()
        defer { controller.window?.orderOut(nil); try? FileManager.default.removeItem(at: dir) }
        let view = try #require(controller.window?.contentView)
        await settle()
        try write(view, "01-space-dark")
        store.switchSpace(to: store.workspace.spaces[2].id, in: state)
        await settle(900)
        try write(view, "02-space-light")
        store.switchSpace(to: store.workspace.spaces[0].id, in: state)
        await settle(900)
        store.openLibrary(.history, in: state)
        await settle(900)
        try write(view, "03-library-history")
        store.openLibrary(.downloads, in: state)
        await settle(500)
        try write(view, "04-library-downloads")
        store.show(.space(state.focusedSpaceID), in: state)
        await settle(900)
        // Fingers held halfway to the next space and halfway to the Library.
        try await halfSwipe(view, -(state.sidebarWidth / 2) / SwipeTracker.damping, "08-half-swipe-to-next-space")
        try await halfSwipe(view, (state.sidebarWidth / 2) / SwipeTracker.damping, "09-half-swipe-to-library")
        state.overlay = .commandBar(.newTab)
        await settle()
        try write(view, "05-command-bar")
        state.overlay = nil
        state.utilitiesVisible = true
        await settle()
        try write(view, "06-utilities-rail")
        state.utilitiesVisible = false
        state.sidebarVisible = false
        await settle(700)
        try write(view, "07-sidebar-hidden")
        state.sidebarVisible = true
        await settle(700)
        // More spaces than the bar has room for at full width: six, then nine.
        for (count, name) in [(6, "10-six-spaces"), (9, "11-nine-spaces")] {
            while store.workspace.spaces.count < count {
                _ = store.addSpace(title: "Space \(store.workspace.spaces.count + 1)", icon: .symbol("star.fill"), theme: .pulsar, profileID: nil, in: state)
            }
            await settle(900)
            try write(view, name)
        }
    }

    /// Two fingers put down and moved `dx`, a picture taken while they are still down, then lifted short of a page change.
    private func halfSwipe(_ view: NSView, _ dx: CGFloat, _ name: String) async throws {
        var catchers: [SwipeCatcher.SwipeView] = []
        func collect(_ v: NSView) { if let c = v as? SwipeCatcher.SwipeView { catchers.append(c) }; v.subviews.forEach(collect) }
        collect(view)
        catchers.forEach { $0.handle(.init(phase: .began)) }
        for _ in 0..<8 {
            catchers.forEach { $0.handle(.init(phase: .changed, deltaX: dx / 8)) }
            await settle(16)
        }
        await settle(250)
        try write(view, name)
        // Back to where it started before lifting, so nothing changes page.
        catchers.forEach { $0.handle(.init(phase: .changed, deltaX: -dx)) }
        catchers.forEach { $0.handle(.init(phase: .ended)) }
        await settle(700)
    }

    @Test func settings() async throws {
        let (store, _, controller, dir) = rig()
        defer { controller.window?.orderOut(nil); try? FileManager.default.removeItem(at: dir) }
        for tab in SettingsTab.allCases {
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -2000), size: SettingsView.size), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            let hosting = NSHostingView(rootView: SettingsView(store: store, tab: tab, dropdowns: DropdownHost()))
            hosting.sizingOptions = []
            window.contentView = hosting
            window.setFrame(NSRect(origin: NSPoint(x: -4000, y: -2000), size: SettingsView.size), display: false)
            window.orderBack(nil)
            await settle()
            try write(hosting, "settings-\(tab.rawValue)")
            window.orderOut(nil)
        }
    }
}
