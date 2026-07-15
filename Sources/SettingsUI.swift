import SwiftUI
import ServiceManagement

// MARK: - Login item controller
// Not @AppStorage: SMAppService.mainApp.status is the OS-side source of truth and the
// user can flip it in System Settings → Login Items behind our back.

@MainActor final class LoginItemController: ObservableObject {
    @Published var enabled = false
    @Published var needsApproval = false
    @Published var error: String?

    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func toggle(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = plainReason(error)
        }
        refresh()
    }
}

// MARK: - Settings tab

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @AppStorage("autoSyncEnabled") private var autoSyncEnabled = false
    @AppStorage("quiescenceSeconds") private var quiescenceSeconds = 20.0
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @StateObject private var loginItem = LoginItemController()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("Automation") {
                    Toggle(isOn: $autoSyncEnabled) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Auto-sync").font(.system(size: 12.5, weight: .medium))
                            Text("When a chat finishes receiving a reply in one app, mirror it to the other automatically.")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    HStack(spacing: 10) {
                        Text("Quiet period").font(.system(size: 11.5))
                            .foregroundStyle(autoSyncEnabled ? .primary : .tertiary)
                        Slider(value: $quiescenceSeconds, in: 5...120, step: 5)
                            .frame(width: 220)
                            .disabled(!autoSyncEnabled)
                        Text("\(Int(quiescenceSeconds)) s")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                    Text("A session syncs after its transcript stops changing for this long — long enough to let a full reply (including tool calls) land.")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)

                    Notice(icon: "shield",
                           text: "Conflicts are never auto-resolved: they only raise the menu bar badge and wait for you.",
                           tint: .blue)
                }

                section("Menu bar") {
                    Toggle(isOn: $showMenuBarExtra) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Show in menu bar").font(.system(size: 12.5, weight: .medium))
                            Text("Quick sync and a badge with the number of chats waiting to sync.")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }

                section("System") {
                    Toggle(isOn: Binding(get: { loginItem.enabled },
                                         set: { loginItem.toggle($0) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Launch at login").font(.system(size: 12.5, weight: .medium))
                            Text("Keeps the widget and auto-sync available after a restart.")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    if loginItem.needsApproval {
                        HStack(spacing: 8) {
                            Notice(icon: "exclamationmark.triangle",
                                   text: "macOS wants your approval in System Settings → Login Items.",
                                   tint: .orange)
                            Button("Open") { SMAppService.openSystemSettingsLoginItems() }
                                .controlSize(.small)
                        }
                    }
                    if let err = loginItem.error {
                        Notice(icon: "xmark.octagon", text: err, tint: .red)
                    }
                    Text("Note: this app is ad-hoc signed — after rebuilding it you may need to toggle this again.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }

                section("Watched paths") {
                    pathRow("Claude transcripts", "~/.claude/projects")
                    pathRow("Codex rollouts", "~/.codex/sessions")
                    pathRow("Sync ledger & backups", "~/Library/Application Support/ClaudeSessionSync")
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .onAppear { loginItem.refresh() }
        .onChange(of: autoSyncEnabled) { _, _ in app.settingsChanged() }
        .onChange(of: quiescenceSeconds) { _, _ in app.settingsChanged() }
        .onChange(of: showMenuBarExtra) { _, _ in app.settingsChanged() }
    }

    @ViewBuilder private func section(_ title: String,
                                      @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).kerning(0.7)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.6)))
        }
    }

    private func pathRow(_ label: String, _ path: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer()
            Text(path).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
        }
    }
}
