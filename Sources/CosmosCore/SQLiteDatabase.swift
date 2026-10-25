import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let message: String
    public let code: Int32
    public var description: String { "SQLite error \(code): \(message)" }
}

/// A deliberately small SQLite wrapper (the system library, no dependency): enough for history and for the
/// Chromium importers, which read Arc's own `History` database read-only.
public final class SQLiteDatabase {
    private var db: OpaquePointer?
    public let path: String

    public enum Mode { case readWrite, readOnly }

    public init(path: String, mode: Mode = .readWrite) throws {
        self.path = path
        let flags = mode == .readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(db)
            throw SQLiteError(message: msg, code: rc)
        }
        sqlite3_busy_timeout(db, 3000)
    }

    deinit { sqlite3_close(db) }

    public enum Value {
        case null, int(Int64), double(Double), text(String), blob(Data)
        public var string: String? { if case .text(let s) = self { return s }; return nil }
        public var int64: Int64? {
            switch self { case .int(let i): return i; case .double(let d): return Int64(d); default: return nil }
        }
        public var double: Double? {
            switch self { case .double(let d): return d; case .int(let i): return Double(i); default: return nil }
        }
    }

    public typealias Row = [Value]

    private func fail(_ rc: Int32) -> SQLiteError {
        SQLiteError(message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed", code: rc)
    }

    public func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "error"
            sqlite3_free(err)
            throw SQLiteError(message: msg, code: rc)
        }
    }

    private func bind(_ stmt: OpaquePointer?, _ params: [Value]) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, transient)
            case .blob(let v): v.withUnsafeBytes { _ = sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), transient) }
            }
        }
    }

    /// Runs a statement that returns no rows.
    public func run(_ sql: String, _ params: [Value] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw fail(sqlite3_errcode(db)) }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw fail(rc) }
    }

    /// Runs a query and returns all rows.
    public func query(_ sql: String, _ params: [Value] = []) throws -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw fail(sqlite3_errcode(db)) }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        var rows: [Row] = []
        let cols = sqlite3_column_count(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw fail(rc) }
            var row: Row = []
            for c in 0..<cols {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(stmt, c)))
                case SQLITE_FLOAT: row.append(.double(sqlite3_column_double(stmt, c)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(stmt, c))))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    row.append(.blob(n > 0 ? Data(bytes: sqlite3_column_blob(stmt, c), count: n) : Data()))
                default: row.append(.null)
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") } catch { try? execute("ROLLBACK"); throw error }
    }
}
