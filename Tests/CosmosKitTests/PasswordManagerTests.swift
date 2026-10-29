import CryptoKit
import Foundation
import Testing
@testable import CosmosCore
@testable import CosmosKit

/// When the password manager opens its vault (and so asks the Keychain), what it does when that fails, and what it offers.
@MainActor
@Suite struct PasswordManagerTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-passwords-\(UUID().uuidString)", isDirectory: true)
    var file: URL { folder.appendingPathComponent("Passwords.vault") }
    let key = SymmetricKey(size: .bits256)

    /// A key that counts how often the Keychain would have been asked, and can be made to fail.
    final class Keychain {
        var asked = 0
        var fails = false
        let key: SymmetricKey
        init(_ key: SymmetricKey) { self.key = key }
        func get() throws -> SymmetricKey {
            asked += 1
            if fails { throw PasswordManager.KeychainError(status: -25293) }
            return key
        }
    }

    /// Nothing that only looks (a page's form, a list drawing) asks the Keychain while there is no vault yet; the first
    /// sign-in that is sent does.
    @Test func theKeychainIsAskedOnlyWhenThereIsAReason() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let keychain = Keychain(key)
        let passwords = PasswordManager(file: file, key: keychain.get)
        passwords.prepare()
        #expect(passwords.logins(for: "https://example.com").isEmpty)
        #expect(keychain.asked == 0, "no vault yet: a sign-in form asks nothing")

        #expect(passwords.shouldOffer(origin: "https://example.com", username: "a", password: "one"))
        #expect(keychain.asked == 1)
        passwords.save(origin: "https://example.com", username: "a", password: "one")

        let later = PasswordManager(file: file, key: keychain.get)
        #expect(later.logins(for: "https://example.com").isEmpty, "reading never opens it")
        #expect(keychain.asked == 1)
        later.prepare()
        #expect(keychain.asked == 2, "a sign-in form with a vault there opens it")
        #expect(later.logins(for: "https://example.com").map(\.password) == ["one"])
    }

    /// The Keychain said no: pages don't make Cosmos ask again, and again; the user opening their passwords does.
    @Test func afterTheKeychainSaysNoOnlyTheUserTriesAgain() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try PasswordVault(file: file, key: key).save(origin: "https://example.com", username: "a", password: "kept")
        let keychain = Keychain(key)
        keychain.fails = true
        let passwords = PasswordManager(file: file, key: keychain.get)
        passwords.prepare()
        #expect(keychain.asked == 1)
        #expect(passwords.problem != nil)
        passwords.prepare()
        #expect(!passwords.shouldOffer(origin: "https://example.com", username: "a", password: "new"))
        #expect(keychain.asked == 1, "a page asks once")

        keychain.fails = false
        passwords.load()
        #expect(keychain.asked == 2)
        #expect(passwords.problem == nil)
        #expect(passwords.logins.map(\.password) == ["kept"])
    }

    /// A vault this key does not open is put aside (its key may come back), and a new list begins.
    @Test func aVaultTheKeyDoesNotOpenIsKeptAside() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try PasswordVault(file: file, key: SymmetricKey(size: .bits256)).save(origin: "https://example.com", username: "a", password: "old")
        let old = try Data(contentsOf: file)
        let passwords = PasswordManager(file: file, key: { key })
        passwords.load()
        #expect(passwords.problem?.contains("kept the old file") == true)
        #expect(passwords.logins.isEmpty)
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains("unreadable") }
        #expect(aside.count == 1)
        #expect(try Data(contentsOf: folder.appendingPathComponent(aside[0])) == old)
        passwords.save(origin: "https://example.com", username: "a", password: "new")
        #expect(try PasswordVault(file: file, key: key).logins.map(\.password) == ["new"])
    }

    /// A vault file that can't be read is left alone, and nothing is saved over it.
    @Test func aVaultThatCannotBeReadIsLeftAlone() throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try PasswordVault(file: file, key: key).save(origin: "https://example.com", username: "a", password: "kept")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        let passwords = PasswordManager(file: file, key: { key })
        passwords.save(origin: "https://example.com", username: "b", password: "lost?")
        #expect(passwords.problem == "Cosmos couldn't read the file of its saved passwords.")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try PasswordVault(file: file, key: key).logins.map(\.password) == ["kept"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Passwords.vault"])
    }

    @Test func whatIsOfferedAndWhatIsNot() {
        let passwords = PasswordManager(file: nil, key: { key })
        let site = "https://example.com"
        #expect(passwords.shouldOffer(origin: site, username: "a", password: "one"))
        #expect(!passwords.shouldOffer(origin: site, username: "a", password: "one"), "asked once")
        #expect(!passwords.shouldOffer(origin: site, username: "a", password: ""), "no password, nothing to save")
        passwords.save(origin: site, username: "a", password: "one")
        #expect(!passwords.shouldOffer(origin: site, username: "a", password: "one"), "saved already")
        #expect(passwords.shouldOffer(origin: site, username: "a", password: "two"), "a new password is")
        passwords.neverSave(site)
        #expect(!passwords.shouldOffer(origin: site, username: "b", password: "three"))
        #expect(passwords.neverSaved == [site])
        passwords.allowSaving(site)
        #expect(passwords.shouldOffer(origin: site, username: "b", password: "three"))
    }

    @Test func theLastUsedComesFirstAndImportsKeepWhatCosmosHas() throws {
        let passwords = PasswordManager(file: nil, key: { key })
        let site = "https://example.com", day = Date(timeIntervalSince1970: 1_750_000_000)
        let added = passwords.add([SavedLogin(origin: site, username: "a", password: "1", created: day),
                                   SavedLogin(origin: site, username: "b", password: "2", created: day.addingTimeInterval(60))],
                                  neverSaved: ["https://bank.example"])
        #expect(added == 2)
        #expect(passwords.neverSaved == ["https://bank.example"])
        #expect(passwords.logins(for: site).map(\.username) == ["b", "a"])
        passwords.markUsed(try #require(passwords.logins.first { $0.username == "a" }).id)
        #expect(passwords.logins(for: site).map(\.username) == ["a", "b"])
        #expect(passwords.add([SavedLogin(origin: site, username: "a", password: "theirs", created: day)]) == 0)
        #expect(passwords.logins(for: site).first?.password == "1")
    }

    /// A private window's pages neither open the vault nor are offered to save, and have nothing to fill.
    @Test func aPrivateWindowSavesAndFillsNothing() throws {
        let keychain = Keychain(key)
        let store = BrowserStore(directory: nil, incognito: true, engine: FakeEngine(), passwordKey: keychain.get)
        let window = store.makeWindowState()
        store.register(window)
        let id = try #require(store.newTab(url: URL(string: "https://example.com/"), in: window))
        let runtime = try #require(store.runtime(forItem: id, in: window))
        runtime.handleAgentMessage(["type": "loginForm", "frameOrigin": "https://example.com"], fromMainFrame: true)
        runtime.handleAgentMessage(["type": "login", "frameOrigin": "https://example.com", "username": "a", "password": "secret"],
                                   fromMainFrame: true)
        #expect(runtime.offeredLogin == nil)
        #expect(runtime.savedLogins.isEmpty)
        #expect(keychain.asked == 0)
    }

    /// A page that keeps sending its form raises one question at a time.
    @Test func aTabAsksOneQuestionAtATime() throws {
        let rig = Rig()
        let id = try #require(rig.store.newTab(url: URL(string: "https://example.com/"), in: rig.window))
        let runtime = try #require(rig.store.runtime(forItem: id, in: rig.window))
        defer { runtime.tearDown() }
        for n in 0..<3 {
            runtime.handleAgentMessage(["type": "login", "frameOrigin": "https://example.com", "username": "a", "password": "p\(n)"],
                                       fromMainFrame: true)
        }
        #expect(runtime.offeredLogin == .init(origin: "https://example.com", username: "a"))
        #expect(rig.store.passwords.shouldOffer(origin: "https://example.com", username: "a", password: "p1"),
                "the ones sent while it asked were not counted as asked")
    }
}
