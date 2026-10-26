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
}
