import Foundation
import Observation
import AppKit

/// Global registry that manages multiple simultaneously open `.nativescreen` project windows
/// as well as recent projects.
@Observable
@MainActor
public final class ProjectWorkspaceStore {
    public static let shared = ProjectWorkspaceStore()

    public var sessionsByID: [UUID: ProjectSession] = [:]
    public var recentProjectURLs: [URL] = []

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

    public func closeSession(id: UUID) {
        if let session = sessionsByID[id] {
            session.isPlaying = false
            try? session.saveNow()
        }
        sessionsByID.removeValue(forKey: id)
    }

    public func openOrFocusProject(at url: URL) -> ProjectSession? {
        let standardized = url.standardizedFileURL
        if let existing = sessionsByID.values.first(where: { $0.packageURL.standardizedFileURL == standardized }) {
            addRecentProject(standardized)
            return existing
        }
        guard let loaded = try? ProjectSession.load(from: standardized) else {
            return nil
        }
        registerSession(loaded)
        return loaded
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
