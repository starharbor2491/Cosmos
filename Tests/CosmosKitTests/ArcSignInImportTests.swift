import Foundation
import Testing
import CosmosEngine
@testable import CosmosCore
@testable import CosmosKit

/// Arc's saved passwords go into Cosmos's, and its cookies into the default profile, from an Arc folder made here (the
/// values encrypted, by the openssl command, under the key of the secret "test-secret"). The summary has counts only.
@MainActor
@Suite struct ArcSignInImportTests {
    static func hex(_ s: String) -> Data {
        Data(stride(from: 0, to: s.count, by: 2).map { i in
            UInt8(s[s.index(s.startIndex, offsetBy: i)..<s.index(s.startIndex, offsetBy: i + 2)], radix: 16)!
        })
    }

    /// An Arc folder whose default profile has one saved password ("hunter2" for someone at example.com) and one cookie
    /// (".example.com", "cookie-value").
    static func arcFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-arc-signins-\(UUID().uuidString)", isDirectory: true)
        let profile = folder.appendingPathComponent("User Data/Default", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let logins = try SQLiteDatabase(path: profile.appendingPathComponent("Login Data").path)
        try logins.execute("""
            CREATE TABLE logins (origin_url VARCHAR NOT NULL, username_value VARCHAR, password_value BLOB, blacklisted_by_user INTEGER NOT NULL,
              date_created INTEGER NOT NULL, date_password_modified INTEGER NOT NULL DEFAULT 0);
            """)
        try logins.run("INSERT INTO logins VALUES ('https://example.com/login', 'someone', ?, 0, 13300000000000000, 0)",
                       [.blob(Data("v10".utf8) + hex("53790265f7517865ba531ddf2fefcd77"))])
        let cookies = try SQLiteDatabase(path: profile.appendingPathComponent("Cookies").path)
        try cookies.execute("""
            CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
            INSERT INTO meta VALUES('version', '24');
            CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL, name TEXT NOT NULL,
              value TEXT NOT NULL, encrypted_value BLOB NOT NULL, path TEXT NOT NULL, expires_utc INTEGER NOT NULL, is_secure INTEGER NOT NULL,
              is_httponly INTEGER NOT NULL, is_persistent INTEGER NOT NULL, samesite INTEGER NOT NULL);
            """)
        try cookies.run("INSERT INTO cookies VALUES (13300000000000000, '.example.com', '', 'session', '', ?, '/', 0, 1, 1, 0, 1)", [
            .blob(Data("v10".utf8) + hex("85cd81e47253f2b0648f03c6426c8abb9be1789229d201c454d9e4561a0b9a7498f01778315aaab3c96d1964631d6074")),
        ])
        return folder
    }

    @Test func arcsPasswordsAndSignInsComeIn() async throws {
        let folder = try Self.arcFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let rig = Rig()
        let summary = await ImportCoordinator.importArcSignIns(into: rig.store, from: folder, secret: { "test-secret" })
        #expect(rig.store.passwords.logins.map { "\($0.origin) \($0.username) \($0.password)" } == ["https://example.com someone hunter2"])
        let profile = try #require(rig.store.environment(forProfile: rig.store.workspace.profiles[0].id).engineProfile as? FakeProfile)
        #expect(profile.cookies == [EngineCookie(domain: ".example.com", name: "session", value: "cookie-value", path: "/", expires: nil,
                                                 isSecure: true, isHTTPOnly: true, sameSite: .lax)])
        #expect(summary == "Imported 1 password and sign-ins to sites (1 cookie) from Arc.")
        #expect(!summary.contains("example"), "no site in what Cosmos says")
    }

    @Test func withoutArcsKeyNothingComesIn() async throws {
        let folder = try Self.arcFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let rig = Rig()
        let summary = await ImportCoordinator.importArcSignIns(into: rig.store, from: folder, secret: { nil })
        #expect(rig.store.passwords.logins.isEmpty)
        #expect(summary.hasPrefix("Cosmos couldn't get Arc's key"))
    }
}
