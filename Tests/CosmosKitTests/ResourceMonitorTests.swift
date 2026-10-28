import Foundation
import Testing
import CosmosEngine
@testable import CosmosKit
@testable import CosmosCore

@MainActor
@Suite struct ResourceMonitorTests {
    private func usage(_ id: UUID = UUID(), bytes: UInt64? = nil, cpu: Double? = nil) -> ResourceMonitor.TabUsage {
        .init(id: id, title: "", url: nil, footprint: bytes, cpu: cpu, inUse: false)
    }

    @Test func theBiggestPageComesFirstAndOneWithNoFiguresLast() {
        let small = usage(bytes: 10), big = usage(bytes: 900), none = usage()
        #expect(ResourceMonitor.ordered([small, none, big]).map(\.id) == [big.id, small.id, none.id])
    }

    @Test func equalPagesKeepAFixedOrderSoTheListDoesNotShuffle() {
        let a = usage(bytes: 5), b = usage(bytes: 5), c = usage(bytes: 5)
        let first = ResourceMonitor.ordered([a, b, c]).map(\.id)
        #expect(ResourceMonitor.ordered([c, a, b]).map(\.id) == first)
        #expect(ResourceMonitor.ordered([b, c, a]).map(\.id) == first)
    }

    /// Cosmos costs the app plus the engine's processes, each once. A tab's figure is a share of those, not added again.
    @Test func theAppAndEachEngineProcessAreCountedOnce() {
        var snap = ResourceMonitor.Snapshot()
        snap.app = ProcessUsage(pid: 1, footprint: 100, cpuSeconds: 0)
        snap.appCPU = 1
        snap.engine = [ProcessUsage(pid: 7, footprint: 400, cpuSeconds: 0), ProcessUsage(pid: 7, footprint: 400, cpuSeconds: 0),
                       ProcessUsage(pid: 8, footprint: 50, cpuSeconds: 0)]
        snap.engineCPU = 15
        snap.tabs = [usage(bytes: 400, cpu: 10), usage(bytes: 50, cpu: 5), usage()]
        #expect(snap.cosmosFootprint == 550)
        #expect(snap.cosmosCPU == 16)
    }

    @Test func anEmptySnapshotCostsNothing() {
        let snap = ResourceMonitor.Snapshot()
        #expect(snap.cosmosFootprint == 0)
        #expect(snap.cosmosCPU == nil)
    }

    @Test func theMonitorSeesTheAppAndEveryAwakeTab() {
        let rig = Rig()
        _ = rig.store.newTab(url: URL(string: "about:blank?a"), in: rig.window)
        _ = rig.store.newTab(url: URL(string: "about:blank?b"), in: rig.window)
        rig.store.resources.refresh(from: rig.store)
        let snap = rig.store.resources.snapshot
        #expect(snap.tabs.count == 2)
        #expect(snap.app?.footprint ?? 0 > 0)
        #expect(snap.system != nil)
        #expect(snap.asleepTabs == 0)
    }

    @Test func aTabThatWasPutToSleepIsCountedAsAsleep() throws {
        let rig = Rig()
        let a = try #require(rig.store.newTab(url: URL(string: "about:blank?a"), in: rig.window))
        _ = rig.store.newTab(url: URL(string: "about:blank?b"), in: rig.window)
        rig.store.discardRuntime(forItem: a)
        rig.store.resources.refresh(from: rig.store)
        #expect(rig.store.resources.snapshot.tabs.count == 1)
        #expect(rig.store.resources.snapshot.asleepTabs == 1)
    }

    @Test func readingsLessThanASecondApartAreOneReading() {
        let rig = Rig()
        _ = rig.store.newTab(url: URL(string: "about:blank?a"), in: rig.window)
        let start = Date()
        rig.store.resources.refresh(from: rig.store, now: start)
        _ = rig.store.newTab(url: URL(string: "about:blank?b"), in: rig.window)
        rig.store.resources.refresh(from: rig.store, now: start.addingTimeInterval(0.3))
        #expect(rig.store.resources.snapshot.tabs.count == 1, "the second call was too soon to count")
        rig.store.resources.refresh(from: rig.store, now: start.addingTimeInterval(1.5))
        #expect(rig.store.resources.snapshot.tabs.count == 2)
    }

    @Test func theTabOnScreenIsInUseAndTheOthersCanSleep() async throws {
        let rig = Rig()
        let a = try #require(rig.store.newTab(url: URL(string: "about:blank?a"), in: rig.window))
        let b = try #require(rig.store.newTab(url: URL(string: "about:blank?b"), in: rig.window))
        rig.store.resources.refresh(from: rig.store)
        let tabs = rig.store.resources.snapshot.tabs
        #expect(tabs.first { $0.id == b }?.inUse == true)
        #expect(tabs.first { $0.id == a }?.inUse == false)
    }

    @Test func sleepingTheBackgroundKeepsTheTabOnScreen() async throws {
        let rig = Rig()
        _ = rig.store.newTab(url: URL(string: "about:blank?a"), in: rig.window)
        _ = rig.store.newTab(url: URL(string: "about:blank?b"), in: rig.window)
        let shown = try #require(rig.store.newTab(url: URL(string: "about:blank?c"), in: rig.window))
        #expect(rig.store.sleepBackgroundTabs() == 2)
        #expect(rig.store.runtimes.keys.map(\.item) == [shown])
        #expect(rig.store.sleepBackgroundTabs() == 0)
    }

    /// The engine answers after the app and tabs are shown: each tab's own memory and processor time, and the engine's
    /// processes, which are read like the app's.
    @Test func theEnginesFiguresFollowForTabsAndItsProcesses() async throws {
        let rig = Rig()
        let id = try #require(rig.store.newTab(url: URL(string: "https://example.com/"), in: rig.window))
        let page = try #require(rig.store.runtime(forItem: id, in: rig.window)).fake
        page.reportedUsage = PageUsage(memory: 12_000_000, cpuSeconds: 1)
        let profile = try #require(rig.store.fakeEngine.profiles.first)
        profile.processes = [getpid()]   // a process that is sure to be there to read
        let start = Date()
        rig.store.resources.refresh(from: rig.store, now: start)
        for _ in 0..<100 where rig.store.resources.snapshot.engine.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(rig.store.resources.snapshot.tabs.first?.footprint == 12_000_000)
        #expect(rig.store.resources.snapshot.engine.map(\.pid) == [getpid()])

        page.reportedUsage = PageUsage(memory: 12_000_000, cpuSeconds: 1.5)
        rig.store.resources.refresh(from: rig.store, now: start.addingTimeInterval(2))
        for _ in 0..<100 where rig.store.resources.snapshot.tabs.first?.cpu == nil { try await Task.sleep(for: .milliseconds(20)) }
        let cpu = try #require(rig.store.resources.snapshot.tabs.first?.cpu)
        #expect(abs(cpu - 25) < 0.001, "half a second of work in two seconds")
    }
}
