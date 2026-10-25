import CosmosCore
import Foundation
import Testing
@testable import CosmosBlocking

/// Scripted fetcher: no network. Records every request.
final class FakeFetcher: FilterListFetching, @unchecked Sendable {
    struct Call: Equatable { var url: URL; var etag: String?; var lastModified: String? }
    enum Reply { case body(String, etag: String?), notModified, html, fail }

    private let lock = NSLock()
    private var replies: [String: Reply]
    private var log: [Call] = []

    init(_ replies: [String: Reply]) { self.replies = replies }

    var calls: [Call] { lock.withLock { log } }
    func set(_ id: String, _ reply: Reply) { lock.withLock { replies[id] = reply } }
    func setAll(_ reply: Reply) { lock.withLock { for k in replies.keys { replies[k] = reply } } }

    func fetch(_ url: URL, etag: String?, lastModified: String?) async throws -> FilterListFetchResult {
        let reply: Reply = lock.withLock {
            log.append(Call(url: url, etag: etag, lastModified: lastModified))
            return replies[url.lastPathComponent] ?? .fail
        }
        switch reply {
        case .body(let text, let etag): return .downloaded(Data(text.utf8), etag: etag, lastModified: "Sat, 01 Jan 2026 00:00:00 GMT")
        case .notModified: return .notModified
        case .html: return .downloaded(Data("<!DOCTYPE html><html><body>404</body></html>".utf8), etag: nil, lastModified: nil)
        case .fail: throw URLError(.notConnectedToInternet)
        }
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(hours: Double) { lock.lock(); current = current.addingTimeInterval(hours * 3600); lock.unlock() }
}

@Suite struct FilterListManagerTests {
    static let easylist = "! Title: EasyList\n||ads.example.com^\n||banner.example.net/ads/*$image\n##.ad-banner\n"
    static let easyprivacy = "! Title: EasyPrivacy\n||track.example.org^$third-party\n"
    static let cookies = "##.cookie-banner\nexample.com##.cookie-wall\n"

    struct Fixture {
        let directory: URL
        let settingsURL: URL
        let fetcher: FakeFetcher
        let clock: TestClock
        let manager: FilterListManager

        init(replies: [String: FakeFetcher.Reply]? = nil, directory: URL = makeTempDirectory()) {
            self.directory = directory
            settingsURL = directory.appendingPathComponent("blocking.json")
            fetcher = FakeFetcher(replies ?? [
                "easylist.txt": .body(FilterListManagerTests.easylist, etag: "\"v1\""),
                "easyprivacy.txt": .body(FilterListManagerTests.easyprivacy, etag: "\"p1\""),
                "fanboy-cookiemonster.txt": .body(FilterListManagerTests.cookies, etag: nil),
            ])
            clock = TestClock()
            let clock = self.clock
            manager = FilterListManager(
                directory: directory.appendingPathComponent("FilterLists"), settingsURL: settingsURL,
                fetcher: fetcher, now: { clock.now() })
        }

        func again(replies: [String: FakeFetcher.Reply]? = nil) -> Fixture { Fixture(replies: replies, directory: directory) }
    }

    private func names(_ lists: [CompiledRuleList]) -> [String] { lists.map(\.name) }

    // MARK: Catalog

    @Test func catalogDefaultsMatchTheBrief() {
        let all = FilterListCatalog.all
        #expect(all.count == 8)
        #expect(Set(all.map(\.id)).count == 8)
        #expect(FilterListCatalog.defaultEnabledIDs == ["easylist", "easyprivacy", "fanboy-cookiemonster"])
        #expect(all.allSatisfy { $0.url.scheme == "https" })
        #expect(FilterListCatalog.info(id: "easylist")?.url.absoluteString == "https://easylist.to/easylist/easylist.txt")
        #expect(FilterListCatalog.info(id: "ublock-badware")?.category == .security)
    }

    // MARK: Refresh

    @Test func firstRefreshDownloadsCompilesAndCaches() async throws {
        let f = Fixture()
        let lists = await f.manager.refresh()
        #expect(names(lists) == ["easylist.network.1", "easylist.cosmetic.1", "easyprivacy.network.1", "fanboy-cookiemonster.cosmetic.1"])
        #expect(f.fetcher.calls.count == 3)
        for l in lists { #expect(RuleListValidator.validate(json: l.json) == [], "\(l.name)") }

        let dir = f.directory.appendingPathComponent("FilterLists")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("easylist.txt").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("easylist.meta.json").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("compiled/easylist.manifest.json").path))
        #expect(try String(contentsOf: dir.appendingPathComponent("easylist.txt"), encoding: .utf8) == Self.easylist)
    }

    @Test func freshListsAreNotRefetchedWithin24Hours() async {
        let f = Fixture()
        let first = await f.manager.refresh()
        f.clock.advance(hours: 23)
        let second = await f.manager.refresh()
        #expect(f.fetcher.calls.count == 3)
        #expect(second == first)
        let cached = await f.manager.cachedRuleLists()
        #expect(cached == first)
        #expect(f.fetcher.calls.count == 3)
    }

    @Test func staleListsAreRevalidatedWithETagAndNotRecompiledWhenUnchanged() async throws {
        let f = Fixture()
        let first = await f.manager.refresh()
        let manifestURL = f.directory.appendingPathComponent("FilterLists/compiled/easylist.manifest.json")
        let manifestBefore = try Data(contentsOf: manifestURL)

        f.clock.advance(hours: 25)
        f.fetcher.setAll(.notModified)
        let second = await f.manager.refresh()
        #expect(second == first)
        let revalidations = f.fetcher.calls.suffix(3)
        #expect(revalidations.count == 3)
        let easylistCall = try #require(revalidations.first { $0.url.lastPathComponent == "easylist.txt" })
        #expect(easylistCall.etag == "\"v1\"")
        #expect(easylistCall.lastModified == "Sat, 01 Jan 2026 00:00:00 GMT")
        #expect(try Data(contentsOf: manifestURL) == manifestBefore, "unchanged text must not be recompiled")

        // The 304 renewed the check time, so the next refresh stays offline.
        f.clock.advance(hours: 1)
        _ = await f.manager.refresh()
        #expect(f.fetcher.calls.count == 6)
    }

    @Test func changedListsAreRecompiled() async throws {
        let f = Fixture()
        let first = await f.manager.refresh()
        f.clock.advance(hours: 30)
        f.fetcher.set("easylist.txt", .body(Self.easylist + "||new-ad.example.com^\n", etag: "\"v2\""))
        f.fetcher.set("easyprivacy.txt", .notModified)
        f.fetcher.set("fanboy-cookiemonster.txt", .notModified)
        let second = await f.manager.refresh()
        let before = try #require(first.first { $0.name == "easylist.network.1" })
        let after = try #require(second.first { $0.name == "easylist.network.1" })
        #expect(after.ruleCount == before.ruleCount + 1)
        #expect(after.json.contains("new-ad\\\\.example\\\\.com"))
        // old compiled files of the replaced version are cleaned up
        let compiled = try FileManager.default.contentsOfDirectory(atPath: f.directory.appendingPathComponent("FilterLists/compiled").path)
        #expect(compiled.filter { $0.hasPrefix("easylist.network.1.") }.count == 1)
    }

    @Test func forceIgnoresFreshness() async {
        let f = Fixture()
        _ = await f.manager.refresh()
        _ = await f.manager.refresh(force: true)
        #expect(f.fetcher.calls.count == 6)
    }

    // MARK: Offline behaviour

    @Test func offlineUsesTheCachedCopy() async {
        let f = Fixture()
        let first = await f.manager.refresh()
        f.clock.advance(hours: 48)
        f.fetcher.setAll(.fail)
        let offline = await f.manager.refresh()
        #expect(offline == first)
    }

    @Test func offlineWithNothingCachedFallsBackToTheBundledList() async {
        let f = Fixture(replies: [:])
        let lists = await f.manager.refresh()
        #expect(!lists.isEmpty)
        #expect(lists.allSatisfy { $0.name.hasPrefix(FilterListManager.fallbackListID) })
        #expect(lists.contains { $0.kind == .network && $0.ruleCount > 50 })
        #expect(lists.contains { $0.kind == .cosmetic })
        for l in lists { #expect(RuleListValidator.validate(json: l.json) == [], "\(l.name)") }
    }

    @Test func cachedRuleListsWorkWithoutAnyNetworkAndUseTheFallbackBeforeTheFirstDownload() async {
        let f = Fixture()
        let before = await f.manager.cachedRuleLists()
        #expect(before.allSatisfy { $0.name.hasPrefix(FilterListManager.fallbackListID) })
        #expect(f.fetcher.calls.isEmpty)
        _ = await f.manager.refresh()
        let after = await f.manager.cachedRuleLists()
        #expect(after.contains { $0.name == "easylist.network.1" })
        #expect(!after.contains { $0.name.hasPrefix(FilterListManager.fallbackListID) })
    }

    @Test func partialFailureKeepsWhatWorksAndAddsTheFallback() async {
        let f = Fixture(replies: ["easylist.txt": .body(Self.easylist, etag: nil)])
        let lists = await f.manager.refresh()
        #expect(lists.contains { $0.name == "easylist.network.1" })
        #expect(lists.contains { $0.name.hasPrefix(FilterListManager.fallbackListID) })
    }

    @Test func htmlErrorPagesAreRejected() async throws {
        let f = Fixture(replies: ["easylist.txt": .html, "easyprivacy.txt": .html, "fanboy-cookiemonster.txt": .html])
        let lists = await f.manager.refresh()
        #expect(lists.allSatisfy { $0.name.hasPrefix(FilterListManager.fallbackListID) })
        #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("FilterLists/easylist.txt").path))
        #expect(throws: FilterListError.notAFilterList) { try FilterListManager.validatedText(Data()) }
    }

    @Test func downloadedTextIsValidatedAndBOMStripped() throws {
        let text = try FilterListManager.validatedText(Data("\u{FEFF}||a.com^\n".utf8))
        #expect(text == "||a.com^\n")
    }

    // MARK: Settings

    @Test func enabledListsPersistAcrossInstances() async throws {
        let f = Fixture()
        #expect(await f.manager.enabledListIDs() == ["easylist", "easyprivacy", "fanboy-cookiemonster"])
        try await f.manager.setEnabled("ublock-filters", true)
        try await f.manager.setEnabled("easyprivacy", false)
        #expect(FileManager.default.fileExists(atPath: f.settingsURL.path))

        let g = f.again()
        #expect(await g.manager.enabledListIDs() == ["easylist", "fanboy-cookiemonster", "ublock-filters"])
        #expect(await g.manager.isEnabled("easyprivacy") == false)
        try await g.manager.setEnabled("not-a-list", true)
        #expect(await g.manager.enabledListIDs().count == 3)
    }

    @Test func disabledListsAreNeitherFetchedNorReturned() async throws {
        let f = Fixture()
        try await f.manager.setEnabled("easyprivacy", false)
        try await f.manager.setEnabled("fanboy-cookiemonster", false)
        let lists = await f.manager.refresh()
        #expect(f.fetcher.calls.map(\.url.lastPathComponent) == ["easylist.txt"])
        #expect(lists.allSatisfy { $0.name.hasPrefix("easylist.") })

        try await f.manager.setEnabled("easylist", false)
        #expect(await f.manager.refresh().isEmpty)
        #expect(await f.manager.cachedRuleLists().isEmpty)
    }

    @Test func customListsCanBeAddedFromFileURLsAndRemoved() async throws {
        let dir = makeTempDirectory()
        let source = dir.appendingPathComponent("mylist.txt")
        try "||custom-ads.example.com^\n##.custom-ad\n".write(to: source, atomically: true, encoding: .utf8)

        let settingsURL = dir.appendingPathComponent("blocking.json")
        let manager = FilterListManager(
            directory: dir.appendingPathComponent("FilterLists"), settingsURL: settingsURL,
            catalog: [], fetcher: URLSessionFilterListFetcher())
        let info = try await manager.addCustomList(name: "Mine", url: source)
        #expect(info.isCustom && info.category == .custom && info.id.hasPrefix("custom-"))
        #expect(await manager.availableLists().map(\.id) == [info.id])

        let lists = await manager.refresh()
        #expect(lists.map(\.name) == ["\(info.id).network.1", "\(info.id).cosmetic.1"])
        #expect(lists[0].json.contains("custom-ads\\\\.example\\\\.com"))

        // survives a restart
        let again = FilterListManager(directory: dir.appendingPathComponent("FilterLists"), settingsURL: settingsURL, catalog: [], fetcher: URLSessionFilterListFetcher())
        #expect(await again.availableLists().map(\.id) == [info.id])
        #expect(await again.cachedRuleLists().map(\.name) == lists.map(\.name))

        try await again.removeCustomList(id: info.id)
        #expect(await again.availableLists().isEmpty)
        #expect(await again.refresh().isEmpty)
    }

    @Test func statusReportsCheckTimeAndRuleCounts() async {
        let f = Fixture()
        _ = await f.manager.refresh()
        let status = await f.manager.status()
        let easylist = status.first { $0.id == "easylist" }
        #expect(easylist?.isEnabled == true)
        #expect(easylist?.lastChecked == f.clock.now())
        #expect(easylist?.ruleCount != nil)
        #expect(easylist?.report?.networkParsed == 2)
        let off = status.first { $0.id == "adguard-base" }
        #expect(off?.isEnabled == false)
        #expect(off?.lastChecked == nil)
    }

    @Test func cacheKeyDependsOnTextAndCompilerVersion() {
        #expect(FilterListManager.cacheKey(for: "a") == FilterListManager.cacheKey(for: "a"))
        #expect(FilterListManager.cacheKey(for: "a") != FilterListManager.cacheKey(for: "b"))
        #expect(FilterListManager.cacheKey(for: "a").count == 64)
    }

    @Test func defaultLocationsFollowCosmosPaths() {
        #expect(CosmosPaths.file("blocking.json").lastPathComponent == "blocking.json")
    }
}
