import SwiftUI

/// Dev-only. While an automation run is recording, views tagged `.spatial(name)` report their frames in the
/// sidebar's coordinate space, and the `spatial` step checks the things that should line up do. Tagging costs nothing
/// in normal use.
@MainActor
enum SpatialProbe {
    static var isRecording = false
    static var frames: [String: [CGRect]] = [:]
    static let space = "cosmos-sidebar"
}

struct SpatialKey: PreferenceKey {
    static var defaultValue: [String: [CGRect]] { [:] }
    static func reduce(value: inout [String: [CGRect]], nextValue: () -> [String: [CGRect]]) {
        value.merge(nextValue()) { $0 + $1 }
    }
}

private struct SpatialTag: ViewModifier {
    let name: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if SpatialProbe.isRecording {
            content.background(GeometryReader { g in
                Color.clear.preference(key: SpatialKey.self, value: [name: [g.frame(in: .named(SpatialProbe.space))]])
            })
        } else {
            content
        }
    }
}

extension View {
    func spatial(_ name: String) -> some View { modifier(SpatialTag(name: name)) }

    /// Collects the frames reported by `.spatial` tags below this view.
    func recordsSpatialFrames() -> some View {
        coordinateSpace(name: SpatialProbe.space)
            .onPreferenceChange(SpatialKey.self) { frames in
                MainActor.assumeIsolated { if SpatialProbe.isRecording { SpatialProbe.frames = frames } }
            }
    }
}

struct SpatialCheck: Equatable {
    let name: String
    let passed: Bool
    let detail: String
}

extension SpatialProbe {
    /// The alignment rules of the sidebar, expressed on measured frames. Each rule is one line a designer would say
    /// aloud ("all icons start at the same x"), so a failure names what to fix.
    nonisolated static func check(_ frames: [String: [CGRect]], tolerance: CGFloat = 0.5) -> [SpatialCheck] {
        var out: [SpatialCheck] = []
        func record(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String) {
            out.append(SpatialCheck(name: name, passed: ok, detail: ok ? "" : detail()))
        }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= tolerance }
        func all(_ key: String) -> [CGRect] { frames[key] ?? [] }
        func same(_ values: [CGFloat]) -> Bool { values.allSatisfy { near($0, values[0]) } }
        func list(_ values: [CGFloat]) -> String { Set(values.map { ($0 * 10).rounded() / 10 }).sorted().map { "\($0)" }.joined(separator: ", ") }

        let required = ["pill", "tile", "header.icon", "header.title", "row", "row.icon.d0", "row.title.d0", "divider.title", "divider.rule"]
        let missing = required.filter { all($0).isEmpty }
        record("every probe reported", missing.isEmpty, "nothing reported for \(missing.joined(separator: ", "))")
        guard missing.isEmpty else { return out }

        let iconX = all("row.icon.d0").map(\.minX)
        record("icons share a column", same(iconX), "icon x values: \(list(iconX))")
        let column = iconX[0]

        var depth = 1
        var childrenOK = true, childDetail = ""
        while !all("row.icon.d\(depth)").isEmpty {
            let xs = all("row.icon.d\(depth)").map(\.minX)
            let expected = column + CGFloat(depth) * Metrics.Sidebar.indent
            if !same(xs) || !near(xs[0], expected) { childrenOK = false; childDetail += "depth \(depth): x \(list(xs)), expected \(expected). " }
            depth += 1
        }
        record("children sit under their folder's icon", childrenOK, childDetail)

        let gapOffset = Metrics.Icon.row + Metrics.Sidebar.gap
        var titlesOK = true, titleDetail = "", followOK = true, followDetail = ""
        for d in 0..<depth {
            let titles = all("row.title.d\(d)").map(\.minX)
            let icons = all("row.icon.d\(d)").map(\.minX)
            if !titles.isEmpty, !same(titles) { titlesOK = false; titleDetail += "depth \(d): title x \(list(titles)). " }
            if let t = titles.first, let i = icons.first, !near(t - i, gapOffset) { followOK = false; followDetail += "depth \(d): title is \(t - i) pt after its icon, expected \(gapOffset). " }
        }
        record("titles share a column", titlesOK, titleDetail)
        record("title follows its icon by one gap", followOK, followDetail)

        let titleColumn = all("row.title.d0")[0].minX
        let header = all("header.icon")[0].minX, headerTitle = all("header.title")[0].minX
        record("space header lines up with rows", near(header, column) && near(headerTitle, titleColumn),
               "header icon x \(header) (rows \(column)), name x \(headerTitle) (rows \(titleColumn))")
        let label = all("divider.title").map(\.minX)
        record("section labels start at the icon column", label.allSatisfy { near($0, column) }, "label x \(list(label)), icons \(column)")

        let rows = all("row")
        record("rows share their edges", same(rows.map(\.minX)) && same(rows.map(\.maxX)), "row left \(list(rows.map(\.minX))), right \(list(rows.map(\.maxX)))")
        record("rows are one height", rows.allSatisfy { near($0.height, Metrics.Height.row) }, "row heights \(list(rows.map(\.height))), expected \(Metrics.Height.row)")

        let left = rows[0].minX, right = rows[0].maxX
        let rules = all("divider.rule").map(\.maxX)
        record("section rules reach the row edge", rules.allSatisfy { near($0, right - Metrics.Sidebar.inset) }, "rule ends at \(list(rules)), row content edge \(right - Metrics.Sidebar.inset)")
        let pill = all("pill")[0]
        record("pill spans the rows' width", near(pill.minX, left) && near(pill.maxX, right), "pill \(pill.minX)…\(pill.maxX), rows \(left)…\(right)")

        let tiles = all("tile").sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        record("favorites span the rows' width", near(tiles.map(\.minX).min()!, left) && near(tiles.map(\.maxX).max()!, right),
               "tiles \(tiles.map(\.minX).min()!)…\(tiles.map(\.maxX).max()!), rows \(left)…\(right)")
        record("favorites are one size", tiles.allSatisfy { near($0.width, tiles[0].width) && near($0.height, Metrics.Height.tile) },
               "tile sizes \(list(tiles.map(\.width))) × \(list(tiles.map(\.height))), expected height \(Metrics.Height.tile)")
        var gaps: [CGFloat] = []
        for (a, b) in zip(tiles, tiles.dropFirst()) {
            if near(a.minY, b.minY) { gaps.append(b.minX - a.maxX) } else { gaps.append(b.minY - a.maxY) }
        }
        record("favorites have even gaps", gaps.allSatisfy { near($0, Metrics.Space.s) }, "gaps \(list(gaps)), expected \(Metrics.Space.s)")
        return out
    }
}
