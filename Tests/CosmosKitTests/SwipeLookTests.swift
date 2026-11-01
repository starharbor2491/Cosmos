import AppKit
import CryptoKit
import Testing
import CosmosCore
@testable import CosmosKit

/// While two fingers pull the sidebar toward another page, the window changes with them: the sky and colours mix toward
/// the other space's, and the sidebar widens toward the Library's width, as far as the strip has got, not after the
/// fingers lift. Drawn in a window off every screen and read back from its pixels.
@MainActor
@Suite(.serialized) struct SwipeLookTests {
    init() { _ = NSApplication.shared }

    private struct Rig {
        let store: BrowserStore
        let state: WindowState
        let controller: BrowserWindowController
        let dir: URL
        var view: NSView { controller.window!.contentView! }

        func close() { controller.window?.orderOut(nil); try? FileManager.default.removeItem(at: dir) }

        private var catchers: [SwipeCatcher.SwipeView] {
            var found: [SwipeCatcher.SwipeView] = []
            func collect(_ view: NSView) { if let v = view as? SwipeCatcher.SwipeView { found.append(v) }; view.subviews.forEach(collect) }
            collect(view)
            return found
        }

        /// Two fingers put down and moved `dx` points in all (negative is left, toward the next page), and kept down.
        func swipe(_ dx: CGFloat, steps: Int = 8) async {
            let catchers = catchers
            for c in catchers { c.handle(.init(phase: .began)) }
            for _ in 0..<steps {
                for c in catchers { c.handle(.init(phase: .changed, deltaX: dx / CGFloat(steps))) }
                try? await Task.sleep(for: .milliseconds(16))
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        /// The fingers lift, and the strip is given time to settle.
        func lift() async {
            for c in catchers { c.handle(.init(phase: .ended)) }
            try? await Task.sleep(for: .milliseconds(900))
        }

        func picture() -> NSBitmapImageRep {
            view.layoutSubtreeIfNeeded()
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }
    }

    /// A window with a dark space (Nebula) first and a light one (Moondust) second, the first showing.
    private func rig() async -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-swipe-look-\(UUID().uuidString)", isDirectory: true)
        let store = BrowserStore(directory: dir, engine: FakeEngine(), passwordKey: { SymmetricKey(size: .bits256) })
        let state = WindowState(focusedSpaceID: store.workspace.spaces[0].id, sidebarWidth: 248)
        _ = store.newTab(url: URL(string: "https://example.com/"), in: state)
        _ = store.addSpace(title: "Light", icon: .symbol("sun.max.fill"), theme: .moondust, profileID: nil, in: state)
        store.switchSpace(to: store.workspace.spaces[0].id, in: state)
        let controller = BrowserWindowController(store: store, state: state)
        controller.window!.setFrame(NSRect(x: -4000, y: -4000, width: 1200, height: 760), display: false)
        controller.window!.orderBack(nil)
        try? await Task.sleep(for: .milliseconds(900))
        return Rig(store: store, state: state, controller: controller, dir: dir)
    }

    /// The average colour of the sky in a strip along the window's top edge, above the page, right of the sidebar.
    private func sky(_ rep: NSBitmapImageRep, in view: NSView) -> (r: Double, g: Double, b: Double) {
        let scale = Double(rep.pixelsWide) / view.bounds.width
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for x in stride(from: Int(500 * scale), to: Int(1000 * scale), by: 3) {
            for y in [Int(2 * scale), Int(4 * scale)] {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                r += c.redComponent; g += c.greenComponent; b += c.blueComponent; n += 1
            }
        }
        return (r / n, g / n, b / n)
    }

    private func distance(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Double {
        ((a.r - b.r) * (a.r - b.r) + (a.g - b.g) * (a.g - b.g) + (a.b - b.b) * (a.b - b.b)).squareRoot()
    }

    /// Where the page starts, from the left, along a row through the middle of the window: the sidebar's width and its
    /// handle's.
    private func pageEdge(_ rep: NSBitmapImageRep, in view: NSView) -> Double {
        let scale = Double(rep.pixelsWide) / view.bounds.width
        let y = Int(view.bounds.height / 2 * scale)
        for x in Int(150 * scale)..<rep.pixelsWide {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.redComponent > 0.97, c.greenComponent > 0.97, c.blueComponent > 0.97 {
                return Double(x) / scale
            }
        }
        return .nan
    }

    @Test func theSkyMixesTowardTheNextSpaceWhileTheFingersPull() async throws {
        let rig = await rig()
        defer { rig.close() }
        let dark = sky(rig.picture(), in: rig.view)
        // Halfway: the tracker counts 0.8 of the fingers' movement, and a page is the sidebar's width.
        await rig.swipe(-(248 / 2) / SwipeTracker.damping)
        #expect(rig.state.focusedSpaceID == rig.store.workspace.spaces[0].id, "the fingers have not lifted")
        let halfway = sky(rig.picture(), in: rig.view)
        await rig.lift()
        #expect(rig.state.focusedSpaceID == rig.store.workspace.spaces[1].id, "far enough to count")
        let light = sky(rig.picture(), in: rig.view)
        let whole = distance(dark, light)
        #expect(whole > 0.3, "the two skies are far apart: \(dark) \(light)")
        #expect(distance(dark, halfway) > 0.25 * whole, "halfway the sky has moved toward the light one: \(dark) \(halfway) \(light)")
        #expect(distance(halfway, light) > 0.25 * whole, "and is not there yet")
    }

    /// With swiping switched off (Settings ▸ Features), two fingers across the sidebar move nothing.
    @Test func withSwipingSwitchedOffTheFingersMoveNothing() async throws {
        let rig = await rig()
        defer { rig.close() }
        rig.store.settings.set(.spaceSwipe, on: false)
        try? await Task.sleep(for: .milliseconds(200))
        await rig.swipe(-200)
        #expect(rig.state.sidebarLook?.other == nil && rig.state.sidebarLook?.library == 0)
        await rig.lift()
        #expect(rig.state.focusedSpaceID == rig.store.workspace.spaces[0].id)
    }

    @Test func theSidebarWidensTowardTheLibraryWhileTheFingersPull() async throws {
        let rig = await rig()
        defer { rig.close() }
        let space = pageEdge(rig.picture(), in: rig.view)
        await rig.swipe((248 / 2) / SwipeTracker.damping)
        #expect(!rig.state.libraryOpen, "the fingers have not lifted")
        let halfway = pageEdge(rig.picture(), in: rig.view)
        await rig.lift()
        #expect(rig.state.libraryOpen, "far enough to count")
        let library = pageEdge(rig.picture(), in: rig.view)
        #expect(library - space > 100, "the Library is wider: \(space) → \(library)")
        #expect(halfway > space + 0.25 * (library - space) && halfway < library - 0.25 * (library - space),
                "halfway the sidebar is about halfway between: \(space) \(halfway) \(library)")
    }
}

/// The colours over the sky while it changes from one space's to another's.
@Suite struct PaletteMixTests {
    @Test func theEndsAreEachSpacesOwnAndTheMiddleIsBetween() {
        let dark = Palette.Inks(theme: .nebula), light = Palette.Inks(theme: .moondust)
        #expect(dark.mixed(with: light, 0) == dark)
        #expect(dark.mixed(with: light, 1) == light)
        let half = dark.mixed(with: light, 0.5)
        #expect(half.text == dark.text.mixed(with: light.text, 0.5))
        #expect(half.text != dark.text && half.text != light.text)
        #expect(dark.mixed(with: light, 0.49).isDark && !dark.mixed(with: light, 0.51).isDark, "light or dark is the nearer space's")
    }

    /// The palette made from one theme is the one it always was: built from the same numbers.
    @Test func oneThemesPaletteIsItsInks() {
        for theme in SpaceTheme.presets {
            let inks = Palette.Inks(theme: theme), palette = Palette(theme: theme)
            #expect(palette.isDark == theme.prefersLightForeground)
            #expect(palette.accentRaw == inks.accent && inks.accent == theme.accent)
            #expect(inks.text.a == Legibility.primary.alpha && inks.secondary.a == Legibility.secondary.alpha)
        }
    }
}
