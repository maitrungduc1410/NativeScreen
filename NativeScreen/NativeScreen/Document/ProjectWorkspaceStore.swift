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
    private var cropWindowsBySessionID: [UUID: NSWindow] = [:]
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
            .frame(minWidth: 1180, minHeight: 740)
        let hostingController = NSHostingController(rootView: editorView)
        hostingController.sizingOptions = [.minSize]

        // Default every newly opened project Editor window to fill the active monitor's `visibleFrame` (maximized full screen)!
        let targetScreen = WindowDiscoveryService.screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens.first
        let screenVisibleFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let minWinSize = NSSize(width: 1180, height: 740)

        let window = NSWindow(
            contentRect: screenVisibleFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Crucial: prevent Objective-C over-release when the window closes while Swift holds a reference
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.minSize = minWinSize
        window.contentMinSize = minWinSize
        window.title = "\(session.document.name).nativescreen"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0)
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.fullScreenPrimary]

        let toolbar = NSToolbar(identifier: "NativeScreenUnifiedToolbar-\(session.id.uuidString)")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.delegate = self
        window.setFrame(screenVisibleFrame, display: true)

        editorWindowsBySessionID[session.id] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        return [.autoHideToolbar, .autoHideMenuBar, .fullScreen]
    }

    public func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.toolbar?.isVisible = false
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.toolbar?.isVisible = true
    }

    // MARK: - Standalone Movable Crop Window (`NSWindow` tied to Project Session)

    public func presentCropWindow(for session: ProjectSession) {
        session.isPlaying = false

        if let existingCropWin = cropWindowsBySessionID[session.id] {
            existingCropWin.makeKeyAndOrderFront(nil)
            return
        }

        let cropView = StandaloneCropWindowView(session: session) { [weak self] in
            self?.closeCropWindow(for: session.id)
        }
        .ignoresSafeArea(.container, edges: .top)

        let hostingController = NSHostingController(rootView: cropView)

        let cropWin = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        cropWin.isReleasedWhenClosed = false
        cropWin.contentViewController = hostingController
        cropWin.minSize = NSSize(width: 640, height: 480)
        cropWin.title = "Crop — \(session.document.name)"
        cropWin.titleVisibility = .hidden
        cropWin.titlebarAppearsTransparent = true
        cropWin.backgroundColor = NSColor(red: 0.14, green: 0.14, blue: 0.17, alpha: 1.0)
        cropWin.isMovableByWindowBackground = true

        let toolbar = NSToolbar(identifier: "NativeScreenCropToolbar-\(session.id.uuidString)")
        toolbar.showsBaselineSeparator = false
        cropWin.toolbar = toolbar
        cropWin.toolbarStyle = .unified

        cropWin.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        cropWin.standardWindowButton(.zoomButton)?.isEnabled = false
        cropWin.delegate = self

        // Center over the parent Editor window if available
        if let parentEditorWin = editorWindowsBySessionID[session.id] {
            let pf = parentEditorWin.frame
            let cw: CGFloat = 820
            let ch: CGFloat = 600
            let x = pf.midX - cw * 0.5
            let y = pf.midY - ch * 0.5
            cropWin.setFrame(NSRect(x: x, y: y, width: cw, height: ch), display: false)
        } else {
            cropWin.center()
        }

        cropWindowsBySessionID[session.id] = cropWin
        cropWin.makeKeyAndOrderFront(nil)
    }

    public func closeCropWindow(for sessionID: UUID) {
        if let cropWin = cropWindowsBySessionID.removeValue(forKey: sessionID) {
            cropWin.delegate = nil
            cropWin.orderOut(nil)
        }
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }

        // If the standalone Crop window is closed via its red traffic light button
        if let (cropSessionID, _) = cropWindowsBySessionID.first(where: { $0.value === closingWindow }) {
            cropWindowsBySessionID.removeValue(forKey: cropSessionID)
            return
        }

        // If a Project Editor window is closed, also automatically close its associated Crop window!
        if let (sessionID, _) = editorWindowsBySessionID.first(where: { $0.value === closingWindow }) {
            editorWindowsBySessionID.removeValue(forKey: sessionID)
            closeCropWindow(for: sessionID)
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
