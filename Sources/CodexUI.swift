import SwiftUI

enum CodexFilter: String, CaseIterable, Identifiable {
    case all = "All", pending = "Pending", conflicts = "Conflicts", unlinked = "Unlinked"
    var id: Self { self }
}

struct CodexView: View {
    @EnvironmentObject var app: AppModel
    var body: some View { CodexContent(store: app.codex) }
}

/// One `.sheet` per view (same rationale as `Route` in UI.swift).
enum CodexRoute: Identifiable {
    case confirmAll
    case resolve(PairRow)
    case result(CodexSyncReport)

    var id: String {
        switch self {
        case .confirmAll: "confirmAll"
        case .resolve(let r): "resolve-" + r.id
        case .result(let rep): "result-" + rep.id
        }
    }
}

struct CodexContent: View {
    @ObservedObject var store: CodexStore
    @State private var filter: CodexFilter = .all
    @State private var route: CodexRoute?

    var rows: [PairRow] {
        switch filter {
        case .all: store.rows
        case .pending: store.rows.filter(\.isPending)
        case .conflicts: store.rows.filter { $0.state == .conflict }
        case .unlinked: store.rows.filter {
            $0.state == .unlinkedClaude || $0.state == .unlinkedCodex
        }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            table
            Divider()
            statusBar
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.reload() } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(store.busy)
                .help("Re-scan both sides from disk")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { route = .confirmAll } label: {
                    Label(store.actionableCount == 0 ? "Sync all"
                          : "Sync all (\(store.actionableCount))",
                          systemImage: "arrow.left.arrow.right")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.busy || store.actionableCount == 0)
                .help("Import every unlinked session and sync every pending pair")
            }
        }
        .onAppear { if store.rows.isEmpty { store.reload() } }
        .sheet(item: $route) { r in
            switch r {
            case .confirmAll:
                ConfirmAllSheet(store: store) { store.syncAll() }
            case .resolve(let row):
                ResolveSheet(row: row) { dir in store.resolve(row, winner: dir) }
            case .result(let rep):
                CodexResultSheet(report: rep, codexRunning: store.codexRunning)
                    .onDisappear { store.report = nil }
            }
        }
        .onChange(of: store.report?.id) { _, id in
            if id != nil, let rep = store.report { route = .result(rep) }
        }
        .overlay {
            if let bulk = store.bulk {
                VStack(spacing: 12) {
                    ProgressView(value: Double(bulk.done), total: Double(max(bulk.total, 1)))
                        .frame(width: 280)
                    Text("\(bulk.done) of \(bulk.total)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                    if !bulk.current.isEmpty {
                        Text(bulk.current).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).frame(maxWidth: 280)
                    }
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 22) {
                Stat(value: store.pairCount, label: "Pairs")
                Stat(value: store.syncedCount, label: "In sync", tint: .green)
                Stat(value: store.toCodexCount, label: "→ Codex", tint: .orange, muted: true)
                Stat(value: store.toClaudeCount, label: "→ Claude", tint: .orange, muted: true)
                Stat(value: store.conflictCount, label: "Conflicts", tint: .red, muted: true)
                Divider().frame(height: 30)
                Stat(value: store.unlinkedCount, label: "Unlinked", tint: .accentColor, muted: true)
                Spacer()
            }

            if let fatal = store.fatal {
                Notice(icon: "xmark.octagon", text: fatal.title + " — " + fatal.detail, tint: .red)
            }
            if store.schemaDrifted, let v = store.schemaVersion {
                Notice(icon: "exclamationmark.triangle",
                       text: "Codex database schema is v\(v); this app was validated against v\(CodexPaths.validatedSchemaVersion). Codex-side writes are disabled until the app is updated.",
                       tint: .orange)
            }
            if store.codexRunning {
                Notice(icon: "exclamationmark.triangle",
                       text: "The ChatGPT app is open. It caches its thread list — restart it to see newly imported threads.",
                       tint: .orange)
            }
        }
        .padding(16)
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $filter) {
                ForEach(CodexFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 330)

            Text("\(rows.count) of \(store.rows.count)")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            Spacer()
            if store.busy { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var table: some View {
        Group {
            if rows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 24)).foregroundStyle(.tertiary)
                    Text("Nothing in this category.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(rows) {
                    TableColumn("Session") { r in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(r.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                if r.state == .unlinkedClaude { Chip(text: "CLAUDE ONLY") }
                                if r.state == .unlinkedCodex { Chip(text: "CODEX ONLY") }
                            }
                            Text(r.cwd).font(.system(size: 10)).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.head)
                        }
                        .padding(.vertical, 3)
                    }
                    .width(min: 280, ideal: 400)

                    TableColumn("Claude activity") { r in
                        Text(r.claudeLastActivity > 0 ? fmtDate(r.claudeLastActivity) : "—")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .width(130)

                    TableColumn("Codex activity") { r in
                        Text(r.codexLastActivity > 0 ? fmtDate(r.codexLastActivity) : "—")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .width(130)

                    TableColumn("State") { r in stateLabel(r) }
                        .width(150)

                    TableColumn("Action") { r in actionButton(r) }
                        .width(95)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private func actionButton(_ r: PairRow) -> some View {
        switch r.state {
        case .pendingToCodex, .pendingToClaude:
            Button("Sync") { store.syncRow(r) }
                .controlSize(.small).disabled(store.busy)
        case .unlinkedClaude:
            Button("→ Codex") { store.syncRow(r) }
                .controlSize(.small).disabled(store.busy || store.schemaDrifted)
                .help("Import this Claude session as a Codex thread")
        case .unlinkedCodex:
            Button("→ Claude") { store.syncRow(r) }
                .controlSize(.small).disabled(store.busy)
                .help("Import this Codex thread as a Claude session")
        case .conflict:
            Button("Resolve…") { route = .resolve(r) }
                .controlSize(.small).disabled(store.busy)
                .help("Choose which side wins")
        case .synced:
            Text("—").font(.system(size: 10.5)).foregroundStyle(.quaternary)
        }
    }

    @ViewBuilder private func stateLabel(_ r: PairRow) -> some View {
        switch r.state {
        case .synced:
            Label("in sync", systemImage: "checkmark")
                .font(.system(size: 10.5)).foregroundStyle(.green)
        case .pendingToCodex:
            Label("→ Codex", systemImage: "arrow.right")
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.orange)
        case .pendingToClaude:
            Label("→ Claude", systemImage: "arrow.left")
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.orange)
        case .conflict:
            Label(r.conflictReason ?? "conflict", systemImage: "arrow.triangle.branch")
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.red)
                .lineLimit(1).help(r.conflictReason ?? "")
        case .unlinkedClaude, .unlinkedCodex:
            Label("unlinked", systemImage: "link.badge.plus")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }

    // (result sheet lives below as its own view)
    private var statusBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").font(.system(size: 9.5)).foregroundStyle(.tertiary)
            Text("~/.claude/projects  ⇄  ~/.codex/sessions")
                .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)
            Spacer()
            if store.badgeCount == 0 {
                Label("aligned", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 9.5)).foregroundStyle(.green)
            } else {
                Label("\(store.badgeCount) to sync", systemImage: "circle.fill")
                    .font(.system(size: 9.5)).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Confirm-all sheet

struct ConfirmAllSheet: View {
    @ObservedObject var store: CodexStore
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sync everything").font(.system(size: 15, weight: .semibold))
                Text("Nothing has been written yet.").font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()
            VStack(alignment: .leading, spacing: 9) {
                row("Claude sessions → new Codex threads",
                    "\(store.rows.filter { $0.state == .unlinkedClaude }.count)")
                row("Codex threads → new Claude sessions",
                    "\(store.rows.filter { $0.state == .unlinkedCodex }.count)")
                row("Pending pairs to bring up to date",
                    "\(store.toCodexCount + store.toClaudeCount)")
                if store.conflictCount > 0 {
                    row("Conflicts (left untouched)", "\(store.conflictCount)")
                }
            }
            .padding(16)

            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Notice(icon: "arrow.uturn.backward",
                       text: "A full safety backup (Codex database, indexes, ledger, Claude session index) is created before the first write. Interrupting is safe: the run is resumable and never duplicates.",
                       tint: .blue)
                if store.codexRunning {
                    Notice(icon: "exclamationmark.triangle",
                           text: "The ChatGPT app is open — restart it afterwards to see the imported threads.",
                           tint: .orange)
                }
            }
            .padding(16)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Back up and sync all") { dismiss(); onConfirm() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
        .frame(width: 520)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.system(size: 11.5, weight: .medium, design: .rounded))
        }
    }
}

// MARK: - Resolve sheet

struct ResolveSheet: View {
    let row: PairRow
    let onResolve: (SyncDirection) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Resolve conflict").font(.system(size: 15, weight: .semibold))
                Text(row.title).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                if let reason = row.conflictReason {
                    Text(reason).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            .padding(16)

            Divider()
            HStack(spacing: 12) {
                sideCard(name: "Claude", icon: "c.circle",
                         activity: row.claudeLastActivity,
                         action: "Keep Claude",
                         detail: "Claude's new turns are copied to Codex. Codex's new turns stay in Codex only.",
                         dir: .toCodex)
                sideCard(name: "Codex", icon: "x.circle",
                         activity: row.codexLastActivity,
                         action: "Keep Codex",
                         detail: "Codex's new turns are copied to Claude. Claude's new turns stay in Claude only.",
                         dir: .toClaude)
            }
            .padding(16)

            Notice(icon: "info.circle",
                   text: "Nothing is deleted either way: the losing side's turns remain in their own transcript — they are just not mirrored.",
                   tint: .blue)
                .padding(.horizontal, 16)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 560)
    }

    private func sideCard(name: String, icon: String, activity: Int,
                          action: String, detail: String, dir: SyncDirection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 14))
                Text(name).font(.system(size: 12.5, weight: .semibold))
                Spacer()
            }
            Text("Last activity: \(activity > 0 ? fmtDate(activity) : "—")")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(detail).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action) { dismiss(); onResolve(dir) }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.6)))
    }
}

// MARK: - Result sheet (mirrors ResultSheet's grammar for the Codex engine)

struct CodexResultSheet: View {
    let report: CodexSyncReport
    let codexRunning: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: report.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(report.ok ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)

            Divider()
            VStack(alignment: .leading, spacing: 9) {
                row("Counterparts created", "\(report.created)")
                row("Counterparts updated", "\(report.updated)")
                if report.skippedConflicts > 0 {
                    row("Skipped (conflicts)", "\(report.skippedConflicts)")
                }
                if let backup = report.backupDir {
                    Divider().padding(.vertical, 1)
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Safety backup").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(backup.lastPathComponent)
                                .font(.system(size: 10.5, design: .monospaced))
                        }
                        Spacer()
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([backup])
                        }
                        .controlSize(.small)
                    }
                }
                if !report.failed.isEmpty {
                    Divider().padding(.vertical, 1)
                    Text("Failed").font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
                    ForEach(report.failed) { f in
                        HStack(alignment: .top, spacing: 6) {
                            Chip(text: f.side.uppercased(), tint: .red)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.title).font(.system(size: 11.5)).lineLimit(1)
                                Text(f.reason).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(16)

            if report.ok && report.created + report.updated > 0 && codexRunning {
                Divider()
                Notice(icon: "arrow.clockwise",
                       text: "Restart the ChatGPT app to see imported threads in its list.",
                       tint: .blue)
                    .padding(16)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
        .frame(width: 500)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.system(size: 11.5, weight: .medium, design: .rounded))
        }
    }

    private var title: String {
        if !report.ok { return "Sync finished with errors" }
        if report.created + report.updated == 0 { return "Nothing to do" }
        return "Sync complete"
    }
    private var subtitle: String {
        if !report.ok { return "No data was lost — the backup is intact." }
        return "\(report.created) created, \(report.updated) updated."
    }
}
