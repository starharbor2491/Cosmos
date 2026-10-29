import CryptoKit
import Foundation
import Testing
@testable import CosmosCore

@Suite struct PasswordVaultTests {
    let key = SymmetricKey(size: .bits256)
    let day = Date(timeIntervalSince1970: 1_750_000_000)

    func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-vault-\(UUID().uuidString)/Passwords.vault")
    }

    @Test func whatIsSavedIsThereNextTimeAndTheFileSaysNothingWithoutTheKey() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let vault = try PasswordVault(file: file, key: key)
        try vault.save(origin: "https://example.com", username: "someone@example.com", password: "correct horse", now: day)
        try vault.neverSave("https://bank.example")

        let again = try PasswordVault(file: file, key: key)
        #expect(again.logins.map { "\($0.site) \($0.username) \($0.password)" } == ["example.com someone@example.com correct horse"])
        #expect(again.neverSaved == ["https://bank.example"])

        let bytes = try Data(contentsOf: file)
        for secret in ["example.com", "someone", "correct horse", "bank"] {
            #expect(bytes.range(of: Data(secret.utf8)) == nil, "\(secret) is not in the file")
        }
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(throws: PasswordVault.Failure.locked) { try PasswordVault(file: file, key: SymmetricKey(size: .bits256)) }
    }

    /// A file that is there but can't be read is not an empty vault: saving into one would write over every password in it.
    @Test func aFileThatCannotBeReadIsNotTakenForAnEmptyOne() throws {
        let file = temporaryFile()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        try PasswordVault(file: file, key: key).save(origin: "https://example.com", username: "a", password: "kept", now: day)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        #expect(throws: PasswordVault.Failure.unreadable) { try PasswordVault(file: file, key: key) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try PasswordVault(file: file, key: key).logins.map(\.password) == ["kept"])
    }

    @Test func aSignInPrintsWithoutItsPassword() {
        let login = SavedLogin(origin: "https://example.com", username: "a", password: "hunter2", created: day)
        var dumped = ""
        dump(login, to: &dumped)
        for text in [String(describing: login), String(reflecting: login), dumped, "\(login)"] {
            #expect(!text.contains("hunter2"), "\(text)")
            #expect(text.contains("example.com"))
        }
    }

    @Test func savingTheSameSiteAndUsernameChangesItsPassword() throws {
        let vault = try PasswordVault(file: nil, key: key)
        let first = try vault.save(origin: "https://example.com", username: "a", password: "one", now: day)
        #expect(vault.wouldChange(origin: "https://example.com", username: "a", password: "one") == false)
        #expect(vault.wouldChange(origin: "https://example.com", username: "a", password: "two"))
        let second = try vault.save(origin: "https://example.com", username: "a", password: "two", now: day.addingTimeInterval(60))
        try vault.save(origin: "https://example.com", username: "b", password: "three", now: day)
        #expect(second.id == first.id && second.created == day)
        #expect(vault.logins.count == 2)
        #expect(vault.logins(for: "https://example.com").first { $0.username == "a" }?.password == "two")
        #expect(vault.logins(for: "http://example.com").isEmpty, "another origin (here the scheme) gets none")
    }

    @Test func importedSignInsDoNotReplaceOnesCosmosHas() throws {
        let vault = try PasswordVault(file: nil, key: key)
        try vault.save(origin: "https://example.com", username: "a", password: "mine", now: day)
        let added = try vault.add([
            SavedLogin(origin: "https://example.com", username: "a", password: "theirs", created: day),
            SavedLogin(origin: "https://other.example", username: "a", password: "new", created: day),
        ])
        #expect(added == 1)
        #expect(vault.logins(for: "https://example.com").map(\.password) == ["mine"])
        #expect(vault.logins(for: "https://other.example").map(\.password) == ["new"])
    }

    @Test func theMostRecentlyUsedComesFirstAndSavingASiteUndoesNever() throws {
        let vault = try PasswordVault(file: nil, key: key)
        let a = try vault.save(origin: "https://example.com", username: "a", password: "1", now: day)
        try vault.save(origin: "https://example.com", username: "b", password: "2", now: day.addingTimeInterval(10))
        #expect(vault.logins(for: "https://example.com").map(\.username) == ["b", "a"])
        try vault.markUsed(a.id, now: day.addingTimeInterval(20))
        #expect(vault.logins(for: "https://example.com").map(\.username) == ["a", "b"])
        try vault.remove(a.id)
        #expect(vault.logins(for: "https://example.com").map(\.username) == ["b"])

        try vault.neverSave("https://example.com")
        #expect(vault.neverSaved == ["https://example.com"])
        try vault.save(origin: "https://example.com", username: "c", password: "3", now: day)
        #expect(vault.neverSaved.isEmpty)
    }
}
