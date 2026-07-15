import Foundation
import AppKit

// MARK: - Codex side: paths, thread enumeration, rollout streaming

enum CodexPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
    static let sessionsDir = home.appending(path: "sessions")
    static let stateDB = home.appending(path: "state_5.sqlite")
    static let sessionIndex = home.appending(path: "session_index.jsonl")

    /// The _sqlx_migrations version this app's writes were validated against.
    /// A different live value downgrades Codex writes to read-only (schema drift).
    static let validatedSchemaVersion = 40

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: home.path)
    }
}

struct CodexThreadInfo {
    let id: String
    let rolloutPath: String
    let title: String
    let cwd: String
    let model: String
    let createdAtMs: Int
    let updatedAtMs: Int
    let archived: Bool
    let rolloutSize: Int64
}

/// One rollout line: {timestamp, type, payload}.
struct RolloutLine {
    let timestamp: String
    let type: String
    let payload: [String: Any]

    var payloadType: String? { payload["type"] as? String }
}

enum CodexIO {
    /// Preferred source: the threads table (what the desktop app lists). Falls back to
    /// scanning rollout files when the DB is missing or unreadable — the CLI proves
    /// rollouts alone are resolvable (M1 probe resumed one with no DB at all).
    static func enumerateThreads() -> [CodexThreadInfo] {
        let fromDB = threadsFromDB()
        if !fromDB.isEmpty { return fromDB }
        return threadsFromFilesystem()
    }

    static func schemaVersion() -> Int? {
        guard let db = try? SQLiteDB(path: CodexPaths.stateDB.path, readOnly: true),
              let rows = try? db.query("SELECT MAX(version) AS v FROM _sqlx_migrations"),
              let v = rows.first?["v"]?.asInt else { return nil }
        return Int(v)
    }

    static func codexIsRunning() -> Bool {
        !NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.openai.codex" || $0.localizedName == "ChatGPT"
        }.isEmpty
    }

    private static func threadsFromDB() -> [CodexThreadInfo] {
        guard let db = try? SQLiteDB(path: CodexPaths.stateDB.path, readOnly: true),
              let rows = try? db.query("""
                  SELECT id, rollout_path, title, cwd, model, created_at_ms, updated_at_ms,
                         archived, first_user_message
                  FROM threads
                  """) else { return [] }
        let fm = FileManager.default
        return rows.compactMap { row in
            guard let id = row["id"]?.asString,
                  let rollout = row["rollout_path"]?.asString else { return nil }
            let size = (try? fm.attributesOfItem(atPath: rollout))?[.size] as? Int64 ?? 0
            let title = row["title"]?.asString
                ?? row["first_user_message"]?.asString.map { String($0.prefix(60)) }
                ?? "(untitled)"
            return CodexThreadInfo(
                id: id,
                rolloutPath: rollout,
                title: title,
                cwd: row["cwd"]?.asString ?? "—",
                model: row["model"]?.asString ?? "codex-import",
                createdAtMs: Int(row["created_at_ms"]?.asInt ?? 0),
                updatedAtMs: Int(row["updated_at_ms"]?.asInt ?? 0),
                archived: (row["archived"]?.asInt ?? 0) != 0,
                rolloutSize: size)
        }
    }

    private static func threadsFromFilesystem() -> [CodexThreadInfo] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: CodexPaths.sessionsDir,
                                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return [] }
        var out: [CodexThreadInfo] = []
        for case let url as URL in e where url.lastPathComponent.hasPrefix("rollout-")
                                        && url.pathExtension == "jsonl" {
            var meta: [String: Any]?
            _ = try? streamJSONL(path: url.path, from: 0) { dict in
                if meta == nil, (dict["type"] as? String) == "session_meta" {
                    meta = dict["payload"] as? [String: Any]
                }
            }
            guard let m = meta, let id = m["id"] as? String else { continue }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970 * 1000) } ?? 0
            out.append(CodexThreadInfo(
                id: id,
                rolloutPath: url.path,
                title: "(untitled)",
                cwd: (m["cwd"] as? String) ?? "—",
                model: "codex-import",
                createdAtMs: mtime,
                updatedAtMs: mtime,
                archived: false,
                rolloutSize: (attrs?[.size] as? Int64) ?? 0))
        }
        return out
    }

    @discardableResult
    static func streamLines(path: String, from offset: Int64 = 0,
                            _ body: (RolloutLine) -> Void) throws -> Int64 {
        try streamJSONL(path: path, from: offset) { dict in
            body(RolloutLine(timestamp: (dict["timestamp"] as? String) ?? "",
                             type: (dict["type"] as? String) ?? "unknown",
                             payload: (dict["payload"] as? [String: Any]) ?? [:]))
        }
    }
}

// MARK: - Templates: new rollouts clone the shape of a real one

struct CodexTemplates {
    let meta: [String: Any]           // session_meta payload (base_instructions included —
                                      // the M1 probe validated resume with them present)

    /// From the newest rollout that carries a session_meta (they all should; imported
    /// ones included). Nil only when Codex has no sessions at all.
    static func load() -> CodexTemplates? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: CodexPaths.sessionsDir, includingPropertiesForKeys: nil)
        else { return nil }
        var rollouts: [(URL, Date)] = []
        for case let url as URL in e where url.lastPathComponent.hasPrefix("rollout-")
                                        && url.pathExtension == "jsonl" {
            let m = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
            rollouts.append((url, m))
        }
        for (url, _) in rollouts.sorted(by: { $0.1 > $1.1 }) {
            var meta: [String: Any]?
            _ = try? CodexIO.streamLines(path: url.path) { line in
                if meta == nil, line.type == "session_meta" { meta = line.payload }
            }
            if let m = meta { return CodexTemplates(meta: m) }
        }
        return nil
    }
}

// MARK: - Codex writers

enum CodexWriter {

    /// sessions/YYYY/MM/DD/rollout-<local ts>-<id>.jsonl — the native path convention
    /// (directory partition and filename timestamp are LOCAL time; meta timestamp is UTC).
    static func rolloutPath(threadId: String, createdAtMs: Int) -> URL {
        let date = Date(timeIntervalSince1970: Double(createdAtMs) / 1000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd"
        let dir = CodexPaths.sessionsDir.appending(path: f.string(from: date))
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return dir.appending(path: "rollout-\(f.string(from: date))-\(threadId).jsonl")
    }

    /// Streams a complete new rollout to tmp + fsync + rename — never a partial file.
    static func createRollout(at url: URL,
                              feed: ((@escaping ([[String: Any]]) throws -> Void)) throws -> Void)
        throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appending(path: ".tmp-" + url.lastPathComponent)
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let fh = try FileHandle(forWritingTo: tmp)
        do {
            try feed { lines in
                try fh.write(contentsOf: serializeJSONL(lines))
            }
            try fh.synchronize()
            try fh.close()
        } catch {
            try? fh.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp,
                                                  backupItemName: nil, options: [])
    }

    static func appendRollout(path: String, lines: [[String: Any]]) throws -> (Int64, Int64) {
        try appendJSONL(path: path, data: serializeJSONL(lines))
    }

    /// Idempotent thread upsert by cloning a template row: every NOT NULL/typed column
    /// is satisfied with a value the schema demonstrably accepts, and only identity +
    /// content fields are replaced.
    static func upsertThread(id: String, rolloutPath: String, cwd: String, title: String,
                             firstUserMessage: String, createdAtMs: Int, updatedAtMs: Int)
        throws {
        let db = try SQLiteDB(path: CodexPaths.stateDB.path, readOnly: false)
        guard let template = try db.query("SELECT * FROM threads LIMIT 1").first else {
            throw SQLiteError(message: "threads table is empty — no template row to clone", code: -1)
        }

        var row = template
        func setText(_ k: String, _ v: String) { if row.keys.contains(k) { row[k] = .text(v) } }
        func setInt(_ k: String, _ v: Int64) { if row.keys.contains(k) { row[k] = .int(v) } }
        /// Time columns mimic the template's storage type (int seconds vs ISO text).
        func setTime(_ k: String, ms: Int) {
            guard let cur = row[k] else { return }
            switch cur {
            case .int: row[k] = .int(Int64(ms / 1000))
            case .text:
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                row[k] = .text(f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)))
            default: break
            }
        }

        setText("id", id)
        setText("rollout_path", rolloutPath)
        setText("cwd", cwd)
        setText("title", title)
        setText("first_user_message", firstUserMessage)
        setText("preview", String(firstUserMessage.prefix(200)))
        setTime("created_at", ms: createdAtMs)
        setTime("updated_at", ms: updatedAtMs)
        setTime("recency_at", ms: updatedAtMs)
        setInt("created_at_ms", Int64(createdAtMs))
        setInt("updated_at_ms", Int64(updatedAtMs))
        setInt("recency_at_ms", Int64(updatedAtMs))
        setInt("tokens_used", 0)
        setInt("has_user_event", 1)
        setInt("archived", 0)
        if row.keys.contains("archived_at") { row["archived_at"] = .null }

        let cols = row.keys.sorted()
        let placeholders = cols.map { _ in "?" }.joined(separator: ",")
        let updates = ["updated_at", "updated_at_ms", "recency_at", "recency_at_ms",
                       "title", "preview", "rollout_path"]
            .filter { cols.contains($0) }
            .map { "\($0)=excluded.\($0)" }.joined(separator: ",")
        let sql = """
            INSERT INTO threads (\(cols.joined(separator: ","))) VALUES (\(placeholders))
            ON CONFLICT(id) DO UPDATE SET \(updates)
            """
        try db.transaction {
            try db.run(sql, cols.map { row[$0] ?? .null })
        }
    }

    /// Bumps activity columns for an existing thread after appending turns.
    static func touchThread(id: String, updatedAtMs: Int) throws {
        let db = try SQLiteDB(path: CodexPaths.stateDB.path, readOnly: false)
        try db.run("""
            UPDATE threads SET updated_at_ms=?, recency_at_ms=? WHERE id=?
            """, [.int(Int64(updatedAtMs)), .int(Int64(updatedAtMs)), .text(id)])
    }

    /// The ChatGPT UI's "organize by project" groups threads via a thread→folder hint
    /// map in its Electron state, NOT via the threads.cwd column — unhinted threads all
    /// collapse into one bucket. Top up missing hints for every known thread. Skipped
    /// while ChatGPT runs (it persists its in-memory state on quit, clobbering ours).
    static func topUpWorkspaceHints() {
        guard !CodexIO.codexIsRunning() else { return }
        let gs = CodexPaths.home.appending(path: ".codex-global-state.json")
        guard var d = readJSON(gs) else { return }
        var hints = (d["thread-workspace-root-hints"] as? [String: String]) ?? [:]
        let before = hints.count
        for t in CodexIO.enumerateThreads() where hints[t.id] == nil && t.cwd != "—" {
            hints[t.id] = t.cwd
        }
        guard hints.count > before,
              let data = try? JSONSerialization.data(withJSONObject:
                  { var c = d; c["thread-workspace-root-hints"] = hints; return c }()) else { return }
        try? data.write(to: gs, options: .atomic)
    }

    /// Dedup append to the auxiliary session_index.jsonl.
    static func appendSessionIndex(id: String, name: String) throws {
        let path = CodexPaths.sessionIndex.path
        var seen = Set<String>()
        if FileManager.default.fileExists(atPath: path) {
            _ = try? streamJSONL(path: path, from: 0) { dict in
                if let i = dict["id"] as? String { seen.insert(i) }
            }
            guard !seen.contains(id) else { return }
        }
        let line: [String: Any] = ["id": id, "thread_name": name, "updated_at": isoNow()]
        let data = serializeJSONL([line])
        if let fh = FileHandle(forWritingAtPath: path) {
            defer { try? fh.close() }
            _ = try fh.seekToEnd()
            try fh.write(contentsOf: data)
            try fh.synchronize()
        } else {
            try data.write(to: CodexPaths.sessionIndex, options: [])
        }
    }
}
