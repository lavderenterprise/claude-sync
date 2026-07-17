import Foundation

// MARK: - Pair ledger: the source of truth for what has been synced where

struct SideCursor: Codable {
    var byteOffset: Int64             // everything before this is synced
    var lineCount: Int                // human-debuggable redundancy
    var lastEventId: String?          // Claude: last consumed uuid; Codex: last timestamp

    static let zero = SideCursor(byteOffset: 0, lineCount: 0, lastEventId: nil)
}

struct SkippedRange: Codable {
    var side: String                  // "claude" | "codex"
    var reason: String
    var at: String                    // ISO8601
    var fromByte: Int64
    var toByte: Int64
}

/// Crash-recovery intent: written + fsynced BEFORE appending to a target file.
/// On startup, the region [baseOffset, baseOffset+length) is hashed: match ⇒ the append
/// landed ⇒ the carried post-state is applied verbatim (cursors, chain tail, indices —
/// guessing them after the fact would corrupt uuid chains); file still at baseOffset ⇒
/// the write never started ⇒ intent cleared; anything else ⇒ partial ⇒ conflict.
struct WriteIntent: Codable {
    var targetSide: String
    var targetPath: String
    var baseOffset: Int64
    var length: Int64
    var payloadSHA256: String
    var startedAt: String
    // Post-write state to apply on confirmed landing:
    var postClaude: SideCursor
    var postCodex: SideCursor
    var postChainTail: String?
    var postTurnIndex: Int
    var postEmitIndex: Int
    var postSegments: [ChainSegment]?     // fork-chain cursors (nil on v1 intents)
}

struct PairRecord: Codable {
    var claudeSessionId: String
    var claudeTranscriptPath: String
    var codexThreadId: String
    var codexRolloutPath: String
    var originSide: String            // "claude" | "codex"
    var title: String
    var cwd: String
    var state: String                 // PairState.rawValue (synced/pending*/conflict)
    var conflictReason: String?
    var lastSyncAt: String
    var claude: SideCursor
    var codex: SideCursor
    var claudeChainTail: String?      // uuid to use as parentUuid for the next appended line
    var codexTurnIndex: Int           // deterministic turn-id counter (Claude → Codex)
    var claudeEmitIndex: Int          // deterministic line-uuid counter (Codex → Claude)
    var skipped: [SkippedRange]
    var inFlight: WriteIntent?
    /// Fork/continuation segments of the same logical chat (newer Codex builds link
    /// threads via forked_from_id/parent_thread_id and the UI stitches them into one).
    /// Ordered by creation; each keeps its own consumption cursor. Optional so v1
    /// ledgers keep decoding untouched.
    var codexSegments: [ChainSegment]?
}

struct ChainSegment: Codable {
    var threadId: String
    var rolloutPath: String
    var cursor: SideCursor
}

struct LinkStoreFile: Codable {
    var schemaVersion: Int
    var updatedAt: String
    var pairs: [PairRecord]
}

enum LinkStoreError: Error { case unreadable(String), futureSchema(Int) }

/// Atomic load/save of the ledger. Always ≤2 generations on disk (.json + .json.bak);
/// the swap is rename-based so a crash can never leave a truncated main file.
enum LinkStoreIO {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/ClaudeSessionSync")
    static let url = dir.appending(path: "codex-links.json")
    static let bak = dir.appending(path: "codex-links.json.bak")
    static let currentSchema = 1

    static func load() throws -> LinkStoreFile {
        for candidate in [url, bak] {
            guard let data = try? Data(contentsOf: candidate) else { continue }
            guard let file = try? JSONDecoder().decode(LinkStoreFile.self, from: data) else { continue }
            if file.schemaVersion > currentSchema { throw LinkStoreError.futureSchema(file.schemaVersion) }
            return file
        }
        if FileManager.default.fileExists(atPath: url.path) {
            throw LinkStoreError.unreadable("both codex-links.json and .bak failed to parse")
        }
        return LinkStoreFile(schemaVersion: currentSchema, updatedAt: isoNow(), pairs: [])
    }

    static func save(_ file: LinkStoreFile) throws {
        var out = file
        out.updatedAt = isoNow()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(out)
        let tmp = dir.appending(path: "codex-links.json.tmp")
        try data.write(to: tmp, options: [])
        let fh = try FileHandle(forWritingTo: tmp)
        try fh.synchronize()             // fsync before the rename makes the swap durable
        try fh.close()
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: bak)
            try? FileManager.default.copyItem(at: url, to: bak)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp,
                                                  backupItemName: nil, options: [])
    }
}

func isoNow() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date())
}
