import Foundation

// MARK: - Scan: pair the two worlds and detect what moved (read-only)

struct ScanResult {
    var rows: [PairRow] = []
    var fatal: CodexFatal?
    var schemaVersion: Int?
    var skippedUnknownLines = 0
}

final class CodexEngine {

    /// Builds the pair table. Read-only except for persisting freshly computed pair
    /// states back into the ledger (so the menu bar badge survives restarts).
    func scan() -> ScanResult {
        var result = ScanResult()

        guard CodexPaths.isInstalled else {
            result.fatal = .codexNotInstalled
            result.rows = ClaudeIO.enumerateSessions().map { unlinkedClaudeRow($0) }
                .sorted { $0.claudeLastActivity > $1.claudeLastActivity }
            return result
        }

        var store: LinkStoreFile
        do {
            store = try LinkStoreIO.load()
        } catch LinkStoreError.futureSchema(let v) {
            result.fatal = .linkStoreCorrupt("ledger written by a newer app (schema \(v))")
            return result
        } catch {
            result.fatal = .linkStoreCorrupt(String(describing: error))
            return result
        }
        if recover(&store) { try? LinkStoreIO.save(store) }

        result.schemaVersion = CodexIO.schemaVersion()

        let claudeById = Dictionary(uniqueKeysWithValues:
            ClaudeIO.enumerateSessions().map { ($0.cliSessionId, $0) })
        let codexById = Dictionary(uniqueKeysWithValues:
            CodexIO.enumerateThreads().map { ($0.id, $0) })

        let fm = FileManager.default
        var rows: [PairRow] = []
        var dirty = false

        for i in store.pairs.indices {
            var rec = store.pairs[i]
            let claude = claudeById[rec.claudeSessionId]
            let codex = codexById[rec.codexThreadId]

            let claudeSize = (try? fm.attributesOfItem(atPath: rec.claudeTranscriptPath))?[.size] as? Int64
            let codexSize = (try? fm.attributesOfItem(atPath: rec.codexRolloutPath))?[.size] as? Int64

            let (state, reason) = pairState(rec: rec, claudeSize: claudeSize, codexSize: codexSize)
            if state.rawValue != rec.state || reason != rec.conflictReason {
                rec.state = state.rawValue
                rec.conflictReason = reason
                store.pairs[i] = rec
                dirty = true
            }

            rows.append(PairRow(
                id: rec.claudeSessionId,
                claudeID: rec.claudeSessionId,
                codexID: rec.codexThreadId,
                title: claude?.title ?? codex?.title ?? rec.title,
                cwd: claude?.cwd ?? rec.cwd,
                state: state,
                claudeLastActivity: claude?.lastActivityAt ?? 0,
                codexLastActivity: codex?.updatedAtMs ?? 0,
                conflictReason: reason))
        }

        let pairedClaude = Set(store.pairs.map(\.claudeSessionId))
        let pairedCodex = Set(store.pairs.map(\.codexThreadId))

        for (id, s) in claudeById where !pairedClaude.contains(id) {
            rows.append(unlinkedClaudeRow(s))
        }
        for (id, t) in codexById where !pairedCodex.contains(id) {
            rows.append(PairRow(
                id: id, claudeID: nil, codexID: id,
                title: t.title, cwd: t.cwd,
                state: .unlinkedCodex,
                claudeLastActivity: 0, codexLastActivity: t.updatedAtMs,
                conflictReason: nil))
        }

        if dirty { try? LinkStoreIO.save(store) }

        result.rows = rows.sorted {
            max($0.claudeLastActivity, $0.codexLastActivity) >
            max($1.claudeLastActivity, $1.codexLastActivity)
        }
        return result
    }

    /// Cursor-vs-size state machine. Shrunk file = rewritten history (compaction etc.):
    /// never blind-append, surface as conflict for a manual re-baseline.
    private func pairState(rec: PairRecord, claudeSize: Int64?, codexSize: Int64?)
        -> (PairState, String?) {
        guard let cs = claudeSize else { return (.conflict, "Claude transcript missing") }
        guard let xs = codexSize else { return (.conflict, "Codex rollout missing") }
        if rec.inFlight != nil { return (.conflict, "interrupted write — needs recovery") }
        if cs < rec.claude.byteOffset { return (.conflict, "Claude transcript was rewritten") }
        if xs < rec.codex.byteOffset { return (.conflict, "Codex rollout was rewritten") }
        let claudeGrew = cs > rec.claude.byteOffset
        let codexGrew = xs > rec.codex.byteOffset
        switch (claudeGrew, codexGrew) {
        case (true, true): return (.conflict, "both sides advanced since last sync")
        case (true, false): return (.pendingToCodex, nil)
        case (false, true): return (.pendingToClaude, nil)
        case (false, false): return (.synced, nil)
        }
    }

    private func unlinkedClaudeRow(_ s: ClaudeSessionInfo) -> PairRow {
        PairRow(id: s.cliSessionId, claudeID: s.cliSessionId, codexID: nil,
                title: s.title, cwd: s.cwd,
                state: .unlinkedClaude,
                claudeLastActivity: s.lastActivityAt, codexLastActivity: 0,
                conflictReason: nil)
    }
}

// MARK: - Backups (one set per writing run; sqlite via the Online Backup API)

enum BackupManager {
    static let root = LinkStoreIO.dir.appending(path: "backups")

    static func runBackup() throws -> URL {
        let fm = FileManager.default
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dir = root.appending(path: "run-" + f.string(from: Date()))
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        if fm.fileExists(atPath: CodexPaths.stateDB.path) {
            try sqliteOnlineBackup(from: CodexPaths.stateDB.path,
                                   to: dir.appending(path: "state_5.sqlite").path)
        }
        if fm.fileExists(atPath: CodexPaths.sessionIndex.path) {
            try fm.copyItem(at: CodexPaths.sessionIndex, to: dir.appending(path: "session_index.jsonl"))
        }
        if fm.fileExists(atPath: LinkStoreIO.url.path) {
            try fm.copyItem(at: LinkStoreIO.url, to: dir.appending(path: "codex-links.json"))
        }
        // Claude desktop index (small tree; transcripts are never overwritten, only
        // appended with per-file .css-bak, so they are not part of the run backup).
        if fm.fileExists(atPath: BASE.path) {
            try fm.copyItem(at: BASE, to: dir.appending(path: "claude-code-sessions"))
        }
        prune()
        return dir
    }

    /// Keep the last 3 run backups. Same double-check discipline as the Accounts engine:
    /// only directories inside our own backups/ namespace whose name matches run-*.
    static func prune() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        let runs = entries.filter { $0.hasPrefix("run-") }.sorted(by: >)
        for stale in runs.dropFirst(3) {
            let p = root.appending(path: stale)
            guard p.path.hasPrefix(root.path + "/run-") else { continue }
            try? fm.removeItem(at: p)
        }
    }
}

// MARK: - Write operations

enum EngineError: LocalizedError {
    case schemaDrift(Int)
    case conflictNeedsResolve(String)
    case rowNotFound
    case codexHasNoTemplate
    case interruptedWrite

    var errorDescription: String? {
        switch self {
        case .schemaDrift(let v):
            "Codex DB schema is v\(v) (validated: v\(CodexPaths.validatedSchemaVersion)) — Codex-side writes disabled"
        case .conflictNeedsResolve(let r): "conflict (\(r)) — resolve manually"
        case .rowNotFound: "session not found on either side"
        case .codexHasNoTemplate: "Codex has no sessions yet — open Codex once so a template exists"
        case .interruptedWrite: "previous write was interrupted — recovery did not confirm it"
        }
    }
}

extension CodexEngine {

    /// WriteIntent recovery. Runs at every scan/sync entry; returns true if the store changed.
    func recover(_ store: inout LinkStoreFile) -> Bool {
        var dirty = false
        for i in store.pairs.indices {
            guard let intent = store.pairs[i].inFlight else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: intent.targetPath))?[.size] as? Int64

            if let size, size >= intent.baseOffset + intent.length,
               sha256HexOfRegion(path: intent.targetPath, offset: intent.baseOffset,
                                 length: intent.length) == intent.payloadSHA256 {
                // Landed: apply the carried post-state verbatim.
                store.pairs[i].claude = intent.postClaude
                store.pairs[i].codex = intent.postCodex
                store.pairs[i].claudeChainTail = intent.postChainTail
                store.pairs[i].codexTurnIndex = intent.postTurnIndex
                store.pairs[i].claudeEmitIndex = intent.postEmitIndex
                store.pairs[i].state = PairState.synced.rawValue
                store.pairs[i].inFlight = nil
                dirty = true
            } else if let size, size == intent.baseOffset {
                // Never started.
                store.pairs[i].inFlight = nil
                dirty = true
            }
            // Anything else: partial write — stays flagged; scan reports it as conflict.
        }
        return dirty
    }

    /// Entry point for a single row (manual Sync / Import buttons; M4 loops over this).
    func syncRow(id: String) -> CodexSyncReport {
        var report = CodexSyncReport()
        do {
            var store = try LinkStoreIO.load()
            if recover(&store) { try LinkStoreIO.save(store) }

            report.backupDir = try BackupManager.runBackup()

            if let idx = store.pairs.firstIndex(where: {
                $0.claudeSessionId == id || $0.codexThreadId == id }) {
                try syncPair(at: idx, store: &store, report: &report)
            } else if let claude = ClaudeIO.enumerateSessions().first(where: { $0.cliSessionId == id }) {
                try importClaude(claude, store: &store, report: &report)
            } else if let codex = CodexIO.enumerateThreads().first(where: { $0.id == id }) {
                try importCodex(codex, store: &store, report: &report)
            } else {
                throw EngineError.rowNotFound
            }
            try LinkStoreIO.save(store)
        } catch let e as SQLiteError {
            report.failed.append(CodexFailure(title: id, side: "codex", reason: e.message))
        } catch {
            report.failed.append(CodexFailure(title: id, side: "-",
                                              reason: plainReason(error)))
        }
        return report
    }

    private func guardCodexWritable() throws {
        if let v = CodexIO.schemaVersion(), v != CodexPaths.validatedSchemaVersion {
            throw EngineError.schemaDrift(v)
        }
    }

    // MARK: Bulk sync (initial mass import + catch-up)

    struct BulkProgress: Sendable {
        let done: Int
        let total: Int
        let current: String
    }

    /// Runs every actionable row: imports for unlinked sessions, incremental syncs for
    /// pending pairs. Conflicts are counted, never auto-resolved. One backup per run;
    /// the ledger commit after each pair is the checkpoint that makes interruption safe.
    func syncAll(progress: @escaping (BulkProgress) -> Void) -> CodexSyncReport {
        var report = CodexSyncReport()
        do {
            var store = try LinkStoreIO.load()
            if recover(&store) { try LinkStoreIO.save(store) }

            let rows = scan().rows
            let actionable = rows.filter {
                $0.isPending || $0.state == .unlinkedClaude || $0.state == .unlinkedCodex
            }
            report.skippedConflicts = rows.filter { $0.state == .conflict }.count
            guard !actionable.isEmpty else { return report }

            report.backupDir = try BackupManager.runBackup()

            // Oldest-first: date-partitioned rollout dirs fill chronologically and an
            // interruption leaves the older history complete.
            let ordered = actionable.sorted {
                max($0.claudeLastActivity, $0.codexLastActivity) <
                max($1.claudeLastActivity, $1.codexLastActivity)
            }

            let claudeById = Dictionary(uniqueKeysWithValues:
                ClaudeIO.enumerateSessions().map { ($0.cliSessionId, $0) })
            let codexById = Dictionary(uniqueKeysWithValues:
                CodexIO.enumerateThreads().map { ($0.id, $0) })

            for (i, row) in ordered.enumerated() {
                progress(BulkProgress(done: i, total: ordered.count, current: row.title))
                do {
                    if let idx = store.pairs.firstIndex(where: {
                        $0.claudeSessionId == row.id || $0.codexThreadId == row.id }) {
                        try syncPair(at: idx, store: &store, report: &report)
                    } else if row.state == .unlinkedClaude, let s = claudeById[row.id] {
                        try importClaude(s, store: &store, report: &report)
                    } else if row.state == .unlinkedCodex, let t = codexById[row.id] {
                        try importCodex(t, store: &store, report: &report)
                    }
                    try LinkStoreIO.save(store)              // per-pair checkpoint
                } catch let e as SQLiteError {
                    report.failed.append(CodexFailure(title: row.title, side: "codex",
                                                      reason: e.message))
                } catch let e as EngineError {
                    // Schema drift aborts every remaining Codex-bound op — stop early.
                    if case .schemaDrift = e {
                        report.failed.append(CodexFailure(title: row.title, side: "codex",
                                                          reason: e.localizedDescription))
                        break
                    }
                    report.failed.append(CodexFailure(title: row.title, side: "-",
                                                      reason: e.localizedDescription))
                } catch {
                    report.failed.append(CodexFailure(title: row.title, side: "-",
                                                      reason: plainReason(error)))
                }
            }
            progress(BulkProgress(done: ordered.count, total: ordered.count, current: ""))
            try LinkStoreIO.save(store)
        } catch {
            report.failed.append(CodexFailure(title: "run", side: "-", reason: plainReason(error)))
        }
        return report
    }

    // MARK: Conflict resolution

    /// The chosen side's new region is mirrored; the losing side's new region stays in
    /// its own transcript but is recorded as skipped and never mirrored.
    func resolve(id: String, winner: SyncDirection) -> CodexSyncReport {
        var report = CodexSyncReport()
        do {
            var store = try LinkStoreIO.load()
            if recover(&store) { try LinkStoreIO.save(store) }
            guard let idx = store.pairs.firstIndex(where: {
                $0.claudeSessionId == id || $0.codexThreadId == id }) else {
                throw EngineError.rowNotFound
            }
            report.backupDir = try BackupManager.runBackup()

            var rec = store.pairs[idx]
            let fm = FileManager.default
            let claudeSize = (try? fm.attributesOfItem(atPath: rec.claudeTranscriptPath))?[.size] as? Int64 ?? 0
            let codexSize = (try? fm.attributesOfItem(atPath: rec.codexRolloutPath))?[.size] as? Int64 ?? 0

            switch winner {
            case .toCodex:
                // Loser = Codex's foreign tail: record and fast-forward past it.
                if codexSize > rec.codex.byteOffset {
                    rec.skipped.append(SkippedRange(side: "codex", reason: "conflict-resolution",
                                                    at: isoNow(),
                                                    fromByte: rec.codex.byteOffset, toByte: codexSize))
                    rec.codex.byteOffset = codexSize
                }
                store.pairs[idx] = rec
                try incrementalToCodex(at: idx, store: &store, report: &report)
            case .toClaude:
                if claudeSize > rec.claude.byteOffset {
                    // Advance the chain tail through the skipped native turns so mirrored
                    // turns continue the conversation linearly instead of forking the DAG.
                    var lastUuid: String?
                    let consumed = try ClaudeIO.streamLines(path: rec.claudeTranscriptPath,
                                                            from: rec.claude.byteOffset) { line in
                        if let u = line.uuid { lastUuid = u }
                    }
                    rec.skipped.append(SkippedRange(side: "claude", reason: "conflict-resolution",
                                                    at: isoNow(),
                                                    fromByte: rec.claude.byteOffset, toByte: consumed))
                    rec.claude.byteOffset = consumed
                    if let u = lastUuid { rec.claudeChainTail = u }
                }
                store.pairs[idx] = rec
                try incrementalToClaude(at: idx, store: &store, report: &report)
            }
            try LinkStoreIO.save(store)
        } catch let e as SQLiteError {
            report.failed.append(CodexFailure(title: id, side: "codex", reason: e.message))
        } catch {
            report.failed.append(CodexFailure(title: id, side: "-", reason: plainReason(error)))
        }
        return report
    }

    // MARK: Initial import, Claude → Codex

    func importClaude(_ s: ClaudeSessionInfo, store: inout LinkStoreFile,
                      report: inout CodexSyncReport) throws {
        try guardCodexWritable()
        guard let templates = CodexTemplates.load() else { throw EngineError.codexHasNoTemplate }

        let codexId = DeterministicID.codexThreadId(claudeId: s.cliSessionId,
                                                    createdAtMs: s.createdAt)
        let rolloutURL = CodexWriter.rolloutPath(threadId: codexId, createdAtMs: s.createdAt)

        let emitter = ClaudeToCodexEmitter(codexId: codexId, cwd: s.cwd, startTurnIndex: 0)
        let createdISO = ISO8601DateFormatter()
            .string(from: Date(timeIntervalSince1970: Double(s.createdAt) / 1000))

        var consumed: Int64 = 0
        var rolloutLineCount = 0
        try CodexWriter.createRollout(at: rolloutURL) { write in
            let pre = ClaudeToCodexEmitter.preamble(metaTemplate: templates.meta,
                                                    codexId: codexId, cwd: s.cwd,
                                                    createdAtISO: createdISO)
            try write([pre])
            rolloutLineCount += 1
            var pendingError: Error?
            consumed = try ClaudeIO.streamLines(path: s.transcriptPath) { line in
                guard pendingError == nil else { return }
                let out = emitter.feed(line)
                if !out.isEmpty {
                    do { try write(out); rolloutLineCount += out.count }
                    catch { pendingError = error }
                }
            }
            if let e = pendingError { throw e }
            let tail = emitter.finish()
            try write(tail)
            rolloutLineCount += tail.count
        }

        let rolloutSize = (try? FileManager.default.attributesOfItem(atPath: rolloutURL.path))?[.size] as? Int64 ?? 0
        let firstUser = emitter.stats.firstUserText ?? s.title
        try CodexWriter.upsertThread(id: codexId, rolloutPath: rolloutURL.path, cwd: s.cwd,
                                     title: s.title, firstUserMessage: firstUser,
                                     createdAtMs: s.createdAt, updatedAtMs: s.lastActivityAt)
        try CodexWriter.appendSessionIndex(id: codexId, name: s.title)

        store.pairs.append(PairRecord(
            claudeSessionId: s.cliSessionId,
            claudeTranscriptPath: s.transcriptPath,
            codexThreadId: codexId,
            codexRolloutPath: rolloutURL.path,
            originSide: "claude",
            title: s.title,
            cwd: s.cwd,
            state: PairState.synced.rawValue,
            conflictReason: nil,
            lastSyncAt: isoNow(),
            claude: SideCursor(byteOffset: consumed,
                               lineCount: emitter.stats.consumedLineCount,
                               lastEventId: emitter.stats.lastConsumedUuid),
            codex: SideCursor(byteOffset: rolloutSize,
                              lineCount: rolloutLineCount,
                              lastEventId: emitter.stats.lastTimestamp),
            claudeChainTail: emitter.stats.lastConsumedUuid,
            codexTurnIndex: emitter.nextTurnIndex,
            claudeEmitIndex: 0,
            skipped: [],
            inFlight: nil))
        report.created += 1
    }

    // MARK: Initial import, Codex → Claude

    func importCodex(_ t: CodexThreadInfo, store: inout LinkStoreFile,
                     report: inout CodexSyncReport) throws {
        let claudeId = DeterministicID.claudeSessionId(codexId: t.id)
        let cwd = t.cwd == "—" ? FileManager.default.homeDirectoryForCurrentUser.path : t.cwd
        let emitter = CodexToClaudeEmitter(claudeSessionId: claudeId, codexId: t.id,
                                           cwd: cwd, model: t.model,
                                           chainTail: nil, startLineIndex: 0)

        var consumed: Int64 = 0
        var claudeLineCount = 0
        let transcriptPath = try ClaudeWriter.createTranscript(sessionId: claudeId, cwd: cwd) { write in
            var pendingError: Error?
            consumed = try CodexIO.streamLines(path: t.rolloutPath) { line in
                guard pendingError == nil else { return }
                let out = emitter.feed(line)
                if !out.isEmpty {
                    do { try write(out); claudeLineCount += out.count }
                    catch { pendingError = error }
                }
            }
            if let e = pendingError { throw e }
            let title: [String: Any] = ["type": "custom-title", "customTitle": t.title,
                                        "sessionId": claudeId]
            try write([title])
            claudeLineCount += 1
        }

        try ClaudeWriter.createIndexEntry(cliSessionId: claudeId, cwd: cwd, title: t.title,
                                          createdAtMs: t.createdAtMs,
                                          lastActivityAtMs: t.updatedAtMs)

        let size = (try? FileManager.default.attributesOfItem(atPath: transcriptPath))?[.size] as? Int64 ?? 0
        store.pairs.append(PairRecord(
            claudeSessionId: claudeId,
            claudeTranscriptPath: transcriptPath,
            codexThreadId: t.id,
            codexRolloutPath: t.rolloutPath,
            originSide: "codex",
            title: t.title,
            cwd: cwd,
            state: PairState.synced.rawValue,
            conflictReason: nil,
            lastSyncAt: isoNow(),
            claude: SideCursor(byteOffset: size, lineCount: claudeLineCount,
                               lastEventId: emitter.chainTail),
            codex: SideCursor(byteOffset: consumed,
                              lineCount: emitter.stats.consumedLineCount,
                              lastEventId: emitter.stats.lastTimestamp),
            claudeChainTail: emitter.chainTail,
            codexTurnIndex: 0,
            claudeEmitIndex: emitter.nextLineIndex,
            skipped: [],
            inFlight: nil))
        report.created += 1
    }

    // MARK: Incremental sync of an existing pair

    func syncPair(at idx: Int, store: inout LinkStoreFile,
                  report: inout CodexSyncReport) throws {
        let rec = store.pairs[idx]
        if rec.inFlight != nil { throw EngineError.interruptedWrite }

        let fm = FileManager.default
        let claudeSize = (try? fm.attributesOfItem(atPath: rec.claudeTranscriptPath))?[.size] as? Int64 ?? -1
        let codexSize = (try? fm.attributesOfItem(atPath: rec.codexRolloutPath))?[.size] as? Int64 ?? -1
        let claudeGrew = claudeSize > rec.claude.byteOffset
        let codexGrew = codexSize > rec.codex.byteOffset

        if claudeSize < rec.claude.byteOffset || codexSize < rec.codex.byteOffset {
            throw EngineError.conflictNeedsResolve("a side was rewritten")
        }
        switch (claudeGrew, codexGrew) {
        case (true, true): throw EngineError.conflictNeedsResolve("both sides advanced")
        case (true, false): try incrementalToCodex(at: idx, store: &store, report: &report)
        case (false, true): try incrementalToClaude(at: idx, store: &store, report: &report)
        case (false, false): break                          // already in sync
        }
    }

    func incrementalToCodex(at idx: Int, store: inout LinkStoreFile,
                            report: inout CodexSyncReport) throws {
        try guardCodexWritable()
        guard CodexTemplates.load() != nil else { throw EngineError.codexHasNoTemplate }
        var rec = store.pairs[idx]

        let emitter = ClaudeToCodexEmitter(codexId: rec.codexThreadId, cwd: rec.cwd,
                                           startTurnIndex: rec.codexTurnIndex)
        var lines: [[String: Any]] = []
        let consumed = try ClaudeIO.streamLines(path: rec.claudeTranscriptPath,
                                                from: rec.claude.byteOffset) { line in
            lines.append(contentsOf: emitter.feed(line))
        }
        lines.append(contentsOf: emitter.finish())

        let newClaude = SideCursor(byteOffset: consumed,
                                   lineCount: rec.claude.lineCount + emitter.stats.consumedLineCount,
                                   lastEventId: emitter.stats.lastConsumedUuid ?? rec.claude.lastEventId)

        guard !lines.isEmpty else {
            // Nothing convertible (system/attachment noise): just advance the cursor.
            rec.claude = newClaude
            rec.state = PairState.synced.rawValue
            rec.lastSyncAt = isoNow()
            store.pairs[idx] = rec
            return
        }

        let data = serializeJSONL(lines)
        let base = (try? FileManager.default.attributesOfItem(atPath: rec.codexRolloutPath))?[.size] as? Int64 ?? 0
        rec.inFlight = WriteIntent(
            targetSide: "codex", targetPath: rec.codexRolloutPath,
            baseOffset: base, length: Int64(data.count),
            payloadSHA256: sha256Hex(data), startedAt: isoNow(),
            postClaude: newClaude,
            postCodex: SideCursor(byteOffset: base + Int64(data.count),
                                  lineCount: rec.codex.lineCount + lines.count,
                                  lastEventId: emitter.stats.lastTimestamp),
            postChainTail: emitter.stats.lastConsumedUuid ?? rec.claudeChainTail,
            postTurnIndex: emitter.nextTurnIndex,
            postEmitIndex: rec.claudeEmitIndex)
        store.pairs[idx] = rec
        try LinkStoreIO.save(store)                          // intent durable before the write

        _ = try appendJSONL(path: rec.codexRolloutPath, data: data)
        try? CodexWriter.touchThread(id: rec.codexThreadId,
                                     updatedAtMs: Int(Date().timeIntervalSince1970 * 1000))

        rec.claude = rec.inFlight!.postClaude
        rec.codex = rec.inFlight!.postCodex
        rec.claudeChainTail = rec.inFlight!.postChainTail
        rec.codexTurnIndex = rec.inFlight!.postTurnIndex
        rec.inFlight = nil
        rec.state = PairState.synced.rawValue
        rec.lastSyncAt = isoNow()
        store.pairs[idx] = rec
        report.updated += 1
    }

    func incrementalToClaude(at idx: Int, store: inout LinkStoreFile,
                             report: inout CodexSyncReport) throws {
        var rec = store.pairs[idx]
        let model = CodexIO.enumerateThreads().first { $0.id == rec.codexThreadId }?.model
            ?? "codex-import"
        let emitter = CodexToClaudeEmitter(claudeSessionId: rec.claudeSessionId,
                                           codexId: rec.codexThreadId,
                                           cwd: rec.cwd, model: model,
                                           chainTail: rec.claudeChainTail,
                                           startLineIndex: rec.claudeEmitIndex)
        var lines: [[String: Any]] = []
        let consumed = try CodexIO.streamLines(path: rec.codexRolloutPath,
                                               from: rec.codex.byteOffset) { line in
            lines.append(contentsOf: emitter.feed(line))
        }

        let newCodex = SideCursor(byteOffset: consumed,
                                  lineCount: rec.codex.lineCount + emitter.stats.consumedLineCount,
                                  lastEventId: emitter.stats.lastTimestamp)

        guard !lines.isEmpty else {
            rec.codex = newCodex
            rec.state = PairState.synced.rawValue
            rec.lastSyncAt = isoNow()
            store.pairs[idx] = rec
            return
        }

        let data = serializeJSONL(lines)
        let base = (try? FileManager.default.attributesOfItem(atPath: rec.claudeTranscriptPath))?[.size] as? Int64 ?? 0
        rec.inFlight = WriteIntent(
            targetSide: "claude", targetPath: rec.claudeTranscriptPath,
            baseOffset: base, length: Int64(data.count),
            payloadSHA256: sha256Hex(data), startedAt: isoNow(),
            postClaude: SideCursor(byteOffset: base + Int64(data.count),
                                   lineCount: rec.claude.lineCount + lines.count,
                                   lastEventId: emitter.chainTail),
            postCodex: newCodex,
            postChainTail: emitter.chainTail,
            postTurnIndex: rec.codexTurnIndex,
            postEmitIndex: emitter.nextLineIndex)
        store.pairs[idx] = rec
        try LinkStoreIO.save(store)

        _ = try appendJSONL(path: rec.claudeTranscriptPath, data: data)
        ClaudeWriter.touchIndexEntry(cliSessionId: rec.claudeSessionId,
                                     lastActivityAtMs: Int(Date().timeIntervalSince1970 * 1000))

        rec.claude = rec.inFlight!.postClaude
        rec.codex = rec.inFlight!.postCodex
        rec.claudeChainTail = rec.inFlight!.postChainTail
        rec.claudeEmitIndex = rec.inFlight!.postEmitIndex
        rec.inFlight = nil
        rec.state = PairState.synced.rawValue
        rec.lastSyncAt = isoNow()
        store.pairs[idx] = rec
        report.updated += 1
    }
}
