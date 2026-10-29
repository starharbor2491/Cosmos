import CryptoKit
import Foundation
import Testing
@testable import CosmosCore
@testable import CosmosImport
@testable import CosmosKit

/// Web Store packages are taken only when they are their developer's, for the extension asked for; and extensions from
/// the Web Store keep its id and are updated from it.
@MainActor
@Suite struct WebStoreTests {
    typealias Developer = WebStorePackages.Developer
    let zip = Data([0x50, 0x4B, 0x03, 0x04]) + Data("an extension".utf8)

    // MARK: Signatures

    @Test func aPackageSignedForItsExtensionIsTaken() throws {
        let developer = try Developer()
        let verified = try ChromeWebStore.verifiedPackage(try developer.package(zip: zip), expectedID: developer.id)
        #expect(verified.zip == zip)
        #expect([UInt8](verified.publicKey) == developer.key)
    }

    @Test func aChangedPackageOrOneForAnotherExtensionIsRefused() throws {
        let developer = try Developer()
        var changed = try developer.package(zip: zip)
        changed[changed.count - 1] ^= 0x01
        #expect(throws: ChromeWebStore.SignatureError.badSignature) { try ChromeWebStore.verifiedPackage(changed, expectedID: developer.id) }
        let other = try Developer()
        #expect(throws: ChromeWebStore.SignatureError.wrongExtension(developer.id)) {
            try ChromeWebStore.verifiedPackage(try developer.package(zip: zip), expectedID: other.id)
        }
        let signedElse = try developer.package(zip: zip, signedZip: Data("something else".utf8))
        #expect(throws: ChromeWebStore.SignatureError.badSignature) { try ChromeWebStore.verifiedPackage(signedElse, expectedID: developer.id) }
        // Another developer's package that claims this extension's id: no key in it makes that id.
        let claimed = try other.package(zip: zip, claimedID: Array(SHA256.hash(data: developer.key).prefix(16)))
        #expect(throws: ChromeWebStore.SignatureError.badSignature) { try ChromeWebStore.verifiedPackage(claimed, expectedID: developer.id) }
    }

    @Test func packagesWithoutASignatureCosmosCanCheckAreRefused() {
        let id = String(repeating: "a", count: 32)
        #expect(throws: ChromeWebStore.SignatureError.notCRX3) { try ChromeWebStore.verifiedPackage(zip, expectedID: id) }
        var crx2 = Data("Cr24".utf8)
        withUnsafeBytes(of: UInt32(2).littleEndian) { crx2.append(contentsOf: $0) }
        #expect(throws: ChromeWebStore.SignatureError.notCRX3) { try ChromeWebStore.verifiedPackage(crx2, expectedID: id) }
        var damaged = Data("Cr24".utf8)
        for n in [UInt32(3), UInt32(1_000)] { withUnsafeBytes(of: n.littleEndian) { damaged.append(contentsOf: $0) } }
        #expect(throws: ChromeWebStore.SignatureError.damaged) { try ChromeWebStore.verifiedPackage(damaged, expectedID: id) }
        // A header field whose length is the largest a varint can say: refused, not a crash.
        let huge: [UInt8] = [0x12, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F]
        var crafted = Data("Cr24".utf8)
        for n in [UInt32(3), UInt32(huge.count)] { withUnsafeBytes(of: n.littleEndian) { crafted.append(contentsOf: $0) } }
        crafted.append(contentsOf: huge)
        #expect(throws: ChromeWebStore.SignatureError.damaged) { try ChromeWebStore.verifiedPackage(crafted, expectedID: id) }
    }

    // MARK: The update service

    /// The service is asked as the Chromium Cosmos runs, for CRX3 packages, about every extension at once.
    @Test func theUpdateServiceIsAskedAsTheChromiumThatRuns() throws {
        let a = String(repeating: "a", count: 32), b = String(repeating: "b", count: 32)
        let url = try #require(ChromeWebStore.updateCheckURL([(a, "1.0"), (b, "2.3.4"), ("not an id", "1")], chromiumVersion: "156.0.8078.48"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "prodversion" }?.value == "156.0.8078.48")
        #expect(items.first { $0.name == "acceptformat" }?.value == "crx3")
        #expect(items.filter { $0.name == "x" }.map(\.value) == ["id=\(a)&v=1.0&uc", "id=\(b)&v=2.3.4&uc"])
        #expect(ChromeWebStore.updateCheckURL([], chromiumVersion: "156.0.8078.48") == nil)
        let download = try #require(ChromeWebStore.downloadURL(for: a, chromiumVersion: "156.0.8078.48"))
        #expect(download.absoluteString.contains("prodversion=156.0.8078.48"))
    }

    /// Its answer, in the form Google's service gives it: an update for one, none for another, an unknown id.
    @Test func theServicesAnswerGivesTheNewerVersions() {
        let a = String(repeating: "a", count: 32), b = String(repeating: "b", count: 32), c = String(repeating: "c", count: 32)
        let answer = """
            <?xml version="1.0" encoding="UTF-8"?><gupdate xmlns="http://www.google.com/update2/response" protocol="2.0" server="prod">\
            <daystart elapsed_days="7241" elapsed_seconds="1"/><app appid="\(a)" cohort="1::" status="ok"><updatecheck \
            codebase="https://clients2.googleusercontent.com/crx/blobs/x/A_1_2.crx" hash_sha256="ABCDEF" size="9" status="ok" version="1.2"/></app>\
            <app appid="\(b)" status="ok"><updatecheck status="noupdate"/></app><app appid="\(c)" status="error-unknownApplication"/>\
            <app appid="\(c)" status="ok"><updatecheck codebase="http://insecure.example/c.crx" status="ok" version="9"/></app></gupdate>
            """
        #expect(ChromeWebStore.updates(fromResponse: Data(answer.utf8)) == [
            .init(id: a, version: "1.2", codebase: URL(string: "https://clients2.googleusercontent.com/crx/blobs/x/A_1_2.crx")!, sha256: "abcdef"),
        ])
    }

    @Test func versionsCompareNumberByNumber() {
        #expect(ChromeWebStore.isVersion("1.10", newerThan: "1.9"))
        #expect(ChromeWebStore.isVersion("2026.1026.1812", newerThan: "2026.1019.5"))
        #expect(ChromeWebStore.isVersion("1.0.1", newerThan: "1.0"))
        #expect(!ChromeWebStore.isVersion("1.0.0", newerThan: "1.0"))
        #expect(!ChromeWebStore.isVersion("1.2", newerThan: "1.10"))
    }

    // MARK: Installing and updating

    /// A store with an extension center started on it, whose downloads come from `served` (address → answer).
    @MainActor final class Served {
        var answers: [String: Data] = [:]
        var asked: [URL] = []
        /// Runs as an address is asked for, before the answer comes: what the user does meanwhile.
        var meanwhile: ((URL) -> Void)?
        func fetch(_ url: URL) async throws -> Data {
            asked.append(url)
            meanwhile?(url)
            let key = answers.keys.first { url.absoluteString.contains($0) }
            guard let key, let data = answers[key] else { throw ExtensionError.download("nothing at \(url)") }
            return data
        }
    }

    private func started() throws -> (Rig, ExtensionCenter, FakeExtensions, Served) {
        let rig = Rig()
        let center = ExtensionCenter(store: rig.store, directory: rig.dir)
        rig.store.extensionCenter = center
        _ = try #require(rig.store.newTab(url: URL(string: "https://example.com/"), in: rig.window))
        center.start()
        let engine = try #require(rig.store.fakeEngine.profiles.first?.fakeExtensions)
        let served = Served()
        center.fetch = served.fetch
        return (rig, center, engine, served)
    }

    static func manifest(_ version: String, permissions: [String] = ["storage"], hosts: [String] = []) -> [String: String] {
        let json = try! JSONSerialization.data(withJSONObject: ["manifest_version": 3, "name": "Kept", "version": version,
                                                                "permissions": permissions, "host_permissions": hosts])
        return ["manifest.json": String(decoding: json, as: UTF8.self), "worker.js": "// \(version)"]
    }

    static func answer(_ id: String, _ version: String, sha256: String? = nil) -> Data {
        let hash = sha256.map { " hash_sha256=\"\($0)\"" } ?? ""
        return Data("""
            <gupdate protocol="2.0"><app appid="\(id)" status="ok"><updatecheck codebase="https://packages.test/\(id)/\(version).crx"\(hash) \
            status="ok" version="\(version)"/></app></gupdate>
            """.utf8)
    }

    /// An extension from the Web Store is installed with its developer's key in its manifest, so the engine gives it the
    /// Web Store's id; a package that is not its developer's is refused and nothing is left behind.
    @Test func aWebStoreExtensionKeepsItsIDAndAForgedOneIsRefused() async throws {
        let (rig, center, engine, served) = try started()
        defer { withExtendedLifetime(rig) {} }
        let developer = try Developer()
        served.answers["response=redirect"] = try developer.package(files: Self.manifest("1.0"))
        let item = try await center.installFromWebStore(developer.id) { _ in true }
        let manifest = try #require(ChromiumExtensionScanner.readManifest(center.folder(for: item)))
        #expect(manifest["key"] as? String == Data(developer.key).base64EncodedString())
        #expect(engine.loaded[developer.id] != nil, "the engine's id is the Web Store's")
        #expect(served.asked.first?.absoluteString.contains("prodversion=1.0") == true, "asked as the engine that runs")

        let forger = try Developer()
        served.answers["response=redirect"] = try forger.package(zip: try WebStorePackages.zip(Self.manifest("6.6")),
                                                                 claimedID: Array(SHA256.hash(data: developer.key).prefix(16)))
        let other = try Developer()
        await #expect(throws: ExtensionError.self) { try await center.installFromWebStore(other.id) { _ in true } }
        #expect(center.items.map(\.id) == [item.id])
        #expect(try FileManager.default.contentsOfDirectory(atPath: center.extensionsFolder.path) == [item.id.uuidString])
    }

    /// A newer version that asks for nothing more comes in by itself, in the old one's place and under the same id (so
    /// the engine keeps its data); one that asks for more waits for the user; one whose package isn't what the service
    /// described, or isn't the developer's, does not come in.
    @Test func updatesComeInByThemselvesUnlessTheyAskForMore() async throws {
        let (rig, center, engine, served) = try started()
        defer { withExtendedLifetime(rig) {} }
        let developer = try Developer()
        served.answers["response=redirect"] = try developer.package(files: Self.manifest("1.0", permissions: ["storage", "tabs"]))
        let first = try await center.installFromWebStore(developer.id) { _ in true }

        let quieter = try developer.package(files: Self.manifest("1.1", permissions: ["storage"]))
        served.answers["response=updatecheck"] = Self.answer(developer.id, "1.1", sha256: SHA256.hash(data: quieter).map { String(format: "%02x", $0) }.joined())
        served.answers["packages.test/\(developer.id)/1.1"] = quieter
        #expect(await center.checkForUpdates() == 1)
        let second = try #require(center.items.first)
        #expect(center.items.count == 1 && second.id != first.id && second.version == "1.1")
        #expect(engine.loaded[developer.id] == center.folder(for: second), "the same id, now the new copy")
        // The old copy goes once the engine has been told; it keeps the new one.
        for _ in 0..<100 where FileManager.default.fileExists(atPath: center.folder(for: first).path) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!FileManager.default.fileExists(atPath: center.folder(for: first).path))
        #expect(!engine.unloaded.contains(developer.id), "the engine never let go of it")
        #expect(engine.loaded[developer.id] == center.folder(for: second))

        served.answers["response=updatecheck"] = Self.answer(developer.id, "1.2")
        served.answers["packages.test/\(developer.id)/1.2"] = try developer.package(files: Self.manifest("1.2", hosts: ["https://*/*"]))
        #expect(await center.checkForUpdates() == 0)
        #expect(center.updatesWaiting[second.id] == "1.2")
        #expect(center.items.map(\.version) == ["1.1"])

        served.answers["response=redirect"] = served.answers["packages.test/\(developer.id)/1.2"]
        var asked: ExtensionRequestSummary?
        try await center.update(second.id) { summary in asked = summary; return true }
        #expect(asked?.hostPatterns == ["https://*/*"], "the user saw what it asks for")
        #expect(center.items.map(\.version) == ["1.2"] && center.updatesWaiting.isEmpty)

        let third = try #require(center.items.first)
        served.answers["response=updatecheck"] = Self.answer(developer.id, "1.3", sha256: String(repeating: "0", count: 64))
        served.answers["packages.test/\(developer.id)/1.3"] = try developer.package(files: Self.manifest("1.3"))
        #expect(await center.checkForUpdates() == 0)
        #expect(center.loadErrors[third.id]?.contains("1.3") == true)
        let impostor = try Developer()
        served.answers["response=updatecheck"] = Self.answer(developer.id, "1.4")
        served.answers["packages.test/\(developer.id)/1.4"] = try impostor.package(zip: try WebStorePackages.zip(Self.manifest("1.4")),
                                                                                  claimedID: Array(SHA256.hash(data: developer.key).prefix(16)))
        #expect(await center.checkForUpdates() == 0)
        #expect(center.items.map(\.version) == ["1.2"])
    }

    /// A new permission alone is asking for more too; and a package whose manifest is not the version announced (an
    /// older one, signed and all) is not taken as the update.
    @Test func aNewPermissionWaitsAndAnOlderPackageIsNoUpdate() async throws {
        let (rig, center, _, served) = try started()
        defer { withExtendedLifetime(rig) {} }
        let developer = try Developer()
        served.answers["response=redirect"] = try developer.package(files: Self.manifest("2.0"))
        let first = try await center.installFromWebStore(developer.id) { _ in true }
        served.answers["response=updatecheck"] = Self.answer(developer.id, "2.1")
        served.answers["packages.test/\(developer.id)/2.1"] = try developer.package(files: Self.manifest("2.1", permissions: ["storage", "cookies"]))
        #expect(await center.checkForUpdates() == 0)
        #expect(center.updatesWaiting[first.id] == "2.1")

        served.answers["response=updatecheck"] = Self.answer(developer.id, "2.2")
        served.answers["packages.test/\(developer.id)/2.2"] = try developer.package(files: Self.manifest("1.0"))
        #expect(await center.checkForUpdates() == 0)
        #expect(center.items.map(\.version) == ["2.0"])
        #expect(center.loadErrors[first.id]?.contains("2.2") == true)
    }

    /// What the user does while an update downloads stands: one they removed does not come back, one they turned off
    /// stays off.
    @Test func anUpdateDoesNotUndoARemoveOrADisableMadeWhileItDownloaded() async throws {
        let (rig, center, engine, served) = try started()
        defer { withExtendedLifetime(rig) {} }
        let developer = try Developer()
        served.answers["response=redirect"] = try developer.package(files: Self.manifest("1.0"))
        let first = try await center.installFromWebStore(developer.id) { _ in true }
        served.answers["response=updatecheck"] = Self.answer(developer.id, "1.1")
        served.answers["packages.test/\(developer.id)/1.1"] = try developer.package(files: Self.manifest("1.1"))
        served.meanwhile = { url in if url.host == "packages.test" { center.setEnabled(first.id, false) } }
        #expect(await center.checkForUpdates() == 1)
        #expect(center.items.map { "\($0.version) \($0.enabled)" } == ["1.1 false"])
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.loaded[developer.id] == nil)

        let second = try #require(center.items.first)
        served.answers["response=updatecheck"] = Self.answer(developer.id, "1.2")
        served.answers["packages.test/\(developer.id)/1.2"] = try developer.package(files: Self.manifest("1.2"))
        served.meanwhile = { url in if url.host == "packages.test" { center.remove(second.id) } }
        #expect(await center.checkForUpdates() == 0)
        #expect(center.items.isEmpty)
    }

    /// A version already waiting for the user is not downloaded again each day; an empty hash is no hash.
    @Test func aWaitingUpdateIsNotFetchedAgainAndAnEmptyHashIsNone() async throws {
        let (rig, center, _, served) = try started()
        defer { withExtendedLifetime(rig) {} }
        let developer = try Developer()
        served.answers["response=redirect"] = try developer.package(files: Self.manifest("1.0"))
        let first = try await center.installFromWebStore(developer.id) { _ in true }
        served.answers["response=updatecheck"] = Self.answer(developer.id, "1.1")
        served.answers["packages.test/\(developer.id)/1.1"] = try developer.package(files: Self.manifest("1.1", hosts: ["https://*/*"]))
        _ = await center.checkForUpdates()
        #expect(center.updatesWaiting[first.id] == "1.1")
        served.asked = []
        _ = await center.checkForUpdates()
        #expect(!served.asked.contains { $0.host == "packages.test" })

        served.answers["response=updatecheck"] = Self.answer(developer.id, "1.3", sha256: "")
        served.answers["packages.test/\(developer.id)/1.3"] = try developer.package(files: Self.manifest("1.3"))
        #expect(await center.checkForUpdates() == 1)
        #expect(center.items.map(\.version) == ["1.3"])
    }

    /// A version written another way ("1.1.0" for "1.1") is the same version; Update… refuses a package that is no newer;
    /// a check that cannot reach the Web Store says so.
    @Test func versionsAreNumbersAndAFailedCheckSaysSo() async throws {
        let (rig, center, _, served) = try started()
        defer { withExtendedLifetime(rig) {} }
        let developer = try Developer()
        served.answers["response=redirect"] = try developer.package(files: Self.manifest("1.0"))
        let first = try await center.installFromWebStore(developer.id) { _ in true }
        served.answers["response=updatecheck"] = Self.answer(developer.id, "1.1")
        served.answers["packages.test/\(developer.id)/1.1"] = try developer.package(files: Self.manifest("1.1.0"))
        #expect(await center.checkForUpdates() == 1)
        let second = try #require(center.items.first)
        #expect(second.version == "1.1.0" && second.id != first.id)

        served.answers["response=redirect"] = try developer.package(files: Self.manifest("1.1"))
        await #expect(throws: ExtensionError.self) { try await center.update(second.id) { _ in true } }
        #expect(center.items.map(\.id) == [second.id])

        served.answers["response=updatecheck"] = nil
        #expect(await center.checkForUpdates() == 0)
        #expect(center.message == "Cosmos couldn't reach the Web Store to look for updates.")
    }

    /// A disabled extension is updated too, and stays off.
    @Test func aDisabledExtensionIsUpdatedAndStaysOff() async throws {
        let (rig, center, engine, served) = try started()
        defer { withExtendedLifetime(rig) {} }
        let developer = try Developer()
        served.answers["response=redirect"] = try developer.package(files: Self.manifest("1.0"))
        let first = try await center.installFromWebStore(developer.id) { _ in true }
        center.setEnabled(first.id, false)
        try await Task.sleep(for: .milliseconds(50))
        served.answers["response=updatecheck"] = Self.answer(developer.id, "2.0")
        served.answers["packages.test/\(developer.id)/2.0"] = try developer.package(files: Self.manifest("2.0"))
        #expect(await center.checkForUpdates() == 1)
        #expect(center.items.map { "\($0.version) \($0.enabled)" } == ["2.0 false"])
        #expect(engine.loaded[developer.id] == nil)
    }
}
