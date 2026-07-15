import Foundation

// MARK: - Pair model shared between engine and UI

enum PairState: String, Codable {
    case synced, pendingToCodex, pendingToClaude, conflict, unlinkedClaude, unlinkedCodex
    case working      // a side grew but is still being written (agent mid-turn):
                      // not pending yet, not counted in the badge, no action offered
}

enum SyncDirection { case toCodex, toClaude }

struct PairRow: Identifiable {
    let id: String                    // stable pair key: claude id if present, else codex id
    let claudeID: String?
    let codexID: String?
    let title: String
    let cwd: String
    let state: PairState
    let claudeLastActivity: Int       // epoch ms, 0 = absent
    let codexLastActivity: Int        // epoch ms, 0 = absent
    let conflictReason: String?       // set when state == .conflict

    var isPending: Bool { state == .pendingToCodex || state == .pendingToClaude }
}

// MARK: - Reports (mirrors SyncReport/FatalError style from the Accounts engine)

struct CodexFailure: Identifiable {
    let id = UUID()
    let title: String
    let side: String                  // "claude" | "codex"
    let reason: String
}

struct CodexSyncReport: Identifiable {
    var created = 0                   // new counterpart sessions created
    var updated = 0                   // existing counterparts appended to
    var skippedConflicts = 0
    var failed: [CodexFailure] = []
    var fatal: CodexFatal?
    var backupDir: URL?
    var ok: Bool { fatal == nil && failed.isEmpty }
    var id: String { "\(created)-\(updated)-\(failed.count)-\(backupDir?.path ?? "")" }
}

/// User-facing fatal errors — same philosophy as `FatalError`: the text is what the
/// user reads, never a raw Cocoa/sqlite message.
enum CodexFatal {
    case codexNotInstalled
    case backupFailed(String)
    case schemaDrift(Int)             // observed _sqlx_migrations version
    case linkStoreCorrupt(String)

    var title: String {
        switch self {
        case .codexNotInstalled: "Codex not found on this Mac"
        case .backupFailed: "Backup failed — nothing was changed"
        case .schemaDrift: "Codex database format changed"
        case .linkStoreCorrupt: "Sync ledger unreadable"
        }
    }

    var detail: String {
        switch self {
        case .codexNotInstalled:
            "~/.codex does not exist. Install the ChatGPT app and open Codex at least once, then try again."
        case .backupFailed(let why):
            "The safety backup could not be created, so no session was touched.\n\nTechnical cause: \(why)"
        case .schemaDrift(let v):
            "Codex's internal database reports schema version \(v), but this app was validated against version \(CodexPaths.validatedSchemaVersion). Writing could corrupt Codex data, so Codex-side writes are disabled until the app is updated. Reading and Claude-side sync still work."
        case .linkStoreCorrupt(let why):
            "The sync ledger and its backup are both unreadable (\(why)). Use Rebuild in the Codex tab to reconstruct it from provenance markers."
        }
    }
}
