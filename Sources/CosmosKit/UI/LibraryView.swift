import SwiftUI
import CosmosCore

/// The Library's main area, beside its rail in the sidebar: the section chosen there (Downloads, History, Archive or
/// System Resources), each with a search field and its controls along the top.
struct LibraryView: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WebContentHostView.corner, style: .continuous)
        ZStack {
            shape.fill(palette.isDark ? Color.black.opacity(0.22) : Color.white.opacity(0.35))
                .overlay(shape.strokeBorder(palette.stroke, lineWidth: 0.5))
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
            .frame(maxWidth: 820)
        }
        .clipShape(shape)
        .animation(Motion.quick, value: window.librarySection)
    }
}

/// The row along the top of a section: a search field (or the section's name when there is nothing to search) and the
/// section's controls at the right.
struct LibraryHeader<Controls: View>: View {
    let title: String
    var query: Binding<String>?
    var prompt = ""
    @ViewBuilder var controls: () -> Controls
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Metrics.Space.s) {
            if let query {
                PanelSearchField(text: query, prompt: prompt)
            } else {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.text)
                Spacer(minLength: 0)
            }
            controls()
        }
        .padding(Metrics.Space.l)
    }
}

/// What a section's control looks like: a glyph and a word on a soft rounded fill, like the search field beside it.
struct LibraryControlLabel: View {
    let symbol: String
    let title: String
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var enabled
    @Local private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            if !title.isEmpty { Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1) }
        }
        .foregroundStyle(palette.secondary)
        .opacity(enabled ? 1 : 0.5)
        .padding(.horizontal, Metrics.Space.m).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).fill(hover && enabled ? palette.hoverStrong : palette.hover))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(Motion.quick, value: hover)
    }
}

// MARK: - Filters

/// The Filter menu beside a section's search field. The first choice lets everything through and shows as plain "Filter".
struct LibraryFilterMenu<Option: Hashable & CaseIterable>: View where Option.AllCases: RandomAccessCollection {
    let title: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        let first = Option.allCases.first
        Menu {
            ForEach(Array(Option.allCases), id: \.self) { option in
                Button { selection = option } label: {
                    if option == selection { Label(title(option), systemImage: "checkmark") } else { Text(title(option)) }
                }
            }
        } label: {
            LibraryControlLabel(symbol: "line.3.horizontal.decrease", title: selection == first ? "Filter" : title(selection))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Filter")
        .accessibilityValue(title(selection))
    }
}

/// The History section's Filter: which kind of entry to show and from when. Plain "Filter" while both are at their widest.
struct TimelineFilterMenu: View {
    @Binding var kind: TimelineKind
    @Binding var period: HistoryWindow

    private var summary: String {
        let parts = [kind == .everything ? nil : kind.title, period == .allTime ? nil : period.title].compactMap { $0 }
        return parts.isEmpty ? "Filter" : parts.joined(separator: " · ")
    }

    var body: some View {
        Menu {
            Section("Show") {
                ForEach(TimelineKind.allCases) { option in
                    Button { kind = option } label: {
                        if option == kind { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                    }
                }
            }
            Section("When") {
                ForEach(HistoryWindow.allCases, id: \.self) { option in
                    Button { period = option } label: {
                        if option == period { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                    }
                }
            }
        } label: {
            LibraryControlLabel(symbol: "line.3.horizontal.decrease", title: summary)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Filter")
        .accessibilityValue(summary)
    }
}

/// When a visit was, for the History section's Filter.
enum HistoryWindow: CaseIterable, Hashable {
    case allTime, today, yesterday, lastWeek

    var title: String {
        switch self {
        case .allTime: "All time"
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .lastWeek: "Last 7 days"
        }
    }

    /// How many entries to ask the history for: the usual amount, and more when a time range will throw some away.
    func loadLimit(searching: Bool) -> Int {
        let usual = searching ? 200 : 400
        return self == .allTime ? usual : usual * 10
    }

    func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let midnight = calendar.startOfDay(for: now)
        switch self {
        case .allTime: return true
        case .today: return date >= midnight
        case .yesterday:
            let start = calendar.date(byAdding: .day, value: -1, to: midnight) ?? midnight.addingTimeInterval(-86_400)
            return date >= start && date < midnight
        case .lastWeek: return date >= now.addingTimeInterval(-7 * 86_400)
        }
    }
}

/// What became of a download, for the Downloads section's Filter.
enum DownloadFilter: CaseIterable, Hashable {
    case all, inProgress, finished, stopped

    var title: String {
        switch self {
        case .all: "All"
        case .inProgress: "In progress"
        case .finished: "Finished"
        case .stopped: "Stopped"
        }
    }

    /// Whether finished downloads are among what the list shows (so "Clear", which removes them, takes nothing unseen).
    var showsFinished: Bool { self != .inProgress }

    func matches(_ state: DownloadItem.State) -> Bool {
        switch (self, state) {
        case (.all, _), (.inProgress, .running), (.finished, .finished), (.stopped, .failed), (.stopped, .cancelled): return true
        default: return false
        }
    }
}
