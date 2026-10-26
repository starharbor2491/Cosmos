import CoreGraphics
import Testing
@testable import CosmosKit

@Suite struct SpatialProbeTests {
    /// A sidebar laid out exactly as `Metrics` says: 260 pt wide, an 8 pt gutter, 8 pt inset, 18 pt icons, 8 pt gap.
    private func aligned() -> [String: [CGRect]] {
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
        var f: [String: [CGRect]] = [:]
        f["pill"] = [rect(8, 48, 244, 36)]
        f["tile"] = [rect(8, 100, 76, 48), rect(92, 100, 76, 48), rect(176, 100, 76, 48), rect(8, 156, 76, 48), rect(92, 156, 76, 48)]
        f["header.icon"] = [rect(16, 220, 18, 24)]
        f["header.title"] = [rect(42, 224, 40, 16)]
        // depth 0 rows: a tab and "New Tab"; the folder row sits at depth 0 with its icon in the depth-1 column
        f["row"] = [rect(8, 250, 244, 32), rect(8, 284, 244, 32), rect(8, 318, 244, 32), rect(8, 352, 244, 32)]
        f["row.icon.d0"] = [rect(16, 257, 18, 18), rect(16, 325, 18, 18)]
        f["row.title.d0"] = [rect(42, 259, 80, 16), rect(42, 327, 80, 16)]
        f["folder.chevron.d0"] = [rect(16, 293, 10, 14)]
        f["row.icon.d1"] = [rect(34, 291, 18, 18), rect(34, 359, 18, 18)]
        f["row.title.d1"] = [rect(60, 293, 80, 16), rect(60, 361, 80, 16)]
        f["divider.title"] = [rect(16, 400, 40, 12)]
        f["divider.rule"] = [rect(66, 405, 178, 0.5)]
        return f
    }

    private func failures(_ frames: [String: [CGRect]]) -> [String] {
        SpatialProbe.check(frames).filter { !$0.passed }.map(\.name)
    }

    @Test func aSidebarBuiltFromTheMetricsPassesEveryCheck() {
        #expect(failures(aligned()).isEmpty)
    }

    @Test func oneIconOffTheColumnIsCaught() {
        var f = aligned()
        f["row.icon.d0"]![1].origin.x += 3
        #expect(failures(f).contains("icons share a column"))
    }

    @Test func aChildThatIsNotIndentedUnderItsFolderIsCaught() {
        var f = aligned()
        f["row.icon.d1"] = f["row.icon.d1"]!.map { $0.offsetBy(dx: -6, dy: 0) }
        #expect(failures(f).contains("children sit under their folder's icon"))
    }

    @Test func aTitleThatDriftsFromItsIconIsCaught() {
        var f = aligned()
        f["row.title.d0"]![0].origin.x += 2
        let bad = failures(f)
        #expect(bad.contains("titles share a column") || bad.contains("title follows its icon by one gap"))
    }

    @Test func aRowThatIsTheWrongHeightOrWidthIsCaught() {
        var tall = aligned()
        tall["row"]![2].size.height = 36
        #expect(failures(tall).contains("rows are one height"))
        var narrow = aligned()
        narrow["row"]![1].size.width -= 4
        #expect(failures(narrow).contains("rows share their edges"))
    }

    @Test func sectionLabelsAndTheSpaceHeaderLineUpWithRows() {
        var f = aligned()
        f["divider.title"] = [CGRect(x: 22, y: 400, width: 40, height: 12)]
        #expect(failures(f).contains("section labels start at the icon column"))
        var g = aligned()
        g["header.title"] = [CGRect(x: 40, y: 224, width: 40, height: 16)]
        #expect(failures(g).contains("space header lines up with rows"))
    }

    @Test func thePillAndTheTilesSpanTheSameWidthAsRows() {
        var f = aligned()
        f["pill"] = [CGRect(x: 10, y: 48, width: 240, height: 36)]
        #expect(failures(f).contains("pill spans the rows' width"))
        var g = aligned()
        g["tile"]![2].origin.x += 4
        let bad = failures(g)
        #expect(bad.contains("favorites span the rows' width") || bad.contains("favorites have even gaps"))
    }

    @Test func tilesAreOneSizeWithEvenGaps() {
        var f = aligned()
        f["tile"]![4].size.height = 44
        #expect(failures(f).contains("favorites are one size"))
    }

    @Test func aSectionRuleThatStopsShortOfTheRowEdgeIsCaught() {
        var f = aligned()
        f["divider.rule"] = [CGRect(x: 66, y: 405, width: 120, height: 0.5)]
        #expect(failures(f).contains("section rules reach the row edge"))
    }

    @Test func missingTagsAreReportedNotSilentlyPassed() {
        #expect(failures([:]).contains("every probe reported"))
    }
}
