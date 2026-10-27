import SwiftUI
import CosmosCore

/// The sidebar page left of the first space: a rail of the Library's sections, each a large glyph over its name. Picking
/// one shows it in the main area; the one showing is highlighted.
struct LibraryPage: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: Metrics.Space.s) {
            Spacer(minLength: 0)
            ForEach(LibrarySection.allCases) { section in
                LibraryRailItem(section: section, selected: window.librarySection == section, progress: progress(for: section)) {
                    window.librarySection = section
                    store.haptics.alignment()
                }
            }
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.Sidebar.gutter)
        .padding(.bottom, Metrics.Space.m)
    }

    /// A running download shows on its tile: a ring around the glyph.
    private func progress(for section: LibrarySection) -> Double? {
        section == .downloads && store.downloads.hasActive ? store.downloads.overallFraction : nil
    }
}

private struct LibraryRailItem: View {
    let section: LibrarySection
    let selected: Bool
    var progress: Double?
    let action: () -> Void
    @Environment(\.palette) private var palette
    @Local private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous)
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Image(systemName: section.symbol).font(.system(size: 22, weight: .regular)).symbolSwap()
                        .foregroundStyle(selected ? palette.accentGlyph : palette.secondary)
                    if let progress {
                        Circle().trim(from: 0, to: max(0.05, progress)).stroke(palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90)).frame(width: 34, height: 34)
                    }
                }
                .frame(width: 36, height: 36)
                Text(section.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(selected ? palette.text : palette.secondary)
            }
            .frame(maxWidth: .infinity).frame(height: 78)
            .background(shape.fill(selected ? palette.selected : (hover ? palette.hover : .clear)))
            .overlay(shape.strokeBorder(selected ? palette.stroke : .clear, lineWidth: 0.8))
            .contentShape(Rectangle())
            .animation(Motion.quick, value: selected)
            .animation(Motion.quick, value: hover)
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .onHover { hover = $0 }
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
