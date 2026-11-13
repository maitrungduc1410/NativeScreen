import Foundation
import Darwin

/// Folders and projects the sandboxed App Store build may open again after a relaunch (ADR-85).
///
/// A sandboxed app reaches a file outside its container only while the user's grant lasts: a pick in an open panel or
/// a project opened from Finder works until the app quits. Each such place is kept as a security-scoped bookmark and
/// reopened at launch. Outside the App Store build every call does nothing, since nothing is sandboxed there.
enum SandboxAccess {
    private static let defaultsKey = "NativeScreen.SecurityScopedBookmarks"
    private static let maxBookmarks = 64
    /// URLs whose access was started in this run, by standardized path.
    nonisolated(unsafe) private static var started: [String: URL] = [:]

    /// The user's home folder. In the sandbox `homeDirectoryForCurrentUser` is the app's container instead.
    static var realHomeDirectory: URL {
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Keeps `url` reachable in later runs. Call it while the grant is valid (right after a pick or an open).
    static func remember(_ url: URL) {
        #if APPSTORE
        let path = url.standardizedFileURL.path
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return
        }
        var stored = storedBookmarks()
        stored.removeAll { $0.path == path }
        stored.insert((path, data), at: 0)
        save(Array(stored.prefix(maxBookmarks)))
        start(url, path: path)
        #endif
    }

    /// Reopens every remembered place. Call once at launch, before settings and recent projects are read.
    static func restore() {
        #if APPSTORE
        var kept: [(path: String, data: Data)] = []
        for entry in storedBookmarks() {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: entry.data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
                continue // Deleted or no longer reachable.
            }
            let path = url.standardizedFileURL.path
            start(url, path: path)
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                kept.append((path, fresh))
            } else {
                kept.append((path, entry.data))
            }
        }
        save(kept)
        #endif
    }

    private static func start(_ url: URL, path: String) {
        guard started[path] == nil else { return }
        // Kept for the whole run: projects and folders may be read or written at any time.
        if url.startAccessingSecurityScopedResource() {
            started[path] = url
        }
    }

    private static func storedBookmarks() -> [(path: String, data: Data)] {
        guard let list = UserDefaults.standard.array(forKey: defaultsKey) as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let path = item["path"] as? String, let data = item["bookmark"] as? Data else { return nil }
            return (path, data)
        }
    }

    private static func save(_ list: [(path: String, data: Data)]) {
        UserDefaults.standard.set(list.map { ["path": $0.path, "bookmark": $0.data] }, forKey: defaultsKey)
    }
}
