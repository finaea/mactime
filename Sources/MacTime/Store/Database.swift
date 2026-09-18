import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin sqlite3 wrapper. Single connection, main-thread use only.
final class Database {
    private(set) var handle: OpaquePointer?

    init(path: String) {
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            NSLog("MacTime: cannot open db at %@: %@", path, lastError)
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
    }

    deinit { close() }

    func close() {
        if let h = handle { sqlite3_close(h); handle = nil }
    }

    var lastError: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"
    }

    @discardableResult
    func exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            NSLog("MacTime: sql error: %@ in %@", err.map { String(cString: $0) } ?? "?", sql)
            sqlite3_free(err)
            return false
        }
        return true
    }

    /// Prepare, bind, run a statement; `row` is called once per result row.
    func run(_ sql: String, bind: [Any?] = [], row: ((OpaquePointer) -> Void)? = nil) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            NSLog("MacTime: prepare failed: %@ in %@", lastError, sql)
            return
        }
        defer { sqlite3_finalize(s) }
        for (i, v) in bind.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case nil: sqlite3_bind_null(s, idx)
            case let d as Double: sqlite3_bind_double(s, idx, d)
            case let n as Int64: sqlite3_bind_int64(s, idx, n)
            case let n as Int: sqlite3_bind_int64(s, idx, Int64(n))
            case let t as String: sqlite3_bind_text(s, idx, t, -1, SQLITE_TRANSIENT)
            // Sealed window titles and URLs. They go in as blobs rather than as
            // text because SQLite's own type tag is then the format marker:
            // rows written before encryption hold TEXT, sealed ones hold BLOB,
            // and no title a user could have can be mistaken for either. Binding
            // as text would also truncate at the first zero byte, which
            // ciphertext is full of.
            case let d as Data:
                _ = d.withUnsafeBytes { sqlite3_bind_blob(s, idx, $0.baseAddress, Int32(d.count), SQLITE_TRANSIENT) }
            default: sqlite3_bind_null(s, idx)
            }
        }
        while sqlite3_step(s) == SQLITE_ROW {
            row?(s)
        }
    }

    var lastInsertId: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Rows the last INSERT/UPDATE/DELETE touched — what the erase actions
    /// report back to the user.
    var changes: Int { Int(sqlite3_changes(handle)) }

    /// Schema generation, for migrations that can't be expressed as "does this
    /// column exist". Stored in the file header, so it costs no table.
    var userVersion: Int {
        get {
            var v = 0
            run("PRAGMA user_version;") { s in v = Int(Database.int64(s, 0)) }
            return v
        }
        set { exec("PRAGMA user_version = \(newValue);") }
    }

    // Column readers
    static func text(_ s: OpaquePointer, _ col: Int32) -> String? {
        sqlite3_column_text(s, col).map { String(cString: $0) }
    }
    static func double(_ s: OpaquePointer, _ col: Int32) -> Double {
        sqlite3_column_double(s, col)
    }
    static func int64(_ s: OpaquePointer, _ col: Int32) -> Int64 {
        sqlite3_column_int64(s, col)
    }
    /// What a column actually holds, for the two that carry either a sealed
    /// blob or the plaintext a row was written with before encryption. SQLite
    /// is dynamically typed, so its own tag separates them — and reading it
    /// here keeps `SQLITE_*` inside the one file that talks to sqlite3.
    enum Value {
        case null
        case blob(Data)
        case text(String)
    }

    static func value(_ s: OpaquePointer, _ col: Int32) -> Value {
        switch sqlite3_column_type(s, col) {
        case SQLITE_NULL:
            return .null
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(s, col) else { return .null }
            return .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, col))))
        default:
            return text(s, col).map(Value.text) ?? .null
        }
    }
}
