import SwiftUI
import AppKit

/// NativeScreenAppDelegate launches ONLY the small floating Recording HUD (`NSPanel`) on startup,
/// hides the HUD when any `.nativescreen` project Editor window opens,
/// and automatically re-shows the HUD when all Editor windows are closed.
@MainActor
final class NativeScreenAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenuOrder.install()
        AppSettings.shared.applyAppearance()
        if let appMenuItem = NSApp.mainMenu?.items.first {
            appMenuItem.title = String(localized: "Native Screen")
            appMenuItem.submenu?.title = String(localized: "Native Screen")
        }
        if !ProjectWorkspaceStore.shared.hasOpenEditorWindows {
            RecordingCoordinator.shared.showRecordingHUD()
        }
        MCPServer.shared.applySetting()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Removes the socket file so the bridge knows the app is gone.
        MCPServer.shared.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !ProjectWorkspaceStore.shared.hasOpenEditorWindows {
            RecordingCoordinator.shared.showRecordingHUD()
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "nativescreen" {
            _ = ProjectWorkspaceStore.shared.openOrFocusProject(at: url)
        }
    }
}

/// `NativeScreen --mcp` is the stdio bridge MCP clients start (`MCPStdioBridge`); it must not start AppKit.
@main
enum NativeScreenMain {
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            MCPStdioBridge.run()
        }
        NativeScreenApp.main()
    }
}

struct NativeScreenApp: App {
    @NSApplicationDelegateAdaptor(NativeScreenAppDelegate.self) private var appDelegate
    @Bindable private var workspace = ProjectWorkspaceStore.shared
    @Bindable private var recorder = RecordingCoordinator.shared

    init() {
        // Pinned now, before anything can change it, so Settings knows when a restart is due.
        _ = AppLanguage.atLaunch
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--generate-conformance"), idx + 1 < args.count {
            let outputPath = args[idx + 1]
            let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
            do {
                try ConformanceFixtureGenerator.generateAll(to: outputURL)
                exit(0)
            } catch {
                fputs("Failed to generate conformance fixtures: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    var body: some Scene {
        // Menu Bar Extra Icon (Like the top-right macOS Menu Bar icon!)
        MenuBarExtra("Native Screen", systemImage: "record.circle") {
            Button("Show Recording Bar") {
                recorder.showRecordingHUD()
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("Open .nativescreen Project…") {
                workspace.promptOpenProjectDialog()
            }
            .keyboardShortcut("o", modifiers: [.command])

            Button("Create Interactive Showcase Project") {
                _ = recorder.createInteractiveSampleProject()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            if !workspace.recentProjectURLs.isEmpty {
                Divider()
                Menu("Recent Projects") {
                    ForEach(workspace.recentProjectURLs.prefix(10), id: \.path) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            _ = workspace.openOrFocusProject(at: url)
                        }
                    }
                }
            }

            if !MCPServer.shared.connectedClients.isEmpty {
                Divider()
                Text("AI agent connected: \(MCPServer.shared.connectedClients.joined(separator: ", "))")
            }

            Divider()
            Button("Quit Native Screen") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }

        // `Native Screen > Settings…` (⌘,); the Settings scene also keeps the app running without a placeholder window
        Settings {
            SettingsView()
        }
        .commands {
            AppMenuCommands(workspace: workspace, recorder: recorder, preferences: EditorViewPreferences.shared)
        }
    }
}
