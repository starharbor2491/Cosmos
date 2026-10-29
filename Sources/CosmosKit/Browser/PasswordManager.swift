import CryptoKit
import Foundation
import Observation
import Security
import CosmosCore

/// Cosmos's password manager: the saved sign-ins (a `PasswordVault` whose key the Keychain keeps), what pages are
/// offered to save, and what is filled into them. The vault is opened, and the Keychain asked for its key, only when
/// there is a reason: a page shows a sign-in form while there is a vault, a sign-in is sent, or the user opens their
/// passwords. A person who never saves one is not asked until they sign in somewhere. Nothing that draws opens it.
@MainActor @Observable
public final class PasswordManager {
    /// The vault's sign-ins, for lists.
    public private(set) var logins: [SavedLogin] = []
    public private(set) var neverSaved: [String] = []
    /// What went wrong opening the vault or saving into it, for Settings to say.
    public private(set) var problem: String?

    @ObservationIgnored private var vault: PasswordVault?
    /// Opening failed (the Keychain said no, the file couldn't be read): pages don't make Cosmos try, and ask, again; the
    /// user opening their passwords does.
    @ObservationIgnored private var failed = false
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private let key: () throws -> SymmetricKey
    /// The sign-ins a page sent that the user was already asked about, so a form sent twice asks once.
    @ObservationIgnored private var asked: Set<String> = []

    /// `file` nil keeps everything in memory.
    public init(file: URL?, key: @escaping () throws -> SymmetricKey = PasswordManager.keychainKey) {
        self.file = file
        self.key = key
    }

    /// The vault, opened now if it is not yet; after a failure only when `retry` (the user asked). A file this key does
    /// not open is put aside, not written over, in case the key that opens it comes back; one that can't be read is left
    /// alone, and nothing is saved until it can be.
    private func open(retry: Bool) -> PasswordVault? {
        if let vault { return vault }
        guard retry || !failed else { return nil }
        failed = true
        let key: SymmetricKey
        do { key = try self.key() } catch {
            problem = "Cosmos couldn't get the key to its saved passwords from your Keychain."
            return nil
        }
        do {
            vault = try PasswordVault(file: file, key: key)
            problem = nil
        } catch PasswordVault.Failure.unreadable {
            problem = "Cosmos couldn't read the file of its saved passwords."
            return nil
        } catch {
            if let file {
                let aside = file.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).vault")
                try? FileManager.default.moveItem(at: file, to: aside)
            }
            vault = try? PasswordVault(file: file, key: key)
            problem = "Cosmos couldn't open its saved passwords with the key in your Keychain. It kept the old file and started a new list."
        }
        failed = vault == nil
        refresh()
        return vault
    }

    private func refresh() {
        logins = (vault?.logins ?? []).sorted { ($0.site, $0.username) < ($1.site, $1.username) }
        neverSaved = (vault?.neverSaved ?? []).sorted()
    }

    /// Runs a change to the vault, and says so when it could not be kept.
    @discardableResult
    private func change<T>(_ body: (PasswordVault) throws -> T) -> T? {
        guard let vault = open(retry: true) else { return nil }
        defer { refresh() }
        do { return try body(vault) } catch {
            problem = "Cosmos couldn't save the change to its passwords."
            return nil
        }
    }

    /// Opens the vault for the user, who asked to see their passwords: after a failure, this tries again.
    public func load() { _ = open(retry: true) }

    /// A page showed a sign-in form: opens the vault, if there is one, so that its sign-ins for the page can be offered.
    public func prepare() {
        if let file, !FileManager.default.fileExists(atPath: file.path) { return }
        _ = open(retry: false)
    }

    /// The sign-ins for `origin`, most recently used first, if the vault is open; this never opens it (views ask as they
    /// draw, and redraw when it opens).
    public func logins(for origin: String) -> [SavedLogin] {
        logins.filter { $0.origin == origin }.sorted { ($0.lastUsed ?? $0.created) > ($1.lastUsed ?? $1.created) }
    }

    /// Whether to ask about saving what was sent to `origin`: it is new, or a new password, the user has not said never
    /// for the site, and has not been asked about this one already. Asking counts as asked.
    public func shouldOffer(origin: String, username: String, password: String) -> Bool {
        guard !password.isEmpty, let vault = open(retry: false), !vault.neverSaved.contains(origin),
              vault.wouldChange(origin: origin, username: username, password: password) else { return false }
        return asked.insert(origin + "\n" + username + "\n" + password).inserted
    }

    public func save(origin: String, username: String, password: String) {
        _ = change { try $0.save(origin: origin, username: username, password: password) }
    }

    public func neverSave(_ origin: String) { change { try $0.neverSave(origin) } }

    public func allowSaving(_ origin: String) { change { try $0.allowSaving(origin) } }

    public func remove(_ id: SavedLogin.ID) { change { try $0.remove(id) } }

    public func markUsed(_ id: SavedLogin.ID) { change { try $0.markUsed(id) } }

    /// Sign-ins from another browser, and the sites it was told never to save for; returns how many sign-ins were new.
    @discardableResult
    public func add(_ imported: [SavedLogin], neverSaved sites: [String] = []) -> Int {
        change { try $0.add(imported, neverSaved: sites) } ?? 0
    }

    // MARK: The key

    /// Not "<name> Safe Storage", which is what Chromium-based browsers call the key to their own data.
    nonisolated static let keychainService = "Cosmos Password Vault"
    nonisolated static let keychainAccount = "Cosmos"

    /// The vault's key, from the Keychain; made and kept there the first time.
    nonisolated public static func keychainKey() throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: keychainAccount, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        let key = SymmetricKey(size: .bits256)
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                  kSecAttrAccount as String: keychainAccount, kSecAttrLabel as String: keychainService,
                                  kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                  kSecValueData as String: key.withUnsafeBytes { Data($0) }]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
        return key
    }

    struct KeychainError: Error, Sendable { let status: OSStatus }
}
