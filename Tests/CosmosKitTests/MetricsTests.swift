import CoreGraphics
import Testing
@testable import CosmosKit

@Suite struct MetricsTests {
    @Test func aPanelKeepsItsSizeWhenTheWindowIsLargeEnough() {
        #expect(Metrics.panelSize(560, within: 1200) == 560)
        #expect(Metrics.panelSize(840, within: 840 + 2 * Metrics.Space.l) == 840)
    }

    @Test func aPanelShrinksToLeaveAMarginInASmallWindow() {
        // The smallest window is 760 x 480: Boosts (840 x 600) and the theme editor (640 tall) have to give way.
        #expect(Metrics.panelSize(840, within: 760) == 760 - 2 * Metrics.Space.l)
        #expect(Metrics.panelSize(600, within: 480) == 480 - 2 * Metrics.Space.l)
    }

    @Test func aWindowThatHasNotBeenMeasuredDoesNotShrinkAnything() {
        #expect(Metrics.panelSize(560, within: 0) == 560)
    }

    @Test func aFavoritesTileIsAThirdOfTheRowsWidthLessTwoGaps() {
        // 260 pt sidebar: 8 pt gutters leave 244, two 8 pt gaps leave 228 for three tiles.
        #expect(Metrics.Sidebar.tileWidth(sidebarWidth: 260) == 76)
        #expect(Metrics.Sidebar.tileWidth(sidebarWidth: 320) == 96)
    }

    @Test func aWindowSmallerThanItsMarginsLeavesNothingNegative() {
        #expect(Metrics.panelSize(300, within: 20) == 0)
    }
}
