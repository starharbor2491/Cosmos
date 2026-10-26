import Foundation

public extension JSONEncoder {
    /// Pretty, key-sorted, ISO-8601: diffable files that survive hand editing.
    static var cosmos: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

public extension JSONDecoder {
    static var cosmos: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Atomic JSON persistence for one Codable value, with timestamped rotating backups.
///
/// Arc keeps `Storable<Name>.<timestamp>.json` copies next to each file so "Restore Data" can roll back; Cosmos
/// does the same in a `Backups/` folder: at most one backup per `backupInterval`, newest `keepBackups` kept (`0` keeps none,
/// for a file that is only a cache of what could be learned again).
public final class JSONFileStore<Value: Codable> {
    public let url: URL
    public let backupDirectory: URL
    public var backupInterval: TimeInterval
    public var keepBackups: Int
    private let fm = FileManager.default
    private let name: String

    public init(url: URL, backupInterval: TimeInterval = 15 * 60, keepBackups: Int = 40) {
        self.url = url
        self.name = url.deletingPathExtension().lastPathComponent
        self.backupDirectory = url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        self.backupInterval = backupInterval
        self.keepBackups = keepBackups
    }

    /// `nil` when the file does not exist; throws when it exists but cannot be decoded.
    public func load() throws -> Value? {
        guard fm.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder.cosmos.decode(Value.self, from: Data(contentsOf: url))
    }

    public func save(_ value: Value, now: Date = Date()) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        backupIfDue(now: now)
        let data = try JSONEncoder.cosmos.encode(value)
        try data.write(to: url, options: .atomic)
    }

    // MARK: Backups

    private static var stamp: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd-HH-mm-ss-SSS"
        return f
    }

    public func backups() -> [URL] {
        let all = (try? fm.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.lastPathComponent.hasPrefix(name + ".") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func backupIfDue(now: Date) {
        guard keepBackups > 0, fm.fileExists(atPath: url.path) else { return }
        if let newest = backups().first,
           let attrs = try? fm.attributesOfItem(atPath: newest.path), let made = attrs[.modificationDate] as? Date,
           now.timeIntervalSince(made) < backupInterval { return }
        try? fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let dest = backupDirectory.appendingPathComponent("\(name).\(Self.stamp.string(from: now)).json")
        try? fm.copyItem(at: url, to: dest)
        for old in backups().dropFirst(keepBackups) { try? fm.removeItem(at: old) }
    }

    /// Writes the value now without keeping a copy of what it replaces, and deletes the copies there are. For a file from which
    /// something was just forgotten: the dated copies would otherwise still hold it.
    public func rewriteDiscardingBackups(_ value: Value) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.cosmos.encode(value).write(to: url, options: .atomic)
        deleteBackups()
    }

    public func deleteBackups() {
        for old in backups() { try? fm.removeItem(at: old) }
    }

    /// Restores the newest backup that decodes; returns its value.
    public func restoreLatestBackup() throws -> Value? {
        for b in backups() {
            if let v = try? JSONDecoder.cosmos.decode(Value.self, from: Data(contentsOf: b)) {
                try save(v)
                return v
            }
        }
        return nil
    }
}

/// Where Cosmos keeps its files. `COSMOS_DATA_DIR` overrides it (tests, demos, side-by-side installs).
public enum CosmosPaths {
    public static var dataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["COSMOS_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Cosmos", isDirectory: true)
    }

    public static func file(_ name: String) -> URL { dataDirectory.appendingPathComponent(name) }
}
