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

/// Countdown duration options before recording starts (`Off`, `3s`, `5s`, `10s`).
public enum RecordingCountdownOption: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case threeSeconds = 3
    case fiveSeconds = 5
    case tenSeconds = 10

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .off: return "Off"
        case .threeSeconds: return "3s"
        case .fiveSeconds: return "5s"
        case .tenSeconds: return "10s"
        }
    }
}

/// Coordinates the floating Recording HUD (`NSPanel`), multi-monitor interactive Window/Display/Area Picker overlays,
/// pre-recording Countdown, While-Recording options, `ESC` key cancellation, and `ScreenCaptureEngine` + `TelemetryRecorder`.
@Observable
@MainActor
public final class RecordingCoordinator {
    public static let shared = RecordingCoordinator()

    public var isHUDVisible: Bool = false
    public var isRecording: Bool = false
    public var isRecordingPaused: Bool = false
    public var isCountingDown: Bool = false
    public var countdownRemainingSeconds: Double = 3.0
    public var countdownTotalSeconds: Double = 3.0

    public var isPickingTarget: Bool = false
    public var recordingElapsedSeconds: TimeInterval = 0.0
    public var selectedMode: CaptureTargetMode = .window
    public var captureMicrophone: Bool = false
    public var captureSystemAudio: Bool = true

    // Recording Options (Persisted in UserDefaults)
    public var countdownOption: RecordingCountdownOption = .threeSeconds {
        didSet { UserDefaults.standard.set(countdownOption.rawValue, forKey: countdownOptionKey) }
    }
    public var hideDesktopIcons: Bool = false {
        didSet { UserDefaults.standard.set(hideDesktopIcons, forKey: hideDesktopIconsKey) }
    }
    public var hideDockIcon: Bool = true {
        didSet { UserDefaults.standard.set(hideDockIcon, forKey: hideDockIconKey) }
    }
    public var highlightRecordedArea: Bool = true {
        didSet {
            UserDefaults.standard.set(highlightRecordedArea, forKey: highlightRecordedAreaKey)
            updateRecordedAreaHighlightOverlay()
        }
    }

    // Multi-Monitor Window, Display & Area Picker State
    public var hoveredWindow: CapturableWindowInfo?
    public var hoveredDisplayID: CGDirectDisplayID = CGMainDisplayID()
    public var selectedAreaRectQuartz: CGRect = CGRect(x: 240, y: 160, width: 1280, height: 720)
    public var lastErrorMessage: String?

    public var onRecordingCompleted: ((ProjectSession) -> Void)?

    private var hudPanel: DraggableHUDPanel?
    private var pickerOverlayWindows: [NSWindow] = []
    private var recordedAreaHighlightWindow: NSWindow?
    private var hoverTimer: Timer?
    private var countdownTimer: Timer?
    private var recordingTimer: Timer?
    private var recordingStartUptime: TimeInterval = 0
    private var pauseStartUptime: TimeInterval?
    private var accumulatedPausedSeconds: TimeInterval = 0
    private var escLocalMonitor: Any?
    private var escGlobalMonitor: Any?

    private var captureEngine: ScreenCaptureEngine?
    private var telemetryRecorder: TelemetryRecorder?
    private var activePackageURL: URL?
    private var activeTargetMetadata: CaptureTargetMetadata?
    private var activeLogicalBoundsQuartz: CGRect?

    private let savedHUDOriginXKey = "NativeScreen.HUDPanel.OriginX"
    private let savedHUDOriginYKey = "NativeScreen.HUDPanel.OriginY"
    private let hasSavedHUDOriginKey = "NativeScreen.HUDPanel.HasSavedOrigin"

    private let countdownOptionKey = "NativeScreen.RecordingOptions.Countdown"
    private let hideDesktopIconsKey = "NativeScreen.RecordingOptions.HideDesktopIcons"
    private let hideDockIconKey = "NativeScreen.RecordingOptions.HideDockIcon"
    private let highlightRecordedAreaKey = "NativeScreen.RecordingOptions.HighlightRecordedArea"

    fileprivate static let idleBarWidth: CGFloat = 786.0
    fileprivate static let countdownBarWidth: CGFloat = 496.0
    fileprivate static let recordingBarWidth: CGFloat = 278.0
    fileprivate static let barHeight: CGFloat = 64.0

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: countdownOptionKey) != nil,
           let opt = RecordingCountdownOption(rawValue: defaults.integer(forKey: countdownOptionKey)) {
            self.countdownOption = opt
        }
        if defaults.object(forKey: hideDesktopIconsKey) != nil {
            self.hideDesktopIcons = defaults.bool(forKey: hideDesktopIconsKey)
        }
        if defaults.object(forKey: hideDockIconKey) != nil {
            self.hideDockIcon = defaults.bool(forKey: hideDockIconKey)
        }
        if defaults.object(forKey: highlightRecordedAreaKey) != nil {
            self.highlightRecordedArea = defaults.bool(forKey: highlightRecordedAreaKey)
        }
    }

    // MARK: - Show / Hide Floating Recording HUD Bar (`NSPanel`)

    private var currentDesiredPanelSize: NSSize {
        let width: CGFloat
        if isRecording {
            width = Self.recordingBarWidth
        } else if isCountingDown {
            width = Self.countdownBarWidth
        } else {
            width = Self.idleBarWidth
        }
        return NSSize(width: width, height: Self.barHeight)
    }

    public func showRecordingHUD() {
        let desiredSize = currentDesiredPanelSize

        if hudPanel == nil {
            let panel = DraggableHUDPanel(
                contentRect: NSRect(origin: .zero, size: desiredSize),
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
            let restoredOrigin = restoredAndClampedHUDOrigin(panelSize: desiredSize)
            panel.setFrame(NSRect(origin: restoredOrigin, size: desiredSize), display: true)
            panel.orderFrontRegardless()
        }

        isPickingTarget = false
        stopPickerOverlay()
        isHUDVisible = true
        installEscapeKeyMonitors()
    }

    /// Resizes the HUD panel smoothly around its current horizontal center (`midX`) when switching between Idle, Countdown, and Recording bars.
    private func updateHUDPanelFrameForCurrentState(animated: Bool = true) {
        guard let panel = hudPanel else { return }
        let newSize = currentDesiredPanelSize
        let currentFrame = panel.frame
        let newOriginX = round(currentFrame.midX - newSize.width * 0.5)
        var targetOrigin = NSPoint(x: newOriginX, y: currentFrame.origin.y)

        // Clamp inside the current monitor's visibleFrame
        if let screen = panel.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            let margin: CGFloat = 10.0
            let minX = vf.minX + margin
            let maxX = max(minX, vf.maxX - newSize.width - margin)
            targetOrigin.x = min(max(targetOrigin.x, minX), maxX)
        }

        let targetFrame = NSRect(origin: targetOrigin, size: newSize)
        panel.setFrame(targetFrame, display: true, animate: animated)
    }

    private func saveHUDPanelOrigin(_ origin: NSPoint) {
        guard !isRecording && !isCountingDown else { return }
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
        SharedFloatingTooltipWindowController.shared.hideTooltip()
        cancelCountdown()
        isPickingTarget = false
        stopPickerOverlay()
        hideRecordedAreaHighlightOverlay()
        removeEscapeKeyMonitors()
        hudPanel?.orderOut(nil)
        isHUDVisible = false
    }

    public func selectMode(_ mode: CaptureTargetMode) {
        if selectedMode == mode && isPickingTarget {
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

    // MARK: - `ESC` Hotkey Monitor (Cancels Countdown / Picker Overlay first, or Closes Recording HUD)

    private func installEscapeKeyMonitors() {
        removeEscapeKeyMonitors()
        escLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC key
                Task { @MainActor [weak self] in
                    guard let self = self, !self.isRecording else { return }
                    if self.isCountingDown {
                        self.cancelCountdown()
                    } else if self.isPickingTarget {
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
                    if self.isCountingDown {
                        self.cancelCountdown()
                    } else if self.isPickingTarget {
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
        guard isHUDVisible, isPickingTarget, !isRecording, !isCountingDown else {
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

        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isRecording, !self.isCountingDown else { return }
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

    // MARK: - Countdown & Start / Pause / Restart / Discard / Stop Recording

    /// Initiates recording: if `countdownOption != .off`, enters the Countdown bar first (`Get ready. Recording will start soon.` + `Continue (3)`).
    public func requestStartRecording() {
        guard !isRecording && !isCountingDown else { return }
        isPickingTarget = false
        stopPickerOverlay()

        let totalSec = Double(countdownOption.rawValue)
        if totalSec > 0 {
            isCountingDown = true
            countdownTotalSeconds = totalSec
            countdownRemainingSeconds = totalSec
            updateHUDPanelFrameForCurrentState(animated: true)

            let startUptime = ProcessInfo.processInfo.systemUptime
            countdownTimer?.invalidate()
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, self.isCountingDown else { return }
                    let elapsed = ProcessInfo.processInfo.systemUptime - startUptime
                    let remaining = max(0.0, totalSec - elapsed)
                    self.countdownRemainingSeconds = remaining
                    if remaining <= 0.01 {
                        self.skipCountdownAndStartImmediately()
                    }
                }
            }
        } else {
            Task { await startRecordingImmediately() }
        }
    }

    /// Cancels an active pre-recording countdown and returns the HUD to the idle bar.
    public func cancelCountdown() {
        guard isCountingDown else { return }
        countdownTimer?.invalidate()
        countdownTimer = nil
        isCountingDown = false
        updateHUDPanelFrameForCurrentState(animated: true)
    }

    /// Triggered when the user clicks `"Continue (1)"` during countdown or when the countdown reaches `0`.
    public func skipCountdownAndStartImmediately() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        isCountingDown = false
        Task { await startRecordingImmediately() }
    }

    public func startRecording() async {
        requestStartRecording()
    }

    public func startRecordingImmediately() async {
        guard !isRecording else { return }
        lastErrorMessage = nil
        isPickingTarget = false
        stopPickerOverlay()

        do {
            let shareable = try await SCShareableContent.excludingDesktopWindows(
                hideDesktopIcons,
                onScreenWindowsOnly: true
            )
            guard !shareable.displays.isEmpty else {
                lastErrorMessage = "No capturable display found."
                updateHUDPanelFrameForCurrentState(animated: true)
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

            // Apply "While Recording" options: Hide Dock Icon & Highlight Recorded Area
            if hideDockIcon {
                NSApp.setActivationPolicy(.accessory)
                hudPanel?.orderFrontRegardless()
            }

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
            self.activeLogicalBoundsQuartz = logicalBounds
            self.isRecording = true
            self.isRecordingPaused = false
            self.recordingStartUptime = ProcessInfo.processInfo.systemUptime
            self.pauseStartUptime = nil
            self.accumulatedPausedSeconds = 0
            self.recordingElapsedSeconds = 0.0

            updateHUDPanelFrameForCurrentState(animated: true)
            updateRecordedAreaHighlightOverlay()

            recordingTimer?.invalidate()
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, self.isRecording, !self.isRecordingPaused else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    self.recordingElapsedSeconds = max(0.0, now - self.recordingStartUptime - self.accumulatedPausedSeconds)
                }
            }
        } catch {
            restorePostRecordingSystemState()
            lastErrorMessage = error.localizedDescription
            updateHUDPanelFrameForCurrentState(animated: true)
        }
    }

    // MARK: - Pause / Resume, Restart, and Discard Recording ( & 5!)

    public func togglePauseRecording() {
        guard isRecording else { return }
        let newPaused = !isRecordingPaused
        isRecordingPaused = newPaused
        let now = ProcessInfo.processInfo.systemUptime
        if newPaused {
            pauseStartUptime = now
        } else if let pStart = pauseStartUptime {
            accumulatedPausedSeconds += max(0.0, now - pStart)
            pauseStartUptime = nil
        }
        captureEngine?.setPaused(newPaused)
        telemetryRecorder?.setPaused(newPaused)
    }

    public func restartCurrentRecording() async {
        guard isRecording else { return }
        await stopAndDeleteCurrentRecordingFiles()
        requestStartRecording()
    }

    /// Shows the native macOS confirmation alert (`Discard this recording?`) when clicking the Trash button!
    public func promptDiscardCurrentRecording() {
        guard isRecording else { return }
        let wasAlreadyPaused = isRecordingPaused
        if !wasAlreadyPaused {
            togglePauseRecording()
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard this recording?"
        alert.informativeText = "Everything recorded so far will be deleted."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Continue Recording")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Task {
                await stopAndDeleteCurrentRecordingFiles()
                updateHUDPanelFrameForCurrentState(animated: true)
                hudPanel?.orderFrontRegardless()
            }
        } else {
            if !wasAlreadyPaused && isRecordingPaused {
                togglePauseRecording()
            }
            hudPanel?.orderFrontRegardless()
        }
    }

    private func stopAndDeleteCurrentRecordingFiles() async {
        recordingTimer?.invalidate()
        recordingTimer = nil
        isRecording = false
        isRecordingPaused = false

        telemetryRecorder?.stop()
        telemetryRecorder = nil

        if let engine = captureEngine {
            await engine.stopCapture()
        }
        captureEngine = nil

        if let pkgURL = activePackageURL {
            try? FileManager.default.removeItem(at: pkgURL)
        }
        activePackageURL = nil
        activeTargetMetadata = nil
        activeLogicalBoundsQuartz = nil
        restorePostRecordingSystemState()
    }

    private func restorePostRecordingSystemState() {
        hideRecordedAreaHighlightOverlay()
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func updateRecordedAreaHighlightOverlay() {
        guard isRecording, highlightRecordedArea, let boundsQuartz = activeLogicalBoundsQuartz else {
            hideRecordedAreaHighlightOverlay()
            return
        }
        guard let screen = NSScreen.screens.first(where: {
            WindowDiscoveryService.quartzFrame(for: $0).intersects(boundsQuartz)
        }) ?? NSScreen.main else {
            return
        }

        let localTopLeft = WindowDiscoveryService.localTopLeftRect(fromQuartzRect: boundsQuartz, on: screen)
        let cocoaX = screen.frame.origin.x + localTopLeft.origin.x - 3
        let cocoaY = screen.frame.maxY - localTopLeft.maxY - 3
        let frameRect = NSRect(x: cocoaX, y: cocoaY, width: localTopLeft.width + 6, height: localTopLeft.height + 6)

        if recordedAreaHighlightWindow == nil {
            let win = NSPanel(
                contentRect: frameRect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            win.isReleasedWhenClosed = false
            win.isFloatingPanel = true
            win.level = .statusBar
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.ignoresMouseEvents = true
            win.sharingType = .none // Never captured by ScreenCaptureKit!
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.contentView = NSHostingView(
                rootView: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.indigo.opacity(0.65), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            )
            recordedAreaHighlightWindow = win
        }
        recordedAreaHighlightWindow?.setFrame(frameRect, display: true)
        recordedAreaHighlightWindow?.orderFrontRegardless()
    }

    private func hideRecordedAreaHighlightOverlay() {
        recordedAreaHighlightWindow?.orderOut(nil)
        recordedAreaHighlightWindow = nil
    }

    public func stopRecordingAndOpenEditor() async {
        guard isRecording else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil
        isRecording = false
        isRecordingPaused = false

        telemetryRecorder?.stop()
        telemetryRecorder = nil

        if let engine = captureEngine {
            await engine.stopCapture()
        }
        let durationMs = max(1000.0, captureEngine?.recordedDurationMs ?? (recordingElapsedSeconds * 1000.0))
        captureEngine = nil
        activeLogicalBoundsQuartz = nil
        restorePostRecordingSystemState()

        guard let packageURL = activePackageURL,
              let targetMeta = activeTargetMetadata else {
            updateHUDPanelFrameForCurrentState(animated: true)
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

// MARK: - Native `NSMenu` Presenter for HUD Projects & Recording Options

@MainActor
public final class HUDNativeMenuPresenter: NSObject {
    public static let shared = HUDNativeMenuPresenter()

    private var activeMenu: NSMenu?
    private var retainedTargets: [AnyObject] = []

    private override init() {
        super.init()
    }

    public func presentRecordingOptionsMenu(coordinator: RecordingCoordinator, anchorButtonScreenRect: NSRect, from panel: NSWindow?) {
        SharedFloatingTooltipWindowController.shared.hideTooltip()

        let menu = NSMenu(title: "Recording Options")
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        let menuWidth: CGFloat = 324.0

        // 1. Section Header: "Before Recording"
        let beforeHeaderItem = NSMenuItem()
        let beforeHeaderView = NSHostingView(rootView: HUDMenuSectionHeaderView(title: "Before Recording"))
        beforeHeaderView.sizingOptions = []
        beforeHeaderView.autoresizingMask = [.width]
        beforeHeaderView.frame = NSRect(x: 0, y: 0, width: menuWidth, height: 26)
        beforeHeaderItem.view = beforeHeaderView
        menu.addItem(beforeHeaderItem)

        // 2. Countdown Row (`Off | 3s | 5s | 10s` — Single-line `.fixedSize(horizontal: true)` for i18n safety!)
        let countdownItem = NSMenuItem()
        let countdownView = NSHostingView(rootView: HUDCountdownSegmentedRowView(coordinator: coordinator))
        let countdownIntrinsicW = ceil(countdownView.fittingSize.width)
        let effectiveWidth = max(menuWidth, countdownIntrinsicW)
        beforeHeaderView.frame.size.width = effectiveWidth
        countdownView.sizingOptions = []
        countdownView.autoresizingMask = [.width]
        countdownView.frame = NSRect(x: 0, y: 0, width: effectiveWidth, height: 38)
        countdownItem.view = countdownView
        menu.addItem(countdownItem)

        menu.addItem(.separator())

        // 3. Section Header: "While Recording"
        let whileHeaderItem = NSMenuItem()
        let whileHeaderView = NSHostingView(rootView: HUDMenuSectionHeaderView(title: "While Recording"))
        whileHeaderView.sizingOptions = []
        whileHeaderView.autoresizingMask = [.width]
        whileHeaderView.frame = NSRect(x: 0, y: 0, width: effectiveWidth, height: 26)
        whileHeaderItem.view = whileHeaderView
        menu.addItem(whileHeaderItem)

        // 4. Switch Rows: "Hide Desktop Icons", "Hide Dock Icon", "Highlight Recorded Area"
        let desktopIconsItem = NSMenuItem()
        let desktopIconsView = NSHostingView(
            rootView: HUDSwitchMenuRowView(
                title: "Hide Desktop Icons",
                isOn: Binding(
                    get: { coordinator.hideDesktopIcons },
                    set: { coordinator.hideDesktopIcons = $0 }
                )
            )
        )
        desktopIconsView.sizingOptions = []
        desktopIconsView.autoresizingMask = [.width]
        desktopIconsView.frame = NSRect(x: 0, y: 0, width: effectiveWidth, height: 34)
        desktopIconsItem.view = desktopIconsView
        menu.addItem(desktopIconsItem)

        let dockIconItem = NSMenuItem()
        let dockIconView = NSHostingView(
            rootView: HUDSwitchMenuRowView(
                title: "Hide Dock Icon",
                isOn: Binding(
                    get: { coordinator.hideDockIcon },
                    set: { coordinator.hideDockIcon = $0 }
                )
            )
        )
        dockIconView.sizingOptions = []
        dockIconView.autoresizingMask = [.width]
        dockIconView.frame = NSRect(x: 0, y: 0, width: effectiveWidth, height: 34)
        dockIconItem.view = dockIconView
        menu.addItem(dockIconItem)

        let highlightAreaItem = NSMenuItem()
        let highlightAreaView = NSHostingView(
            rootView: HUDSwitchMenuRowView(
                title: "Highlight Recorded Area",
                isOn: Binding(
                    get: { coordinator.highlightRecordedArea },
                    set: { coordinator.highlightRecordedArea = $0 }
                )
            )
        )
        highlightAreaView.sizingOptions = []
        highlightAreaView.autoresizingMask = [.width]
        highlightAreaView.frame = NSRect(x: 0, y: 0, width: effectiveWidth, height: 36)
        highlightAreaItem.view = highlightAreaView
        menu.addItem(highlightAreaItem)
        menu.minimumWidth = effectiveWidth

        activeMenu = menu
        popUpMenuOutsideButton(menu: menu, anchorButtonScreenRect: anchorButtonScreenRect, in: panel)
    }

    public func presentProjectsMenu(
        coordinator: RecordingCoordinator,
        workspace: ProjectWorkspaceStore,
        anchorButtonScreenRect: NSRect,
        from panel: NSWindow?
    ) {
        SharedFloatingTooltipWindowController.shared.hideTooltip()

        let menu = NSMenu(title: "Projects")
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        menu.addItem(makeCommandItem(title: "Open .nativescreen Project…", symbol: "folder") {
            workspace.promptOpenProjectDialog()
        })

        menu.addItem(makeCommandItem(title: "Create Interactive Showcase Project", symbol: "sparkles.tv") {
            _ = coordinator.createInteractiveSampleProject()
        })

        if !workspace.recentProjectURLs.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem.sectionHeader(title: "Recent Projects")
            menu.addItem(header)

            for url in workspace.recentProjectURLs.prefix(8) {
                menu.addItem(makeCommandItem(title: url.deletingPathExtension().lastPathComponent, symbol: "film") {
                    _ = workspace.openOrFocusProject(at: url)
                })
            }
        }

        menu.addItem(.separator())
        menu.addItem(makeCommandItem(title: "Show Projects Folder in Finder", symbol: "arrow.up.forward.app") {
            NSWorkspace.shared.open(ProjectWorkspaceStore.defaultProjectsDirectory)
        })

        activeMenu = menu
        popUpMenuOutsideButton(menu: menu, anchorButtonScreenRect: anchorButtonScreenRect, in: panel)
    }

    /// Pops up the HUD context menu cleanly **outside** the clicked button highlight (below the button if there is room below on screen,
    /// or cleanly above the HUD bar if near the bottom of the screen — NEVER overlapping the button!).
    private func popUpMenuOutsideButton(menu: NSMenu, anchorButtonScreenRect: NSRect, in panel: NSWindow?) {
        let menuSize = menu.size
        let menuW = max(260.0, menuSize.width)
        let menuH = max(160.0, menuSize.height)

        if let win = panel, let contentView = win.contentView {
            let screenFrame = (win.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

            // 1. Horizontal: align left edge with the button's left edge, or flip to align right edges if near the right of the screen
            var topLeftScreenX = anchorButtonScreenRect.minX
            if topLeftScreenX + menuW > screenFrame.maxX - 10.0 {
                topLeftScreenX = anchorButtonScreenRect.maxX - menuW
            }
            topLeftScreenX = min(max(topLeftScreenX, screenFrame.minX + 10.0), screenFrame.maxX - menuW - 10.0)

            // 2. Vertical:
            // Prefer opening BELOW the button (`top of menu == anchorButtonScreenRect.minY - 8`) so the menu sits cleanly below the button highlight!
            // If the HUD bar is near the bottom of the screen and there isn't enough vertical space below (`belowTopY - menuH < screenFrame.minY + 10`),
            // open cleanly ABOVE the button (`bottom of menu == anchorButtonScreenRect.maxY + 8`, so `top of menu == anchorButtonScreenRect.maxY + 8 + menuH`).
            let belowTopScreenY = anchorButtonScreenRect.minY - 8.0
            let aboveTopScreenY = anchorButtonScreenRect.maxY + 8.0 + menuH

            let topLeftScreenY: CGFloat
            if belowTopScreenY - menuH >= screenFrame.minY + 10.0 {
                topLeftScreenY = belowTopScreenY
            } else {
                topLeftScreenY = min(aboveTopScreenY, screenFrame.maxY - 10.0)
            }

            let ptInWin = win.convertPoint(fromScreen: NSPoint(x: topLeftScreenX, y: topLeftScreenY))
            let ptInView = contentView.convert(ptInWin, from: nil)
            menu.popUp(positioning: nil, at: ptInView, in: contentView)
        } else {
            let mouseLoc = NSEvent.mouseLocation
            menu.popUp(positioning: nil, at: mouseLoc, in: nil)
        }
    }

    private func makeCommandItem(title: String, symbol: String, action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let target = HUDMenuClosureTarget(action: action)
        retainedTargets.append(target)
        let item = NSMenuItem(title: title, action: #selector(HUDMenuClosureTarget.invoke(_:)), keyEquivalent: "")
        item.target = target
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }
}

@MainActor
private final class HUDMenuClosureTarget: NSObject {
    let action: @MainActor () -> Void
    init(action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func invoke(_ sender: Any?) { action() }
}

private struct HUDMenuSectionHeaderView: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }
}

private struct HUDCountdownSegmentedRowView: View {
    @Bindable var coordinator: RecordingCoordinator

    var body: some View {
        HStack(spacing: 14) {
            Text("Countdown")
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 12)

            // 4-segment pill selector (`Off | 3s | 5s | 10s`)
            HStack(spacing: 0) {
                let options = RecordingCountdownOption.allCases
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    let isSelected = (coordinator.countdownOption == option)
                    Button {
                        withAnimation(.easeInOut(duration: 0.14)) {
                            coordinator.countdownOption = option
                        }
                    } label: {
                        Text(option.label)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minWidth: 38, minHeight: 24)
                            .padding(.horizontal, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isSelected ? Color(red: 0.04, green: 0.52, blue: 1.0) : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Subtle vertical divider between unselected adjacent options
                    if index < options.count - 1 {
                        let nextOption = options[index + 1]
                        let showDivider = (coordinator.countdownOption != option && coordinator.countdownOption != nextOption)
                        Rectangle()
                            .fill(Color.white.opacity(showDivider ? 0.18 : 0.0))
                            .frame(width: 1, height: 13)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                    .fill(Color.white.opacity(0.11))
            )
        }
        .padding(.horizontal, 14)
    }
}

private struct HUDSwitchMenuRowView: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 12)

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .tint(Color(red: 0.04, green: 0.52, blue: 1.0))
        }
        .padding(.horizontal, 14)
    }
}

// MARK: - Floating Recording HUD Bar View (`NSPanel` Content — Idle Bar, Countdown Bar, and Compact Recording Bar)

public struct RecordingHUDBarView: View {
    @Bindable var coordinator: RecordingCoordinator
    @Bindable private var workspace = ProjectWorkspaceStore.shared

    private let buttonHeight: CGFloat = 44

    public var body: some View {
        Group {
            if coordinator.isRecording {
                activeRecordingCompactBar
            } else if coordinator.isCountingDown {
                countdownBar
            } else {
                idlePreRecordingBar
            }
        }
        .frame(height: RecordingCoordinator.barHeight)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.32))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        )
        .preferredColorScheme(.dark)
    }

    // MARK: - 1. Idle Pre-Recording HUD Bar ( — Borderless Hover Buttons + Recording Options `⚙️ ⌄`)

    private var idlePreRecordingBar: some View {
        HStack(spacing: 8) {
            // 1. Close button (ESC)
            HUDInteractiveItemButton(
                tooltip: "Close (ESC)",
                isSelected: false,
                width: 32,
                height: 32,
                cornerRadius: 16
            ) {
                coordinator.hideRecordingHUD()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
            }

            Divider()
                .frame(height: 28)
                .padding(.horizontal, 2)

            // 2. Capture Target Mode Buttons (Display, Window, Area, Device — Uniform 44pt height, NO border/outline on hover!)
            HStack(spacing: 4) {
                ForEach(CaptureTargetMode.allCases) { mode in
                    let isSelected = (coordinator.isPickingTarget && coordinator.selectedMode == mode)
                    HUDInteractiveItemButton(
                        tooltip: nil,
                        isSelected: isSelected,
                        width: 58,
                        height: buttonHeight,
                        cornerRadius: 10
                    ) {
                        coordinator.selectMode(mode)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: mode.systemImage)
                                .font(.system(size: 16, weight: .regular))
                            Text(mode.title)
                                .font(.system(size: 11, weight: .regular))
                                .lineLimit(1)
                        }
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.75))
                    }
                }
            }

            Divider()
                .frame(height: 28)
                .padding(.horizontal, 2)

            // 3. Microphone & System Audio Buttons (Uniform 44pt height, NO border/outline on hover!)
            HStack(spacing: 6) {
                HUDInteractiveItemButton(
                    tooltip: coordinator.captureMicrophone ? "Disable microphone" : "Enable microphone",
                    isSelected: coordinator.captureMicrophone,
                    width: nil,
                    height: buttonHeight,
                    cornerRadius: 10
                ) {
                    coordinator.captureMicrophone.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: coordinator.captureMicrophone ? "mic.fill" : "mic.slash")
                            .font(.system(size: 13.5, weight: .regular))
                        Text(coordinator.captureMicrophone ? "Microphone" : "No microphone")
                            .font(.system(size: 12.5, weight: .regular))
                            .lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(coordinator.captureMicrophone ? .white : .white.opacity(0.70))
                    .padding(.horizontal, 12)
                }

                HUDInteractiveItemButton(
                    tooltip: coordinator.captureSystemAudio ? "Mute system audio" : "Record system audio",
                    isSelected: coordinator.captureSystemAudio,
                    width: nil,
                    height: buttonHeight,
                    cornerRadius: 10
                ) {
                    coordinator.captureSystemAudio.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: coordinator.captureSystemAudio ? "speaker.wave.2.fill" : "speaker.slash")
                            .font(.system(size: 13.5, weight: .regular))
                        Text(coordinator.captureSystemAudio ? "System audio" : "No audio")
                            .font(.system(size: 12.5, weight: .regular))
                            .lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(coordinator.captureSystemAudio ? .white : .white.opacity(0.70))
                    .padding(.horizontal, 12)
                }
            }

            Divider()
                .frame(height: 28)
                .padding(.horizontal, 2)

            // 4. Projects Folder Button + Recording Options Button (`⚙️ ⌄`)
            HStack(spacing: 4) {
                HUDInteractiveItemButton(
                    tooltip: "Projects",
                    isSelected: false,
                    width: 44,
                    height: buttonHeight,
                    cornerRadius: 10,
                    onActionWithScreenRect: { buttonScreenRect in
                        HUDNativeMenuPresenter.shared.presentProjectsMenu(
                            coordinator: coordinator,
                            workspace: workspace,
                            anchorButtonScreenRect: buttonScreenRect,
                            from: NSApp.windows.first(where: { $0 is DraggableHUDPanel })
                        )
                    }
                ) {
                    Image(systemName: "folder")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.white.opacity(0.85))
                }

                HUDInteractiveItemButton(
                    tooltip: "Recording options",
                    isSelected: false,
                    width: 56,
                    height: buttonHeight,
                    cornerRadius: 10,
                    onActionWithScreenRect: { buttonScreenRect in
                        HUDNativeMenuPresenter.shared.presentRecordingOptionsMenu(
                            coordinator: coordinator,
                            anchorButtonScreenRect: buttonScreenRect,
                            from: NSApp.windows.first(where: { $0 is DraggableHUDPanel })
                        )
                    }
                ) {
                    HStack(spacing: 5) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 15.5, weight: .regular))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.88))
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 2. Pre-Recording Countdown HUD Bar ( — `Get ready. Recording will start soon.` + `Continue (1)`)

    private var countdownBar: some View {
        let coralColor = Color(red: 0.96, green: 0.46, blue: 0.43)
        let secondsInt = max(1, Int(ceil(coordinator.countdownRemainingSeconds)))
        let progress = max(0.0, min(1.0, coordinator.countdownRemainingSeconds / max(1.0, coordinator.countdownTotalSeconds)))

        return HStack(spacing: 14) {
            // Left: Cancel Countdown (`xmark.circle.fill`)
            HUDInteractiveItemButton(
                tooltip: "Cancel countdown (ESC)",
                isSelected: false,
                width: 36,
                height: 36,
                cornerRadius: 18
            ) {
                coordinator.cancelCountdown()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.white.opacity(0.92))
            }

            Rectangle()
                .fill(Color.white.opacity(0.16))
                .frame(width: 1, height: 28)

            // Center: "Get ready. Recording will start soon."
            Text("Get ready. Recording will start soon.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Rectangle()
                .fill(Color.white.opacity(0.16))
                .frame(width: 1, height: 28)

            // Right: "Continue" + Circular Countdown Ring (Clicking starts recording immediately!)
            HUDInteractiveItemButton(
                tooltip: nil,
                isSelected: false,
                width: nil,
                height: 42,
                cornerRadius: 10
            ) {
                coordinator.skipCountdownAndStartImmediately()
            } label: {
                HStack(spacing: 9) {
                    Text("Continue")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(coralColor)

                    ZStack {
                        Circle()
                            .stroke(coralColor.opacity(0.22), lineWidth: 2.2)

                        Circle()
                            .trim(from: 0.0, to: progress)
                            .stroke(
                                coralColor,
                                style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))

                        Text("\(secondsInt)")
                            .font(.system(size: 11.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(coralColor)
                    }
                    .frame(width: 22, height: 22)
                }
                .padding(.horizontal, 10)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 3. Active Recording Compact HUD Bar ( — `[⏹ 0:04 | ⏸  ↺  🗑]`)

    private var activeRecordingCompactBar: some View {
        let stopRed = Color(red: 1.0, green: 0.27, blue: 0.21)

        return HStack(spacing: 10) {
            // Left: Stop Recording Button (Red Stop-Circle Icon + Red Elapsed Timer `0:04`)
            HUDInteractiveItemButton(
                tooltip: "Finish recording",
                isSelected: false,
                width: nil,
                height: 42,
                cornerRadius: 10
            ) {
                Task { await coordinator.stopRecordingAndOpenEditor() }
            } label: {
                HStack(spacing: 9) {
                    // Red circle with rounded square stop icon inside
                    ZStack {
                        Circle()
                            .strokeBorder(stopRed, lineWidth: 2.2)
                            .frame(width: 20, height: 20)

                        RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                            .fill(stopRed)
                            .frame(width: 8, height: 8)
                    }

                    Text(formatCompactElapsed(coordinator.recordingElapsedSeconds))
                        .font(.system(size: 15, weight: .bold).monospacedDigit())
                        .foregroundStyle(coordinator.isRecordingPaused ? Color.orange : stopRed)
                }
                .padding(.horizontal, 8)
            }

            Rectangle()
                .fill(Color.white.opacity(0.20))
                .frame(width: 1, height: 26)

            // Right: Pause/Resume (`⏸`), Restart (`↺`), and Trash/Discard (`🗑`)
            HStack(spacing: 6) {
                HUDInteractiveItemButton(
                    tooltip: coordinator.isRecordingPaused ? "Resume recording" : "Pause recording",
                    isSelected: coordinator.isRecordingPaused,
                    width: 38,
                    height: 38,
                    cornerRadius: 9
                ) {
                    coordinator.togglePauseRecording()
                } label: {
                    Image(systemName: coordinator.isRecordingPaused ? "play.circle.fill" : "pause.circle.fill")
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(.white.opacity(0.90))
                }

                HUDInteractiveItemButton(
                    tooltip: "Restart recording",
                    isSelected: false,
                    width: 38,
                    height: 38,
                    cornerRadius: 9
                ) {
                    Task { await coordinator.restartCurrentRecording() }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 16.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.90))
                }

                HUDInteractiveItemButton(
                    tooltip: "Cancel & delete recording",
                    isSelected: false,
                    width: 38,
                    height: 38,
                    cornerRadius: 9
                ) {
                    coordinator.promptDiscardCurrentRecording()
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.white.opacity(0.90))
                }
            }
        }
        .padding(.horizontal, 14)
    }

    private func formatCompactElapsed(_ sec: TimeInterval) -> String {
        let total = Int(sec)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

/// Borderless Hover-Highlight Button for the Recording HUD Panel:
/// NO border/outline on hover — only a smooth rounded fill + standalone floating top tooltip window that never clips!).
private struct HUDInteractiveItemButton<LabelContent: View>: View {
    let tooltip: String?
    let isSelected: Bool
    let width: CGFloat?
    let height: CGFloat
    let cornerRadius: CGFloat
    let action: () -> Void
    let onActionWithScreenRect: ((NSRect) -> Void)?
    @ViewBuilder let label: () -> LabelContent

    @State private var isHovered = false
    @State private var anchorNSView: NSView?

    init(
        tooltip: String?,
        isSelected: Bool,
        width: CGFloat?,
        height: CGFloat,
        cornerRadius: CGFloat,
        action: @escaping () -> Void = {},
        onActionWithScreenRect: ((NSRect) -> Void)? = nil,
        @ViewBuilder label: @escaping () -> LabelContent
    ) {
        self.tooltip = tooltip
        self.isSelected = isSelected
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.action = action
        self.onActionWithScreenRect = onActionWithScreenRect
        self.label = label
    }

    var body: some View {
        Button {
            SharedFloatingTooltipWindowController.shared.hideTooltip(ifOwnedBy: anchorNSView)
            if let onActionWithScreenRect {
                onActionWithScreenRect(currentScreenRect())
            } else {
                action()
            }
        } label: {
            label()
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(backgroundColor)
                )
                .background(
                    TooltipScreenRectProbe { v in
                        anchorNSView = v
                    }
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
            if hovering, let tooltip = tooltip, !tooltip.isEmpty {
                let rect = currentScreenRect()
                if rect.width > 0 {
                    SharedFloatingTooltipWindowController.shared.showTooltip(
                        text: tooltip,
                        edge: .top,
                        forButtonScreenRect: rect,
                        ownerView: anchorNSView
                    )
                }
            } else {
                SharedFloatingTooltipWindowController.shared.hideTooltip(ifOwnedBy: anchorNSView)
            }
        }
        .onDisappear {
            if isHovered {
                SharedFloatingTooltipWindowController.shared.hideTooltip(ifOwnedBy: anchorNSView)
            }
        }
    }

    private func currentScreenRect() -> NSRect {
        guard let v = anchorNSView, let win = v.window else { return .zero }
        let rectInWin = v.convert(v.bounds, to: nil)
        return win.convertToScreen(rectInWin)
    }

    private var backgroundColor: Color {
        if isSelected {
            return isHovered ? Color.white.opacity(0.20) : Color.white.opacity(0.14)
        }
        return isHovered ? Color.white.opacity(0.11) : Color.clear
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
                                .font(.system(size: 13, weight: .regular, design: .default).monospacedDigit())
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
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.18), in: Capsule())
                        }

                        Button {
                            coordinator.requestStartRecording()
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
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.black.opacity(0.35))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(0.16), lineWidth: 1)
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
                            .font(.system(size: 13, weight: .regular, design: .default).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.75))

                        Button {
                            coordinator.requestStartRecording()
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
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.black.opacity(0.35))
                    )
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
                            .font(.system(size: 13.5, weight: .medium, design: .default).monospacedDigit())
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
                            coordinator.requestStartRecording()
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
