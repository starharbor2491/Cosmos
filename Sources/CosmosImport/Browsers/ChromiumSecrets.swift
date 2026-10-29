import CommonCrypto
import CryptoKit
import Foundation
import Security
import CosmosCore

/// A saved sign-in, as another browser keeps it.
public struct ImportedLogin: Hashable, Sendable {
    /// The site's origin: scheme, host and port ("https://example.com").
    public var origin: String
    public var username: String
    public var password: String
    public var created: Date?

    public init(origin: String, username: String, password: String, created: Date? = nil) {
        self.origin = origin; self.username = username; self.password = password; self.created = created
    }
}

/// A cookie, as another browser keeps it.
public struct ImportedCookie: Hashable, Sendable {
    /// Chromium's numbers for it.
    public enum SameSite: Int, Sendable { case unspecified = -1, none = 0, lax = 1, strict = 2 }

    /// Chromium's host key: "example.com" for a cookie only that host gets, ".example.com" for one its subdomains get too.
    public var domain: String
    public var name: String
    public var value: String
    public var path: String
    /// Nil for a cookie that ends with the browsing session.
    public var expires: Date?
    public var isSecure: Bool
    public var isHTTPOnly: Bool
    public var sameSite: SameSite

    public init(domain: String, name: String, value: String, path: String = "/", expires: Date? = nil, isSecure: Bool = false,
                isHTTPOnly: Bool = false, sameSite: SameSite = .unspecified) {
        self.domain = domain; self.name = name; self.value = value; self.path = path; self.expires = expires
        self.isSecure = isSecure; self.isHTTPOnly = isHTTPOnly; self.sameSite = sameSite
    }
}

/// How Chromium on macOS encrypts saved passwords and cookie values: "v10", then AES-128-CBC with an IV of sixteen
/// spaces, under a key made by PBKDF2-HMAC-SHA1 (salt "saltysalt", 1003 rounds) from the secret the browser keeps in its
/// "<Name> Safe Storage" Keychain item.
public struct ChromiumSafeStorage: Sendable {
    private static let prefix = Data("v10".utf8)
    private let key: [UInt8]

    public init(secret: String) {
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret, secret.utf8.count, salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        self.key = key
    }

    /// The value's bytes. A value without the prefix was stored unencrypted (older versions) and is returned as it is;
    /// nil when the key is not the one it was encrypted with, or the value is damaged.
    public func decrypt(_ value: Data) -> Data? {
        guard value.starts(with: Self.prefix) else { return value }
        let body = Data(value.dropFirst(Self.prefix.count))
        guard !body.isEmpty, body.count % kCCBlockSizeAES128 == 0 else { return nil }
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128)
        var moved = 0
        let status = body.withUnsafeBytes { b in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key, key.count, iv,
                    b.baseAddress, body.count, &out, out.count, &moved)
        }
        return status == kCCSuccess ? Data(out.prefix(moved)) : nil
    }

    /// The secret of the Keychain item `service` / `account` (Arc's: "Arc Safe Storage" / "Arc"). macOS asks the user
    /// before it hands it over; nil when there is no such item or the user said no.
    public static func keychainSecret(service: String, account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// The saved passwords (`Login Data`, and `Login Data For Account` where there is one) and cookies (`Cookies`, or
/// `Network/Cookies` in newer layouts) of a Chromium profile. Works from private copies of the databases.
public enum ChromiumSecrets {
    public struct Read<Item: Sendable>: Sendable {
        public var items: [Item]
        /// Rows that could not be used: a value the key does not open, a site that is not a web page, a cookie partitioned
        /// by the site it was set under (CHIPS), which Cosmos cannot give back to Chromium as such.
        public var skipped: Int
        /// The sites the user told the browser never to save a password for (from its logins only).
        public var neverSaved: [String] = []
    }

    public static let loginFiles = ["Login Data", "Login Data For Account"]

    public static func cookiesFile(in profileDirectory: URL) -> URL? {
        ["Network/Cookies", "Cookies"].map { profileDirectory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// One login per site and username: the most recently changed. Sites the user said never to save for have no
    /// password: they come back as `neverSaved`. Entries that are not for web pages, or are for a site's HTTP
    /// authentication prompt rather than its sign-in form, are left out.
    public static func readLogins(profileDirectory: URL, storage: ChromiumSafeStorage, workDirectory: URL? = nil) throws -> Read<ImportedLogin> {
        var newest: [String: (login: ImportedLogin, changed: Int64)] = [:]
        var never: Set<String> = []
        var skipped = 0
        let files = loginFiles.map { profileDirectory.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { throw BrowserImportError.fileNotFound(path: profileDirectory.appendingPathComponent(loginFiles[0]).path) }
        for file in files {
            try DatabaseSnapshot.withDatabase(copyOf: file, workDirectory: workDirectory) { db in
                guard try BrowserSQL.tableNames(db).contains("logins") else {
                    throw BrowserImportError.unreadable(path: file.path, reason: "no `logins` table")
                }
                let columns = try BrowserSQL.columnNames(of: "logins", in: db)
                let changed = columns.contains("date_password_modified") ? "MAX(date_created, date_password_modified)" : "date_created"
                // 0: a sign-in form; 1, 2, 3: an HTTP authentication prompt (basic, digest, other).
                let scheme = columns.contains("scheme") ? "scheme" : "0"
                let rows = try db.query("""
                    SELECT origin_url, username_value, password_value, blacklisted_by_user, date_created, \(changed), \(scheme) FROM logins
                    """)
                for r in rows {
                    if r[3].int64 == 1 {
                        if let origin = webOrigin(r[0].string) { never.insert(origin) }
                        continue
                    }
                    if r[6].int64 != 0 { skipped += 1; continue }
                    guard let origin = webOrigin(r[0].string), case .blob(let encrypted) = r[2], !encrypted.isEmpty,
                          let plain = storage.decrypt(encrypted), let password = String(data: plain, encoding: .utf8), !password.isEmpty else {
                        skipped += 1
                        continue
                    }
                    let username = r[1].string ?? ""
                    let created = r[4].int64.flatMap { $0 > 0 ? BrowserTimestamp.chromium(microseconds: $0) : nil }
                    let login = ImportedLogin(origin: origin, username: username, password: password, created: created)
                    let key = origin + "\n" + username
                    let when = r[5].int64 ?? 0
                    if let seen = newest[key], seen.changed >= when { continue }
                    newest[key] = (login, when)
                }
            }
        }
        let logins = newest.values.map(\.login).sorted { ($0.origin, $0.username) < ($1.origin, $1.username) }
        return Read(items: logins, skipped: skipped, neverSaved: never.sorted())
    }

    /// Cookies that have not expired by `now`. In databases from version 24 on, a decrypted value starts with the SHA-256
    /// of its host key, which is checked and removed.
    public static func readCookies(profileDirectory: URL, storage: ChromiumSafeStorage, now: Date = Date(),
                                   workDirectory: URL? = nil) throws -> Read<ImportedCookie> {
        guard let file = cookiesFile(in: profileDirectory) else {
            throw BrowserImportError.fileNotFound(path: profileDirectory.appendingPathComponent("Cookies").path)
        }
        return try DatabaseSnapshot.withDatabase(copyOf: file, workDirectory: workDirectory) { db in
            guard try BrowserSQL.tableNames(db).contains("cookies") else {
                throw BrowserImportError.unreadable(path: file.path, reason: "no `cookies` table")
            }
            let version = (try? db.query("SELECT value FROM meta WHERE key = 'version'"))?.first?.first?.string.flatMap { Int($0) } ?? 0
            let columns = try BrowserSQL.columnNames(of: "cookies", in: db)
            let partition = columns.contains("top_frame_site_key") ? "top_frame_site_key" : "''"
            let sameSite = columns.contains("samesite") ? "samesite" : "-1"
            let persistent = columns.contains("is_persistent") ? "is_persistent" : "has_expires"
            let rows = try db.query("""
                SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, \(sameSite), \(persistent),
                       \(partition) FROM cookies
                """)
            var cookies: [ImportedCookie] = []
            var skipped = 0
            for r in rows {
                guard let domain = r[0].string, !domain.isEmpty, let name = r[1].string else { skipped += 1; continue }
                if let key = r[10].string, !key.isEmpty { skipped += 1; continue }
                var expires: Date?
                if r[9].int64 == 1 {
                    guard let micros = r[5].int64, micros > 0 else { skipped += 1; continue }
                    let date = BrowserTimestamp.chromium(microseconds: micros)
                    guard date > now else { continue }
                    expires = date
                }
                var value = r[2].string ?? ""
                if case .blob(let encrypted) = r[3], !encrypted.isEmpty {
                    guard var plain = storage.decrypt(encrypted) else { skipped += 1; continue }
                    if version >= 24 {
                        let hash = Data(SHA256.hash(data: Data(domain.utf8)))
                        guard plain.starts(with: hash) else { skipped += 1; continue }
                        plain = Data(plain.dropFirst(hash.count))
                    }
                    guard let text = String(data: plain, encoding: .utf8) else { skipped += 1; continue }
                    value = text
                }
                cookies.append(ImportedCookie(domain: domain, name: name, value: value, path: r[4].string ?? "/", expires: expires,
                                              isSecure: r[6].int64 == 1, isHTTPOnly: r[7].int64 == 1,
                                              sameSite: ImportedCookie.SameSite(rawValue: Int(r[8].int64 ?? -1)) ?? .unspecified))
            }
            return Read(items: cookies, skipped: skipped)
        }
    }

    /// "https://example.com" for a web page's address; nil for anything else (Android apps' `android://` entries, ...).
    static func webOrigin(_ raw: String?) -> String? { SavedLogin.origin(raw) }
}

public extension ArcImporter {
    /// Arc's own Chromium profile (the default one), inside Arc's data folder.
    static func defaultChromiumProfile(in directory: URL) -> URL {
        directory.appendingPathComponent("User Data/Default", isDirectory: true)
    }

    /// Where Arc keeps the key to its saved passwords and cookies.
    /// The name of Arc's Keychain item, which Cosmos asks macOS for by name: an identifier to read Arc's data with, as the
    /// folder names the importers read are, not anything of Arc's that Cosmos carries.
    static let safeStorage = (service: "Arc Safe Storage", account: "Arc")
}
