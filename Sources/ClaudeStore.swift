import Foundation
import CryptoKit

// MARK: - Claude Code side: transcript streaming + session enumeration

/// One parsed transcript line. `raw` keeps the full dictionary; typed accessors cover
/// what conversion needs. Unknown types pass through and are skipped by consumers —
/// never an error (schema-drift guard).
struct ClaudeLine {
    let type: String
    let raw: [String: Any]

    var uuid: String? { raw["uuid"] as? String }
    var parentUuid: String? { raw["parentUuid"] as? String }
    var timestamp: String? { raw["timestamp"] as? String }
    var isSidechain: Bool { raw["isSidechain"] as? Bool ?? false }
    var isMeta: Bool { raw["isMeta"] as? Bool ?? false }
    var message: [String: Any]? { raw["message"] as? [String: Any] }
    var syncOrigin: String? { raw["syncOrigin"] as? String }
}

/// A Claude session as the sync engine sees it: one desktop-index entry + its transcript.
struct ClaudeSessionInfo {
    let cliSessionId: String
    let indexFile: String             // "local_<uuid>.json"
    let title: String
    let cwd: String
    let createdAt: Int                // epoch ms
    let lastActivityAt: Int           // epoch ms
    let model: String
    let transcriptPath: String
    let transcriptSize: Int64
}

enum ClaudeIO {
    /// The lossy native encoding of a cwd into a projects/ directory name.
    static func encodeProjectDir(_ cwd: String) -> String {
        cwd.replacingOccurrences(of: "/", with: "-")
           .replacingOccurrences(of: " ", with: "-")
    }

    /// Sessions eligible for pairing: the DEDUP UNION of every account's index (most
    /// recent copy of each cliSessionId wins) with a transcript on disk. A union — not
    /// a "pick the active account" heuristic — because accounts can tie on activity and
    /// Dictionary iteration order would then flip the choice per process.
    static func enumerateSessions() -> [ClaudeSessionInfo] {
        let fm = FileManager.default
        var byId: [String: ClaudeSessionInfo] = [:]
        for (_, dir) in discoverAccounts() {
            for file in sessionFiles(in: dir) {
                guard let d = readJSON(file),
                      let cli = d["cliSessionId"] as? String,
                      let cwd = d["cwd"] as? String else { continue }
                let activity = num(d["lastActivityAt"])
                if let seen = byId[cli], seen.lastActivityAt >= activity { continue }
                let path = CLAUDE_HOME.appending(path: "projects")
                    .appending(path: encodeProjectDir(cwd))
                    .appending(path: cli + ".jsonl").path
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let size = attrs[.size] as? Int64 else { continue }   // orphan → skip
                byId[cli] = ClaudeSessionInfo(
                    cliSessionId: cli,
                    indexFile: file.lastPathComponent,
                    title: (d["title"] as? String) ?? "(untitled)",
                    cwd: cwd,
                    createdAt: num(d["createdAt"]),
                    lastActivityAt: activity,
                    model: (d["model"] as? String) ?? "",
                    transcriptPath: path,
                    transcriptSize: size)
            }
        }
        return Array(byId.values)
    }

    /// Stream transcript lines starting at a byte offset, without loading the file whole.
    /// Malformed/unknown lines are surfaced with type "unknown" so callers can count them.
    /// Returns the byte offset consumed through the last complete line.
    @discardableResult
    static func streamLines(path: String, from offset: Int64 = 0,
                            _ body: (ClaudeLine) -> Void) throws -> Int64 {
        try streamJSONL(path: path, from: offset) { dict in
            body(ClaudeLine(type: (dict["type"] as? String) ?? "unknown", raw: dict))
        }
    }
}

// MARK: - Fork-file forensics (prompt-edit forks copy ancestor lines verbatim)

extension ClaudeIO {
    /// First uuid in the transcript. A fork file copies the ancestor chain with the
    /// SAME uuids, so a shared root uuid is a definitive fork signature — independent
    /// v4 roots cannot collide by chance.
    static func rootUuid(path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 262_144) else { return nil }
        for chunk in data.split(separator: UInt8(ascii: "\n")) {
            if let d = try? JSONSerialization.jsonObject(with: Data(chunk)) as? [String: Any],
               let u = d["uuid"] as? String {
                return u
            }
        }
        return nil
    }

    /// Every uuid in the first `upTo` bytes. A synced region always ends on a line
    /// boundary, so no partial-line handling is needed.
    static func uuidsInRegion(path: String, upTo: Int64) -> Set<String> {
        guard upTo > 0, let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: Int(upTo)) else { return [] }
        var out = Set<String>()
        for chunk in data.split(separator: UInt8(ascii: "\n")) {
            if let d = try? JSONSerialization.jsonObject(with: Data(chunk)) as? [String: Any],
               let u = d["uuid"] as? String {
                out.insert(u)
            }
        }
        return out
    }

    /// Extent of a fork file's shared prefix against the ancestor's synced uuids:
    /// the byte offset past the last consecutive known line, that prefix's line count,
    /// and the last shared uuid (the fork point — the DAG parent of whatever follows).
    /// Lines without a uuid (titles, summaries) extend the prefix but never anchor it.
    static func forkDivergence(forkPath: String, ancestorUuids: Set<String>)
        -> (byteOffset: Int64, lineCount: Int, lastSharedUuid: String?) {
        guard !ancestorUuids.isEmpty,
              let fh = FileHandle(forReadingAtPath: forkPath) else { return (0, 0, nil) }
        defer { try? fh.close() }
        var offset: Int64 = 0
        var lines = 0
        var lastShared: String?
        var leftover: [UInt8] = []
        while let chunk = try? fh.read(upToCount: 4 << 20), !chunk.isEmpty {
            let buf: [UInt8] = leftover.isEmpty ? [UInt8](chunk) : leftover + [UInt8](chunk)
            leftover = []
            var start = 0
            var i = 0
            while i < buf.count {
                if buf[i] == UInt8(ascii: "\n") {
                    let lineData = Data(buf[start..<i])
                    if let d = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                       let u = d["uuid"] as? String {
                        guard ancestorUuids.contains(u) else { return (offset, lines, lastShared) }
                        lastShared = u
                    }
                    offset += Int64(i - start) + 1
                    lines += 1
                    start = i + 1
                }
                i += 1
            }
            leftover = Array(buf[start...])
        }
        return (offset, lines, lastShared)
    }
}

// MARK: - Turn-in-flight detection (tail semantics, not just mtime quiet)

/// Yields the parsed JSONL lines from the file's last `cap` bytes (first partial line
/// discarded). Cheap enough to run per grown pair on every scan.
func tailJSONLLines(path: String, cap: Int = 262_144) -> [[String: Any]] {
    guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    var window = cap
    // A single line larger than the window (huge tool_result) yields zero parseable
    // lines; widen up to 8× before giving up so in-flight detection stays sighted.
    while true {
        let start = size > UInt64(window) ? size - UInt64(window) : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd() else { return [] }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if start > 0, !lines.isEmpty { lines.removeFirst() }      // partial first line
        let parsed = lines.compactMap {
            try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
        }
        if !parsed.isEmpty || start == 0 { return parsed }
        if window >= cap * 8 { return parsed }
        window *= 8
    }
}

/// Turns older than this are treated as abandoned (interrupted session), not in flight —
/// otherwise a dead dangling turn would block syncing forever.
let inFlightStalenessCap: TimeInterval = 600

extension ClaudeIO {
    /// Is the LAST conversational element an open turn? Open = a user prompt awaiting
    /// its reply, a tool_result the model is still following up on, or an assistant
    /// message that called tools whose results haven't landed.
    static func turnInFlight(path: String, mtime: Date?) -> Bool {
        if let m = mtime, Date().timeIntervalSince(m) > inFlightStalenessCap { return false }
        var last: [String: Any]?
        for dict in tailJSONLLines(path: path) {
            guard let t = dict["type"] as? String, t == "user" || t == "assistant",
                  (dict["isSidechain"] as? Bool) != true,
                  (dict["isMeta"] as? Bool) != true,
                  dict["message"] != nil else { continue }
            last = dict
        }
        guard let line = last, let message = line["message"] as? [String: Any] else {
            // No conversational line in the tail (huge unparseable line, or pure
            // bookkeeping): we cannot prove the turn is closed — fail safe. The
            // staleness cap at the top still releases abandoned files.
            return true
        }
        if (line["type"] as? String) == "assistant" {
            if let items = message["content"] as? [[String: Any]],
               items.contains(where: { ($0["type"] as? String) == "tool_use" }) {
                return true                    // tools called, results not in the tail yet
            }
            return false                       // plain assistant reply = turn closed
        }
        return true                            // user prompt or tool_result = model's move
    }
}

enum ClaudeWriter {

    /// Creates a new transcript atomically (tmp + fsync + rename, chmod 600, like the
    /// native writer). `feed` streams line dictionaries; they are serialized one per line.
    static func createTranscript(sessionId: String, cwd: String,
                                 feed: ((@escaping ([[String: Any]]) throws -> Void)) throws -> Void)
        throws -> String {
        let dir = CLAUDE_HOME.appending(path: "projects")
            .appending(path: ClaudeIO.encodeProjectDir(cwd))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let final = dir.appending(path: sessionId + ".jsonl")
        let tmp = dir.appending(path: ".tmp-" + sessionId + ".jsonl")
        // Deterministic ids make re-imports converge on the same path: if a previous
        // mirror exists (ledger lost/reset), keep a copy before replacing it.
        if FileManager.default.fileExists(atPath: final.path) {
            try? FileManager.default.removeItem(atPath: final.path + ".pre-import-bak")
            try? FileManager.default.copyItem(atPath: final.path,
                                              toPath: final.path + ".pre-import-bak")
        }

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
        _ = try FileManager.default.replaceItemAt(final, withItemAt: tmp,
                                                  backupItemName: nil, options: [])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: final.path)
        return final.path
    }

    /// Appends lines to an existing transcript: one-generation .css-bak first, then a
    /// single O_APPEND write + fsync. Returns (bytesAppended, newSize).
    static func appendTranscript(path: String, lines: [[String: Any]]) throws -> (Int64, Int64) {
        try appendJSONL(path: path, data: serializeJSONL(lines))
    }

    /// Desktop-index entry so the Claude app lists the imported session. Written into the
    /// ACTIVE account dir; the existing cross-account engine propagates it from there.
    /// Deterministic filename → idempotent re-runs.
    static func createIndexEntry(cliSessionId: String, cwd: String, title: String,
                                 createdAtMs: Int, lastActivityAtMs: Int) throws {
        // Deterministic account choice: highest activity, then most entries, then uuid —
        // Dictionary order must never decide (accounts can tie on activity).
        let ranked = discoverAccounts().sorted { a, b in
            func rank(_ dir: URL) -> (Int, Int) {
                let files = sessionFiles(in: dir)
                let act = files.compactMap { readJSON($0) }.map { num($0["lastActivityAt"]) }.max() ?? 0
                return (act, files.count)
            }
            let ra = rank(a.value), rb = rank(b.value)
            if ra.0 != rb.0 { return ra.0 > rb.0 }
            if ra.1 != rb.1 { return ra.1 > rb.1 }
            return a.key < b.key
        }
        guard let active = ranked.first?.value else {
            throw NSError(domain: "css", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no Claude account directory found"])
        }

        // Borrow the current default model from the newest native entry.
        let model = sessionFiles(in: active).compactMap { readJSON($0) }
            .max { num($0["lastActivityAt"]) < num($1["lastActivityAt"]) }
            .flatMap { $0["model"] as? String } ?? "claude-opus-4-8"

        let entry: [String: Any] = [
            "sessionId": "local_" + DeterministicID.indexFileId(claudeId: cliSessionId),
            "cliSessionId": cliSessionId,
            "cwd": cwd,
            "originCwd": cwd,
            "createdAt": createdAtMs,
            "lastActivityAt": lastActivityAtMs,
            "lastFocusedAt": lastActivityAtMs,
            "model": model,
            "effort": "high",
            "isArchived": false,
            "title": title,
            "titleSource": "user",              // prevents auto-retitle
            "permissionMode": "default",
            "enabledMcpTools": [:],
            "remoteMcpServersConfig": [],
            "chromePermissionMode": "default",
            "alwaysAllowedReasons": [],
            "sessionPermissionUpdates": [],
            "classifierSummaryEnabled": true,
            "spawnSeed": [:],
        ]
        let url = active.appending(path: "local_"
            + DeterministicID.indexFileId(claudeId: cliSessionId) + ".json")
        let data = try JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted])
        try data.write(to: url, options: .atomic)
    }

    /// Bumps lastActivityAt on the index entry after appending turns (atomic rewrite).
    static func touchIndexEntry(cliSessionId: String, lastActivityAtMs: Int) {
        for (_, dir) in discoverAccounts() {
            for file in sessionFiles(in: dir) {
                guard var d = readJSON(file), (d["cliSessionId"] as? String) == cliSessionId
                else { continue }
                d["lastActivityAt"] = lastActivityAtMs
                if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted]) {
                    try? data.write(to: file, options: .atomic)
                }
            }
        }
    }
}

// MARK: - Shared JSONL write helpers

func serializeJSONL(_ lines: [[String: Any]]) -> Data {
    var out = Data()
    for line in lines {
        if let d = try? JSONSerialization.data(withJSONObject: line) {
            out.append(d)
            out.append(UInt8(ascii: "\n"))
        }
    }
    return out
}

enum AppendError: Error { case targetMoved }

/// .css-bak copy + single append write + fsync. Shared by both sides' appenders.
/// `expectedEnd` guards against the native writer appending between the caller's size
/// probe (recorded in the WriteIntent) and this write: a moved end means writing now
/// would leave the ledger cursor pointing mid-content — abort instead.
func appendJSONL(path: String, data: Data, expectedEnd: Int64? = nil) throws -> (Int64, Int64) {
    let fm = FileManager.default
    let bak = path + ".css-bak"
    try? fm.removeItem(atPath: bak)
    try fm.copyItem(atPath: path, toPath: bak)

    guard let fh = FileHandle(forWritingAtPath: path) else {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                      userInfo: [NSFilePathErrorKey: path])
    }
    defer { try? fh.close() }
    let end = try fh.seekToEnd()
    if let expected = expectedEnd, Int64(end) != expected {
        throw AppendError.targetMoved
    }
    try fh.write(contentsOf: data)
    try fh.synchronize()
    return (Int64(data.count), Int64(end) + Int64(data.count))
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Hashes a byte region of a file (WriteIntent recovery).
func sha256HexOfRegion(path: String, offset: Int64, length: Int64) -> String? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    guard (try? fh.seek(toOffset: UInt64(offset))) != nil,
          let data = try? fh.read(upToCount: Int(length)), Int64(data.count) == length
    else { return nil }
    return sha256Hex(data)
}

// MARK: - Shared chunked JSONL reader

/// Reads a JSONL file from `offset`, invoking `body` per parsed line. Chunked (1 MB) so
/// 130 MB transcripts never materialize in memory. Unparseable lines are skipped.
/// Returns the byte offset consumed through the last complete line — the safe value for
/// a sync cursor (an incomplete trailing line is NOT counted unless it parsed).
@discardableResult
func streamJSONL(path: String, from offset: Int64,
                 _ body: ([String: Any]) -> Void) throws -> Int64 {
    guard let fh = FileHandle(forReadingAtPath: path) else {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
                      userInfo: [NSFilePathErrorKey: path])
    }
    defer { try? fh.close() }
    if offset > 0 { try fh.seek(toOffset: UInt64(offset)) }

    var consumed = offset
    var carry = Data()
    while true {
        let chunk = autoreleasepool { fh.readData(ofLength: 1 << 20) }
        if chunk.isEmpty { break }
        carry.append(chunk)
        // One consume pass per chunk; Data slices keep parent indices, so line data is
        // copied via Data(_:) before parsing and the consumed prefix removed in one go.
        var start = carry.startIndex
        while let nl = carry[start...].firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = Data(carry[start..<nl])
            start = carry.index(after: nl)
            guard !lineData.isEmpty else { continue }
            autoreleasepool {
                if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                    body(obj)
                }
            }
        }
        consumed += Int64(carry.distance(from: carry.startIndex, to: start))
        carry.removeSubrange(carry.startIndex..<start)
    }
    // Trailing line without newline (writer mid-append): parse if complete JSON.
    if !carry.isEmpty,
       let obj = try? JSONSerialization.jsonObject(with: carry) as? [String: Any] {
        body(obj)
        consumed += Int64(carry.count)
    }
    return consumed
}
