import CommonCrypto
import CryptoKit
import Foundation
import Testing
import CosmosCore
@testable import CosmosImport

/// Saved passwords and cookies of a Chromium profile, from databases laid out as Chromium's are, encrypted with a key
/// made by other tools (Python's PBKDF2 and the openssl command), so the tests do not share a mistake with the code.
@Suite struct ChromiumSecretsTests {
    static let secret = "test-secret"
    /// PBKDF2-HMAC-SHA1("test-secret", "saltysalt", 1003 rounds, 16 bytes), from Python's hashlib.
    static let key: [UInt8] = hex("01ab06dc67d036480129f3e40d53ca5f")
    let storage = ChromiumSafeStorage(secret: secret)
    let now = browserDate(1_750_000_000)

    static func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map { i in
            UInt8(s[s.index(s.startIndex, offsetBy: i)..<s.index(s.startIndex, offsetBy: i + 2)], radix: 16)!
        }
    }

    /// "v10" and `plain` encrypted as Chromium does, with `key`.
    static func encrypt(_ plain: Data, key: [UInt8] = key) -> Data {
        var out = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
        var moved = 0
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        _ = plain.withUnsafeBytes { p in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key, key.count, iv,
                    p.baseAddress, plain.count, &out, out.count, &moved)
        }
        return Data("v10".utf8) + Data(out.prefix(moved))
    }

    static func encrypt(_ text: String, key: [UInt8] = key) -> Data { encrypt(Data(text.utf8), key: key) }

    @Test func aValueEncryptedAsChromiumDoesComesBack() {
        // openssl enc -aes-128-cbc -K <key> -iv 2020…20 of "hunter2".
        let fromOpenSSL = Data("v10".utf8) + Data(Self.hex("53790265f7517865ba531ddf2fefcd77"))
        #expect(storage.decrypt(fromOpenSSL).flatMap { String(data: $0, encoding: .utf8) } == "hunter2")
        #expect(ChromiumSafeStorage(secret: "another secret").decrypt(fromOpenSSL).flatMap { String(data: $0, encoding: .utf8) } != "hunter2")
        #expect(storage.decrypt(Data("plain".utf8)) == Data("plain".utf8), "a value from before encryption is as it was")
        #expect(storage.decrypt(Data("v10".utf8) + Data([1, 2, 3])) == nil, "not a whole block")
    }

    // MARK: Passwords

    struct Login {
        var origin: String
        var username = "someone"
        var password: Data
        var never = 0
        var created: Int64 = BrowserEpoch.chromiumMicros(unix: 1_700_000_000)
        var modified: Int64 = 0
        /// 0 a sign-in form, 1 a site's HTTP authentication prompt.
        var scheme: Int64 = 0
    }

    static func makeLoginData(at url: URL, _ logins: [Login]) throws {
        let db = try SQLiteDatabase(path: url.path)
        try db.execute("""
            CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
            INSERT INTO meta VALUES('version', '43'), ('last_compatible_version', '40');
            CREATE TABLE logins (origin_url VARCHAR NOT NULL, action_url VARCHAR, username_element VARCHAR, username_value VARCHAR,
              password_element VARCHAR, password_value BLOB, submit_element VARCHAR, signon_realm VARCHAR NOT NULL,
              date_created INTEGER NOT NULL, blacklisted_by_user INTEGER NOT NULL, scheme INTEGER NOT NULL, password_type INTEGER,
              times_used INTEGER, form_data BLOB, display_name VARCHAR, icon_url VARCHAR, federation_url VARCHAR,
              skip_zero_click INTEGER, generation_upload_status INTEGER, possible_username_pairs BLOB,
              id INTEGER PRIMARY KEY AUTOINCREMENT, date_last_used INTEGER NOT NULL DEFAULT 0, moving_blocked_for BLOB,
              date_password_modified INTEGER NOT NULL DEFAULT 0);
            """)
        for l in logins {
            try db.run("""
                INSERT INTO logins (origin_url, action_url, username_value, password_value, signon_realm, date_created,
                  blacklisted_by_user, scheme, date_password_modified) VALUES (?, '', ?, ?, ?, ?, ?, ?, ?)
                """, [.text(l.origin), .text(l.username), .blob(l.password), .text(l.origin), .int(l.created), .int(Int64(l.never)),
                      .int(l.scheme), .int(l.modified)])
        }
    }

    @Test func savedPasswordsAreReadOnceForEachSiteAndUser() throws {
        let dir = try BrowserTempDir("cosmos-secrets")
        defer { dir.remove() }
        let t = { (s: Int64) in BrowserEpoch.chromiumMicros(unix: s) }
        try Self.makeLoginData(at: dir.sub("Login Data"), [
            Login(origin: "https://example.com/login", password: Self.encrypt("old"), modified: t(1_700_000_100)),
            Login(origin: "https://Example.com/signin?x=1", password: Self.encrypt("new"), modified: t(1_700_000_900)),
            Login(origin: "https://example.com/", username: "other", password: Self.encrypt("theirs")),
            Login(origin: "http://intranet.test:8080/", username: "", password: Self.encrypt("pin")),
            Login(origin: "https://never.example/", username: "", password: Data(), never: 1),
            Login(origin: "https://router.example/", username: "admin", password: Self.encrypt("basic"), scheme: 1),
            Login(origin: "android://hash@com.example.app/", password: Self.encrypt("app")),
            Login(origin: "https://wrong-key.example/", password: Self.encrypt("x", key: Self.hex("00112233445566778899aabbccddeeff"))),
            Login(origin: "https://federated.example/", password: Data()),
        ])
        try Self.makeLoginData(at: dir.sub("Login Data For Account"), [Login(origin: "https://account.example/", password: Self.encrypt("acct"))])

        let read = try ChromiumSecrets.readLogins(profileDirectory: dir.url, storage: storage)
        let found = read.items.map { "\($0.origin) \($0.username) \($0.password)" }
        #expect(found == [
            "http://intranet.test:8080  pin",
            "https://account.example someone acct",
            "https://example.com other theirs",
            "https://example.com someone new",
        ])
        #expect(read.skipped == 4, "an app's entry, an HTTP authentication prompt's, one the key does not open, one with no password")
        #expect(read.neverSaved == ["https://never.example"], "a site the user said never to save for stays so")
        #expect(read.items.first { $0.password == "new" }?.created == browserDate(1_700_000_000))
        #expect(dir.names() == ["Login Data", "Login Data For Account"], "the databases are read from copies")
    }

    @Test func aProfileWithoutSavedPasswordsSaysSo() throws {
        let dir = try BrowserTempDir("cosmos-secrets")
        defer { dir.remove() }
        #expect(throws: BrowserImportError.fileNotFound(path: dir.sub("Login Data").path)) {
            try ChromiumSecrets.readLogins(profileDirectory: dir.url, storage: storage)
        }
    }

    // MARK: Cookies

    struct Cookie {
        var host = ".example.com"
        var name = "session"
        var value = ""
        var encrypted = Data()
        var path = "/"
        var expires: Int64 = BrowserEpoch.chromiumMicros(unix: 1_800_000_000)
        var persistent = 1
        var secure = 1
        var httpOnly = 1
        var sameSite = 1
        var partition = ""
    }

    static func makeCookies(at url: URL, version: Int = 24, _ cookies: [Cookie]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: url.path)
        try db.execute("""
            CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
            INSERT INTO meta VALUES('version', '\(version)'), ('last_compatible_version', '\(version)');
            CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL, name TEXT NOT NULL,
              value TEXT NOT NULL, encrypted_value BLOB NOT NULL, path TEXT NOT NULL, expires_utc INTEGER NOT NULL, is_secure INTEGER NOT NULL,
              is_httponly INTEGER NOT NULL, last_access_utc INTEGER NOT NULL, has_expires INTEGER NOT NULL, is_persistent INTEGER NOT NULL,
              priority INTEGER NOT NULL, samesite INTEGER NOT NULL, source_scheme INTEGER NOT NULL, source_port INTEGER NOT NULL,
              last_update_utc INTEGER NOT NULL, source_type INTEGER NOT NULL, has_cross_site_ancestor INTEGER NOT NULL);
            """)
        for c in cookies {
            try db.run("""
                INSERT INTO cookies VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, 1, ?, 2, 443, 0, 0, 0)
                """, [.int(BrowserEpoch.chromiumMicros(unix: 1_700_000_000)), .text(c.host), .text(c.partition), .text(c.name), .text(c.value),
                      .blob(c.encrypted), .text(c.path), .int(c.persistent == 1 ? c.expires : 0), .int(Int64(c.secure)), .int(Int64(c.httpOnly)),
                      .int(Int64(c.persistent)), .int(Int64(c.persistent)), .int(Int64(c.sameSite))])
        }
    }

    static func hashed(_ value: String, host: String) -> Data {
        encrypt(Data(SHA256.hash(data: Data(host.utf8))) + Data(value.utf8))
    }

    @Test func cookiesAreDecryptedAndCheckedAgainstTheirHost() throws {
        let dir = try BrowserTempDir("cosmos-secrets")
        defer { dir.remove() }
        // openssl enc of SHA-256(".example.com") followed by "cookie-value".
        let fromOpenSSL = Data("v10".utf8) + Data(Self.hex("85cd81e47253f2b0648f03c6426c8abb9be1789229d201c454d9e4561a0b9a7498f01778315aaab3c96d1964631d6074"))
        try Self.makeCookies(at: dir.sub("Network/Cookies"), [
            Cookie(encrypted: fromOpenSSL),
            Cookie(host: "www.example.org", name: "pref", encrypted: Self.hashed("dark", host: "www.example.org"), path: "/app",
                   secure: 0, httpOnly: 0, sameSite: -1),
            Cookie(host: "tab.example", name: "now", encrypted: Self.hashed("only-this-session", host: "tab.example"), persistent: 0, sameSite: 2),
            Cookie(host: "old.example", encrypted: Self.hashed("gone", host: "old.example"), expires: BrowserEpoch.chromiumMicros(unix: 1_600_000_000)),
            Cookie(host: "embedded.example", encrypted: Self.hashed("chips", host: "embedded.example"), partition: "https://top.example"),
            Cookie(host: "moved.example", encrypted: Self.hashed("elsewhere", host: "other.example")),
            Cookie(host: "plain.example", name: "legacy", value: "unencrypted"),
            Cookie(host: "garbled.example", encrypted: Self.encrypt("x", key: Self.hex("00112233445566778899aabbccddeeff"))),
        ])
        let read = try ChromiumSecrets.readCookies(profileDirectory: dir.url, storage: storage, now: now)
        let byHost = Dictionary(uniqueKeysWithValues: read.items.map { ($0.domain, $0) })
        #expect(Set(byHost.keys) == [".example.com", "www.example.org", "tab.example", "plain.example"], "the expired one is left out")
        #expect(read.skipped == 3, "partitioned, another host's value, and a value the key does not open")
        #expect(byHost[".example.com"] == ImportedCookie(domain: ".example.com", name: "session", value: "cookie-value", path: "/",
                                                         expires: browserDate(1_800_000_000), isSecure: true, isHTTPOnly: true,
                                                         sameSite: .lax))
        let org = try #require(byHost["www.example.org"])
        #expect(org.value == "dark" && org.path == "/app" && !org.isSecure && !org.isHTTPOnly && org.sameSite == .unspecified)
        let session = try #require(byHost["tab.example"])
        #expect(session.value == "only-this-session" && session.expires == nil && session.sameSite == .strict, "a session cookie has no end")
        #expect(byHost["plain.example"]?.value == "unencrypted")
    }

    @Test func cookiesFromBeforeVersion24HaveNoHostHash() throws {
        let dir = try BrowserTempDir("cosmos-secrets")
        defer { dir.remove() }
        try Self.makeCookies(at: dir.sub("Cookies"), version: 23, [Cookie(encrypted: Self.encrypt("plain-old"))])
        let read = try ChromiumSecrets.readCookies(profileDirectory: dir.url, storage: storage, now: now)
        #expect(read.items.map(\.value) == ["plain-old"])
        #expect(read.skipped == 0)
    }

    @Test func webOriginsAreSchemeHostAndPort() {
        #expect(ChromiumSecrets.webOrigin("https://Example.COM:443/a?b") == "https://example.com")
        #expect(ChromiumSecrets.webOrigin("http://example.com:8080/") == "http://example.com:8080")
        #expect(ChromiumSecrets.webOrigin("ftp://example.com/") == nil)
        #expect(ChromiumSecrets.webOrigin("android://abc@com.example/") == nil)
        #expect(ChromiumSecrets.webOrigin("not a url") == nil)
    }
}
