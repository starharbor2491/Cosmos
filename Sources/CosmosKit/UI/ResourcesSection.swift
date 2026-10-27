import SwiftUI
import AppKit
import CosmosCore

/// What the browser costs the Mac: memory in use, what Cosmos holds, and each awake tab's share, with a way to put the
/// ones nobody is looking at to sleep. The figures refresh every couple of seconds while the section is open.
struct ResourcesSection: View {
    let store: BrowserStore
    let window: WindowState
    @Environment(\.palette) private var palette

    var body: some View {
        let snap = store.resources.snapshot
        let sleepable = snap.tabs.contains { !$0.inUse }
        VStack(spacing: 0) {
            LibraryHeader(title: "System Resources") {
                Button {
                    let count = store.sleepBackgroundTabs()
                    store.resources.refresh(from: store, force: true)
                    window.showToast(count == 0 ? "No background tabs to sleep" : "Put \(count) tab\(count == 1 ? "" : "s") to sleep", symbol: "moon.zzz.fill")
                } label: { LibraryControlLabel(symbol: "moon.zzz", title: "Sleep Background Tabs") }
                    .buttonStyle(.plain).disabled(!sleepable)
            }
            HStack(spacing: Metrics.Space.s) {
                let total = snap.system?.total ?? 0
                StatTile(title: "Memory in use", value: snap.system.map { ResourceText.bytes($0.used) } ?? "—",
                         detail: total == 0 ? nil : "of \(ResourceText.bytes(total))", fraction: snap.system?.fractionUsed)
                StatTile(title: "Cosmos memory", value: ResourceText.bytes(snap.cosmosFootprint), detail: "\(snap.tabs.count) awake",
                         fraction: total == 0 ? nil : Double(snap.cosmosFootprint) / Double(total))
                StatTile(title: "Cosmos processor", value: snap.cosmosCPU.map(ResourceText.percent) ?? "—", detail: nil,
                         fraction: snap.cosmosCPU.map { min(1, $0 / (100 * Double(ProcessInfo.processInfo.activeProcessorCount))) })
            }
            .padding(.horizontal, Metrics.Space.l).padding(.bottom, Metrics.Space.m)
            Rectangle().fill(palette.stroke).frame(height: 0.5)
            ScrollView {
                LazyVStack(spacing: 2) {
                    UsageHeader()
                    UsageRow(title: "Cosmos", detail: "The browser itself: windows, sidebar, downloads",
                             memory: snap.app?.footprint, cpu: snap.appCPU) { EmptyView() }
                    ForEach(snap.tabs) { tab in
                        UsageRow(favicon: (store, tab.url), title: tab.title, detail: tab.url.map { URLInput.hostForDisplay($0) } ?? "",
                                 memory: tab.footprint, cpu: tab.cpu) {
                            if tab.inUse {
                                Text("In use").font(.system(size: 11.5)).foregroundStyle(palette.tertiary)
                            } else {
                                Button("Sleep") {
                                    store.discardRuntime(forItem: tab.id)
                                    store.resources.refresh(from: store, force: true)
                                }
                                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.accentText)
                                .accessibilityLabel("Put \(tab.title) to sleep")
                            }
                        }
                    }
                    if snap.asleepTabs > 0 {
                        Text("\(snap.asleepTabs) more tab\(snap.asleepTabs == 1 ? " is" : "s are") asleep and use no memory.")
                            .font(.system(size: 11.5)).foregroundStyle(palette.tertiary).padding(.top, Metrics.Space.m)
                    }
                }
                .padding(.horizontal, Metrics.Space.s).padding(.vertical, Metrics.Space.s)
            }
        }
        .task {
            // The first reading has nothing to compare with, so the second comes quickly and shows the processor use.
            store.resources.refresh(from: store)
            try? await Task.sleep(for: .milliseconds(1100))
            while !Task.isCancelled {
                store.resources.refresh(from: store)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    var detail: String?
    var fraction: Double?
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(palette.text)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(palette.tertiary) }
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            UsageBar(fraction: fraction)
        }
        .padding(Metrics.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).fill(palette.hover))
        .accessibilityElement(children: .combine)
    }
}

/// A thin bar that fills to `fraction`, quietly when there is nothing to fill it.
struct UsageBar: View {
    let fraction: Double?
    var height: CGFloat = 4
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { g in
            Capsule().fill(palette.faint.opacity(0.5))
                .overlay(alignment: .leading) {
                    Capsule().fill(palette.accent).frame(width: g.size.width * max(0, min(1, fraction ?? 0)))
                        .animation(Motion.standard, value: fraction)
                }
                .clipShape(Capsule())
        }
        .frame(height: height)
    }
}

/// The names of the columns the rows below line up in.
private struct UsageHeader: View {
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Text("Memory").frame(width: UsageColumns.memory, alignment: .trailing)
            Text("Processor").frame(width: UsageColumns.cpu, alignment: .trailing)
            Spacer().frame(width: UsageColumns.action)
        }
        .font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.tertiary)
        .padding(.horizontal, 10).padding(.bottom, 2)
        .accessibilityHidden(true)
    }
}

private enum UsageColumns {
    static let memory: CGFloat = 70
    static let cpu: CGFloat = 60
    static let action: CGFloat = 52
}

private struct UsageRow<Trailing: View>: View {
    var favicon: (BrowserStore, URL?)?
    let title: String
    let detail: String
    let memory: UInt64?
    let cpu: Double?
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.palette) private var palette
    @Local private var hover = false

    init(title: String, detail: String, memory: UInt64?, cpu: Double?, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title; self.detail = detail; self.memory = memory; self.cpu = cpu; self.trailing = trailing
    }

    init(favicon: (BrowserStore, URL?), title: String, detail: String, memory: UInt64?, cpu: Double?, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.favicon = favicon; self.title = title; self.detail = detail; self.memory = memory; self.cpu = cpu; self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            if let favicon {
                FaviconView(store: favicon.0, url: favicon.1, size: 18)
            } else {
                CosmosLogo(size: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.text).lineLimit(1)
                if !detail.isEmpty { Text(detail).font(.system(size: 11.5)).foregroundStyle(palette.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            Text(memory.map(ResourceText.bytes) ?? "—").frame(width: UsageColumns.memory, alignment: .trailing)
            Text(cpu.map(ResourceText.percent) ?? "—").frame(width: UsageColumns.cpu, alignment: .trailing)
            trailing().frame(width: UsageColumns.action, alignment: .trailing)
        }
        .font(.system(size: 12.5, weight: .medium)).monospacedDigit()
        .foregroundStyle(palette.text)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).fill(hover ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}
