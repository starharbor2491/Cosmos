import Foundation
import CoreGraphics
import Testing
@testable import CosmosKit

/// Settings' dropdown list is drawn by the window, above every pane, so where it goes and what the keys do while it is
/// open are plain logic.
@MainActor
@Suite struct DropdownTests {
    private let bounds = CGRect(x: 0, y: 0, width: 840, height: 648)
    private let size = CGSize(width: 232, height: 120)

    // MARK: Placement

    @Test func listOpensUnderTheFieldWithItsRightEdge() {
        let anchor = CGRect(x: 560, y: 100, width: 232, height: 32)
        let origin = DropdownPlacement.origin(anchor: anchor, size: size, bounds: bounds)
        #expect(origin.x == anchor.maxX - size.width)
        #expect(origin.y == anchor.maxY + Metrics.Space.xs)
    }

    @Test func listFlipsAboveWhenThereIsNoRoomBelow() {
        let anchor = CGRect(x: 560, y: 560, width: 232, height: 32)
        let origin = DropdownPlacement.origin(anchor: anchor, size: size, bounds: bounds)
        #expect(origin.y + size.height == anchor.minY - Metrics.Space.xs)
    }

    @Test func listStaysInsideTheWindowWhenNeitherSideHasRoom() {
        let tall = CGSize(width: 232, height: 600)
        let origin = DropdownPlacement.origin(anchor: CGRect(x: 560, y: 300, width: 232, height: 32), size: tall, bounds: bounds)
        #expect(origin.y >= bounds.minY + Metrics.Space.m)
        #expect(origin.y + tall.height <= bounds.maxY - Metrics.Space.m)
    }

    @Test func listIsKeptInsideTheWindowSideways() {
        let origin = DropdownPlacement.origin(anchor: CGRect(x: 20, y: 100, width: 100, height: 32), size: size, bounds: bounds)
        #expect(origin.x >= bounds.minX + Metrics.Space.m)
    }

    @Test func listHeightCoversItsRowsAndPadding() {
        #expect(DropdownPlacement.height(rows: 1) == Metrics.Height.button + 2 * Metrics.Space.xs)
        #expect(DropdownPlacement.height(rows: 3) == 3 * Metrics.Height.button + 2 * DropdownPlacement.rowGap + 2 * Metrics.Space.xs)
        #expect(DropdownPlacement.height(rows: 0) == 2 * Metrics.Space.xs)
    }

    // MARK: Host

    private func present(_ host: DropdownHost, rows: Int = 4, selected: Int? = 1, chosen: Chosen) -> UUID {
        let id = UUID()
        host.present(.init(id: id, labels: (0..<rows).map { "Row \($0)" }, selected: selected, width: 232, choose: { chosen.index = $0 }))
        return id
    }

    final class Chosen { var index: Int? }

    @Test func openingHighlightsTheCurrentChoice() {
        let host = DropdownHost()
        let chosen = Chosen()
        let id = present(host, selected: 2, chosen: chosen)
        #expect(host.isOpen(id))
        #expect(host.highlight == 2)
    }

    @Test func openingAnotherListClosesTheFirst() {
        let host = DropdownHost()
        let chosen = Chosen()
        let first = present(host, chosen: chosen)
        let second = present(host, chosen: chosen)
        #expect(!host.isOpen(first))
        #expect(host.isOpen(second))
    }

    @Test func arrowKeysStayWithinTheList() {
        let host = DropdownHost()
        let chosen = Chosen()
        _ = present(host, rows: 3, selected: 1, chosen: chosen)
        #expect(host.handle(.down))
        #expect(host.highlight == 2)
        #expect(host.handle(.down))
        #expect(host.highlight == 2)
        #expect(host.handle(.up) && host.handle(.up) && host.handle(.up))
        #expect(host.highlight == 0)
    }

    @Test func returnPicksTheHighlightedRowAndCloses() {
        let host = DropdownHost()
        let chosen = Chosen()
        let id = present(host, selected: 0, chosen: chosen)
        _ = host.handle(.down)
        #expect(host.handle(.commit))
        #expect(chosen.index == 1)
        #expect(!host.isOpen(id))
    }

    @Test func escapeClosesWithoutPicking() {
        let host = DropdownHost()
        let chosen = Chosen()
        let id = present(host, chosen: chosen)
        #expect(host.handle(.escape))
        #expect(!host.isOpen(id))
        #expect(chosen.index == nil)
    }

    @Test func tabClosesTheListButStillMovesFocus() {
        let host = DropdownHost()
        let chosen = Chosen()
        let id = present(host, chosen: chosen)
        #expect(!host.handle(.leave))
        #expect(!host.isOpen(id))
    }

    @Test func keysAreLeftAloneWhenNothingIsOpen() {
        let host = DropdownHost()
        #expect(!host.handle(.down))
        #expect(!host.handle(.commit))
    }

    @Test func aFieldThatLeavesTheWindowTakesItsListWithIt() {
        let host = DropdownHost()
        let chosen = Chosen()
        let id = present(host, chosen: chosen)
        host.close(ifOpen: UUID())
        #expect(host.isOpen(id))
        host.close(ifOpen: id)
        #expect(!host.isOpen(id))
    }

    @Test func registeredFieldsCanBeOpenedInOrderOfPosition() {
        let host = DropdownHost()
        let a = UUID(), b = UUID()
        var opened: [UUID] = []
        host.register(a) { opened.append(a) }
        host.register(b) { opened.append(b) }
        host.setFrames([a: CGRect(x: 0, y: 300, width: 10, height: 10), b: CGRect(x: 0, y: 100, width: 10, height: 10)])
        host.openRegistered(at: 0)
        host.openRegistered(at: 1)
        host.openRegistered(at: 5)
        #expect(opened == [b, a])
    }
}
