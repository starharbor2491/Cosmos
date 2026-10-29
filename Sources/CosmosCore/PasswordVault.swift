import CryptoKit
import Foundation

/// A sign-in Cosmos keeps for a site.
public struct SavedLogin: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// The site's origin: scheme, host and port ("https://example.com").
    public var origin: String
    public var username: String
    public var password: String
    public var created: Date
    public var lastUsed: Date?

    public init(id: UUID = UUID(), origin: String, username: String, password: String, created: Date, lastUsed: Date? = nil) {
        self.id = id; self.origin = origin; self.username = username; self.password = password
        self.created = created; self.lastUsed = lastUsed
    }

    /// "https://example.com" for a web page's address or origin (scheme, host and a port that is not the scheme's own);
    /// nil for anything that is not a web page.
    public static func origin(_ raw: String?) -> String? {
        guard let raw, let c = URLComponents(string: raw), let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = c.host?.lowercased(), !host.isEmpty else { return nil }
        let port = c.port.flatMap { ($0 == 443 && scheme == "https") || ($0 == 80 && scheme == "http") ? nil : $0 }
        return "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
    }

    /// "example.com" (with the port when there is one), for lists.
    public var site: String { Self.site(of: origin) }

    public static func site(of origin: String) -> String {
        guard let c = URLComponents(string: origin), let host = c.host else { return origin }
        return c.port.map { "\(host):\($0)" } ?? host
    }
}

/// A sign-in printed, dumped or shown in a failed test says everything but its password.
extension SavedLogin: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "SavedLogin(\(origin), \(username), password: ••••)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["id": id, "origin": origin, "username": username, "password": "••••", "created": created,
                                "lastUsed": lastUsed as Any])
    }
}

/// Cosmos's saved passwords: one file, sealed with AES-GCM under a key kept elsewhere (the Keychain), so the file says
/// nothing without it, not even which sites it has passwords for. In memory when there is no file (a private window).
public final class PasswordVault {
    public enum Failure: Error, Equatable {
        /// The file is there but this key does not open it (another key, or a damaged file).
        case locked
        /// The file is there but could not be read (its permissions, the disk): nothing is known about what is in it.
        case unreadable
    }

    private struct Contents: Codable {
        var version = 1
        var logins: [SavedLogin] = []
        /// Sites the user asked never to be offered to save a password for.
        var neverSaved: [String] = []
    }

    public let file: URL?
    private let key: SymmetricKey
    private var contents = Contents()

    public var logins: [SavedLogin] { contents.logins }
    public var neverSaved: Set<String> { Set(contents.neverSaved) }

    /// Opens `file` (nil: nothing is written) with `key`; a file that is not there yet is an empty vault.
    public init(file: URL?, key: SymmetricKey) throws {
        self.file = file
        self.key = key
        guard let file else { return }
        let sealed: Data
        do { sealed = try Data(contentsOf: file) } catch CocoaError.fileReadNoSuchFile { return } catch { throw Failure.unreadable }
        guard let box = try? AES.GCM.SealedBox(combined: sealed), let plain = try? AES.GCM.open(box, using: key),
              let decoded = try? JSONDecoder.cosmos.decode(Contents.self, from: plain) else { throw Failure.locked }
        contents = decoded
    }

    /// The sign-ins for a page whose origin is `origin`, most recently used first.
    public func logins(for origin: String) -> [SavedLogin] {
        contents.logins.filter { $0.origin == origin }.sorted { ($0.lastUsed ?? $0.created) > ($1.lastUsed ?? $1.created) }
    }

    /// Whether saving this would change anything: a new sign-in, or a new password for one Cosmos has.
    public func wouldChange(origin: String, username: String, password: String) -> Bool {
        !contents.logins.contains { $0.origin == origin && $0.username == username && $0.password == password }
    }

    /// Keeps the sign-in, replacing the password of the one Cosmos has for that site and username.
    @discardableResult
    public func save(origin: String, username: String, password: String, now: Date = Date()) throws -> SavedLogin {
        let login: SavedLogin
        if let i = contents.logins.firstIndex(where: { $0.origin == origin && $0.username == username }) {
            contents.logins[i].password = password
            login = contents.logins[i]
        } else {
            login = SavedLogin(origin: origin, username: username, password: password, created: now)
            contents.logins.append(login)
        }
        contents.neverSaved.removeAll { $0 == origin }
        try write()
        return login
    }

    /// Sign-ins from another browser, and the sites it was told never to save for, in one write. One Cosmos already has
    /// for the same site and username keeps its password (it is the newer one, or the same). Returns how many were added.
    @discardableResult
    public func add(_ imported: [SavedLogin], neverSaved sites: [String] = []) throws -> Int {
        var added = 0
        for login in imported where !contents.logins.contains(where: { $0.origin == login.origin && $0.username == login.username }) {
            contents.logins.append(login)
            added += 1
        }
        let never = Set(contents.neverSaved)
        let newSites = Array(Set(sites).subtracting(never)).sorted()
        contents.neverSaved += newSites
        if added > 0 || !newSites.isEmpty { try write() }
        return added
    }

    public func remove(_ id: SavedLogin.ID) throws {
        contents.logins.removeAll { $0.id == id }
        try write()
    }

    public func markUsed(_ id: SavedLogin.ID, now: Date = Date()) throws {
        guard let i = contents.logins.firstIndex(where: { $0.id == id }) else { return }
        contents.logins[i].lastUsed = now
        try write()
    }

    public func neverSave(_ origin: String) throws {
        guard !contents.neverSaved.contains(origin) else { return }
        contents.neverSaved.append(origin)
        try write()
    }

    public func allowSaving(_ origin: String) throws {
        contents.neverSaved.removeAll { $0 == origin }
        try write()
    }

    private func write() throws {
        guard let file else { return }
        let sealed = try AES.GCM.seal(try JSONEncoder.cosmos.encode(contents), using: key)
        guard let data = sealed.combined else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
