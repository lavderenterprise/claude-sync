import SwiftUI
import AppKit

// MARK: - Components

enum Filter: String, CaseIterable, Identifiable {
    case all = "All", differs = "Diverging", missing = "Missing", orphan = "Orphaned"
    var id: Self { self }
}

/// Compact single-line notice. The colored border is an `overlay`, not a `Rectangle` in an
/// HStack: the latter collapses to a dot when the container imposes no height.
struct Notice: View {
    let icon: String, text: String, tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint)
                .frame(width: 14).padding(.top, 1)
            Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint.opacity(0.22)))
    }
}

struct Stat: View {
    let value: Int, label: String
    var tint: Color = .primary
    var muted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundStyle(muted && value == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
                .contentTransition(.numericText())
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).kerning(0.5)
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 74, alignment: .leading)
    }
}

struct Chip: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(tint)
    }
}

struct AccountCard: View {
    let row: AccountRow
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle().fill(active ? .green : .secondary.opacity(0.35)).frame(width: 6, height: 6)
                Text(active ? "Active" : "Inactive")
                    .font(.system(size: 9.5, weight: .semibold)).kerning(0.3)
                    .foregroundStyle(active ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                Spacer()
                Text("\(row.sessions) sessions").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Text(row.id).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.middle)
            Text("Last activity: \(fmtDate(row.lastActivity))")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator.opacity(0.6)))
    }
}

// MARK: - Sheet: plan preview

struct PlanSheet: View {
    let actions: [Action]
    let accounts: Int
    let claudeRunning: Bool
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sync preview").font(.system(size: 15, weight: .semibold))
                Text("\(actions.count) changes across \(accounts) accounts. Nothing has been written yet.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()

            if actions.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.system(size: 26)).foregroundStyle(.green)
                    Text("All accounts are already aligned.").font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(actions.indices, id: \.self) { i in
                            let a = actions[i]
                            HStack(spacing: 10) {
                                Chip(text: a.create ? "CREATE" : "UPDATE", tint: a.create ? .green : .orange)
                                    .frame(width: 76, alignment: .leading)
                                Text(a.title).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 12)
                                HStack(spacing: 4) {
                                    Chip(text: short(a.from))
                                    Image(systemName: "arrow.right").font(.system(size: 8))
                                        .foregroundStyle(.tertiary)
                                    Chip(text: short(a.to))
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(i.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                        }
                    }
                }
                .frame(height: min(CGFloat(actions.count) * 32 + 8, 260))
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Notice(icon: "arrow.uturn.backward",
                       text: "Before writing, previous backups are deleted and a fresh, complete, dated one is created.",
                       tint: .blue)
                if claudeRunning {
                    Notice(icon: "exclamationmark.triangle",
                           text: "The Claude app is open. Quit and reopen it after the sync: the index is only re-read on launch.",
                           tint: .orange)
                }
            }
            .padding(16)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Back up and apply") { dismiss(); onConfirm() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(actions.isEmpty)
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
        .frame(width: 620)
    }
}

// MARK: - Sheet: result

struct ResultSheet: View {
    let report: SyncReport
    let claudeRunning: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: icon).font(.system(size: 22)).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)

            if let fatal = report.fatal {
                Divider()
                Text(fatal.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    row("Sessions created", "\(report.created)")
                    row("Sessions updated", "\(report.updated)")
                    row("Previous backups removed", report.removed.isEmpty ? "none" : "\(report.removed.count)")

                    if let backup = report.backup {
                        Divider().padding(.vertical, 1)
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Safety backup").font(.system(size: 11)).foregroundStyle(.secondary)
                                Text(backup.lastPathComponent)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .lineLimit(1).truncationMode(.middle)
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
                                Chip(text: f.account, tint: .red)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(f.session).font(.system(size: 11.5))
                                    Text(f.reason).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }

            if report.ok {
                Divider()
                Notice(icon: "arrow.clockwise",
                       text: claudeRunning
                           ? "Quit and reopen the Claude app to see the synced sessions."
                           : "Reopen the Claude app to see the synced sessions.",
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
        .frame(width: 520)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.system(size: 11.5, weight: .medium, design: .rounded))
        }
    }

    private var icon: String {
        if report.fatal != nil { return "xmark.octagon.fill" }
        return report.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }
    private var tint: Color {
        if report.fatal != nil { return .red }
        return report.failed.isEmpty ? .green : .orange
    }
    private var title: String {
        if let f = report.fatal { return f.title }
        if !report.failed.isEmpty { return "Sync finished with errors" }
        if report.created + report.updated == 0 { return "Everything was already aligned" }
        return "Sync complete"
    }
    private var subtitle: String {
        if report.fatal != nil { return "No session was modified." }
        if !report.failed.isEmpty {
            return "\(report.failed.count) sessions were not written. The backup is intact — you can restore it."
        }
        return "\(report.created + report.updated) sessions aligned across all accounts."
    }
}

// MARK: - Main view

/// One `.sheet` per view: two modifiers on the same view cancel each other out, and the
/// second one silently wins.
enum Route: Identifiable {
    case plan
    case result(SyncReport)

    var id: String {
        switch self {
        case .plan: "plan"
        case .result(let r): "result-" + r.id
        }
    }
}

struct AccountsView: View {
    @StateObject var store = Store()
    @State private var filter: Filter = .all
    @State private var route: Route?

    var rows: [SessionRow] {
        switch filter {
        case .all: store.sessions
        case .orphan: store.sessions.filter(\.orphan)
        case .differs: store.sessions.filter { $0.status == .differs }
        case .missing: store.sessions.filter { $0.status == .missing }
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
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.reload() } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(store.busy)
                .help("Re-read the folders from disk")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { route = .plan } label: {
                    Label(store.pending.isEmpty ? "Sync" : "Sync (\(store.pending.count))",
                          systemImage: "arrow.left.arrow.right")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.busy || store.pending.isEmpty)
                .help(store.pending.isEmpty
                      ? "All accounts are already aligned"
                      : "Preview the \(store.pending.count) changes")
            }
        }
        .sheet(item: $route) { r in
            switch r {
            case .plan:
                PlanSheet(actions: store.pending, accounts: store.accounts.count,
                          claudeRunning: store.claudeRunning) { store.sync() }
            case .result(let report):
                ResultSheet(report: report, claudeRunning: store.claudeRunning)
                    .onDisappear { store.report = nil }
            }
        }
        .onChange(of: store.report?.id) { _, id in
            if id != nil, let report = store.report { route = .result(report) }
        }
        .overlay {
            if store.busy {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Backing up and syncing…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .onAppear { store.reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 22) {
                Stat(value: store.sessions.count, label: "Sessions")
                Stat(value: store.synced, label: "In sync", tint: .green)
                Stat(value: store.differs, label: "Diverging", tint: .orange, muted: true)
                Stat(value: store.missing, label: "Missing", tint: .red, muted: true)
                Stat(value: store.orphans, label: "Orphaned", tint: .red, muted: true)
                Divider().frame(height: 30)
                Stat(value: store.pending.count, label: "To sync", tint: .accentColor, muted: true)
                Spacer()
            }

            HStack(spacing: 10) {
                ForEach(store.accounts) { a in
                    AccountCard(row: a, active: a.id == store.activeAccount)
                }
            }

            if store.claudeRunning || store.orphans > 0 {
                VStack(spacing: 6) {
                    if store.claudeRunning {
                        Notice(icon: "exclamationmark.triangle",
                               text: "The Claude app is open. The index is only re-read on launch: quit and reopen it after the sync.",
                               tint: .orange)
                    }
                    if store.orphans > 0 {
                        Notice(icon: "doc.badge.gearshape",
                               text: "\(store.orphans) orphaned sessions: the transcript in ~/.claude/projects was deleted by automatic cleanup. They stay in the list but open empty, and the sync cannot recover them.",
                               tint: .red)
                    }
                }
            }
        }
        .padding(16)
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 330)

            Text("\(rows.count) of \(store.sessions.count)")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var table: some View {
        Group {
            if rows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 24)).foregroundStyle(.tertiary)
                    Text("No sessions in this category.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(rows) {
                    TableColumn("Session") { r in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(r.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                if r.orphan { Chip(text: "ORPHAN", tint: .red) }
                            }
                            Text(r.cwd).font(.system(size: 10)).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.head)
                        }
                        .padding(.vertical, 3)
                    }
                    .width(min: 300, ideal: 420)

                    TableColumn("Last activity") { r in
                        Text(fmtDate(r.lastActivity)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .width(135)

                    TableColumn("Present in") { r in
                        HStack(spacing: 3) { ForEach(r.accounts, id: \.self) { Chip(text: $0) } }
                    }
                    .width(150)

                    TableColumn("Most recent") { r in
                        Chip(text: r.winner, tint: .accentColor)
                    }
                    .width(80)

                    TableColumn("Status") { r in
                        switch r.status {
                        case .synced:
                            Label("in sync", systemImage: "checkmark")
                                .font(.system(size: 10.5)).foregroundStyle(.green).labelStyle(.titleAndIcon)
                        case .differs:
                            Label("diverging", systemImage: "arrow.triangle.branch")
                                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.orange)
                        case .missing:
                            Label("missing", systemImage: "minus.circle")
                                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.red)
                        }
                    }
                    .width(105)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").font(.system(size: 9.5)).foregroundStyle(.tertiary)
            Text(BASE.path(percentEncoded: false))
                .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            if store.pending.isEmpty {
                Label("aligned", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 9.5)).foregroundStyle(.green)
            } else {
                Label("\(store.pending.count) to sync", systemImage: "circle.fill")
                    .font(.system(size: 9.5)).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

extension SyncReport: Identifiable {
    public var id: String { (backup?.path ?? "") + "\(created)-\(updated)-\(failed.count)" }
}
