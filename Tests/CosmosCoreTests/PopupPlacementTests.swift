import Foundation
import CoreGraphics
import Testing
@testable import CosmosCore

@Suite struct PopupPlacementTests {
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let size = CGSize(width: 360, height: 420)

    @Test func itHangsCentredUnderItsButton() {
        let button = CGRect(x: 600, y: 700, width: 28, height: 28)
        let frame = PopupPlacement.frame(under: button, size: size, visible: visible)
        #expect(frame.midX == button.midX)
        #expect(frame.maxY == button.minY - PopupPlacement.gap)
        #expect(frame.size == size)
    }

    @Test func theEdgesOfTheScreenPushItBackIn() {
        let left = PopupPlacement.frame(under: CGRect(x: 0, y: 700, width: 28, height: 28), size: size, visible: visible)
        #expect(left.minX == visible.minX + PopupPlacement.margin)
        let right = PopupPlacement.frame(under: CGRect(x: 1412, y: 700, width: 28, height: 28), size: size, visible: visible)
        #expect(right.maxX == visible.maxX - PopupPlacement.margin)
    }

    /// A button low on the screen has the popup above it when there is more room there.
    @Test func noRoomBelowPutsItAbove() {
        let button = CGRect(x: 600, y: 200, width: 28, height: 28)
        let frame = PopupPlacement.frame(under: button, size: size, visible: visible)
        #expect(frame.minY == button.maxY + PopupPlacement.gap)
        #expect(frame.size == size)
    }

    /// Little room either way: it is made shorter rather than leaving the screen.
    @Test func aShortScreenShrinksIt() {
        let short = CGRect(x: 0, y: 0, width: 1440, height: 300)
        let frame = PopupPlacement.frame(under: CGRect(x: 600, y: 250, width: 28, height: 28), size: size, visible: short)
        #expect(frame.minY >= short.minY + PopupPlacement.margin)
        #expect(frame.maxY == 250 - PopupPlacement.gap)
        #expect(frame.width == size.width && frame.height < size.height)
    }

    /// With no button (a shortcut opened it), it is in the top-right corner of the page, inside it, even when the page
    /// fills the screen.
    @Test func withNoButtonItIsInThePagesTopRightCorner() {
        let page = CGRect(x: 8, y: 8, width: 1424, height: 859)
        let frame = PopupPlacement.frame(inTopRightOf: page, size: size, visible: visible)
        #expect(frame.size == size)
        #expect(frame.maxX == page.maxX - PopupPlacement.margin)
        #expect(frame.maxY == page.maxY - PopupPlacement.margin)
        let small = CGRect(x: -3000, y: -3000, width: 300, height: 200)
        #expect(PopupPlacement.frame(inTopRightOf: small, size: size, visible: nil).size == CGSize(width: 284, height: 184),
                "no bigger than the page")
    }

    /// A button on no screen (a window off every screen) has the popup under it, as it is.
    @Test func withNoScreenItIsJustUnderTheButton() {
        let button = CGRect(x: -3000, y: -3000, width: 28, height: 28)
        let frame = PopupPlacement.frame(under: button, size: size, visible: nil)
        #expect(frame == CGRect(x: button.midX - 180, y: button.minY - PopupPlacement.gap - 420, width: 360, height: 420))
    }
}
