import Foundation
import SwiftUI
import Observation
import AppKit
import UniformTypeIdentifiers

/// Global registry that manages multiple simultaneously open `.nativescreen` project `NSWindow`s
/// and coordinates showing/hiding the floating Recording HUD panel automatically:
/// - On app launch (0 open projects) -> shows only the small floating Recording HUD panel.
/// - When any project Editor window opens -> hides the Recording HUD panel.
/// - When all project Editor windows are closed -> automatically re-shows the small Recording HUD panel.
@Observable
@MainActor
public final class ProjectWorkspaceStore: NSObject, NSWindowDelegate {
    public static let shared = ProjectWorkspaceStore()

    /// Posted with the `ProjectSession` as object right before its editor window is torn down, so views can remove
    /// `NSEvent` monitors (SwiftUI does not run `onDisappear` when the hosting view is simply released).
    public static let editorWillCloseNotification = Notification.Name("NativeScreen.EditorWillClose")

    public var sessionsByID: [UUID: ProjectSession] = [:]
    public var recentProjectURLs: [URL] = []
    /// Session of the editor window that is (or was last) key. App menu commands act on it.
    public private(set) var activeSessionID: UUID?

    public var activeSession: ProjectSession? {
        guard let id = activeSessionID, editorWindowsBySessionID[id] != nil else { return nil }
        return sessionsByID[id]
    }

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

    /// `Settings > Recording > Save new projects to` (defaults to `~/Native Screen Projects`).
    public static var defaultProjectsDirectory: URL {
        let path = UserDefaults.standard.string(forKey: AppSettings.Keys.projectsDirectory) ?? AppSettings.defaultProjectsDirectoryPath
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The active project's editor window as a capture target, or `nil` if it is not on screen (minimized, for example).
    public var activeEditorCaptureWindow: CapturableWindowInfo? {
        guard let id = activeSessionID, let window = editorWindowsBySessionID[id] else { return nil }
        return WindowDiscoveryService.listFrontToBackWindows(resolveCornerRadius: false).first { $0.id == UInt32(window.windowNumber) }
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
        window.backgroundColor = NSColor.surface(red: 0.05, green: 0.05, blue: 0.07)
        window.isMovableByWindowBackground = false

        // Not full-screenable, but the green button still zooms:
        // Disable macOS native Full-Screen space mode so the green traffic light button shows `+` (Zoom / Move & Resize)!
        window.collectionBehavior = [.fullScreenNone]

        let toolbar = NSToolbar(identifier: "NativeScreenUnifiedToolbar-\(session.id.uuidString)")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.delegate = self
        window.setFrame(initialFrame, display: true)

        editorWindowsBySessionID[session.id] = window
        activeSessionID = session.id
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
        cropWin.title = String(localized: "Crop: \(session.document.name)")
        cropWin.titleVisibility = .hidden
        cropWin.titlebarAppearsTransparent = true
        cropWin.backgroundColor = .surface(red: 0.19, green: 0.19, blue: 0.23)
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
        win.title = String(localized: "Crop camera: \(session.document.name)")
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.backgroundColor = .surface(red: 0.19, green: 0.19, blue: 0.23)
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
        win.title = String(localized: "Color preset studio")
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.backgroundColor = .surface(red: 0.19, green: 0.19, blue: 0.23)
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

    /// With autosave off, closing an editor with unsaved edits asks whether to save them.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let (sessionID, _) = editorWindowsBySessionID.first(where: { $0.value === sender }),
              let session = sessionsByID[sessionID],
              session.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Do you want to save the changes made to “\(session.document.name)”?")
        alert.informativeText = String(localized: "Your changes will be lost if you don’t save them.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let dontSave = alert.addButton(withTitle: String(localized: "Don’t Save"))
        dontSave.hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            try? session.saveNow()
            return true
        case .alertThirdButtonReturn:
            session.discardUnsavedChanges()
            return true
        default:
            return false
        }
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let (sessionID, _) = editorWindowsBySessionID.first(where: { $0.value === window }) else { return }
        activeSessionID = sessionID
    }

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
            if activeSessionID == sessionID {
                activeSessionID = editorWindowsBySessionID.keys.first
            }
            closeCropWindow(for: sessionID)
            closeCameraCropWindow(for: sessionID)
            closeColorPresetStudioWindow(for: sessionID)
            if let session = sessionsByID.removeValue(forKey: sessionID) {
                NotificationCenter.default.post(name: Self.editorWillCloseNotification, object: session)
                session.prepareForClose()
                if !session.isDeletedFromDisk {
                    if AppSettings.shared.autosaveEnabled {
                        try? session.saveNow()
                    }
                    AppSettings.shared.rememberLastProjectStyle(session.document)
                }
            }
            // AppKit and SwiftUI's focus tracking can keep a closed window alive until another one becomes key.
            // Dropping the hosting controller frees the preview (MTKView, players, compositor) right away. The local
            // pool matters: otherwise the controller sits in the event loop's pool until the next event arrives.
            closingWindow.delegate = nil
            DispatchQueue.main.async {
                autoreleasepool {
                    closingWindow.contentViewController = nil
                }
            }
        }

        // With no editor left, nothing shows these images; they are rebuilt on demand when a project opens.
        if editorWindowsBySessionID.isEmpty {
            SystemWallpaperCatalog.purgeThumbnailCache()
            GradedWebcamPortraitView.purgeCaches()
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
        panel.prompt = String(localized: "Open Project")

        if panel.runModal() == .OK {
            for url in panel.urls where url.pathExtension.lowercased() == "nativescreen" {
                _ = openOrFocusProject(at: url)
            }
        }
    }

    // MARK: - App Menu Actions (`File`, `Export`, `Window`)

    /// Opens the most recently used project that still exists on disk (`File > Open last project`).
    public func openLastProject() {
        guard let url = recentProjectURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        openOrFocusProject(at: url)
    }

    public func clearRecentProjects() {
        recentProjectURLs.removeAll()
        UserDefaults.standard.set([String](), forKey: recentsDefaultsKey)
    }

    /// `File > Show previous projects`: reveals the folder new recordings are saved to.
    public func revealProjectsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.defaultProjectsDirectory])
    }

    /// `File > Save as...`: saves, copies the whole package to a new location and continues editing the copy.
    public func saveActiveProjectAs() {
        guard let session = activeSession else { return }
        session.isPlaying = false
        try? session.saveNow()

        let panel = NSSavePanel()
        panel.message = String(localized: "Save a copy of this project")
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [UTType(filenameExtension: "nativescreen") ?? .package]
        panel.directoryURL = session.packageURL.deletingLastPathComponent()
        panel.nameFieldStringValue = "\(session.document.name) copy.nativescreen"
        guard panel.runModal() == .OK, var destination = panel.url else { return }
        if destination.pathExtension.lowercased() != "nativescreen" {
            destination.appendPathExtension("nativescreen")
        }
        guard destination.standardizedFileURL != session.packageURL.standardizedFileURL else { return }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            }
            // APFS clones the media files, so this is instant on the same volume.
            try FileManager.default.copyItem(at: session.packageURL, to: destination)
            var copiedDoc = session.document
            copiedDoc.name = destination.deletingPathExtension().lastPathComponent
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(copiedDoc).write(to: destination.appendingPathComponent("project.json"), options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        editorWindowsBySessionID[session.id]?.close()
        openOrFocusProject(at: destination)
    }

    /// `Window > Reset windows positions`: maximizes every editor window on the main display and re-centers the recording bar.
    public func resetWindowPositions() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        for window in editorWindowsBySessionID.values {
            window.setFrame(NSRect(
                x: vf.origin.x,
                y: vf.origin.y,
                width: max(Self.minEditorWindowWidth, vf.width),
                height: max(Self.minEditorWindowHeight, vf.height)
            ), display: true, animate: true)
        }
        RecordingCoordinator.shared.resetHUDPosition()
    }

    /// Folder clipboard exports are written to (kept so `Export > Show previous clipboard exports` can list them).
    public static var clipboardExportsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("NativeScreen/Clipboard Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Newest first.
    public static func recentClipboardExports(limit: Int = 10) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: clipboardExportsDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        let dated = urls.map { url in
            (url, (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
        }
        return dated.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// `Export > Extract raw recording files...`: copies the untouched recorded media (screen, camera, microphone) to a folder.
    public func extractRawRecordingFiles() {
        guard let session = activeSession else { return }
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose where to save the raw recording files")
        panel.prompt = String(localized: "Extract")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }

        let recordingDir = session.packageURL.appendingPathComponent("recording", isDirectory: true)
        let tracks = session.metadata.tracks
        let names = Set([tracks.displayVideo, tracks.webcamVideo, tracks.microphoneAudio].compactMap { $0 })
        var destination = parent.appendingPathComponent("\(session.document.name) raw files", isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = parent.appendingPathComponent("\(session.document.name) raw files \(suffix)", isDirectory: true)
            suffix += 1
        }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in names.sorted() {
                let source = recordingDir.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try FileManager.default.copyItem(at: source, to: destination.appendingPathComponent(name))
            }
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }

    /// Moves a project's package to the Trash and forgets it, so closing its window cannot save it back.
    /// Closes a project's editor window (the caller saves first; unsaved changes would ask).
    public func closeEditorWindow(for session: ProjectSession) {
        editorWindowsBySessionID[session.id]?.close()
    }

    public func trashProject(_ session: ProjectSession) {
        let url = session.packageURL.standardizedFileURL
        guard (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil else { return }
        session.markDeletedFromDisk()
        recentProjectURLs.removeAll { $0.standardizedFileURL == url }
        UserDefaults.standard.set(recentProjectURLs.map(\.path), forKey: recentsDefaultsKey)
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

// MARK: - Presets Store

public struct ProjectPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var canvas: CanvasConfig
    public var background: BackgroundConfig
    public var frameStyle: FrameStyleConfig
    public var cursor: CursorConfig
    public var camera: CameraConfig
    public var motion: MotionConfig
    public var audio: AudioConfig

    public init(
        id: String = UUID().uuidString,
        name: String,
        canvas: CanvasConfig = CanvasConfig(),
        background: BackgroundConfig = BackgroundConfig(),
        frameStyle: FrameStyleConfig = FrameStyleConfig(),
        cursor: CursorConfig = CursorConfig(),
        camera: CameraConfig = CameraConfig(),
        motion: MotionConfig = MotionConfig(),
        audio: AudioConfig = AudioConfig()
    ) {
        self.id = id
        self.name = name
        self.canvas = canvas
        self.background = background
        self.frameStyle = frameStyle
        self.cursor = cursor
        self.camera = camera
        self.motion = motion
        self.audio = audio
    }

    public init(name: String, from doc: ProjectDocument) {
        self.id = UUID().uuidString
        self.name = name
        self.canvas = doc.canvas
        self.background = doc.background
        self.frameStyle = doc.frameStyle
        self.cursor = doc.cursor
        self.camera = doc.camera
        self.motion = doc.motion
        self.audio = doc.audio
    }

    public func matchesDocument(_ doc: ProjectDocument) -> Bool {
        var normCanvas = doc.canvas
        normCanvas.cropRect01 = canvas.cropRect01
        return canvas == normCanvas
            && background.type == doc.background.type
            && background.solidColor == doc.background.solidColor
            && background.gradient == doc.background.gradient
            && background.meshPresetId == doc.background.meshPresetId
            && abs(background.blurRadius - doc.background.blurRadius) < 0.01
            && frameStyle == doc.frameStyle
            && cursor == doc.cursor
            && camera.layoutMode == doc.camera.layoutMode
            && camera.colorGradePreset == doc.camera.colorGradePreset
            && abs(camera.sizeRatio - doc.camera.sizeRatio) < 0.01
            && motion == doc.motion
    }

    public func apply(to doc: inout ProjectDocument) {
        let existingCrop = doc.canvas.cropRect01
        doc.canvas = canvas
        doc.canvas.cropRect01 = existingCrop
        doc.background = background
        doc.frameStyle = frameStyle
        doc.cursor = cursor
        let existingCamEnabled = doc.camera.enabled
        let existingCamCrop = doc.camera.cropRect01
        doc.camera = camera
        doc.camera.enabled = existingCamEnabled
        doc.camera.cropRect01 = existingCamCrop
        doc.motion = motion
        doc.audio.microphoneAudioPreset = audio.microphoneAudioPreset
    }
}

@Observable
@MainActor
public final class ProjectPresetsStore {
    public static let shared = ProjectPresetsStore()

    public var presets: [ProjectPreset] = []
    public var defaultPresetId: String? = nil

    private let defaultPresetDefaultsKey = "NativeScreen.DefaultPresetID"

    /// `Settings > Editing > Save presets in`.
    public nonisolated static var presetsDirectoryURL: URL {
        let path = UserDefaults.standard.string(forKey: "NativeScreen.Settings.PresetsDirectory") ?? AppSettings.defaultPresetsDirectoryPath
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        self.defaultPresetId = UserDefaults.standard.string(forKey: defaultPresetDefaultsKey)
        loadPresetsFromDisk()
    }

    public func fileURL(for preset: ProjectPreset) -> URL {
        let safeFile = preset.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = safeFile.isEmpty ? preset.id : safeFile
        return Self.presetsDirectoryURL.appendingPathComponent("\(base).json")
    }

    public func loadPresetsFromDisk() {
        let fm = FileManager.default
        let dir = Self.presetsDirectoryURL
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.filter {
            $0.pathExtension.lowercased() == "json"
        } ?? []

        let decoder = JSONDecoder()
        var loaded: [ProjectPreset] = []
        for url in urls {
            if let data = try? Data(contentsOf: url),
               let p = try? decoder.decode(ProjectPreset.self, from: data) {
                loaded.append(p)
            }
        }
        if loaded.isEmpty {
            let defaults = Self.seedBuiltInPresets()
            for p in defaults {
                savePresetToDisk(p)
            }
            loaded = defaults
        }
        loaded.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.presets = loaded
    }

    private static func seedBuiltInPresets() -> [ProjectPreset] {
        let studioDefault = ProjectPreset(
            id: "preset-default-studio",
            name: "Default Studio",
            canvas: CanvasConfig(aspectRatioMode: .preset, aspectRatioPreset: .widescreen16x9, paddingRatio: 0.10),
            background: BackgroundConfig(type: .mesh, meshPresetId: "spring-aurora"),
            frameStyle: FrameStyleConfig(borderRadius: 16.0, inset: FrameInsetConfig(enabled: true), shadow: FrameShadowConfig(enabled: true, isDirectional: true, intensity: 0.42)),
            cursor: CursorConfig(scale: 1.6, themeId: CursorThemePreset.defaultThemeId),
            camera: CameraConfig(layoutMode: .overlay, colorGradePreset: .studio),
            motion: MotionConfig(cameraSpring: .defaultCamera, motionBlurIntensity: 1.0)
        )
        let darkCinema = ProjectPreset(
            id: "preset-macos-dark-cinema",
            name: "macOS Dark Cinema",
            canvas: CanvasConfig(aspectRatioMode: .preset, aspectRatioPreset: .widescreen16x9, paddingRatio: 0.12),
            background: BackgroundConfig(
                type: .gradient,
                gradient: GradientConfig(stops: [
                    GradientStopConfig(color: "#0F172A", location: 0.0),
                    GradientStopConfig(color: "#1E1B4B", location: 1.0)
                ])
            ),
            frameStyle: FrameStyleConfig(borderRadius: 20.0, inset: FrameInsetConfig(enabled: true, size: 1.5, opacity: 0.22), shadow: FrameShadowConfig(enabled: true, isDirectional: true, intensity: 0.58, blur: 44.0, distance: 26.0)),
            cursor: CursorConfig(scale: 1.8, themeId: CursorThemePreset.defaultThemeId),
            camera: CameraConfig(layoutMode: .overlay, colorGradePreset: .cinema),
            motion: MotionConfig(cameraSpring: .focusedCamera, motionBlurIntensity: 1.0)
        )
        let socialVertical = ProjectPreset(
            id: "preset-social-vertical",
            name: "Social Vertical 9:16",
            canvas: CanvasConfig(aspectRatioMode: .preset, aspectRatioPreset: .vertical9x16, paddingRatio: 0.08),
            background: BackgroundConfig(
                type: .gradient,
                gradient: GradientConfig(stops: [
                    GradientStopConfig(color: "#4776E6", location: 0.0),
                    GradientStopConfig(color: "#8E54E9", location: 1.0)
                ])
            ),
            frameStyle: FrameStyleConfig(borderRadius: 18.0, inset: FrameInsetConfig(enabled: true), shadow: FrameShadowConfig(enabled: true, isDirectional: true, intensity: 0.48)),
            cursor: CursorConfig(scale: 1.9, themeId: CursorThemePreset.defaultThemeId),
            camera: CameraConfig(layoutMode: .splitScreen, splitScreenRatio01: 0.50, colorGradePreset: .punch),
            motion: MotionConfig(cameraSpring: .focusedCamera, motionBlurIntensity: 1.0)
        )
        return [studioDefault, darkCinema, socialVertical]
    }

    private func savePresetToDisk(_ preset: ProjectPreset) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(preset) {
            try? data.write(to: fileURL(for: preset), options: .atomic)
        }
    }

    /// `File > Import preset...`: imports preset `.json` files (as written to the presets folder) shared by another user or machine.
    /// An imported preset gets a fresh id so it never overwrites an existing one.
    public func promptImportPresets() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose preset files to import")
        panel.prompt = String(localized: "Import")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }

        var failed: [String] = []
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url),
                  var preset = try? JSONDecoder().decode(ProjectPreset.self, from: data) else {
                failed.append(url.lastPathComponent)
                continue
            }
            preset.id = UUID().uuidString
            presets.append(preset)
            savePresetToDisk(preset)
        }
        presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if !failed.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(localized: "Some files are not NativeScreen presets")
            alert.informativeText = failed.joined(separator: "\n")
            alert.runModal()
        }
    }

    public func addPreset(name: String, from session: ProjectSession) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = ProjectPreset(name: trimmed, from: session.document)
        savePresetToDisk(preset)
        presets.append(preset)
        presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        session.showToast("Preset created")
    }

    public func applyPreset(_ preset: ProjectPreset, to session: ProjectSession) {
        session.mutate { doc in
            preset.apply(to: &doc)
        }
        session.showToast("Preset applied")
    }

    public func syncPresetWithProject(_ preset: ProjectPreset, session: ProjectSession) {
        guard let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        var updated = ProjectPreset(name: preset.name, from: session.document)
        updated.id = preset.id
        presets[idx] = updated
        savePresetToDisk(updated)
        session.showToast("Preset updated to match")
    }

    public func renamePreset(_ preset: ProjectPreset, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        let oldURL = fileURL(for: presets[idx])
        try? FileManager.default.removeItem(at: oldURL)
        presets[idx].name = trimmed
        savePresetToDisk(presets[idx])
        presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func removePreset(_ preset: ProjectPreset) {
        let url = fileURL(for: preset)
        try? FileManager.default.removeItem(at: url)
        presets.removeAll { $0.id == preset.id }
        if defaultPresetId == preset.id {
            defaultPresetId = nil
            UserDefaults.standard.removeObject(forKey: defaultPresetDefaultsKey)
        }
    }

    public func toggleDefaultPreset(_ preset: ProjectPreset) {
        if defaultPresetId == preset.id {
            defaultPresetId = nil
            UserDefaults.standard.removeObject(forKey: defaultPresetDefaultsKey)
        } else {
            defaultPresetId = preset.id
            UserDefaults.standard.set(preset.id, forKey: defaultPresetDefaultsKey)
        }
    }

    public var defaultPreset: ProjectPreset? {
        guard let defId = defaultPresetId else { return nil }
        return presets.first(where: { $0.id == defId })
    }
}
