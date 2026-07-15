import SwiftUI
import AppKit

// MARK: - Menu bar widget

/// Template glyph + monospaced count beside it (the system's own battery-percentage
/// idiom). A red badge composited into an NSImage would lose template rendering —
/// light/dark/selected adaptation — and need manual redraws; this stays native.
struct MenuBarLabel: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
            Text(count > 99 ? "99+" : "\(count)").monospacedDigit()
        } else {
            Image(systemName: "arrow.triangle.2.circlepath")
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("autoSyncEnabled") private var autoSyncEnabled = false

    var body: some View {
        let pending = app.codex.rows.filter(\.isPending)
        let conflicts = app.codex.rows.filter { $0.state == .conflict }

        if app.codex.badgeCount > 0 {
            Button("Sync now (\(app.codex.badgeCount - conflicts.count))") {
                app.codex.syncAll()
            }
            .disabled(app.codex.busy || pending.isEmpty)
            Divider()
        }

        // Top pending/conflict rows for one-click access.
        ForEach(Array((pending + conflicts).prefix(5))) { row in
            if row.state == .conflict {
                Button("⚠ \(row.title.prefix(40)) — conflict") { openMain() }
            } else {
                Button("\(row.title.prefix(40)) \(row.state == .pendingToCodex ? "→ Codex" : "→ Claude")") {
                    app.codex.syncRow(row)
                }
                .disabled(app.codex.busy)
            }
        }
        if !pending.isEmpty || !conflicts.isEmpty { Divider() }

        if app.codex.badgeCount == 0 {
            Text("✓ All synced")
            Divider()
        }

        Toggle("Auto-sync", isOn: $autoSyncEnabled)
        Divider()

        Button("Open Claude Session Sync") { openMain() }
        Button("Refresh") { app.codex.reload() }
            .disabled(app.codex.busy)
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate()
    }
}
