import AppKit
import Foundation
import Testing
import CosmosEngine
import CosmosBlocking
@testable import CosmosKit
@testable import CosmosCore

/// A site asking for the camera, microphone, location or notifications. The engine asks Cosmos; Cosmos answers from what
/// the user decided, and what Settings ▸ Engine blocks is refused without a question.
@MainActor
@Suite struct PermissionTests {
    private func runtime(_ rig: Rig) throws -> TabRuntime {
        _ = try #require(rig.store.newTab(url: URL(string: "about:blank?perm"), in: rig.window))
        return try #require(rig.store.currentRuntime(in: rig.window))
    }

    @Test func whatSettingsBlockIsRefusedWithoutAsking() async throws {
        let rig = Rig()
        let tab = try runtime(rig)
        rig.store.settings.engine.camera = .block
        rig.store.settings.engine.notifications = .block
        #expect(await tab.page(tab.page, wantsPermission: PermissionRequest(kind: .camera, host: "meet.example")) == false)
        #expect(await tab.page(tab.page, wantsPermission: PermissionRequest(kind: .cameraAndMicrophone, host: "meet.example")) == false,
                "the camera is part of it")
        #expect(await tab.page(tab.page, wantsPermission: PermissionRequest(kind: .notifications, host: "news.example")) == false)
        #expect(rig.store.settings.permissionDecisions.isEmpty, "a refusal by setting is not a decision about the site")
    }

    /// What the user decided for a site wins over the setting for every site, as a site exception does in Chrome.
    @Test func aRememberedAnswerIsGivenWithoutAsking() async throws {
        let rig = Rig()
        let tab = try runtime(rig)
        rig.store.settings.permissionDecisions["meet.example|camera"] = true
        rig.store.settings.permissionDecisions["meet.example|microphone"] = false
        rig.store.settings.engine.camera = .block
        #expect(await tab.page(tab.page, wantsPermission: PermissionRequest(kind: .camera, host: "meet.example")) == true)
        #expect(await tab.page(tab.page, wantsPermission: PermissionRequest(kind: .microphone, host: "meet.example")) == false)
    }

    /// What the user decided reaches every profile's engine, so a site the user allowed finds itself allowed before it
    /// asks, and a reset in Site Controls takes the permission back.
    @Test func decisionsReachTheEngineOfEveryProfile() throws {
        let rig = Rig()
        rig.store.settings.permissionDecisions["meet.example|camera"] = true
        let engine = try #require(rig.store.engine as? FakeEngine)
        _ = try runtime(rig)
        let profile = try #require(engine.profiles.last)
        #expect(profile.permissionDecisions == [PermissionDecision(host: "meet.example", kind: .camera, allowed: true)])
        rig.store.settings.permissionDecisions["news.example|notifications"] = false
        #expect(Set(profile.permissionDecisions) == [PermissionDecision(host: "meet.example", kind: .camera, allowed: true),
                                                    PermissionDecision(host: "news.example", kind: .notifications, allowed: false)])
        rig.store.settings.permissionDecisions = [:]
        #expect(profile.permissionDecisions.isEmpty)
    }

    /// A site that wants a user name and password (HTTP authentication): the answer comes from the store's sign-in, which
    /// in the app is a sheet over the tab.
    @Test func aSignInChallengeIsAnsweredByTheStore() async throws {
        let rig = Rig()
        let tab = try runtime(rig)
        var asked: [AuthChallenge] = []
        rig.store.signIn = { _, challenge in asked.append(challenge); return PageCredentials(user: "ann", password: "pw") }
        let challenge = AuthChallenge(host: "intranet.example", realm: "Staff", isProxy: false, isSecure: true)
        #expect(await tab.page(tab.page, wantsCredentialsFor: challenge) == PageCredentials(user: "ann", password: "pw"))
        #expect(asked == [challenge])
    }

    /// A video asks for Picture in Picture: the engine hands over a view of it, which the store puts in a floating window.
    /// Closing that window takes the video back; the page leaving it closes the window.
    @Test func pictureInPictureGoesThroughTheStore() async throws {
        let rig = Rig()
        let tab = try runtime(rig)
        let view = NSView()
        #expect(await tab.page(tab.page, wantsPictureInPicture: view) == false, "no window to put it in")
        var shown: [NSView] = []
        var ended = 0
        rig.store.onPictureInPicture = { _, v in shown.append(v); return true }
        rig.store.onPictureInPictureEnded = { _ in ended += 1 }
        #expect(await tab.page(tab.page, wantsPictureInPicture: view) == true)
        #expect(shown == [view])
        #expect(tab.isInPictureInPicture)
        tab.pageDidLeavePictureInPicture(tab.page)
        #expect(ended == 1)
        #expect(!tab.isInPictureInPicture)
        let before = try #require(tab.page as? FakePage).leftPictureInPicture
        tab.exitPictureInPicture()
        #expect((tab.page as? FakePage)?.leftPictureInPicture == before + 1)
    }

    /// A page from a site on a malware or phishing list: Cosmos says so before it loads, unless the setting is off or the
    /// user chose to visit it anyway in this session.
    @Test func dangerousSitesAreCaughtUnlessTheUserSaidOtherwise() throws {
        let rig = Rig()
        let tab = try runtime(rig)
        rig.store.dangerousSites = DangerousSites.parse("0.0.0.0 phish.example", reason: .phishing)
        let url = URL(string: "https://login.phish.example/")!
        #expect(tab.page(tab.page, dangerAt: url) == .phishing)
        #expect(tab.page(tab.page, dangerAt: URL(string: "https://bank.example/")!) == nil)
        rig.store.settings.warnAboutDangerousSites = false
        #expect(tab.page(tab.page, dangerAt: url) == nil, "the setting is off")
        rig.store.settings.warnAboutDangerousSites = true
        rig.store.allowDangerousSite(url)
        #expect(tab.page(tab.page, dangerAt: url) == nil, "visited anyway, for this session")
        #expect(rig.store.settings.permissionDecisions.isEmpty)
    }

    /// The engine never asks macOS where the Mac is: Cosmos does, and hands the answer over.
    @Test func theLocationComesFromCosmos() async throws {
        let rig = Rig()
        let tab = try runtime(rig)
        rig.store.locate = { PageLocation(latitude: 48.85, longitude: 2.35, accuracy: 20) }
        #expect(await tab.pageWantsLocation(tab.page) == PageLocation(latitude: 48.85, longitude: 2.35, accuracy: 20))
        rig.store.locate = { nil }
        #expect(await tab.pageWantsLocation(tab.page) == nil)
    }
}
