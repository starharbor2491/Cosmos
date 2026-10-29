import SwiftUI
import CosmosCore

/// The sidebar page left of the first space: the Library, in the sidebar itself, which widens for it (as Arc's does)
/// while the page stays beside it. Its sections are tabs along the top; the one showing fills the rest.
struct LibraryPage: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette

    /// How wide the sidebar is while the Library is in it (never narrower than the user's own width).
    static let width: Double = 480

    var body: some View {
        VStack(spacing: Metrics.Space.s) {
            HStack(spacing: Metrics.Space.xs) {
                ForEach(LibrarySection.allCases) { section in
                    LibraryTab(section: section, selected: window.librarySection == section, progress: progress(for: section)) {
                        window.librarySection = section
                        store.haptics.alignment()
                    }
                }
            }
            .padding(.horizontal, Metrics.Sidebar.gutter)
            let shape = RoundedRectangle(cornerRadius: Metrics.Radius.tile, style: .continuous)
            // One section at a time; each starts fresh, so a search typed in one does not follow you to the next.
            Group {
                switch window.librarySection {
                case .downloads: DownloadsSection(store: store, window: window)
                case .history: HistorySection(store: store, window: window)
                case .resources: ResourcesSection(store: store, window: window)
                }
            }
            .id(window.librarySection)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(palette.isDark ? Color.black.opacity(0.22) : Color.white.opacity(0.35)))
            .overlay(shape.strokeBorder(palette.stroke, lineWidth: 0.5))
            .clipShape(shape)
            .padding(.horizontal, Metrics.Sidebar.gutter)
        }
        .padding(.bottom, Metrics.Space.s)
        .animation(Motion.quick, value: window.librarySection)
    }

    /// A running download shows on its tab: a ring around the glyph.
    private func progress(for section: LibrarySection) -> Double? {
        section == .downloads && store.downloads.hasActive ? store.downloads.overallFraction : nil
    }
}

private struct LibraryTab: View {
    let section: LibrarySection
    let selected: Bool
    var progress: Double?
    let action: () -> Void
    @Environment(\.palette) private var palette
    @Local private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
        Button(action: action) {
            HStack(spacing: 6) {
                ZStack {
                    Image(systemName: section.symbol).font(.system(size: 13, weight: .medium)).symbolSwap()
                        .foregroundStyle(selected ? palette.accentGlyph : palette.secondary)
                    if let progress {
                        Circle().trim(from: 0, to: max(0.05, progress)).stroke(palette.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .rotationEffect(.degrees(-90)).frame(width: 20, height: 20)
                    }
                }
                .frame(width: 20, height: 20)
                Text(section.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(selected ? palette.text : palette.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity).frame(height: Metrics.Height.button + 6)
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
