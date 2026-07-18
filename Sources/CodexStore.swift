import SwiftUI

@MainActor final class CodexStore: ObservableObject {
    @Published var rows: [PairRow] = []
    @Published var busy = false
    @Published var fatal: CodexFatal?
    @Published var codexRunning = false
    @Published var claudeRunning = false
    @Published var schemaVersion: Int?
    @Published var report: CodexSyncReport?
    @Published var bulk: (done: Int, total: Int, current: String)?
    @Published var twinPlans: [TwinPlan] = []

    let engine = CodexEngine()

    /// Watcher-pause hooks, set by AppModel: called around every disk-writing run so
    /// the FSEvents watcher never reacts to our own writes.
    var willWrite: (() -> Void)?
    var didWrite: (() -> Void)?

    var syncedCount: Int { rows.filter { $0.state == .synced }.count }
    var toCodexCount: Int { rows.filter { $0.state == .pendingToCodex }.count }
    var toClaudeCount: Int { rows.filter { $0.state == .pendingToClaude }.count }
    var conflictCount: Int { rows.filter { $0.state == .conflict }.count }
    var unlinkedCount: Int {
        rows.filter { $0.state == .unlinkedClaude || $0.state == .unlinkedCodex }.count
    }
    var pairCount: Int { rows.count - unlinkedCount }

    /// Menu bar badge: work that needs the user (or one click) to move.
    var badgeCount: Int { toCodexCount + toClaudeCount + conflictCount }

    var schemaDrifted: Bool {
        if let v = schemaVersion, v != CodexPaths.validatedSchemaVersion { return true }
        return false
    }

    func reload() {
        guard !busy else { return }
        busy = true
        let engine = self.engine
        Task.detached(priority: .userInitiated) {
            let result = engine.scan()
            let plans = engine.planConsolidation()
            let codexUp = CodexIO.codexIsRunning()
            let claudeUp = claudeIsRunning()
            await MainActor.run {
                self.rows = result.rows
                self.fatal = result.fatal
                self.schemaVersion = result.schemaVersion
                self.twinPlans = plans
                self.codexRunning = codexUp
                self.claudeRunning = claudeUp
                self.busy = false
            }
        }
    }

    /// Fold every detected duplicated chat into a single unified one (backup runs
    /// first inside the engine; duplicates are archived/hidden, never deleted).
    func consolidate() {
        run { $0.consolidateTwins() }
    }

    /// Sync/import a single row (writes to disk — backup runs first inside the engine).
    func syncRow(_ row: PairRow) {
        run { $0.syncRow(id: row.id) }
    }

    /// Everything actionable in one run, with live progress (mass import + catch-up).
    func syncAll() {
        guard !busy else { return }
        bulk = (0, max(actionableCount, 1), "")
        run { engine in
            engine.syncAll { p in
                Task { @MainActor in self.bulk = (p.done, p.total, p.current) }
            }
        }
    }

    func resolve(_ row: PairRow, winner: SyncDirection) {
        run { $0.resolve(id: row.id, winner: winner) }
    }

    /// Watcher-triggered sync: silent — no result sheet; failures surface only through
    /// pair states and the badge. Conflicts are never auto-resolved by construction
    /// (the engine turns a conflicted pair into a failure that we drop here).
    func autoSync(id: String) {
        run(silent: true) { $0.syncRow(id: id) }
    }

    private func run(silent: Bool = false, _ op: @escaping (CodexEngine) -> CodexSyncReport) {
        guard !busy else { return }
        busy = true
        willWrite?()
        let engine = self.engine
        Task.detached(priority: .userInitiated) {
            let rep = op(engine)
            await MainActor.run {
                self.bulk = nil
                if !silent { self.report = rep }
                self.busy = false
                self.didWrite?()
                self.reload()
            }
        }
    }

    var actionableCount: Int {
        rows.filter { $0.isPending || $0.state == .unlinkedClaude || $0.state == .unlinkedCodex }.count
    }

    @Published var verifyResult: VerifyResult?

    struct VerifyResult: Identifiable {
        let issues: [PairIssue]
        let pairsChecked: Int
        var id: String { "\(pairsChecked)-\(issues.count)" }
    }

    /// Read-only structural validation of every pair (the "doctor").
    func verify() {
        guard !busy else { return }
        busy = true
        let engine = self.engine
        let count = rows.count
        Task.detached(priority: .userInitiated) {
            let issues = engine.verifyAll()
            await MainActor.run {
                self.verifyResult = VerifyResult(issues: issues, pairsChecked: count)
                self.busy = false
            }
        }
    }
}
