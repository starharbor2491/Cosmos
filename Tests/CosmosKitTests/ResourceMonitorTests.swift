import Foundation
import Testing
import WebKit
@testable import CosmosKit
@testable import CosmosCore

@MainActor
@Suite struct ResourceMonitorTests {
    private func usage(_ id: UUID = UUID(), pid: Int32? = nil, bytes: UInt64? = nil, cpu: Double? = nil) -> ResourceMonitor.TabUsage {
        .init(id: id, title: "", url: nil, pid: pid, footprint: bytes, cpu: cpu, inUse: false)
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

    @Test func tabsSharingOneProcessAreCountedOnce() {
        var snap = ResourceMonitor.Snapshot()
        snap.app = ProcessUsage(pid: 1, footprint: 100, cpuSeconds: 0)
        snap.appCPU = 1
        snap.tabs = [usage(pid: 7, bytes: 400, cpu: 10), usage(pid: 7, bytes: 400, cpu: 10), usage(pid: 8, bytes: 50, cpu: 5), usage()]
        #expect(snap.cosmosFootprint == 550)
        #expect(snap.cosmosCPU == 16)
    }

    @Test func anEmptySnapshotCostsNothing() {
        let snap = ResourceMonitor.Snapshot()
        #expect(snap.cosmosFootprint == 0)
        #expect(snap.cosmosCPU == nil)
    }

    /// A tab that is still loading cannot be put to sleep, so the tests wait for their blank pages to be done.
    private func waitUntilLoaded(_ rig: Rig) async throws {
        let deadline = Date().addingTimeInterval(20)
        while rig.store.runtimes.values.contains(where: \.isLoading), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
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
        try await waitUntilLoaded(rig)
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
        try await waitUntilLoaded(rig)
        #expect(rig.store.sleepBackgroundTabs() == 2)
        #expect(rig.store.runtimes.keys.map(\.item) == [shown])
        #expect(rig.store.sleepBackgroundTabs() == 0)
    }

    /// The page process's number comes from a property WebKit keeps for its own tools; this is what tells us a system
    /// update took it away.
    @Test func aLoadedPageHasAProcessWeCanReadTheMemoryOf() async throws {
        let server = try await PageServer(html: "<html><body><h1>hello</h1></body></html>")
        let rig = Rig()
        let id = try #require(rig.store.newTab(url: nil, in: rig.window))
        let web = try #require(rig.store.runtime(forItem: id, in: rig.window)).webView
        await LoadWaiter().load(URL(string: "http://127.0.0.1:\(server.port)/")!, in: web)
        let pid = try #require(web.webProcessID, "WebKit no longer says which process draws a page")
        let usage = try #require(ProcessSampler.sample(pid: pid), "the page process is not ours to look at")
        #expect(usage.footprint > 1_000_000)
        #expect(pid != getpid())
    }
}
