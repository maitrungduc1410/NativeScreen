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
        _ = AppUpdater.shared // starts Sparkle's scheduled checks
        Task { await RecordingCoordinator.shared.recoverInterruptedRecordings() }
    }

    /// Windows are not closed one by one on quit, so saving and the save prompt have to happen here.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ProjectWorkspaceStore.shared.prepareToQuit() else { return .terminateCancel }
        guard RecordingCoordinator.shared.isRecording else { return .terminateNow }
        Task {
            await RecordingCoordinator.shared.stopRecordingAndOpenEditor(opensEditor: false)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
        #if APPSTORE
        // Reopen the folders and projects the user granted in earlier runs before anything reads them.
        SandboxAccess.restore()
        #else
        if CommandLine.arguments.contains("--mcp") {
            MCPStdioBridge.run()
        }
        #endif
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
        if let idx = args.firstIndex(of: "--verify-motion"), idx + 1 < args.count {
            do {
                try MotionRegressionChecks.run(to: URL(fileURLWithPath: args[idx + 1], isDirectory: true))
                exit(0)
            } catch {
                fputs("Motion checks failed: \(error)\n", stderr)
                exit(1)
            }
        }
        if let idx = args.firstIndex(of: "--verify-projects"), idx + 2 < args.count {
            // Real recordings: async export, so the main run loop is spun until the checks finish.
            var finished: Int32? = nil
            Task { @MainActor in
                do {
                    try await ProjectVerification.run(
                        packages: args[(idx + 2)...].map { URL(fileURLWithPath: $0, isDirectory: true) },
                        to: URL(fileURLWithPath: args[idx + 1], isDirectory: true))
                    finished = 0
                } catch {
                    fputs("Project checks failed: \(error)\n", stderr)
                    finished = 1
                }
            }
            while finished == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            exit(finished ?? 1)
        }
        if let idx = args.firstIndex(of: "--generate-conformance"), idx + 1 < args.count {
            let outputPath = args[idx + 1]
            let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
            do {
                try ConformanceFixtureGenerator.generateAll(to: outputURL, motionOnly: args.contains("--motion-only"))
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

            Button("Open .nativescreen Project...") {
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
            if AppUpdater.shared.isAvailable {
                Button("Check for Updates...") {
                    AppUpdater.shared.checkForUpdates()
                }
                .disabled(!AppUpdater.shared.canCheckForUpdates)
            }
            Button("Quit Native Screen") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }

        // `Native Screen > Settings...` (⌘,); the Settings scene also keeps the app running without a placeholder window
        Settings {
            SettingsView()
        }
        .commands {
            AppMenuCommands(workspace: workspace, recorder: recorder, preferences: EditorViewPreferences.shared)
        }
    }
}
