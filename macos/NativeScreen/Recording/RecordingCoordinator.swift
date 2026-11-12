import Foundation
import SwiftUI
import AppKit
import Observation
import ScreenCaptureKit
import AVFoundation

/// Custom `NSPanel` that allows dragging the Recording HUD from ANYWHERE on the bar (even when pressing on buttons),
/// while still allowing normal clicks on buttons, and persists its global multi-monitor position.
private final class DraggableHUDPanel: NSPanel, AlwaysDarkChromeWindow {
    var onPanelMoved: ((NSPoint) -> Void)?
    var isDragEnabled: (() -> Bool)?

    private var mouseDownScreenPoint: NSPoint = .zero
    private var mouseDownWindowOrigin: NSPoint = .zero
    private var isDraggingWindow: Bool = false
    private var isTrackingLeftClick: Bool = false

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if isDragEnabled?() == false {
                isTrackingLeftClick = false
                isDraggingWindow = false
                super.sendEvent(event)
                return
            }
            mouseDownScreenPoint = NSEvent.mouseLocation
            mouseDownWindowOrigin = frame.origin
            isDraggingWindow = false
            isTrackingLeftClick = true
            super.sendEvent(event)

        case .leftMouseDragged:
            guard isTrackingLeftClick, isDragEnabled?() != false else {
                super.sendEvent(event)
                return
            }
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
            isTrackingLeftClick = false
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
        case .off: return String(localized: "Off")
        case .threeSeconds: return "3s"
        case .fiveSeconds: return "5s"
        case .tenSeconds: return "10s"
        }
    }
}

/// Max camera resolution options in the Camera HUD menu (`720p`, `1080p`, `4K`).
public enum CameraMaxResolutionOption: String, CaseIterable, Identifiable, Sendable {
    case p720 = "720p"
    case p1080 = "1080p"
    case p4k = "4K"

    public var id: String { rawValue }
}

/// Identifies which HUD dropdown menu is currently open so its button stays highlighted (Images 1, 2, 4).
public enum HUDActiveMenuKind: Equatable, Sendable {
    case camera
    case microphone
    case systemAudio
    case projects
    case recordingOptions
}

public struct CapturableMediaDeviceInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool
}

public struct RunningAudioAppInfo: Identifiable {
    public let id: String // bundleIdentifier
    public let name: String
    public let icon: NSImage
    public let pid: pid_t
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
    public var selectedMode: CaptureTargetMode = .window {
        didSet {
            guard oldValue != selectedMode else { return }
            if selectedMode == .camera && selectedCameraDeviceID == nil {
                refreshConnectedMediaDevices()
                if let first = connectedCameras.first {
                    selectedCameraName = first.name
                    selectedCameraDeviceID = first.id
                }
            }
            updateFloatingCameraPreviewWindow()
            updateHUDPanelFrameForCurrentState(animated: true)
        }
    }
    public var activeHUDMenuKind: HUDActiveMenuKind? = nil {
        didSet {
            if activeHUDMenuKind == nil {
                lastHUDMenuClosedUptime = ProcessInfo.processInfo.systemUptime
            }
            updateHUDMicrophoneLevelMeter()
        }
    }

    // Live Connected Devices (Dynamically updated via `AVCaptureDeviceWasConnected` / `AVCaptureDeviceWasDisconnected`)
    public var connectedCameras: [CapturableMediaDeviceInfo] = []
    public var connectedMicrophones: [CapturableMediaDeviceInfo] = []

    // Camera Recording State ( & 9)
    public var selectedCameraDeviceID: String? = nil {
        didSet {
            updateHUDPanelFrameForCurrentState(animated: true)
            updateFloatingCameraPreviewWindow()
        }
    }
    public var selectedCameraName: String? = nil {
        didSet { updateHUDPanelFrameForCurrentState(animated: true) }
    }
    public var showCameraPreview: Bool = true {
        didSet { updateFloatingCameraPreviewWindow() }
    }
    public var cameraMaxResolution: CameraMaxResolutionOption = .p1080 {
        didSet { updateFloatingCameraPreviewWindow() }
    }

    // Microphone Recording State ( & 10)
    public var captureMicrophone: Bool = false {
        didSet {
            updateHUDPanelFrameForCurrentState(animated: true)
            updateHUDMicrophoneLevelMeter()
        }
    }
    public var selectedMicrophoneDeviceID: String? = nil {
        didSet {
            updateHUDPanelFrameForCurrentState(animated: true)
            updateHUDMicrophoneLevelMeter()
        }
    }
    public var selectedMicrophoneName: String? = nil {
        didSet { updateHUDPanelFrameForCurrentState(animated: true) }
    }
    public var liveMicrophoneLevel01: Double = 0.0
    public var liveMicrophonePeakHold01: Double = 0.0
    public var monitoredMicrophoneDeviceID: String? = nil

    // System Audio & Per-App Audio State ( & 3)
    public var captureSystemAudio: Bool = true {
        didSet { updateHUDPanelFrameForCurrentState(animated: true) }
    }
    public var systemAudioFromAllApps: Bool = true {
        didSet { updateHUDPanelFrameForCurrentState(animated: true) }
    }
    public var selectedSystemAudioAppBundleIDs: Set<String> = [] {
        didSet { updateHUDPanelFrameForCurrentState(animated: true) }
    }

    public var cameraButtonTitle: String {
        guard let name = selectedCameraName, selectedCameraDeviceID != nil else {
            return String(localized: "No camera")
        }
        return name
    }

    public var microphoneButtonTitle: String {
        guard captureMicrophone, let name = selectedMicrophoneName, selectedMicrophoneDeviceID != nil else {
            return String(localized: "No microphone")
        }
        return name
    }

    public var isSystemAudioEffectivelyActive: Bool {
        guard captureSystemAudio, selectedMode != .camera else { return false }
        if systemAudioFromAllApps { return true }
        return !selectedSystemAudioAppBundleIDs.isEmpty
    }

    public var systemAudioButtonTitle: String {
        guard captureSystemAudio else { return String(localized: "No system audio") }
        if systemAudioFromAllApps {
            return String(localized: "System audio")
        }
        let count = selectedSystemAudioAppBundleIDs.count
        if count == 0 {
            return String(localized: "No system audio")
        } else if count == 1 {
            return String(localized: "Sound from 1 app")
        } else {
            return String(localized: "Sound from \(count) apps")
        }
    }

    public func availableCameraDevices() -> [CapturableMediaDeviceInfo] {
        let defaultID = AVCaptureDevice.default(for: .video)?.uniqueID
        // Exclude `.deskViewCamera` so virtual overhead Desk View cameras never clutter the presenter camera list!
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
        if #available(macOS 14.0, *) {
            deviceTypes.append(.continuityCamera)
        }
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        var seenIDs = Set<String>()
        var list: [CapturableMediaDeviceInfo] = []
        for dev in session.devices {
            guard dev.isConnected,
                  !dev.isSuspended,
                  !dev.localizedName.localizedCaseInsensitiveContains("Desk View"),
                  !seenIDs.contains(dev.uniqueID) else {
                continue
            }
            seenIDs.insert(dev.uniqueID)
            list.append(
                CapturableMediaDeviceInfo(
                    id: dev.uniqueID,
                    name: dev.localizedName,
                    isDefault: dev.uniqueID == defaultID
                )
            )
        }
        if !list.isEmpty && !list.contains(where: { $0.isDefault }) {
            let first = list[0]
            list[0] = CapturableMediaDeviceInfo(id: first.id, name: first.name, isDefault: true)
        }
        // Sort so Default camera is at the top, followed by alphabetical order in)
        list.sort { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return list
    }

    public func availableMicrophoneDevices() -> [CapturableMediaDeviceInfo] {
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        var seenIDs = Set<String>()
        var list: [CapturableMediaDeviceInfo] = []
        for dev in session.devices {
            guard dev.isConnected,
                  !dev.isSuspended,
                  !seenIDs.contains(dev.uniqueID) else {
                continue
            }
            seenIDs.insert(dev.uniqueID)
            list.append(
                CapturableMediaDeviceInfo(
                    id: dev.uniqueID,
                    name: dev.localizedName,
                    isDefault: dev.uniqueID == defaultID
                )
            )
        }
        if !list.isEmpty && !list.contains(where: { $0.isDefault }) {
            let first = list[0]
            list[0] = CapturableMediaDeviceInfo(id: first.id, name: first.name, isDefault: true)
        }
        list.sort { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return list
    }

    public func refreshConnectedMediaDevices() {
        let cams = availableCameraDevices()
        let mics = availableMicrophoneDevices()
        self.connectedCameras = cams
        self.connectedMicrophones = mics

        if let selCam = selectedCameraDeviceID, !cams.contains(where: { $0.id == selCam }) {
            selectedCameraDeviceID = nil
            selectedCameraName = nil
        }
        if let selMic = selectedMicrophoneDeviceID, !mics.contains(where: { $0.id == selMic }) {
            if let defMic = mics.first {
                selectedMicrophoneDeviceID = defMic.id
                selectedMicrophoneName = defMic.name
            } else {
                captureMicrophone = false
                selectedMicrophoneDeviceID = nil
                selectedMicrophoneName = nil
            }
        }
    }

    public func runningAudioApps() -> [RunningAudioAppInfo] {
        let myBundleID = Bundle.main.bundleIdentifier
        var seenBundleIDs = Set<String>()
        var apps: [RunningAudioAppInfo] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  bundleID != myBundleID,
                  !seenBundleIDs.contains(bundleID),
                  let name = app.localizedName,
                  !name.isEmpty else {
                continue
            }
            seenBundleIDs.insert(bundleID)
            let icon = app.icon ?? NSWorkspace.shared.icon(forFile: app.bundleURL?.path ?? "/Applications")
            apps.append(RunningAudioAppInfo(id: bundleID, name: name, icon: icon, pid: app.processIdentifier))
        }

        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return apps
    }

    /// What happens when a recording stops (`Record > After Recording`).
    public enum AfterRecordingAction: String, CaseIterable, Identifiable {
        case createProject
        case exportToClipboard
        case exportToFile

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .createProject: return String(localized: "Create project")
            case .exportToClipboard: return String(localized: "Export and copy to clipboard")
            case .exportToFile: return String(localized: "Export and save to file")
            }
        }
    }

    public var afterRecordingAction: AfterRecordingAction = .createProject {
        didSet { UserDefaults.standard.set(afterRecordingAction.rawValue, forKey: afterRecordingActionKey) }
    }
    /// `Record > Automatically create zooms`: generate click-cluster zooms for new recordings.
    public var autoCreateZooms: Bool = true {
        didSet { UserDefaults.standard.set(autoCreateZooms, forKey: autoCreateZoomsKey) }
    }

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
    /// The speaker notes window (`SpeakerNotesPanel.swift`). It can be turned off any time, but on only between
    /// recordings: the capture leaves out the recording UI that is on screen when it starts.
    public var showSpeakerNotes: Bool = false {
        didSet {
            UserDefaults.standard.set(showSpeakerNotes, forKey: showSpeakerNotesKey)
            updateSpeakerNotesWindow()
        }
    }
    public var canTurnOnSpeakerNotes: Bool { !isRecording && !isCountingDown }

    // Multi-Monitor Window, Display & Area Picker State
    public var hoveredWindow: CapturableWindowInfo?
    public var hoveredDisplayID: CGDirectDisplayID = CGMainDisplayID()
    public var selectedAreaRectQuartz: CGRect = CGRect(x: 240, y: 160, width: 1280, height: 720)
    public var lastErrorMessage: String?

    public var onRecordingCompleted: ((ProjectSession) -> Void)?

    private var hudPanel: DraggableHUDPanel?
    private var floatingCameraPreviewPanel: DraggableHUDPanel?
    private var floatingCameraPreviewView: LiveCameraPreviewHostNSView?
    /// True while the preview is the large camera-mode stage instead of the small bubble.
    private var floatingCameraPreviewIsStage = false

    /// Camera mode shows a large preview with the record button. It stays up from picking the mode, through the
    /// countdown and the recording, until the mode is closed (click it again, Esc) or the recording bar hides, so the
    /// window is never rebuilt (and moved back) between those steps.
    private var cameraStageRequested = false {
        didSet {
            guard oldValue != cameraStageRequested else { return }
            updateFloatingCameraPreviewWindow()
        }
    }

    var isCameraStageActive: Bool {
        selectedMode == .camera && cameraStageRequested
    }

    /// Esc or a second click on the mode: stops picking a target and closes the camera stage.
    private func cancelTargetPicking() {
        isPickingTarget = false
        cameraStageRequested = false
        stopPickerOverlay()
    }
    private var hudMicLevelTimer: Timer?
    private var lastHUDMenuClosedUptime: TimeInterval = 0
    private var pickerOverlayWindows: [NSWindow] = []
    private var recordedAreaHighlightWindow: NSWindow?
    private var hoverTimer: Timer?
    @ObservationIgnored private var lastPickerMouseLocation: NSPoint?
    @ObservationIgnored private var pickerTicksSinceWindowQuery = 0
    private var countdownTimer: Timer?
    private var recordingTimer: Timer?
    /// True from the moment a start is accepted until the capture runs. `isRecording` only turns on after long awaits.
    private var isStartingRecording = false
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

    private let afterRecordingActionKey = "NativeScreen.RecordingOptions.AfterRecording"
    private let autoCreateZoomsKey = "NativeScreen.RecordingOptions.AutoCreateZooms"
    private let countdownOptionKey = "NativeScreen.RecordingOptions.Countdown"
    private let hideDesktopIconsKey = "NativeScreen.RecordingOptions.HideDesktopIcons"
    private let hideDockIconKey = "NativeScreen.RecordingOptions.HideDockIcon"
    private let highlightRecordedAreaKey = "NativeScreen.RecordingOptions.HighlightRecordedArea"
    private let showSpeakerNotesKey = "NativeScreen.RecordingOptions.ShowSpeakerNotes"

    fileprivate static let idleBarWidth: CGFloat = 900.0
    fileprivate static let countdownBarWidth: CGFloat = 496.0
    fileprivate static let recordingBarWidth: CGFloat = 278.0
    fileprivate static let barHeight: CGFloat = 64.0

    private init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: afterRecordingActionKey), let action = AfterRecordingAction(rawValue: raw) {
            afterRecordingAction = action
        }
        if defaults.object(forKey: autoCreateZoomsKey) != nil {
            autoCreateZooms = defaults.bool(forKey: autoCreateZoomsKey)
        }
        showSpeakerNotes = defaults.bool(forKey: showSpeakerNotesKey)
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

        refreshConnectedMediaDevices()
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshConnectedMediaDevices()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshConnectedMediaDevices()
            }
        }
    }

    // MARK: - Show / Hide Floating Recording HUD Bar (`NSPanel`)

    /// The bar's own width as laid out by SwiftUI, reported by `RecordingHUDBarView` whenever it changes. Measuring
    /// `fittingSize` right after a state change could still return the old layout (a longer microphone name not yet
    /// applied), leaving the window narrower than the bar so both rounded ends were cut off.
    @ObservationIgnored fileprivate var measuredHUDBarWidth: CGFloat = 0

    fileprivate func hudBarWidthDidChange(_ width: CGFloat) {
        guard width >= 1, abs(width - measuredHUDBarWidth) >= 0.5 else { return }
        measuredHUDBarWidth = width
        updateHUDPanelFrameForCurrentState(animated: true)
    }

    private var currentDesiredPanelSize: NSSize {
        if measuredHUDBarWidth >= 248 {
            return NSSize(width: ceil(measuredHUDBarWidth / 2.0) * 2.0, height: Self.barHeight)
        }
        if let hosting = hudPanel?.contentView {
            let fittingW = ceil(hosting.fittingSize.width)
            if fittingW >= 248 {
                // Always round up to an even integer width so `width * 0.5` is an exact integer (0.0 fractional part),
                // preventing 0.5pt rounding drift to the left on negative-coordinate secondary monitors (`x < 0`)!
                let evenW = ceil(fittingW / 2.0) * 2.0
                return NSSize(width: evenW, height: Self.barHeight)
            }
        }
        let width: CGFloat
        if isRecording {
            width = Self.recordingBarWidth
        } else if isCountingDown {
            width = Self.countdownBarWidth
        } else {
            width = Self.idleBarWidth
        }
        let evenW = ceil(width / 2.0) * 2.0
        return NSSize(width: evenW, height: Self.barHeight)
    }

    public func showRecordingHUD() {
        refreshConnectedMediaDevices()
        if hudPanel == nil {
            let initialSize = NSSize(width: Self.idleBarWidth, height: Self.barHeight)
            let panel = DraggableHUDPanel(
                contentRect: NSRect(origin: .zero, size: initialSize),
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
            // When idle (not recording), keep `.readOnly` so system screenshots can capture the HUD;
            // when recording starts, we switch `sharingType = .none` so neither screen recordings nor screenshots capture the active recording HUD!
            panel.sharingType = isRecording ? .none : .readOnly
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = false
            panel.isDragEnabled = { [weak self] in
                guard let self = self else { return true }
                if self.activeHUDMenuKind != nil { return false }
                let sinceMenuClose = ProcessInfo.processInfo.systemUptime - self.lastHUDMenuClosedUptime
                return sinceMenuClose > 0.15
            }
            panel.onPanelMoved = { [weak self] newOrigin in
                self?.saveHUDPanelOrigin(newOrigin)
            }

            let hostingView = NSHostingView(rootView: RecordingHUDBarView(coordinator: self))
            hostingView.sizingOptions = []
            panel.contentView = hostingView
            self.hudPanel = panel
        }

        let desiredSize = currentDesiredPanelSize
        if let panel = hudPanel {
            panel.sharingType = isRecording ? .none : .readOnly
            let restoredOrigin = restoredAndClampedHUDOrigin(panelSize: desiredSize)
            panel.setFrame(NSRect(origin: restoredOrigin, size: desiredSize), display: true)
            panel.orderFrontRegardless()
        }

        isPickingTarget = false
        stopPickerOverlay()
        isHUDVisible = true
        installEscapeKeyMonitors()
        updateFloatingCameraPreviewWindow()
        updateSpeakerNotesWindow()
        updateHUDMicrophoneLevelMeter()
    }

    /// Resizes the HUD panel smoothly around its current horizontal center (`midX`) when switching between Idle, Countdown, and Recording bars, or when button titles change.
    fileprivate func updateHUDPanelFrameForCurrentState(animated: Bool = true) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let panel = self.hudPanel else { return }
            let newSize = self.currentDesiredPanelSize
            let currentFrame = panel.frame
            guard abs(currentFrame.width - newSize.width) >= 2.0 || abs(currentFrame.height - newSize.height) >= 1.0 else {
                return
            }
            let newOriginX = floor(currentFrame.midX - newSize.width * 0.5 + 0.5)
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
            // Grow at once: an animated grow shows the bar wider than its window, ends clipped, for the whole animation.
            // Shrinking can animate, since the bar is then narrower than the window and the extra edge is transparent.
            panel.setFrame(targetFrame, display: true, animate: animated && newSize.width < currentFrame.width)
        }
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
        cancelTargetPicking()
        hideRecordedAreaHighlightOverlay()
        removeEscapeKeyMonitors()
        hudPanel?.orderOut(nil)
        isHUDVisible = false
        updateFloatingCameraPreviewWindow()
        updateSpeakerNotesWindow()
        updateHUDMicrophoneLevelMeter()
    }

    // MARK: - Floating Live Camera Preview Window & Live HUD Microphone Meter

    /// In camera mode the notes move under the built-in camera; they go back when the mode closes.
    private func syncSpeakerNotesDocking() {
        SpeakerNotesWindowController.shared.setDockedUnderCamera(isCameraStageActive, screen: hudPanel?.screen)
    }

    private func updateSpeakerNotesWindow() {
        defer { syncSpeakerNotesDocking() }
        let isActiveContext = isHUDVisible || isRecording || isCountingDown
        if isActiveContext && showSpeakerNotes {
            // Only shown while nothing is being captured; once shown it stays through the recording.
            if SpeakerNotesWindowController.shared.isShown || canTurnOnSpeakerNotes {
                SpeakerNotesWindowController.shared.show(near: hudPanel?.screen) { [weak self] in
                    self?.showSpeakerNotes = false
                }
            }
        } else {
            SpeakerNotesWindowController.shared.hide()
        }
    }

    private func updateFloatingCameraPreviewWindow() {
        defer { syncSpeakerNotesDocking() }
        let isActiveContext = (isHUDVisible || isRecording || isCountingDown)

        guard isActiveContext, let camID = selectedCameraDeviceID else {
            WarmCameraCaptureController.shared.setPreviewSurfaceHandler(nil)
            WarmCameraCaptureController.shared.stopSession()
            floatingCameraPreviewView = nil
            floatingCameraPreviewPanel?.orderOut(nil)
            floatingCameraPreviewPanel = nil
            return
        }

        // Request camera authorization if needed and keep the hardware camera session warm across HUD -> Countdown -> Recording!
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if authStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                Task { @MainActor [weak self] in
                    self?.updateFloatingCameraPreviewWindow()
                }
            }
            return
        }

        WarmCameraCaptureController.shared.ensureWarmSession(
            deviceID: camID,
            maxResolution: cameraMaxResolution
        )

        let isStage = isCameraStageActive
        guard showCameraPreview || isStage else {
            WarmCameraCaptureController.shared.setPreviewSurfaceHandler(nil)
            floatingCameraPreviewPanel?.orderOut(nil)
            return
        }

        if floatingCameraPreviewPanel != nil && floatingCameraPreviewIsStage != isStage {
            floatingCameraPreviewPanel?.orderOut(nil)
            floatingCameraPreviewPanel = nil
            floatingCameraPreviewView = nil
        }

        let screen = hudPanel?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let stageInset: CGFloat = 14
        let previewSize: NSSize = {
            guard isStage else { return NSSize(width: 224, height: 224) }
            let dims = WarmCameraCaptureController.shared.activeDimensions
            let aspect = dims.width > 0 && dims.height > 0 ? CGFloat(dims.width) / CGFloat(dims.height) : 16.0 / 9.0
            let width = min(720, vf.width * 0.5)
            return NSSize(width: width + stageInset * 2, height: width / aspect + stageInset * 2)
        }()
        if floatingCameraPreviewPanel == nil {
            // With speaker notes up, the stage sits under the notes docked at the top of the screen.
            let notesBottom = showSpeakerNotes && SpeakerNotesWindowController.shared.isShown
                ? SpeakerNotesWindowController.dockedFrame(on: screen).minY
                : nil
            let origin: NSPoint
            if !isStage {
                origin = NSPoint(x: vf.minX + 36, y: vf.minY + 120)
            } else if let notesBottom {
                origin = NSPoint(x: vf.midX - previewSize.width / 2, y: max(vf.minY, notesBottom - 4 - previewSize.height))
            } else {
                origin = NSPoint(x: vf.midX - previewSize.width / 2, y: vf.midY - previewSize.height / 2 + vf.height * 0.06)
            }
            let panel = DraggableHUDPanel(
                contentRect: NSRect(origin: origin, size: previewSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.level = .screenSaver
            panel.backgroundColor = .clear
            panel.isOpaque = false
            // Crucial: Set `hasShadow = false` on the borderless window and draw the soft rounded drop shadow inside `LiveCameraPreviewHostNSView`
            // so macOS WindowServer never renders a rectangular black shadow box around the squircle corners!
            panel.hasShadow = false
            // The bubble is kept out of screen recordings. The camera stage can show in screenshots: a camera-only
            // recording captures no screen.
            panel.sharingType = isStage ? .readOnly : .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = false

            let hostView = LiveCameraPreviewHostNSView(
                frame: NSRect(origin: .zero, size: previewSize),
                cornerRadius: isStage ? 18 : 42
            )
            if isStage {
                let overlay = NSHostingView(rootView: CameraStageOverlayView(coordinator: self).padding(stageInset))
                overlay.frame = hostView.bounds
                overlay.autoresizingMask = [.width, .height]
                hostView.addSubview(overlay)
            }
            panel.contentView = hostView
            floatingCameraPreviewView = hostView
            floatingCameraPreviewPanel = panel
            floatingCameraPreviewIsStage = isStage
        }

        WarmCameraCaptureController.shared.setPreviewSurfaceHandler { [weak self] ioSurface in
            Task { @MainActor [weak self] in
                self?.floatingCameraPreviewView?.displayCapturedSurface(ioSurface)
            }
        }
        floatingCameraPreviewPanel?.orderFrontRegardless()
    }

    private func updateHUDMicrophoneLevelMeter() {
        let isMenuMonitoring = (isHUDVisible && activeHUDMenuKind == .microphone)
        let isHUDMicActive = ((isHUDVisible || isRecording || isCountingDown) && captureMicrophone && selectedMicrophoneDeviceID != nil)

        if isHUDMicActive || isMenuMonitoring {
            hudMicLevelTimer?.invalidate()
            hudMicLevelTimer = nil
            let targetMicID = selectedMicrophoneDeviceID ?? connectedMicrophones.first?.id ?? AVCaptureDevice.default(for: .audio)?.uniqueID
            guard let micID = targetMicID else { return }

            WarmMicrophoneCaptureController.shared.setLevelUpdateHandler { [weak self] devID, instant01, trailing01 in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.monitoredMicrophoneDeviceID = devID
                    withAnimation(.linear(duration: 0.045)) {
                        self.liveMicrophoneLevel01 = instant01
                        self.liveMicrophonePeakHold01 = trailing01
                    }
                }
            }
            WarmMicrophoneCaptureController.shared.ensureWarmSession(deviceID: micID)
        } else {
            hudMicLevelTimer?.invalidate()
            hudMicLevelTimer = nil
            WarmMicrophoneCaptureController.shared.setLevelUpdateHandler(nil)
            if !isRecording {
                WarmMicrophoneCaptureController.shared.stopSession()
            }
            liveMicrophoneLevel01 = 0.0
            liveMicrophonePeakHold01 = 0.0
            monitoredMicrophoneDeviceID = nil
        }
    }

    public func selectMode(_ mode: CaptureTargetMode) {
        if selectedMode == mode && (isPickingTarget || isCameraStageActive) {
            cancelTargetPicking()
            return
        }
        selectedMode = mode
        isPickingTarget = true
        cameraStageRequested = mode == .camera
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
            // While recording, ESC belongs to the editor window that may be on camera.
            let isRecording = MainActor.assumeIsolated { self?.isRecording ?? false }
            if event.keyCode == 53, !isRecording { // ESC key
                Task { @MainActor [weak self] in
                    guard let self = self, !self.isRecording else { return }
                    if self.isCountingDown {
                        self.cancelCountdown()
                    } else if self.isPickingTarget || self.isCameraStageActive {
                        self.cancelTargetPicking()
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
                    } else if self.isPickingTarget || self.isCameraStageActive {
                        self.cancelTargetPicking()
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
        case .camera:
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
            overlay.sharingType = .none
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
                    // Listing every window costs a WindowServer round trip; with the mouse still, a refresh every
                    // 0.25 s is enough to follow windows that move or close under it.
                    let mouse = NSEvent.mouseLocation
                    self.pickerTicksSinceWindowQuery += 1
                    guard mouse != self.lastPickerMouseLocation || self.pickerTicksSinceWindowQuery >= 15 else { return }
                    self.lastPickerMouseLocation = mouse
                    self.pickerTicksSinceWindowQuery = 0
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
    /// - Parameter showsAlerts: false for automation (MCP): a problem is left in `lastErrorMessage` instead of a modal alert.
    /// - Returns: false when the recording was not started (already busy, no camera, or not enough disk space).
    @discardableResult
    public func requestStartRecording(showsAlerts: Bool = true) -> Bool {
        guard !isRecording && !isCountingDown && !isStartingRecording else { return false }
        // Checked once, here: every way to start a recording comes through this function.
        guard hasDiskSpaceToStartRecording(showsAlert: showsAlerts) else { return false }
        if selectedMode == .camera {
            guard selectedCameraDeviceID != nil else {
                lastErrorMessage = String(localized: "Choose a camera to record.")
                updateHUDPanelFrameForCurrentState(animated: true)
                return false
            }
            cameraStageRequested = true
        }
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
        return true
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
        guard !isRecording && !isStartingRecording else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }
        lastErrorMessage = nil
        isPickingTarget = false
        stopPickerOverlay()
        // Hide the active recording HUD (`[⏹ 0:04 | ⏸ ↺ 🗑]`) from both ScreenCaptureKit recordings and system screenshots!
        hudPanel?.sharingType = .none
        SpeakerNotesWindowController.shared.setHiddenFromCapture(true)

        if selectedMode == .camera {
            await startCameraOnlyRecording()
            return
        }
        // Before the filter is built, so it leaves the drawing panels out.
        LiveDrawingController.shared.prepare()
        hudPanel?.orderFrontRegardless()

        var startedPackageURL: URL?
        var startedTelemetry: TelemetryRecorder?
        var startedEngine: ScreenCaptureEngine?

        do {
            let shareable = try await SCShareableContent.excludingDesktopWindows(
                hideDesktopIcons,
                onScreenWindowsOnly: true
            )
            guard !shareable.displays.isEmpty else {
                lastErrorMessage = String(localized: "No capturable display found.")
                restorePostRecordingSystemState()
                updateHUDPanelFrameForCurrentState(animated: true)
                return
            }

            let myPID = ProcessInfo.processInfo.processIdentifier
            // Only the recording UI stays off camera (it all has `sharingType = .none`). Editor windows are recordable.
            let recordingUIWindowIDs = Set(NSApp.windows.filter { $0.sharingType == .none }.map { UInt32($0.windowNumber) })
            let recordingUIWindows = shareable.windows.filter { recordingUIWindowIDs.contains($0.windowID) }

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
                if let chosen = hoveredWindow ?? WindowDiscoveryService.listFrontToBackWindows(resolveCornerRadius: false).first.map(WindowDiscoveryService.withCornerRadius),
                   let scWindow = shareable.windows.first(where: { $0.windowID == chosen.id }) {
                    WindowDiscoveryService.bringWindowToFront(chosen)
                    logicalBounds = chosen.bounds
                    targetWindowId = chosen.id
                    targetBundleId = chosen.bundleId
                    targetAppName = chosen.appName
                    targetWindowTitle = chosen.title

                    let matchingScreen = NSScreen.screens.first(where: {
                        WindowDiscoveryService.quartzFrame(for: $0).intersects(chosen.bounds)
                    })
                    if let matchingScreen {
                        let dID = WindowDiscoveryService.displayID(for: matchingScreen)
                        if let scDisp = shareable.displays.first(where: { $0.displayID == dID }) {
                            targetDisplay = scDisp
                        }
                    }

                    if chosen.pid == myPID,
                       let matchingScreen {
                        // A single-window filter would drop the popovers, menus and tooltips a demo of the editor needs.
                        // Those are separate windows of this app, so capture the display without other windows and crop to the window.
                        // It stays a display filter because the system swaps the window controls for a sharing badge on app filters.
                        filter = SCContentFilter(
                            display: targetDisplay,
                            excludingWindows: recordingUIWindows + shareable.windows.filter { $0.owningApplication?.processID != myPID }
                        )
                        sourceRect = WindowDiscoveryService.localTopLeftRect(fromQuartzRect: chosen.bounds, on: matchingScreen)
                    } else {
                        filter = SCContentFilter(desktopIndependentWindow: scWindow)
                        sourceRect = nil
                    }
                } else {
                    filter = SCContentFilter(display: targetDisplay, excludingWindows: recordingUIWindows)
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
                filter = SCContentFilter(display: targetDisplay, excludingWindows: recordingUIWindows)
                logicalBounds = selectedAreaRectQuartz

            case .display, .camera: // `.camera` never gets here (`startCameraOnlyRecording`).
                filter = SCContentFilter(display: targetDisplay, excludingWindows: recordingUIWindows)
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
            let (packageURL, recordingDir, telemetryDir) = try Self.makeRecordingPackage()
            startedPackageURL = packageURL

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
            // An open editor keeps the Dock icon: without it the app loses its menu bar, which the editor may be demoing.
            if hideDockIcon && !ProjectWorkspaceStore.shared.hasOpenEditorWindows {
                NSApp.setActivationPolicy(.accessory)
                hudPanel?.orderFrontRegardless()
            }

            let outputVideoURL = recordingDir.appendingPathComponent("display.mp4")
            let outputWebcamURL = selectedCameraDeviceID != nil
                ? recordingDir.appendingPathComponent("webcam.mp4")
                : nil
            let outputMicrophoneURL = (captureMicrophone && selectedMicrophoneDeviceID != nil)
                ? recordingDir.appendingPathComponent("microphone.m4a")
                : nil

            // Written now so a crash or power loss leaves a package that can be recovered at the next launch (ADR-70).
            try Self.encodedForDisk(RecordingMetadata(durationMs: 0.0, captureTarget: targetMeta, tracks: currentRecordingTracks()))
                .write(to: recordingDir.appendingPathComponent("metadata.json"), options: .atomic)
            try Data("\(ProcessInfo.processInfo.processIdentifier)".utf8)
                .write(to: Self.inProgressMarkerURL(in: packageURL), options: .atomic)

            let engine = ScreenCaptureEngine()
            startedEngine = engine
            let telemetry = TelemetryRecorder(
                telemetryDirectoryURL: telemetryDir,
                captureLogicalBounds: logicalBounds
            )
            startedTelemetry = telemetry
            engine.onFirstVideoFrameArrived = { firstFrameUptimeSec in
                telemetry.markFirstVideoFrameArrived(atUptimeSec: firstFrameUptimeSec)
            }
            engine.onCaptureFailed = { [weak self, weak engine] failure in
                Task { @MainActor [weak self, weak engine] in
                    guard let self, let engine else { return }
                    await self.endRecordingAfterCaptureFailure(failure, engine: engine)
                }
            }
            telemetry.start()
            LiveDrawingController.shared.begin(
                captureBoundsQuartz: logicalBounds,
                telemetryDirectory: telemetryDir,
                timelineMs: { [weak telemetry] in telemetry?.currentTimelineMs() }
            )

            try await engine.startCapture(
                filter: filter,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                sourceRect: sourceRect,
                captureSystemAudio: isSystemAudioEffectivelyActive,
                outputVideoURL: outputVideoURL,
                cameraDeviceID: selectedCameraDeviceID,
                cameraMaxResolution: cameraMaxResolution,
                outputWebcamURL: outputWebcamURL,
                microphoneDeviceID: captureMicrophone ? selectedMicrophoneDeviceID : nil,
                outputMicrophoneURL: outputMicrophoneURL
            )
            // Fallback in case the first frame arrived before or shortly after `startCapture` returns
            telemetry.markFirstVideoFrameArrived(atUptimeSec: ProcessInfo.processInfo.systemUptime)

            markRecordingStarted(
                engine: engine,
                telemetry: telemetry,
                packageURL: packageURL,
                targetMeta: targetMeta,
                logicalBounds: logicalBounds
            )
        } catch {
            startedTelemetry?.stop()
            await startedEngine?.stopCapture()
            if let startedPackageURL {
                try? FileManager.default.removeItem(at: startedPackageURL)
            }
            restorePostRecordingSystemState()
            lastErrorMessage = error.localizedDescription
            updateHUDPanelFrameForCurrentState(animated: true)
        }
    }

    /// Shared by screen and camera-only recordings once capture is running: state, HUD and the elapsed-time timer.
    private func markRecordingStarted(
        engine: ScreenCaptureEngine,
        telemetry: TelemetryRecorder?,
        packageURL: URL,
        targetMeta: CaptureTargetMetadata,
        logicalBounds: CGRect?
    ) {
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
                let prevSecInt = Int(self.recordingElapsedSeconds)
                let now = ProcessInfo.processInfo.systemUptime
                self.recordingElapsedSeconds = max(0.0, now - self.recordingStartUptime - self.accumulatedPausedSeconds)
                let newSecInt = Int(self.recordingElapsedSeconds)
                // Only resize the HUD panel when the timer text digit count actually changes (e.g., 9:59 -> 10:00),
                // preventing 1Hz frame recalculations from drifting the HUD on secondary monitors!
                if (prevSecInt / 600) != (newSecInt / 600) {
                    self.updateHUDPanelFrameForCurrentState(animated: false)
                }
                self.checkDiskSpaceWhileRecording(now: now)
            }
        }
    }

    // MARK: - Free disk space (ADR-83)

    /// A recording does not start with less free space than this (about half an hour of a busy Retina screen).
    private static let minimumFreeBytesToStart: Int64 = 2_000_000_000
    /// Below this the recording stops by itself, leaving room to finish the files and write the project.
    private static let minimumFreeBytesWhileRecording: Int64 = 500_000_000
    private static let diskSpaceCheckInterval: TimeInterval = 5
    private var lastDiskSpaceCheckUptime: TimeInterval = 0
    private var isCheckingDiskSpace = false

    /// Free bytes on the volume that holds `url` (or its nearest existing folder). Nil when the system cannot say.
    nonisolated private static func freeDiskBytes(near url: URL) -> Int64? {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 {
            candidate = candidate.deletingLastPathComponent()
        }
        let values = try? candidate.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// False, after telling the user (or only setting `lastErrorMessage`), when the projects folder's disk is too full
    /// to start a recording. One quick volume query on the main thread, once per start.
    private func hasDiskSpaceToStartRecording(showsAlert: Bool) -> Bool {
        guard let free = Self.freeDiskBytes(near: ProjectWorkspaceStore.defaultProjectsDirectory),
              free < Self.minimumFreeBytesToStart else { return true }
        let message = String(localized: "There is not enough free disk space to record. Free up at least 2 GB and try again.")
        lastErrorMessage = message
        updateHUDPanelFrameForCurrentState(animated: true)
        guard showsAlert else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Not enough disk space")
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        return false
    }

    /// Every few seconds, off the main thread: a disk that is filling up ends the recording cleanly instead of
    /// letting the writers fail.
    private func checkDiskSpaceWhileRecording(now: TimeInterval) {
        guard !isCheckingDiskSpace, now - lastDiskSpaceCheckUptime >= Self.diskSpaceCheckInterval,
              let packageURL = activePackageURL, let engine = captureEngine else { return }
        let engineID = ObjectIdentifier(engine)
        lastDiskSpaceCheckUptime = now
        isCheckingDiskSpace = true
        Task.detached(priority: .utility) { [weak self] in
            let free = Self.freeDiskBytes(near: packageURL)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isCheckingDiskSpace = false
                guard let free, free < Self.minimumFreeBytesWhileRecording,
                      self.isRecording, self.captureEngine.map(ObjectIdentifier.init) == engineID else { return }
                Task { await self.endRecordingForLowDiskSpace() }
            }
        }
    }

    private func endRecordingForLowDiskSpace() async {
        guard isRecording else { return }
        let savedMs = await stopRecordingAndOpenEditor()
        showRecordingStoppedAlert(
            reason: String(localized: "The disk is almost full."),
            details: nil,
            savedMs: savedMs
        )
    }

    /// The package folders for a new recording: `<name>.nativescreen/recording/telemetry` and `assets`.
    private static func makeRecordingPackage() throws -> (package: URL, recording: URL, telemetry: URL) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let timestampName = "Recording \(formatter.string(from: Date()))"
        let packageURL = ProjectWorkspaceStore.defaultProjectsDirectory
            .appendingPathComponent("\(timestampName).nativescreen", isDirectory: true)
        let recordingDir = packageURL.appendingPathComponent("recording", isDirectory: true)
        let telemetryDir = recordingDir.appendingPathComponent("telemetry", isDirectory: true)
        try FileManager.default.createDirectory(at: telemetryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageURL.appendingPathComponent("assets", isDirectory: true), withIntermediateDirectories: true)
        return (packageURL, recordingDir, telemetryDir)
    }

    /// Records only the camera and microphone. No screen stream and no telemetry: the cursor, click and key files are
    /// empty, the way they are in a project made from a video, and `displayVideo` names the camera movie.
    private func startCameraOnlyRecording() async {
        guard let cameraID = selectedCameraDeviceID else {
            lastErrorMessage = String(localized: "Choose a camera to record.")
            restorePostRecordingSystemState()
            updateHUDPanelFrameForCurrentState(animated: true)
            return
        }
        var startedPackageURL: URL?
        do {
            let folders = try Self.makeRecordingPackage()
            startedPackageURL = folders.package
            for name in ["cursor.jsonl", "clicks.jsonl", "keys.jsonl"] {
                try Data().write(to: folders.telemetry.appendingPathComponent(name))
            }
            let dims = WarmCameraCaptureController.shared.activeDimensions
            let targetMeta = Self.cameraTargetMetadata(
                width: Int(dims.width),
                height: Int(dims.height),
                fps: WarmCameraCaptureController.shared.activeFps
            )
            let outputWebcamURL = folders.recording.appendingPathComponent("webcam.mp4")
            let outputMicrophoneURL = (captureMicrophone && selectedMicrophoneDeviceID != nil)
                ? folders.recording.appendingPathComponent("microphone.m4a")
                : nil

            try Self.encodedForDisk(RecordingMetadata(durationMs: 0.0, captureTarget: targetMeta, tracks: currentRecordingTracks()))
                .write(to: folders.recording.appendingPathComponent("metadata.json"), options: .atomic)
            try Data("\(ProcessInfo.processInfo.processIdentifier)".utf8)
                .write(to: Self.inProgressMarkerURL(in: folders.package), options: .atomic)

            if hideDockIcon && !ProjectWorkspaceStore.shared.hasOpenEditorWindows {
                NSApp.setActivationPolicy(.accessory)
                hudPanel?.orderFrontRegardless()
            }

            let engine = ScreenCaptureEngine()
            engine.onCaptureFailed = { [weak self, weak engine] failure in
                Task { @MainActor [weak self, weak engine] in
                    guard let self, let engine else { return }
                    await self.endRecordingAfterCaptureFailure(failure, engine: engine)
                }
            }
            engine.startCameraOnlyCapture(
                cameraDeviceID: cameraID,
                cameraMaxResolution: cameraMaxResolution,
                outputWebcamURL: outputWebcamURL,
                microphoneDeviceID: captureMicrophone ? selectedMicrophoneDeviceID : nil,
                outputMicrophoneURL: outputMicrophoneURL
            )
            markRecordingStarted(
                engine: engine,
                telemetry: nil,
                packageURL: folders.package,
                targetMeta: targetMeta,
                logicalBounds: nil
            )
        } catch {
            if let startedPackageURL {
                try? FileManager.default.removeItem(at: startedPackageURL)
            }
            restorePostRecordingSystemState()
            lastErrorMessage = error.localizedDescription
            updateHUDPanelFrameForCurrentState(animated: true)
        }
    }

    private static func cameraTargetMetadata(width: Int, height: Int, fps: Int) -> CaptureTargetMetadata {
        CaptureTargetMetadata(
            mode: .camera,
            displayId: 0,
            windowId: nil,
            appBundleId: nil,
            appName: nil,
            windowTitle: nil,
            logicalBounds: LogicalBounds(x: 0, y: 0, width: Double(width), height: Double(height)),
            pixelSize: PixelDimensions(width: width, height: height),
            scaleFactor: 1.0,
            refreshRate: Double(fps),
            windowBorderRadius: 0.0
        )
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
        captureEngine?.setPaused(newPaused, atUptime: now)
        telemetryRecorder?.setPaused(newPaused, atUptime: now)
        if newPaused { LiveDrawingController.shared.setDrawing(false) }
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
        alert.messageText = String(localized: "Discard this recording?")
        alert.informativeText = String(localized: "Everything recorded so far will be deleted.")
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.addButton(withTitle: String(localized: "Continue Recording"))

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

    /// Stops and deletes the recording without asking (AI agent `control_recording cancel`).
    public func discardCurrentRecording() async {
        guard isRecording else { return }
        await stopAndDeleteCurrentRecordingFiles()
        updateHUDPanelFrameForCurrentState(animated: true)
        hudPanel?.orderFrontRegardless()
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
        LiveDrawingController.shared.tearDown()
        hideRecordedAreaHighlightOverlay()
        hudPanel?.sharingType = .readOnly
        SpeakerNotesWindowController.shared.setHiddenFromCapture(false)
        updateFloatingCameraPreviewWindow()
        updateSpeakerNotesWindow()
        updateHUDMicrophoneLevelMeter()
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

    /// A writer failed or the stream ended by itself (`ScreenCaptureEngine.onCaptureFailed`): keep what was written,
    /// open it, and say why the recording stopped.
    private func endRecordingAfterCaptureFailure(_ failure: ScreenCaptureEngine.CaptureFailure, engine: ScreenCaptureEngine) async {
        guard isRecording, captureEngine === engine else { return }
        let savedMs = await stopRecordingAndOpenEditor()
        let reason: String
        let details: String
        switch failure {
        case .stream(let d):
            reason = String(localized: "The recorded window or display is no longer available.")
            details = d
        case .screenWriter(let d):
            reason = String(localized: "The screen video could not be written.")
            details = d
        case .webcamWriter(let d):
            reason = String(localized: "The camera video could not be written.")
            details = d
        case .microphoneWriter(let d):
            reason = String(localized: "The microphone audio could not be written.")
            details = d
        }
        showRecordingStoppedAlert(reason: reason, details: details, savedMs: savedMs)
    }

    /// Says why a recording ended by itself and how much of it was kept.
    private func showRecordingStoppedAlert(reason: String, details: String?, savedMs: Double?) {
        lastErrorMessage = reason
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Recording stopped")
        let outcome: String
        if let savedMs {
            let total = Int((savedMs / 1000.0).rounded())
            let length = String(format: "%d:%02d", total / 60, total % 60)
            outcome = String(localized: "The first \(length) was saved and opened in the editor.")
        } else {
            outcome = String(localized: "Nothing could be saved.")
        }
        alert.informativeText = details.map { "\(reason) \(outcome)\n\n\($0)" } ?? "\(reason) \(outcome)"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Returns the saved length in milliseconds, or nil when nothing was saved.
    @discardableResult
    public func stopRecordingAndOpenEditor(opensEditor: Bool = true) async -> Double? {
        guard isRecording else { return nil }
        recordingTimer?.invalidate()
        recordingTimer = nil
        isRecording = false
        isRecordingPaused = false

        telemetryRecorder?.stop()
        telemetryRecorder = nil

        if let engine = captureEngine {
            await engine.stopCapture()
        }
        let recordedMs = captureEngine?.recordedDurationMs ?? 0
        var durationMs = max(1000.0, captureEngine?.recordedDurationMs ?? (recordingElapsedSeconds * 1000.0))
        let failed = captureEngine?.captureFailure != nil
        captureEngine = nil
        activeLogicalBoundsQuartz = nil
        restorePostRecordingSystemState()

        guard let packageURL = activePackageURL,
              var targetMeta = activeTargetMetadata else {
            updateHUDPanelFrameForCurrentState(animated: true)
            return nil
        }

        let recordingDir = packageURL.appendingPathComponent("recording", isDirectory: true)
        let tracks = currentRecordingTracks(mode: targetMeta.mode)

        if targetMeta.mode == .camera {
            // The camera never sent a usable picture: there is nothing to edit.
            let cameraURL = recordingDir.appendingPathComponent(tracks.displayVideo)
            let track = try? await AVURLAsset(url: cameraURL).loadTracks(withMediaType: .video).first
            guard let track, recordedMs > 0 || failed else {
                try? FileManager.default.removeItem(at: packageURL)
                activePackageURL = nil
                activeTargetMetadata = nil
                lastErrorMessage = String(localized: "The camera did not send any picture, so nothing was recorded.")
                updateHUDPanelFrameForCurrentState(animated: true)
                hudPanel?.orderFrontRegardless()
                return nil
            }
            // The project is as long as the camera movie, however short (a screen recording is padded to 1 s).
            if recordedMs > 0 { durationMs = recordedMs }
            if let size = try? await track.load(.naturalSize), size.width > 0, size.height > 0 {
                targetMeta.pixelSize = PixelDimensions(width: Int(size.width), height: Int(size.height))
                targetMeta.logicalBounds = LogicalBounds(x: 0, y: 0, width: Double(size.width), height: Double(size.height))
            }
        }

        // A failed writer is never finished: the file holds only its complete 2 s fragments, so the project must not
        // be longer than what can be played back.
        if failed {
            let asset = AVURLAsset(url: recordingDir.appendingPathComponent(tracks.displayVideo))
            let playableMs = ((try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0) * 1000.0
            guard playableMs.isFinite, playableMs >= 500 else {
                try? FileManager.default.removeItem(at: packageURL)
                activePackageURL = nil
                activeTargetMetadata = nil
                updateHUDPanelFrameForCurrentState(animated: true)
                hudPanel?.orderFrontRegardless()
                return nil
            }
            durationMs = min(durationMs, playableMs)
        }
        writeProjectFiles(
            packageURL: packageURL,
            metadata: RecordingMetadata(durationMs: durationMs, captureTarget: targetMeta, tracks: tracks)
        )

        guard opensEditor else { return durationMs }

        hideRecordingHUD()

        if let session = ProjectWorkspaceStore.shared.openOrFocusProject(at: packageURL) {
            switch afterRecordingAction {
            case .createProject:
                break
            case .exportToClipboard:
                session.pendingEditorCommand = .quickExport(.clipboard)
            case .exportToFile:
                session.pendingEditorCommand = .quickExport(.file)
            }
            onRecordingCompleted?(session)
        }
        return durationMs
    }

    // MARK: - Project files and recovery

    private static func inProgressMarkerURL(in packageURL: URL) -> URL {
        packageURL.appendingPathComponent("recording", isDirectory: true).appendingPathComponent("in-progress")
    }

    private static func encodedForDisk<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    private func currentRecordingTracks(mode: CaptureTargetMode? = nil) -> RecordingTracksMetadata {
        if (mode ?? selectedMode) == .camera {
            return RecordingTracksMetadata(
                displayVideo: "webcam.mp4",
                webcamVideo: nil,
                microphoneAudio: (captureMicrophone && selectedMicrophoneDeviceID != nil) ? "microphone.m4a" : nil,
                systemAudio: nil,
                windowTelemetry: nil
            )
        }
        return RecordingTracksMetadata(
            displayVideo: "display.mp4",
            webcamVideo: selectedCameraDeviceID != nil ? "webcam.mp4" : nil,
            microphoneAudio: (captureMicrophone && selectedMicrophoneDeviceID != nil) ? "microphone.m4a" : nil,
            systemAudio: isSystemAudioEffectivelyActive ? "display.mp4" : nil
        )
    }

    /// Finishes a package: metadata, a new project built from the telemetry, and the in-progress marker removed.
    private func writeProjectFiles(packageURL: URL, metadata: RecordingMetadata) {
        let recordingDir = packageURL.appendingPathComponent("recording", isDirectory: true)
        if let data = try? Self.encodedForDisk(metadata) {
            try? data.write(to: recordingDir.appendingPathComponent("metadata.json"), options: .atomic)
        }

        let clicks = JSONLinesCodec.load(ClickEvent.self, from: recordingDir.appendingPathComponent(metadata.tracks.clicksTelemetry))
        let keys = JSONLinesCodec.load(KeyStrokeEvent.self, from: recordingDir.appendingPathComponent(metadata.tracks.keysTelemetry))
        let autoZooms = autoCreateZooms ? AutoZoomClusterGenerator.generateZooms(
            clicks: clicks,
            keys: keys,
            durationMs: metadata.durationMs,
            defaultScale: 1.8
        ) : []

        var doc = ProjectDocument(
            name: metadata.captureTarget.appName ?? packageURL.deletingPathExtension().lastPathComponent,
            camera: CameraConfig(enabled: metadata.tracks.webcamVideo != nil),
            timeline: TimelineConfig(
                slices: [ClipSlice(sourceStartMs: 0.0, sourceEndMs: metadata.durationMs, speed: 1.0)],
                zooms: autoZooms,
                maskTracks: []
            )
        )
        if let defPreset = AppSettings.shared.presetForNewProject() {
            defPreset.apply(to: &doc)
        }
        if metadata.captureTarget.mode == .camera {
            // The face keeps the picture framed when it is cropped or zoomed (scanned once, on device). No extra zoom:
            // the camera picture is the whole video.
            doc.camera.enableFaceTracking = true
            doc.camera.faceTrackingZoom = 1.0
        }
        // What was drawn on the screen while recording, as editable annotations.
        let drawings = JSONLinesCodec.load(LiveDrawingEvent.self, from: recordingDir.appendingPathComponent("telemetry/drawings.jsonl"))
        doc.timeline.annotationTracks.insert(
            contentsOf: LiveDrawingEvent.annotationTracks(from: drawings, durationMs: metadata.durationMs),
            at: 0
        )
        if let data = try? Self.encodedForDisk(doc) {
            try? data.write(to: packageURL.appendingPathComponent("project.json"), options: .atomic)
        }
        try? FileManager.default.removeItem(at: Self.inProgressMarkerURL(in: packageURL))
    }

    /// Opens recordings a crash or power loss cut off. The writers finish a fragment every 2 s, so the file plays up
    /// to the last one. A package still owned by another running copy of the app is left alone.
    public func recoverInterruptedRecordings() async {
        let packages = (try? FileManager.default.contentsOfDirectory(
            at: ProjectWorkspaceStore.defaultProjectsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for packageURL in packages where packageURL.pathExtension == "nativescreen" && packageURL != activePackageURL {
            let marker = Self.inProgressMarkerURL(in: packageURL)
            guard let owner = try? String(contentsOf: marker, encoding: .utf8) else { continue }
            if let pid = Int32(owner), pid != ProcessInfo.processInfo.processIdentifier, kill(pid, 0) == 0 { continue }

            let recordingDir = packageURL.appendingPathComponent("recording", isDirectory: true)
            guard let data = try? Data(contentsOf: recordingDir.appendingPathComponent("metadata.json")),
                  var metadata = try? JSONDecoder().decode(RecordingMetadata.self, from: data) else { continue }
            let asset = AVURLAsset(url: recordingDir.appendingPathComponent(metadata.tracks.displayVideo))
            let playableMs = ((try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0) * 1000.0
            guard playableMs.isFinite, playableMs >= 500 else {
                try? FileManager.default.trashItem(at: packageURL, resultingItemURL: nil)
                continue
            }
            metadata.durationMs = playableMs
            writeProjectFiles(packageURL: packageURL, metadata: metadata)
            ProjectWorkspaceStore.shared.openOrFocusProject(at: packageURL)?
                .showToast("Interrupted recording recovered", durationMs: 4000)
        }
    }

    // MARK: - App Menu Entry Points (`Record`, `View > Show recording widget`, `Window > Reset windows positions`)

    /// `Record > Record display / window / area`: opens the recording bar with that capture mode already picking a target.
    public func showRecordingHUD(mode: CaptureTargetMode) {
        guard !isRecording && !isCountingDown else { return }
        showRecordingHUD()
        if !(selectedMode == mode && isPickingTarget) {
            selectMode(mode)
        }
    }

    /// `Record > Record this project window`: starts recording an editor window without going through the picker.
    public func startRecordingWindow(_ window: CapturableWindowInfo) {
        guard !isRecording && !isCountingDown else { return }
        showRecordingHUD()
        selectedMode = .window
        hoveredWindow = window
        requestStartRecording()
    }

    public func toggleRecordingHUD() {
        if isHUDVisible {
            guard !isRecording && !isCountingDown else { return }
            hideRecordingHUD()
        } else {
            showRecordingHUD()
        }
    }

    public func resetHUDPosition() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: hasSavedHUDOriginKey)
        defaults.removeObject(forKey: savedHUDOriginXKey)
        defaults.removeObject(forKey: savedHUDOriginYKey)
        guard isHUDVisible, let panel = hudPanel else { return }
        let size = panel.frame.size
        panel.setFrame(NSRect(origin: restoredAndClampedHUDOrigin(panelSize: size), size: size), display: true, animate: true)
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
        let keysAppender = JSONLinesAppender(fileURL: telemetryDir.appendingPathComponent("keys.jsonl"))

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

        // Sample shortcuts & typing burst ( & 6!)
        keysAppender.append(KeyStrokeEvent(t: 4800.0, kind: "shortcut", modifiers: ["Alt", "Ctrl"], key: "Space", label: "⌥ ⌃ Space"))
        keysAppender.append(KeyStrokeEvent(t: 6400.0, kind: "typing", modifiers: nil, key: "D", label: "D"))
        keysAppender.append(KeyStrokeEvent(t: 7800.0, kind: "shortcut", modifiers: ["Meta"], key: "A", label: "⌘ A"))
        keysAppender.append(KeyStrokeEvent(t: 9100.0, kind: "shortcut", modifiers: nil, key: "Delete", label: "⌫"))
        let typingChars = ["A", "D", "D", "S", "F", "D", "A", "S", "F", "S", "D", "F", "G", "I", "T"]
        for (idx, ch) in typingChars.enumerated() {
            keysAppender.append(KeyStrokeEvent(t: 9900.0 + Double(idx) * 165.0, kind: "typing", modifiers: nil, key: ch, label: ch))
        }
        keysAppender.append(KeyStrokeEvent(t: 14400.0, kind: "shortcut", modifiers: ["Meta"], key: "ArrowRight", label: "⌘ →"))
        keysAppender.close()

        let metadata = RecordingMetadata(
            durationMs: durationMs,
            captureTarget: CaptureTargetMetadata(
                mode: .window,
                displayId: 1,
                appBundleId: "com.apple.Safari",
                appName: "Interactive Demo",
                windowTitle: "Native Screen 120Hz Engine Preview",
                logicalBounds: LogicalBounds(x: 100, y: 80, width: 1280, height: 800),
                pixelSize: PixelDimensions(width: 2560, height: 1600),
                scaleFactor: 2.0,
                refreshRate: 60.0,
                windowBorderRadius: 16.0
            ),
            tracks: RecordingTracksMetadata(
                displayVideo: "display.mp4",
                webcamVideo: "webcam.mp4",
                microphoneAudio: "microphone.m4a",
                systemAudio: "display.mp4"
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

        let sampleCaptions = LocalOnDeviceMediaIntelligence.synthesizeLocalFallbackTranscript(durationMs: durationMs)
        let doc = ProjectDocument(
            name: name,
            camera: CameraConfig(enabled: true),
            captions: CaptionsConfig(enabled: true, segments: sampleCaptions),
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

// MARK: - Native `NSMenu` Presenter for HUD Camera, Microphone, System Audio, Projects & Recording Options (Matches Images 1, 2, 3, 4!)

@MainActor
public final class HUDNativeMenuPresenter: NSObject {
    public static let shared = HUDNativeMenuPresenter()

    private var activeMenu: NSMenu?
    private var retainedTargets: [AnyObject] = []

    private override init() {
        super.init()
    }

    public func dismissActiveMenu() {
        activeMenu?.cancelTracking()
        activeMenu = nil
    }

    // MARK: - 1. Camera Menu (Camera List with "Default" Badge + "Don't record camera" + "Show camera preview" + "Max resolution" 720p/1080p/4K)

    public func presentCameraMenu(
        coordinator: RecordingCoordinator,
        anchorButtonScreenRect: NSRect,
        from panel: NSWindow?
    ) {
        SharedFloatingTooltipWindowController.shared.hideTooltip()
        coordinator.refreshConnectedMediaDevices()

        let menu = NSMenu(title: String(localized: "Camera"))
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        let contentView = NSHostingView(
            rootView: HUDCameraMenuContentView(
                coordinator: coordinator,
                onDismiss: { [weak self] in
                    self?.dismissActiveMenu()
                }
            )
        )
        let fitting = contentView.fittingSize
        let width = max(316.0, ceil(fitting.width))
        let height = max(180.0, ceil(fitting.height))
        contentView.sizingOptions = []
        contentView.autoresizingMask = [.width]
        contentView.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let item = NSMenuItem()
        item.view = contentView
        menu.addItem(item)
        menu.minimumWidth = width

        activeMenu = menu
        coordinator.activeHUDMenuKind = .camera
        popUpMenuOutsideButton(menu: menu, anchorButtonScreenRect: anchorButtonScreenRect, in: panel)
        coordinator.activeHUDMenuKind = nil
    }

    // MARK: - 2. Microphone Menu (Microphone List with "Default" Badge + Live Blue Input Level Meter Bars + "Don't record microphone")

    public func presentMicrophoneMenu(
        coordinator: RecordingCoordinator,
        anchorButtonScreenRect: NSRect,
        from panel: NSWindow?
    ) {
        SharedFloatingTooltipWindowController.shared.hideTooltip()
        coordinator.refreshConnectedMediaDevices()

        let menu = NSMenu(title: String(localized: "Microphone"))
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        let contentView = NSHostingView(
            rootView: HUDMicrophoneMenuContentView(
                coordinator: coordinator,
                onDismiss: { [weak self] in
                    self?.dismissActiveMenu()
                }
            )
        )
        let fitting = contentView.fittingSize
        let width = max(328.0, ceil(fitting.width))
        let height = max(120.0, ceil(fitting.height))
        contentView.sizingOptions = []
        contentView.autoresizingMask = [.width]
        contentView.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let item = NSMenuItem()
        item.view = contentView
        menu.addItem(item)
        menu.minimumWidth = width

        activeMenu = menu
        coordinator.activeHUDMenuKind = .microphone
        popUpMenuOutsideButton(menu: menu, anchorButtonScreenRect: anchorButtonScreenRect, in: panel)
        coordinator.activeHUDMenuKind = nil
    }

    // MARK: - 3. System Audio Menu ("Record system audio" + "From all apps" + Running GUI Apps with Real Icons & Switches)

    public func presentSystemAudioMenu(
        coordinator: RecordingCoordinator,
        anchorButtonScreenRect: NSRect,
        from panel: NSWindow?
    ) {
        SharedFloatingTooltipWindowController.shared.hideTooltip()

        let menu = NSMenu(title: String(localized: "System Audio"))
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        let runningApps = coordinator.runningAudioApps()
        let contentView = NSHostingView(
            rootView: HUDSystemAudioMenuContentView(
                coordinator: coordinator,
                runningApps: runningApps
            )
        )
        let fitting = contentView.fittingSize
        let width = max(284.0, ceil(fitting.width))
        let height = max(140.0, ceil(fitting.height))
        contentView.sizingOptions = []
        contentView.autoresizingMask = [.width]
        contentView.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let item = NSMenuItem()
        item.view = contentView
        menu.addItem(item)
        menu.minimumWidth = width

        activeMenu = menu
        coordinator.activeHUDMenuKind = .systemAudio
        popUpMenuOutsideButton(menu: menu, anchorButtonScreenRect: anchorButtonScreenRect, in: panel)
        coordinator.activeHUDMenuKind = nil
    }

    // MARK: - 4. Recording Options Menu (`⚙️ ⌄`)

    public func presentRecordingOptionsMenu(coordinator: RecordingCoordinator, anchorButtonScreenRect: NSRect, from panel: NSWindow?) {
        SharedFloatingTooltipWindowController.shared.hideTooltip()

        let menu = NSMenu(title: String(localized: "Recording Options"))
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        let menuWidth: CGFloat = 324.0

        // 0. Profiles: saved sets of HUD choices (`RecordingProfiles.swift`).
        let profilesHeaderItem = NSMenuItem()
        let profilesHeaderView = NSHostingView(rootView: HUDMenuSectionHeaderView(title: "Profiles"))
        profilesHeaderView.sizingOptions = []
        profilesHeaderView.autoresizingMask = [.width]
        profilesHeaderView.frame = NSRect(x: 0, y: 0, width: menuWidth, height: 26)
        profilesHeaderItem.view = profilesHeaderView
        menu.addItem(profilesHeaderItem)
        let profiles = RecordingProfileStore.shared.profiles
        let canApply = !coordinator.isRecording && !coordinator.isCountingDown
        for profile in profiles {
            let item = makeCommandItem(title: profile.name, symbol: "slider.horizontal.3") {
                coordinator.apply(profile)
            }
            item.title = profile.name
            item.state = coordinator.matches(profile) ? .on : .off
            item.isEnabled = canApply
            menu.addItem(item)
        }
        let saveItem = makeCommandItem(title: "Save Current Settings as Profile...", symbol: "plus") {
            guard let name = RecordingProfileStore.askName() else { return }
            RecordingProfileStore.shared.save(coordinator.currentRecordingProfile(named: name))
        }
        menu.addItem(saveItem)
        if !profiles.isEmpty {
            let deleteItem = NSMenuItem(title: "Delete Profile".localizedUI, action: nil, keyEquivalent: "")
            deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            let submenu = NSMenu()
            for profile in profiles {
                let item = makeCommandItem(title: profile.name, symbol: "minus.circle") {
                    RecordingProfileStore.shared.delete(id: profile.id)
                }
                item.title = profile.name
                submenu.addItem(item)
            }
            deleteItem.submenu = submenu
            menu.addItem(deleteItem)
        }
        menu.addItem(.separator())

        // 1. Section Header: "Before Recording"
        let beforeHeaderItem = NSMenuItem()
        let beforeHeaderView = NSHostingView(rootView: HUDMenuSectionHeaderView(title: "Before Recording"))
        beforeHeaderView.sizingOptions = []
        beforeHeaderView.autoresizingMask = [.width]
        beforeHeaderView.frame = NSRect(x: 0, y: 0, width: menuWidth, height: 26)
        beforeHeaderItem.view = beforeHeaderView
        menu.addItem(beforeHeaderItem)

        // 2. Countdown Row (`Off | 3s | 5s | 10s`: Single-line `.fixedSize(horizontal: true)` for i18n safety!)
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

        let notesItem = NSMenuItem()
        let notesView = NSHostingView(
            rootView: HUDSwitchMenuRowView(
                title: "Speaker Notes",
                isOn: Binding(
                    get: { coordinator.showSpeakerNotes },
                    set: { on in
                        if !on || coordinator.canTurnOnSpeakerNotes { coordinator.showSpeakerNotes = on }
                    }
                ),
                isEnabled: coordinator.showSpeakerNotes || coordinator.canTurnOnSpeakerNotes
            )
        )
        notesView.sizingOptions = []
        notesView.autoresizingMask = [.width]
        notesView.frame = NSRect(x: 0, y: 0, width: effectiveWidth, height: 36)
        notesItem.view = notesView
        menu.addItem(notesItem)

        let drawingsItem = NSMenuItem()
        let drawingsView = NSHostingView(
            rootView: HUDSwitchMenuRowView(
                title: "Drawings Stay Until Cleared",
                isOn: Binding(
                    get: { LiveDrawingController.shared.staysUntilCleared },
                    set: { LiveDrawingController.shared.staysUntilCleared = $0 }
                ),
                isEnabled: true
            )
        )
        drawingsView.sizingOptions = []
        drawingsView.autoresizingMask = [.width]
        drawingsView.frame = NSRect(x: 0, y: 0, width: effectiveWidth, height: 36)
        drawingsItem.view = drawingsView
        menu.addItem(drawingsItem)
        menu.minimumWidth = effectiveWidth

        activeMenu = menu
        coordinator.activeHUDMenuKind = .recordingOptions
        popUpMenuOutsideButton(menu: menu, anchorButtonScreenRect: anchorButtonScreenRect, in: panel)
        coordinator.activeHUDMenuKind = nil
    }

    // MARK: - 5. Projects Menu (`📁`)

    public func presentProjectsMenu(
        coordinator: RecordingCoordinator,
        workspace: ProjectWorkspaceStore,
        anchorButtonScreenRect: NSRect,
        from panel: NSWindow?
    ) {
        SharedFloatingTooltipWindowController.shared.hideTooltip()

        let menu = NSMenu(title: String(localized: "Projects"))
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        menu.addItem(makeCommandItem(title: "Open .nativescreen Project...", symbol: "folder") {
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
        coordinator.activeHUDMenuKind = .projects
        popUpMenuOutsideButton(menu: menu, anchorButtonScreenRect: anchorButtonScreenRect, in: panel)
        coordinator.activeHUDMenuKind = nil
    }

    /// Pops up the HUD context menu cleanly **outside** the clicked button highlight (below the button if there is room below on screen,
    /// or cleanly above the HUD bar if near the bottom of the screen, NEVER overlapping the button!).
    private func popUpMenuOutsideButton(menu: NSMenu, anchorButtonScreenRect: NSRect, in panel: NSWindow?) {
        let menuSize = menu.size
        let menuW = max(260.0, menuSize.width)
        let menuH = max(140.0, menuSize.height)

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
        let item = NSMenuItem(title: title.localizedUI, action: #selector(HUDMenuClosureTarget.invoke(_:)), keyEquivalent: "")
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

// MARK: - Custom Views Inside HUD `NSMenu`s (Camera, Microphone, System Audio, and Recording Options)

private struct HUDCameraMenuContentView: View {
    @Bindable var coordinator: RecordingCoordinator
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(coordinator.connectedCameras) { cam in
                let isSelected = (coordinator.selectedCameraDeviceID == cam.id)
                HUDSelectableMenuRowButton(isSelected: isSelected) {
                    coordinator.selectedCameraDeviceID = cam.id
                    coordinator.selectedCameraName = cam.name
                    onDismiss()
                } content: {
                    HStack(spacing: 10) {
                        Text(cam.name)
                            .font(.system(size: 13.5, weight: .regular))
                            .foregroundStyle(.white.opacity(0.96))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Spacer(minLength: 14)

                        if cam.isDefault {
                            HUDDefaultDevicePillBadge()
                        }
                    }
                }
            }

            // "Don't record camera"
            let isNoneSelected = (coordinator.selectedCameraDeviceID == nil)
            HUDSelectableMenuRowButton(isSelected: isNoneSelected) {
                coordinator.selectedCameraDeviceID = nil
                coordinator.selectedCameraName = nil
                onDismiss()
            } content: {
                Text("Don't record camera")
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Divider()
                .padding(.vertical, 5)
                .padding(.horizontal, 10)

            // "Show camera preview" Switch Row
            HStack(spacing: 14) {
                Text("Show camera preview")
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 12)

                Toggle("", isOn: $coordinator.showCameraPreview)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(Color(red: 0.04, green: 0.52, blue: 1.0))
                    .accessibilityLabel(Text("Show camera preview"))
            }
            .padding(.horizontal, 14)
            .frame(height: 32)

            // "Max resolution" [720p | 1080p | 4K] Row
            HStack(spacing: 14) {
                Text("Max resolution")
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 12)

                HStack(spacing: 0) {
                    let options = CameraMaxResolutionOption.allCases
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        let isSelected = (coordinator.cameraMaxResolution == option)
                        Button {
                            withAnimation(.easeInOut(duration: 0.14)) {
                                coordinator.cameraMaxResolution = option
                            }
                        } label: {
                            Text(option.rawValue)
                                .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 9)
                                .frame(height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(isSelected ? Color(red: 0.04, green: 0.52, blue: 1.0) : Color.clear)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])

                        if index < options.count - 1 {
                            let nextOption = options[index + 1]
                            let showDivider = (coordinator.cameraMaxResolution != option && coordinator.cameraMaxResolution != nextOption)
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
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Max resolution"))
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}

private struct HUDMicrophoneMenuContentView: View {
    @Bindable var coordinator: RecordingCoordinator
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(coordinator.connectedMicrophones) { mic in
                let isSelected = (coordinator.captureMicrophone && coordinator.selectedMicrophoneDeviceID == mic.id)
                let isMonitored = (coordinator.monitoredMicrophoneDeviceID == mic.id) || (coordinator.monitoredMicrophoneDeviceID == nil && mic.isDefault)
                let instantLevel = isMonitored ? coordinator.liveMicrophoneLevel01 : 0.0
                let trailingLevel = isMonitored ? coordinator.liveMicrophonePeakHold01 : 0.0

                HUDSelectableMenuRowButton(isSelected: isSelected, rowHeight: 44) {
                    coordinator.selectedMicrophoneDeviceID = mic.id
                    coordinator.selectedMicrophoneName = mic.name
                    coordinator.captureMicrophone = true
                    onDismiss()
                } content: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Text(mic.name)
                                .font(.system(size: 13.5, weight: .regular))
                                .foregroundStyle(.white.opacity(0.96))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)

                            Spacer(minLength: 14)

                            if mic.isDefault {
                                HUDDefaultDevicePillBadge()
                            }
                        }

                        // Live Dual-Bar Audio Level Meter underneath each microphone name
                        GeometryReader { geo in
                            let totalW = max(10.0, geo.size.width)
                            let brightW = totalW * CGFloat(max(0.0, min(1.0, instantLevel)))
                            let trailW = totalW * CGFloat(max(instantLevel, min(1.0, trailingLevel)))
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.15))
                                    .frame(width: totalW, height: 3.5)

                                if trailW > 1.0 {
                                    Capsule()
                                        .fill(Color(red: 0.04, green: 0.52, blue: 1.0).opacity(0.42))
                                        .frame(width: max(3.5, trailW), height: 3.5)
                                }

                                if brightW > 1.0 {
                                    Capsule()
                                        .fill(Color(red: 0.04, green: 0.52, blue: 1.0))
                                        .frame(width: max(3.5, brightW), height: 3.5)
                                }
                            }
                        }
                        .frame(height: 4)
                        .accessibilityDecorative()
                    }
                }
            }

            // "Don't record microphone"
            let isNoneSelected = (!coordinator.captureMicrophone || coordinator.selectedMicrophoneDeviceID == nil)
            HUDSelectableMenuRowButton(isSelected: isNoneSelected, rowHeight: 30) {
                coordinator.captureMicrophone = false
                coordinator.selectedMicrophoneDeviceID = nil
                coordinator.selectedMicrophoneName = nil
                onDismiss()
            } content: {
                Text("Don't record microphone")
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}

private struct HUDSystemAudioMenuContentView: View {
    @Bindable var coordinator: RecordingCoordinator
    let runningApps: [RunningAudioAppInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 1. "Record system audio" Switch
            HUDSwitchMenuRowView(
                title: "Record system audio",
                isOn: Binding(
                    get: { coordinator.captureSystemAudio },
                    set: { newValue in
                        coordinator.captureSystemAudio = newValue
                        if newValue && !coordinator.systemAudioFromAllApps && coordinator.selectedSystemAudioAppBundleIDs.isEmpty {
                            coordinator.systemAudioFromAllApps = true
                        }
                    }
                )
            )
            .frame(height: 34)

            // 2. "From all apps" Switch
            HUDSwitchMenuRowView(
                title: "From all apps",
                isOn: Binding(
                    get: { coordinator.captureSystemAudio && coordinator.systemAudioFromAllApps },
                    set: { allApps in
                        if allApps {
                            coordinator.captureSystemAudio = true
                            coordinator.systemAudioFromAllApps = true
                            coordinator.selectedSystemAudioAppBundleIDs.removeAll()
                        } else {
                            coordinator.systemAudioFromAllApps = false
                        }
                    }
                )
            )
            .frame(height: 34)

            Divider()
                .padding(.vertical, 5)
                .padding(.horizontal, 14)

            // 3. "Apps" Section Header + Per-App Switches with Real App Icons
            HUDMenuSectionHeaderView(title: "Apps")
                .frame(height: 24)

            ForEach(runningApps.prefix(12)) { app in
                let isAppOn = coordinator.captureSystemAudio
                    && !coordinator.systemAudioFromAllApps
                    && coordinator.selectedSystemAudioAppBundleIDs.contains(app.id)

                HStack(spacing: 10) {
                    Image(nsImage: app.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 19, height: 19)
                        .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))

                    Text(app.name)
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(.white.opacity(0.96))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 16)

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { isAppOn },
                            set: { enabled in
                                if enabled {
                                    coordinator.captureSystemAudio = true
                                    coordinator.systemAudioFromAllApps = false
                                    coordinator.selectedSystemAudioAppBundleIDs.insert(app.id)
                                } else {
                                    coordinator.selectedSystemAudioAppBundleIDs.remove(app.id)
                                }
                            }
                        )
                    )
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(Color(red: 0.04, green: 0.52, blue: 1.0))
                    .accessibilityLabel(Text(app.name))
                }
                .padding(.horizontal, 14)
                .frame(height: 32)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct HUDDefaultDevicePillBadge: View {
    var body: some View {
        Text("Default")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.16))
            )
            .fixedSize()
    }
}

private struct HUDSelectableMenuRowButton<RowContent: View>: View {
    let isSelected: Bool
    var rowHeight: CGFloat = 30
    let action: () -> Void
    @ViewBuilder let content: () -> RowContent

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.96))
                }
            }
            .frame(width: 14, alignment: .center)

            content()
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.14) : Color.clear)
        )
        .overlay(
            HUDMenuImmediateClickAndHoverOverlay(
                onHoverChanged: { isHovered = $0 },
                onClick: action
            )
        )
        .accessibleButton(isSelected: isSelected, action: action)
    }
}

private struct HUDMenuImmediateClickAndHoverOverlay: NSViewRepresentable {
    var onHoverChanged: ((Bool) -> Void)? = nil
    let onClick: () -> Void

    func makeNSView(context: Context) -> TrackingNSView {
        let v = TrackingNSView()
        v.onHoverChanged = onHoverChanged
        v.onClick = onClick
        return v
    }

    func updateNSView(_ nsView: TrackingNSView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
        nsView.onClick = onClick
    }

    final class TrackingNSView: NSView {
        var onHoverChanged: ((Bool) -> Void)?
        var onClick: (() -> Void)?
        private var trackingArea: NSTrackingArea?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea {
                removeTrackingArea(existing)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .enabledDuringMouseDrag, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChanged?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChanged?(false)
        }

        override func mouseDown(with event: NSEvent) {
            onClick?()
        }
    }
}

private struct HUDMenuSectionHeaderView: View {
    let title: String

    var body: some View {
        HStack {
            Text(title.localizedUI)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
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
                        .overlay(
                            HUDMenuImmediateClickAndHoverOverlay {
                                withAnimation(.easeInOut(duration: 0.14)) {
                                    coordinator.countdownOption = option
                                }
                            }
                        )
                        .accessibleButton(isSelected: isSelected) {
                            coordinator.countdownOption = option
                        }

                    // Subtle vertical divider between unselected adjacent options
                    if index < options.count - 1 {
                        let nextOption = options[index + 1]
                        let showDivider = (coordinator.countdownOption != option && coordinator.countdownOption != nextOption)
                        Rectangle()
                            .fill(Color.white.opacity(showDivider ? 0.18 : 0.0))
                            .frame(width: 1, height: 13)
                            .accessibilityDecorative()
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                    .fill(Color.white.opacity(0.11))
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Countdown"))
        }
        .padding(.horizontal, 14)
    }
}

private struct HUDSwitchMenuRowView: View {
    let title: String
    @Binding var isOn: Bool
    var isEnabled: Bool = true

    var body: some View {
        HStack(spacing: 14) {
            Text(title.localizedUI)
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
                .accessibilityLabel(Text(title.localizedUI))
                .disabled(!isEnabled)
        }
        .padding(.horizontal, 14)
        .opacity(isEnabled ? 1.0 : 0.5)
    }
}

// MARK: - True Behind-Window Liquid Glass `NSVisualEffectView` for the Recording HUD Panel ( & 4!)

private struct HUDLiquidGlassBackgroundView: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = cornerRadius
            glass.tintColor = NSColor(red: 0.06, green: 0.06, blue: 0.09, alpha: 0.34)
            return glass
        } else {
            let v = NSVisualEffectView()
            configureBlur(v)
            return v
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = nsView as? NSGlassEffectView {
            glass.style = .clear
            glass.cornerRadius = cornerRadius
            glass.tintColor = NSColor(red: 0.06, green: 0.06, blue: 0.09, alpha: 0.34)
        } else if let v = nsView as? NSVisualEffectView {
            configureBlur(v)
        }
    }

    /// macOS 14 and 15. Rounded with `maskImage`, at full alpha: a behind-window blur left the bar see-through
    /// with `alphaValue` below 1 and a rounded layer mask (ADR-62).
    private func configureBlur(_ view: NSVisualEffectView) {
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.maskImage = Self.roundedMask(cornerRadius: cornerRadius)
    }

    private static func roundedMask(cornerRadius: CGFloat) -> NSImage {
        let side = cornerRadius * 2 + 1
        let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        mask.resizingMode = .stretch
        return mask
    }
}

// MARK: - Floating Recording HUD Bar View (`NSPanel` content: Idle Bar, Countdown Bar, and Compact Recording Bar)

public struct RecordingHUDBarView: View {
    @Bindable var coordinator: RecordingCoordinator
    @Bindable private var workspace = ProjectWorkspaceStore.shared
    @Bindable private var drawing = LiveDrawingController.shared

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
        .background(
            HUDLiquidGlassBackgroundView(cornerRadius: 18)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
        )
        // The bar takes its own width and the window follows it, never the other way round.
        .fixedSize(horizontal: true, vertical: false)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            coordinator.hudBarWidthDidChange(width)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }

    // MARK: - 1. Idle Pre-Recording HUD Bar ( & 4 100%: `xmark.circle.fill` + 4 Target Modes + Camera/Mic/SystemAudio + Projects + Options!)

    private var idlePreRecordingBar: some View {
        HStack(spacing: 8) {
            // 1. Close button (`xmark.circle.fill`: No tooltip, rounded-rectangle hover background matching other HUD buttons!)
            HUDInteractiveItemButton(
                tooltip: nil,
                isSelected: false,
                width: 42,
                height: buttonHeight,
                cornerRadius: 10
            ) {
                coordinator.hideRecordingHUD()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.white.opacity(0.94))
            }
            .accessibilityLabel(Text("Close"))

            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 28)
                .padding(.horizontal, 2)

            // 2. Capture Target Mode Buttons (`Display`, `Window`, `Area`, `Camera`: Uniform 44pt height, crisp white icons!)
            HStack(spacing: 4) {
                ForEach(CaptureTargetMode.allCases) { mode in
                    let isSelected = coordinator.selectedMode == mode
                        && (coordinator.isPickingTarget || (mode == .camera && coordinator.isCameraStageActive))
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
                                .font(.system(size: 16.5, weight: .medium))
                                .foregroundStyle(.white.opacity(isSelected ? 1.0 : 0.92))
                            Text(mode.title)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.white.opacity(isSelected ? 0.98 : 0.72))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                }
            }

            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 28)
                .padding(.horizontal, 2)

            // 3. Camera, Microphone & System Audio Selector Buttons (No tooltips since they have explicit text labels!)
            HStack(spacing: 4) {
                // 3a. Camera Button (`No camera` or `<Camera Name>`: Truncated cleanly like `MacBoo...` in)
                let hasCamera = (coordinator.selectedCameraDeviceID != nil)
                HUDInteractiveItemButton(
                    tooltip: nil,
                    isSelected: coordinator.activeHUDMenuKind == .camera,
                    width: nil,
                    height: buttonHeight,
                    cornerRadius: 10,
                    onActionWithScreenRect: { buttonScreenRect in
                        HUDNativeMenuPresenter.shared.presentCameraMenu(
                            coordinator: coordinator,
                            anchorButtonScreenRect: buttonScreenRect,
                            from: NSApp.windows.first(where: { $0 is DraggableHUDPanel })
                        )
                    }
                ) {
                    HStack(spacing: 8) {
                        Image(systemName: hasCamera ? "video" : "video.slash")
                            .font(.system(size: 14.5, weight: .medium))
                        Text(coordinator.cameraButtonTitle)
                            .font(.system(size: 13, weight: hasCamera ? .medium : .regular))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: hasCamera ? 72 : 96, alignment: .leading)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(.white.opacity(hasCamera || coordinator.activeHUDMenuKind == .camera ? 0.96 : 0.65))
                    .padding(.horizontal, 12)
                }

                // 3b. Microphone Button (`No microphone` or `<Microphone Name>` + Live Horizontal Level Bar along bottom edge)
                let hasMic = (coordinator.captureMicrophone && coordinator.selectedMicrophoneDeviceID != nil)
                HUDInteractiveItemButton(
                    tooltip: nil,
                    isSelected: coordinator.activeHUDMenuKind == .microphone,
                    width: nil,
                    height: buttonHeight,
                    cornerRadius: 10,
                    onActionWithScreenRect: { buttonScreenRect in
                        HUDNativeMenuPresenter.shared.presentMicrophoneMenu(
                            coordinator: coordinator,
                            anchorButtonScreenRect: buttonScreenRect,
                            from: NSApp.windows.first(where: { $0 is DraggableHUDPanel })
                        )
                    }
                ) {
                    ZStack(alignment: .bottom) {
                        HStack(spacing: 8) {
                            Image(systemName: hasMic ? "mic.fill" : "mic.slash")
                                .font(.system(size: 14.5, weight: .medium))
                            Text(coordinator.microphoneButtonTitle)
                                .font(.system(size: 13, weight: hasMic ? .medium : .regular))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: hasMic ? 96 : 112, alignment: .leading)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.white.opacity(hasMic || coordinator.activeHUDMenuKind == .microphone ? 0.96 : 0.65))
                        .padding(.horizontal, 12)
                        .frame(height: buttonHeight)

                        if hasMic {
                            GeometryReader { meterGeo in
                                let totalW = max(10.0, meterGeo.size.width)
                                let brightW = totalW * CGFloat(max(0.0, min(1.0, coordinator.liveMicrophoneLevel01)))
                                let trailingW = totalW * CGFloat(max(coordinator.liveMicrophoneLevel01, min(1.0, coordinator.liveMicrophonePeakHold01)))
                                ZStack(alignment: .leading) {
                                    // 1. Dark base track
                                    Capsule()
                                        .fill(Color.white.opacity(0.14))
                                        .frame(width: totalW, height: 3.0)

                                    // 2. Dimmer trailing peak-hold bar (decays slightly slower behind the bright bar)
                                    if trailingW > 0.5 {
                                        Capsule()
                                            .fill(Color.white.opacity(0.30))
                                            .frame(width: max(3.0, trailingW), height: 3.0)
                                    }

                                    // 3. Bright instantaneous level bar
                                    if brightW > 0.5 {
                                        Capsule()
                                            .fill(Color.white.opacity(0.68))
                                            .frame(width: max(3.0, brightW), height: 3.0)
                                    }
                                }
                            }
                            .frame(height: 3.0)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 3.0)
                            .accessibilityDecorative()
                        }
                    }
                }

                // 3c. System Audio Button. A camera-only recording has no screen stream to take system audio from.
                if coordinator.selectedMode != .camera {
                    let sysAudioActive = coordinator.isSystemAudioEffectivelyActive
                    HUDInteractiveItemButton(
                        tooltip: nil,
                        isSelected: coordinator.activeHUDMenuKind == .systemAudio,
                        width: nil,
                        height: buttonHeight,
                        cornerRadius: 10,
                        onActionWithScreenRect: { buttonScreenRect in
                            HUDNativeMenuPresenter.shared.presentSystemAudioMenu(
                                coordinator: coordinator,
                                anchorButtonScreenRect: buttonScreenRect,
                                from: NSApp.windows.first(where: { $0 is DraggableHUDPanel })
                            )
                        }
                    ) {
                        HStack(spacing: 8) {
                            Image(systemName: "tv.music.note")
                                .font(.system(size: 14.5, weight: .medium))
                            Text(coordinator.systemAudioButtonTitle)
                                .font(.system(size: 13, weight: sysAudioActive ? .medium : .regular))
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.white.opacity(sysAudioActive || coordinator.activeHUDMenuKind == .systemAudio ? 0.96 : 0.65))
                        .padding(.horizontal, 12)
                    }
                }
            }

            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 28)
                .padding(.horizontal, 2)

            // 4. Projects Folder Button + Recording Options Button (`⚙️ ⌄`)
            HStack(spacing: 4) {
                HUDInteractiveItemButton(
                    tooltip: "Projects",
                    isSelected: coordinator.activeHUDMenuKind == .projects,
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
                        .font(.system(size: 15.5, weight: .regular))
                        .foregroundStyle(.white.opacity(0.88))
                }

                HUDInteractiveItemButton(
                    tooltip: "Recording options",
                    isSelected: coordinator.activeHUDMenuKind == .recordingOptions,
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
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - 2. Pre-Recording Countdown HUD Bar (`Get ready. Recording will start soon.` + `Continue (1)`)

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
                    .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
            }
            .accessibilityValue(Text(AccessibilityText.duration(ms: Double(secondsInt) * 1000)))
        }
        .padding(.horizontal, 16)
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - 3. Active Recording Compact HUD Bar (`[⏹ 0:04 | ⏸  ↺  🗑]`)

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
                        .font(.system(size: 15, weight: .regular).monospacedDigit())
                        .lineLimit(1)
                        .frame(minWidth: 38, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(coordinator.isRecordingPaused ? Color.orange : stopRed)
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
            }
            .accessibilityValue(Text(AccessibilityText.duration(ms: coordinator.recordingElapsedSeconds * 1000)))

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

            if drawing.isPrepared {
                Rectangle()
                    .fill(Color.white.opacity(0.20))
                    .frame(width: 1, height: 26)
                liveDrawingControls
            }
        }
        .padding(.horizontal, 16)
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Draw on the screen while recording: the toggle, then the tools, color, undo and clear while drawing.
    private var liveDrawingControls: some View {
        HStack(spacing: 6) {
            HUDInteractiveItemButton(
                tooltip: drawing.isDrawing ? "Stop drawing (Esc)" : "Draw on screen",
                isSelected: drawing.isDrawing,
                width: 38,
                height: 38,
                cornerRadius: 9
            ) {
                guard !coordinator.isRecordingPaused else { return }
                drawing.setDrawing(!drawing.isDrawing)
            } label: {
                Image(systemName: "pencil.tip.crop.circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white.opacity(coordinator.isRecordingPaused ? 0.35 : 0.90))
            }

            if drawing.isDrawing {
                ForEach(Array(LiveDrawingTool.allCases.enumerated()), id: \.element) { index, tool in
                    HUDInteractiveItemButton(
                        tooltip: "\(tool.title.localizedUI) (\(index + 1))",
                        isSelected: drawing.tool == tool,
                        width: 34,
                        height: 38,
                        cornerRadius: 9
                    ) {
                        drawing.tool = tool
                    } label: {
                        Image(systemName: tool.systemImage)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                }
                HUDInteractiveItemButton(tooltip: "Color", isSelected: false, width: 34, height: 38, cornerRadius: 9) {
                    let palette = LiveDrawingController.palette
                    let next = ((palette.firstIndex(of: drawing.color) ?? -1) + 1) % palette.count
                    drawing.color = palette[next]
                } label: {
                    Circle()
                        .fill(Color(nsColor: NSColor(hexString: drawing.color)))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
                }
                HUDInteractiveItemButton(tooltip: "Undo (⌘Z)", isSelected: false, width: 34, height: 38, cornerRadius: 9) {
                    drawing.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.90))
                }
                HUDInteractiveItemButton(tooltip: "Clear drawings (C)", isSelected: false, width: 34, height: 38, cornerRadius: 9) {
                    drawing.clear()
                } label: {
                    Image(systemName: "eraser")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.white.opacity(0.90))
                }
            }
        }
    }

    private func formatCompactElapsed(_ sec: TimeInterval) -> String {
        let total = Int(sec)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

/// Borderless Hover-Highlight Button for the Recording HUD Panel:
/// NO border/outline on hover, only a smooth rounded fill + standalone floating top tooltip window that never clips!).
private struct HUDInteractiveItemButton<LabelContent: View>: View {
    let tooltip: String?
    let isSelected: Bool
    let width: CGFloat?
    let height: CGFloat
    let cornerRadius: CGFloat
    let action: () -> Void
    let onActionWithScreenRect: ((NSRect) -> Void)?
    @ViewBuilder let label: () -> LabelContent

    @State private var magnetNSView: HoverMagnetTrackingNSView?

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
            SharedFloatingTooltipWindowController.shared.hideTooltip(ifOwnedBy: magnetNSView)
            if let onActionWithScreenRect {
                onActionWithScreenRect(currentScreenRect())
            } else {
                action()
            }
        } label: {
            label()
                .frame(width: width, height: height)
                .background(
                    HoverMagnetBackgroundRepresentable(
                        tooltip: tooltip ?? "",
                        shortcutBadge: nil,
                        edge: .top,
                        cornerRadius: min(cornerRadius, 8),
                        isActive: isSelected,
                        isDisabled: false,
                        isRailTab: false,
                        hasActiveBorder: false,
                        activeRGB: (0.95, 0.96, 1.0)
                    ) { v in
                        magnetNSView = v
                    }
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        // Buttons with a tooltip are icon-only, so the tooltip is their name; the others read their text.
        .accessibilityLabelIfAny(translated: tooltip.map { AccessibilityText.label(fromTooltip: $0) })
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func currentScreenRect() -> NSRect {
        guard let v = magnetNSView, let win = v.window else { return .zero }
        let rectInWin = v.convert(v.bounds, to: nil)
        return win.convertToScreen(rectInWin)
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
                        .fill(Color(red: 0.36, green: 0.22, blue: 0.98).opacity(0.24))
                        .overlay(
                            RoundedRectangle(cornerRadius: win.borderRadius, style: .continuous)
                                .strokeBorder(Color(red: 0.44, green: 0.30, blue: 1.0).opacity(0.95), lineWidth: 2.5)
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
                                    Button(preset.label.localizedUI) {
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
                            .background(Color(red: 0.36, green: 0.22, blue: 0.98), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                    .padding(22)
                    .background(HUDLiquidGlassBackgroundView(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                    )
                }
                .frame(width: localRect.width, height: localRect.height)
                .position(x: localRect.midX, y: localRect.midY)
            }

            // 2. DISPLAY MODE (Allows selecting any connected monitor!)
            else if coordinator.selectedMode == .display, coordinator.hoveredDisplayID == screenDisplayID {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(red: 0.44, green: 0.30, blue: 1.0), lineWidth: 4)
                        .background(Color(red: 0.36, green: 0.22, blue: 0.98).opacity(0.10))

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
                            .background(Color(red: 0.36, green: 0.22, blue: 0.98), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(24)
                    .background(HUDLiquidGlassBackgroundView(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
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
                        .background(Color(red: 0.36, green: 0.22, blue: 0.98).opacity(0.12))

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
                                .background(Color(red: 0.36, green: 0.22, blue: 0.98), in: Capsule())
                                .foregroundStyle(.white)
                                .contentShape(Capsule())
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

// MARK: - Pure AppKit Floating Live Camera Preview Bubble (`Show camera preview` in HUD)

private final class LiveCameraPreviewHostNSView: NSView {
    private let shadowContainerLayer = CALayer()
    private let clipLayer = CALayer()
    private let recordedFrameLayer = CALayer()
    private let borderLayer = CAShapeLayer()
    private let cornerRadius: CGFloat
    private let insetMargin: CGFloat = 14.0

    init(frame frameRect: NSRect, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        // 1. Outer shadow container layer (casts a smooth, rounded drop shadow with ZERO rectangular window border!)
        shadowContainerLayer.shadowColor = NSColor.black.cgColor
        shadowContainerLayer.shadowOpacity = 0.42
        shadowContainerLayer.shadowRadius = 10.0
        shadowContainerLayer.shadowOffset = CGSize(width: 0, height: -4)
        shadowContainerLayer.masksToBounds = false
        layer?.addSublayer(shadowContainerLayer)

        // 2. Inner squircle-clipped camera container
        clipLayer.backgroundColor = NSColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1.0).cgColor
        clipLayer.cornerRadius = cornerRadius
        clipLayer.cornerCurve = .continuous
        clipLayer.masksToBounds = true
        shadowContainerLayer.addSublayer(clipLayer)

        recordedFrameLayer.contentsGravity = .resizeAspectFill
        recordedFrameLayer.setAffineTransform(CGAffineTransform(scaleX: -1.0, y: 1.0))
        clipLayer.addSublayer(recordedFrameLayer)

        // 3. Subtle 1px inner border
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.18).cgColor
        borderLayer.lineWidth = 1.0
        shadowContainerLayer.addSublayer(borderLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let innerRect = bounds.insetBy(dx: insetMargin, dy: insetMargin)
        shadowContainerLayer.frame = innerRect
        let roundedPath = CGPath(
            roundedRect: CGRect(origin: .zero, size: innerRect.size),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        shadowContainerLayer.shadowPath = roundedPath
        clipLayer.frame = CGRect(origin: .zero, size: innerRect.size)
        recordedFrameLayer.frame = clipLayer.bounds
        borderLayer.frame = clipLayer.bounds
        borderLayer.path = roundedPath
        CATransaction.commit()
    }

    func displayCapturedSurface(_ ioSurface: IOSurfaceRef) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        recordedFrameLayer.contents = ioSurface
        CATransaction.commit()
    }
}

