import Foundation
import SwiftUI
import AppKit
import Observation
import ScreenCaptureKit

/// Custom `NSPanel` that allows dragging the Recording HUD from ANYWHERE on the bar (even when pressing on buttons),
/// while still allowing normal clicks on buttons, and persists its global multi-monitor position.
private final class DraggableHUDPanel: NSPanel {
    var onPanelMoved: ((NSPoint) -> Void)?

    private var mouseDownScreenPoint: NSPoint = .zero
    private var mouseDownWindowOrigin: NSPoint = .zero
    private var isDraggingWindow: Bool = false

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            mouseDownScreenPoint = NSEvent.mouseLocation
            mouseDownWindowOrigin = frame.origin
            isDraggingWindow = false
            super.sendEvent(event)

        case .leftMouseDragged:
            let current = NSEvent.mouseLocation
            let dx = current.x - mouseDownScreenPoint.x
            let dy = current.y - mouseDownScreenPoint.y
            if !isDraggingWindow && hypot(dx, dy) > 3.5 {
                isDraggingWindow = true
            }
            if isDraggingWindow {
                let newOrigin = NSPoint(x: mouseDownWindowOrigin.x + dx, y: mouseDownWindowOrigin.y + dy)
                setFrameOrigin(newOrigin)
                onPanelMoved?(newOrigin)
                return
            }
            super.sendEvent(event)

        case .leftMouseUp:
            if isDraggingWindow {
                isDraggingWindow = false
                onPanelMoved?(frame.origin)
                // Send a synthetic mouse-up outside any button so SwiftUI buttons don't fire their action after a drag
                if let cancelEvent = NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: NSPoint(x: -100, y: -100),
                    modifierFlags: event.modifierFlags,
                    timestamp: event.timestamp,
                    windowNumber: windowNumber,
                    context: nil,
                    eventNumber: event.eventNumber,
                    clickCount: 0,
                    pressure: 0
                ) {
                    super.sendEvent(cancelEvent)
                }
                return
            }
            super.sendEvent(event)

        default:
            super.sendEvent(event)
        }
    }
}

/// Coordinates the floating Recording HUD (`NSPanel`), multi-monitor interactive Window/Display/Area Picker overlays,
/// `ESC` key cancellation, and the `ScreenCaptureEngine` + `TelemetryRecorder`.
@Observable
@MainActor
public final class RecordingCoordinator {
    public static let shared = RecordingCoordinator()

    public var isHUDVisible: Bool = false
    public var isRecording: Bool = false
    public var isPickingTarget: Bool = false
    public var recordingElapsedSeconds: TimeInterval = 0.0
    public var selectedMode: CaptureTargetMode = .window
    public var captureMicrophone: Bool = false
    public var captureSystemAudio: Bool = true

    // Multi-Monitor Window, Display & Area Picker State
    public var hoveredWindow: CapturableWindowInfo?
    public var hoveredDisplayID: CGDirectDisplayID = CGMainDisplayID()
    public var selectedAreaRectQuartz: CGRect = CGRect(x: 240, y: 160, width: 1280, height: 720)
    public var lastErrorMessage: String?

    public var onRecordingCompleted: ((ProjectSession) -> Void)?

    private var hudPanel: DraggableHUDPanel?
    private var pickerOverlayWindows: [NSWindow] = []
    private var hoverTimer: Timer?
    private var recordingTimer: Timer?
    private var recordingStartUptime: TimeInterval = 0
    private var escLocalMonitor: Any?
    private var escGlobalMonitor: Any?

    private var captureEngine: ScreenCaptureEngine?
    private var telemetryRecorder: TelemetryRecorder?
    private var activePackageURL: URL?
    private var activeTargetMetadata: CaptureTargetMetadata?

    private let savedHUDOriginXKey = "NativeScreen.HUDPanel.OriginX"
    private let savedHUDOriginYKey = "NativeScreen.HUDPanel.OriginY"
    private let hasSavedHUDOriginKey = "NativeScreen.HUDPanel.HasSavedOrigin"

    private init() {}

    // MARK: - Show / Hide Floating Recording HUD Bar (`NSPanel`)

    public func showRecordingHUD() {
        let panelW: CGFloat = 840
        let panelH: CGFloat = 66

        if hudPanel == nil {
            let panel = DraggableHUDPanel(
                contentRect: NSRect(x: 0, y: 0, width: panelW, height: panelH),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.level = .screenSaver
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.onPanelMoved = { [weak self] newOrigin in
                self?.saveHUDPanelOrigin(newOrigin)
            }

            let hostingView = NSHostingView(rootView: RecordingHUDBarView(coordinator: self))
            hostingView.sizingOptions = []
            panel.contentView = hostingView
            self.hudPanel = panel
        }

        if let panel = hudPanel {
            let restoredOrigin = restoredAndClampedHUDOrigin(panelSize: NSSize(width: panelW, height: panelH))
            panel.setFrame(NSRect(origin: restoredOrigin, size: NSSize(width: panelW, height: panelH)), display: true)
            panel.orderFrontRegardless()
        }

        // Crucial: on launch or showRecordingHUD, ONLY show the small HUD bar!
        // Do NOT automatically enter window/area/display selection mode until the user clicks a mode button.
        isPickingTarget = false
        stopPickerOverlay()
        isHUDVisible = true
        installEscapeKeyMonitors()
    }

    private func saveHUDPanelOrigin(_ origin: NSPoint) {
        let defaults = UserDefaults.standard
        defaults.set(Double(origin.x), forKey: savedHUDOriginXKey)
        defaults.set(Double(origin.y), forKey: savedHUDOriginYKey)
        defaults.set(true, forKey: hasSavedHUDOriginKey)
    }

    /// Restores the saved multi-monitor HUD position and clamps it so 100% of the panel is fully visible inside the target monitor.
    private func restoredAndClampedHUDOrigin(panelSize: NSSize) -> NSPoint {
        let defaults = UserDefaults.standard
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return NSPoint(x: 200, y: 80)
        }

        if defaults.bool(forKey: hasSavedHUDOriginKey) {
            let savedX = CGFloat(defaults.double(forKey: savedHUDOriginXKey))
            let savedY = CGFloat(defaults.double(forKey: savedHUDOriginYKey))
            let candidateRect = NSRect(x: savedX, y: savedY, width: panelSize.width, height: panelSize.height)
            let candidateCenter = NSPoint(x: candidateRect.midX, y: candidateRect.midY)

            // Find the monitor that contains `candidateCenter`, or has the closest visibleFrame to `candidateCenter`
            let bestScreen = screens.min { s1, s2 in
                let d1 = distanceSquared(from: candidateCenter, to: s1.visibleFrame)
                let d2 = distanceSquared(from: candidateCenter, to: s2.visibleFrame)
                return d1 < d2
            } ?? screens[0]

            let vf = bestScreen.visibleFrame
            let margin: CGFloat = 10.0
            let minX = vf.minX + margin
            let maxX = max(minX, vf.maxX - panelSize.width - margin)
            let minY = vf.minY + margin
            let maxY = max(minY, vf.maxY - panelSize.height - margin)

            let clampedX = min(max(savedX, minX), maxX)
            let clampedY = min(max(savedY, minY), maxY)
            let clampedOrigin = NSPoint(x: clampedX, y: clampedY)
            saveHUDPanelOrigin(clampedOrigin)
            return clampedOrigin
        }

        let defaultScreen = WindowDiscoveryService.screenUnderMouse() ?? NSScreen.main ?? screens[0]
        let vf = defaultScreen.visibleFrame
        return NSPoint(x: vf.midX - panelSize.width * 0.5, y: vf.minY + 42)
    }

    private func distanceSquared(from pt: NSPoint, to rect: NSRect) -> CGFloat {
        let cx = min(max(pt.x, rect.minX), rect.maxX)
        let cy = min(max(pt.y, rect.minY), rect.maxY)
        let dx = pt.x - cx
        let dy = pt.y - cy
        return dx * dx + dy * dy
    }

    public func hideRecordingHUD() {
        isPickingTarget = false
        stopPickerOverlay()
        removeEscapeKeyMonitors()
        hudPanel?.orderOut(nil)
        isHUDVisible = false
    }

    public func selectMode(_ mode: CaptureTargetMode) {
        if selectedMode == mode && isPickingTarget {
            // Clicking the already-active mode toggles off the picker overlay back to the plain HUD bar
            isPickingTarget = false
            stopPickerOverlay()
            return
        }
        selectedMode = mode
        isPickingTarget = true
        if mode == .area, let screen = WindowDiscoveryService.screenUnderMouse() {
            let qFrame = WindowDiscoveryService.quartzFrame(for: screen)
            let w = min(1280.0, qFrame.width * 0.7)
            let h = min(720.0, qFrame.height * 0.7)
            selectedAreaRectQuartz = CGRect(
                x: qFrame.midX - w * 0.5,
                y: qFrame.midY - h * 0.5,
                width: w,
                height: h
            )
        }
        updatePickerOverlayForSelectedMode()
    }

    // MARK: - `ESC` Hotkey Monitor (Cancels Picker Overlay first, or Closes Recording HUD)

    private func installEscapeKeyMonitors() {
        removeEscapeKeyMonitors()
        escLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC key
                Task { @MainActor [weak self] in
                    guard let self = self, !self.isRecording else { return }
                    if self.isPickingTarget {
                        self.isPickingTarget = false
                        self.stopPickerOverlay()
                    } else {
                        self.hideRecordingHUD()
                    }
                }
                return nil
            }
            return event
        }
        escGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC key
                Task { @MainActor [weak self] in
                    guard let self = self, !self.isRecording else { return }
                    if self.isPickingTarget {
                        self.isPickingTarget = false
                        self.stopPickerOverlay()
                    } else {
                        self.hideRecordingHUD()
                    }
                }
            }
        }
    }

    private func removeEscapeKeyMonitors() {
        if let local = escLocalMonitor {
            NSEvent.removeMonitor(local)
            escLocalMonitor = nil
        }
        if let global = escGlobalMonitor {
            NSEvent.removeMonitor(global)
            escGlobalMonitor = nil
        }
    }

    // MARK: - Multi-Monitor Interactive Window / Display / Area Picker Overlays

    public func updatePickerOverlayForSelectedMode() {
        guard isHUDVisible, isPickingTarget, !isRecording else {
            stopPickerOverlay()
            return
        }

        switch selectedMode {
        case .window, .area, .display:
            startPickerOverlaysAcrossAllScreens()
        case .device:
            stopPickerOverlay()
        }
    }

    private func startPickerOverlaysAcrossAllScreens() {
        stopPickerOverlay()

        // Create one overlay panel per connected monitor (`NSScreen.screens`)
        for screen in NSScreen.screens {
            let overlay = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            overlay.isReleasedWhenClosed = false
            overlay.isFloatingPanel = true
            overlay.isOpaque = false
            overlay.backgroundColor = .clear
            overlay.hasShadow = false
            overlay.level = .floating
            overlay.ignoresMouseEvents = false
            overlay.acceptsMouseMovedEvents = true
            overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let hosting = NSHostingView(
                rootView: WindowAndAreaPickerOverlayView(coordinator: self, screen: screen)
            )
            hosting.sizingOptions = []
            overlay.contentView = hosting
            overlay.setFrame(screen.frame, display: true)
            overlay.orderFrontRegardless()
            pickerOverlayWindows.append(overlay)
        }

        hudPanel?.orderFrontRegardless()

        // Poll mouse across all connected displays at 60Hz for buttery-smooth window/display tracking
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isRecording else { return }
                if let currentScreen = WindowDiscoveryService.screenUnderMouse() {
                    let dispID = WindowDiscoveryService.displayID(for: currentScreen)
                    if self.hoveredDisplayID != dispID {
                        self.hoveredDisplayID = dispID
                    }
                }
                if self.selectedMode == .window {
                    if let win = WindowDiscoveryService.topmostWindowUnderMouse() {
                        if self.hoveredWindow != win {
                            withAnimation(.spring(response: 0.20, dampingFraction: 0.86)) {
                                self.hoveredWindow = win
                            }
                        }
                    }
                }
            }
        }
    }

    private func stopPickerOverlay() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        for win in pickerOverlayWindows {
            win.orderOut(nil)
        }
        pickerOverlayWindows.removeAll()
    }

    // MARK: - Start & Stop Real Recording (Supports Any Connected Monitor)

    public func startRecording() async {
        guard !isRecording else { return }
        lastErrorMessage = nil

        do {
            let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !shareable.displays.isEmpty else {
                lastErrorMessage = "No capturable display found."
                return
            }

            let myPID = ProcessInfo.processInfo.processIdentifier
            let ownWindows = shareable.windows.filter { $0.owningApplication?.processID == myPID }

            let filter: SCContentFilter
            let logicalBounds: CGRect
            let sourceRect: CGRect?
            var targetDisplay = shareable.displays.first(where: { $0.displayID == hoveredDisplayID }) ?? shareable.displays[0]
            var targetWindowId: UInt32?
            var targetBundleId: String?
            var targetAppName: String?
            var targetWindowTitle: String?

            switch selectedMode {
            case .window:
                if let chosen = hoveredWindow ?? WindowDiscoveryService.listFrontToBackWindows().first,
                   let scWindow = shareable.windows.first(where: { $0.windowID == chosen.id }) {
                    WindowDiscoveryService.bringWindowToFront(chosen)
                    filter = SCContentFilter(desktopIndependentWindow: scWindow)
                    logicalBounds = chosen.bounds
                    sourceRect = nil
                    targetWindowId = chosen.id
                    targetBundleId = chosen.bundleId
                    targetAppName = chosen.appName
                    targetWindowTitle = chosen.title

                    // Match display where window resides
                    if let matchingScreen = NSScreen.screens.first(where: {
                        WindowDiscoveryService.quartzFrame(for: $0).intersects(chosen.bounds)
                    }) {
                        let dID = WindowDiscoveryService.displayID(for: matchingScreen)
                        if let scDisp = shareable.displays.first(where: { $0.displayID == dID }) {
                            targetDisplay = scDisp
                        }
                    }
                } else {
                    filter = SCContentFilter(display: targetDisplay, excludingWindows: ownWindows)
                    let screen = NSScreen.screens.first(where: { WindowDiscoveryService.displayID(for: $0) == targetDisplay.displayID })
                    logicalBounds = screen.map { WindowDiscoveryService.quartzFrame(for: $0) }
                        ?? CGRect(x: 0, y: 0, width: targetDisplay.width, height: targetDisplay.height)
                    sourceRect = nil
                }

            case .area:
                if let matchingScreen = NSScreen.screens.first(where: {
                    WindowDiscoveryService.quartzFrame(for: $0).intersects(selectedAreaRectQuartz)
                }) {
                    let dID = WindowDiscoveryService.displayID(for: matchingScreen)
                    if let scDisp = shareable.displays.first(where: { $0.displayID == dID }) {
                        targetDisplay = scDisp
                    }
                    let localRect = WindowDiscoveryService.localTopLeftRect(fromQuartzRect: selectedAreaRectQuartz, on: matchingScreen)
                    sourceRect = localRect
                } else {
                    sourceRect = selectedAreaRectQuartz
                }
                filter = SCContentFilter(display: targetDisplay, excludingWindows: ownWindows)
                logicalBounds = selectedAreaRectQuartz

            case .display, .device:
                filter = SCContentFilter(display: targetDisplay, excludingWindows: ownWindows)
                let screen = NSScreen.screens.first(where: { WindowDiscoveryService.displayID(for: $0) == targetDisplay.displayID })
                logicalBounds = screen.map { WindowDiscoveryService.quartzFrame(for: $0) }
                    ?? CGRect(x: 0, y: 0, width: targetDisplay.width, height: targetDisplay.height)
                sourceRect = nil
            }

            let targetNSScreen = NSScreen.screens.first(where: {
                WindowDiscoveryService.displayID(for: $0) == targetDisplay.displayID
            }) ?? NSScreen.main
            let screenScale = targetNSScreen?.backingScaleFactor ?? 2.0

            stopPickerOverlay()

            // Create new `.nativescreen` package bundle
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let timestampName = "Recording \(formatter.string(from: Date()))"
            let packageURL = ProjectWorkspaceStore.defaultProjectsDirectory
                .appendingPathComponent("\(timestampName).nativescreen", isDirectory: true)
            let recordingDir = packageURL.appendingPathComponent("recording", isDirectory: true)
            let telemetryDir = recordingDir.appendingPathComponent("telemetry", isDirectory: true)
            let assetsDir = packageURL.appendingPathComponent("assets", isDirectory: true)

            try FileManager.default.createDirectory(at: telemetryDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

            let pixelWidth = Int(logicalBounds.width * screenScale)
            let pixelHeight = Int(logicalBounds.height * screenScale)

            let targetMeta = CaptureTargetMetadata(
                mode: selectedMode,
                displayId: targetDisplay.displayID,
                windowId: targetWindowId,
                appBundleId: targetBundleId,
                appName: targetAppName,
                windowTitle: targetWindowTitle,
                logicalBounds: LogicalBounds(
                    x: logicalBounds.origin.x,
                    y: logicalBounds.origin.y,
                    width: logicalBounds.width,
                    height: logicalBounds.height
                ),
                pixelSize: PixelDimensions(width: pixelWidth, height: pixelHeight),
                scaleFactor: Double(screenScale),
                refreshRate: 60.0,
                windowBorderRadius: selectedMode == .window ? 16.0 : 12.0
            )

            let outputVideoURL = recordingDir.appendingPathComponent("display.mp4")
            let engine = ScreenCaptureEngine()
            let telemetry = TelemetryRecorder(
                telemetryDirectoryURL: telemetryDir,
                captureLogicalBounds: logicalBounds
            )

            try await engine.startCapture(
                filter: filter,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                sourceRect: sourceRect,
                captureSystemAudio: captureSystemAudio,
                outputVideoURL: outputVideoURL
            )
            telemetry.start()

            self.captureEngine = engine
            self.telemetryRecorder = telemetry
            self.activePackageURL = packageURL
            self.activeTargetMetadata = targetMeta
            self.isRecording = true
            self.recordingStartUptime = ProcessInfo.processInfo.systemUptime
            self.recordingElapsedSeconds = 0.0

            recordingTimer?.invalidate()
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, self.isRecording else { return }
                    self.recordingElapsedSeconds = ProcessInfo.processInfo.systemUptime - self.recordingStartUptime
                }
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    public func stopRecordingAndOpenEditor() async {
        guard isRecording else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil
        isRecording = false

        telemetryRecorder?.stop()
        telemetryRecorder = nil

        if let engine = captureEngine {
            await engine.stopCapture()
        }
        let durationMs = max(1000.0, captureEngine?.recordedDurationMs ?? (recordingElapsedSeconds * 1000.0))
        captureEngine = nil

        guard let packageURL = activePackageURL,
              let targetMeta = activeTargetMetadata else {
            return
        }

        let recordingDir = packageURL.appendingPathComponent("recording", isDirectory: true)
        let metadata = RecordingMetadata(
            durationMs: durationMs,
            captureTarget: targetMeta,
            tracks: RecordingTracksMetadata(displayVideo: "display.mp4")
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let metaData = try? encoder.encode(metadata) {
            try? metaData.write(to: recordingDir.appendingPathComponent("metadata.json"), options: .atomic)
        }

        let clicksURL = recordingDir.appendingPathComponent(metadata.tracks.clicksTelemetry)
        let keysURL = recordingDir.appendingPathComponent(metadata.tracks.keysTelemetry)
        let clicks = JSONLinesCodec.load(ClickEvent.self, from: clicksURL)
        let keys = JSONLinesCodec.load(KeyStrokeEvent.self, from: keysURL)

        let autoZooms = AutoZoomClusterGenerator.generateZooms(
            clicks: clicks,
            keys: keys,
            durationMs: durationMs,
            defaultScale: 1.8
        )

        let projectName = targetMeta.appName ?? packageURL.deletingPathExtension().lastPathComponent
        let initialSlice = ClipSlice(sourceStartMs: 0.0, sourceEndMs: durationMs, speed: 1.0)
        let doc = ProjectDocument(
            name: projectName,
            timeline: TimelineConfig(
                slices: [initialSlice],
                zooms: autoZooms,
                maskTracks: [
                    MaskTrack(id: "mask-track-1", name: "Mask Track 1")
                ]
            )
        )

        if let docData = try? encoder.encode(doc) {
            try? docData.write(to: packageURL.appendingPathComponent("project.json"), options: .atomic)
        }

        hideRecordingHUD()

        if let session = ProjectWorkspaceStore.shared.openOrFocusProject(at: packageURL) {
            onRecordingCompleted?(session)
        }
    }

    // MARK: - Create Instant Interactive Demo Project

    public func createInteractiveSampleProject() -> ProjectSession? {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH-mm-ss"
        let name = "Demo Showcase \(formatter.string(from: Date()))"
        let packageURL = ProjectWorkspaceStore.defaultProjectsDirectory
            .appendingPathComponent("\(name).nativescreen", isDirectory: true)
        let recordingDir = packageURL.appendingPathComponent("recording", isDirectory: true)
        let telemetryDir = recordingDir.appendingPathComponent("telemetry", isDirectory: true)
        let assetsDir = packageURL.appendingPathComponent("assets", isDirectory: true)

        try? FileManager.default.createDirectory(at: telemetryDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        let durationMs = 18000.0
        let cursorAppender = JSONLinesAppender(fileURL: telemetryDir.appendingPathComponent("cursor.jsonl"))
        let clicksAppender = JSONLinesAppender(fileURL: telemetryDir.appendingPathComponent("clicks.jsonl"))

        let totalSamples = Int(durationMs / 16.67)
        for i in 0...totalSamples {
            let t = Double(i) * 16.67
            let phase = (t / durationMs) * (.pi * 4.0)
            let x = 0.5 + 0.30 * sin(phase)
            let y = 0.5 + 0.24 * sin(phase * 2.0)
            cursorAppender.append(CursorSampleEvent(t: t, x: x, y: y, c: "arrow"))
        }
        cursorAppender.close()

        let sampleClickTimes: [(Double, Double, Double)] = [
            (2200.0, 0.72, 0.34),
            (8400.0, 0.28, 0.66),
            (13800.0, 0.64, 0.42)
        ]
        for (t, cx, cy) in sampleClickTimes {
            clicksAppender.append(ClickEvent(t: t, type: "down", button: "left", x: cx, y: cy, count: 1))
            clicksAppender.append(ClickEvent(t: t + 90.0, type: "up", button: "left", x: cx, y: cy, count: 1))
        }
        clicksAppender.close()

        let metadata = RecordingMetadata(
            durationMs: durationMs,
            captureTarget: CaptureTargetMetadata(
                mode: .window,
                displayId: 1,
                appBundleId: "com.apple.Safari",
                appName: "Interactive Demo",
                windowTitle: "NativeScreen 120Hz Engine Preview",
                logicalBounds: LogicalBounds(x: 100, y: 80, width: 1280, height: 800),
                pixelSize: PixelDimensions(width: 2560, height: 1600),
                scaleFactor: 2.0,
                refreshRate: 60.0,
                windowBorderRadius: 16.0
            )
        )

        let clicks = JSONLinesCodec.load(ClickEvent.self, from: telemetryDir.appendingPathComponent("clicks.jsonl"))
        let autoZooms = AutoZoomClusterGenerator.generateZooms(clicks: clicks, keys: [], durationMs: durationMs)

        let mask1 = MaskItem(
            sourceStartMs: 1500.0,
            sourceEndMs: 11000.0,
            type: .blur,
            style: .gaussian,
            intensity: 36.0,
            cornerRadius: 10.0,
            keyframes: [
                MaskKeyframe(sourceMs: 1500.0, rect01: Rect01(x: 0.08, y: 0.16, width: 0.36, height: 0.14))
            ]
        )
        let mask2 = MaskItem(
            sourceStartMs: 4000.0,
            sourceEndMs: 15000.0,
            type: .blur,
            style: .pixelate,
            intensity: 28.0,
            cornerRadius: 10.0,
            keyframes: [
                MaskKeyframe(sourceMs: 4000.0, rect01: Rect01(x: 0.54, y: 0.62, width: 0.34, height: 0.16))
            ]
        )

        let doc = ProjectDocument(
            name: name,
            timeline: TimelineConfig(
                slices: [ClipSlice(sourceStartMs: 0.0, sourceEndMs: durationMs, speed: 1.0)],
                zooms: autoZooms,
                maskTracks: [
                    MaskTrack(id: "mask-track-1", name: "Mask Track 1", items: [mask1]),
                    MaskTrack(id: "mask-track-2", name: "Mask Track 2", items: [mask2])
                ]
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let metaData = try? encoder.encode(metadata) {
            try? metaData.write(to: recordingDir.appendingPathComponent("metadata.json"), options: .atomic)
        }
        if let docData = try? encoder.encode(doc) {
            try? docData.write(to: packageURL.appendingPathComponent("project.json"), options: .atomic)
        }

        return ProjectWorkspaceStore.shared.openOrFocusProject(at: packageURL)
    }
}

// MARK: - Floating Recording HUD Bar View (`NSPanel` Content — Matches the Recording Bar)

public struct RecordingHUDBarView: View {
    @Bindable var coordinator: RecordingCoordinator
    @Bindable private var workspace = ProjectWorkspaceStore.shared

    public var body: some View {
        HStack(spacing: 12) {
            // Close button (ESC)
            Button {
                if coordinator.isRecording {
                    Task { await coordinator.stopRecordingAndOpenEditor() }
                } else {
                    coordinator.hideRecordingHUD()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)

            Divider()
                .frame(height: 26)

            if !coordinator.isRecording {
                // Capture Target Mode Buttons (Display, Window, Area, Device)
                HStack(spacing: 4) {
                    ForEach(CaptureTargetMode.allCases) { mode in
                        let isSelected = (coordinator.isPickingTarget && coordinator.selectedMode == mode)
                        Button {
                            coordinator.selectMode(mode)
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: mode.systemImage)
                                    .font(.system(size: 16, weight: .medium))
                                Text(mode.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(isSelected ? .white : .white.opacity(0.65))
                            .frame(width: 58, height: 46)
                            .background(
                                isSelected
                                    ? Color.white.opacity(0.16)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()
                    .frame(height: 26)

                // Single-Line Microphone & System Audio Pills
                HStack(spacing: 8) {
                    Button {
                        coordinator.captureMicrophone.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: coordinator.captureMicrophone ? "mic.fill" : "mic.slash")
                                .font(.system(size: 13))
                            Text(coordinator.captureMicrophone ? "Microphone" : "No microphone")
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(coordinator.captureMicrophone ? .white : .white.opacity(0.60))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.white.opacity(coordinator.captureMicrophone ? 0.14 : 0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        coordinator.captureSystemAudio.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: coordinator.captureSystemAudio ? "speaker.wave.2.fill" : "speaker.slash")
                                .font(.system(size: 13))
                            Text(coordinator.captureSystemAudio ? "System Audio" : "No audio")
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(coordinator.captureSystemAudio ? .white : .white.opacity(0.60))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.white.opacity(coordinator.captureSystemAudio ? 0.14 : 0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Divider()
                    .frame(height: 26)

                // Projects Folder Menu (Like the 📁 icon right on the Recording Bar!)
                Menu {
                    Button("Open .nativescreen Project…") {
                        workspace.promptOpenProjectDialog()
                    }

                    Button("Create Interactive Showcase Project") {
                        _ = coordinator.createInteractiveSampleProject()
                    }

                    if !workspace.recentProjectURLs.isEmpty {
                        Divider()
                        Section("Recent Projects") {
                            ForEach(workspace.recentProjectURLs.prefix(10), id: \.path) { url in
                                Button(url.deletingPathExtension().lastPathComponent) {
                                    _ = workspace.openOrFocusProject(at: url)
                                }
                            }
                        }
                    }

                    Divider()
                    Button("Show Projects Folder in Finder") {
                        NSWorkspace.shared.open(ProjectWorkspaceStore.defaultProjectsDirectory)
                    }
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(width: 34, height: 34)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Record Button
                Button {
                    Task { await coordinator.startRecording() }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.red)
                            .frame(width: 9, height: 9)
                        Text("Record")
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 8)
                    .background(Color.indigo, in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            } else {
                // Active Recording Status & Stop Button
                HStack(spacing: 12) {
                    Circle()
                        .fill(.red)
                        .frame(width: 9, height: 9)
                    Text(formatElapsed(coordinator.recordingElapsedSeconds))
                        .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                    Button {
                        Task { await coordinator.stopRecordingAndOpenEditor() }
                    } label: {
                        Label("Stop Recording", systemImage: "stop.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(.red, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(Color(red: 0.11, green: 0.12, blue: 0.16).opacity(0.94), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
    }

    private func formatElapsed(_ sec: TimeInterval) -> String {
        let total = Int(sec)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Multi-Monitor Smart Window Picker, Display Picker & Area Selection Overlay View

public struct WindowAndAreaPickerOverlayView: View {
    @Bindable var coordinator: RecordingCoordinator
    let screen: NSScreen

    private var screenDisplayID: CGDirectDisplayID {
        WindowDiscoveryService.displayID(for: screen)
    }

    private var screenQuartzFrame: CGRect {
        WindowDiscoveryService.quartzFrame(for: screen)
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.22)
                .ignoresSafeArea()

            // 1. WINDOW MODE (Works across all connected monitors!)
            if coordinator.selectedMode == .window,
               let win = coordinator.hoveredWindow,
               screenQuartzFrame.intersects(win.bounds) {
                let localRect = WindowDiscoveryService.localTopLeftRect(fromQuartzRect: win.bounds, on: screen)

                ZStack {
                    RoundedRectangle(cornerRadius: win.borderRadius, style: .continuous)
                        .fill(Color.indigo.opacity(0.24))
                        .overlay(
                            RoundedRectangle(cornerRadius: win.borderRadius, style: .continuous)
                                .strokeBorder(Color.indigo.opacity(0.95), lineWidth: 2.5)
                        )

                    // Center Card (App Icon + App Name + Exact Size + Resize Menu + Start Recording)
                    VStack(spacing: 10) {
                        if let icon = win.appIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 64, height: 64)
                                .shadow(radius: 8)
                        }

                        Text(win.appName)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            Text("\(Int(win.bounds.width)) × \(Int(win.bounds.height))")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.85))

                            Menu {
                                ForEach(WindowSizePreset.presets) { preset in
                                    Button(preset.label) {
                                        WindowDiscoveryService.resizeWindow(
                                            win,
                                            toWidth: Double(preset.width),
                                            height: Double(preset.height)
                                        )
                                    }
                                }
                            } label: {
                                Text("Resize")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.18), in: Capsule())
                        }

                        Button {
                            Task { await coordinator.startRecording() }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "record.circle")
                                Text("Start recording")
                                    .fontWeight(.semibold)
                            }
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Color.indigo, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                    .padding(22)
                    .background(Color(red: 0.12, green: 0.13, blue: 0.20).opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                    )
                }
                .frame(width: localRect.width, height: localRect.height)
                .position(x: localRect.midX, y: localRect.midY)
            }

            // 2. DISPLAY MODE (Allows selecting any connected monitor!)
            else if coordinator.selectedMode == .display, coordinator.hoveredDisplayID == screenDisplayID {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.indigo, lineWidth: 4)
                        .background(Color.indigo.opacity(0.10))

                    VStack(spacing: 12) {
                        Image(systemName: "display")
                            .font(.system(size: 42))
                            .foregroundStyle(.white)
                        Text(screen.localizedName)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                        Text("\(Int(screen.frame.width)) × \(Int(screen.frame.height)) • Press ESC to cancel")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.75))

                        Button {
                            Task { await coordinator.startRecording() }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "record.circle")
                                Text("Record This Display")
                                    .fontWeight(.semibold)
                            }
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Color.indigo, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(24)
                    .background(Color(red: 0.12, green: 0.13, blue: 0.20).opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // 3. AREA MODE
            else if coordinator.selectedMode == .area,
                    screenQuartzFrame.intersects(coordinator.selectedAreaRectQuartz) {
                let localRect = WindowDiscoveryService.localTopLeftRect(
                    fromQuartzRect: coordinator.selectedAreaRectQuartz,
                    on: screen
                )
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                        .foregroundStyle(.white)
                        .background(Color.indigo.opacity(0.12))

                    VStack(spacing: 10) {
                        Text("\(Int(localRect.width)) × \(Int(localRect.height))")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)

                        HStack(spacing: 8) {
                            ForEach(WindowSizePreset.presets.prefix(4)) { preset in
                                Button(preset.id) {
                                    coordinator.selectedAreaRectQuartz.size = CGSize(
                                        width: preset.width,
                                        height: preset.height
                                    )
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }

                        Button {
                            Task { await coordinator.startRecording() }
                        } label: {
                            Label("Start Area Recording", systemImage: "record.circle")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.indigo, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(16)
                    .background(Color(red: 0.12, green: 0.13, blue: 0.20).opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .frame(width: localRect.width, height: localRect.height)
                .position(x: localRect.midX, y: localRect.midY)
                .gesture(
                    DragGesture(coordinateSpace: .named("screenOverlaySpace"))
                        .onChanged { value in
                            let newLocalOriginX = max(0, value.location.x - localRect.width * 0.5)
                            let newLocalOriginY = max(0, value.location.y - localRect.height * 0.5)
                            coordinator.selectedAreaRectQuartz.origin = CGPoint(
                                x: screenQuartzFrame.origin.x + newLocalOriginX,
                                y: screenQuartzFrame.origin.y + newLocalOriginY
                            )
                        }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: "screenOverlaySpace")
    }
}
