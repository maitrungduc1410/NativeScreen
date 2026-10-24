import Foundation
import SwiftUI
import AppKit
import Observation
import ScreenCaptureKit

/// Coordinates the floating Recording HUD (`NSPanel`), the interactive Window/Area Picker overlays,
/// and the `ScreenCaptureEngine` + `TelemetryRecorder`.
@Observable
@MainActor
public final class RecordingCoordinator {
    public static let shared = RecordingCoordinator()

    public var isHUDVisible: Bool = false
    public var isRecording: Bool = false
    public var recordingElapsedSeconds: TimeInterval = 0.0
    public var selectedMode: CaptureTargetMode = .window
    public var captureMicrophone: Bool = false
    public var captureSystemAudio: Bool = true

    // Window & Area Picker State
    public var hoveredWindow: CapturableWindowInfo?
    public var selectedAreaRectQuartz: CGRect = CGRect(x: 240, y: 160, width: 1280, height: 720)
    public var lastErrorMessage: String?

    // Callback triggered on the main actor when a new `.nativescreen` project finishes recording
    public var onRecordingCompleted: ((ProjectSession) -> Void)?

    private var hudPanel: NSPanel?
    private var pickerOverlayWindow: NSWindow?
    private var hoverTimer: Timer?
    private var recordingTimer: Timer?
    private var recordingStartUptime: TimeInterval = 0

    private var captureEngine: ScreenCaptureEngine?
    private var telemetryRecorder: TelemetryRecorder?
    private var activePackageURL: URL?
    private var activeTargetMetadata: CaptureTargetMetadata?

    private init() {}

    // MARK: - Show / Hide Floating Recording HUD Bar (`NSPanel`)

    public func showRecordingHUD() {
        if hudPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 68),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true

            let hostingView = NSHostingView(rootView: RecordingHUDBarView(coordinator: self))
            panel.contentView = hostingView
            self.hudPanel = panel
        }

        if let screen = NSScreen.main, let panel = hudPanel {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 380
            let y = screenFrame.minY + 48
            panel.setFrame(NSRect(x: x, y: y, width: 760, height: 68), display: true)
            panel.orderFrontRegardless()
        }

        isHUDVisible = true
        updatePickerOverlayForSelectedMode()
    }

    public func hideRecordingHUD() {
        stopPickerOverlay()
        hudPanel?.orderOut(nil)
        isHUDVisible = false
    }

    public func selectMode(_ mode: CaptureTargetMode) {
        selectedMode = mode
        updatePickerOverlayForSelectedMode()
    }

    // MARK: - Interactive Window / Area Picker Overlay

    public func updatePickerOverlayForSelectedMode() {
        guard isHUDVisible, !isRecording else {
            stopPickerOverlay()
            return
        }

        switch selectedMode {
        case .window, .area:
            startPickerOverlay()
        case .display, .device:
            stopPickerOverlay()
        }
    }

    private func startPickerOverlay() {
        guard let screen = NSScreen.main else { return }

        if pickerOverlayWindow == nil {
            let overlay = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            overlay.isOpaque = false
            overlay.backgroundColor = .clear
            overlay.hasShadow = false
            overlay.level = .floating
            overlay.ignoresMouseEvents = false
            overlay.acceptsMouseMovedEvents = true
            overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            overlay.contentView = NSHostingView(rootView: WindowAndAreaPickerOverlayView(coordinator: self, screen: screen))
            self.pickerOverlayWindow = overlay
        }

        pickerOverlayWindow?.setFrame(screen.frame, display: true)
        pickerOverlayWindow?.orderFrontRegardless()
        hudPanel?.orderFrontRegardless()

        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.selectedMode == .window, !self.isRecording else { return }
                if let win = WindowDiscoveryService.topmostWindowUnderMouse() {
                    if self.hoveredWindow != win {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                            self.hoveredWindow = win
                        }
                    }
                }
            }
        }
    }

    private func stopPickerOverlay() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        pickerOverlayWindow?.orderOut(nil)
    }

    // MARK: - Start & Stop Real Recording

    public func startRecording() async {
        guard !isRecording else { return }
        lastErrorMessage = nil

        do {
            let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let primaryDisplay = shareable.displays.first else {
                lastErrorMessage = "No capturable display found."
                return
            }

            let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
            let filter: SCContentFilter
            let logicalBounds: CGRect
            let sourceRect: CGRect?
            var targetWindowId: UInt32?
            var targetBundleId: String?
            var targetAppName: String?
            var targetWindowTitle: String?

            // Exclude NativeScreen's own windows so HUD/Overlays never appear in the recording
            let myPID = ProcessInfo.processInfo.processIdentifier
            let ownWindows = shareable.windows.filter { $0.owningApplication?.processID == myPID }

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
                } else {
                    filter = SCContentFilter(display: primaryDisplay, excludingWindows: ownWindows)
                    logicalBounds = CGRect(x: 0, y: 0, width: primaryDisplay.width, height: primaryDisplay.height)
                    sourceRect = nil
                }

            case .area:
                filter = SCContentFilter(display: primaryDisplay, excludingWindows: ownWindows)
                logicalBounds = selectedAreaRectQuartz
                sourceRect = selectedAreaRectQuartz

            case .display, .device:
                filter = SCContentFilter(display: primaryDisplay, excludingWindows: ownWindows)
                logicalBounds = CGRect(x: 0, y: 0, width: primaryDisplay.width, height: primaryDisplay.height)
                sourceRect = nil
            }

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
                displayId: primaryDisplay.displayID,
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

        // Load telemetry to generate initial Auto-Zoom blocks automatically!
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
                    MaskTrack(id: "mask-track-1", name: "Blur Track 1")
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

    // MARK: - Create Instant Interactive Demo Project (For Testing Editor Without Screen Recording Permission)

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

        // Generate smooth figure-8 cursor path + sample clicks
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
            (3100.0, 0.74, 0.36),
            (8400.0, 0.28, 0.66),
            (13200.0, 0.64, 0.42)
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
                    MaskTrack(id: "mask-track-1", name: "Blur Track 1 (API Key)", items: [mask1]),
                    MaskTrack(id: "mask-track-2", name: "Blur Track 2 (Personal Info)", items: [mask2])
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

// MARK: - Floating Recording HUD Bar View (`NSPanel` Content)

public struct RecordingHUDBarView: View {
    @Bindable var coordinator: RecordingCoordinator

    public var body: some View {
        HStack(spacing: 14) {
            // Close button
            Button {
                if coordinator.isRecording {
                    Task { await coordinator.stopRecordingAndOpenEditor() }
                } else {
                    coordinator.hideRecordingHUD()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)

            Divider()
                .frame(height: 28)

            if !coordinator.isRecording {
                // Capture Target Mode Buttons (Display, Window, Area, Device)
                HStack(spacing: 6) {
                    ForEach(CaptureTargetMode.allCases) { mode in
                        Button {
                            coordinator.selectMode(mode)
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: mode.systemImage)
                                    .font(.system(size: 16, weight: .medium))
                                Text(mode.title)
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(coordinator.selectedMode == mode ? .white : .secondary)
                            .frame(width: 56, height: 46)
                            .background(
                                coordinator.selectedMode == mode
                                    ? Color.accentColor.opacity(0.35)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()
                    .frame(height: 28)

                // Microphone & System Audio Toggles
                HStack(spacing: 10) {
                    Button {
                        coordinator.captureMicrophone.toggle()
                    } label: {
                        Label(
                            coordinator.captureMicrophone ? "Mic On" : "No mic",
                            systemImage: coordinator.captureMicrophone ? "mic.fill" : "mic.slash"
                        )
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(coordinator.captureMicrophone ? .white : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        coordinator.captureSystemAudio.toggle()
                    } label: {
                        Label(
                            coordinator.captureSystemAudio ? "System Audio" : "Muted",
                            systemImage: coordinator.captureSystemAudio ? "speaker.wave.2.fill" : "speaker.slash"
                        )
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(coordinator.captureSystemAudio ? .white : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Divider()
                    .frame(height: 28)

                // Record Button
                Button {
                    Task { await coordinator.startRecording() }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.red)
                            .frame(width: 10, height: 10)
                        Text("Record")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            } else {
                // Active Recording Status & Stop Button
                HStack(spacing: 12) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                    Text(formatElapsed(coordinator.recordingElapsedSeconds))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                    Button {
                        Task { await coordinator.stopRecordingAndOpenEditor() }
                    } label: {
                        Label("Stop Recording", systemImage: "stop.fill")
                            .font(.system(size: 13, weight: .semibold))
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
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        )
    }

    private func formatElapsed(_ sec: TimeInterval) -> String {
        let total = Int(sec)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Smart Window Picker & Area Selection Overlay View

public struct WindowAndAreaPickerOverlayView: View {
    @Bindable var coordinator: RecordingCoordinator
    let screen: NSScreen

    public var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            if coordinator.selectedMode == .window, let win = coordinator.hoveredWindow {
                let rect = win.bounds
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

                        HStack(spacing: 6) {
                            Text("\(Int(rect.width)) × \(Int(rect.height))")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.85))

                            Menu("Resize") {
                                ForEach(WindowSizePreset.presets) { preset in
                                    Button(preset.label) {
                                        WindowDiscoveryService.resizeWindow(
                                            win,
                                            toWidth: Double(preset.width),
                                            height: Double(preset.height)
                                        )
                                    }
                                }
                            }
                            .menuStyle(.borderlessButton)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
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
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            } else if coordinator.selectedMode == .area {
                let rect = coordinator.selectedAreaRectQuartz
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                        .foregroundStyle(.white)
                        .background(Color.indigo.opacity(0.12))

                    VStack(spacing: 10) {
                        Text("Recording Area: \(Int(rect.width)) × \(Int(rect.height))")
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
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            coordinator.selectedAreaRectQuartz.origin = CGPoint(
                                x: max(0, value.location.x - rect.width * 0.5),
                                y: max(0, value.location.y - rect.height * 0.5)
                            )
                        }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
