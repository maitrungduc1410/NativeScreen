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
    private var cameraCropWindowsBySessionID: [UUID: NSWindow] = [:]
    private var colorPresetWindowsBySessionID: [UUID: NSWindow] = [:]
    private let recentsDefaultsKey = "NativeScreen.RecentProjects"

    private override init() {
        super.init()
        loadRecentProjects()
    }

    public var hasOpenEditorWindows: Bool {
        !editorWindowsBySessionID.isEmpty
    }

    public static var defaultProjectsDirectory: URL {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let dir = homeDir.appendingPathComponent("Native Screen Projects", isDirectory: true)
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

    ///Editor Window Minimum Dimensions.
    public static let minEditorWindowWidth: CGFloat = 1280.0
    public static let minEditorWindowHeight: CGFloat = 780.0

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

        let minWinSize = NSSize(width: Self.minEditorWindowWidth, height: Self.minEditorWindowHeight)

        let editorView = ProjectEditorWindowView(session: session)
            .ignoresSafeArea(.container, edges: .top)
            .frame(minWidth: Self.minEditorWindowWidth, minHeight: Self.minEditorWindowHeight)
        let hostingController = NSHostingController(rootView: editorView)
        hostingController.sizingOptions = [.minSize]

        // Default every newly opened project Editor window to fill the active monitor's `visibleFrame` (maximized)!
        let targetScreen = WindowDiscoveryService.screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens.first
        let rawVisibleFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let initialFrame = NSRect(
            x: rawVisibleFrame.origin.x,
            y: rawVisibleFrame.origin.y,
            width: max(minWinSize.width, rawVisibleFrame.width),
            height: max(minWinSize.height, rawVisibleFrame.height)
        )

        let window = NSWindow(
            contentRect: initialFrame,
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

        // Match NativeScreen:
        // Disable macOS native Full-Screen space mode so the green traffic light button shows `+` (Zoom / Move & Resize)!
        window.collectionBehavior = [.fullScreenNone]

        let toolbar = NSToolbar(identifier: "NativeScreenUnifiedToolbar-\(session.id.uuidString)")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.delegate = self
        window.setFrame(initialFrame, display: true)

        editorWindowsBySessionID[session.id] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        if editorWindowsBySessionID.values.contains(where: { $0 === sender }) {
            return NSSize(
                width: max(Self.minEditorWindowWidth, frameSize.width),
                height: max(Self.minEditorWindowHeight, frameSize.height)
            )
        }
        return frameSize
    }

    public func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        let vf = (window.screen ?? NSScreen.main)?.visibleFrame ?? newFrame
        return NSRect(
            x: vf.origin.x,
            y: vf.origin.y,
            width: max(Self.minEditorWindowWidth, vf.width),
            height: max(Self.minEditorWindowHeight, vf.height)
        )
    }

    public func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        toggleWindowZoom(window)
        return false
    }

    public func toggleWindowZoom(_ window: NSWindow) {
        let vf = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let isCurrentlyMaximized = abs(window.frame.width - vf.width) < 12.0 && abs(window.frame.height - vf.height) < 12.0
        if isCurrentlyMaximized {
            let restoredW = max(Self.minEditorWindowWidth, round(vf.width * 0.86))
            let restoredH = max(Self.minEditorWindowHeight, round(vf.height * 0.86))
            let restoredRect = NSRect(
                x: round(vf.midX - restoredW * 0.5),
                y: round(vf.midY - restoredH * 0.5),
                width: restoredW,
                height: restoredH
            )
            window.setFrame(restoredRect, display: true, animate: true)
        } else {
            let maxRect = NSRect(
                x: vf.origin.x,
                y: vf.origin.y,
                width: max(Self.minEditorWindowWidth, vf.width),
                height: max(Self.minEditorWindowHeight, vf.height)
            )
            window.setFrame(maxRect, display: true, animate: true)
        }
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
        cropWin.backgroundColor = NSColor(red: 0.19, green: 0.19, blue: 0.23, alpha: 1.0)
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

    // MARK: - Standalone Movable Camera Crop Window (`NSWindow`)

    public func presentCameraCropWindow(for session: ProjectSession) {
        session.isPlaying = false

        if let existingWin = cameraCropWindowsBySessionID[session.id] {
            existingWin.makeKeyAndOrderFront(nil)
            return
        }

        let camCropView = StandaloneCameraCropWindowView(session: session) { [weak self] in
            self?.closeCameraCropWindow(for: session.id)
        }
        .ignoresSafeArea(.container, edges: .top)

        let hostingController = NSHostingController(rootView: camCropView)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        win.contentViewController = hostingController
        win.minSize = NSSize(width: 720, height: 520)
        win.title = "Crop camera — \(session.document.name)"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.backgroundColor = NSColor(red: 0.19, green: 0.19, blue: 0.23, alpha: 1.0)
        win.isMovableByWindowBackground = true

        let toolbar = NSToolbar(identifier: "NativeScreenCameraCropToolbar-\(session.id.uuidString)")
        toolbar.showsBaselineSeparator = false
        win.toolbar = toolbar
        win.toolbarStyle = .unified

        win.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        win.standardWindowButton(.zoomButton)?.isEnabled = false
        win.delegate = self

        if let parentEditorWin = editorWindowsBySessionID[session.id] {
            let pf = parentEditorWin.frame
            let cw: CGFloat = 920
            let ch: CGFloat = 640
            let x = pf.midX - cw * 0.5
            let y = pf.midY - ch * 0.5
            win.setFrame(NSRect(x: x, y: y, width: cw, height: ch), display: false)
        } else {
            win.center()
        }

        cameraCropWindowsBySessionID[session.id] = win
        win.makeKeyAndOrderFront(nil)
    }

    public func closeCameraCropWindow(for sessionID: UUID) {
        if let win = cameraCropWindowsBySessionID.removeValue(forKey: sessionID) {
            win.delegate = nil
            win.orderOut(nil)
        }
    }

    // MARK: - Standalone Movable "Color preset studio" Window (`NSWindow`)

    public func presentColorPresetStudioWindow(for session: ProjectSession) {
        session.isPlaying = false

        if let existingWin = colorPresetWindowsBySessionID[session.id] {
            existingWin.makeKeyAndOrderFront(nil)
            return
        }

        let studioView = StandaloneColorPresetStudioWindowView(session: session) { [weak self] in
            self?.closeColorPresetStudioWindow(for: session.id)
        }
        .ignoresSafeArea(.container, edges: .top)

        let hostingController = NSHostingController(rootView: studioView)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 610),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        win.contentViewController = hostingController
        win.minSize = NSSize(width: 780, height: 540)
        win.title = "Color preset studio"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.backgroundColor = NSColor(red: 0.19, green: 0.19, blue: 0.23, alpha: 1.0)
        win.isMovableByWindowBackground = true

        let toolbar = NSToolbar(identifier: "NativeScreenColorPresetToolbar-\(session.id.uuidString)")
        toolbar.showsBaselineSeparator = false
        win.toolbar = toolbar
        win.toolbarStyle = .unified

        win.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        win.standardWindowButton(.zoomButton)?.isEnabled = false
        win.delegate = self

        if let parentEditorWin = editorWindowsBySessionID[session.id] {
            let pf = parentEditorWin.frame
            let cw: CGFloat = 920
            let ch: CGFloat = 610
            let x = pf.midX - cw * 0.5
            let y = pf.midY - ch * 0.5
            win.setFrame(NSRect(x: x, y: y, width: cw, height: ch), display: false)
        } else {
            win.center()
        }

        colorPresetWindowsBySessionID[session.id] = win
        win.makeKeyAndOrderFront(nil)
    }

    public func closeColorPresetStudioWindow(for sessionID: UUID) {
        if let win = colorPresetWindowsBySessionID.removeValue(forKey: sessionID) {
            win.delegate = nil
            win.orderOut(nil)
        }
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }

        // If a standalone Studio/Crop window is closed via its red traffic light button
        if let (cropSessionID, _) = cropWindowsBySessionID.first(where: { $0.value === closingWindow }) {
            cropWindowsBySessionID.removeValue(forKey: cropSessionID)
            return
        }
        if let (camCropSessionID, _) = cameraCropWindowsBySessionID.first(where: { $0.value === closingWindow }) {
            cameraCropWindowsBySessionID.removeValue(forKey: camCropSessionID)
            return
        }
        if let (presetSessionID, _) = colorPresetWindowsBySessionID.first(where: { $0.value === closingWindow }) {
            colorPresetWindowsBySessionID.removeValue(forKey: presetSessionID)
            return
        }

        // If a Project Editor window is closed, also automatically close its associated Crop / Studio windows!
        if let (sessionID, _) = editorWindowsBySessionID.first(where: { $0.value === closingWindow }) {
            editorWindowsBySessionID.removeValue(forKey: sessionID)
            closeCropWindow(for: sessionID)
            closeCameraCropWindow(for: sessionID)
            closeColorPresetStudioWindow(for: sessionID)
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
