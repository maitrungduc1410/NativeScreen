import SwiftUI

@main
struct NativeScreenApp: App {
    @Environment(\.openWindow) private var openWindow
    @Bindable private var workspace = ProjectWorkspaceStore.shared
    @Bindable private var recorder = RecordingCoordinator.shared

    var body: some Scene {
        // 1. Launch Hub Window
        WindowGroup("NativeScreen", id: "launch-hub") {
            ContentView()
                .onOpenURL { url in
                    guard url.pathExtension.lowercased() == "nativescreen" else { return }
                    if let session = workspace.openOrFocusProject(at: url) {
                        openWindow(id: "project-editor", value: session.id)
                    }
                }
        }
        .defaultSize(width: 780, height: 460)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Screen Recording…") {
                    recorder.onRecordingCompleted = { newSession in
                        openWindow(id: "project-editor", value: newSession.id)
                    }
                    recorder.showRecordingHUD()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        // 2. Multi-Window Project Editor Scene (Borderless Unified Titlebar!)
        WindowGroup("NativeScreen Editor", id: "project-editor", for: UUID.self) { $sessionID in
            if let id = sessionID, let session = workspace.session(for: id) {
                ProjectEditorWindowView(session: session)
                    .ignoresSafeArea(.container, edges: .top)
                    .frame(minWidth: 1080, minHeight: 720)
                    .onDisappear {
                        session.isPlaying = false
                        try? session.saveNow()
                    }
            } else {
                VStack(spacing: 12) {
                    Text("No Project Selected")
                        .font(.headline)
                    Text("Open or create a .nativescreen project from the main window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 600, minHeight: 400)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
    }
}
