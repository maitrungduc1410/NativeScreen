import SwiftUI
import AppKit

/// NativeScreenAppDelegate launches ONLY the small floating Recording HUD (`NSPanel`) on startup,
/// hides the HUD when any `.nativescreen` project Editor window opens,
/// and automatically re-shows the HUD when all Editor windows are closed.
@MainActor
final class NativeScreenAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !ProjectWorkspaceStore.shared.hasOpenEditorWindows {
            RecordingCoordinator.shared.showRecordingHUD()
        }
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

@main
struct NativeScreenApp: App {
    @NSApplicationDelegateAdaptor(NativeScreenAppDelegate.self) private var appDelegate
    @Bindable private var workspace = ProjectWorkspaceStore.shared
    @Bindable private var recorder = RecordingCoordinator.shared

    var body: some Scene {
        // Menu Bar Extra Icon (Like the top-right macOS Menu Bar icon!)
        MenuBarExtra("NativeScreen", systemImage: "record.circle") {
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

            Divider()
            Button("Quit NativeScreen") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }

        // Settings scene keeps the app running without spawning any unwanted placeholder window on launch
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Screen Recording…") {
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
            }
        }
    }
}
