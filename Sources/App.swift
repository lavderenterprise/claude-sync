import SwiftUI
import AppKit

enum AppTab: String { case accounts, codex, settings }

/// Keeps the process alive when the last window closes: the menu bar extra and the
/// auto-sync watcher must survive the window. Dock-icon reopen recreates the window
/// via the closure captured from the scene (SwiftUI has no native hook for this).
final class AppDelegate: NSObject, NSApplicationDelegate {
    var reopen: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { reopen?() }
        return true
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        TabView(selection: $app.selectedTab) {
            AccountsView()
                .tabItem { Label("Accounts", systemImage: "person.2") }
                .tag(AppTab.accounts)
            CodexView()
                .tabItem { Label("Codex", systemImage: "arrow.triangle.2.circlepath") }
                .tag(AppTab.codex)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

@main struct ClaudeSessionSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var appModel = AppModel()
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Claude Session Sync", id: "main") {
            RootView()
                .environmentObject(appModel)
                .onAppear { delegate.reopen = { openWindow(id: "main"); NSApp.activate() } }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1120, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appModel.selectedTab = .settings
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .keyboardShortcut(",")
            }
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarContent().environmentObject(appModel)
        } label: {
            MenuBarLabel(count: appModel.badgeCount)
        }
        .menuBarExtraStyle(.menu)
    }
}
