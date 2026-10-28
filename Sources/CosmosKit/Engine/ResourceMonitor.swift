import AppKit
import CosmosCore
import CosmosEngine

/// What the browser is costing the Mac right now: the app, the engine's processes, each awake tab's share of them, and
/// the machine's memory. Views that show it call `refresh` while they are on screen; nothing samples while none is.
@MainActor
@Observable
final class ResourceMonitor {
    struct TabUsage: Identifiable, Equatable {
        let id: UUID
        var title: String
        var url: URL?
        /// The page's own JavaScript memory (the engine shares its processes between pages, so a page has no process of
        /// its own to measure).
        var footprint: UInt64?
        /// Processor time the page's main thread used, in percent of one processor.
        var cpu: Double?
        /// It cannot be put to sleep (`BrowserStore.sleepBackgroundTabs` leaves it): on screen, playing sound, loading,
        /// recording, or a site the user asked to keep awake.
        var inUse: Bool
    }

    struct Snapshot: Equatable {
        var app: ProcessUsage?
        var appCPU: Double?
        /// The engine's processes, each once.
        var engine: [ProcessUsage] = []
        var engineCPU: Double?
        var tabs: [TabUsage] = []
        var asleepTabs = 0
        var system: SystemMemory?

        /// Everything Cosmos holds: the app and every engine process. A tab's figure is a share of those, so it is not
        /// added again.
        var cosmosFootprint: UInt64 {
            var seen = Set<Int32>()
            var total = app?.footprint ?? 0
            for p in engine where seen.insert(p.pid).inserted { total += p.footprint }
            return total
        }

        var cosmosCPU: Double? {
            guard appCPU != nil || engineCPU != nil else { return nil }
            return (appCPU ?? 0) + (engineCPU ?? 0)
        }
    }

    /// Biggest first; a page with no figures goes last, and equal ones keep a steady order.
    static func ordered(_ tabs: [TabUsage]) -> [TabUsage] {
        tabs.sorted { ($0.footprint ?? 0, $1.id.uuidString) > ($1.footprint ?? 0, $0.id.uuidString) }
    }

    private(set) var snapshot = Snapshot()
    @ObservationIgnored private var meter = CPUMeter()
    @ObservationIgnored private var pageMeter: [UUID: (seconds: Double, at: Date)] = [:]
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var sampling: Task<Void, Never>?

    /// Reads everything again. Calls closer together than a second apart are ignored: processor use over less than that
    /// is noise, and two views on screen both ask. `force` is for a change the viewer just made (a tab put to sleep). The
    /// app and the tabs show at once; the engine's figures follow when it has answered.
    func refresh(from store: BrowserStore, now: Date = Date(), force: Bool = false) {
        guard force || now.timeIntervalSince(lastRefresh) >= 1 else { return }
        lastRefresh = now

        var snap = Snapshot()
        if let app = ProcessSampler.sample(pid: getpid()) {
            snap.app = app
            snap.appCPU = meter.percent(pid: app.pid, cpuSeconds: app.cpuSeconds, at: now)
        }
        let visible = store.visibleTabIDs
        var seenItems = Set<UUID>()
        var pages: [(UUID, EnginePage)] = []
        for (key, runtime) in store.runtimes where !runtime.isEphemeral && seenItems.insert(key.item).inserted {
            let previous = snapshot.tabs.first { $0.id == key.item }
            snap.tabs.append(TabUsage(id: key.item, title: store.title(forItem: key.item, in: nil), url: runtime.url,
                                      footprint: previous?.footprint, cpu: previous?.cpu,
                                      inUse: visible.contains(key.item) || runtime.isAudible || runtime.isLoading || runtime.isCapturing
                                          || BehaviorConfig.shared.keepsAlive(runtime.url)))
            pages.append((key.item, runtime.page))
        }
        snap.tabs = Self.ordered(snap.tabs)
        snap.asleepTabs = max(0, store.workspace.allTabs().count - snap.tabs.count)
        snap.system = SystemMemory.read()
        snap.engine = snapshot.engine
        snap.engineCPU = snapshot.engineCPU
        snapshot = snap

        let profiles = store.engineProfiles
        sampling?.cancel()
        sampling = Task { [weak self] in
            var usage: [UUID: PageUsage] = [:]
            for (id, page) in pages { if let u = await page.usage() { usage[id] = u } }
            var pids = Set<Int32>()
            for profile in profiles { pids.formUnion(await profile.processIDs()) }
            guard let self, !Task.isCancelled else { return }
            self.finish(usage: usage, enginePIDs: pids, now: now)
        }
    }

    private func finish(usage: [UUID: PageUsage], enginePIDs: Set<Int32>, now: Date) {
        var snap = snapshot
        var engine: [ProcessUsage] = []
        var engineCPU: Double?
        for pid in enginePIDs.sorted() {
            guard let u = ProcessSampler.sample(pid: pid) else { continue }
            engine.append(u)
            if let cpu = meter.percent(pid: pid, cpuSeconds: u.cpuSeconds, at: now) { engineCPU = (engineCPU ?? 0) + cpu }
        }
        meter.keepOnly(enginePIDs.union([getpid()]))
        snap.engine = engine
        snap.engineCPU = engineCPU
        for i in snap.tabs.indices {
            guard let u = usage[snap.tabs[i].id] else { continue }
            snap.tabs[i].footprint = u.memory
            if let last = pageMeter[snap.tabs[i].id], now.timeIntervalSince(last.at) > 0 {
                snap.tabs[i].cpu = max(0, u.cpuSeconds - last.seconds) / now.timeIntervalSince(last.at) * 100
            }
            pageMeter[snap.tabs[i].id] = (u.cpuSeconds, now)
        }
        pageMeter = pageMeter.filter { usage[$0.key] != nil }
        snap.tabs = Self.ordered(snap.tabs)
        snapshot = snap
    }
}
