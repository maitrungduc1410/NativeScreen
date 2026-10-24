import Foundation
import Observation
import AppKit

/// Global registry that manages multiple simultaneously open `.nativescreen` project windows
/// and coordinates showing/hiding the floating Recording HUD panel automatically:
/// - When the app launches with 0 open projects -> shows the small floating Recording HUD panel.
/// - When any project window opens -> hides the Recording HUD panel.
/// - When the last open project window closes -> automatically re-shows the small Recording HUD panel!
@Observable
@MainActor
public final class ProjectWorkspaceStore {
    public static let shared = ProjectWorkspaceStore()

    public var sessionsByID: [UUID: ProjectSession] = [:]
    public var openEditorWindowIDs: Set<UUID> = []
    public var recentProjectURLs: [URL] = []

    /// Callback provided by the app root to open a SwiftUI Editor window for a `ProjectSession.id`.
    public var openEditorWindowHandler: ((UUID) -> Void)?

    private let recentsDefaultsKey = "NativeScreen.RecentProjects"

    private init() {
        loadRecentProjects()
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

    public func editorWindowDidAppear(sessionID: UUID) {
        openEditorWindowIDs.insert(sessionID)
        // Automatically hide the small Recording HUD when a project window opens
        if !RecordingCoordinator.shared.isRecording {
            RecordingCoordinator.shared.hideRecordingHUD()
        }
    }

    public func editorWindowDidDisappear(sessionID: UUID) {
        openEditorWindowIDs.remove(sessionID)
        if let session = sessionsByID[sessionID] {
            session.isPlaying = false
            try? session.saveNow()
        }
        // When all project editor windows are closed, automatically show the small Recording HUD!
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self = self else { return }
            if self.openEditorWindowIDs.isEmpty && !RecordingCoordinator.shared.isHUDVisible {
                RecordingCoordinator.shared.showRecordingHUD()
            }
        }
    }

    public func openOrFocusProject(at url: URL) -> ProjectSession? {
        let standardized = url.standardizedFileURL
        if let existing = sessionsByID.values.first(where: { $0.packageURL.standardizedFileURL == standardized }) {
            addRecentProject(standardized)
            if !RecordingCoordinator.shared.isRecording {
                RecordingCoordinator.shared.hideRecordingHUD()
            }
            openEditorWindowHandler?(existing.id)
            return existing
        }
        guard let loaded = try? ProjectSession.load(from: standardized) else {
            return nil
        }
        registerSession(loaded)
        if !RecordingCoordinator.shared.isRecording {
            RecordingCoordinator.shared.hideRecordingHUD()
        }
        openEditorWindowHandler?(loaded.id)
        return loaded
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
