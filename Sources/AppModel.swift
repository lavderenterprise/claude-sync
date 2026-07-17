import SwiftUI
import Combine

/// Root model, App-scoped: it outlives the window so anything with background duties
/// (Codex store for the menu bar badge, the FSEvents watcher, the auto-sync coordinator)
/// hangs off this object. The Accounts `Store` stays view-owned — it has no background role.
@MainActor final class AppModel: ObservableObject {
    @Published var selectedTab: AppTab = .accounts
    let codex = CodexStore()

    private let watcher = SessionWatcher()
    private let debouncer = Debouncer()
    private var forwarder: AnyCancellable?

    init() {
        // Re-publish CodexStore changes so App-level consumers (menu bar badge) update
        // even when no window exists.
        forwarder = codex.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        // Engine writes land in the watched trees: pause the watcher during any sync
        // and keep it paused through the FSEvents latency window afterwards.
        // Counted pause with a per-run balance: run A's delayed unpause can no longer
        // fire while run B is still writing (the old single Bool had exactly that hole).
        codex.willWrite = { [weak self] in self?.watcher.beginPause() }
        codex.didWrite = { [weak self] in
            // Keep the pause through the FSEvents latency window before balancing it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                self?.watcher.endPause()
            }
        }

        settingsChanged()
    }

    var badgeCount: Int { codex.badgeCount }

    private var autoSyncEnabled: Bool {
        UserDefaults.standard.bool(forKey: "autoSyncEnabled")
    }
    private var showMenuBarExtra: Bool {
        UserDefaults.standard.object(forKey: "showMenuBarExtra") as? Bool ?? true
    }
    private var quiescenceSeconds: Double {
        let v = UserDefaults.standard.double(forKey: "quiescenceSeconds")
        return v == 0 ? 20 : v
    }

    /// Watcher runs iff something consumes its events: auto-sync, or the menu bar badge
    /// (which must stay fresh with the window closed). Both off → zero wakeups.
    func settingsChanged() {
        Task { await debouncer.setQuiescence(seconds: quiescenceSeconds) }

        let wanted = autoSyncEnabled || showMenuBarExtra
        if wanted && !watcher.isRunning {
            watcher.start(
                roots: [CLAUDE_HOME.appending(path: "projects"), CodexPaths.sessionsDir],
                onEvent: { [weak self] path in
                    guard let self else { return }
                    Task {
                        guard let key = await self.pairKey(forChangedPath: path) else { return }
                        await self.debouncer.bump(key: key) { k in
                            Task { @MainActor in self.quiescent(k) }
                        }
                    }
                },
                onOverflow: { [weak self] in
                    Task { @MainActor in self?.codex.reload() }
                })
        } else if !wanted && watcher.isRunning {
            watcher.stop()
            Task { await debouncer.cancelAll() }
        }
    }

    /// Changed file → pair key. Transcript stem IS the claude session id; a rollout
    /// filename ends with the thread uuid. Ledger pairs map either to the claude id
    /// (= row key); unlinked sessions map to themselves (auto-import on first reply).
    nonisolated private func pairKey(forChangedPath path: String) async -> String? {
        let name = (path as NSString).lastPathComponent
        guard name.hasSuffix(".jsonl") else { return nil }
        let stem = String(name.dropLast(6))

        // Prefix checks against the ACTUAL roots (CODEX_HOME may relocate ~/.codex).
        if path.hasPrefix(CLAUDE_HOME.appending(path: "projects").path) {
            guard stem.count == 36 else { return nil }        // subagent/aux files differ
            return stem
        }
        if path.hasPrefix(CodexPaths.sessionsDir.path) {
            guard stem.hasPrefix("rollout-"), stem.count > 36 else { return nil }
            let codexId = String(stem.suffix(36))
            if let store = try? LinkStoreIO.load(),
               let pair = store.pairs.first(where: {
                   $0.codexThreadId == codexId
                       || ($0.codexSegments ?? []).contains(where: { $0.threadId == codexId }) }) {
                // A chain child's event belongs to its root's pair — never a new import.
                return pair.claudeSessionId
            }
            return codexId
        }
        return nil
    }

    /// Quiescence fired: the session stopped changing for the configured window.
    private func quiescent(_ key: String) {
        guard !codex.busy else {
            // Busy run in progress: re-check later rather than dropping the event.
            Task { await debouncer.bump(key: key) { k in
                Task { @MainActor in self.quiescent(k) }
            } }
            return
        }
        if autoSyncEnabled {
            codex.autoSync(id: key)          // conflicts are never auto-resolved inside
        } else {
            codex.reload()                   // menu-bar-only mode: keep the badge fresh
        }
    }
}
