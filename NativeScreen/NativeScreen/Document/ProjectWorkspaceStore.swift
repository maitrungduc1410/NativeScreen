import Foundation
import SwiftUI
import Observation
import AppKit

/// Global registry that manages multiple simultaneously open `.nativescreen` project `NSWindow`s
/// and coordinates showing/hiding the floating Recording HUD panel automatically:
/// - On app launch (0 open projects) -> shows only the small floating Recording HUD panel.
/// - When any project Editor window opens -> hides the Recording HUD panel.
/// - When all project Editor windows are closed -> automatically re-shows the small Recording HUD panel.
@Observable
@MainActor
public final class ProjectWorkspaceStore: NSObject, NSWindowDelegate {
    public static let shared = ProjectWorkspaceStore()

    public var sessionsByID: [UUID: ProjectSession] = [:]
    public var recentProjectURLs: [URL] = []

    private var editorWindowsBySessionID: [UUID: NSWindow] = [:]
    private let recentsDefaultsKey = "NativeScreen.RecentProjects"

    private override init() {
        super.init()
        loadRecentProjects()
    }

    public var hasOpenEditorWindows: Bool {
        !editorWindowsBySessionID.isEmpty
    }

    public static var defaultProjectsDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        let dir = movies.appendingPathComponent("NativeScreen Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func registerSession(_ session: ProjectSession) {
        sessionsByID[session.id] = session
        addRecentProject(session.packageURL)
    }

    public func session(for id: UUID) -> ProjectSession? {
        sessionsByID[id]
    }

    /// Opens a `.nativescreen` project from disk (or focuses its existing Editor window if already open)
    /// and hides the small Recording HUD bar.
    @discardableResult
    public func openOrFocusProject(at url: URL) -> ProjectSession? {
        let standardized = url.standardizedFileURL
        if let existing = sessionsByID.values.first(where: { $0.packageURL.standardizedFileURL == standardized }) {
            addRecentProject(standardized)
            presentEditorWindow(for: existing)
            return existing
        }
        guard let loaded = try? ProjectSession.load(from: standardized) else {
            return nil
        }
        registerSession(loaded)
        presentEditorWindow(for: loaded)
        return loaded
    }

    /// Creates or brings to front the native macOS Editor `NSWindow` for the given `ProjectSession`.
    public func presentEditorWindow(for session: ProjectSession) {
        if !RecordingCoordinator.shared.isRecording {
            RecordingCoordinator.shared.hideRecordingHUD()
        }

        if let existingWindow = editorWindowsBySessionID[session.id] {
            NSApp.activate(ignoringOtherApps: true)
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let editorView = ProjectEditorWindowView(session: session)
            .ignoresSafeArea(.container, edges: .top)
        let hostingController = NSHostingController(rootView: editorView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Crucial: prevent Objective-C over-release when the window closes while Swift holds a reference
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.minSize = NSSize(width: 1080, height: 720)
        window.title = "\(session.document.name).nativescreen"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0)
        window.isMovableByWindowBackground = false

        let toolbar = NSToolbar(identifier: "NativeScreenUnifiedToolbar-\(session.id.uuidString)")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.delegate = self
        window.center()

        // Cascade slightly if multiple project windows are open simultaneously
        let openCount = editorWindowsBySessionID.count
        if openCount > 0 {
            let offset = CGFloat(openCount * 26)
            var frame = window.frame
            frame.origin.x += offset
            frame.origin.y -= offset
            window.setFrame(frame, display: false)
        }

        editorWindowsBySessionID[session.id] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }

        if let (sessionID, _) = editorWindowsBySessionID.first(where: { $0.value === closingWindow }) {
            editorWindowsBySessionID.removeValue(forKey: sessionID)
            if let session = sessionsByID[sessionID] {
                session.isPlaying = false
                try? session.saveNow()
            }
        }

        // When all project editor windows are closed, automatically show the small Recording HUD panel!
        if editorWindowsBySessionID.isEmpty && !RecordingCoordinator.shared.isRecording {
            DispatchQueue.main.async {
                if self.editorWindowsBySessionID.isEmpty {
                    RecordingCoordinator.shared.showRecordingHUD()
                }
            }
        }
    }

    public func promptOpenProjectDialog() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Open Project"

        if panel.runModal() == .OK {
            for url in panel.urls where url.pathExtension.lowercased() == "nativescreen" {
                _ = openOrFocusProject(at: url)
            }
        }
    }

    public func addRecentProject(_ url: URL) {
        let standardized = url.standardizedFileURL
        recentProjectURLs.removeAll { $0.standardizedFileURL == standardized }
        recentProjectURLs.insert(standardized, at: 0)
        if recentProjectURLs.count > 20 {
            recentProjectURLs = Array(recentProjectURLs.prefix(20))
        }
        let paths = recentProjectURLs.map(\.path)
        UserDefaults.standard.set(paths, forKey: recentsDefaultsKey)
    }

    private func loadRecentProjects() {
        let paths = UserDefaults.standard.stringArray(forKey: recentsDefaultsKey) ?? []
        let fm = FileManager.default
        recentProjectURLs = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { fm.fileExists(atPath: $0.path) }
    }
}
