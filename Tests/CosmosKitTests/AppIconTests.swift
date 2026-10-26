import AppKit
import Testing
@testable import CosmosKit

@Suite struct AppIconTests {
    private var bitmap: NSBitmapImageRep? { AppIcon.image.representations.compactMap { $0 as? NSBitmapImageRep }.first }

    @Test func theIconShipsInsideTheApp() throws {
        let rep = try #require(bitmap, "AppIcon.png is missing from the resources")
        #expect(rep.pixelsWide == 512 && rep.pixelsHigh == 512)
    }

    @Test func theTileFillsTheCentreAndTheMarginIsClear() throws {
        let rep = try #require(bitmap)
        func alpha(_ x: Double, _ y: Double) -> Double { rep.colorAt(x: Int(x * Double(rep.pixelsWide)), y: Int(y * Double(rep.pixelsHigh))).map { Double($0.alphaComponent) } ?? -1 }
        #expect(alpha(0.5, 0.5) > 0.99, "the artwork is opaque in the middle")
        #expect(alpha(0.01, 0.01) == 0 && alpha(0.99, 0.99) == 0, "the corners of the canvas are transparent")
        // The tile is `AppIcon.tile` of `AppIcon.canvas` wide: its edge is opaque just inside, clear just outside.
        let margin = (AppIcon.canvas - AppIcon.tile) / 2 / AppIcon.canvas
        #expect(alpha(margin + 0.02, 0.5) > 0.99)
        #expect(alpha(margin - 0.04, 0.5) < 0.2)
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
