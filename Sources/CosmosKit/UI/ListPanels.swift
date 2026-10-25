import SwiftUI
import AppKit
import CosmosCore

// MARK: - Archive

/// Everything that left the sidebar: auto-archived tabs, closed tabs and cleared ones. Searchable and restorable.
struct ArchivePanel: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette
    @Local private var query = ""

    var body: some View {
        let entries = store.archive.search(query)
        PanelFrame(title: "Archive", symbol: "archivebox.fill", close: { window.overlay = nil }, accessory: {
            Menu {
                ForEach(ArchiveInterval.allCases, id: \.self) { i in
                    Button { store.archive.interval = i } label: {
                        if store.archive.interval == i { Label(i.label, systemImage: "checkmark") } else { Text(i.label) }
                    }
                }
            } label: {
                Label("Archive tabs: \(store.archive.interval.label.lowercased())", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .menuStyle(.borderlessButton).fixedSize()
            Button("Clear All") { store.clearArchive() }
                .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(palette.secondary)
                .disabled(store.archive.entries.isEmpty)
        }) {
            VStack(spacing: 0) {
                PanelSearchField(text: $query, prompt: "Search archived tabs").padding(12)
                if entries.isEmpty {
                    EmptyPanelMessage(symbol: "archivebox", title: query.isEmpty ? "Nothing archived yet" : "No matches",
                                      detail: query.isEmpty ? "Tabs you leave untouched for \(store.archive.interval.label.lowercased().replacingOccurrences(of: "after ", with: "")) land here, so your sidebar stays tidy." : nil)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(entries.prefix(300)) { entry in
                                ArchiveRow(store: store, window: window, entry: entry)
                            }
                        }
                        .padding(.horizontal, 8).padding(.bottom, 10)
                    }
                }
            }
        }
    }
}

private struct ArchiveRow: View {
    let store: BrowserStore
    let window: WindowState
    let entry: ArchivedItem
    @Environment(\.palette) private var palette
    @Local private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            FaviconView(store: store, url: entry.url, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.text).lineLimit(1)
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(palette.secondary).lineLimit(1)
            }
            Spacer()
            if hover {
                Button("Restore") { store.restore(entry, in: window); window.overlay = nil }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.accent)
                Button { store.deleteArchived(entry.id) } label: { Image(systemName: "trash").font(.system(size: 11.5)) }
                    .buttonStyle(.plain).foregroundStyle(palette.secondary)
            } else {
                Text(entry.archivedAt, format: .relative(presentation: .named)).font(.system(size: 11.5)).foregroundStyle(palette.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { store.restore(entry, in: window); window.overlay = nil }
    }

    private var subtitle: String {
        if entry.tabCount > 1 { return "\(entry.tabCount) tabs" }
        return entry.url.map { URLInput.display($0) } ?? ""
    }
}

struct EmptyPanelMessage: View {
    let symbol: String
    let title: String
    var detail: String?
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(palette.tertiary)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.secondary)
            if let detail {
                Text(detail).font(.system(size: 12.5)).foregroundStyle(palette.tertiary)
                    .multilineTextAlignment(.center).frame(maxWidth: 320)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - History

struct HistoryPanel: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette
    @Local private var query = ""
    @Local private var entries: [HistoryEntry] = []
    @Local private var revision = 0

    var body: some View {
        PanelFrame(title: "History", symbol: "clock.fill", width: 700, height: 560, close: { window.overlay = nil }, accessory: {
            Menu("Clear…") {
                Button("Last Hour") { store.history.clear(since: Date().addingTimeInterval(-3600)); revision += 1 }
                Button("Today") { store.history.clear(since: Calendar.current.startOfDay(for: Date())); revision += 1 }
                Button("Last 7 Days") { store.history.clear(since: Date().addingTimeInterval(-7 * 86400)); revision += 1 }
                Divider()
                Button("All History") { store.history.clear(since: nil); revision += 1 }
            }
            .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11.5, weight: .medium))
        }) {
            VStack(spacing: 0) {
                PanelSearchField(text: $query, prompt: "Search history").padding(12)
                if entries.isEmpty {
                    EmptyPanelMessage(symbol: "clock", title: query.isEmpty ? "No history yet" : "No matches")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(grouped, id: \.0) { day, items in
                                Text(day).font(.system(size: 11, weight: .bold)).foregroundStyle(palette.tertiary)
                                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
                                ForEach(items) { e in HistoryRow(store: store, window: window, entry: e) { revision += 1 } }
                            }
                        }
                        .padding(.horizontal, 8).padding(.bottom, 10)
                    }
                }
            }
        }
        .task(id: "\(query)|\(revision)") {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(120)) }
            entries = query.isEmpty ? store.history.recent(limit: 400) : store.history.search(query, limit: 200)
        }
    }

    private var grouped: [(String, [HistoryEntry])] {
        guard query.isEmpty else { return [("Results", entries)] }
        let cal = Calendar.current
        var out: [(String, [HistoryEntry])] = []
        let fmt = DateFormatter(); fmt.dateStyle = .full; fmt.timeStyle = .none
        for e in entries {
            let label: String
            if cal.isDateInToday(e.lastVisit) { label = "Today" }
            else if cal.isDateInYesterday(e.lastVisit) { label = "Yesterday" }
            else { label = fmt.string(from: e.lastVisit) }
            if let last = out.indices.last, out[last].0 == label { out[last].1.append(e) } else { out.append((label, [e])) }
        }
        return out
    }
}

private struct HistoryRow: View {
    let store: BrowserStore
    let window: WindowState
    let entry: HistoryEntry
    let onDelete: () -> Void
    @Environment(\.palette) private var palette
    @Local private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            FaviconView(store: store, url: entry.url, size: 17)
            Text(entry.title.isEmpty ? URLInput.display(entry.url) : entry.title)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(palette.text).lineLimit(1)
            Text(URLInput.hostForDisplay(entry.url)).font(.system(size: 12)).foregroundStyle(palette.tertiary).lineLimit(1)
            Spacer()
            if hover {
                Button { store.history.delete(url: entry.url); onDelete() } label: { Image(systemName: "xmark").font(.system(size: 10.5, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(palette.secondary)
            } else {
                Text(entry.lastVisit, style: .time).font(.system(size: 11.5)).foregroundStyle(palette.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            window.overlay = nil
            store.openFromCommandBar(entry.url, mode: .newTab, typed: false, in: window)
        }
    }
}

// MARK: - Downloads

struct DownloadsPanel: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette

    var body: some View {
        let items = store.downloads.items
        PanelFrame(title: "Downloads", symbol: "arrow.down.circle.fill", width: 380, height: min(420, 110 + CGFloat(max(1, items.count)) * 58),
                   close: { window.overlay = nil }, accessory: {
            Button("Clear") { store.downloads.clearFinished() }
                .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(palette.secondary)
                .disabled(items.allSatisfy(\.isRunning))
        }) {
            if items.isEmpty {
                EmptyPanelMessage(symbol: "arrow.down.circle", title: "No downloads", detail: "Files you download are saved to your Downloads folder.")
            } else {
                ScrollView {
                    VStack(spacing: 2) { ForEach(items) { DownloadRow(item: $0) } }.padding(8)
                }
            }
        }
        // Rises from the sidebar footer, where the Downloads button lives.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 12).padding(.bottom, 52)
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    @Environment(\.palette) private var palette
    @Local private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename).font(.system(size: 12.5, weight: .medium)).foregroundStyle(palette.text).lineLimit(1).truncationMode(.middle)
                switch item.state {
                case .running:
                    ProgressView(value: item.fraction).progressViewStyle(.linear).tint(palette.accent)
                    Text("\(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))  ·  \(Int(item.fraction * 100))%")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                case .finished:
                    Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).font(.system(size: 11)).foregroundStyle(palette.secondary)
                case .failed(let message):
                    Text(message).font(.system(size: 11)).foregroundStyle(.red.opacity(0.9)).lineLimit(1)
                case .cancelled:
                    Text("Cancelled").font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
            }
            Spacer(minLength: 4)
            if item.isRunning {
                Button { item.cancel() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(palette.secondary)
            } else if case .finished = item.state {
                Button { item.reveal() } label: { Image(systemName: "magnifyingglass.circle.fill") }.buttonStyle(.plain).foregroundStyle(palette.secondary).help("Show in Finder")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { if case .finished = item.state { item.open() } }
    }

    private var icon: NSImage {
        if let d = item.destination, FileManager.default.fileExists(atPath: d.path) { return NSWorkspace.shared.icon(forFile: d.path) }
        return NSWorkspace.shared.icon(for: .data)
    }
}
