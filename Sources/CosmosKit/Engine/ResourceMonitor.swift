import AppKit
import WebKit
import CosmosCore

extension WKWebView {
    /// The process that draws this page. WebKit gives no public way to ask for it; the property it has for its own tools
    /// is read when it is there, and a page then simply has no figures of its own.
    var webProcessID: Int32? {
        let key = "_webProcessIdentifier"
        guard responds(to: NSSelectorFromString(key)), let id = (value(forKey: key) as? NSNumber)?.int32Value, id > 0 else { return nil }
        return id
    }
}

/// What the browser is costing the Mac right now: the app, each awake tab's page process, and the machine's memory.
/// Views that show it call `refresh` while they are on screen; nothing samples while none is.
@MainActor
@Observable
final class ResourceMonitor {
    struct TabUsage: Identifiable, Equatable {
        let id: UUID
        var title: String
        var url: URL?
        var pid: Int32?
        var footprint: UInt64?
        var cpu: Double?
        /// It cannot be put to sleep (`BrowserStore.sleepBackgroundTabs` leaves it): on screen, playing sound, loading,
        /// recording, or a site the user asked to keep awake.
        var inUse: Bool
    }

    struct Snapshot: Equatable {
        var app: ProcessUsage?
        var appCPU: Double?
        var tabs: [TabUsage] = []
        var asleepTabs = 0
        var system: SystemMemory?

        /// Everything Cosmos holds: the app and each page process once, however many tabs share it.
        var cosmosFootprint: UInt64 {
            var seen = Set<Int32>()
            var total = app?.footprint ?? 0
            for tab in tabs {
                if let pid = tab.pid, let bytes = tab.footprint, seen.insert(pid).inserted { total += bytes }
            }
            return total
        }

        var cosmosCPU: Double? {
            var total = appCPU
            var seen = Set<Int32>()
            for tab in tabs {
                if let pid = tab.pid, let cpu = tab.cpu, seen.insert(pid).inserted { total = (total ?? 0) + cpu }
            }
            return total
        }
    }

    /// Biggest first; a page with no figures goes last, and equal ones keep a steady order.
    static func ordered(_ tabs: [TabUsage]) -> [TabUsage] {
        tabs.sorted { ($0.footprint ?? 0, $1.id.uuidString) > ($1.footprint ?? 0, $0.id.uuidString) }
    }

    private(set) var snapshot = Snapshot()
    @ObservationIgnored private var meter = CPUMeter()
    @ObservationIgnored private var lastRefresh = Date.distantPast

    /// Reads everything again. Calls closer together than a second apart are ignored: processor use over less than that
    /// is noise, and two views on screen both ask. `force` is for a change the viewer just made (a tab put to sleep).
    func refresh(from store: BrowserStore, now: Date = Date(), force: Bool = false) {
        guard force || now.timeIntervalSince(lastRefresh) >= 1 else { return }
        lastRefresh = now

        var snap = Snapshot()
        var pids: Set<Int32> = [getpid()]
        if let app = ProcessSampler.sample(pid: getpid()) {
            snap.app = app
            snap.appCPU = meter.percent(pid: app.pid, cpuSeconds: app.cpuSeconds, at: now)
        }

        let visible = store.visibleTabIDs
        var seenItems = Set<UUID>()
        for (key, runtime) in store.runtimes where !runtime.isEphemeral && seenItems.insert(key.item).inserted {
            var tab = TabUsage(id: key.item, title: store.title(forItem: key.item, in: nil), url: runtime.url, pid: nil, footprint: nil, cpu: nil,
                               inUse: visible.contains(key.item) || runtime.isAudible || runtime.isLoading || runtime.isCapturing
                                   || BehaviorConfig.shared.keepsAlive(runtime.url))
            if let pid = runtime.webView.webProcessID, let usage = ProcessSampler.sample(pid: pid) {
                pids.insert(pid)
                tab.pid = pid
                tab.footprint = usage.footprint
                tab.cpu = meter.percent(pid: pid, cpuSeconds: usage.cpuSeconds, at: now)
            }
            snap.tabs.append(tab)
        }
        snap.tabs = Self.ordered(snap.tabs)
        snap.asleepTabs = max(0, store.workspace.allTabs().count - snap.tabs.count)
        snap.system = SystemMemory.read()
        meter.keepOnly(pids)
        snapshot = snap
    }
}
