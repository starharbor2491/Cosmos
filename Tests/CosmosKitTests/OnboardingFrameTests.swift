import AppKit
import SwiftUI
import Testing
import CosmosCore
@testable import CosmosKit

/// Frames of the welcome, drawn at chosen moments in the test process in a window off every screen, for a person (or a
/// reviewer) to look at. The browsers it offers to bring along are made up, so no picture shows what is on this Mac.
/// Runs only with COSMOS_UI_SNAPSHOTS set to the folder the PNGs go to.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["COSMOS_UI_SNAPSHOTS"] != nil))
struct OnboardingFrameTests {
    private let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["COSMOS_UI_SNAPSHOTS"] ?? NSTemporaryDirectory(), isDirectory: true)
    private var size = CGSize(width: 1280, height: 800)

    init() { _ = NSApplication.shared }

    /// The galaxy is drawn first on its own (a picture of a window leaves out what the GPU draws) and passed in, then the
    /// whole welcome is pictured from a window.
    private func write(_ model: OnboardingModel, _ name: String, over backdrop: NSImage? = nil, size: CGSize? = nil) async throws {
        let size = size ?? self.size
        let t = model.frozen ?? 0
        if model.sprites == nil { model.prepareNow() }
        let sprites = try #require(model.sprites)
        let sky = ImageRenderer(content: GalaxyView(galaxy: OnboardingView.galaxy, sprites: sprites, time: t, frame: { model.frame(at: $0, in: size) })
            .frame(width: size.width, height: size.height))
        sky.scale = 2
        let background = try #require(sky.nsImage)

        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: ZStack {
            if let backdrop { Image(nsImage: backdrop).resizable() }
            OnboardingView(model: model).environment(\.onboardingSkyPicture, background)
        })
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderBack(nil)
        // Long enough for SwiftUI's own animations (a panel springing open) to settle.
        try? await Task.sleep(for: .milliseconds(700))
        hosting.layoutSubtreeIfNeeded()
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
    }

    private func model(_ rig: Rig, at t: Double) -> OnboardingModel {
        rig.store.settings.useNewInstallDefaults()
        rig.window.overlay = .welcome
        let model = OnboardingModel(store: rig.store, window: rig.window)
        model.frozen = t
        model.sourcesLoaded = true
        model.sources = [
            ImportSource(id: "arc", name: "Arc", symbol: "arrow.down.doc", icon: nil, detail: "Spaces, Favorites, pinned tabs, folders, split views and the archive.",
                         isAvailable: true, bringsSpaces: true) { store, window, _ in
                Self.inventSpaces(in: store, window: window)
                return ImportOutcome(summary: "Brought 3 spaces, 9 tabs and 120 archived tabs.", offersSignIns: true, extensions: 3)
            },
            ImportSource(id: "safari", name: "Safari", symbol: "safari", icon: nil, detail: "History (1,204) and bookmarks (86).", isAvailable: true) { _, _, _ in ImportOutcome(summary: "") },
            ImportSource(id: "chrome", name: "Google Chrome", symbol: "globe", icon: nil, detail: "History (3,410) and bookmarks (212).", isAvailable: true) { _, _, _ in ImportOutcome(summary: "") },
        ]
        return model
    }

    /// What a made-up import brings: three spaces with a few tabs (invented, nothing of anyone's).
    private static func inventSpaces(in store: BrowserStore, window: WindowState) {
        let home = window.focusedSpaceID
        store.updateSpace(home) { $0.title = "Personal"; $0.theme = .aurora }
        _ = store.addSpace(title: "Work", icon: .symbol("briefcase.fill"), theme: .deepField, profileID: nil, in: nil)
        _ = store.addSpace(title: "Studio", icon: .symbol("paintpalette.fill"), theme: .supernova, profileID: nil, in: nil)
        store.edit { w in
            guard let space = w.space(home) else { return }
            for (title, host) in [("Reading list", "reading.example"), ("Weekly menu", "kitchen.example")] {
                w.addTab(url: URL(string: "https://\(host)/"), title: title, under: space.pinnedRootID)
            }
            for (title, host) in [("Trail maps", "trails.example"), ("Piano practice", "music.example"), ("Garden planner", "garden.example"),
                                  ("Film night", "films.example")] {
                w.addTab(url: URL(string: "https://\(host)/"), title: title, under: space.unpinnedRootID)
            }
        }
    }

    /// The browser window behind the welcome, as it is when the welcome clears.
    private func browserPicture(_ rig: Rig, size: CGSize? = nil) async throws -> NSImage {
        let size = size ?? self.size
        let overlay = rig.window.overlay
        rig.window.overlay = nil
        defer { rig.window.overlay = overlay }
        let controller = BrowserWindowController(store: rig.store, state: rig.window)
        let window = try #require(controller.window)
        window.setFrame(NSRect(x: -4000, y: -4000, width: size.width, height: size.height), display: false)
        window.orderBack(nil)
        try? await Task.sleep(for: .milliseconds(400))
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        window.orderOut(nil)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// What a galaxy frame costs the main thread: the painter's work for one frame (working out where every star is and
    /// recording the drawing, which the GPU then draws), at moments of the opening, at rest, and in the way in's light.
    /// Also the whole frame made into a picture by SwiftUI's renderer. Written to frame-times.txt beside the pictures; a
    /// frame at 120 Hz has 8.3 ms in all.
    @Test func whatAFrameCosts() async throws {
        let rig = Rig()
        let m = model(rig, at: 0)
        m.prepareNow()
        let sprites = try #require(m.sprites)
        var report = "Galaxy at 1280×800 on a Retina (2×) display, median / worst of 40 frames each (after 5 to warm up): painter on the main thread; whole frame made into a picture (ImageRenderer)\n"
        var medians: [Double] = []
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        for (name, t, entered) in [("forming", 1.3, nil), ("opening", 3.0, nil), ("at rest", 14.0, nil), ("way in", 15.0, 14.2 as Double?)] {
            m.frozen = t
            m.enteredAt = entered
            let frame = m.frame(at: t)
            var times: [Double] = [], whole: [Double] = []
            for i in 0..<45 {
                let clock = ContinuousClock()
                let renderer = ImageRenderer(content: Canvas { ctx, size in
                    let began = clock.now
                    GalaxyPainter.paint(&ctx, size: size, galaxy: OnboardingView.galaxy, sprites: sprites, time: t + Double(i) / 60, frame: frame, pointer: .zero)
                    let spent = clock.now - began
                    if i >= 5 { times.append(ms(spent)) }
                }.frame(width: size.width, height: size.height))
                renderer.scale = 2
                let began = clock.now
                _ = renderer.cgImage
                if i >= 5 { whole.append(ms(clock.now - began)) }
            }
            times.sort()
            whole.sort()
            let median = times[times.count / 2]
            medians.append(median)
            report += String(format: "  %@: painter %.2f / %.2f ms; whole frame %.2f / %.2f ms\n", name, median, times.last ?? 0,
                             whole[whole.count / 2], whole.last ?? 0)
        }
        // Everything over the galaxy on the Sky step (the glass cards, the tiles, the live preview of the window), drawn
        // whole into a picture by AppKit on the CPU: more work than the screen does, which only redraws what changed.
        m.enteredAt = nil
        m.frozen = 30
        for _ in 0..<2 { m.primary() }
        try #require(m.step == .sky)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: OnboardingView(model: m).environment(\.onboardingSkyPicture, NSImage(size: size)))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderBack(nil)
        try? await Task.sleep(for: .milliseconds(350))
        var scene: [Double] = [], update: [Double] = []
        let clock = ContinuousClock()
        for i in 0..<25 {
            let began = clock.now
            m.choose(SpaceTheme.presets[i % SpaceTheme.presets.count])
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let laidOut = clock.now
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            if i >= 5 { update.append(ms(laidOut - began)); scene.append(ms(clock.now - laidOut)) }
        }
        window.orderOut(nil)
        scene.sort()
        update.sort()
        report += String(format: "  Sky step, a sky picked: SwiftUI's update and layout %.2f / %.2f ms; everything then redrawn whole on the CPU %.2f / %.2f ms\n",
                         update[update.count / 2], update.last ?? 0, scene[scene.count / 2], scene.last ?? 0)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try report.write(to: folder.appendingPathComponent("frame-times.txt"), atomically: true, encoding: .utf8)
        #expect(medians.allSatisfy { $0 < 8.3 }, "\(report)")
    }

    @Test func theOpening() async throws {
        for t in [0.5, 1.3, 1.9, 2.3, 2.7, 3.2, 3.6, 4.3] {
            let rig = Rig()
            try await write(model(rig, at: t), "opening-\(t)")
        }
    }

    @Test func theSteps() async throws {
        let rig = Rig()
        let m = model(rig, at: 12)
        for step in OnboardingStep.allCases where step != .welcome {
            while m.step != step { m.primary() }
            // Drawn once the camera has arrived.
            m.frozen = (m.frozen ?? 0) + 3
            switch step {
            case .bring:
                try await write(m, "step-bring")
                try await write(m, "narrow-bring", size: CGSize(width: 1000, height: 700))
                m.run(m.sources[0])
                let deadline = Date.now.addingTimeInterval(60)
                while m.results.isEmpty, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
                let landed = try #require(m.landedAt)
                for dt in [0.3, 0.6] {
                    m.frozen = landed + dt
                    try await write(m, "bring-landing-\(dt)")
                }
                m.frozen = landed + 3
                try await write(m, "step-bring-imported")
            case .sky:
                // Every sky, the pale and grey ones too, then Aurora for the steps after.
                for theme in SpaceTheme.presets.reversed() + [.aurora] {
                    m.choose(theme)
                    m.frozen = (m.frozen ?? 0) + 2
                    try await write(m, "sky-\(theme.name)")
                }
                try await write(m, "step-sky")
                try await write(m, "short-sky", size: CGSize(width: 1300, height: 560))
                try await write(m, "narrow-sky", size: CGSize(width: 1000, height: 700))
            case .moves:
                m.perform(.commandBar)
                try await write(m, "step-moves")
                try await write(m, "small-moves", size: CGSize(width: 760, height: 480))
            case .features:
                try await write(m, "step-features")
                // A pale sky and a grey one, where the words sit beside the galaxy.
                for theme in [SpaceTheme.moondust, .eclipse] {
                    m.choose(theme)
                    m.frozen = (m.frozen ?? 0) + 2
                    try await write(m, "features-\(theme.name)")
                }
                m.choose(.aurora)
                m.frozen = (m.frozen ?? 0) + 2
            default:
                try await write(m, "step-\(step.rawValue)")
            }
            m.frozen = (m.frozen ?? 0) + 8
        }
        // The way in, over the browser it clears to: the window beside the words grows into it.
        rig.store.settings.hasCompletedOnboarding = true
        let settled = try await browserPicture(rig)
        let entered = m.frozen ?? 0
        m.enteredAt = entered
        m.grows = true
        for dt in [0.2, 0.4, 0.6, 0.8, 1.0, 1.2, 1.4] {
            m.frozen = entered + dt
            try await write(m, "entry-\(dt)", over: settled)
        }
        // A window too narrow for it: the browser waits under the light (large and soft), then settles.
        m.grows = false
        let small = CGSize(width: 1000, height: 700)
        rig.window.arriving = true
        let waiting = try await browserPicture(rig, size: small)
        rig.window.arriving = false
        let settledSmall = try await browserPicture(rig, size: small)
        for dt in [0.5, 1.0, 1.4] {
            m.frozen = entered + dt
            try await write(m, "narrow-entry-\(dt)", over: dt < OnboardingFlow.arrivalStarts + 0.2 ? waiting : settledSmall, size: small)
        }
    }
}
