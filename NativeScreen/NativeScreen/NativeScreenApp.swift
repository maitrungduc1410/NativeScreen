import SwiftUI
import AppKit

/// AppLifecycleDelegate launches the small floating Recording HUD (`NSPanel`) directly on app startup
/// (without opening any extra "No Project Selected" or "Project List" window!),
/// hides the HUD when any project Editor window is opened, and re-shows the HUD when all Editor windows are closed.
@MainActor
final class NativeScreenAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            // Close any empty placeholder window SwiftUI may have created on cold launch
            for win in NSApp.windows where !(win is NSPanel) {
                if ProjectWorkspaceStore.shared.openEditorWindowIDs.isEmpty {
                    win.close()
                }
            }
            if ProjectWorkspaceStore.shared.openEditorWindowIDs.isEmpty {
                RecordingCoordinator.shared.showRecordingHUD()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if ProjectWorkspaceStore.shared.openEditorWindowIDs.isEmpty {
            RecordingCoordinator.shared.showRecordingHUD()
        }
        return false
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
    @Environment(\.openWindow) private var openWindow
    @Bindable private var workspace = ProjectWorkspaceStore.shared
    @Bindable private var recorder = RecordingCoordinator.shared

    var body: some Scene {
        // Multi-Window Project Editor Scene (Borderless Unified Titlebar!)
        WindowGroup("NativeScreen Editor", id: "project-editor", for: UUID.self) { $sessionID in
            Group {
                if let id = sessionID, let session = workspace.session(for: id) {
                    ProjectEditorWindowView(session: session)
                        .ignoresSafeArea(.container, edges: .top)
                        .frame(minWidth: 1120, minHeight: 740)
                        .onAppear {
                            workspace.openEditorWindowHandler = { targetID in
                                openWindow(id: "project-editor", value: targetID)
                            }
                            recorder.onRecordingCompleted = { newSession in
                                openWindow(id: "project-editor", value: newSession.id)
                            }
                            workspace.editorWindowDidAppear(sessionID: id)
                        }
                        .onDisappear {
                            workspace.editorWindowDidDisappear(sessionID: id)
                        }
                } else {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .onAppear {
                            workspace.openEditorWindowHandler = { targetID in
                                openWindow(id: "project-editor", value: targetID)
                            }
                            recorder.onRecordingCompleted = { newSession in
                                openWindow(id: "project-editor", value: newSession.id)
                            }
                            // Immediately dismiss this empty placeholder window and show the small Recording HUD
                            DispatchQueue.main.async {
                                for win in NSApp.windows where !(win is NSPanel) && win.frame.width <= 10 {
                                    win.close()
                                }
                                if workspace.openEditorWindowIDs.isEmpty {
                                    recorder.showRecordingHUD()
                                }
                            }
                        }
                }
            }
            .onOpenURL { url in
                guard url.pathExtension.lowercased() == "nativescreen" else { return }
                _ = workspace.openOrFocusProject(at: url)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Screen Recording…") {
                    recorder.onRecordingCompleted = { newSession in
                        openWindow(id: "project-editor", value: newSession.id)
                    }
                    recorder.showRecordingHUD()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Open .nativescreen Project…") {
                    workspace.openEditorWindowHandler = { targetID in
                        openWindow(id: "project-editor", value: targetID)
                    }
                    workspace.promptOpenProjectDialog()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Create Interactive Showcase Project") {
                    workspace.openEditorWindowHandler = { targetID in
                        openWindow(id: "project-editor", value: targetID)
                    }
                    if let demo = recorder.createInteractiveSampleProject() {
                        openWindow(id: "project-editor", value: demo.id)
                    }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        // Menu Bar Extra Icon (Like the top-right macOS Menu Bar icon!)
        MenuBarExtra("NativeScreen", systemImage: "record.circle") {
            Button("Show Recording Bar") {
                workspace.openEditorWindowHandler = { targetID in
                    openWindow(id: "project-editor", value: targetID)
                }
                recorder.onRecordingCompleted = { newSession in
                    openWindow(id: "project-editor", value: newSession.id)
                }
                recorder.showRecordingHUD()
            }

            Button("Open .nativescreen Project…") {
                workspace.openEditorWindowHandler = { targetID in
                    openWindow(id: "project-editor", value: targetID)
                }
                workspace.promptOpenProjectDialog()
            }

            Button("Create Interactive Showcase Project") {
                workspace.openEditorWindowHandler = { targetID in
                    openWindow(id: "project-editor", value: targetID)
                }
                if let demo = recorder.createInteractiveSampleProject() {
                    openWindow(id: "project-editor", value: demo.id)
                }
            }

            if !workspace.recentProjectURLs.isEmpty {
                Divider()
                Menu("Recent Projects") {
                    ForEach(workspace.recentProjectURLs.prefix(10), id: \.path) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            workspace.openEditorWindowHandler = { targetID in
                                openWindow(id: "project-editor", value: targetID)
                            }
                            _ = workspace.openOrFocusProject(at: url)
                        }
                    }
                }
            }

            Divider()
            Button("Quit NativeScreen") {
                NSApp.terminate(nil)
            }
        }
    }
}
