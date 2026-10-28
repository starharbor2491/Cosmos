import Foundation
import Testing
import CosmosEngine
@testable import CosmosKit
@testable import CosmosCore

@MainActor
@Suite struct ContentBlockerTests {
    @Test func allowlistCoversTheHostAndItsSubdomainsOnly() throws {
        let list = ["example.com", "News.Site"]
        #expect(ContentBlockerController.isAllowlisted(try #require(URL(string: "https://example.com/a")), allowlist: list))
        #expect(ContentBlockerController.isAllowlisted(try #require(URL(string: "https://www.example.com/")), allowlist: list))
        #expect(ContentBlockerController.isAllowlisted(try #require(URL(string: "https://sub.news.site/x")), allowlist: list))
        #expect(!ContentBlockerController.isAllowlisted(try #require(URL(string: "https://notexample.com/")), allowlist: list))
        #expect(!ContentBlockerController.isAllowlisted(try #require(URL(string: "https://example.org/")), allowlist: list))
        #expect(!ContentBlockerController.isAllowlisted(try #require(URL(string: "https://example.com/")), allowlist: []))
    }

    /// The Site Controls switch answers for the site the way blocking does (its subdomains too), and turning it back on
    /// takes away whatever entry turned it off, not only one for this exact host.
    @Test func theSiteSwitchFollowsTheEntryThatCoversTheSite() throws {
        let url = try #require(URL(string: "https://www.example.com/a"))
        #expect(ContentBlockerController.isAllowlisted(url, allowlist: ["example.com"]))
        #expect(ContentBlockerController.allowlist(["example.com", "other.org"], blocking: true, for: url) == ["other.org"])
        #expect(ContentBlockerController.allowlist([], blocking: false, for: url) == ["www.example.com"])
        #expect(ContentBlockerController.allowlist(["example.com"], blocking: false, for: url) == ["example.com"], "already off: nothing to add")
    }

    /// A store whose only list is one of the user's own (so nothing is downloaded), once that list reached the profile.
    private func blocking(allowlist: [String]) async throws -> (Rig, ContentBlockerController, FakeProfile) {
        let rig = Rig()
        let source = rig.dir.appendingPathComponent("mine.txt")
        try FileManager.default.createDirectory(at: rig.dir, withIntermediateDirectories: true)
        try "! test list\n||ads.example^\nlocalhost##.cosmos-test-ad\n".write(to: source, atomically: true, encoding: .utf8)
        rig.store.settings.enabledFilterLists = []
        rig.store.settings.adBlockAllowlist = allowlist
        let blocker = ContentBlockerController(store: rig.store, directory: rig.dir, offline: false)
        rig.store.blocker = blocker
        _ = rig.store.environment(forProfile: rig.store.workspace.profiles[0].id)
        let profile = try #require(rig.store.fakeEngine.profiles.first)
        _ = await blocker.addCustomList(name: "mine", url: source)
        try await until { profile.blocking?.lists?.contains { $0.json.contains("ads.example") } == true }
        return (rig, blocker, profile)
    }

    private func until(_ done: () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(for: .milliseconds(100)) }
        #expect(done())
    }

    /// A list of the user's own is compiled and handed to the engine: its requests rules and its hiding rules.
    @Test func aCustomListIsCompiledAndHandedToTheProfile() async throws {
        let (rig, blocker, profile) = try await blocking(allowlist: [])
        let lists = try #require(profile.blocking?.lists)
        #expect(lists.contains { $0.kind == .network && $0.json.contains("||ads.example^") })
        #expect(lists.contains { $0.kind == .cosmetic && $0.json.contains("cosmos-test-ad") })
        #expect(blocker.installedRuleCount > 0)
        // A profile opened later gets the same lists straight away.
        _ = rig.store.environment(forProfile: nil)
        #expect(rig.store.fakeEngine.profiles.last?.blocking?.lists == lists)
    }

    /// The Site Controls switch goes to the engine with the lists, and a change to it is passed on.
    @Test func theSitesBlockingIsOffForGoWithTheLists() async throws {
        let (rig, _, profile) = try await blocking(allowlist: ["localhost"])
        #expect(profile.blocking?.allowlist == ["localhost"])
        rig.store.settings.adBlockAllowlist = ["localhost", "example.com"]
        try await until { profile.blocking?.allowlist == ["localhost", "example.com"] }
    }

    @Test func turningBlockingOffRemovesTheRules() async throws {
        let (rig, blocker, profile) = try await blocking(allowlist: [])
        rig.store.settings.adBlockingEnabled = false
        try await until { profile.blocking.map { $0.lists == nil } == true }
        #expect(blocker.installedRuleCount == 0)
    }
}
