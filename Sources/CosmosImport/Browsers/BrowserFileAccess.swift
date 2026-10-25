import Foundation
import SQLite3
import CosmosCore

enum BrowserFileAccess {
    enum State: Equatable { case readable, missing, denied }

    /// Whether we can open `url` for reading. macOS reports TCC-protected files (Safari's) as `EPERM`.
    static func state(of url: URL) -> State {
        let fd = open(url.path, O_RDONLY)
        if fd >= 0 { close(fd); return .readable }
        return (errno == EPERM || errno == EACCES) ? .denied : .missing
    }

    /// Like `state(of:)` for a directory, which we only need to `stat`.
    static func directoryState(of url: URL) -> State {
        var st = stat()
        if stat(url.path, &st) == 0 { return (st.st_mode & S_IFMT) == S_IFDIR ? .readable : .missing }
        return (errno == EPERM || errno == EACCES) ? .denied : .missing
    }

    static func requireReadable(_ url: URL) throws {
        switch state(of: url) {
        case .readable: return
        case .missing: throw BrowserImportError.fileNotFound(path: url.path)
        case .denied: throw BrowserImportError.permissionDenied(path: url.path)
        }
    }

    static func readData(_ url: URL) throws -> Data {
        try requireReadable(url)
        do { return try Data(contentsOf: url) } catch { throw map(error, path: url.path) }
    }

    static func map(_ error: Error, path: String) -> BrowserImportError {
        if let e = error as? BrowserImportError { return e }
        let ns = error as NSError
        let underlying = (ns.userInfo[NSUnderlyingErrorKey] as? NSError)
        let posix = ns.domain == NSPOSIXErrorDomain ? Int32(ns.code) : Int32(underlying?.code ?? 0)
        let cocoa = ns.domain == NSCocoaErrorDomain
        if (cocoa && ns.code == NSFileReadNoPermissionError) || posix == EPERM || posix == EACCES { return .permissionDenied(path: path) }
        if (cocoa && (ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError)) || posix == ENOENT { return .fileNotFound(path: path) }
        return .unreadable(path: path, reason: ns.localizedDescription)
    }
}

/// Reads a browser's SQLite file without ever touching the original.
///
/// The browser may be running and holding locks (Arc keeps its `History` open with exclusive locking), and opening
/// a database, even read-only, can create `-shm`/`-wal` files beside it. So the file and its `-wal`/`-journal`
/// siblings are copied (an APFS clone, so it's quick and a point-in-time snapshot of each file) into a private
/// temporary directory, the copy is opened, and the directory is deleted afterwards. The `-shm` index is not copied:
/// it is derived from the WAL, and SQLite rebuilds it, whereas a stale copy could disagree with the copied WAL.
enum DatabaseSnapshot {
    private static let sidecars = ["-wal", "-journal"]
    private static let attempts = 3

    static func withDatabase<T>(copyOf source: URL, workDirectory: URL? = nil, _ body: (SQLiteDatabase) throws -> T) throws -> T {
        try BrowserFileAccess.requireReadable(source)
        let fm = FileManager.default
        let parent = workDirectory ?? fm.temporaryDirectory
        let dir = parent.appendingPathComponent("cosmos-import-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw BrowserImportError.unreadable(path: parent.path, reason: "cannot create a temporary directory (\(error.localizedDescription))")
        }
        defer { try? fm.removeItem(at: dir) }

        let copy = dir.appendingPathComponent(source.lastPathComponent)
        try copyConsistently(source, to: copy)
        do {
            let db = try openCopy(copy)
            return try body(db)
        } catch let e as SQLiteError {
            throw BrowserImportError.unreadable(path: source.path, reason: e.message)
        }
    }

    /// Opens read-only. If the browser was mid-transaction a rollback journal is "hot" and SQLite can't open it
    /// read-only; the private copy is then opened read-write so SQLite rolls it back to the last committed state.
    private static func openCopy(_ copy: URL) throws -> SQLiteDatabase {
        do {
            let db = try SQLiteDatabase(path: copy.path, mode: .readOnly)
            _ = try db.query("SELECT COUNT(*) FROM sqlite_master")
            return db
        } catch let e as SQLiteError where e.code & 0xFF == SQLITE_READONLY || e.code & 0xFF == SQLITE_CANTOPEN {
            let db = try SQLiteDatabase(path: copy.path, mode: .readWrite)
            _ = try db.query("SELECT COUNT(*) FROM sqlite_master")
            return db
        }
    }

    /// Copies the database and its siblings, retrying when the browser wrote to them while we copied.
    private static func copyConsistently(_ source: URL, to copy: URL) throws {
        let fm = FileManager.default
        for attempt in 1...attempts {
            let before = fingerprint(source)
            for suffix in sidecars {
                try? fm.removeItem(atPath: copy.path + suffix)
                let from = source.path + suffix
                guard fm.fileExists(atPath: from) else { continue }
                do { try fm.copyItem(atPath: from, toPath: copy.path + suffix) }
                catch {
                    // A journal can disappear between the check and the copy: that just means the transaction finished.
                    if case .fileNotFound = BrowserFileAccess.map(error, path: from) { continue }
                    throw BrowserFileAccess.map(error, path: from)
                }
            }
            try? fm.removeItem(at: copy)
            do { try fm.copyItem(at: source, to: copy) } catch { throw BrowserFileAccess.map(error, path: source.path) }
            if fingerprint(source) == before || attempt == attempts { return }
        }
    }

    private struct Fingerprint: Equatable { var size: UInt64; var modified: Date? }

    private static func fingerprint(_ source: URL) -> [Fingerprint?] {
        ([""] + sidecars).map { suffix in
            guard let a = try? FileManager.default.attributesOfItem(atPath: source.path + suffix) else { return nil }
            return Fingerprint(size: (a[.size] as? UInt64) ?? 0, modified: a[.modificationDate] as? Date)
        }
    }
}

/// Small SQLite helpers shared by the importers.
enum BrowserSQL {
    /// Runs `sql` in pages of `pageSize` rows. The statement must select the paging key as column 0, filter on
    /// `?1` (rows after the last key seen), `ORDER BY` that key and `LIMIT ?2`; its own parameters start at `?3`.
    static func forEachPage(_ db: SQLiteDatabase, _ sql: String, params: [SQLiteDatabase.Value] = [], pageSize: Int = 5_000,
                            _ body: ([SQLiteDatabase.Row]) throws -> Void) throws {
        var after: Int64 = 0
        while true {
            let rows = try db.query(sql, [.int(after), .int(Int64(pageSize))] + params)
            guard let last = rows.last?.first?.int64 else { return }
            try body(rows)
            if rows.count < pageSize { return }
            after = last
        }
    }

    static func tableNames(_ db: SQLiteDatabase) throws -> Set<String> {
        Set(try db.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0.first?.string })
    }

    static func columnNames(of table: String, in db: SQLiteDatabase) throws -> Set<String> {
        Set(try db.query("PRAGMA table_info(\(table))").compactMap { $0.count > 1 ? $0[1].string : nil })
    }

    static func scalarInt(_ db: SQLiteDatabase, _ sql: String, _ params: [SQLiteDatabase.Value] = []) throws -> Int {
        Int(try db.query(sql, params).first?.first?.int64 ?? 0)
    }
}
