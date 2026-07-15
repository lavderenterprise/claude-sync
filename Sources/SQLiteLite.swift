import Foundation
import SQLite3

// Minimal zero-dependency wrapper over the system libsqlite3. Used read-only to list
// Codex threads and read-write (M3) to upsert imported ones. Never touches -wal/-shm
// or journal_mode: ChatGPT.app owns that database; we are a polite guest.

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct SQLiteError: Error {
    let message: String
    let code: Int32
}

enum SQLiteValue {
    case text(String), int(Int64), real(Double), null

    var asString: String? { if case .text(let s) = self { return s }; return nil }
    var asInt: Int64? {
        switch self {
        case .int(let i): i
        case .real(let d): Int64(d)
        default: nil
        }
    }
}

final class SQLiteDB {
    private var db: OpaquePointer?

    init(path: String, readOnly: Bool) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let handle = db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close(db)
            throw SQLiteError(message: msg, code: rc)
        }
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit { sqlite3_close(db) }

    func query(_ sql: String, _ binds: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw lastError()
        }
        defer { sqlite3_finalize(s) }
        try bind(s, binds)

        var rows: [[String: SQLiteValue]] = []
        while true {
            let rc = step(s)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError() }
            var row: [String: SQLiteValue] = [:]
            for i in 0..<sqlite3_column_count(s) {
                let name = String(cString: sqlite3_column_name(s, i))
                row[name] = switch sqlite3_column_type(s, i) {
                case SQLITE_INTEGER: .int(sqlite3_column_int64(s, i))
                case SQLITE_FLOAT: .real(sqlite3_column_double(s, i))
                case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(s, i)))
                default: .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    func run(_ sql: String, _ binds: [SQLiteValue] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw lastError()
        }
        defer { sqlite3_finalize(s) }
        try bind(s, binds)
        guard step(s) == SQLITE_DONE else { throw lastError() }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE")
        do {
            let out = try body()
            try run("COMMIT")
            return out
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    private func bind(_ s: OpaquePointer, _ binds: [SQLiteValue]) throws {
        for (i, v) in binds.enumerated() {
            let idx = Int32(i + 1)
            let rc = switch v {
            case .text(let t): sqlite3_bind_text(s, idx, t, -1, SQLITE_TRANSIENT)
            case .int(let n): sqlite3_bind_int64(s, idx, n)
            case .real(let d): sqlite3_bind_double(s, idx, d)
            case .null: sqlite3_bind_null(s, idx)
            }
            guard rc == SQLITE_OK else { throw lastError() }
        }
    }

    /// step with retry: ChatGPT.app holds this DB open; brief BUSY under WAL is normal.
    private func step(_ s: OpaquePointer) -> Int32 {
        for attempt in 0..<4 {
            let rc = sqlite3_step(s)
            if rc != SQLITE_BUSY && rc != SQLITE_LOCKED { return rc }
            if attempt < 3 {
                usleep(250_000)
                sqlite3_reset(s)
            }
        }
        return sqlite3_step(s)
    }

    private func lastError() -> SQLiteError {
        SQLiteError(message: db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown",
                    code: db.flatMap { sqlite3_errcode($0) } ?? -1)
    }
}

/// The only safe way to copy a live WAL database another process holds open.
func sqliteOnlineBackup(from src: String, to dst: String) throws {
    var srcDB: OpaquePointer?
    var dstDB: OpaquePointer?
    defer { sqlite3_close(srcDB); sqlite3_close(dstDB) }
    guard sqlite3_open_v2(src, &srcDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        throw SQLiteError(message: "cannot open source for backup: \(src)", code: -1)
    }
    guard sqlite3_open_v2(dst, &dstDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
        throw SQLiteError(message: "cannot create backup target: \(dst)", code: -1)
    }
    guard let b = sqlite3_backup_init(dstDB, "main", srcDB, "main") else {
        throw SQLiteError(message: String(cString: sqlite3_errmsg(dstDB)), code: -1)
    }
    // Canonical live-backup loop: copy in small batches, yielding on BUSY/LOCKED while
    // the owning process (ChatGPT.app) writes. Bounded by a deadline, not attempts.
    let deadline = Date().addingTimeInterval(15)
    var rc: Int32
    repeat {
        rc = sqlite3_backup_step(b, 128)
        if rc == SQLITE_BUSY || rc == SQLITE_LOCKED { sqlite3_sleep(250) }
    } while (rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED)
        && Date() < deadline
    let frc = sqlite3_backup_finish(b)
    guard rc == SQLITE_DONE, frc == SQLITE_OK else {
        let detail = String(cString: sqlite3_errmsg(dstDB))
        throw SQLiteError(message: "backup incomplete (step=\(rc), finish=\(frc): \(detail))",
                          code: rc == SQLITE_DONE ? frc : rc)
    }
}
