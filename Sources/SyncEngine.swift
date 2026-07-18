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
        withLedgerLock { scanInner() }
    }

    /// Ledger-lock-free core; callers must hold the ledger lock.
    func scanInner() -> ScanResult {
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

        if healRolloutPaths(&store, codexById: codexById) { try? LinkStoreIO.save(store) }

        let chains = buildChains(codexById)
        // Every thread that is a chain CHILD of some root: never shown as its own row.
        let childIds: Set<String> = Set(chains.values.flatMap { $0.children.map(\.id) })
        if attachNewSegments(&store, codexById: codexById) { try? LinkStoreIO.save(store) }
        // Claude prompt-edit forks: the new file continues an existing pair — adopt it
        // BEFORE the unlinked classification below can offer it as a fresh import.
        if adoptClaudeForks(&store, claudeById: claudeById) { try? LinkStoreIO.save(store) }

        let fm = FileManager.default
        var rows: [PairRow] = []
        var dirty = false

        for i in store.pairs.indices {
            var rec = store.pairs[i]
            let claude = claudeById[rec.claudeSessionId]
            let codex = codexById[rec.codexThreadId]

            let claudeAttrs = try? fm.attributesOfItem(atPath: rec.claudeTranscriptPath)
            let claudeSize = claudeAttrs?[.size] as? Int64
            let health = chainHealth(rec)

            var (state, reason) = pairState(rec: rec, claudeSize: claudeSize, codex: health)

            // A grown side that is still mid-turn must not read as "to sync" (or as a
            // conflict). Two signals, both required to be quiet: recent writes (the
            // auto-sync quiet window) AND tail semantics — a long-running tool keeps
            // the file silent for minutes while the turn is very much open.
            if state == .pendingToCodex || state == .pendingToClaude || state == .conflict {
                let quiet = max(5, UserDefaults.standard.double(forKey: "quiescenceSeconds")
                                   .isZero ? 20 : UserDefaults.standard.double(forKey: "quiescenceSeconds"))
                func isHot(_ attrs: [FileAttributeKey: Any]?) -> Bool {
                    guard let m = attrs?[.modificationDate] as? Date else { return false }
                    return Date().timeIntervalSince(m) < quiet
                }
                let leaf = leafSegment(rec)
                let leafAttrs = try? fm.attributesOfItem(atPath: leaf.path)
                let claudeGrew = (claudeSize ?? 0) > rec.claude.byteOffset
                let claudeBusy = claudeGrew && (isHot(claudeAttrs)
                    || ClaudeIO.turnInFlight(path: rec.claudeTranscriptPath,
                                             mtime: claudeAttrs?[.modificationDate] as? Date))
                let codexBusy = health.grew && (isHot(leafAttrs)
                    || CodexIO.turnInFlight(path: leaf.path,
                                            mtime: leafAttrs?[.modificationDate] as? Date))
                if claudeBusy || codexBusy {
                    state = .working
                    reason = nil
                }
            }
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
        // Retired = fork ancestors and consolidated duplicates: represented by their
        // pair already, never offered as fresh imports again.
        let retiredClaude = Set(store.pairs.flatMap { $0.claudeForkedFrom ?? [] })
        let retiredCodex = Set(store.retiredCodexThreadIds ?? [])

        for (id, s) in claudeById where !pairedClaude.contains(id)
                                         && !retiredClaude.contains(id) {
            rows.append(unlinkedClaudeRow(s))
        }
        for (id, t) in codexById where !pairedCodex.contains(id) && !childIds.contains(id)
                                        && !t.archived && !retiredCodex.contains(id) {
            // Chain roots represent the whole chat; children never get their own row.
            let leafActivity = chains[id]?.leaf.updatedAtMs ?? t.updatedAtMs
            rows.append(PairRow(
                id: id, claudeID: nil, codexID: id,
                title: t.title, cwd: t.cwd,
                state: .unlinkedCodex,
                claudeLastActivity: 0, codexLastActivity: max(t.updatedAtMs, leafActivity),
                conflictReason: nil))
        }

        if dirty { try? LinkStoreIO.save(store) }

        result.rows = rows.sorted {
            max($0.claudeLastActivity, $0.codexLastActivity) >
            max($1.claudeLastActivity, $1.codexLastActivity)
        }
        return result
    }

    /// Codex MOVES a rollout when its thread is archived (sessions/… →
    /// archived_sessions/…) and records the new location in the threads row. Follow the
    /// move instead of reporting a phantom "rollout missing" conflict.
    func healRolloutPaths(_ store: inout LinkStoreFile,
                          codexById: [String: CodexThreadInfo]) -> Bool {
        let fm = FileManager.default
        var dirty = false
        for i in store.pairs.indices {
            let rec = store.pairs[i]
            if !fm.fileExists(atPath: rec.codexRolloutPath),
               let t = codexById[rec.codexThreadId],
               t.rolloutPath != rec.codexRolloutPath,
               fm.fileExists(atPath: t.rolloutPath) {
                store.pairs[i].codexRolloutPath = t.rolloutPath
                dirty = true
            }
            // Chain segments move on archive exactly like roots do.
            if var segs = store.pairs[i].codexSegments {
                var segDirty = false
                for si in segs.indices where !fm.fileExists(atPath: segs[si].rolloutPath) {
                    guard let t = codexById[segs[si].threadId],
                          t.rolloutPath != segs[si].rolloutPath,
                          fm.fileExists(atPath: t.rolloutPath) else { continue }
                    segs[si].rolloutPath = t.rolloutPath
                    segDirty = true
                }
                if segDirty {
                    store.pairs[i].codexSegments = segs
                    dirty = true
                }
            }
        }
        return dirty
    }

    /// Cursor-vs-size state machine. Shrunk file = rewritten history (compaction etc.):
    /// never blind-append, surface as conflict for a manual re-baseline. Codex side is
    /// evaluated across the whole fork chain.
    private func pairState(rec: PairRecord, claudeSize: Int64?, codex: ChainHealth)
        -> (PairState, String?) {
        guard let cs = claudeSize else { return (.conflict, "Claude transcript missing") }
        if codex.missing { return (.conflict, "Codex rollout missing") }
        if rec.inFlight != nil { return (.conflict, "interrupted write — needs recovery") }
        if cs < rec.claude.byteOffset { return (.conflict, "Claude transcript was rewritten") }
        if codex.shrunk { return (.conflict, "Codex rollout was rewritten") }
        let claudeGrew = cs > rec.claude.byteOffset
        switch (claudeGrew, codex.grew) {
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

// MARK: - Fork chains (newer Codex builds link continuation threads)

/// One logical chat = a chain of threads linked by forked_from_id/parent_thread_id.
/// The ChatGPT UI stitches them; importing each segment as its own Claude session is
/// exactly the bug this solves.
struct ChainView {
    let root: CodexThreadInfo
    let children: [CodexThreadInfo]           // ordered by createdAtMs
    var leaf: CodexThreadInfo { children.last ?? root }
}

extension CodexEngine {
    /// rootId → chain. Threads without links are single-segment chains. Cycle-safe.
    func buildChains(_ byId: [String: CodexThreadInfo]) -> [String: ChainView] {
        func rootOf(_ id: String) -> String {
            var cur = id, hops = 0
            while hops < 64, let p = byId[cur]?.parentId, byId[p] != nil, p != cur {
                cur = p; hops += 1
            }
            return cur
        }
        var childrenByRoot: [String: [CodexThreadInfo]] = [:]
        for (id, t) in byId where rootOf(id) != id {
            childrenByRoot[rootOf(id), default: []].append(t)
        }
        var out: [String: ChainView] = [:]
        for (id, t) in byId where rootOf(id) == id {
            let kids = (childrenByRoot[id] ?? []).sorted { $0.createdAtMs < $1.createdAtMs }
            out[id] = ChainView(root: t, children: kids)
        }
        return out
    }

    /// Health of the pair's codex side across root + every chain segment.
    struct ChainHealth { var missing = false; var shrunk = false; var grew = false }

    func chainHealth(_ rec: PairRecord) -> ChainHealth {
        let fm = FileManager.default
        var h = ChainHealth()
        func check(_ path: String, _ cursor: SideCursor) {
            guard let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int64 else {
                h.missing = true
                return
            }
            if size < cursor.byteOffset { h.shrunk = true }
            if size > cursor.byteOffset { h.grew = true }
        }
        check(rec.codexRolloutPath, rec.codex)
        for seg in rec.codexSegments ?? [] { check(seg.rolloutPath, seg.cursor) }
        return h
    }

    /// Attach chain children that appeared since the pair was created. Used by scan
    /// AND syncRow — an auto-sync triggered straight by the watcher must see fresh
    /// fork segments even when no scan ran in between.
    func attachNewSegments(_ store: inout LinkStoreFile,
                           codexById: [String: CodexThreadInfo]) -> Bool {
        let chains = buildChains(codexById)
        var dirty = false
        for i in store.pairs.indices {
            guard let chain = chains[store.pairs[i].codexThreadId] else { continue }
            let known = Set((store.pairs[i].codexSegments ?? []).map(\.threadId))
            for kid in chain.children where !known.contains(kid.id) {
                var segs = store.pairs[i].codexSegments ?? []
                segs.append(ChainSegment(threadId: kid.id, rolloutPath: kid.rolloutPath,
                                         cursor: .zero))
                store.pairs[i].codexSegments = segs
                dirty = true
            }
        }
        return dirty
    }

    /// The file where a Claude→Codex append belongs: the chain's active leaf.
    func leafSegment(_ rec: PairRecord) -> (threadId: String, path: String) {
        if let seg = rec.codexSegments?.last { return (seg.threadId, seg.rolloutPath) }
        return (rec.codexThreadId, rec.codexRolloutPath)
    }
}

// MARK: - Stale fork-siblings (account-switch relics)

extension CodexEngine {
    /// An account switch forks sessions: the continuation gets a new cliSessionId with
    /// the SAME createdAt+cwd, and the original strands in the now-inactive account's
    /// index. Claude shows only the active account's copy; our multi-account union
    /// imports both (no data loss), so the mirror ends up with a visible "duplicate".
    /// This archives the stranded copy's Codex thread via the official RPC — reversible,
    /// and the pre-switch history stays available in the archive.
    func archiveStaleForkThreads() -> Int {
        // Active account = same ranking used everywhere: activity, then entries, then uuid.
        let accounts = discoverAccounts()
        let ranked = accounts.sorted { a, b in
            func rank(_ dir: URL) -> (Int, Int) {
                let files = sessionFiles(in: dir)
                let act = files.compactMap { readJSON($0) }
                    .map { num($0["lastActivityAt"]) }.max() ?? 0
                return (act, files.count)
            }
            let ra = rank(a.value), rb = rank(b.value)
            if ra.0 != rb.0 { return ra.0 > rb.0 }
            if ra.1 != rb.1 { return ra.1 > rb.1 }
            return a.key < b.key
        }
        guard let active = ranked.first?.key else { return 0 }

        // (createdAt, cwd) → cliSessionId → accounts that index it.
        var groups: [String: [String: Set<String>]] = [:]
        for (acc, dir) in accounts {
            for file in sessionFiles(in: dir) {
                guard let d = readJSON(file), let cli = d["cliSessionId"] as? String,
                      let cwd = d["cwd"] as? String else { continue }
                let key = "\(num(d["createdAt"]))|\(cwd)"
                groups[key, default: [:]][cli, default: []].insert(acc)
            }
        }

        guard let store = try? LinkStoreIO.load() else { return 0 }
        let pairByClaude = Dictionary(uniqueKeysWithValues:
            store.pairs.map { ($0.claudeSessionId, $0) })
        let archivedIds = Set(CodexIO.enumerateThreads().filter(\.archived).map(\.id))

        var targets: [String] = []
        for (_, clis) in groups where clis.count > 1 {
            let hasActive = clis.values.contains { $0.contains(active) }
            guard hasActive else { continue }
            for (cli, accs) in clis where !accs.contains(active) {
                if let pair = pairByClaude[cli], !archivedIds.contains(pair.codexThreadId) {
                    targets.append(pair.codexThreadId)
                }
            }
        }
        guard !targets.isEmpty else { return 0 }
        return AppServerRPC.archiveThreads(targets)
    }
}

// MARK: - Claude prompt-edit forks (the desktop forks the session into a NEW file)

extension CodexEngine {
    /// Editing a past prompt makes the Claude desktop write a NEW session file that
    /// copies the ancestor lines VERBATIM (same uuids) and diverges at the edit point,
    /// abandoning the old file. Treating that file as a fresh session exported a twin
    /// Codex thread ending in "[Request interrupted by user]". Instead: re-link the
    /// existing pair to the fork file so only the divergent turns flow — into the SAME
    /// thread. Runs in scan AND at syncRow entry (watcher events race scans).
    func adoptClaudeForks(_ store: inout LinkStoreFile,
                          claudeById: [String: ClaudeSessionInfo]) -> Bool {
        var paired = Set(store.pairs.map(\.claudeSessionId))
        var retired = Set(store.pairs.flatMap { $0.claudeForkedFrom ?? [] })
        var rootCache: [String: String] = [:]
        func root(_ path: String) -> String? {
            if let c = rootCache[path] { return c.isEmpty ? nil : c }
            let r = ClaudeIO.rootUuid(path: path)
            rootCache[path] = r ?? ""
            return r
        }

        var dirty = false
        // Oldest-first so that with several forks of one chat the NEWEST ends up as
        // the pair's active file and the earlier ones retire.
        let unlinked = claudeById.values
            .filter { !paired.contains($0.cliSessionId) && !retired.contains($0.cliSessionId) }
            .sorted { $0.lastActivityAt < $1.lastActivityAt }

        for s in unlinked {
            guard let sRoot = root(s.transcriptPath) else { continue }
            let dir = (s.transcriptPath as NSString).deletingLastPathComponent
            let candidates = store.pairs.indices.filter { i in
                let p = store.pairs[i].claudeTranscriptPath
                return (p as NSString).deletingLastPathComponent == dir && root(p) == sRoot
            }
            guard !candidates.isEmpty else { continue }

            // Deepest ancestor wins: the pair whose SYNCED region shares the longest
            // prefix. Only the synced region counts — matching against unsynced tail
            // lines would mark never-exported turns as already mirrored (data loss).
            var bestIdx = -1
            var best: (Int64, Int, String?) = (0, 0, nil)
            for i in candidates {
                let anc = ClaudeIO.uuidsInRegion(path: store.pairs[i].claudeTranscriptPath,
                                                 upTo: store.pairs[i].claude.byteOffset)
                guard !anc.isEmpty else { continue }
                let div = ClaudeIO.forkDivergence(forkPath: s.transcriptPath, ancestorUuids: anc)
                if bestIdx < 0 || div.byteOffset > best.0 { best = div; bestIdx = i }
            }
            guard bestIdx >= 0, best.0 > 0 else { continue }

            var rec = store.pairs[bestIdx]
            let currentActivity = claudeById[rec.claudeSessionId]?.lastActivityAt ?? 0
            var forkedFrom = rec.claudeForkedFrom ?? []
            if s.lastActivityAt >= currentActivity {
                // The fork is the live continuation: the pair follows it.
                forkedFrom.append(rec.claudeSessionId)
                retired.insert(rec.claudeSessionId)
                paired.remove(rec.claudeSessionId)
                rec.claudeSessionId = s.cliSessionId
                rec.claudeTranscriptPath = s.transcriptPath
                rec.claude = SideCursor(byteOffset: best.0, lineCount: best.1,
                                        lastEventId: best.2 ?? rec.claude.lastEventId)
                if let u = best.2 { rec.claudeChainTail = u }
                paired.insert(s.cliSessionId)
            } else {
                // Stale sibling fork: claim it so it can never import as a twin, but
                // keep the pair on its current (newer) file.
                forkedFrom.append(s.cliSessionId)
                retired.insert(s.cliSessionId)
            }
            rec.claudeForkedFrom = forkedFrom
            store.pairs[bestIdx] = rec
            dirty = true
        }
        return dirty
    }

    /// Retired fork ancestors keep their transcript on disk but must leave the desktop
    /// sidebar — one logical chat, one visible session. Runs after the backup in every
    /// write path; idempotent single pass over the index files.
    func hideRetiredClaudeSessions(_ store: LinkStoreFile) {
        let keep = Set(store.pairs.map(\.claudeSessionId))
        let retired = Set(store.pairs.flatMap { $0.claudeForkedFrom ?? [] }).subtracting(keep)
        guard !retired.isEmpty else { return }
        for (_, dir) in discoverAccounts() {
            for file in sessionFiles(in: dir) {
                guard let d = readJSON(file), let cli = d["cliSessionId"] as? String,
                      retired.contains(cli) else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

// MARK: - Twin consolidation (two mirrored copies of one logical chat → one)

/// What consolidation would do for one duplicated chat — shown to the user before
/// anything runs, and the exact instructions the apply step follows.
struct TwinPlan: Identifiable {
    let title: String
    let cwd: String
    let keepClaudeId: String
    let keepCodexId: String
    let relinkClaude: Bool            // canonical pair must adopt the active fork file
    let dropClaudeIds: [String]       // sidebar entries hidden; transcripts stay on disk
    let archiveCodexIds: [String]     // archived via the official RPC (reversible)
    let dropPairIds: [String]         // ledger records folded into the canonical pair
    var id: String { keepCodexId }
}

extension CodexEngine {
    /// Conversational user turns as normalized hashes — the same extraction the
    /// replay-dedup seed uses. Cached by (path, size, mtime): the planner runs on
    /// every reload and the transcripts can be tens of MB.
    private static var seqCache: [String: (key: String, seq: [Int])] = [:]
    private static let seqCacheLock = NSLock()

    func userTurnSequence(_ path: String) -> [Int] {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let key = "\(attrs?[.size] as? Int64 ?? -1)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        Self.seqCacheLock.lock()
        if let hit = Self.seqCache[path], hit.key == key {
            Self.seqCacheLock.unlock()
            return hit.seq
        }
        Self.seqCacheLock.unlock()
        var out: [Int] = []
        _ = try? ClaudeIO.streamLines(path: path) { line in
            guard line.type == "user", !line.isMeta, !line.isSidechain,
                  let c = line.message?["content"] else { return }
            if let s = c as? String {
                if !isInterruptionArtifact(s) {
                    out.append(CodexToClaudeEmitter.normalizedHash(s))
                }
            } else if let items = c as? [[String: Any]] {
                let text = items.filter { ($0["type"] as? String) == "text" }
                    .compactMap { $0["text"] as? String }.joined(separator: "\n")
                if !text.isEmpty, !isInterruptionArtifact(text) {
                    out.append(CodexToClaudeEmitter.normalizedHash(text))
                }
            }
        }
        Self.seqCacheLock.lock()
        Self.seqCache[path] = (key, out)
        Self.seqCacheLock.unlock()
        return out
    }

    /// Read-only twin detection over the current ledger.
    func planConsolidation() -> [TwinPlan] {
        guard let store = try? LinkStoreIO.load() else { return [] }
        let claudeById = Dictionary(uniqueKeysWithValues:
            ClaudeIO.enumerateSessions().map { ($0.cliSessionId, $0) })
        return planConsolidation(store, claudeById: claudeById)
    }

    func planConsolidation(_ store: LinkStoreFile,
                           claudeById: [String: ClaudeSessionInfo]) -> [TwinPlan] {
        var rootCache: [String: String] = [:]
        func root(_ path: String) -> String? {
            if let c = rootCache[path] { return c.isEmpty ? nil : c }
            let r = ClaudeIO.rootUuid(path: path)
            rootCache[path] = r ?? ""
            return r
        }
        func stamp(_ rolloutPath: String) -> String? {
            // "rollout-2026-07-18T11-12-16-" — the second the thread was minted.
            let n = (rolloutPath as NSString).lastPathComponent
            guard n.hasPrefix("rollout-"), n.count > 28 else { return nil }
            return String(n.prefix(28))
        }
        func originator(_ rec: PairRecord) -> String? {
            CodexIO.rolloutOriginator(path: rec.codexRolloutPath)
        }
        /// Twin signature: same claude root uuid (prompt-edit fork twins), OR rollouts
        /// minted the same second with near-identical uuidv7 timestamps where at least
        /// one side is our own export (import-fork twins à la ChatGPT continue-fork).
        func isTwin(_ a: PairRecord, _ b: PairRecord) -> Bool {
            if let ra = root(a.claudeTranscriptPath), let rb = root(b.claudeTranscriptPath),
               ra == rb { return true }
            guard let sa = stamp(a.codexRolloutPath), let sb = stamp(b.codexRolloutPath),
                  sa == sb else { return false }
            let ha = a.codexThreadId.replacingOccurrences(of: "-", with: "").prefix(9)
            let hb = b.codexThreadId.replacingOccurrences(of: "-", with: "").prefix(9)
            guard ha == hb else { return false }
            return originator(a) == "claude_session_sync"
                || originator(b) == "claude_session_sync"
        }

        var plans: [TwinPlan] = []
        let byCwd = Dictionary(grouping: store.pairs.indices, by: { store.pairs[$0].cwd })
        for (_, idxs) in byCwd where idxs.count > 1 {
            // Connected components over the twin relation (groups are tiny).
            var groups: [[Int]] = []
            for i in idxs {
                if let g = groups.indices.first(where: { gi in
                    groups[gi].contains { isTwin(store.pairs[i], store.pairs[$0]) } }) {
                    groups[g].append(i)
                } else {
                    groups.append([i])
                }
            }
            for group in groups where group.count > 1 {
                let members = group.map { store.pairs[$0] }
                // Canonical codex thread: natively minted if any (earliest wins);
                // otherwise the one still being written to (latest rollout mtime).
                let native = members.filter {
                    let o = originator($0)
                    return o != nil && o != "claude_session_sync"
                }
                let canonical: PairRecord
                if !native.isEmpty {
                    canonical = native.min { $0.codexThreadId < $1.codexThreadId }!
                } else {
                    func mtime(_ p: String) -> Date {
                        (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate]
                            as? Date ?? .distantPast
                    }
                    canonical = members.max {
                        mtime($0.codexRolloutPath) < mtime($1.codexRolloutPath) }!
                }
                // Active claude session: the most recently touched among the members.
                let active = members.max {
                    (claudeById[$0.claudeSessionId]?.lastActivityAt ?? 0) <
                    (claudeById[$1.claudeSessionId]?.lastActivityAt ?? 0) }!
                var keepClaude = canonical.claudeSessionId
                var relink = false
                if active.claudeSessionId != canonical.claudeSessionId,
                   let ra = root(active.claudeTranscriptPath),
                   root(canonical.claudeTranscriptPath) == ra {
                    // The user's live file is a fork of the canonical transcript:
                    // the canonical pair adopts it and its divergent turns flow in.
                    keepClaude = active.claudeSessionId
                    relink = true
                }
                // Consolidation must be provably lossless in what it hides: every
                // dropped session is either a uuid-verified member of the kept file's
                // fork family (its extra tail is the branch the user abandoned, already
                // mirrored), or its user-turn sequence is a strict prefix of the kept
                // one (pure duplicate). Account-switch relics hold COMPLEMENTARY
                // halves with unrelated roots — those never qualify and stay visible.
                let keepPath = members.first { $0.claudeSessionId == keepClaude }
                    .map(\.claudeTranscriptPath)
                    ?? (claudeById[keepClaude]?.transcriptPath ?? "")
                let keepRoot = root(keepPath)
                let drops = members.map(\.claudeSessionId).filter { $0 != keepClaude }
                let provable = drops.allSatisfy { d in
                    guard let path = members.first(where: { $0.claudeSessionId == d })?
                        .claudeTranscriptPath else { return false }
                    if let r = root(path), let kr = keepRoot, r == kr { return true }
                    let dropSeq = userTurnSequence(path)
                    let keepSeq = userTurnSequence(keepPath)
                    return !keepSeq.isEmpty && dropSeq.count <= keepSeq.count
                        && Array(keepSeq.prefix(dropSeq.count)) == dropSeq
                }
                guard provable else { continue }

                let archiveIds = members.filter { $0.codexThreadId != canonical.codexThreadId }
                    .flatMap { [$0.codexThreadId] + ($0.codexSegments ?? []).map(\.threadId) }
                plans.append(TwinPlan(
                    title: canonical.title,
                    cwd: canonical.cwd,
                    keepClaudeId: keepClaude,
                    keepCodexId: canonical.codexThreadId,
                    relinkClaude: relink,
                    dropClaudeIds: drops,
                    archiveCodexIds: archiveIds,
                    dropPairIds: members.map(\.claudeSessionId)
                        .filter { $0 != canonical.claudeSessionId }))
            }
        }
        return plans
    }

    /// Applies every plan: archive the duplicate Codex threads (official RPC), fold the
    /// spurious ledger records into the canonical pair, hide the dead sidebar entries,
    /// then flow any divergent turns into the kept thread. Everything it removes from
    /// view stays on disk; the run backup covers the rest.
    func consolidateTwins() -> CodexSyncReport {
        withLedgerLock { consolidateInner() }
    }

    private func consolidateInner() -> CodexSyncReport {
        var report = CodexSyncReport()
        do {
            var store = try LinkStoreIO.load()
            if recover(&store) { try LinkStoreIO.save(store) }
            let claudeById = Dictionary(uniqueKeysWithValues:
                ClaudeIO.enumerateSessions().map { ($0.cliSessionId, $0) })
            let plans = planConsolidation(store, claudeById: claudeById)
            guard !plans.isEmpty else { return report }

            report.backupDir = try BackupManager.runBackup()

            let alreadyArchived = Set(CodexIO.enumerateThreads().filter(\.archived).map(\.id))
            for plan in plans {
                // Archive FIRST. If the RPC fails, leave this group fully untouched:
                // the still-present pair records keep the duplicates from re-importing.
                // Threads a previous run (or the user) already archived count as done.
                let toArchive = plan.archiveCodexIds.filter { !alreadyArchived.contains($0) }
                let archived = AppServerRPC.archiveThreads(toArchive)
                guard archived == toArchive.count else {
                    report.failed.append(CodexFailure(
                        title: plan.title, side: "codex",
                        reason: "archive RPC failed (\(archived)/\(toArchive.count) archived) — group left untouched, retry later"))
                    continue
                }
                var retiredCodex = store.retiredCodexThreadIds ?? []
                retiredCodex.append(contentsOf: plan.archiveCodexIds)
                store.retiredCodexThreadIds = retiredCodex

                store.pairs.removeAll { plan.dropPairIds.contains($0.claudeSessionId) }
                guard let ci = store.pairs.firstIndex(where: {
                    $0.codexThreadId == plan.keepCodexId }) else { continue }
                var rec = store.pairs[ci]
                var forkedFrom = rec.claudeForkedFrom ?? []
                if plan.relinkClaude, let info = claudeById[plan.keepClaudeId] {
                    let anc = ClaudeIO.uuidsInRegion(path: rec.claudeTranscriptPath,
                                                     upTo: rec.claude.byteOffset)
                    let div = ClaudeIO.forkDivergence(forkPath: info.transcriptPath,
                                                      ancestorUuids: anc)
                    forkedFrom.append(rec.claudeSessionId)
                    rec.claudeSessionId = info.cliSessionId
                    rec.claudeTranscriptPath = info.transcriptPath
                    rec.claude = SideCursor(byteOffset: div.byteOffset,
                                            lineCount: div.lineCount,
                                            lastEventId: div.lastSharedUuid ?? rec.claude.lastEventId)
                    if let u = div.lastSharedUuid { rec.claudeChainTail = u }
                }
                for d in plan.dropClaudeIds
                    where d != rec.claudeSessionId && !forkedFrom.contains(d) {
                    forkedFrom.append(d)
                }
                rec.claudeForkedFrom = forkedFrom.isEmpty ? nil : forkedFrom
                store.pairs[ci] = rec
                try LinkStoreIO.save(store)

                hideRetiredClaudeSessions(store)
                report.consolidatedGroups += 1
                report.wroteCodexSide = true
                report.wroteClaudeSide = true

                // Flow the divergent turns into the kept thread right away.
                if let idx = store.pairs.firstIndex(where: {
                    $0.codexThreadId == plan.keepCodexId }) {
                    do { try syncPair(at: idx, store: &store, report: &report) }
                    catch {
                        report.failed.append(CodexFailure(title: plan.title, side: "-",
                                                          reason: plainReason(error)))
                    }
                }
                try LinkStoreIO.save(store)
            }
        } catch {
            report.failed.append(CodexFailure(title: "consolidate", side: "-",
                                              reason: plainReason(error)))
        }
        return report
    }
}

// MARK: - Integrity doctor

struct PairIssue: Identifiable {
    let id = UUID()
    let pairTitle: String
    let side: String                  // "claude" | "codex" | "ledger"
    let detail: String
}

extension CodexEngine {
    /// Structural validation of every pair — the guard against broken sessions
    /// compounding across ping-pong syncs. Read-only.
    func verifyAll() -> [PairIssue] {
        var issues: [PairIssue] = []
        guard let store = try? LinkStoreIO.load() else {
            return [PairIssue(pairTitle: "ledger", side: "ledger",
                              detail: "codex-links.json unreadable")]
        }
        let fm = FileManager.default

        for rec in store.pairs {
            let title = rec.title

            // Ledger vs disk coherence.
            let cSize = (try? fm.attributesOfItem(atPath: rec.claudeTranscriptPath))?[.size] as? Int64
            let xSize = (try? fm.attributesOfItem(atPath: rec.codexRolloutPath))?[.size] as? Int64
            if cSize == nil { issues.append(.init(pairTitle: title, side: "claude",
                                                  detail: "transcript missing on disk")) }
            if xSize == nil { issues.append(.init(pairTitle: title, side: "codex",
                                                  detail: "rollout missing on disk")) }
            if let c = cSize, c < rec.claude.byteOffset {
                issues.append(.init(pairTitle: title, side: "ledger",
                                    detail: "claude cursor beyond file size (rewritten?)"))
            }
            if let x = xSize, x < rec.codex.byteOffset {
                issues.append(.init(pairTitle: title, side: "ledger",
                                    detail: "codex cursor beyond file size (rewritten?)"))
            }
            if rec.inFlight != nil {
                issues.append(.init(pairTitle: title, side: "ledger",
                                    detail: "unrecovered in-flight write intent"))
            }
            for seg in rec.codexSegments ?? [] {
                guard let size = (try? fm.attributesOfItem(atPath: seg.rolloutPath))?[.size] as? Int64 else {
                    issues.append(.init(pairTitle: title, side: "codex",
                                        detail: "chain segment rollout missing on disk"))
                    continue
                }
                if size < seg.cursor.byteOffset {
                    issues.append(.init(pairTitle: title, side: "ledger",
                                        detail: "segment cursor beyond file size (rewritten?)"))
                }
            }

            // Claude transcript: uuid chain + tool_use/tool_result pairing.
            // Calibrated against native reality: compaction legitimately prunes chain
            // heads and retries fork the DAG, so the strict parent check applies only
            // to lines WE wrote; and the last tool_use of a live session is allowed to
            // be momentarily unpaired (its result simply hasn't landed yet).
            if cSize != nil {
                var allUuids = Set<String>()
                var ourOrphanParents = 0
                var pendingOurParents: [String] = []   // our lines' parents, checked after pass
                var toolUseLine: [String: Int] = [:]   // id → line index of the use
                var toolResults = Set<String>()
                var lastToolUseLineIdx = -1
                var lineIdx = -1
                var chainTailSeen = rec.claudeChainTail == nil
                _ = try? ClaudeIO.streamLines(path: rec.claudeTranscriptPath) { line in
                    lineIdx += 1
                    if let u = line.uuid {
                        allUuids.insert(u)
                        if u == rec.claudeChainTail { chainTailSeen = true }
                        if line.syncOrigin != nil, let p = line.parentUuid, !p.isEmpty {
                            pendingOurParents.append(p)
                        }
                    }
                    guard let items = line.message?["content"] as? [[String: Any]] else { return }
                    for item in items {
                        switch item["type"] as? String {
                        case "tool_use":
                            if let id = item["id"] as? String {
                                toolUseLine[id] = lineIdx
                                lastToolUseLineIdx = lineIdx
                            }
                        case "tool_result":
                            if let id = item["tool_use_id"] as? String { toolResults.insert(id) }
                        default: break
                        }
                    }
                }
                ourOrphanParents = pendingOurParents.filter { !allUuids.contains($0) }.count
                if ourOrphanParents > 0 {
                    issues.append(.init(pairTitle: title, side: "claude",
                                        detail: "\(ourOrphanParents) synced lines with unknown parentUuid"))
                }
                // Unpaired uses are broken only when a LATER tool_use exists (i.e. the
                // conversation moved on without the result) — a trailing one is in flight.
                let broken = toolUseLine.filter { !toolResults.contains($0.key)
                                                  && $0.value < lastToolUseLineIdx }
                if !broken.isEmpty {
                    issues.append(.init(pairTitle: title, side: "claude",
                                        detail: "\(broken.count) tool_use without tool_result (breaks resume)"))
                }
                if !chainTailSeen {
                    issues.append(.init(pairTitle: title, side: "ledger",
                                        detail: "chain tail uuid not present in transcript"))
                }
            }

            // Codex rollout: session_meta identity + turn balance.
            if xSize != nil {
                var metaId: String?
                var started = 0, completed = 0
                _ = try? CodexIO.streamLines(path: rec.codexRolloutPath) { line in
                    if metaId == nil, line.type == "session_meta" {
                        metaId = line.payload["id"] as? String
                    }
                    if line.type == "event_msg" {
                        if line.payloadType == "task_started" { started += 1 }
                        if line.payloadType == "task_complete" { completed += 1 }
                    }
                }
                if metaId == nil {
                    issues.append(.init(pairTitle: title, side: "codex",
                                        detail: "rollout has no session_meta"))
                } else if metaId != rec.codexThreadId {
                    issues.append(.init(pairTitle: title, side: "codex",
                                        detail: "session_meta id ≠ thread id"))
                }
                if started < completed {
                    issues.append(.init(pairTitle: title, side: "codex",
                                        detail: "more task_complete than task_started"))
                }
            }
        }
        return issues
    }
}

func isoFractional(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s)
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
                if let segs = intent.postSegments { store.pairs[i].codexSegments = segs }
                store.pairs[i].state = PairState.synced.rawValue
                store.pairs[i].inFlight = nil
                dirty = true
            } else if let size, size == intent.baseOffset {
                // Never started.
                store.pairs[i].inFlight = nil
                dirty = true
            }
            else if let started = ISO8601DateFormatter().date(from: intent.startedAt)
                        ?? isoFractional(intent.startedAt),
                    Date().timeIntervalSince(started) > 3600 {
                // Stale partial write (crash mid-append over an hour ago, region never
                // matched): without an escape the pair loops in "interrupted write"
                // forever. Re-baseline: cursors to live sizes, the ambiguous region
                // recorded as skipped — bytes stay in the file, nothing is mirrored.
                let fm = FileManager.default
                if let size = (try? fm.attributesOfItem(atPath: intent.targetPath))?[.size] as? Int64 {
                    store.pairs[i].skipped.append(SkippedRange(
                        side: intent.targetSide, reason: "stale-interrupted-write",
                        at: isoNow(), fromByte: intent.baseOffset, toByte: size))
                    if intent.targetSide == "claude" {
                        store.pairs[i].claude.byteOffset = size
                    } else if intent.targetPath == store.pairs[i].codexRolloutPath {
                        store.pairs[i].codex.byteOffset = size
                    } else if var segs = store.pairs[i].codexSegments,
                              let si = segs.firstIndex(where: { $0.rolloutPath == intent.targetPath }) {
                        segs[si].cursor.byteOffset = size
                        store.pairs[i].codexSegments = segs
                    }
                    store.pairs[i].inFlight = nil
                    dirty = true
                }
            }
            // Fresh partial writes stay flagged; scan reports them as conflict.
        }
        return dirty
    }

    /// Entry point for a single row (manual Sync / Import buttons; M4 loops over this).
    func syncRow(id: String) -> CodexSyncReport {
        withLedgerLock { syncRowInner(id: id) }
    }

    private func syncRowInner(id: String) -> CodexSyncReport {
        var report = CodexSyncReport()
        do {
            var store = try LinkStoreIO.load()
            if recover(&store) { try LinkStoreIO.save(store) }
            let codexById = Dictionary(uniqueKeysWithValues:
                CodexIO.enumerateThreads().map { ($0.id, $0) })
            if healRolloutPaths(&store, codexById: codexById) { try LinkStoreIO.save(store) }
            if attachNewSegments(&store, codexById: codexById) { try LinkStoreIO.save(store) }
            // A watcher event can arrive before any scan saw the fork file: adopt here
            // too, or the fallback below would import it as a twin thread.
            let claudeById = Dictionary(uniqueKeysWithValues:
                ClaudeIO.enumerateSessions().map { ($0.cliSessionId, $0) })
            if adoptClaudeForks(&store, claudeById: claudeById) { try LinkStoreIO.save(store) }
            // Consolidated duplicates: if the user unarchives one, never re-import it.
            if (store.retiredCodexThreadIds ?? []).contains(id) { return report }

            report.backupDir = try BackupManager.runBackup()
            hideRetiredClaudeSessions(store)

            if let idx = store.pairs.firstIndex(where: {
                $0.claudeSessionId == id || $0.codexThreadId == id
                    || ($0.codexSegments ?? []).contains(where: { $0.threadId == id })
                    || ($0.claudeForkedFrom ?? []).contains(id) }) {
                try syncPair(at: idx, store: &store, report: &report)
            } else if let claude = claudeById[id] {
                try importClaude(claude, store: &store, report: &report)
            } else if let codex = CodexIO.enumerateThreads().first(where: { $0.id == id }) {
                // Never import a chain CHILD as a standalone chat: resolve to its root.
                let chains = buildChains(Dictionary(uniqueKeysWithValues:
                    CodexIO.enumerateThreads().map { ($0.id, $0) }))
                if chains[codex.id] == nil,
                   let rootId = chains.first(where: { $0.value.children.contains { $0.id == codex.id } })?.key {
                    if let idx = store.pairs.firstIndex(where: { $0.codexThreadId == rootId }) {
                        try syncPair(at: idx, store: &store, report: &report)
                    } else if let root = CodexIO.enumerateThreads().first(where: { $0.id == rootId }) {
                        try importCodex(root, store: &store, report: &report)
                    }
                } else {
                    try importCodex(codex, store: &store, report: &report)
                }
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
        withLedgerLock { syncAllInner(progress: progress) }
    }

    private func syncAllInner(progress: @escaping (BulkProgress) -> Void) -> CodexSyncReport {
        var report = CodexSyncReport()
        do {
            // Scan FIRST: it persists recover/heal/attach repairs. Loading before it
            // (as this code once did) meant iterating a stale snapshot and saving it
            // back per pair — silently reverting every repair the scan just made.
            let rows = scanInner().rows
            var store = try LinkStoreIO.load()
            let actionable = rows.filter {
                $0.isPending || $0.state == .unlinkedClaude || $0.state == .unlinkedCodex
            }
            report.skippedConflicts = rows.filter { $0.state == .conflict }.count
            guard !actionable.isEmpty else { return report }

            report.backupDir = try BackupManager.runBackup()
            hideRetiredClaudeSessions(store)

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
                        $0.claudeSessionId == row.id || $0.codexThreadId == row.id
                            || ($0.claudeForkedFrom ?? []).contains(row.id) }) {
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
            _ = archiveStaleForkThreads()
        } catch {
            report.failed.append(CodexFailure(title: "run", side: "-", reason: plainReason(error)))
        }
        return report
    }

    // MARK: Conflict resolution

    /// The chosen side's new region is mirrored; the losing side's new region stays in
    /// its own transcript but is recorded as skipped and never mirrored.
    func resolve(id: String, winner: SyncDirection) -> CodexSyncReport {
        withLedgerLock { resolveInner(id: id, winner: winner) }
    }

    private func resolveInner(id: String, winner: SyncDirection) -> CodexSyncReport {
        var report = CodexSyncReport()
        do {
            var store = try LinkStoreIO.load()
            if recover(&store) { try LinkStoreIO.save(store) }
            let codexById = Dictionary(uniqueKeysWithValues:
                CodexIO.enumerateThreads().map { ($0.id, $0) })
            if healRolloutPaths(&store, codexById: codexById) { try LinkStoreIO.save(store) }
            if attachNewSegments(&store, codexById: codexById) { try LinkStoreIO.save(store) }
            guard let idx = store.pairs.firstIndex(where: {
                $0.claudeSessionId == id || $0.codexThreadId == id
                    || ($0.claudeForkedFrom ?? []).contains(id) }) else {
                throw EngineError.rowNotFound
            }
            if store.pairs[idx].inFlight != nil { throw EngineError.interruptedWrite }
            // Revalidate against live disk state: the sheet's snapshot may be stale
            // (another run advanced or resolved this pair while it was open). A blind
            // fast-forward here would swallow legitimate new turns into skipped ranges.
            do {
                let rec0 = store.pairs[idx]
                let cs = (try? FileManager.default.attributesOfItem(
                    atPath: rec0.claudeTranscriptPath))?[.size] as? Int64 ?? 0
                let h = chainHealth(rec0)
                let claudeGrew0 = cs > rec0.claude.byteOffset
                guard claudeGrew0 && h.grew else {
                    throw EngineError.conflictNeedsResolve(
                        "no longer in conflict — refresh and retry")
                }
            }
            report.backupDir = try BackupManager.runBackup()

            var rec = store.pairs[idx]
            let fm = FileManager.default
            let claudeSize = (try? fm.attributesOfItem(atPath: rec.claudeTranscriptPath))?[.size] as? Int64 ?? 0
            let codexSize = (try? fm.attributesOfItem(atPath: rec.codexRolloutPath))?[.size] as? Int64 ?? 0

            switch winner {
            case .toCodex:
                // Loser = Codex's foreign tail: record and fast-forward past it —
                // on the root AND on every chain segment, or the skipped content
                // would sync (duplicate) on the next pass.
                if codexSize > rec.codex.byteOffset {
                    rec.skipped.append(SkippedRange(side: "codex", reason: "conflict-resolution",
                                                    at: isoNow(),
                                                    fromByte: rec.codex.byteOffset, toByte: codexSize))
                    rec.codex.byteOffset = codexSize
                }
                if var segs = rec.codexSegments {
                    for si in segs.indices {
                        let size = (try? fm.attributesOfItem(atPath: segs[si].rolloutPath))?[.size] as? Int64 ?? 0
                        if size > segs[si].cursor.byteOffset {
                            rec.skipped.append(SkippedRange(
                                side: "codex", reason: "conflict-resolution", at: isoNow(),
                                fromByte: segs[si].cursor.byteOffset, toByte: size))
                            segs[si].cursor.byteOffset = size
                        }
                    }
                    rec.codexSegments = segs
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
                        guard !line.isSidechain, line.type == "user" || line.type == "assistant",
                              let u = line.uuid else { return }
                        lastUuid = u
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
        CodexWriter.topUpWorkspaceHints()
        CodexWriter.topUpProjects()
        report.wroteCodexSide = true

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
            inFlight: nil,
            codexSegments: nil))
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

        // The whole fork chain (root + continuation segments) becomes ONE session —
        // exactly how the ChatGPT UI presents it.
        let chain = buildChains(Dictionary(uniqueKeysWithValues:
            CodexIO.enumerateThreads().map { ($0.id, $0) }))[t.id]
        let children = chain?.children ?? []

        var consumed: Int64 = 0
        var segments: [ChainSegment] = []
        var claudeLineCount = 0
        let transcriptPath = try ClaudeWriter.createTranscript(sessionId: claudeId, cwd: cwd) { write in
            var pendingError: Error?
            emitter.beginSegment(dedupReplay: false)
            consumed = try CodexIO.streamLines(path: t.rolloutPath) { line in
                guard pendingError == nil else { return }
                let out = emitter.feed(line)
                if !out.isEmpty {
                    do { try write(out); claudeLineCount += out.count }
                    catch { pendingError = error }
                }
            }
            if let e = pendingError { throw e }
            for kid in children {
                emitter.beginSegment(dedupReplay: true)     // children may replay history
                let segConsumed = try CodexIO.streamLines(path: kid.rolloutPath) { line in
                    guard pendingError == nil else { return }
                    let out = emitter.feed(line)
                    if !out.isEmpty {
                        do { try write(out); claudeLineCount += out.count }
                        catch { pendingError = error }
                    }
                }
                if let e = pendingError { throw e }
                segments.append(ChainSegment(
                    threadId: kid.id, rolloutPath: kid.rolloutPath,
                    cursor: SideCursor(byteOffset: segConsumed, lineCount: 0,
                                       lastEventId: emitter.stats.lastTimestamp)))
            }
            let tail = emitter.finish()             // settle any dangling tool calls
            if !tail.isEmpty {
                try write(tail)
                claudeLineCount += tail.count
            }
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
            inFlight: nil,
            codexSegments: segments.isEmpty ? nil : segments))
        report.wroteClaudeSide = true
        report.created += 1
    }

    // MARK: Incremental sync of an existing pair

    func syncPair(at idx: Int, store: inout LinkStoreFile,
                  report: inout CodexSyncReport) throws {
        let rec = store.pairs[idx]
        if rec.inFlight != nil { throw EngineError.interruptedWrite }

        let fm = FileManager.default
        let claudeSize = (try? fm.attributesOfItem(atPath: rec.claudeTranscriptPath))?[.size] as? Int64 ?? -1
        let claudeGrew = claudeSize > rec.claude.byteOffset
        let health = chainHealth(rec)

        if claudeSize < rec.claude.byteOffset || health.shrunk {
            throw EngineError.conflictNeedsResolve("a side was rewritten")
        }
        // Never convert an open turn: a long tool keeps the file quiet past the
        // debounce window, but the tail says the agent is still working — skip this
        // round; the next quiescence (or the staleness cap) will pick it up whole.
        let fmDate: (String) -> Date? = {
            (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }
        switch (claudeGrew, health.grew) {
        case (true, true): throw EngineError.conflictNeedsResolve("both sides advanced")
        case (true, false):
            guard !ClaudeIO.turnInFlight(path: rec.claudeTranscriptPath,
                                         mtime: fmDate(rec.claudeTranscriptPath)) else { return }
            try incrementalToCodex(at: idx, store: &store, report: &report)
        case (false, true):
            let leaf = leafSegment(rec)
            guard !CodexIO.turnInFlight(path: leaf.path, mtime: fmDate(leaf.path)) else { return }
            try incrementalToClaude(at: idx, store: &store, report: &report)
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
            // Nothing convertible (system/attachment noise): just advance the cursor —
            // including the chain tail, or a later Codex→Claude append would parent
            // onto a stale uuid and fork the mirrored DAG.
            rec.claude = newClaude
            if let u = emitter.stats.lastConsumedUuid { rec.claudeChainTail = u }
            rec.state = PairState.synced.rawValue
            rec.lastSyncAt = isoNow()
            store.pairs[idx] = rec
            return
        }

        let data = serializeJSONL(lines)
        // Claude→Codex appends land on the chain's active LEAF — that is the thread
        // the ChatGPT UI shows as "the" conversation.
        let leaf = leafSegment(rec)
        let base = (try? FileManager.default.attributesOfItem(atPath: leaf.path))?[.size] as? Int64 ?? 0
        var postCodex = rec.codex
        var postSegments = rec.codexSegments
        if leaf.threadId == rec.codexThreadId {
            postCodex = SideCursor(byteOffset: base + Int64(data.count),
                                   lineCount: rec.codex.lineCount + lines.count,
                                   lastEventId: emitter.stats.lastTimestamp)
        } else if var segs = postSegments,
                  let li = segs.firstIndex(where: { $0.threadId == leaf.threadId }) {
            segs[li].cursor = SideCursor(byteOffset: base + Int64(data.count),
                                         lineCount: segs[li].cursor.lineCount + lines.count,
                                         lastEventId: emitter.stats.lastTimestamp)
            postSegments = segs
        }
        rec.inFlight = WriteIntent(
            targetSide: "codex", targetPath: leaf.path,
            baseOffset: base, length: Int64(data.count),
            payloadSHA256: sha256Hex(data), startedAt: isoNow(),
            postClaude: newClaude,
            postCodex: postCodex,
            postChainTail: emitter.stats.lastConsumedUuid ?? rec.claudeChainTail,
            postTurnIndex: emitter.nextTurnIndex,
            postEmitIndex: rec.claudeEmitIndex,
            postSegments: postSegments)
        store.pairs[idx] = rec
        try LinkStoreIO.save(store)                          // intent durable before the write

        do {
            _ = try appendJSONL(path: leaf.path, data: data, expectedEnd: base)
        } catch AppendError.targetMoved {
            // The native writer appended between our size probe and the write: writing
            // now would poison the cursor. Clear the intent, skip this round; the next
            // quiescence re-reads a settled file.
            rec.inFlight = nil
            store.pairs[idx] = rec
            try LinkStoreIO.save(store)
            return
        }
        try? CodexWriter.touchThread(id: leaf.threadId,
                                     updatedAtMs: Int(Date().timeIntervalSince1970 * 1000))

        rec.claude = rec.inFlight!.postClaude
        rec.codex = rec.inFlight!.postCodex
        rec.claudeChainTail = rec.inFlight!.postChainTail
        rec.codexTurnIndex = rec.inFlight!.postTurnIndex
        if let segs = rec.inFlight!.postSegments { rec.codexSegments = segs }
        rec.inFlight = nil
        rec.state = PairState.synced.rawValue
        rec.lastSyncAt = isoNow()
        store.pairs[idx] = rec
        report.wroteCodexSide = true
        report.updated += 1
    }

    func incrementalToClaude(at idx: Int, store: inout LinkStoreFile,
                             report: inout CodexSyncReport) throws {
        var rec = store.pairs[idx]
        let fm = FileManager.default
        let model = CodexIO.enumerateThreads().first { $0.id == rec.codexThreadId }?.model
            ?? "codex-import"
        let emitter = CodexToClaudeEmitter(claudeSessionId: rec.claudeSessionId,
                                           codexId: rec.codexThreadId,
                                           cwd: rec.cwd, model: model,
                                           chainTail: rec.claudeChainTail,
                                           startLineIndex: rec.claudeEmitIndex)

        // Fork children starting from zero may replay the parent's history: seed the
        // dedup with the user turns already present in the Claude transcript.
        let segments = rec.codexSegments ?? []
        let anyFreshSegment = segments.contains { $0.cursor.byteOffset == 0 }
        if anyFreshSegment {
            var ordered: [Int] = []
            _ = try? ClaudeIO.streamLines(path: rec.claudeTranscriptPath) { line in
                guard line.type == "user", !line.isMeta, !line.isSidechain,
                      let c = line.message?["content"] else { return }
                // Interruption artifacts are excluded from BOTH emission paths, so the
                // seed must exclude them too or the replay sequences drift apart.
                if let s = c as? String {
                    if !isInterruptionArtifact(s) {
                        ordered.append(CodexToClaudeEmitter.normalizedHash(s))
                    }
                } else if let items = c as? [[String: Any]] {
                    let text = items.filter { ($0["type"] as? String) == "text" }
                        .compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if !text.isEmpty, !isInterruptionArtifact(text) {
                        ordered.append(CodexToClaudeEmitter.normalizedHash(text))
                    }
                }
            }
            emitter.seedEmittedUserSequence(ordered)
        }

        // Consume root first, then every chain segment in creation order.
        var lines: [[String: Any]] = []
        var newCodex = rec.codex
        let rootSize = (try? fm.attributesOfItem(atPath: rec.codexRolloutPath))?[.size] as? Int64 ?? 0
        if rootSize > rec.codex.byteOffset {
            emitter.beginSegment(dedupReplay: false)
            let consumed = try CodexIO.streamLines(path: rec.codexRolloutPath,
                                                   from: rec.codex.byteOffset) { line in
                lines.append(contentsOf: emitter.feed(line))
            }
            newCodex = SideCursor(byteOffset: consumed,
                                  lineCount: rec.codex.lineCount + emitter.stats.consumedLineCount,
                                  lastEventId: emitter.stats.lastTimestamp)
        }
        var newSegments = segments
        for si in segments.indices {
            let seg = segments[si]
            let size = (try? fm.attributesOfItem(atPath: seg.rolloutPath))?[.size] as? Int64 ?? 0
            guard size > seg.cursor.byteOffset else { continue }
            emitter.beginSegment(dedupReplay: seg.cursor.byteOffset == 0)
            let before = emitter.stats.consumedLineCount
            let consumed = try CodexIO.streamLines(path: seg.rolloutPath,
                                                   from: seg.cursor.byteOffset) { line in
                lines.append(contentsOf: emitter.feed(line))
            }
            newSegments[si].cursor = SideCursor(
                byteOffset: consumed,
                lineCount: seg.cursor.lineCount + (emitter.stats.consumedLineCount - before),
                lastEventId: emitter.stats.lastTimestamp)
        }

        if emitter.hasPendingCalls {
            // A tool call is still awaiting its output (long-running tool caught by the
            // quiescence window). Don't fabricate a result — skip this round entirely;
            // the next scan re-reads the same region once the turn has settled.
            return
        }

        guard !lines.isEmpty else {
            rec.codex = newCodex
            rec.codexSegments = segments.isEmpty ? rec.codexSegments : newSegments
            rec.state = PairState.synced.rawValue
            rec.lastSyncAt = isoNow()
            store.pairs[idx] = rec
            return
        }

        let data = serializeJSONL(lines)
        let base = (try? fm.attributesOfItem(atPath: rec.claudeTranscriptPath))?[.size] as? Int64 ?? 0
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
            postEmitIndex: emitter.nextLineIndex,
            postSegments: segments.isEmpty ? nil : newSegments)
        store.pairs[idx] = rec
        try LinkStoreIO.save(store)

        do {
            _ = try appendJSONL(path: rec.claudeTranscriptPath, data: data, expectedEnd: base)
        } catch AppendError.targetMoved {
            rec.inFlight = nil
            store.pairs[idx] = rec
            try LinkStoreIO.save(store)
            return
        }
        ClaudeWriter.touchIndexEntry(cliSessionId: rec.claudeSessionId,
                                     lastActivityAtMs: Int(Date().timeIntervalSince1970 * 1000))

        rec.claude = rec.inFlight!.postClaude
        rec.codex = rec.inFlight!.postCodex
        rec.claudeChainTail = rec.inFlight!.postChainTail
        rec.claudeEmitIndex = rec.inFlight!.postEmitIndex
        if let segs = rec.inFlight!.postSegments { rec.codexSegments = segs }
        rec.inFlight = nil
        rec.state = PairState.synced.rawValue
        rec.lastSyncAt = isoNow()
        store.pairs[idx] = rec
        report.wroteClaudeSide = true
        report.updated += 1
    }
}
