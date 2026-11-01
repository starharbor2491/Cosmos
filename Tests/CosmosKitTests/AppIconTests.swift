import AppKit
import Testing
@testable import CosmosKit

@MainActor @Suite struct AppIconTests {
    private func bitmap(_ style: Settings.AppIconStyle) -> NSBitmapImageRep? {
        AppIcon.image(style).representations.compactMap { $0 as? NSBitmapImageRep }.first
    }

    @Test(arguments: Settings.AppIconStyle.allCases) func eachIconShipsInsideTheApp(_ style: Settings.AppIconStyle) throws {
        let rep = try #require(bitmap(style), "AppIcon-\(style.rawValue).png is missing from the resources")
        #expect(rep.pixelsWide == 512 && rep.pixelsHigh == 512)
    }

    @Test(arguments: Settings.AppIconStyle.allCases) func theTileFillsTheCentreAndTheMarginIsClear(_ style: Settings.AppIconStyle) throws {
        let rep = try #require(bitmap(style))
        func alpha(_ x: Double, _ y: Double) -> Double { rep.colorAt(x: Int(x * Double(rep.pixelsWide)), y: Int(y * Double(rep.pixelsHigh))).map { Double($0.alphaComponent) } ?? -1 }
        #expect(alpha(0.5, 0.5) > 0.99, "the artwork is opaque in the middle")
        #expect(alpha(0.01, 0.01) == 0 && alpha(0.99, 0.99) == 0, "the corners of the canvas are transparent")
        // The tile is `AppIcon.tile` of `AppIcon.canvas` wide: its edge is opaque just inside, clear just outside.
        let margin = (AppIcon.canvas - AppIcon.tile) / 2 / AppIcon.canvas
        #expect(alpha(margin + 0.02, 0.5) > 0.99)
        #expect(alpha(margin - 0.04, 0.5) < 0.2)
    }

    /// The icons differ, so picking one changes something.
    @Test func theFourIconsAreFourPictures() throws {
        let middles = try Settings.AppIconStyle.allCases.map { style in
            let rep = try #require(bitmap(style))
            let c = try #require(rep.colorAt(x: rep.pixelsWide / 2 + 60, y: rep.pixelsHigh / 2 + 60))
            return [c.redComponent, c.greenComponent, c.blueComponent].map { Int($0 * 20) }
        }
        #expect(Set(middles).count == 4)
    }

    /// The pick is saved, and a file from before the choice existed (or naming an icon this build does not have) gets
    /// Nebula, the icon the app is built with.
    @Test func thePickIsSavedAndAnUnknownOneFallsBackToNebula() throws {
        var s = Settings()
        s.appIcon = .deepField
        #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)).appIcon == .deepField)
        #expect(try JSONDecoder().decode(Settings.self, from: Data(#"{"appIcon": "quasar"}"#.utf8)).appIcon == .nebula)
        #expect(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).appIcon == .nebula)
    }

    @Test func pickingAnIconPutsItInTheDock() throws {
        _ = NSApplication.shared
        let rig = Rig()
        // The Dock keeps its own (colour-matched) copy of the picture, so it is told apart by which of the four it looks
        // most like.
        func look(_ image: NSImage) -> [Double] {
            let rep = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
            let c = rep.colorAt(x: rep.pixelsWide / 2 + rep.pixelsWide / 8, y: rep.pixelsHigh / 2 + rep.pixelsHigh / 8)!
            return [c.redComponent, c.greenComponent, c.blueComponent]
        }
        func inTheDock() -> Settings.AppIconStyle? {
            let dock = look(NSApp.applicationIconImage)
            var best: (style: Settings.AppIconStyle, distance: Double)?
            for style in Settings.AppIconStyle.allCases {
                let own = look(AppIcon.image(style))
                var distance = 0.0
                for i in 0..<3 { distance += (own[i] - dock[i]) * (own[i] - dock[i]) }
                if distance < best?.distance ?? .infinity { best = (style, distance) }
            }
            return best?.style
        }
        rig.store.settings.appIcon = .supernova
        #expect(inTheDock() == .supernova)
        rig.store.settings.appIcon = .aurora
        #expect(inTheDock() == .aurora)
    }

    /// The menu bar shows the one-colour mark as a template, so the system draws it in the menu bar's own ink in light
    /// and dark, with a sharp copy for each screen scale.
    @Test func theMenuBarMarkIsAnOneColourTemplateWithACopyForEachScale() {
        let mark = AppIcon.menuBarImage()
        let widths = mark.representations.compactMap { $0 as? NSBitmapImageRep }.map(\.pixelsWide).sorted()
        #expect(mark.isTemplate)
        #expect(mark.size == NSSize(width: 18, height: 18))
        #expect(widths == [18, 36, 54])
        #expect(mark.representations.allSatisfy { $0.size == NSSize(width: 18, height: 18) })
    }

    @Test func theMenuBarMarkIsDrawnOnClearGround() throws {
        let rep = try #require(AppIcon.menuBarImage().representations.compactMap { $0 as? NSBitmapImageRep }.first { $0.pixelsWide == 54 })
        let corner = rep.colorAt(x: 0, y: 0).map { Double($0.alphaComponent) }
        let ink = (0..<rep.pixelsWide).contains { x in (0..<rep.pixelsHigh).contains { y in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.9 } }
        #expect(corner == 0, "the mark has no tile behind it")
        #expect(ink, "the mark has solid ink")
    }
}
