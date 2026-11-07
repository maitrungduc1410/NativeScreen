import Foundation
import SwiftUI
import Observation
import AppKit
import AVFoundation
import CoreImage
import UniformTypeIdentifiers

/// Per-window isolated NLE Project Session with Value-Type Snapshot Undo/Redo (`⌘Z` / `⇧⌘Z`)
/// and `.nativescreen` package persistence.
@Observable
@MainActor
public final class ProjectSession: Identifiable {
    public let id: UUID = UUID()
    public var packageURL: URL
    public var document: ProjectDocument
    public var metadata: RecordingMetadata
    public var cursorEvents: [CursorSampleEvent]
    public var clickEvents: [ClickEvent]
    public var keyEvents: [KeyStrokeEvent]

    // Playback, Hover Skimming, Tool Mode & Selection State
    public var playheadTimelineMs: Double = 0.0 {
        didSet { refreshPreviewTimeDerivedState() }
    }
    public var hoverSkimTimelineMs: Double? = nil {
        didSet { refreshPreviewTimeDerivedState() }
    }
    public var isPlaying: Bool = false {
        didSet { refreshPreviewTimeDerivedState() }
    }

    // Coarse, change-only mirrors of "what is under the preview time" for SwiftUI views.
    // `playheadTimelineMs` changes 120 times a second during playback; views that read it directly re-evaluate every
    // frame. Reading these instead only invalidates a view when the spoken word / active mask actually changes.
    public private(set) var spokenTranscriptSegmentIds: Set<String> = []
    public private(set) var activeMaskIdAtPreviewTime: String? = nil
    public private(set) var isCursorHiddenAtPreviewTime: Bool = false
    public var previewPlaybackRate: Double = 1.0
    public var isSplitModeActive: Bool = false
    public var timelineZoom: Double = 1.0
    public var isReelModeActive: Bool = false
    public var reelPlatformStyle: ReelPlatformStyle = .tiktok
    public var isShowingStillFrameExportModal: Bool = false
    public var isShowingCameraCropModal: Bool = false
    public var isGeneratingTranscript: Bool = false
    public var transcriptErrorMessage: String?
    public var isScanningSensitiveData: Bool = false
    public var isScanningFaces: Bool = false
    public var isRecordingVoiceover: Bool = false
    public var voiceoverRecordingStartSourceMs: Double = 0.0
    public var voiceoverRecordingTrackIndex: Int = 0
    @ObservationIgnored private var activeVoiceoverRecorder: AVAudioRecorder?
    @ObservationIgnored private var activeVoiceoverRelativePath: String?
    public var selectedSliceId: String?
    public var selectedZoomId: String?
    public var selectedCameraLayoutId: String?
    public var selectedMaskId: String?
    public var selectedVoiceoverId: String?
    public var selectedCaptionId: String?
    public var selectedShortcutId: String? {
        didSet {
            // The preview draws the selected keycaps highlighted.
            if selectedShortcutId != oldValue && !isPlaying {
                renderRevision &+= 1
            }
        }
    }
    /// Keycap group under the mouse in the preview (drawn brighter by the compositor).
    public var hoveredShortcutId: String? {
        didSet {
            if hoveredShortcutId != oldValue && !isPlaying {
                renderRevision &+= 1
            }
        }
    }
    /// Keycap hit areas from the last preview frame, normalized with a top-left origin. Updated only when they change.
    public var previewShortcutHitRects01: [String: CGRect] = [:]
    public var previewCaptionHitRects01: [String: CGRect] = [:]
    public var pendingAddMaskType: MaskType? = nil
    public var pendingAddMaskStyle: MaskStyle = .gaussian
    public var isDraggingTimelineSegment: Bool = false
    /// Frozen timeline duration while resizing a segment so the ruler never jumps or rescales mid-drag!
    public var frozenPlaybackDurationMs: Double? = nil

    // Bottom-Center Toast Notification State
    public var activeToastMessage: String? = nil
    @ObservationIgnored private var toastDismissTask: Task<Void, Never>?

    /// Actions that need the editor window's own UI state (export modal, command menu, alerts), requested by the
    /// app menu or by the recorder (`After Recording`). `ProjectEditorWindowView` performs it and clears it.
    public enum EditorCommand: Equatable {
        case showExportSheet
        case quickExport(HardwareVideoExporter.ExportTarget)
        case showCommandMenu
        case removeProject
    }
    public var pendingEditorCommand: EditorCommand? = nil

    public var scrollToTrackTargetId: String? = nil
    public var scrollToTrackRevision: Int = 0
    public var selectedInspectorTab: InspectorTab = .background

    // Audio Waveform Envelope Samples (`0.0 ... 1.0`, ~240 buckets/sec across `metadata.durationMs`)
    // - `audioWaveformSamples`: System / App Audio waveform (Purple `#4D2FF5` in Timeline Clip)
    // - `microphoneWaveformSamples`: Recorded Microphone waveform (Translucent White in Timeline Clip)
    // - `voiceoverWaveformSamplesByID`: Per-VoiceoverSegment audio waveform samples (Translucent White in Voiceover segment)
    public var audioWaveformSamples: [Float] = []
    public var microphoneWaveformSamples: [Float] = []
    public var voiceoverWaveformSamplesByID: [String: [Float]] = [:]

    // Clipboard for Zoom / Mask Copy & Cut (`⌘C` / `⌘X`)
    public var copiedZoomBlock: ZoomBlock?
    public var copiedMaskItem: MaskItem?
    public var copiedCameraLayoutSegment: CameraLayoutSegment?

    // Cached NLE Mapper & 120Hz Spring Trajectory Solver
    public private(set) var timeMapper: NLETimeMapper
    @ObservationIgnored public private(set) var trajectorySolver: SpringTrajectorySolver

    @ObservationIgnored private var lastMappedSlices: [ClipSlice]
    @ObservationIgnored private var lastSolverCursorConfig: CursorConfig
    @ObservationIgnored private var lastSolverMotionConfig: MotionConfig
    @ObservationIgnored private var lastSolverZooms: [ZoomBlock]
    @ObservationIgnored private var lastSolverZoomTrackHidden: Bool

    @ObservationIgnored private var cachedTypingSuggestions: [TypingSuggestionRange]?
    @ObservationIgnored private var lastTypingSuggestionsSlices: [ClipSlice]?
    @ObservationIgnored private var lastDismissedTypingStarts: [Int]?

    @ObservationIgnored private var cachedDetectedShortcuts: [ShortcutPressCluster]?
    @ObservationIgnored private var lastShortcutCaptionsConfig: CaptionsConfig?
    @ObservationIgnored private var lastShortcutSlices: [ClipSlice]?

    // Value-Type Snapshot Undo/Redo Stack
    private var undoStack: [ProjectDocument] = []
    private var redoStack: [ProjectDocument] = []
    @ObservationIgnored private var interactiveEditSnapshot: ProjectDocument?
    private let maxUndoDepth = 150
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    // Incrementing token used to notify the Metal preview view (`MTKView.needsDisplay = true`) on any state/scrub/skim change
    public var renderRevision: UInt64 = 0

    public enum InspectorTab: String, CaseIterable, Identifiable {
        case background = "Background"
        case cursor = "Cursor"
        case cameraLayout = "Camera Layout"
        case cameraStyle = "Camera Style"
        case captions = "Captions"
        case transcript = "Edit by transcript"
        case audio = "Audio"
        case shortcuts = "Shortcuts"
        case zoom = "Zoom"
        case deviceFrame = "Device Frame"
        case masks = "Masks"

        public var id: String { rawValue }

        public var tooltipTitle: String {
            switch self {
            case .background: return String(localized: "General")
            case .cursor: return String(localized: "Cursor")
            case .cameraLayout: return String(localized: "Camera Layout")
            case .cameraStyle: return String(localized: "Camera Style")
            case .captions: return String(localized: "Captions")
            case .transcript: return String(localized: "Edit by transcript")
            case .audio: return String(localized: "Audio")
            case .shortcuts: return String(localized: "Keyboard Shortcuts")
            case .zoom: return String(localized: "Animations")
            case .deviceFrame: return String(localized: "Device Frame")
            case .masks: return String(localized: "Masks")
            }
        }

        public var shortcutBadge: String? {
            switch self {
            case .background: return "⌘ 1"
            case .cursor: return "⌘ 2"
            case .cameraLayout: return "⌘ 3"
            case .cameraStyle: return "⌘ 4"
            case .captions: return "⌘ 5"
            case .transcript: return "⌘ 6"
            case .audio: return "⌘ 7"
            case .shortcuts: return "⌘ 8"
            case .zoom: return "⌘ 9"
            case .deviceFrame: return "⌘ 0"
            case .masks: return nil
            }
        }

        public var systemImage: String {
            switch self {
            case .background: return "inset.filled.square.dashed"
            case .cursor: return "cursorarrow"
            case .cameraLayout: return "inset.filled.rectangle.and.person.filled"
            case .cameraStyle: return "person.fill.viewfinder"
            case .captions: return "captions.bubble"
            case .transcript: return "text.quote"
            case .audio: return "speaker.wave.1"
            case .shortcuts: return "command"
            case .zoom: return "point.topleft.down.to.point.bottomright.curvepath.fill"
            case .deviceFrame: return "laptopcomputer.and.iphone"
            case .masks: return "circle.filled.pattern.diagonalline.rectangle"
            }
        }
    }

    public init(
        packageURL: URL,
        document: ProjectDocument,
        metadata: RecordingMetadata,
        cursorEvents: [CursorSampleEvent] = [],
        clickEvents: [ClickEvent] = [],
        keyEvents: [KeyStrokeEvent] = []
    ) {
        var cleanedDoc = document
        cleanedDoc.timeline.maskTracks.removeAll { $0.items.isEmpty }

        self.packageURL = packageURL
        self.document = cleanedDoc
        self.metadata = metadata
        self.cursorEvents = cursorEvents
        self.clickEvents = clickEvents
        self.keyEvents = keyEvents
        self.timeMapper = NLETimeMapper(slices: cleanedDoc.timeline.slices)
        self.lastMappedSlices = cleanedDoc.timeline.slices
        self.lastSolverCursorConfig = cleanedDoc.cursor
        self.lastSolverMotionConfig = cleanedDoc.motion
        self.lastSolverZooms = cleanedDoc.timeline.zooms
        self.lastSolverZoomTrackHidden = cleanedDoc.timeline.isZoomTrackHidden
        self.trajectorySolver = SpringTrajectorySolver(
            durationMs: metadata.durationMs,
            cursorEvents: cursorEvents,
            clickEvents: clickEvents,
            document: cleanedDoc
        )
        self.selectedSliceId = nil
        let realDisplayVideoExists = FileManager.default.fileExists(
            atPath: packageURL.appendingPathComponent("recording").appendingPathComponent(metadata.tracks.displayVideo).path
        )
        self.audioWaveformSamples = realDisplayVideoExists
            ? []
            : Self.generateProceduralWaveform(durationMs: metadata.durationMs)
        self.microphoneWaveformSamples = []

        self.document.captions.migrateTranscriptToCaptionTracksIfNeeded()
        self.document.captions.removeEmptyCaptionTracks()

        // Synchronize `shortcutTracks` with actual shortcuts so projects without shortcuts never show an empty default Shortcuts track!
        let initialShortcutClusters = self.detectedShortcutClusters
        if !initialShortcutClusters.isEmpty && self.document.captions.shortcutTracks.isEmpty {
            self.document.captions.shortcutTracks = [
                ShortcutTrackConfig(
                    id: "default-shortcuts-track",
                    name: "Shortcuts",
                    isHidden: false,
                    style: self.document.captions.defaultShortcutStyle
                )
            ]
        } else if initialShortcutClusters.isEmpty && self.document.captions.customShortcuts.isEmpty {
            self.document.captions.shortcutTracks.removeAll()
        }

        refreshPreviewTimeDerivedState()

        Task { [weak self] in
            await self?.loadRealAudioWaveformIfAvailable()
        }
    }

    // MARK: - Load & Save `.nativescreen` Bundle

    public static func load(from packageURL: URL) throws -> ProjectSession {
        let projectJSONURL = packageURL.appendingPathComponent("project.json")
        let recordingDir = packageURL.appendingPathComponent("recording", isDirectory: true)
        let metadataJSONURL = recordingDir.appendingPathComponent("metadata.json")

        let decoder = JSONDecoder()
        let docData = try Data(contentsOf: projectJSONURL)
        var document = try decoder.decode(ProjectDocument.self, from: docData)

        let metadata: RecordingMetadata
        if let metaData = try? Data(contentsOf: metadataJSONURL),
           let decodedMeta = try? decoder.decode(RecordingMetadata.self, from: metaData) {
            metadata = decodedMeta
        } else {
            let fallbackDuration = document.timeline.slices.map(\.sourceEndMs).max() ?? 10000.0
            metadata = RecordingMetadata(
                durationMs: fallbackDuration,
                captureTarget: CaptureTargetMetadata(
                    mode: .display,
                    displayId: 0,
                    logicalBounds: LogicalBounds(x: 0, y: 0, width: 1920, height: 1080),
                    pixelSize: PixelDimensions(width: 1920, height: 1080)
                )
            )
        }

        document.timeline.zooms = AutoZoomClusterGenerator.normalizeNonOverlappingZooms(
            document.timeline.zooms,
            durationMs: metadata.durationMs
        )
        document.timeline.maskTracks.removeAll { $0.items.isEmpty }
        document.timeline.normalizeVoiceoverTracks()

        let cursorURL = recordingDir.appendingPathComponent(metadata.tracks.cursorTelemetry)
        let clicksURL = recordingDir.appendingPathComponent(metadata.tracks.clicksTelemetry)
        let keysURL = recordingDir.appendingPathComponent(metadata.tracks.keysTelemetry)

        let cursorEvents = JSONLinesCodec.load(CursorSampleEvent.self, from: cursorURL)
        let clickEvents = JSONLinesCodec.load(ClickEvent.self, from: clicksURL)
        let keyEvents = JSONLinesCodec.load(KeyStrokeEvent.self, from: keysURL)

        return ProjectSession(
            packageURL: packageURL,
            document: document,
            metadata: metadata,
            cursorEvents: cursorEvents,
            clickEvents: clickEvents,
            keyEvents: keyEvents
        )
    }

    public func saveNow() throws {
        hasUnsavedChanges = false
        var updatedDoc = document
        updatedDoc.updatedAt = ISO8601DateFormatter().string(from: Date())

        let fm = FileManager.default
        try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let assetsDir = packageURL.appendingPathComponent("assets", isDirectory: true)
        try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let projectData = try encoder.encode(updatedDoc)
        let projectJSONURL = packageURL.appendingPathComponent("project.json")
        try projectData.write(to: projectJSONURL, options: .atomic)
    }

    public func saveProjectWithToast() {
        try? saveNow()
        showToast("Project saved", durationMs: 2000)
    }

    public func showToast(_ message: String, durationMs: Int = 2000) {
        toastDismissTask?.cancel()
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            activeToastMessage = message
        }
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(durationMs))
            guard !Task.isCancelled, let self = self else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                self.activeToastMessage = nil
            }
        }
    }

    /// Edits made while autosave is off and not yet saved.
    public private(set) var hasUnsavedChanges = false

    /// Reloads the project from disk, dropping edits that were never saved (autosave off, `Don’t Save`).
    public func discardUnsavedChanges() {
        hasUnsavedChanges = false
        saveTask?.cancel()
        let projectURL = packageURL.appendingPathComponent("project.json")
        if let data = try? Data(contentsOf: projectURL),
           let saved = try? JSONDecoder().decode(ProjectDocument.self, from: data) {
            document = saved
            rebuildDerivedState(forceSpringRebuild: true)
        }
    }

    private func scheduleAutoSave() {
        guard AppSettings.shared.autosaveEnabled else {
            hasUnsavedChanges = true
            return
        }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self = self else { return }
            try? self.saveNow()
        }
    }

    // MARK: - Value-Type Snapshot Undo / Redo (`⌘Z` / `⇧⌘Z`)

    public func beginInteractiveEdit() {
        isDraggingTimelineSegment = true
        if frozenPlaybackDurationMs == nil {
            frozenPlaybackDurationMs = max(1000.0, timeMapper.totalTimelineDurationMs)
        }
        if interactiveEditSnapshot == nil {
            interactiveEditSnapshot = document
        }
    }

    public func endInteractiveEdit() {
        isDraggingTimelineSegment = false
        frozenPlaybackDurationMs = nil
        if let snapshot = interactiveEditSnapshot {
            interactiveEditSnapshot = nil
            if snapshot != document {
                pushUndoSnapshot(snapshot)
            }
            rebuildDerivedState()
            scheduleAutoSave()
        }
    }

    public func mutate(_ mutation: (inout ProjectDocument) -> Void) {
        let before = interactiveEditSnapshot ?? document
        var next = document
        mutation(&next)
        if next.timeline.maskTracks != document.timeline.maskTracks {
            next.timeline.maskTracks.removeAll { $0.items.isEmpty }
            for idx in next.timeline.maskTracks.indices {
                next.timeline.maskTracks[idx].name = idx == 0 ? "Masks" : "Masks \(idx + 1)"
            }
        }
        if next.captions.captionTracks != document.captions.captionTracks || next.captions.captionBlocks != document.captions.captionBlocks {
            next.captions.removeEmptyCaptionTracks()
            if next.captions.captionTracks.isEmpty, !document.captions.captionTracks.isEmpty {
                // Words without tracks read as a project saved before tracks existed: the next load would bring the deleted captions back.
                next.captions.segments = []
            }
        }

        guard next != document else { return }
        if interactiveEditSnapshot == nil {
            pushUndoSnapshot(before)
        }
        document = next
        rebuildDerivedState()
        if interactiveEditSnapshot == nil {
            scheduleAutoSave()
        }
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Projects created from an imported video have no cursor telemetry: zooms must be positioned by hand.
    public var hasRecordedCursor: Bool { !cursorEvents.isEmpty }

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        document = previous
        rebuildDerivedState(forceSpringRebuild: true)
        scheduleAutoSave()
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
        rebuildDerivedState(forceSpringRebuild: true)
        scheduleAutoSave()
    }

    private func pushUndoSnapshot(_ snapshot: ProjectDocument) {
        undoStack.append(snapshot)
        if undoStack.count > maxUndoDepth {
            undoStack.removeFirst(undoStack.count - maxUndoDepth)
        }
        redoStack.removeAll()
    }

    private func rebuildDerivedState(forceSpringRebuild: Bool = false) {
        if forceSpringRebuild || document.timeline.slices != lastMappedSlices {
            lastMappedSlices = document.timeline.slices
            timeMapper = NLETimeMapper(slices: document.timeline.slices)
        }

        // Size, cursor set and click effect are applied at draw time only, so changing them (e.g. dragging the
        // Cursor size slider) must not re-solve the whole 120Hz trajectory.
        var trajectoryCursorConfig = document.cursor
        trajectoryCursorConfig.scale = lastSolverCursorConfig.scale
        trajectoryCursorConfig.themeId = lastSolverCursorConfig.themeId
        trajectoryCursorConfig.variantId = lastSolverCursorConfig.variantId
        trajectoryCursorConfig.clickEffect = lastSolverCursorConfig.clickEffect
        let cursorChanged = forceSpringRebuild || trajectoryCursorConfig != lastSolverCursorConfig
        let needsSpringRebuild = cursorChanged
            || document.motion != lastSolverMotionConfig
            || document.timeline.zooms != lastSolverZooms
            || document.timeline.isZoomTrackHidden != lastSolverZoomTrackHidden

        if needsSpringRebuild {
            let reusableCursorStates = cursorChanged ? nil : trajectorySolver.cursorStates
            lastSolverCursorConfig = document.cursor
            lastSolverMotionConfig = document.motion
            lastSolverZooms = document.timeline.zooms
            lastSolverZoomTrackHidden = document.timeline.isZoomTrackHidden
            trajectorySolver = SpringTrajectorySolver(
                durationMs: metadata.durationMs,
                cursorEvents: cursorEvents,
                clickEvents: clickEvents,
                document: document,
                reusingCursorStates: reusableCursorStates
            )
        }

        if playheadTimelineMs > timeMapper.totalTimelineDurationMs {
            playheadTimelineMs = timeMapper.totalTimelineDurationMs
        }
        refreshPreviewTimeDerivedState()
        renderRevision &+= 1
    }

    @ObservationIgnored private var sortedTranscriptSegmentsSource: [CaptionSegment] = []
    @ObservationIgnored private var sortedTranscriptSegments: [CaptionSegment] = []

    /// Caption words sorted by start time, re-sorted only when the transcript changes (`Array ==` is O(1) on shared storage).
    private func sortedCaptionSegments() -> [CaptionSegment] {
        let segments = document.captions.segments
        if segments != sortedTranscriptSegmentsSource {
            sortedTranscriptSegmentsSource = segments
            sortedTranscriptSegments = segments.sorted { $0.sourceStartMs < $1.sourceStartMs }
        }
        return sortedTranscriptSegments
    }

    private func refreshPreviewTimeDerivedState() {
        let sourceMs = currentSourceTimeMs

        let cursorHidden = currentActiveSlice?.hideCursor == true
        if cursorHidden != isCursorHiddenAtPreviewTime {
            isCursorHiddenAtPreviewTime = cursorHidden
        }

        let maskId = activeMasks(atSourceMs: sourceMs).first?.id
        if maskId != activeMaskIdAtPreviewTime {
            activeMaskIdAtPreviewTime = maskId
        }

        let sortedTranscriptSegments = sortedCaptionSegments()
        // Binary search the first word starting after `sourceMs`, then walk back over words still inside their +80ms tail.
        var lo = 0
        var hi = sortedTranscriptSegments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedTranscriptSegments[mid].sourceStartMs <= sourceMs {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        var spoken: Set<String> = []
        var idx = lo - 1
        while idx >= 0, idx >= lo - 32 {
            let seg = sortedTranscriptSegments[idx]
            if sourceMs <= seg.sourceEndMs + 80.0 {
                spoken.insert(seg.id)
            }
            idx -= 1
        }
        if spoken != spokenTranscriptSegmentIds {
            spokenTranscriptSegmentIds = spoken
        }
    }

    // MARK: - Current Playhead & Live Hover Skimming Helpers

    /// When hovering over the timeline while paused, the preview renders at `hoverSkimTimelineMs` in real time!
    public var effectivePreviewTimelineMs: Double {
        if !isPlaying, let hoverMs = hoverSkimTimelineMs {
            return max(0.0, min(timeMapper.totalTimelineDurationMs, hoverMs))
        }
        return playheadTimelineMs
    }

    public var currentSourceTimeMs: Double {
        timeMapper.sourceTime(forTimelineMs: effectivePreviewTimelineMs).sourceMs
    }

    public var committedSourceTimeMs: Double {
        timeMapper.sourceTime(forTimelineMs: playheadTimelineMs).sourceMs
    }

    public var currentActiveSlice: ClipSlice? {
        timeMapper.sourceTime(forTimelineMs: effectivePreviewTimelineMs).slice
    }

    public func seek(toTimelineMs timelineMs: Double) {
        let clamped = max(0.0, min(timeMapper.totalTimelineDurationMs, timelineMs))
        if abs(clamped - playheadTimelineMs) > 0.01 {
            playheadTimelineMs = clamped
            renderRevision &+= 1
        }
    }

    public func setHoverSkimTimelineMs(_ timelineMs: Double?) {
        let next = timelineMs.map { max(0.0, min(timeMapper.totalTimelineDurationMs, $0)) }
        if next != hoverSkimTimelineMs {
            hoverSkimTimelineMs = next
            if !isPlaying {
                renderRevision &+= 1
            }
        }
    }

    // MARK: - Selection & Deletion (`Delete` / `Backspace` / Context Menu)

    public func scrollToTimelineTrack(_ trackTargetId: String) {
        scrollToTrackTargetId = trackTargetId
        scrollToTrackRevision &+= 1
    }

    public func beginInteractiveMaskSelection(type: MaskType, style: MaskStyle? = nil) {
        isPlaying = false
        hoverSkimTimelineMs = nil
        isSplitModeActive = false
        let resolvedStyle: MaskStyle = style ?? (type == .blur ? .gaussian : .dim)
        if pendingAddMaskType == type && pendingAddMaskStyle == resolvedStyle {
            pendingAddMaskType = nil
            NSCursor.arrow.set()
        } else {
            pendingAddMaskType = type
            pendingAddMaskStyle = resolvedStyle
            selectedZoomId = nil
            selectedShortcutId = nil
            selectedInspectorTab = .masks
        }
        renderRevision &+= 1
    }

    public func cancelInteractiveMaskSelection() {
        guard pendingAddMaskType != nil else { return }
        pendingAddMaskType = nil
        NSCursor.arrow.set()
        renderRevision &+= 1
    }

    public func completeInteractiveMaskSelection(rect01: Rect01) {
        let type = pendingAddMaskType ?? .blur
        let style = pendingAddMaskStyle
        pendingAddMaskType = nil
        NSCursor.arrow.set()

        let srcMs = committedSourceTimeMs
        let maxDur = metadata.durationMs
        let endMs = min(maxDur, srcMs + 4500.0)
        let startMs = max(0.0, min(srcMs, endMs - 1200.0))
        let clampedRect = rect01.clamped()

        let item = MaskItem(
            sourceStartMs: startMs,
            sourceEndMs: endMs,
            type: type,
            style: style,
            intensity: type == .spotlight ? 50.0 : 36.0,
            cornerRadius: 12.0,
            keyframes: [MaskKeyframe(sourceMs: startMs, rect01: clampedRect)]
        )

        var targetTrackId = ""
        mutate { doc in
            if let freeTrackIndex = doc.timeline.maskTracks.firstIndex(where: { track in
                !track.items.contains(where: { !(endMs <= $0.sourceStartMs + 30.0 || startMs >= $0.sourceEndMs - 30.0) })
            }) {
                doc.timeline.maskTracks[freeTrackIndex].isHidden = false
                doc.timeline.maskTracks[freeTrackIndex].items.append(item)
                doc.timeline.maskTracks[freeTrackIndex].items.sort { $0.sourceStartMs < $1.sourceStartMs }
                targetTrackId = doc.timeline.maskTracks[freeTrackIndex].id
            } else {
                let newTrackNumber = doc.timeline.maskTracks.count + 1
                let newTrack = MaskTrack(
                    name: newTrackNumber == 1 ? "Masks" : "Masks \(newTrackNumber)",
                    isHidden: false,
                    items: [item]
                )
                doc.timeline.maskTracks.append(newTrack)
                targetTrackId = newTrack.id
            }
        }
        selectMask(item.id)
        if !targetTrackId.isEmpty {
            scrollToTimelineTrack("track_mask_\(targetTrackId)")
        }
    }

    public func selectCaption(_ id: String?) {
        clearTimelineSelection()
        selectedCaptionId = id
        if id != nil {
            selectedInspectorTab = .captions
        }
    }

    public func selectSlice(_ id: String?) {
        selectedCaptionId = nil
        selectedSliceId = id
        selectedZoomId = nil
        selectedCameraLayoutId = nil
        selectedMaskId = nil
        selectedVoiceoverId = nil
        selectedShortcutId = nil
        pendingAddMaskType = nil
        renderRevision &+= 1
    }

    public func selectZoom(_ id: String?) {
        selectedCaptionId = nil
        selectedZoomId = id
        selectedSliceId = nil
        selectedCameraLayoutId = nil
        selectedMaskId = nil
        selectedVoiceoverId = nil
        selectedShortcutId = nil
        pendingAddMaskType = nil
        if id != nil {
            selectedInspectorTab = .zoom
        }
        renderRevision &+= 1
    }

    public func selectCameraLayout(_ id: String?) {
        selectedCaptionId = nil
        selectedCameraLayoutId = id
        selectedSliceId = nil
        selectedZoomId = nil
        selectedMaskId = nil
        selectedVoiceoverId = nil
        selectedShortcutId = nil
        pendingAddMaskType = nil
        if id != nil {
            selectedInspectorTab = .cameraLayout
        }
        renderRevision &+= 1
    }

    public func selectMask(_ id: String?) {
        selectedCaptionId = nil
        selectedMaskId = id
        selectedSliceId = nil
        selectedZoomId = nil
        selectedCameraLayoutId = nil
        selectedVoiceoverId = nil
        selectedShortcutId = nil
        if id != nil {
            selectedInspectorTab = .masks
        }
        renderRevision &+= 1
    }

    public func selectVoiceover(_ id: String?) {
        selectedCaptionId = nil
        selectedVoiceoverId = id
        selectedSliceId = nil
        selectedZoomId = nil
        selectedCameraLayoutId = nil
        selectedMaskId = nil
        selectedShortcutId = nil
        pendingAddMaskType = nil
        if id != nil {
            selectedInspectorTab = .audio
        }
        renderRevision &+= 1
    }

    public func selectShortcut(_ id: String?) {
        selectedCaptionId = nil
        selectedShortcutId = id
        selectedSliceId = nil
        selectedZoomId = nil
        selectedCameraLayoutId = nil
        selectedMaskId = nil
        selectedVoiceoverId = nil
        pendingAddMaskType = nil
        if id != nil {
            selectedInspectorTab = .shortcuts
        }
        renderRevision &+= 1
    }

    public func clearTimelineSelection() {
        selectedCaptionId = nil
        selectedSliceId = nil
        selectedZoomId = nil
        selectedCameraLayoutId = nil
        selectedMaskId = nil
        selectedVoiceoverId = nil
        selectedShortcutId = nil
        pendingAddMaskType = nil
        renderRevision &+= 1
    }

    public func deleteSelectedTimelineItem() {
        if let captionId = selectedCaptionId {
            deleteCaption(id: captionId)
            return
        }
        if let shortcutId = selectedShortcutId,
           let cluster = detectedShortcutClusters.first(where: { $0.id == shortcutId }) {
            deleteShortcut(cluster)
            return
        }
        if let voId = selectedVoiceoverId {
            deleteVoiceover(id: voId)
            return
        }
        if let layoutId = selectedCameraLayoutId {
            deleteCameraLayout(id: layoutId)
            return
        }
        if let maskId = selectedMaskId {
            deleteMask(maskId: maskId)
            return
        }
        if let zoomId = selectedZoomId {
            deleteZoom(zoomId: zoomId)
            return
        }
        if selectedSliceId != nil {
            deleteSelectedSlice()
        }
    }

    // MARK: - Universal Split Tool Actions (Works on Clip Slices, Zoom Blocks, AND Blur/Spotlight Masks!)

    public func splitSlice(id: String, atTimelineMs timelineMs: Double) {
        guard let index = timeMapper.mappedSlices.firstIndex(where: { $0.slice.id == id }) else { return }
        let mapped = timeMapper.mappedSlices[index]
        guard timelineMs > mapped.timelineStartMs + 100.0 && timelineMs < mapped.timelineEndMs - 100.0 else {
            showToast("The part you want to cut is too short", durationMs: 2000)
            return
        }

        let offsetTimeline = timelineMs - mapped.timelineStartMs
        let splitSourceMs = mapped.slice.sourceStartMs + offsetTimeline * mapped.slice.speed

        mutate { doc in
            let original = doc.timeline.slices[index]
            var firstHalf = original
            firstHalf.id = UUID().uuidString
            firstHalf.sourceEndMs = splitSourceMs

            var secondHalf = original
            secondHalf.id = UUID().uuidString
            secondHalf.sourceStartMs = splitSourceMs

            doc.timeline.slices.replaceSubrange(index...index, with: [firstHalf, secondHalf])
            selectedSliceId = secondHalf.id
        }
        seek(toTimelineMs: timelineMs)
    }

    public func splitSliceAtPlayhead() {
        let currentTimeline = playheadTimelineMs
        if let hit = timeMapper.mappedSlices.first(where: {
            currentTimeline > $0.timelineStartMs + 100.0 && currentTimeline < $0.timelineEndMs - 100.0
        }) {
            splitSlice(id: hit.slice.id, atTimelineMs: currentTimeline)
        }
    }

    public func splitZoom(id: String, atSourceMs sourceMs: Double) {
        guard let idx = document.timeline.zooms.firstIndex(where: { $0.id == id }) else { return }
        let original = document.timeline.zooms[idx]
        guard sourceMs > original.sourceStartMs + 200.0 && sourceMs < original.sourceEndMs - 200.0 else {
            showToast("Can't cut item shorter than 0.2s", durationMs: 2000)
            return
        }
        mutate { doc in
            var firstHalf = original
            firstHalf.id = UUID().uuidString
            firstHalf.sourceEndMs = sourceMs

            var secondHalf = original
            secondHalf.id = UUID().uuidString
            secondHalf.sourceStartMs = sourceMs

            doc.timeline.zooms.replaceSubrange(idx...idx, with: [firstHalf, secondHalf])
            selectedZoomId = secondHalf.id
        }
    }

    public func splitMask(id: String, atSourceMs sourceMs: Double) {
        for tIdx in document.timeline.maskTracks.indices {
            if let mIdx = document.timeline.maskTracks[tIdx].items.firstIndex(where: { $0.id == id }) {
                let original = document.timeline.maskTracks[tIdx].items[mIdx]
                guard sourceMs > original.sourceStartMs + 180.0 && sourceMs < original.sourceEndMs - 180.0 else {
                    showToast("Can't cut item shorter than 0.2s", durationMs: 2000)
                    return
                }
                let rectAtSplit = original.interpolatedRect(at: sourceMs)
                mutate { doc in
                    var firstHalf = original
                    firstHalf.id = UUID().uuidString
                    firstHalf.sourceEndMs = sourceMs

                    var secondHalf = original
                    secondHalf.id = UUID().uuidString
                    secondHalf.sourceStartMs = sourceMs
                    secondHalf.keyframes = [MaskKeyframe(sourceMs: secondHalf.sourceStartMs, rect01: rectAtSplit)]

                    doc.timeline.maskTracks[tIdx].items.replaceSubrange(mIdx...mIdx, with: [firstHalf, secondHalf])
                    selectedMaskId = secondHalf.id
                }
                return
            }
        }
    }

    // MARK: - Caption Tracks

    private static let minCaptionDurationMs = 220.0
    private static let newCaptionDurationMs = 2000.0

    private var captionSourceBounds: (start: Double, end: Double) {
        let start = document.timeline.slices.map(\.sourceStartMs).min() ?? 0.0
        let end = document.timeline.slices.map(\.sourceEndMs).max() ?? max(500.0, metadata.durationMs)
        return (start, end)
    }

    /// Free space around a caption on its track. Captions on one track never overlap.
    private func captionNeighborBounds(blockId: String, trackId: String, around startMs: Double) -> (lower: Double, upper: Double) {
        let bounds = captionSourceBounds
        let others = document.captions.captionBlocks.filter { $0.trackId == trackId && $0.id != blockId }
        let lower = others.filter { $0.sourceStartMs < startMs }.map(\.sourceEndMs).max() ?? bounds.start
        let upper = others.filter { $0.sourceStartMs >= startMs }.map(\.sourceStartMs).min() ?? bounds.end
        return (max(bounds.start, lower), min(bounds.end, upper))
    }

    /// A track always holds a caption, so a new one starts with one at the playhead, kept whole near the end.
    @discardableResult
    public func addCaptionTrack() -> String {
        var newTrack = CaptionTrack(name: "Captions \(document.captions.captionTracks.count + 1)")
        if document.captions.captionTracks.isEmpty {
            newTrack.name = "Captions"
        } else if let last = document.captions.captionTracks.last {
            newTrack.style = last.style
            // A second track at the same spot would cover the first.
            newTrack.style.position01 = abs(last.style.position01.y - 1.0) < 0.1 ? Point01(x: 0.5, y: 0.0) : CaptionStyle.bottomPosition01
        }
        let bounds = captionSourceBounds
        let start = max(bounds.start, min(currentSourceTimeMs, bounds.end - Self.newCaptionDurationMs))
        let block = CaptionBlock(
            trackId: newTrack.id,
            sourceStartMs: start,
            sourceEndMs: min(bounds.end, start + Self.newCaptionDurationMs),
            customText: "New caption"
        )
        mutate { doc in
            doc.captions.enabled = true
            doc.captions.captionTracks.append(newTrack)
            doc.captions.captionBlocks.append(block)
        }
        selectCaption(block.id)
        scrollToTimelineTrack("track_caption_\(newTrack.id)")
        return newTrack.id
    }

    public func deleteCaptionTrack(id: String) {
        if let selected = selectedCaptionId,
           document.captions.captionBlocks.first(where: { $0.id == selected })?.trackId == id {
            selectedCaptionId = nil
        }
        mutate { doc in
            doc.captions.captionTracks.removeAll { $0.id == id }
            doc.captions.captionBlocks.removeAll { $0.trackId == id }
        }
    }

    public func toggleCaptionTrackVisibility(id: String) {
        mutate { doc in
            if let idx = doc.captions.captionTracks.firstIndex(where: { $0.id == id }) {
                doc.captions.captionTracks[idx].isHidden.toggle()
            }
        }
    }

    public func addCaption(trackId: String, sourceStartMs: Double, sourceEndMs: Double, text: String = "New caption") {
        let block = CaptionBlock(trackId: trackId, sourceStartMs: sourceStartMs, sourceEndMs: sourceEndMs, customText: text)
        mutate { doc in
            doc.captions.enabled = true
            doc.captions.captionBlocks.append(block)
        }
        selectCaption(block.id)
    }

    public func deleteCaption(id: String) {
        mutate { doc in
            doc.captions.captionBlocks.removeAll { $0.id == id }
        }
        if selectedCaptionId == id {
            selectedCaptionId = nil
        }
    }

    public func moveCaption(id: String, desiredStartMs: Double, durationMs: Double) {
        guard let idx = document.captions.captionBlocks.firstIndex(where: { $0.id == id }) else { return }
        let block = document.captions.captionBlocks[idx]
        let span = max(Self.minCaptionDurationMs, durationMs)
        let room = captionNeighborBounds(blockId: id, trackId: block.trackId, around: block.sourceStartMs)
        guard room.upper - room.lower >= span else { return }
        let start = max(room.lower, min(room.upper - span, desiredStartMs))
        document.captions.captionBlocks[idx].sourceStartMs = start
        document.captions.captionBlocks[idx].sourceEndMs = start + span
        renderRevision &+= 1
    }

    public func resizeCaption(id: String, newStartMs: Double, newEndMs: Double) {
        guard let idx = document.captions.captionBlocks.firstIndex(where: { $0.id == id }) else { return }
        let block = document.captions.captionBlocks[idx]
        let room = captionNeighborBounds(blockId: id, trackId: block.trackId, around: block.sourceStartMs)
        if abs(newEndMs - block.sourceEndMs) < 0.5 {
            document.captions.captionBlocks[idx].sourceStartMs = max(room.lower, min(block.sourceEndMs - Self.minCaptionDurationMs, newStartMs))
        } else {
            document.captions.captionBlocks[idx].sourceEndMs = max(block.sourceStartMs + Self.minCaptionDurationMs, min(room.upper, newEndMs))
        }
        renderRevision &+= 1
    }

    /// Moves a caption to another track, or to a new one when dragged past the last track. It stays put if the target is taken.
    public func moveCaptionToTrack(id: String, targetTrackIndex: Int) {
        guard let block = document.captions.captionBlocks.first(where: { $0.id == id }) else { return }
        mutate { doc in
            guard let idx = doc.captions.captionBlocks.firstIndex(where: { $0.id == id }) else { return }
            guard targetTrackIndex >= 0, targetTrackIndex < doc.captions.captionTracks.count else {
                guard let currentTrack = doc.captions.captionTracks.first(where: { $0.id == block.trackId }) else { return }
                // Its track would go away with it, leaving the same layout with the caption at another spot.
                guard doc.captions.captionBlocks.contains(where: { $0.trackId == block.trackId && $0.id != id }) else { return }
                var newTrack = CaptionTrack(name: "Captions \(doc.captions.captionTracks.count + 1)", style: currentTrack.style)
                newTrack.style.position01 = abs(currentTrack.style.position01.y - 1.0) < 0.1 ? Point01(x: 0.5, y: 0.0) : CaptionStyle.bottomPosition01
                if targetTrackIndex < 0 {
                    doc.captions.captionTracks.insert(newTrack, at: 0)
                } else {
                    doc.captions.captionTracks.append(newTrack)
                }
                doc.captions.captionBlocks[idx].trackId = newTrack.id
                return
            }
            let targetId = doc.captions.captionTracks[targetTrackIndex].id
            let isTaken = doc.captions.captionBlocks.contains { other in
                other.trackId == targetId
                    && other.id != id
                    && block.sourceEndMs > other.sourceStartMs + 20.0
                    && block.sourceStartMs < other.sourceEndMs - 20.0
            }
            if !isTaken {
                doc.captions.captionBlocks[idx].trackId = targetId
            }
        }
    }

    /// Splits between words. A caption shows at least one word on each side.
    public func splitCaption(id: String, atSourceMs sourceMs: Double) {
        guard let block = document.captions.captionBlocks.first(where: { $0.id == id }),
              sourceMs > block.sourceStartMs, sourceMs < block.sourceEndMs else { return }

        var first = block
        var second = block
        second.id = UUID().uuidString

        if let custom = block.customText {
            let words = custom.split(whereSeparator: \.isWhitespace).map(String.init)
            let keep = Int(round(Double(words.count) * (sourceMs - block.sourceStartMs) / (block.sourceEndMs - block.sourceStartMs)))
            guard words.count >= 2 else {
                showToast("Can't split a caption with one word", durationMs: 2000)
                return
            }
            let firstCount = max(1, min(words.count - 1, keep))
            first.customText = words[..<firstCount].joined(separator: " ")
            second.customText = words[firstCount...].joined(separator: " ")
            first.sourceEndMs = sourceMs
            second.sourceStartMs = sourceMs
        } else {
            let lookup = Dictionary(document.captions.segments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let spoken = block.wordIds.compactMap { lookup[$0] }
            guard spoken.count >= 2, let spokenFirst = spoken.first, let spokenLast = spoken.last else {
                showToast("Can't split a caption with one word", durationMs: 2000)
                return
            }
            let spokenSpan = max(1.0, spokenLast.sourceEndMs - spokenFirst.sourceStartMs)
            let scale = (block.sourceEndMs - block.sourceStartMs) / spokenSpan
            let displayStarts = spoken.map { block.sourceStartMs + ($0.sourceStartMs - spokenFirst.sourceStartMs) * scale }
            let firstCount = max(1, min(spoken.count - 1, displayStarts.filter { $0 < sourceMs }.count))
            // Cut where the next word starts, so words keep their timing.
            let cut = displayStarts[firstCount]
            first.wordIds = Array(block.wordIds[..<firstCount])
            second.wordIds = Array(block.wordIds[firstCount...])
            first.sourceEndMs = cut
            second.sourceStartMs = cut
        }

        mutate { doc in
            guard let idx = doc.captions.captionBlocks.firstIndex(where: { $0.id == id }) else { return }
            doc.captions.captionBlocks.replaceSubrange(idx...idx, with: [first, second])
        }
        selectedCaptionId = second.id
    }

    /// Editing keeps the spoken timing while the word count is unchanged. Otherwise the caption becomes typed text.
    public func updateCaptionText(id: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate { doc in
            guard let idx = doc.captions.captionBlocks.firstIndex(where: { $0.id == id }) else { return }
            let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            let block = doc.captions.captionBlocks[idx]
            let visibleIds = block.wordIds.filter { wordId in
                doc.captions.segments.first(where: { $0.id == wordId })?.isHidden == false
            }
            if block.customText == nil, visibleIds.count == parts.count {
                for (wordId, part) in zip(visibleIds, parts) {
                    if let wordIdx = doc.captions.segments.firstIndex(where: { $0.id == wordId }) {
                        doc.captions.segments[wordIdx].text = part
                    }
                }
            } else {
                doc.captions.captionBlocks[idx].customText = trimmed
                doc.captions.captionBlocks[idx].wordIds = []
            }
        }
    }

    public func effectiveCaptionStyle(blockId: String?, trackId: String?) -> CaptionStyle {
        let captions = document.captions
        let block = captions.captionBlocks.first(where: { $0.id == blockId })
        if let override = block?.styleOverride { return override }
        let resolvedTrackId = block?.trackId ?? trackId
        return captions.captionTracks.first(where: { $0.id == resolvedTrackId })?.style
            ?? captions.captionTracks.first?.style
            ?? CaptionStyle()
    }

    /// With `blockId`, changes only that caption. Otherwise changes the whole track, including captions that override it.
    public func updateCaptionStyle(blockId: String?, trackId: String?, _ change: (inout CaptionStyle) -> Void) {
        mutate { doc in
            if let blockId, let idx = doc.captions.captionBlocks.firstIndex(where: { $0.id == blockId }) {
                let block = doc.captions.captionBlocks[idx]
                var style = block.styleOverride
                    ?? doc.captions.captionTracks.first(where: { $0.id == block.trackId })?.style
                    ?? CaptionStyle()
                change(&style)
                doc.captions.captionBlocks[idx].styleOverride = style
                return
            }
            guard let trackIdx = doc.captions.captionTracks.firstIndex(where: { $0.id == trackId }) else { return }
            change(&doc.captions.captionTracks[trackIdx].style)
            let id = doc.captions.captionTracks[trackIdx].id
            for idx in doc.captions.captionBlocks.indices where doc.captions.captionBlocks[idx].trackId == id {
                if var override = doc.captions.captionBlocks[idx].styleOverride {
                    change(&override)
                    doc.captions.captionBlocks[idx].styleOverride = override
                }
            }
        }
    }

    // MARK: - Move Mask Between Tracks (Cross-Track Vertical Drag & Auto-Prune Empty Tracks)

    /// Moves a `MaskItem` vertically to `targetTrackIndex` (or creates a new track if dragged below all existing tracks).
    /// Any track left with 0 items is automatically deleted inside `mutate(...)`.
    public func moveMaskToTrack(maskId: String, targetTrackIndex: Int) {
        mutate { doc in
            var extractedMask: MaskItem?
            var sourceTrackIdx: Int?

            for tIdx in doc.timeline.maskTracks.indices {
                if let mIdx = doc.timeline.maskTracks[tIdx].items.firstIndex(where: { $0.id == maskId }) {
                    extractedMask = doc.timeline.maskTracks[tIdx].items.remove(at: mIdx)
                    sourceTrackIdx = tIdx
                    break
                }
            }

            guard let mask = extractedMask else { return }

            if targetTrackIndex < 0 {
                // Insert a new track at top
                let newTrack = MaskTrack(name: "Masks", items: [mask])
                doc.timeline.maskTracks.insert(newTrack, at: 0)
                return
            }

            if targetTrackIndex >= doc.timeline.maskTracks.count {
                // Append a new track at bottom
                let newTrack = MaskTrack(name: "Masks \(doc.timeline.maskTracks.count + 1)", items: [mask])
                doc.timeline.maskTracks.append(newTrack)
                return
            }

            // Check if target track has an overlapping item; if not, place directly in targetTrackIndex
            let hasOverlap = doc.timeline.maskTracks[targetTrackIndex].items.contains { other in
                !(mask.sourceEndMs <= other.sourceStartMs + 20.0 || mask.sourceStartMs >= other.sourceEndMs - 20.0)
            }

            if !hasOverlap {
                doc.timeline.maskTracks[targetTrackIndex].items.append(mask)
                doc.timeline.maskTracks[targetTrackIndex].items.sort { $0.sourceStartMs < $1.sourceStartMs }
            } else if let origIdx = sourceTrackIdx, origIdx < doc.timeline.maskTracks.count {
                // Put back in original track if target track is occupied at that timestamp
                doc.timeline.maskTracks[origIdx].items.append(mask)
                doc.timeline.maskTracks[origIdx].items.sort { $0.sourceStartMs < $1.sourceStartMs }
            } else {
                let newTrack = MaskTrack(name: "Masks", items: [mask])
                doc.timeline.maskTracks.append(newTrack)
            }
        }
    }

    // MARK: - Track Visibility Toggles

    public func toggleZoomTrackVisibility() {
        mutate { doc in
            doc.timeline.isZoomTrackHidden.toggle()
        }
    }

    public func toggleMaskTrackVisibility(trackId: String) {
        mutate { doc in
            if let idx = doc.timeline.maskTracks.firstIndex(where: { $0.id == trackId }) {
                doc.timeline.maskTracks[idx].isHidden.toggle()
            }
        }
    }

    // MARK: - Dedicated Move (Constant Duration) vs. Edge Resize Actions

    public func updateSliceSourceRange(id: String, newSourceStartMs: Double, newSourceEndMs: Double) {
        let maxDur = metadata.durationMs
        let clampedStart = max(0.0, min(maxDur - 200.0, newSourceStartMs))
        let clampedEnd = max(clampedStart + 200.0, min(maxDur, newSourceEndMs))
        mutate { doc in
            if let idx = doc.timeline.slices.firstIndex(where: { $0.id == id }) {
                doc.timeline.slices[idx].sourceStartMs = clampedStart
                doc.timeline.slices[idx].sourceEndMs = clampedEnd
            }
        }
    }

    /// Moves a ZoomBlock horizontally while strictly preserving its exact `durationMs` (NEVER resizes! Touching neighbors with 0ms gap).
    public func moveZoom(id: String, desiredStartMs: Double, durationMs: Double) {
        let earliestSourceMs = document.timeline.slices.map(\.sourceStartMs).min() ?? 0.0
        let latestSourceMs = document.timeline.slices.map(\.sourceEndMs).max() ?? metadata.durationMs
        let span = max(250.0, durationMs)

        mutate { doc in
            let sorted = doc.timeline.zooms.sorted { $0.sourceStartMs < $1.sourceStartMs }
            guard let sortedIdx = sorted.firstIndex(where: { $0.id == id }) else { return }

            let lowerBound = sortedIdx > 0
                ? max(earliestSourceMs, sorted[sortedIdx - 1].sourceEndMs)
                : earliestSourceMs
            let upperBound = sortedIdx + 1 < sorted.count
                ? min(latestSourceMs, sorted[sortedIdx + 1].sourceStartMs)
                : latestSourceMs
            guard upperBound - lowerBound >= span else { return }

            let clampedStart = max(lowerBound, min(upperBound - span, desiredStartMs))
            let clampedEnd = clampedStart + span

            if let realIdx = doc.timeline.zooms.firstIndex(where: { $0.id == id }) {
                doc.timeline.zooms[realIdx].sourceStartMs = clampedStart
                doc.timeline.zooms[realIdx].sourceEndMs = clampedEnd
            }
            doc.timeline.zooms.sort { $0.sourceStartMs < $1.sourceStartMs }
        }
    }

    /// Resizes ONLY the left/start or right/end edge of a ZoomBlock (touching neighbors edge-to-edge with 0ms gap).
    public func resizeZoom(id: String, newStartMs: Double, newEndMs: Double) {
        let earliestSourceMs = document.timeline.slices.map(\.sourceStartMs).min() ?? 0.0
        let latestSourceMs = document.timeline.slices.map(\.sourceEndMs).max() ?? metadata.durationMs
        let minDuration = 250.0

        mutate { doc in
            let sorted = doc.timeline.zooms.sorted { $0.sourceStartMs < $1.sourceStartMs }
            guard let sortedIdx = sorted.firstIndex(where: { $0.id == id }) else { return }

            let lowerBound = sortedIdx > 0
                ? max(earliestSourceMs, sorted[sortedIdx - 1].sourceEndMs)
                : earliestSourceMs
            let upperBound = sortedIdx + 1 < sorted.count
                ? min(latestSourceMs, sorted[sortedIdx + 1].sourceStartMs)
                : latestSourceMs
            guard upperBound - lowerBound >= minDuration else { return }

            let current = sorted[sortedIdx]
            let isResizingLeft = abs(newEndMs - current.sourceEndMs) < 0.5

            let start: Double
            let end: Double
            if isResizingLeft {
                end = current.sourceEndMs
                start = max(lowerBound, min(end - minDuration, newStartMs))
            } else {
                start = current.sourceStartMs
                end = max(start + minDuration, min(upperBound, newEndMs))
            }

            if let realIdx = doc.timeline.zooms.firstIndex(where: { $0.id == id }) {
                doc.timeline.zooms[realIdx].sourceStartMs = start
                doc.timeline.zooms[realIdx].sourceEndMs = end
            }
            doc.timeline.zooms.sort { $0.sourceStartMs < $1.sourceStartMs }
        }
    }

    /// Moves a MaskItem horizontally while strictly preserving its exact `durationMs` (touching neighbors with 0ms gap).
    public func moveMask(id: String, desiredStartMs: Double, durationMs: Double) {
        let earliestSourceMs = document.timeline.slices.map(\.sourceStartMs).min() ?? 0.0
        let latestSourceMs = document.timeline.slices.map(\.sourceEndMs).max() ?? metadata.durationMs
        let span = max(220.0, durationMs)

        mutate { doc in
            for tIdx in doc.timeline.maskTracks.indices {
                let items = doc.timeline.maskTracks[tIdx].items.sorted { $0.sourceStartMs < $1.sourceStartMs }
                guard let sortedIdx = items.firstIndex(where: { $0.id == id }) else { continue }

                let lowerBound = sortedIdx > 0
                    ? max(earliestSourceMs, items[sortedIdx - 1].sourceEndMs)
                    : earliestSourceMs
                let upperBound = sortedIdx + 1 < items.count
                    ? min(latestSourceMs, items[sortedIdx + 1].sourceStartMs)
                    : latestSourceMs
                guard upperBound - lowerBound >= span else { return }

                let clampedStart = max(lowerBound, min(upperBound - span, desiredStartMs))
                let clampedEnd = clampedStart + span

                if let realIdx = doc.timeline.maskTracks[tIdx].items.firstIndex(where: { $0.id == id }) {
                    let delta = clampedStart - doc.timeline.maskTracks[tIdx].items[realIdx].sourceStartMs
                    doc.timeline.maskTracks[tIdx].items[realIdx].sourceStartMs = clampedStart
                    doc.timeline.maskTracks[tIdx].items[realIdx].sourceEndMs = clampedEnd
                    for kIdx in doc.timeline.maskTracks[tIdx].items[realIdx].keyframes.indices {
                        doc.timeline.maskTracks[tIdx].items[realIdx].keyframes[kIdx].sourceMs += delta
                    }
                }
                doc.timeline.maskTracks[tIdx].items.sort { $0.sourceStartMs < $1.sourceStartMs }
                return
            }
        }
    }

    /// Resizes ONLY the left/start or right/end edge of a MaskItem (touching neighbors edge-to-edge with 0ms gap).
    public func resizeMask(id: String, newStartMs: Double, newEndMs: Double) {
        let earliestSourceMs = document.timeline.slices.map(\.sourceStartMs).min() ?? 0.0
        let latestSourceMs = document.timeline.slices.map(\.sourceEndMs).max() ?? metadata.durationMs
        let minDuration = 220.0

        mutate { doc in
            for tIdx in doc.timeline.maskTracks.indices {
                let items = doc.timeline.maskTracks[tIdx].items.sorted { $0.sourceStartMs < $1.sourceStartMs }
                guard let sortedIdx = items.firstIndex(where: { $0.id == id }) else { continue }

                let lowerBound = sortedIdx > 0
                    ? max(earliestSourceMs, items[sortedIdx - 1].sourceEndMs)
                    : earliestSourceMs
                let upperBound = sortedIdx + 1 < items.count
                    ? min(latestSourceMs, items[sortedIdx + 1].sourceStartMs)
                    : latestSourceMs
                guard upperBound - lowerBound >= minDuration else { return }

                let current = items[sortedIdx]
                let isResizingLeft = abs(newEndMs - current.sourceEndMs) < 0.5

                let start: Double
                let end: Double
                if isResizingLeft {
                    end = current.sourceEndMs
                    start = max(lowerBound, min(end - minDuration, newStartMs))
                } else {
                    start = current.sourceStartMs
                    end = max(start + minDuration, min(upperBound, newEndMs))
                }

                if let realIdx = doc.timeline.maskTracks[tIdx].items.firstIndex(where: { $0.id == id }) {
                    doc.timeline.maskTracks[tIdx].items[realIdx].sourceStartMs = start
                    doc.timeline.maskTracks[tIdx].items[realIdx].sourceEndMs = end
                }
                doc.timeline.maskTracks[tIdx].items.sort { $0.sourceStartMs < $1.sourceStartMs }
                return
            }
        }
    }

    // MARK: - Add / Delete Zooms & Masks

    public func deleteSelectedSlice() {
        guard let sliceId = selectedSliceId, document.timeline.slices.count > 1 else { return }
        mutate { doc in
            doc.timeline.slices.removeAll { $0.id == sliceId }
            selectedSliceId = doc.timeline.slices.first?.id
        }
    }

    public func deleteZoom(zoomId: String) {
        mutate { doc in
            doc.timeline.zooms.removeAll { $0.id == zoomId }
        }
        if selectedZoomId == zoomId {
            selectedZoomId = nil
        }
    }

    public func addZoomAtPlayhead(presentation: ZoomPresentation = .screen) {
        let srcMs = committedSourceTimeMs
        let maxDur = metadata.durationMs
        let cursorState = trajectorySolver.evaluate(atSourceMs: srcMs).cursor

        let sorted = document.timeline.zooms.sorted { $0.sourceStartMs < $1.sourceStartMs }
        if let containing = sorted.first(where: { srcMs >= $0.sourceStartMs && srcMs <= $0.sourceEndMs }) {
            if containing.presentation != presentation {
                setZoomPresentation(id: containing.id, presentation: presentation)
            }
            selectZoom(containing.id)
            scrollToTimelineTrack("track_zoom")
            return
        }

        let prevEnd = sorted.last(where: { $0.sourceEndMs <= srcMs })?.sourceEndMs ?? 0.0
        let nextStart = sorted.first(where: { $0.sourceStartMs >= srcMs })?.sourceStartMs ?? maxDur
        let availStart = prevEnd
        let availEnd = nextStart
        guard availEnd - availStart >= 400.0 else { return }

        let desiredDuration = min(3200.0, availEnd - availStart)
        let startMs = max(availStart, min(availEnd - desiredDuration, srcMs))
        let endMs = min(availEnd, startMs + desiredDuration)

        let newZoom = ZoomBlock(
            sourceStartMs: startMs,
            sourceEndMs: endMs,
            scale: presentation == .loupe ? 2.0 : 1.8,
            mode: hasRecordedCursor ? .followCursor : .manual,
            presentation: presentation,
            manualCenter01: hasRecordedCursor ? cursorState.position01 : .center,
            loupe: LoupeConfig(radius01: 0.35, bevelRatio: 0.25, chromaticAberration: 0.65)
        )
        mutate { doc in
            doc.timeline.isZoomTrackHidden = false
            doc.timeline.zooms.append(newZoom)
            doc.timeline.zooms.sort { $0.sourceStartMs < $1.sourceStartMs }
        }
        selectZoom(newZoom.id)
        scrollToTimelineTrack("track_zoom")
    }

    public func addZoomInRange(sourceStartMs: Double, sourceEndMs: Double) {
        guard sourceEndMs - sourceStartMs >= 350.0 else { return }
        let midMs = (sourceStartMs + sourceEndMs) * 0.5
        let cursorState = trajectorySolver.evaluate(atSourceMs: midMs).cursor
        let newZoom = ZoomBlock(
            sourceStartMs: sourceStartMs,
            sourceEndMs: sourceEndMs,
            scale: 1.8,
            mode: hasRecordedCursor ? .followCursor : .manual,
            presentation: .screen,
            manualCenter01: hasRecordedCursor ? cursorState.position01 : .center
        )
        mutate { doc in
            doc.timeline.isZoomTrackHidden = false
            doc.timeline.zooms.append(newZoom)
            doc.timeline.zooms.sort { $0.sourceStartMs < $1.sourceStartMs }
        }
        selectZoom(newZoom.id)
        scrollToTimelineTrack("track_zoom")
    }

    public func regenerateAutoZooms() {
        let generated = AutoZoomClusterGenerator.generateZooms(
            clicks: clickEvents,
            keys: keyEvents,
            durationMs: metadata.durationMs,
            defaultScale: 1.8
        )
        mutate { doc in
            doc.timeline.isZoomTrackHidden = false
            doc.timeline.zooms = generated
        }
        scrollToTimelineTrack("track_zoom")
    }

    public func addMaskAtPlayhead(type: MaskType = .blur, style: MaskStyle = .gaussian) {
        let srcMs = committedSourceTimeMs
        let maxDur = metadata.durationMs
        let endMs = min(maxDur, srcMs + 4500.0)
        let startMs = max(0.0, min(srcMs, endMs - 1200.0))

        let existingCount = activeMasks(atSourceMs: srcMs).count
        let offset = Double(existingCount % 4) * 0.03

        let boxW = 0.28
        let boxH = 0.14
        let boxX = 0.5 - boxW * 0.5 + offset
        let boxY = 0.5 - boxH * 0.5 + offset
        let initialRect = Rect01(x: boxX, y: boxY, width: boxW, height: boxH).clamped()

        let item = MaskItem(
            sourceStartMs: startMs,
            sourceEndMs: endMs,
            type: type,
            style: style,
            intensity: type == .spotlight ? 50.0 : 36.0,
            cornerRadius: 12.0,
            keyframes: [MaskKeyframe(sourceMs: startMs, rect01: initialRect)]
        )

        var targetTrackId = ""
        mutate { doc in
            if let freeTrackIndex = doc.timeline.maskTracks.firstIndex(where: { track in
                !track.items.contains(where: { !(endMs <= $0.sourceStartMs + 30.0 || startMs >= $0.sourceEndMs - 30.0) })
            }) {
                doc.timeline.maskTracks[freeTrackIndex].isHidden = false
                doc.timeline.maskTracks[freeTrackIndex].items.append(item)
                doc.timeline.maskTracks[freeTrackIndex].items.sort { $0.sourceStartMs < $1.sourceStartMs }
                targetTrackId = doc.timeline.maskTracks[freeTrackIndex].id
            } else {
                let newTrackNumber = doc.timeline.maskTracks.count + 1
                let newTrack = MaskTrack(
                    name: newTrackNumber == 1 ? "Masks" : "Masks \(newTrackNumber)",
                    isHidden: false,
                    items: [item]
                )
                doc.timeline.maskTracks.append(newTrack)
                targetTrackId = newTrack.id
            }
        }
        selectMask(item.id)
        if !targetTrackId.isEmpty {
            scrollToTimelineTrack("track_mask_\(targetTrackId)")
        }
    }

    public func addMaskInRange(trackId: String, sourceStartMs: Double, sourceEndMs: Double) {
        guard sourceEndMs - sourceStartMs >= 300.0 else { return }

        let existingTrack = document.timeline.maskTracks.first(where: { $0.id == trackId })
        let referenceMask = existingTrack?.items.last ?? document.timeline.maskTracks.first?.items.last
        let inheritedType = referenceMask?.type ?? .blur
        let inheritedStyle = referenceMask?.style ?? .gaussian
        let inheritedIntensity = referenceMask?.intensity ?? (inheritedType == .spotlight ? 50.0 : 36.0)
        let inheritedCornerRadius = referenceMask?.cornerRadius ?? 12.0

        let boxW = 0.28
        let boxH = 0.14
        let boxX = 0.5 - boxW * 0.5
        let boxY = 0.5 - boxH * 0.5
        let initialRect = Rect01(x: boxX, y: boxY, width: boxW, height: boxH).clamped()

        let item = MaskItem(
            sourceStartMs: sourceStartMs,
            sourceEndMs: sourceEndMs,
            type: inheritedType,
            style: inheritedStyle,
            intensity: inheritedIntensity,
            cornerRadius: inheritedCornerRadius,
            keyframes: [MaskKeyframe(sourceMs: sourceStartMs, rect01: initialRect)]
        )

        mutate { doc in
            if let tIdx = doc.timeline.maskTracks.firstIndex(where: { $0.id == trackId }) {
                doc.timeline.maskTracks[tIdx].isHidden = false
                doc.timeline.maskTracks[tIdx].items.append(item)
                doc.timeline.maskTracks[tIdx].items.sort { $0.sourceStartMs < $1.sourceStartMs }
            }
        }
        selectMask(item.id)
        scrollToTimelineTrack("track_mask_\(trackId)")
    }

    public func deleteMaskTrack(trackId: String) {
        mutate { doc in
            if let track = doc.timeline.maskTracks.first(where: { $0.id == trackId }),
               let selected = selectedMaskId,
               track.items.contains(where: { $0.id == selected }) {
                selectedMaskId = nil
            }
            doc.timeline.maskTracks.removeAll { $0.id == trackId }
        }
    }

    public func activeMasks(atSourceMs sourceMs: Double) -> [MaskItem] {
        var result: [MaskItem] = []
        for track in document.timeline.maskTracks where !track.isHidden {
            for item in track.items where !item.disabled {
                if sourceMs >= item.sourceStartMs && sourceMs <= item.sourceEndMs {
                    result.append(item)
                }
            }
        }
        return result
    }

    public func updateMaskRect(maskId: String, newRect01: Rect01, atSourceMs sourceMs: Double) {
        mutate { doc in
            for tIdx in doc.timeline.maskTracks.indices {
                if let mIdx = doc.timeline.maskTracks[tIdx].items.firstIndex(where: { $0.id == maskId }) {
                    doc.timeline.maskTracks[tIdx].items[mIdx].setRect(newRect01, at: sourceMs)
                    return
                }
            }
        }
    }

    public func deleteMask(maskId: String) {
        mutate { doc in
            for tIdx in doc.timeline.maskTracks.indices {
                doc.timeline.maskTracks[tIdx].items.removeAll { $0.id == maskId }
            }
        }
        if selectedMaskId == maskId {
            selectedMaskId = nil
        }
    }

    // MARK: - Copy Chosen System/Custom Wallpaper into `.nativescreen/assets/`

    public func selectSystemWallpaper(_ item: SystemWallpaperItem) {
        let assetsDir = packageURL.appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let destFileName = "background-\(item.id).jpg"
        let destURL = assetsDir.appendingPathComponent(destFileName)

        if FileManager.default.fileExists(atPath: destURL.path) {
            mutate { doc in
                doc.background.type = .wallpaper
                doc.background.systemWallpaperName = item.name
                doc.background.wallpaperRelativePath = "assets/\(destFileName)"
            }
            return
        }

        let sourceURL = item.fullImageURL
        let itemName = item.name
        let isBundled = item.isBundled
        DispatchQueue.global(qos: .utility).async { [weak self] in
            if isBundled {
                try? FileManager.default.copyItem(at: sourceURL, to: destURL)
            } else if let cgImage = SystemWallpaperCatalog.downsampleCGImage(at: sourceURL, maxPixelSize: 2560) {
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                if let jpgData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) {
                    try? jpgData.write(to: destURL, options: .atomic)
                }
            } else {
                try? FileManager.default.copyItem(at: sourceURL, to: destURL)
            }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.mutate { doc in
                    doc.background.type = .wallpaper
                    doc.background.systemWallpaperName = itemName
                    doc.background.wallpaperRelativePath = "assets/\(destFileName)"
                }
            }
        }
    }

    public func selectCustomBackgroundImage(from url: URL) {
        let assetsDir = packageURL.appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let destFileName = "custom-bg-\(Int(Date().timeIntervalSince1970)).jpg"
        let destURL = assetsDir.appendingPathComponent(destFileName)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            if let cgImage = SystemWallpaperCatalog.downsampleCGImage(at: url, maxPixelSize: 2560) {
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                if let jpgData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.90]) {
                    try? jpgData.write(to: destURL, options: .atomic)
                }
            } else {
                try? FileManager.default.copyItem(at: url, to: destURL)
            }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.mutate { doc in
                    doc.background.type = .image
                    doc.background.wallpaperRelativePath = "assets/\(destFileName)"
                }
            }
        }
    }

    public func selectCustomBackgroundNSImage(_ image: NSImage) {
        let assetsDir = packageURL.appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let destFileName = "custom-bg-\(Int(Date().timeIntervalSince1970)).jpg"
        let destURL = assetsDir.appendingPathComponent(destFileName)

        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let jpgData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.90]) {
            try? jpgData.write(to: destURL, options: .atomic)
            mutate { doc in
                doc.background.type = .image
                doc.background.wallpaperRelativePath = "assets/\(destFileName)"
            }
        }
    }

    public var videoFileURL: URL {
        packageURL
            .appendingPathComponent("recording", isDirectory: true)
            .appendingPathComponent(metadata.tracks.displayVideo)
    }

    /// Renames the project in-place (`document.name` + `.nativescreen` bundle folder on disk).
    public func renameProject(to rawName: String) {
        let trimmed = rawName
            .replacingOccurrences(of: ".nativescreen", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        mutate { doc in
            doc.name = trimmed
        }

        let parentDir = packageURL.deletingLastPathComponent()
        let newPackageURL = parentDir.appendingPathComponent("\(trimmed).nativescreen", isDirectory: true)
        if newPackageURL.standardizedFileURL != packageURL.standardizedFileURL,
           !FileManager.default.fileExists(atPath: newPackageURL.path) {
            do {
                try FileManager.default.moveItem(at: packageURL, to: newPackageURL)
                packageURL = newPackageURL
                ProjectWorkspaceStore.shared.addRecentProject(newPackageURL)
            } catch {
                // Keep existing packageURL if file move is blocked, but save updated document name
            }
        }
        try? saveNow()
    }

    // MARK: - Playback Toggle & Current Frame Extraction

    public func togglePlayPause() {
        if !isPlaying {
            if pendingAddMaskType != nil {
                pendingAddMaskType = nil
                NSCursor.arrow.set()
            }
            // Clear hoverSkimTimelineMs when starting playback so when playback pauses or finishes at the end,
            // it stays at `playheadTimelineMs` until the user actively moves the mouse on the timeline!
            hoverSkimTimelineMs = nil
            // If playhead is already at the very end, restart from 0:00 when pressing Play
            if playheadTimelineMs >= timeMapper.totalTimelineDurationMs - 15.0 {
                playheadTimelineMs = 0.0
                renderRevision &+= 1
            }
            isPlaying = true
        } else {
            hoverSkimTimelineMs = nil
            isPlaying = false
            renderRevision &+= 1
        }
    }

    public func extractRawSourceFrameNSImage() async -> NSImage? {
        let url = videoFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let cmTime = CMTime(seconds: currentSourceTimeMs / 1000.0, preferredTimescale: 600)
        guard let (cgImg, _) = try? await gen.image(at: cmTime) else { return nil }
        return NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
    }

    public func extractRawWebcamFrameCGImage() async -> CGImage? {
        guard let url = webcamVideoFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)
        let cmTime = CMTime(seconds: max(0.05, currentSourceTimeMs / 1000.0), preferredTimescale: 600)
        if let (cgImg, _) = try? await gen.image(at: cmTime) {
            return cgImg
        }
        if let (cgImg0, _) = try? await gen.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) {
            return cgImg0
        }
        return nil
    }

    public func extractRawWebcamFrameNSImage() async -> (image: NSImage, pixelSize: CGSize)? {
        if let cgImg = await extractRawWebcamFrameCGImage() {
            let size = CGSize(width: cgImg.width, height: cgImg.height)
            return (NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height)), size)
        }
        let fallback = GradedWebcamPortraitView.cachedGradedPortraitImage(preset: .original, intensity: 1.0, sharpen01: 0.0)
        return (fallback, CGSize(width: 1920, height: 1080))
    }

    public func renderCurrentCompositedCGImage(targetHeight: Double = 1440.0) async -> CGImage? {
        guard let compositor = MetalFrameCompositor() else { return nil }
        let sourceMs = currentSourceTimeMs
        var sourceCI: CIImage?

        let url = videoFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            let cmTime = CMTime(seconds: sourceMs / 1000.0, preferredTimescale: 600)
            if let (cgImg, _) = try? await gen.image(at: cmTime) {
                sourceCI = CIImage(cgImage: cgImg)
            }
        }

        // Still frames bake the real webcam frame too, same as video export.
        var webcamCI: CIImage?
        if document.camera.enabled, let webcamURL = webcamVideoFileURL {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: webcamURL))
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
            gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
            let webcamMs = max(0.0, sourceMs + document.camera.delayAdjustmentMs)
            if let (cgImg, _) = try? await gen.image(at: CMTime(seconds: webcamMs / 1000.0, preferredTimescale: 600)) {
                webcamCI = CIImage(cgImage: cgImg)
            }
        }

        let srcW = Double(max(1280, metadata.captureTarget.pixelSize.width))
        let srcH = Double(max(720, metadata.captureTarget.pixelSize.height))
        let aspect = document.canvas.effectiveAspectRatio(sourceWidth: srcW, sourceHeight: srcH)
        let outH = max(240.0, targetHeight)
        let outW = max(200.0, round(outH * aspect))
        let outputSize = CGSize(width: outW, height: outH)

        let composited = compositor.composeFrame(
            sourceVideoFrame: sourceCI,
            sourceTimeMs: sourceMs,
            session: self,
            outputSize: outputSize,
            includeShortcutOverlay: true,
            webcamVideoFrame: webcamCI
        )
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        return compositor.ciContext.createCGImage(
            composited,
            from: CGRect(origin: .zero, size: outputSize),
            format: .RGBA8,
            colorSpace: colorSpace
        )
    }

    public func openStillFrameExportModal() {
        isPlaying = false
        isShowingStillFrameExportModal = true
    }

    public func copyCurrentFrameToClipboard() {
        isPlaying = false
        Task {
            guard let cgImg = await renderCurrentCompositedCGImage() else { return }
            let nsImg = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([nsImg])
            await MainActor.run {
                self.showToast("Current frame image copied to clipboard")
            }
        }
    }

    // MARK: - Rich Context Popover Actions (Clip, Zoom, Mask)

    public func mergeSliceWithNext(id: String) {
        mutate { doc in
            guard let idx = doc.timeline.slices.firstIndex(where: { $0.id == id }),
                  idx + 1 < doc.timeline.slices.count else { return }
            let nextSlice = doc.timeline.slices[idx + 1]
            doc.timeline.slices[idx].sourceEndMs = max(doc.timeline.slices[idx].sourceEndMs, nextSlice.sourceEndMs)
            doc.timeline.slices.remove(at: idx + 1)
            selectedSliceId = doc.timeline.slices[idx].id
        }
    }

    public func removeSliceStartTrim(id: String) {
        mutate { doc in
            guard let idx = doc.timeline.slices.firstIndex(where: { $0.id == id }) else { return }
            let prevEnd = idx > 0 ? doc.timeline.slices[idx - 1].sourceEndMs : 0.0
            if doc.timeline.slices[idx].sourceStartMs > prevEnd {
                doc.timeline.slices[idx].sourceStartMs = prevEnd
            }
            selectedSliceId = doc.timeline.slices[idx].id
        }
    }

    public func removeSliceEndTrim(id: String) {
        let maxDur = metadata.durationMs
        mutate { doc in
            guard let idx = doc.timeline.slices.firstIndex(where: { $0.id == id }) else { return }
            let nextStart = (idx + 1 < doc.timeline.slices.count) ? doc.timeline.slices[idx + 1].sourceStartMs : maxDur
            if doc.timeline.slices[idx].sourceEndMs < nextStart {
                doc.timeline.slices[idx].sourceEndMs = nextStart
            }
            selectedSliceId = doc.timeline.slices[idx].id
        }
    }

    public func resetSliceTrim(id: String) {
        let maxDur = metadata.durationMs
        mutate { doc in
            guard let idx = doc.timeline.slices.firstIndex(where: { $0.id == id }) else { return }
            let prevEnd = idx > 0 ? doc.timeline.slices[idx - 1].sourceEndMs : 0.0
            let nextStart = (idx + 1 < doc.timeline.slices.count) ? doc.timeline.slices[idx + 1].sourceStartMs : maxDur
            if nextStart > prevEnd + 100.0 {
                doc.timeline.slices[idx].sourceStartMs = prevEnd
                doc.timeline.slices[idx].sourceEndMs = nextStart
            }
        }
    }

    public func resetAllSlicesTrimAndCuts() {
        let maxDur = metadata.durationMs
        mutate { doc in
            let newSlice = ClipSlice(sourceStartMs: 0.0, sourceEndMs: maxDur, speed: 1.0)
            doc.timeline.slices = [newSlice]
            selectedSliceId = newSlice.id
        }
    }

    public func setSliceSpeed(id: String, speed: Double) {
        mutate { doc in
            if let idx = doc.timeline.slices.firstIndex(where: { $0.id == id }) {
                doc.timeline.slices[idx].speed = max(0.25, min(8.0, speed))
            }
        }
    }

    /// Volume sliders never set `muted`: that flag silences every source of the slice, so tying it to one slider
    /// made the system audio slider at 0 also mute the microphone. Moving a slider clears a mute left by older builds.
    public func setSliceSystemAudioVolume(id: String, volume: Double) {
        mutate { doc in
            if let idx = doc.timeline.slices.firstIndex(where: { $0.id == id }) {
                doc.timeline.slices[idx].systemAudioVolume = max(0.0, min(1.0, volume))
                doc.timeline.slices[idx].muted = false
            }
        }
    }

    public func setSliceMicrophoneVolume(id: String, volume: Double) {
        mutate { doc in
            if let idx = doc.timeline.slices.firstIndex(where: { $0.id == id }) {
                doc.timeline.slices[idx].microphoneVolume = max(0.0, min(1.0, volume))
                doc.timeline.slices[idx].muted = false
            }
        }
    }

    public func toggleSliceHideCursor(id: String) {
        mutate { doc in
            if let idx = doc.timeline.slices.firstIndex(where: { $0.id == id }) {
                doc.timeline.slices[idx].hideCursor.toggle()
            }
        }
    }

    public func toggleSliceDisableSmoothCursor(id: String) {
        mutate { doc in
            if let idx = doc.timeline.slices.firstIndex(where: { $0.id == id }) {
                doc.timeline.slices[idx].disableSmoothCursor.toggle()
            }
        }
    }

    public func setZoomPresentation(id: String, presentation: ZoomPresentation) {
        mutate { doc in
            if let idx = doc.timeline.zooms.firstIndex(where: { $0.id == id }) {
                doc.timeline.zooms[idx].presentation = presentation
            }
        }
    }

    /// Pins a zoom to a hand-picked focus point (`Zoom position` pad). Switches the zoom to `Manual`.
    public func setZoomManualCenter(id: String, center01: Point01) {
        let clamped = Point01(x: min(1.0, max(0.0, center01.x)), y: min(1.0, max(0.0, center01.y)))
        mutate { doc in
            if let idx = doc.timeline.zooms.firstIndex(where: { $0.id == id }) {
                doc.timeline.zooms[idx].mode = .manual
                doc.timeline.zooms[idx].manualCenter01 = clamped
            }
        }
    }

    /// Moves the playhead inside `zoom`, past its zoom-in animation, so the preview shows the zoomed framing while
    /// the zoom is being positioned. Does nothing when the playhead is already there.
    public func seekIntoZoomForEditing(id: String) {
        guard let zoom = document.timeline.zooms.first(where: { $0.id == id }) else { return }
        let duration = zoom.sourceEndMs - zoom.sourceStartMs
        let settledStartMs = zoom.sourceStartMs + min(900.0, duration * 0.5)
        let current = currentSourceTimeMs
        if current >= settledStartMs && current <= zoom.sourceEndMs - 30.0 {
            return
        }
        guard let timelineMs = timeMapper.timelineTime(forSourceMs: settledStartMs) else { return }
        isPlaying = false
        hoverSkimTimelineMs = nil
        seek(toTimelineMs: timelineMs)
    }

    public func setZoomScale(id: String, scale: Double) {
        let stepped = (scale * 10.0).rounded() / 10.0
        mutate { doc in
            if let idx = doc.timeline.zooms.firstIndex(where: { $0.id == id }) {
                doc.timeline.zooms[idx].scale = max(1.0, min(4.0, stepped))
            }
        }
    }

    public func applyZoomLevelToAllOtherZooms(fromId id: String) {
        mutate { doc in
            guard let sourceZoom = doc.timeline.zooms.first(where: { $0.id == id }) else { return }
            for idx in doc.timeline.zooms.indices {
                doc.timeline.zooms[idx].scale = sourceZoom.scale
            }
        }
        showToast("Zoom level applied to all zooms")
    }

    public func duplicateZoom(id: String) {
        let maxDur = metadata.durationMs
        mutate { doc in
            let sorted = doc.timeline.zooms.sorted { $0.sourceStartMs < $1.sourceStartMs }
            guard let sortedIdx = sorted.firstIndex(where: { $0.id == id }) else { return }
            let orig = sorted[sortedIdx]
            let nextStart = (sortedIdx + 1 < sorted.count) ? sorted[sortedIdx + 1].sourceStartMs : maxDur
            let availAfter = nextStart - orig.sourceEndMs

            if availAfter >= 300.0 {
                var copy = orig
                copy.id = UUID().uuidString
                copy.sourceStartMs = orig.sourceEndMs
                copy.sourceEndMs = min(nextStart, orig.sourceEndMs + (orig.sourceEndMs - orig.sourceStartMs))
                doc.timeline.zooms.append(copy)
                doc.timeline.zooms.sort { $0.sourceStartMs < $1.sourceStartMs }
                selectedZoomId = copy.id
            } else if orig.sourceEndMs - orig.sourceStartMs >= 500.0 {
                // Split in half so duplicate fits right beside it
                let mid = (orig.sourceStartMs + orig.sourceEndMs) * 0.5
                if let realIdx = doc.timeline.zooms.firstIndex(where: { $0.id == id }) {
                    doc.timeline.zooms[realIdx].sourceEndMs = mid
                }
                var copy = orig
                copy.id = UUID().uuidString
                copy.sourceStartMs = mid
                copy.sourceEndMs = orig.sourceEndMs
                doc.timeline.zooms.append(copy)
                doc.timeline.zooms.sort { $0.sourceStartMs < $1.sourceStartMs }
                selectedZoomId = copy.id
            }
        }
    }

    public func toggleZoomDisabled(id: String) {
        mutate { doc in
            if let idx = doc.timeline.zooms.firstIndex(where: { $0.id == id }) {
                doc.timeline.zooms[idx].disabled.toggle()
            }
        }
    }

    public func copyZoomToClipboard(id: String) {
        if let found = document.timeline.zooms.first(where: { $0.id == id }) {
            copiedZoomBlock = found
            showToast("Zoom range copied")
        }
    }

    public func cutZoomToClipboard(id: String) {
        if let found = document.timeline.zooms.first(where: { $0.id == id }) {
            copiedZoomBlock = found
        }
        deleteZoom(zoomId: id)
        showToast("Zoom range copied")
    }

    public func setMaskType(id: String, type: MaskType) {
        mutate { doc in
            for tIdx in doc.timeline.maskTracks.indices {
                if let mIdx = doc.timeline.maskTracks[tIdx].items.firstIndex(where: { $0.id == id }) {
                    doc.timeline.maskTracks[tIdx].items[mIdx].type = type
                    if type == .spotlight {
                        doc.timeline.maskTracks[tIdx].items[mIdx].style = .dim
                    } else if doc.timeline.maskTracks[tIdx].items[mIdx].style == .dim {
                        doc.timeline.maskTracks[tIdx].items[mIdx].style = .gaussian
                    }
                    return
                }
            }
        }
    }

    public func toggleMaskDisabled(id: String) {
        mutate { doc in
            for tIdx in doc.timeline.maskTracks.indices {
                if let mIdx = doc.timeline.maskTracks[tIdx].items.firstIndex(where: { $0.id == id }) {
                    doc.timeline.maskTracks[tIdx].items[mIdx].disabled.toggle()
                    return
                }
            }
        }
    }

    public func copyMaskToClipboard(id: String) {
        for track in document.timeline.maskTracks {
            if let found = track.items.first(where: { $0.id == id }) {
                copiedMaskItem = found
                showToast("Mask copied")
                return
            }
        }
    }

    public func cutMaskToClipboard(id: String) {
        for track in document.timeline.maskTracks {
            if let found = track.items.first(where: { $0.id == id }) {
                copiedMaskItem = found
                break
            }
        }
        deleteMask(maskId: id)
        showToast("Mask copied")
    }

    public func pasteFromClipboard() {
        let srcMs = currentSourceTimeMs
        let maxDur = metadata.durationMs
        if let copiedZoom = copiedZoomBlock {
            if let selZoomId = selectedZoomId {
                mutate { doc in
                    if let idx = doc.timeline.zooms.firstIndex(where: { $0.id == selZoomId }) {
                        doc.timeline.zooms[idx].mode = copiedZoom.mode
                        doc.timeline.zooms[idx].scale = copiedZoom.scale
                        doc.timeline.zooms[idx].presentation = copiedZoom.presentation
                        doc.timeline.zooms[idx].loupe = copiedZoom.loupe
                        doc.timeline.zooms[idx].manualCenter01 = copiedZoom.manualCenter01
                        doc.timeline.zooms[idx].instantAnimation = copiedZoom.instantAnimation
                    }
                }
                showToast("Zoom range settings pasted")
            } else {
                let dur = max(300.0, copiedZoom.sourceEndMs - copiedZoom.sourceStartMs)
                var newZoom = copiedZoom
                newZoom.id = UUID().uuidString
                newZoom.sourceStartMs = min(max(0.0, srcMs), max(0.0, maxDur - 300.0))
                newZoom.sourceEndMs = min(maxDur, newZoom.sourceStartMs + dur)
                mutate { doc in
                    doc.timeline.zooms.append(newZoom)
                    doc.timeline.zooms.sort { $0.sourceStartMs < $1.sourceStartMs }
                    selectedZoomId = newZoom.id
                }
                showToast("Zoom range settings pasted")
            }
            return
        }
        if let copiedMask = copiedMaskItem {
            let dur = max(300.0, copiedMask.sourceEndMs - copiedMask.sourceStartMs)
            var newMask = copiedMask
            newMask.id = UUID().uuidString
            newMask.sourceStartMs = min(max(0.0, srcMs), max(0.0, maxDur - 300.0))
            newMask.sourceEndMs = min(maxDur, newMask.sourceStartMs + dur)
            mutate { doc in
                if doc.timeline.maskTracks.isEmpty {
                    doc.timeline.maskTracks.append(MaskTrack(id: UUID().uuidString, name: "Masks", items: [newMask]))
                } else {
                    doc.timeline.maskTracks[0].items.append(newMask)
                }
                selectedMaskId = newMask.id
            }
            showToast("Mask settings pasted")
        }
    }

    /// Splits whichever item is currently selected at `currentSourceTimeMs` (or splits the Clip at Playhead) when pressing `C`.
    public func splitAtCurrentTimeShortcut() {
        let srcMs = currentSourceTimeMs
        if let captionId = selectedCaptionId {
            splitCaption(id: captionId, atSourceMs: srcMs)
            return
        }
        if let layoutId = selectedCameraLayoutId {
            splitCameraLayout(id: layoutId, atSourceMs: srcMs)
            return
        }
        if let maskId = selectedMaskId {
            splitMask(id: maskId, atSourceMs: srcMs)
            return
        }
        if let zoomId = selectedZoomId {
            splitZoom(id: zoomId, atSourceMs: srcMs)
            return
        }
        splitSliceAtPlayhead()
    }

    /// Toggles `disabled` on the selected Zoom, Camera Layout, Voiceover, or Mask when pressing `D`.
    public func toggleDisableSelectedShortcut() {
        if let voId = selectedVoiceoverId {
            toggleVoiceoverDisabled(id: voId)
            return
        }
        if let layoutId = selectedCameraLayoutId {
            toggleCameraLayoutDisabled(id: layoutId)
            return
        }
        if let maskId = selectedMaskId {
            toggleMaskDisabled(id: maskId)
            return
        }
        if let zoomId = selectedZoomId {
            toggleZoomDisabled(id: zoomId)
        }
    }

    // MARK: - Audio Waveform Extraction & Smooth Speech Envelope Generator

    private static func generateProceduralWaveform(durationMs: Double, bucketCount: Int = 240) -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity(bucketCount)
        for i in 0..<bucketCount {
            let t = Double(i) / Double(max(1, bucketCount)) * (durationMs / 1000.0)
            let syllabic = abs(sin(t * 4.7)) * 0.52 + abs(sin(t * 11.3 + 1.2)) * 0.30 + abs(cos(t * 2.1)) * 0.18
            let pauseEnvelope = sin(t * 1.35) > -0.55 ? 1.0 : 0.14
            let val = Float(min(0.95, max(0.08, syllabic * pauseEnvelope)))
            samples.append(val)
        }
        return samples
    }

    private func loadRealAudioWaveformIfAvailable() async {
        let durationSec = max(1.0, metadata.durationMs / 1000.0)
        let targetBinCount = max(256, min(16384, Int(durationSec * 240.0)))

        // 1. System / App Audio Waveform (`display.mp4` -> Purple waveform on timeline clips)
        let sysURL = videoFileURL
        if FileManager.default.fileExists(atPath: sysURL.path) {
            if let sysSamples = await Self.extractNormalizedAudioWaveform(from: sysURL, targetBinCount: targetBinCount) {
                self.audioWaveformSamples = sysSamples
            } else {
                self.audioWaveformSamples = []
            }
        }

        // 2. Microphone Audio Waveform (`microphone.m4a` -> Translucent white waveform on timeline clips)
        if let micURL = microphoneAudioFileURL, FileManager.default.fileExists(atPath: micURL.path) {
            if let micSamples = await Self.extractNormalizedAudioWaveform(from: micURL, targetBinCount: targetBinCount) {
                self.microphoneWaveformSamples = micSamples
            } else {
                self.microphoneWaveformSamples = []
            }
        }

        // 3. Voiceovers Audio Waveforms (`voiceovers` -> Translucent white waveform on each Voiceover segment)
        await loadAllVoiceoverWaveformsIfNeeded()
    }

    public func loadAllVoiceoverWaveformsIfNeeded() async {
        for vo in document.timeline.voiceovers {
            await loadVoiceoverWaveform(for: vo)
        }
    }

    public func loadVoiceoverWaveform(for vo: VoiceoverSegment) async {
        let voURL = packageURL.appendingPathComponent(vo.relativePath)
        let bins = max(128, min(4096, Int((vo.durationMs / 1000.0) * 240.0)))
        if FileManager.default.fileExists(atPath: voURL.path),
           let extracted = await Self.extractNormalizedAudioWaveform(from: voURL, targetBinCount: bins) {
            self.voiceoverWaveformSamplesByID[vo.id] = extracted
        } else {
            self.voiceoverWaveformSamplesByID[vo.id] = Self.generateProceduralWaveform(durationMs: vo.durationMs, bucketCount: max(96, bins))
        }
        renderRevision &+= 1
    }

    private static func extractNormalizedAudioWaveform(from url: URL, targetBinCount: Int) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              let audioTrack = tracks.first else {
            return nil
        }

        return await Task.detached(priority: .utility) {
            guard let reader = try? AVAssetReader(asset: asset) else { return nil }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading() else { return nil }

            var rawPeaks: [Float] = []
            rawPeaks.reserveCapacity(8192)

            while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                let length = CMBlockBufferGetDataLength(blockBuffer)
                guard length >= 2 else { continue }
                var data = Data(count: length)
                data.withUnsafeMutableBytes { rawBuffer in
                    if let baseAddress = rawBuffer.baseAddress {
                        CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: baseAddress)
                        let int16Ptr = baseAddress.assumingMemoryBound(to: Int16.self)
                        let totalSamples = length / MemoryLayout<Int16>.size
                        let chunkSize = 128
                        var offset = 0
                        while offset < totalSamples {
                            let end = min(totalSamples, offset + chunkSize)
                            var maxSample: Float = 0.0
                            var i = offset
                            while i < end {
                                let v = abs(Float(int16Ptr[i])) / 32768.0
                                if v > maxSample { maxSample = v }
                                i += 1
                            }
                            rawPeaks.append(maxSample)
                            offset += chunkSize
                        }
                    }
                }
            }

            guard rawPeaks.count >= 8 else { return nil }
            let sortedPeaks = rawPeaks.sorted()
            let p95Idx = min(sortedPeaks.count - 1, Int(Double(sortedPeaks.count) * 0.95))
            let p95Peak = sortedPeaks[p95Idx]
            let maxPeak = sortedPeaks.last ?? 0.0
            // If the audio track is completely silent (e.g. silent system audio), return nil so no fake flat bar is drawn!
            guard maxPeak >= 0.002 else { return nil }
            let referencePeak = max(0.025, p95Peak)

            let finalCount = min(targetBinCount, rawPeaks.count)
            var buckets = [Float](repeating: 0.02, count: finalCount)
            for b in 0..<finalCount {
                let startIdx = (b * rawPeaks.count) / finalCount
                let endIdx = max(startIdx + 1, ((b + 1) * rawPeaks.count) / finalCount)
                var localMax: Float = 0
                for j in startIdx..<min(rawPeaks.count, endIdx) {
                    localMax = max(localMax, rawPeaks[j])
                }
                let normalized = min(1.0, localMax / referencePeak)
                buckets[b] = localMax < 0.0015 ? 0.015 : min(0.98, max(0.02, pow(normalized, 0.62)))
            }
            return buckets
        }.value
    }

    // MARK: - Speed Up Typing Suggestion Detection & Actions

    public struct TypingSuggestionRange: Identifiable, Equatable, Sendable {
        public var id: Int { startKeyMs }
        public let startKeyMs: Int
        public let sourceStartMs: Double
        public let sourceEndMs: Double
    }

    /// Detects continuous typing bursts (`gap < 500ms`, `duration >= 1500ms`, `rate >= 2.0 keys/sec`)
    /// that haven't been dismissed and lie inside a normal-speed (`~1x`) ClipSlice.
    public var activeTypingSuggestions: [TypingSuggestionRange] {
        guard !keyEvents.isEmpty else { return [] }
        if let cached = cachedTypingSuggestions,
           lastTypingSuggestionsSlices == document.timeline.slices,
           lastDismissedTypingStarts == document.timeline.dismissedTypingSuggestionStarts {
            return cached
        }

        let maxGapMs = 500.0
        let minDurationMs = 1500.0
        let minRatePerSec = 2.0

        var rawBursts: [(startMs: Double, endMs: Double)] = []
        var currentBurst: [KeyStrokeEvent] = []

        for ev in keyEvents {
            if currentBurst.isEmpty {
                currentBurst = [ev]
                continue
            }
            let prev = currentBurst[currentBurst.count - 1]
            if ev.t - prev.t < maxGapMs {
                currentBurst.append(ev)
                continue
            }
            let durMs = prev.t - currentBurst[0].t
            let rate = Double(currentBurst.count) / max(0.001, durMs / 1000.0)
            if durMs >= minDurationMs && rate >= minRatePerSec {
                rawBursts.append((currentBurst[0].t, prev.t))
            }
            currentBurst = [ev]
        }

        if currentBurst.count >= 2 {
            let prev = currentBurst[currentBurst.count - 1]
            let durMs = prev.t - currentBurst[0].t
            let rate = Double(currentBurst.count) / max(0.001, durMs / 1000.0)
            if durMs >= minDurationMs && rate >= minRatePerSec {
                rawBursts.append((currentBurst[0].t, prev.t))
            }
        }

        let dismissed = Set(document.timeline.dismissedTypingSuggestionStarts)
        var results: [TypingSuggestionRange] = []

        for burst in rawBursts {
            let keyInt = Int(round(burst.startMs))
            guard !dismissed.contains(keyInt) else { continue }
            // Only suggest if there is a ClipSlice containing `[burst.startMs, burst.endMs]` that is still at ~1x speed
            if let slice = document.timeline.slices.first(where: {
                burst.startMs >= $0.sourceStartMs + 120.0 && burst.endMs <= $0.sourceEndMs - 120.0
            }), slice.speed <= 1.08 {
                results.append(
                    TypingSuggestionRange(
                        startKeyMs: keyInt,
                        sourceStartMs: burst.startMs,
                        sourceEndMs: burst.endMs
                    )
                )
            }
        }
        lastTypingSuggestionsSlices = document.timeline.slices
        lastDismissedTypingStarts = document.timeline.dismissedTypingSuggestionStarts
        cachedTypingSuggestions = results
        return results
    }

    public func applyTypingSuggestion(_ range: TypingSuggestionRange, speed: Double) {
        let clampedSpeed = max(1.5, min(8.0, (speed * 10.0).rounded() / 10.0))
        mutate { doc in
            Self.splitAndSpeedUpSlice(in: &doc, startMs: range.sourceStartMs, endMs: range.sourceEndMs, speed: clampedSpeed)
            if !doc.timeline.dismissedTypingSuggestionStarts.contains(range.startKeyMs) {
                doc.timeline.dismissedTypingSuggestionStarts.append(range.startKeyMs)
            }
        }
    }

    public func applyAllTypingSuggestions(speed: Double) {
        let clampedSpeed = max(1.5, min(8.0, (speed * 10.0).rounded() / 10.0))
        let ranges = activeTypingSuggestions
        guard !ranges.isEmpty else { return }
        mutate { doc in
            for r in ranges {
                Self.splitAndSpeedUpSlice(in: &doc, startMs: r.sourceStartMs, endMs: r.sourceEndMs, speed: clampedSpeed)
                if !doc.timeline.dismissedTypingSuggestionStarts.contains(r.startKeyMs) {
                    doc.timeline.dismissedTypingSuggestionStarts.append(r.startKeyMs)
                }
            }
        }
    }

    public func dismissTypingSuggestion(_ range: TypingSuggestionRange) {
        mutate { doc in
            if !doc.timeline.dismissedTypingSuggestionStarts.contains(range.startKeyMs) {
                doc.timeline.dismissedTypingSuggestionStarts.append(range.startKeyMs)
            }
        }
    }

    private static func splitAndSpeedUpSlice(in doc: inout ProjectDocument, startMs: Double, endMs: Double, speed: Double) {
        guard endMs - startMs >= 300.0 else { return }
        guard let idx = doc.timeline.slices.firstIndex(where: {
            startMs >= $0.sourceStartMs + 100.0 && endMs <= $0.sourceEndMs - 100.0
        }) else {
            return
        }
        let original = doc.timeline.slices[idx]
        var beforeSlice = original
        beforeSlice.id = UUID().uuidString
        beforeSlice.sourceEndMs = startMs

        var typingSlice = original
        typingSlice.id = UUID().uuidString
        typingSlice.sourceStartMs = startMs
        typingSlice.sourceEndMs = endMs
        typingSlice.speed = speed

        var afterSlice = original
        afterSlice.id = UUID().uuidString
        afterSlice.sourceStartMs = endMs

        doc.timeline.slices.replaceSubrange(idx...idx, with: [beforeSlice, typingSlice, afterSlice])
    }

    // MARK: - Keyboard Shortcuts Track & 3D Keycap Overlay Engine

    public struct ShortcutKeyCap: Equatable, Hashable, Sendable, Identifiable {
        public enum LabelPlacement: String, Sendable {
            case center
            case bottomLeft
            case bottomCenter
        }

        public var id: String { "\(key)_\(symbol ?? "")_\(label)" }
        public let key: String
        public let widthRatio: Double
        public let symbol: String?
        public let label: String
        public let labelPlacement: LabelPlacement
    }

    public struct ShortcutPressCluster: Identifiable, Equatable, Sendable {
        public let id: String
        public let trackId: String
        public let isCustomSegment: Bool
        public let firstKeyDownMsInt: Int
        public let firstKeyDownMs: Double
        public let lastKeyDownMs: Double
        public var displayStartMs: Double
        public var displayEndMs: Double
        public let modifiers: [String]
        public let primaryKey: String
        public let compactTimelineLabel: String
        public let keyCaps: [ShortcutKeyCap]
    }

    /// Computes all visible/hidden shortcut clusters across all shortcut tracks.
    public var detectedShortcutClusters: [ShortcutPressCluster] {
        if let cached = cachedDetectedShortcuts,
           lastShortcutCaptionsConfig == document.captions,
           lastShortcutSlices == document.timeline.slices {
            return cached
        }

        let primaryTrackId = document.captions.shortcutTracks.first?.id ?? "default-shortcuts-track"
        let deletedTelemetrySet = Set(document.captions.deletedShortcutStartMs)
        let timingOverrides = document.captions.shortcutTimingOverrides
        let keyOverrides = document.captions.shortcutKeyOverrides

        var telemetryClusters: [ShortcutPressCluster] = []

        if !keyEvents.isEmpty {
            let allowSingleLetters = document.captions.showSingleKeyShortcuts

            struct NormalizedEvent {
                let raw: KeyStrokeEvent
                let modifiers: [String]
                let primaryKey: String
                var tokenCount: Int { modifiers.count + 1 }
                var signature: String { (modifiers + [primaryKey]).joined(separator: "+") }
            }

            let normalized: [NormalizedEvent] = keyEvents.compactMap { ev in
                guard let key = Self.normalizeKeyToken(from: ev) else { return nil }
                let mods = Self.normalizeModifiers(from: ev.modifiers ?? [])
                return NormalizedEvent(raw: ev, modifiers: mods, primaryKey: key)
            }

            var filtered: [NormalizedEvent] = []
            for i in 0..<normalized.count {
                let curr = normalized[i]
                if curr.modifiers == ["Shift"], curr.primaryKey.count == 1, i + 1 < normalized.count {
                    let next = normalized[i + 1]
                    if next.modifiers.isEmpty && (next.raw.t - curr.raw.t) < 1000.0 {
                        continue
                    }
                }

                if !allowSingleLetters && curr.tokenCount == 1 {
                    guard Self.isAllowedStandaloneSpecialKey(curr.primaryKey) else {
                        continue
                    }
                }
                filtered.append(curr)
            }

            struct RawGroup {
                let modifiers: [String]
                let primaryKey: String
                let signature: String
                var events: [NormalizedEvent]
            }

            var groups: [RawGroup] = []
            for curr in filtered {
                guard let last = groups.last else {
                    groups.append(RawGroup(modifiers: curr.modifiers, primaryKey: curr.primaryKey, signature: curr.signature, events: [curr]))
                    continue
                }

                if allowSingleLetters {
                    let firstOfLast = last.events[0]
                    if firstOfLast.modifiers.isEmpty && curr.modifiers.isEmpty
                        && Self.isAlphaNumericSingleKey(firstOfLast.primaryKey)
                        && Self.isAlphaNumericSingleKey(curr.primaryKey)
                        && (curr.raw.t - firstOfLast.raw.t) < 1000.0 {
                        groups.removeLast()
                        continue
                    }
                }

                let lastEventInGroup = last.events[last.events.count - 1]
                if (curr.raw.t - lastEventInGroup.raw.t) <= 2000.0 && last.signature == curr.signature {
                    groups[groups.count - 1].events.append(curr)
                } else {
                    groups.append(RawGroup(modifiers: curr.modifiers, primaryKey: curr.primaryKey, signature: curr.signature, events: [curr]))
                }
            }

            var rawClusters: [ShortcutPressCluster] = groups.compactMap { g in
                let firstMs = g.events[0].raw.t
                let msInt = Int(round(firstMs))
                guard !deletedTelemetrySet.contains(msInt) else { return nil }

                let lastMs = g.events[g.events.count - 1].raw.t
                var startMs = max(0.0, firstMs - 80.0)
                var endMs = lastMs + 1500.0

                if let overrideSpan = timingOverrides[msInt] {
                    startMs = max(0.0, overrideSpan.x)
                    endMs = max(startMs + 180.0, overrideSpan.y)
                }

                let effectiveMods = keyOverrides[msInt]?.modifiers ?? g.modifiers
                let effectiveKey = keyOverrides[msInt]?.primaryKey ?? g.primaryKey

                return ShortcutPressCluster(
                    id: "telemetry_\(msInt)",
                    trackId: primaryTrackId,
                    isCustomSegment: false,
                    firstKeyDownMsInt: msInt,
                    firstKeyDownMs: firstMs,
                    lastKeyDownMs: lastMs,
                    displayStartMs: startMs,
                    displayEndMs: endMs,
                    modifiers: effectiveMods,
                    primaryKey: effectiveKey,
                    compactTimelineLabel: Self.buildCompactTimelineLabel(modifiers: effectiveMods, primaryKey: effectiveKey),
                    keyCaps: Self.buildKeyCaps(modifiers: effectiveMods, primaryKey: effectiveKey)
                )
            }

            if rawClusters.count >= 2 {
                for i in 0..<(rawClusters.count - 1) {
                    if timingOverrides[rawClusters[i].firstKeyDownMsInt] == nil,
                       timingOverrides[rawClusters[i + 1].firstKeyDownMsInt] == nil {
                        let nextFirst = rawClusters[i + 1].firstKeyDownMs
                        if rawClusters[i].displayEndMs > nextFirst {
                            rawClusters[i].displayEndMs = max(rawClusters[i].firstKeyDownMs + 120.0, nextFirst)
                            rawClusters[i + 1].displayStartMs = rawClusters[i].displayEndMs
                        }
                    }
                }
            }

            telemetryClusters = rawClusters.filter { c in
                document.timeline.slices.contains { slice in
                    min(c.displayEndMs, slice.sourceEndMs) > max(c.displayStartMs, slice.sourceStartMs)
                }
            }
        }

        let customClusters: [ShortcutPressCluster] = document.captions.customShortcuts.compactMap { seg in
            let hasOverlap = document.timeline.slices.contains { slice in
                min(seg.sourceEndMs, slice.sourceEndMs) > max(seg.sourceStartMs, slice.sourceStartMs)
            }
            guard hasOverlap else { return nil }
            let mods = Self.normalizeModifiers(from: seg.modifiers)
            let pKey = seg.primaryKey.isEmpty ? "K" : seg.primaryKey
            return ShortcutPressCluster(
                id: seg.id,
                trackId: seg.trackId,
                isCustomSegment: true,
                firstKeyDownMsInt: Int(round(seg.sourceStartMs)),
                firstKeyDownMs: seg.sourceStartMs,
                lastKeyDownMs: seg.sourceEndMs,
                displayStartMs: seg.sourceStartMs,
                displayEndMs: seg.sourceEndMs,
                modifiers: mods,
                primaryKey: pKey,
                compactTimelineLabel: Self.buildCompactTimelineLabel(modifiers: mods, primaryKey: pKey),
                keyCaps: Self.buildKeyCaps(modifiers: mods, primaryKey: pKey)
            )
        }

        let allCombined = (telemetryClusters + customClusters).sorted {
            if abs($0.displayStartMs - $1.displayStartMs) > 0.01 {
                return $0.displayStartMs < $1.displayStartMs
            }
            return $0.id < $1.id
        }

        // Enforce strict non-overlapping spans within each shortcut track!
        let primaryId = document.captions.shortcutTracks.first?.id ?? "default-shortcuts-track"
        var byTrack: [String: [ShortcutPressCluster]] = [:]
        for c in allCombined {
            let effectiveTrackId = (c.trackId == "default-shortcuts-track") ? primaryId : c.trackId
            byTrack[effectiveTrackId, default: []].append(c)
        }

        var sanitized: [ShortcutPressCluster] = []
        let maxSourceMs = document.timeline.slices.map(\.sourceEndMs).max() ?? metadata.durationMs
        for (_, var list) in byTrack {
            list.sort { $0.displayStartMs < $1.displayStartMs }
            var currentMinStart = 0.0
            for i in 0..<list.count {
                if list[i].displayStartMs < currentMinStart {
                    let dur = max(220.0, list[i].displayEndMs - list[i].displayStartMs)
                    list[i].displayStartMs = currentMinStart
                    list[i].displayEndMs = min(maxSourceMs, currentMinStart + dur)
                }
                if i + 1 < list.count && list[i].displayEndMs > list[i + 1].displayStartMs {
                    let mid = max(list[i].displayStartMs + 220.0, list[i + 1].displayStartMs)
                    list[i].displayEndMs = mid
                }
                if list[i].displayEndMs - list[i].displayStartMs >= 150.0 {
                    currentMinStart = list[i].displayEndMs
                    sanitized.append(list[i])
                }
            }
        }

        let result = sanitized.sorted { $0.displayStartMs < $1.displayStartMs }
        lastShortcutCaptionsConfig = document.captions
        lastShortcutSlices = document.timeline.slices
        cachedDetectedShortcuts = result
        return result
    }

    public func shortcutClusters(forTrackId trackId: String) -> [ShortcutPressCluster] {
        let isPrimary = (trackId == document.captions.shortcutTracks.first?.id)
        return detectedShortcutClusters.filter {
            $0.trackId == trackId || (isPrimary && $0.trackId == "default-shortcuts-track")
        }
    }

    public func isShortcutHidden(_ cluster: ShortcutPressCluster) -> Bool {
        if cluster.isCustomSegment {
            return document.captions.customShortcuts.first(where: { $0.id == cluster.id })?.isHidden ?? false
        }
        return document.captions.hiddenShortcutStartMs.contains(cluster.firstKeyDownMsInt)
    }

    public func toggleShortcutHidden(_ cluster: ShortcutPressCluster) {
        mutate { doc in
            if !doc.captions.showKeystrokes {
                doc.captions.showKeystrokes = true
            }
            if cluster.isCustomSegment {
                if let idx = doc.captions.customShortcuts.firstIndex(where: { $0.id == cluster.id }) {
                    doc.captions.customShortcuts[idx].isHidden.toggle()
                }
            } else {
                if let idx = doc.captions.hiddenShortcutStartMs.firstIndex(of: cluster.firstKeyDownMsInt) {
                    doc.captions.hiddenShortcutStartMs.remove(at: idx)
                } else {
                    doc.captions.hiddenShortcutStartMs.append(cluster.firstKeyDownMsInt)
                }
            }
        }
    }

    public func setEveryShortcutWithSameLabelHidden(_ cluster: ShortcutPressCluster, hidden: Bool) {
        let matching = detectedShortcutClusters.filter { $0.compactTimelineLabel == cluster.compactTimelineLabel }
        mutate { doc in
            for item in matching {
                if item.isCustomSegment {
                    if let idx = doc.captions.customShortcuts.firstIndex(where: { $0.id == item.id }) {
                        doc.captions.customShortcuts[idx].isHidden = hidden
                    }
                } else {
                    if hidden {
                        if !doc.captions.hiddenShortcutStartMs.contains(item.firstKeyDownMsInt) {
                            doc.captions.hiddenShortcutStartMs.append(item.firstKeyDownMsInt)
                        }
                    } else {
                        doc.captions.hiddenShortcutStartMs.removeAll { $0 == item.firstKeyDownMsInt }
                    }
                }
            }
        }
    }

    public func setAllShortcutsHidden(_ hidden: Bool) {
        let all = detectedShortcutClusters
        mutate { doc in
            if hidden {
                doc.captions.hiddenShortcutStartMs = all.filter { !$0.isCustomSegment }.map(\.firstKeyDownMsInt)
                for idx in doc.captions.customShortcuts.indices {
                    doc.captions.customShortcuts[idx].isHidden = true
                }
            } else {
                doc.captions.hiddenShortcutStartMs.removeAll()
                for idx in doc.captions.customShortcuts.indices {
                    doc.captions.customShortcuts[idx].isHidden = false
                }
            }
        }
    }

    public func toggleShortcutsTrackVisibility(trackId: String? = nil) {
        mutate { doc in
            if let trackId, let idx = doc.captions.shortcutTracks.firstIndex(where: { $0.id == trackId }) {
                doc.captions.shortcutTracks[idx].isHidden.toggle()
                if idx == 0 {
                    doc.timeline.isShortcutsTrackHidden = doc.captions.shortcutTracks[0].isHidden
                }
            } else {
                doc.timeline.isShortcutsTrackHidden.toggle()
                if !doc.captions.shortcutTracks.isEmpty {
                    doc.captions.shortcutTracks[0].isHidden = doc.timeline.isShortcutsTrackHidden
                }
            }
        }
    }

    /// Permanently deletes a shortcut segment (either telemetry-recorded or custom-inserted) from the timeline,
    /// and automatically removes the Shortcut track in the same atomic Undo transaction if it has no remaining segments.
    public func deleteShortcut(_ cluster: ShortcutPressCluster) {
        let trackId = cluster.trackId
        let remainingOnTrackCount = shortcutClusters(forTrackId: trackId).filter { $0.id != cluster.id }.count

        mutate { doc in
            if cluster.isCustomSegment {
                doc.captions.customShortcuts.removeAll { $0.id == cluster.id }
            } else {
                if !doc.captions.deletedShortcutStartMs.contains(cluster.firstKeyDownMsInt) {
                    doc.captions.deletedShortcutStartMs.append(cluster.firstKeyDownMsInt)
                }
                doc.captions.hiddenShortcutStartMs.removeAll { $0 == cluster.firstKeyDownMsInt }
                doc.captions.shortcutTimingOverrides.removeValue(forKey: cluster.firstKeyDownMsInt)
                doc.captions.shortcutKeyOverrides.removeValue(forKey: cluster.firstKeyDownMsInt)
            }
            doc.captions.shortcutStyleOverrides.removeValue(forKey: cluster.id)

            // If the track now has 0 shortcut segments left, remove the empty track and renumber remaining tracks in the same Undo step!
            if remainingOnTrackCount == 0 {
                let isPrimary = (trackId == doc.captions.shortcutTracks.first?.id || trackId == "default-shortcuts-track")
                if isPrimary, !doc.captions.shortcutTracks.isEmpty {
                    doc.captions.shortcutTracks.removeFirst()
                } else {
                    doc.captions.shortcutTracks.removeAll { $0.id == trackId }
                }
                for idx in doc.captions.shortcutTracks.indices {
                    doc.captions.shortcutTracks[idx].name = idx == 0 ? "Shortcuts" : "Shortcuts \(idx + 1)"
                }
            }
        }
        if selectedShortcutId == cluster.id {
            selectedShortcutId = nil
        }
    }

    /// Inserts a new custom shortcut segment on the given track (or at the playhead) into the available non-overlapping gap and selects it immediately.
    @discardableResult
    public func addCustomShortcut(
        trackId: String? = nil,
        sourceStartMs: Double? = nil,
        sourceEndMs: Double? = nil,
        modifiers: [String] = ["Meta"],
        primaryKey: String = "K"
    ) -> String {
        let earliestSourceMs = document.timeline.slices.map(\.sourceStartMs).min() ?? 0.0
        let latestSourceMs = document.timeline.slices.map(\.sourceEndMs).max() ?? max(1000.0, metadata.durationMs)
        let targetTrackId = trackId ?? document.captions.shortcutTracks.first?.id ?? "default-shortcuts-track"
        let existing = shortcutClusters(forTrackId: targetTrackId).sorted { $0.displayStartMs < $1.displayStartMs }

        let anchorMs = sourceStartMs ?? currentSourceTimeMs

        // If `anchorMs` is already inside an existing shortcut on this track (when no explicit range was passed),
        // either select it or place the new shortcut in the next available gap after it!
        let prevEnd = existing.last(where: { $0.displayEndMs <= anchorMs + 1.0 })?.displayEndMs ?? earliestSourceMs
        let nextStart = existing.first(where: { $0.displayStartMs >= anchorMs - 1.0 && $0.displayEndMs > anchorMs + 1.0 })?.displayStartMs ?? latestSourceMs

        var start: Double
        var end: Double

        if nextStart - prevEnd >= 300.0 {
            let desiredDur = min(sourceEndMs.map { max(300.0, $0 - (sourceStartMs ?? anchorMs)) } ?? 1600.0, nextStart - prevEnd)
            start = max(prevEnd, min(nextStart - desiredDur, anchorMs))
            end = min(nextStart, start + desiredDur)
        } else if let containingIdx = existing.firstIndex(where: { anchorMs >= $0.displayStartMs && anchorMs <= $0.displayEndMs }) {
            // Find the gap right after `containing`
            let cont = existing[containingIdx]
            let gapStart = cont.displayEndMs
            let gapEnd = (containingIdx + 1 < existing.count) ? existing[containingIdx + 1].displayStartMs : latestSourceMs
            if gapEnd - gapStart >= 300.0 {
                start = gapStart
                end = min(gapEnd, gapStart + 1500.0)
            } else {
                selectShortcut(cont.id)
                scrollToTimelineTrack("track_shortcut_\(targetTrackId)")
                return cont.id
            }
        } else {
            return ""
        }

        let newSeg = CustomShortcutSegment(
            id: UUID().uuidString,
            trackId: targetTrackId,
            sourceStartMs: start,
            sourceEndMs: end,
            modifiers: modifiers,
            primaryKey: primaryKey,
            isHidden: false,
            customStyle: nil
        )
        mutate { doc in
            doc.captions.showKeystrokes = true
            if !doc.captions.shortcutTracks.contains(where: { $0.id == targetTrackId }) {
                let nextIdx = doc.captions.shortcutTracks.count + 1
                doc.captions.shortcutTracks.append(
                    ShortcutTrackConfig(
                        id: targetTrackId,
                        name: nextIdx == 1 ? "Shortcuts" : "Shortcuts \(nextIdx)",
                        isHidden: false,
                        style: doc.captions.defaultShortcutStyle
                    )
                )
            }
            doc.captions.customShortcuts.append(newSeg)
        }
        selectShortcut(newSeg.id)
        scrollToTimelineTrack("track_shortcut_\(targetTrackId)")
        return newSeg.id
    }

    /// Duplicates an existing shortcut segment right after it on the same track (or splits it in half if touching the next segment, matching `duplicateZoom`!).
    public func duplicateShortcut(_ cluster: ShortcutPressCluster) {
        let latestSourceMs = document.timeline.slices.map(\.sourceEndMs).max() ?? max(1000.0, metadata.durationMs)
        let sorted = shortcutClusters(forTrackId: cluster.trackId).sorted { $0.displayStartMs < $1.displayStartMs }
        guard let sortedIdx = sorted.firstIndex(where: { $0.id == cluster.id }) else { return }

        let orig = sorted[sortedIdx]
        let nextStart = (sortedIdx + 1 < sorted.count) ? sorted[sortedIdx + 1].displayStartMs : latestSourceMs
        let availAfter = nextStart - orig.displayEndMs
        let origDur = max(300.0, orig.displayEndMs - orig.displayStartMs)
        let customStyle = document.captions.shortcutStyleOverrides[cluster.id]
            ?? (cluster.isCustomSegment ? document.captions.customShortcuts.first(where: { $0.id == cluster.id })?.customStyle : nil)

        if availAfter >= 300.0 {
            let start = orig.displayEndMs
            let end = min(nextStart, start + origDur)
            let copy = CustomShortcutSegment(
                id: UUID().uuidString,
                trackId: cluster.trackId,
                sourceStartMs: start,
                sourceEndMs: end,
                modifiers: cluster.modifiers,
                primaryKey: cluster.primaryKey,
                isHidden: false,
                customStyle: customStyle
            )
            mutate { doc in
                doc.captions.customShortcuts.append(copy)
            }
            selectShortcut(copy.id)
            scrollToTimelineTrack("track_shortcut_\(cluster.trackId)")
        } else if origDur >= 500.0 {
            // Split the original segment in half at `mid` so the duplicate sits cleanly beside it with zero overlap!
            let mid = (orig.displayStartMs + orig.displayEndMs) * 0.5
            let copy = CustomShortcutSegment(
                id: UUID().uuidString,
                trackId: cluster.trackId,
                sourceStartMs: mid,
                sourceEndMs: orig.displayEndMs,
                modifiers: cluster.modifiers,
                primaryKey: cluster.primaryKey,
                isHidden: false,
                customStyle: customStyle
            )
            mutate { doc in
                if orig.isCustomSegment {
                    if let idx = doc.captions.customShortcuts.firstIndex(where: { $0.id == orig.id }) {
                        doc.captions.customShortcuts[idx].sourceEndMs = mid
                    }
                } else {
                    doc.captions.shortcutTimingOverrides[orig.firstKeyDownMsInt] = Point01(x: orig.displayStartMs, y: mid)
                }
                doc.captions.customShortcuts.append(copy)
            }
            selectShortcut(copy.id)
            scrollToTimelineTrack("track_shortcut_\(cluster.trackId)")
        }
    }

    /// Adds a new Shortcut Track (with a distinct default position like Bottom / Top / Left / Right) and scrolls the timeline to it.
    @discardableResult
    public func addShortcutTrack() -> String {
        let nextIndex = document.captions.shortcutTracks.count + 1
        let defaultPositions: [ShortcutDockPosition] = [.bottom, .top, .left, .right]
        let chosenPos = defaultPositions[(nextIndex - 1) % defaultPositions.count]
        let newTrack = ShortcutTrackConfig(
            id: UUID().uuidString,
            name: nextIndex == 1 ? "Shortcuts" : "Shortcuts \(nextIndex)",
            isHidden: false,
            style: ShortcutStyleConfig(dockPosition: chosenPos)
        )
        mutate { doc in
            doc.captions.showKeystrokes = true
            doc.captions.shortcutTracks.append(newTrack)
        }
        selectedShortcutId = nil
        selectedInspectorTab = .shortcuts
        scrollToTimelineTrack("track_shortcut_\(newTrack.id)")
        return newTrack.id
    }

    public func removeShortcutTrack(id: String) {
        mutate { doc in
            doc.captions.shortcutTracks.removeAll { $0.id == id }
            doc.captions.customShortcuts.removeAll { $0.trackId == id }
            for idx in doc.captions.shortcutTracks.indices {
                doc.captions.shortcutTracks[idx].name = idx == 0 ? "Shortcuts" : "Shortcuts \(idx + 1)"
            }
        }
    }

    /// Moves a Shortcut segment horizontally while strictly preserving its exact `durationMs` and clamping against adjacent neighbors on the same track (0ms overlap!).
    public func moveShortcut(_ cluster: ShortcutPressCluster, desiredStartMs: Double, durationMs: Double) {
        let earliestSourceMs = document.timeline.slices.map(\.sourceStartMs).min() ?? 0.0
        let latestSourceMs = document.timeline.slices.map(\.sourceEndMs).max() ?? max(500.0, metadata.durationMs)
        let span = max(220.0, durationMs)

        let sorted = shortcutClusters(forTrackId: cluster.trackId).sorted { $0.displayStartMs < $1.displayStartMs }
        guard let sortedIdx = sorted.firstIndex(where: { $0.id == cluster.id }) else { return }

        let lowerBound = sortedIdx > 0
            ? max(earliestSourceMs, sorted[sortedIdx - 1].displayEndMs)
            : earliestSourceMs
        let upperBound = sortedIdx + 1 < sorted.count
            ? min(latestSourceMs, sorted[sortedIdx + 1].displayStartMs)
            : latestSourceMs
        guard upperBound - lowerBound >= span else { return }

        let clampedStart = max(lowerBound, min(upperBound - span, desiredStartMs))
        let clampedEnd = clampedStart + span

        if cluster.isCustomSegment {
            if let idx = document.captions.customShortcuts.firstIndex(where: { $0.id == cluster.id }) {
                document.captions.customShortcuts[idx].sourceStartMs = clampedStart
                document.captions.customShortcuts[idx].sourceEndMs = clampedEnd
            }
        } else {
            document.captions.shortcutTimingOverrides[cluster.firstKeyDownMsInt] = Point01(x: clampedStart, y: clampedEnd)
        }
        renderRevision &+= 1
    }

    /// Resizes ONLY the left/start or right/end edge of a Shortcut segment while clamping against adjacent neighbors on the same track (0ms overlap!).
    public func resizeShortcut(_ cluster: ShortcutPressCluster, newStartMs: Double, newEndMs: Double) {
        let earliestSourceMs = document.timeline.slices.map(\.sourceStartMs).min() ?? 0.0
        let latestSourceMs = document.timeline.slices.map(\.sourceEndMs).max() ?? max(500.0, metadata.durationMs)
        let minDuration = 220.0

        let sorted = shortcutClusters(forTrackId: cluster.trackId).sorted { $0.displayStartMs < $1.displayStartMs }
        guard let sortedIdx = sorted.firstIndex(where: { $0.id == cluster.id }) else { return }

        let lowerBound = sortedIdx > 0
            ? max(earliestSourceMs, sorted[sortedIdx - 1].displayEndMs)
            : earliestSourceMs
        let upperBound = sortedIdx + 1 < sorted.count
            ? min(latestSourceMs, sorted[sortedIdx + 1].displayStartMs)
            : latestSourceMs
        guard upperBound - lowerBound >= minDuration else { return }

        let current = sorted[sortedIdx]
        let isResizingLeft = abs(newEndMs - current.displayEndMs) < 0.5

        let s: Double
        let e: Double
        if isResizingLeft {
            e = current.displayEndMs
            s = max(lowerBound, min(e - minDuration, newStartMs))
        } else {
            s = current.displayStartMs
            e = max(s + minDuration, min(upperBound, newEndMs))
        }

        if cluster.isCustomSegment {
            if let idx = document.captions.customShortcuts.firstIndex(where: { $0.id == cluster.id }) {
                document.captions.customShortcuts[idx].sourceStartMs = s
                document.captions.customShortcuts[idx].sourceEndMs = e
            }
        } else {
            document.captions.shortcutTimingOverrides[cluster.firstKeyDownMsInt] = Point01(x: s, y: e)
        }
        renderRevision &+= 1
    }

    public func moveShortcutToTrack(_ cluster: ShortcutPressCluster, targetTrackIndex: Int) {
        let tracks = document.captions.shortcutTracks
        guard targetTrackIndex >= 0 && targetTrackIndex < tracks.count else { return }
        let targetTrackId = tracks[targetTrackIndex].id
        guard targetTrackId != cluster.trackId else { return }

        mutate { doc in
            if cluster.isCustomSegment {
                if let idx = doc.captions.customShortcuts.firstIndex(where: { $0.id == cluster.id }) {
                    doc.captions.customShortcuts[idx].trackId = targetTrackId
                }
            } else {
                // Convert telemetry cluster to a custom segment on the target track and mark original telemetry key as moved/deleted
                if !doc.captions.deletedShortcutStartMs.contains(cluster.firstKeyDownMsInt) {
                    doc.captions.deletedShortcutStartMs.append(cluster.firstKeyDownMsInt)
                }
                let customSeg = CustomShortcutSegment(
                    id: UUID().uuidString,
                    trackId: targetTrackId,
                    sourceStartMs: cluster.displayStartMs,
                    sourceEndMs: cluster.displayEndMs,
                    modifiers: cluster.modifiers,
                    primaryKey: cluster.primaryKey,
                    isHidden: false,
                    customStyle: doc.captions.shortcutStyleOverrides[cluster.id]
                )
                doc.captions.customShortcuts.append(customSeg)
                selectedShortcutId = customSeg.id
            }
        }
    }

    public func updateShortcutKeys(for cluster: ShortcutPressCluster, modifiers: [String], primaryKey: String) {
        let canonicalMods = Self.normalizeModifiers(from: modifiers)
        let cleanKey = primaryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "K" : primaryKey.trimmingCharacters(in: .whitespacesAndNewlines)

        mutate { doc in
            if cluster.isCustomSegment {
                if let idx = doc.captions.customShortcuts.firstIndex(where: { $0.id == cluster.id }) {
                    doc.captions.customShortcuts[idx].modifiers = canonicalMods
                    doc.captions.customShortcuts[idx].primaryKey = cleanKey
                }
            } else {
                doc.captions.shortcutKeyOverrides[cluster.firstKeyDownMsInt] = CustomShortcutSegment(
                    id: cluster.id,
                    trackId: cluster.trackId,
                    sourceStartMs: cluster.displayStartMs,
                    sourceEndMs: cluster.displayEndMs,
                    modifiers: canonicalMods,
                    primaryKey: cleanKey
                )
            }
        }
    }

    /// Resolves the effective `ShortcutStyleConfig` (position, offsetX/Y, solid/gradient keycap colors) for a given shortcut segment.
    public func effectiveShortcutStyle(for cluster: ShortcutPressCluster) -> ShortcutStyleConfig {
        if let segOverride = document.captions.shortcutStyleOverrides[cluster.id] {
            return segOverride
        }
        if cluster.isCustomSegment,
           let customSeg = document.captions.customShortcuts.first(where: { $0.id == cluster.id }),
           let customStyle = customSeg.customStyle {
            return customStyle
        }
        if let track = document.captions.shortcutTracks.first(where: { $0.id == cluster.trackId }) {
            return track.style
        }
        return document.captions.shortcutTracks.first?.style ?? document.captions.defaultShortcutStyle
    }

    /// Returns all active, non-hidden `ShortcutPressCluster` items (one per visible track) at `sourceMs` with their resolved styles.
    public func activeShortcutClustersWithStyles(atSourceMs sourceMs: Double) -> [(cluster: ShortcutPressCluster, style: ShortcutStyleConfig)] {
        guard document.captions.showKeystrokes else { return [] }
        var results: [(cluster: ShortcutPressCluster, style: ShortcutStyleConfig)] = []

        for (index, track) in document.captions.shortcutTracks.enumerated() {
            if track.isHidden || (index == 0 && document.timeline.isShortcutsTrackHidden) {
                continue
            }
            let trackClusters = shortcutClusters(forTrackId: track.id)
            var candidate: ShortcutPressCluster?
            for cluster in trackClusters where !isShortcutHidden(cluster) {
                if cluster.displayStartMs > sourceMs {
                    break
                }
                candidate = cluster
            }
            if let match = candidate, sourceMs >= match.displayStartMs && sourceMs <= match.displayEndMs {
                results.append((match, effectiveShortcutStyle(for: match)))
            }
        }
        return results
    }

    /// Returns the primary active, non-hidden `ShortcutPressCluster` at `sourceMs`.
    public func activeShortcutCluster(atSourceMs sourceMs: Double) -> ShortcutPressCluster? {
        return activeShortcutClustersWithStyles(atSourceMs: sourceMs).first?.cluster
    }

    // MARK: - Shortcut Normalization & Keycap Helpers

    private static func normalizeModifiers(from rawMods: [String]) -> [String] {
        var set = Set<String>()
        for m in rawMods {
            switch m.lowercased() {
            case "capslock": set.insert("CapsLock")
            case "meta", "cmd", "command": set.insert("Meta")
            case "shift": set.insert("Shift")
            case "alt", "opt", "option": set.insert("Alt")
            case "ctrl", "control": set.insert("Ctrl")
            default: break
            }
        }
        // Canonical order:
        let order = ["CapsLock", "Meta", "Shift", "Alt", "Ctrl"]
        return order.filter { set.contains($0) }
    }

    private static func normalizeKeyToken(from ev: KeyStrokeEvent) -> String? {
        if let k = ev.key, !k.isEmpty {
            if k == " " { return "Space" }
            return k
        }
        return nil
    }

    private static func isAllowedStandaloneSpecialKey(_ key: String) -> Bool {
        switch key {
        case "CapsLock", "Backspace", "Delete", "ForwardDelete",
             "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
             "Home", "End", "PageUp", "PageDown",
             "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12":
            return true
        default:
            return false
        }
    }

    private static func isAlphaNumericSingleKey(_ key: String) -> Bool {
        guard key.count == 1, let scalar = key.unicodeScalars.first else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private static func buildCompactTimelineLabel(modifiers: [String], primaryKey: String) -> String {
        // Note: timeline order is `["Meta", "Shift", "Alt", "Ctrl"]` (or `⌥ ⌃` as shown in)
        let modSymbols: [String] = modifiers.map { mod in
            switch mod {
            case "Meta": return "⌘"
            case "Shift": return "⇧"
            case "Alt": return "⌥"
            case "Ctrl": return "⌃"
            case "CapsLock": return "⇪"
            default: return mod
            }
        }
        let keySymbol: String = {
            switch primaryKey {
            case "Delete", "Backspace": return "⌫"
            case "ForwardDelete": return "⌦"
            case "Enter": return "⏎"
            case "Tab": return "⇥"
            case "Escape": return "Esc"
            case "Space", " ": return "Space"
            case "ArrowUp": return "↑"
            case "ArrowDown": return "↓"
            case "ArrowLeft": return "←"
            case "ArrowRight": return "→"
            default: return primaryKey.uppercased()
            }
        }()
        return (modSymbols + [keySymbol]).joined(separator: " ")
    }

    private static func buildKeyCaps(modifiers: [String], primaryKey: String) -> [ShortcutKeyCap] {
        var caps: [ShortcutKeyCap] = modifiers.map { mod in
            switch mod {
            case "Meta":
                return ShortcutKeyCap(key: mod, widthRatio: 1.33, symbol: "⌘", label: "command", labelPlacement: .bottomLeft)
            case "Alt":
                return ShortcutKeyCap(key: mod, widthRatio: 1.33, symbol: "⌥", label: "option", labelPlacement: .bottomLeft)
            case "Ctrl":
                return ShortcutKeyCap(key: mod, widthRatio: 1.33, symbol: "⌃", label: "control", labelPlacement: .bottomLeft)
            case "Shift":
                return ShortcutKeyCap(key: mod, widthRatio: 1.33, symbol: "⇧", label: "shift", labelPlacement: .bottomLeft)
            case "CapsLock":
                return ShortcutKeyCap(key: mod, widthRatio: 1.33, symbol: "⇪", label: "caps lock", labelPlacement: .bottomLeft)
            default:
                return ShortcutKeyCap(key: mod, widthRatio: 1.33, symbol: nil, label: mod.lowercased(), labelPlacement: .center)
            }
        }

        let primaryCap: ShortcutKeyCap = {
            switch primaryKey {
            case "Space", " ":
                return ShortcutKeyCap(key: "Space", widthRatio: 1.66, symbol: "␣", label: "space", labelPlacement: .bottomCenter)
            case "Delete", "Backspace":
                return ShortcutKeyCap(key: "Delete", widthRatio: 1.33, symbol: "⌫", label: "delete", labelPlacement: .bottomLeft)
            case "ForwardDelete":
                return ShortcutKeyCap(key: "ForwardDelete", widthRatio: 1.33, symbol: "⌦", label: "delete", labelPlacement: .bottomLeft)
            case "Tab":
                return ShortcutKeyCap(key: "Tab", widthRatio: 1.33, symbol: "⇥", label: "tab", labelPlacement: .bottomLeft)
            case "Escape":
                return ShortcutKeyCap(key: "Escape", widthRatio: 1.33, symbol: "⎋", label: "esc", labelPlacement: .bottomLeft)
            case "Enter":
                return ShortcutKeyCap(key: "Enter", widthRatio: 1.33, symbol: nil, label: "⏎", labelPlacement: .center)
            case "ArrowUp":
                return ShortcutKeyCap(key: "ArrowUp", widthRatio: 1.0, symbol: nil, label: "↑", labelPlacement: .center)
            case "ArrowDown":
                return ShortcutKeyCap(key: "ArrowDown", widthRatio: 1.0, symbol: nil, label: "↓", labelPlacement: .center)
            case "ArrowLeft":
                return ShortcutKeyCap(key: "ArrowLeft", widthRatio: 1.0, symbol: nil, label: "←", labelPlacement: .center)
            case "ArrowRight":
                return ShortcutKeyCap(key: "ArrowRight", widthRatio: 1.0, symbol: nil, label: "→", labelPlacement: .center)
            default:
                return ShortcutKeyCap(key: primaryKey, widthRatio: 1.0, symbol: nil, label: primaryKey.uppercased(), labelPlacement: .center)
            }
        }()
        caps.append(primaryCap)
        return caps
    }

    // MARK: - Camera, Microphone, Local On-Device Captions & Edit-by-Transcript Engine

    public var webcamVideoFileURL: URL? {
        let recordingDir = packageURL.appendingPathComponent("recording", isDirectory: true)
        if let rel = metadata.tracks.webcamVideo {
            let candidate = recordingDir.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let defaultURL = recordingDir.appendingPathComponent("webcam.mp4")
        return FileManager.default.fileExists(atPath: defaultURL.path) ? defaultURL : nil
    }

    public var microphoneAudioFileURL: URL? {
        let recordingDir = packageURL.appendingPathComponent("recording", isDirectory: true)
        if let rel = metadata.tracks.microphoneAudio {
            let candidate = recordingDir.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let defaultURL = recordingDir.appendingPathComponent("microphone.m4a")
        return FileManager.default.fileExists(atPath: defaultURL.path) ? defaultURL : nil
    }

    public var hasRecordedCamera: Bool {
        metadata.tracks.webcamVideo != nil || webcamVideoFileURL != nil
    }

    public var hasRecordedMicrophone: Bool {
        metadata.tracks.microphoneAudio != nil || microphoneAudioFileURL != nil || !document.captions.segments.isEmpty
    }

    /// Evaluates whether a sidebar tab can be opened and returns the exact disabled tooltip reason.
    public func inspectorTabAvailability(_ tab: InspectorTab) -> (canApply: Bool, disabledTooltip: String?) {
        switch tab {
        case .background:
            return (true, nil)
        case .cursor:
            let hasCursor = !cursorEvents.isEmpty
            return (hasCursor, hasCursor ? nil : "There is no mouse cursor recorded")
        case .cameraLayout:
            return (hasRecordedCamera, hasRecordedCamera ? nil : "No camera recorded")
        case .cameraStyle:
            if !hasRecordedCamera {
                return (false, "No camera recorded")
            }
            if !document.camera.enabled {
                return (false, "Camera is hidden (see Camera Layout)")
            }
            return (true, nil)
        case .captions:
            return (true, nil)
        case .transcript:
            return (hasRecordedMicrophone, hasRecordedMicrophone ? nil : "No microphone recorded")
        case .audio:
            return (true, nil)
        case .shortcuts:
            let hasShortcuts = !keyEvents.isEmpty || !document.captions.customShortcuts.isEmpty || !document.captions.shortcutTracks.isEmpty
            return (hasShortcuts, hasShortcuts ? nil : "No keyboard shortcuts during recording")
        case .zoom:
            return (true, nil)
        case .deviceFrame:
            return (true, nil)
        case .masks:
            return (true, nil)
        }
    }

    /// Generates a word-level transcript on-device, and shows why if it cannot.
    public func generateLocalOnDeviceTranscript() {
        guard !isGeneratingTranscript else { return }

        isGeneratingTranscript = true
        transcriptErrorMessage = nil

        let audioSourceURL = microphoneAudioFileURL ?? videoFileURL
        let localeId = document.captions.transcriptLocale
        let promptWords = document.captions.customPrompt
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let fallbackDur = metadata.durationMs

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let generated = try await LocalOnDeviceMediaIntelligence.transcribeAudioFileOnDevice(
                    audioURL: audioSourceURL,
                    localeIdentifier: localeId,
                    customPromptWords: promptWords,
                    maxDurationMs: fallbackDur
                )
                self.selectedCaptionId = nil
                self.mutate { doc in
                    doc.captions.segments = generated
                    doc.captions.rebuildTranscriptCaptionBlocks()
                    doc.captions.enabled = true
                }
            } catch {
                self.transcriptErrorMessage = error.localizedDescription
            }
            self.isGeneratingTranscript = false
        }
    }

    /// Checks whether a given `[sourceStartMs, sourceEndMs]` word span is present in at least one active `ClipSlice`.
    public func isSourceRangePresentInSlices(startMs: Double, endMs: Double) -> Bool {
        document.timeline.slices.contains { slice in
            min(endMs, slice.sourceEndMs) > max(startMs, slice.sourceStartMs) + 15.0
        }
    }

    /// Returns all present filler-word segments (`"um"`, `"uh"`, etc.) that haven't been cut from the video yet.
    public var presentFillerWordSegments: [CaptionSegment] {
        document.captions.segments.filter { seg in
            LocalOnDeviceMediaIntelligence.isFillerWord(seg.text)
                && isSourceRangePresentInSlices(startMs: seg.sourceStartMs, endMs: seg.sourceEndMs)
        }
    }

    /// Evaluates whether the camera should be hidden at `sourceMs` due to `Hide during silence` (`hideDuringSilenceMs`),
    /// checking both transcript inter-word gaps (when a transcript exists) and recorded audio waveform envelopes
    /// (with a safe `count >= 2` guard so `0..<(segs.count - 1)` can NEVER crash when `segs` is empty!).
    public func isCameraHiddenDuringSilence(atSourceMs sourceMs: Double) -> Bool {
        guard let minSilenceMs = document.camera.hideDuringSilenceMs, minSilenceMs > 100.0 else {
            return false
        }

        // 1. Check transcript inter-word gaps when >= 2 caption segments exist
        let segs = sortedCaptionSegments()
        if segs.count >= 2 {
            for i in 0..<(segs.count - 1) {
                let gapStart = segs[i].sourceEndMs
                let gapEnd = segs[i + 1].sourceStartMs
                if (gapEnd - gapStart) >= minSilenceMs && sourceMs >= gapStart + 150.0 && sourceMs <= gapEnd - 150.0 {
                    return true
                }
            }
            return false
        }

        // 2. Fallback when no transcript has been generated yet: check `microphoneWaveformSamples` (or `audioWaveformSamples`)
        let waveform = !microphoneWaveformSamples.isEmpty ? microphoneWaveformSamples : audioWaveformSamples
        let totalMs = max(1.0, metadata.durationMs)
        guard waveform.count >= 8, totalMs > minSilenceMs else { return false }

        let msPerBin = totalMs / Double(waveform.count)
        let currentBin = max(0, min(waveform.count - 1, Int(sourceMs / msPerBin)))
        let silenceThreshold: Float = 0.08
        guard waveform[currentBin] < silenceThreshold else { return false }

        var startBin = currentBin
        while startBin > 0 && waveform[startBin - 1] < silenceThreshold {
            startBin -= 1
        }
        var endBin = currentBin
        while endBin + 1 < waveform.count && waveform[endBin + 1] < silenceThreshold {
            endBin += 1
        }

        let silentRunStartMs = Double(startBin) * msPerBin
        let silentRunEndMs = Double(endBin + 1) * msPerBin
        if (silentRunEndMs - silentRunStartMs) >= minSilenceMs
            && sourceMs >= silentRunStartMs + 150.0
            && sourceMs <= silentRunEndMs - 150.0 {
            return true
        }
        return false
    }

    /// Returns all inter-word silence pauses `>= 800ms` that are still present in the timeline slices and can be tightened.
    public var tightenablePauseRangesMs: [(startMs: Double, endMs: Double)] {
        let segs = document.captions.segments.sorted { $0.sourceStartMs < $1.sourceStartMs }
        guard segs.count >= 2 else { return [] }
        var pauses: [(startMs: Double, endMs: Double)] = []
        for i in 0..<(segs.count - 1) {
            let gapStart = segs[i].sourceEndMs
            let gapEnd = segs[i + 1].sourceStartMs
            if gapEnd - gapStart >= 800.0 && isSourceRangePresentInSlices(startMs: gapStart + 100.0, endMs: gapEnd - 100.0) {
                pauses.append((gapStart, gapEnd))
            }
        }
        return pauses
    }

    /// Cuts every detected filler word (`"um"`, `"uh"`, ...) out of `document.timeline.slices` in a single atomic Undo step.
    public func removeAllFillerWordsFromTranscript() {
        let fillers = presentFillerWordSegments
        guard !fillers.isEmpty else { return }
        mutate { doc in
            for filler in fillers.reversed() {
                Self.cutSourceIntervalFromSlices(
                    in: &doc,
                    cutStartMs: max(0.0, filler.sourceStartMs - 25.0),
                    cutEndMs: min(metadata.durationMs, filler.sourceEndMs + 25.0)
                )
            }
        }
    }

    /// Shortens every long pause (`>= 800ms`) down to a natural `200ms` breath (`100ms` on each side) in a single atomic Undo step.
    public func tightenAllPausesInTranscript() {
        let pauses = tightenablePauseRangesMs
        guard !pauses.isEmpty else { return }
        mutate { doc in
            for pause in pauses.reversed() {
                let trimStart = pause.startMs + 100.0
                let trimEnd = pause.endMs - 100.0
                if trimEnd > trimStart + 120.0 {
                    Self.cutSourceIntervalFromSlices(in: &doc, cutStartMs: trimStart, cutEndMs: trimEnd)
                }
            }
        }
    }

    /// Cuts a single word or pause `[cutStartMs, cutEndMs]` from the video slices (`⌫` / `Cut video` in `Edit by transcript`).
    public func cutTranscriptRangeFromVideo(startMs: Double, endMs: Double) {
        guard endMs > startMs + 40.0 else { return }
        mutate { doc in
            Self.cutSourceIntervalFromSlices(in: &doc, cutStartMs: startMs, cutEndMs: endMs)
        }
    }

    /// Restores a previously cut word or pause back into `document.timeline.slices` and unhides it from captions (`Restore` in `Edit by transcript`).
    public func restoreTranscriptRangeToVideo(startMs: Double, endMs: Double, segmentId: String? = nil) {
        mutate { doc in
            if let segId = segmentId,
               let idx = doc.captions.segments.firstIndex(where: { $0.id == segId }) {
                doc.captions.segments[idx].isHidden = false
            }
            Self.restoreSourceIntervalIntoSlices(in: &doc, restoreStartMs: startMs, restoreEndMs: endMs, maxDurationMs: metadata.durationMs)
        }
    }

    public func toggleCaptionWordHidden(id: String) {
        mutate { doc in
            if let idx = doc.captions.segments.firstIndex(where: { $0.id == id }) {
                doc.captions.segments[idx].isHidden.toggle()
            }
        }
    }

    public func updateCaptionWordText(id: String, newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate { doc in
            if let idx = doc.captions.segments.firstIndex(where: { $0.id == id }) {
                doc.captions.segments[idx].text = trimmed
            }
        }
    }

    public func exportTranscriptAsSRT() {
        let srtContent = LocalOnDeviceMediaIntelligence.formatSRT(
            segments: document.captions.segments,
            timeMapper: timeMapper
        )
        guard !srtContent.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = String(localized: "Export Transcript (.srt)")
        panel.message = String(localized: "Where to save the transcript?")
        panel.nameFieldStringValue = "\(document.name).srt"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let outURL = panel.url {
            try? srtContent.write(to: outURL, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([outURL])
        }
    }

    private static func cutSourceIntervalFromSlices(
        in doc: inout ProjectDocument,
        cutStartMs: Double,
        cutEndMs: Double
    ) {
        let minSliceDur = 150.0
        var updated: [ClipSlice] = []

        for slice in doc.timeline.slices {
            if cutEndMs <= slice.sourceStartMs || cutStartMs >= slice.sourceEndMs {
                updated.append(slice)
                continue
            }
            let leftDur = cutStartMs - slice.sourceStartMs
            let rightDur = slice.sourceEndMs - cutEndMs

            if leftDur >= minSliceDur && rightDur >= minSliceDur {
                var left = slice
                left.id = UUID().uuidString
                left.sourceEndMs = cutStartMs
                var right = slice
                right.id = UUID().uuidString
                right.sourceStartMs = cutEndMs
                updated.append(left)
                updated.append(right)
            } else if leftDur >= minSliceDur {
                var trimmed = slice
                trimmed.sourceEndMs = cutStartMs
                updated.append(trimmed)
            } else if rightDur >= minSliceDur {
                var trimmed = slice
                trimmed.sourceStartMs = cutEndMs
                updated.append(trimmed)
            }
        }

        // Never allow deleting 100% of the video
        if !updated.isEmpty {
            doc.timeline.slices = updated
        }
    }

    private static func restoreSourceIntervalIntoSlices(
        in doc: inout ProjectDocument,
        restoreStartMs: Double,
        restoreEndMs: Double,
        maxDurationMs: Double
    ) {
        let start = max(0.0, restoreStartMs)
        let end = min(maxDurationMs, restoreEndMs)
        guard end > start + 40.0 else { return }

        var slices = doc.timeline.slices.sorted { $0.sourceStartMs < $1.sourceStartMs }
        // Try extending an adjacent slice or bridging two split slices across `[start, end]`
        if let prevIdx = slices.lastIndex(where: { $0.sourceEndMs <= start + 120.0 }) {
            if prevIdx + 1 < slices.count && slices[prevIdx + 1].sourceStartMs <= end + 120.0 {
                // Merge `prevIdx` and `prevIdx + 1` across the restored range!
                slices[prevIdx].sourceEndMs = slices[prevIdx + 1].sourceEndMs
                slices.remove(at: prevIdx + 1)
                doc.timeline.slices = slices
                return
            } else {
                slices[prevIdx].sourceEndMs = max(slices[prevIdx].sourceEndMs, end)
                doc.timeline.slices = slices
                return
            }
        }
        if let nextIdx = slices.firstIndex(where: { $0.sourceStartMs >= end - 120.0 }) {
            slices[nextIdx].sourceStartMs = min(slices[nextIdx].sourceStartMs, start)
            doc.timeline.slices = slices
        }
    }

    // MARK: - AI Sensitive Data OCR (`VNRecognizeTextRequest`) & Face Blur (`VNDetectFaceRectanglesRequest`)

    public func setHideSensitiveData(enabled: Bool) {
        mutate { doc in
            doc.background.hideSensitiveData = enabled
            if !enabled {
                for tIdx in doc.timeline.maskTracks.indices {
                    doc.timeline.maskTracks[tIdx].items.removeAll { $0.isAutoSensitiveMask }
                }
            }
        }
        if enabled {
            rescanSensitiveDataMasks()
        }
    }

    public func updateSensitiveDataCustomPhrases(_ rawCommaString: String) {
        let phrases = rawCommaString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        mutate { doc in
            doc.background.sensitiveDataCustomPhrases = phrases
        }
        if document.background.hideSensitiveData {
            rescanSensitiveDataMasks()
        }
    }

    public func rescanSensitiveDataMasks() {
        guard !isScanningSensitiveData else { return }
        isScanningSensitiveData = true
        let url = videoFileURL
        let durMs = metadata.durationMs
        let phrases = document.background.sensitiveDataCustomPhrases

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let detected = await LocalOnDeviceMediaIntelligence.detectSensitiveDataMasks(
                videoURL: url,
                durationMs: durMs,
                customPhrases: phrases
            )
            self.isScanningSensitiveData = false
            guard self.document.background.hideSensitiveData else { return }

            self.mutate { doc in
                for tIdx in doc.timeline.maskTracks.indices {
                    doc.timeline.maskTracks[tIdx].items.removeAll { $0.isAutoSensitiveMask }
                }
                if !detected.isEmpty {
                    let newTrack = MaskTrack(
                        name: doc.timeline.maskTracks.isEmpty ? "Masks" : "Masks \(doc.timeline.maskTracks.count + 1)",
                        isHidden: false,
                        items: detected
                    )
                    doc.timeline.maskTracks.append(newTrack)
                }
            }
        }
    }

    public func setHideFaces(enabled: Bool) {
        mutate { doc in
            doc.background.hideFaces = enabled
            if !enabled {
                for tIdx in doc.timeline.maskTracks.indices {
                    doc.timeline.maskTracks[tIdx].items.removeAll { $0.isAutoFaceMask }
                }
            }
        }
        if enabled {
            rescanFaceMasks()
        }
    }

    public func rescanFaceMasks() {
        guard !isScanningFaces else { return }
        isScanningFaces = true
        let url = videoFileURL
        let durMs = metadata.durationMs

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let detected = await LocalOnDeviceMediaIntelligence.detectFaceMasks(
                videoURL: url,
                durationMs: durMs
            )
            self.isScanningFaces = false
            guard self.document.background.hideFaces else { return }

            self.mutate { doc in
                for tIdx in doc.timeline.maskTracks.indices {
                    doc.timeline.maskTracks[tIdx].items.removeAll { $0.isAutoFaceMask }
                }
                if !detected.isEmpty {
                    let newTrack = MaskTrack(
                        name: doc.timeline.maskTracks.isEmpty ? "Masks" : "Masks \(doc.timeline.maskTracks.count + 1)",
                        isHidden: false,
                        items: detected
                    )
                    doc.timeline.maskTracks.append(newTrack)
                }
            }
        }
    }

    // MARK: - Camera Layouts Track Actions

    public func activeCameraLayoutSegment(atSourceMs sourceMs: Double) -> CameraLayoutSegment? {
        guard !document.timeline.isCameraLayoutsTrackHidden else { return nil }
        return document.timeline.cameraLayouts.first { seg in
            !seg.disabled && sourceMs >= seg.sourceStartMs && sourceMs <= seg.sourceEndMs
        }
    }

    public func toggleCameraLayoutsTrackVisibility() {
        mutate { doc in
            doc.timeline.isCameraLayoutsTrackHidden.toggle()
        }
    }

    public func addCameraLayoutAtPlayhead(type: CameraTimelineLayoutType = .cameraOverlay) {
        let srcMs = committedSourceTimeMs
        let maxDur = metadata.durationMs
        let sorted = document.timeline.cameraLayouts.sorted { $0.sourceStartMs < $1.sourceStartMs }

        if let containing = sorted.first(where: { srcMs >= $0.sourceStartMs && srcMs <= $0.sourceEndMs }) {
            mutate { doc in
                if let idx = doc.timeline.cameraLayouts.firstIndex(where: { $0.id == containing.id }) {
                    doc.timeline.cameraLayouts[idx].layoutType = type
                }
            }
            selectCameraLayout(containing.id)
            scrollToTimelineTrack("track_camera_layouts")
            return
        }

        let prevEnd = sorted.last(where: { $0.sourceEndMs <= srcMs })?.sourceEndMs ?? 0.0
        let nextStart = sorted.first(where: { $0.sourceStartMs >= srcMs })?.sourceStartMs ?? maxDur
        let availStart = prevEnd
        let availEnd = nextStart
        guard availEnd - availStart >= 400.0 else { return }

        let desiredDur = min(3500.0, availEnd - availStart)
        let startMs = max(availStart, min(availEnd - desiredDur, srcMs))
        let endMs = min(availEnd, startMs + desiredDur)

        let seg = CameraLayoutSegment(
            sourceStartMs: startMs,
            sourceEndMs: endMs,
            layoutType: type,
            overlayPosition01: document.camera.position01,
            cutoutPositionX01: document.camera.cutoutPositionX01
        )
        mutate { doc in
            doc.timeline.isCameraLayoutsTrackHidden = false
            doc.timeline.cameraLayouts.append(seg)
            doc.timeline.cameraLayouts.sort { $0.sourceStartMs < $1.sourceStartMs }
        }
        selectCameraLayout(seg.id)
        scrollToTimelineTrack("track_camera_layouts")
    }

    public func addCameraLayoutInRange(sourceStartMs: Double, sourceEndMs: Double, type: CameraTimelineLayoutType = .cameraOverlay) {
        guard sourceEndMs - sourceStartMs >= 350.0 else { return }
        let seg = CameraLayoutSegment(
            sourceStartMs: sourceStartMs,
            sourceEndMs: sourceEndMs,
            layoutType: type,
            overlayPosition01: document.camera.position01,
            cutoutPositionX01: document.camera.cutoutPositionX01
        )
        mutate { doc in
            doc.timeline.isCameraLayoutsTrackHidden = false
            doc.timeline.cameraLayouts.append(seg)
            doc.timeline.cameraLayouts.sort { $0.sourceStartMs < $1.sourceStartMs }
        }
        selectCameraLayout(seg.id)
        scrollToTimelineTrack("track_camera_layouts")
    }

    public func moveCameraLayout(id: String, desiredStartMs: Double, durationMs: Double) {
        let earliestSourceMs = document.timeline.slices.map(\.sourceStartMs).min() ?? 0.0
        let latestSourceMs = document.timeline.slices.map(\.sourceEndMs).max() ?? metadata.durationMs
        let span = max(250.0, durationMs)

        mutate { doc in
            let sorted = doc.timeline.cameraLayouts.sorted { $0.sourceStartMs < $1.sourceStartMs }
            guard let sortedIdx = sorted.firstIndex(where: { $0.id == id }) else { return }

            let lowerBound = sortedIdx > 0
                ? max(earliestSourceMs, sorted[sortedIdx - 1].sourceEndMs)
                : earliestSourceMs
            let upperBound = sortedIdx + 1 < sorted.count
                ? min(latestSourceMs, sorted[sortedIdx + 1].sourceStartMs)
                : latestSourceMs
            guard upperBound - lowerBound >= span else { return }

            let clampedStart = max(lowerBound, min(upperBound - span, desiredStartMs))
            let clampedEnd = clampedStart + span

            if let realIdx = doc.timeline.cameraLayouts.firstIndex(where: { $0.id == id }) {
                doc.timeline.cameraLayouts[realIdx].sourceStartMs = clampedStart
                doc.timeline.cameraLayouts[realIdx].sourceEndMs = clampedEnd
            }
            doc.timeline.cameraLayouts.sort { $0.sourceStartMs < $1.sourceStartMs }
        }
    }

    public func resizeCameraLayout(id: String, newStartMs: Double, newEndMs: Double) {
        let earliestSourceMs = document.timeline.slices.map(\.sourceStartMs).min() ?? 0.0
        let latestSourceMs = document.timeline.slices.map(\.sourceEndMs).max() ?? metadata.durationMs
        let minDuration = 250.0

        mutate { doc in
            let sorted = doc.timeline.cameraLayouts.sorted { $0.sourceStartMs < $1.sourceStartMs }
            guard let sortedIdx = sorted.firstIndex(where: { $0.id == id }) else { return }

            let lowerBound = sortedIdx > 0
                ? max(earliestSourceMs, sorted[sortedIdx - 1].sourceEndMs)
                : earliestSourceMs
            let upperBound = sortedIdx + 1 < sorted.count
                ? min(latestSourceMs, sorted[sortedIdx + 1].sourceStartMs)
                : latestSourceMs
            guard upperBound - lowerBound >= minDuration else { return }

            let current = sorted[sortedIdx]
            let isResizingLeft = abs(newEndMs - current.sourceEndMs) < 0.5
            let start: Double
            let end: Double
            if isResizingLeft {
                end = current.sourceEndMs
                start = max(lowerBound, min(end - minDuration, newStartMs))
            } else {
                start = current.sourceStartMs
                end = max(start + minDuration, min(upperBound, newEndMs))
            }

            if let realIdx = doc.timeline.cameraLayouts.firstIndex(where: { $0.id == id }) {
                doc.timeline.cameraLayouts[realIdx].sourceStartMs = start
                doc.timeline.cameraLayouts[realIdx].sourceEndMs = end
            }
            doc.timeline.cameraLayouts.sort { $0.sourceStartMs < $1.sourceStartMs }
        }
    }

    public func splitCameraLayout(id: String, atSourceMs sourceMs: Double) {
        guard let idx = document.timeline.cameraLayouts.firstIndex(where: { $0.id == id }) else { return }
        let original = document.timeline.cameraLayouts[idx]
        guard sourceMs > original.sourceStartMs + 200.0 && sourceMs < original.sourceEndMs - 200.0 else {
            showToast("Can't cut item shorter than 0.2s", durationMs: 2000)
            return
        }
        mutate { doc in
            var firstHalf = original
            firstHalf.id = UUID().uuidString
            firstHalf.sourceEndMs = sourceMs

            var secondHalf = original
            secondHalf.id = UUID().uuidString
            secondHalf.sourceStartMs = sourceMs

            doc.timeline.cameraLayouts.replaceSubrange(idx...idx, with: [firstHalf, secondHalf])
            selectedCameraLayoutId = secondHalf.id
        }
    }

    public func duplicateCameraLayout(id: String) {
        let maxDur = metadata.durationMs
        mutate { doc in
            let sorted = doc.timeline.cameraLayouts.sorted { $0.sourceStartMs < $1.sourceStartMs }
            guard let sortedIdx = sorted.firstIndex(where: { $0.id == id }) else { return }
            let orig = sorted[sortedIdx]
            let nextStart = (sortedIdx + 1 < sorted.count) ? sorted[sortedIdx + 1].sourceStartMs : maxDur
            let availAfter = nextStart - orig.sourceEndMs

            if availAfter >= 300.0 {
                var copy = orig
                copy.id = UUID().uuidString
                copy.sourceStartMs = orig.sourceEndMs
                copy.sourceEndMs = min(nextStart, orig.sourceEndMs + (orig.sourceEndMs - orig.sourceStartMs))
                doc.timeline.cameraLayouts.append(copy)
                doc.timeline.cameraLayouts.sort { $0.sourceStartMs < $1.sourceStartMs }
                selectedCameraLayoutId = copy.id
            } else if orig.sourceEndMs - orig.sourceStartMs >= 500.0 {
                let mid = (orig.sourceStartMs + orig.sourceEndMs) * 0.5
                if let realIdx = doc.timeline.cameraLayouts.firstIndex(where: { $0.id == id }) {
                    doc.timeline.cameraLayouts[realIdx].sourceEndMs = mid
                }
                var copy = orig
                copy.id = UUID().uuidString
                copy.sourceStartMs = mid
                copy.sourceEndMs = orig.sourceEndMs
                doc.timeline.cameraLayouts.append(copy)
                doc.timeline.cameraLayouts.sort { $0.sourceStartMs < $1.sourceStartMs }
                selectedCameraLayoutId = copy.id
            }
        }
    }

    public func toggleCameraLayoutDisabled(id: String) {
        mutate { doc in
            if let idx = doc.timeline.cameraLayouts.firstIndex(where: { $0.id == id }) {
                doc.timeline.cameraLayouts[idx].disabled.toggle()
            }
        }
    }

    public func deleteCameraLayout(id: String) {
        mutate { doc in
            doc.timeline.cameraLayouts.removeAll { $0.id == id }
        }
        if selectedCameraLayoutId == id {
            selectedCameraLayoutId = nil
        }
    }

    public func deleteAllCameraLayouts() {
        mutate { doc in
            doc.timeline.cameraLayouts.removeAll()
        }
        selectedCameraLayoutId = nil
    }

    // MARK: - Voiceovers Track & Live Voiceover Recording

    public func activeVoiceovers(atSourceMs sourceMs: Double) -> [VoiceoverSegment] {
        return document.timeline.voiceovers.filter { vo in
            !vo.disabled && !document.timeline.isVoiceoverTrackHidden(vo.trackIndex) && sourceMs >= vo.sourceStartMs && sourceMs <= vo.sourceEndMs
        }
    }

    public func isOriginalRecordingHiddenAndMutedByVoiceover(atSourceMs sourceMs: Double) -> Bool {
        activeVoiceovers(atSourceMs: sourceMs).contains { $0.hideRecording }
    }

    public func toggleVoiceoverTrackVisibility(trackIndex: Int) {
        mutate { doc in
            doc.timeline.setVoiceoverTrack(trackIndex, hidden: !doc.timeline.isVoiceoverTrackHidden(trackIndex))
        }
    }

    public func startVoiceoverRecording() {
        guard !isRecordingVoiceover else {
            stopVoiceoverRecording()
            return
        }

        let assetsDir = packageURL.appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let voId = UUID().uuidString
        let fileName = "voiceover-\(voId).m4a"
        let relPath = "assets/\(fileName)"
        let fileURL = packageURL.appendingPathComponent(relPath)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        guard let recorder = try? AVAudioRecorder(url: fileURL, settings: settings) else {
            showToast("Could not start microphone voiceover recording")
            return
        }
        recorder.prepareToRecord()
        guard recorder.record() else {
            showToast("Could not start microphone voiceover recording")
            return
        }

        activeVoiceoverRecorder = recorder
        activeVoiceoverRelativePath = relPath
        voiceoverRecordingStartSourceMs = committedSourceTimeMs
        voiceoverRecordingTrackIndex = document.timeline.voiceovers.firstVoiceoverTrackEmpty(after: committedSourceTimeMs)
        isRecordingVoiceover = true
        if !isPlaying {
            isPlaying = true
        }
        showToast("Recording voiceover… Click again to finish")
    }

    public func stopVoiceoverRecording() {
        guard isRecordingVoiceover else { return }
        isRecordingVoiceover = false
        isPlaying = false

        let durationSec = activeVoiceoverRecorder?.currentTime ?? 0.0
        activeVoiceoverRecorder?.stop()
        activeVoiceoverRecorder = nil

        guard let relPath = activeVoiceoverRelativePath else { return }
        activeVoiceoverRelativePath = nil

        let recordedDurMs = max(1200.0, durationSec * 1000.0)
        let startMs = max(0.0, min(metadata.durationMs - 400.0, voiceoverRecordingStartSourceMs))
        let clampedDurMs = min(recordedDurMs, max(400.0, metadata.durationMs - startMs))

        let newVO = VoiceoverSegment(
            sourceStartMs: startMs,
            durationMs: clampedDurMs,
            relativePath: relPath,
            volume: 1.0,
            attachMode: .synchronized,
            hideRecording: false,
            disabled: false,
            trackIndex: voiceoverRecordingTrackIndex
        )
        mutate { doc in
            doc.timeline.setVoiceoverTrack(newVO.trackIndex, hidden: false)
            doc.timeline.voiceovers.append(newVO)
            doc.timeline.normalizeVoiceoverTracks()
        }
        Task { @MainActor [weak self] in
            await self?.loadVoiceoverWaveform(for: newVO)
        }
        selectVoiceover(newVO.id)
        scrollToTimelineTrack("track_voiceovers")
        showToast("Voiceover added")
    }

    public func promptImportVoiceoverAudioFile() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Voiceover Audio File")
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        importVoiceoverAudioFile(from: sourceURL)
    }

    public func importVoiceoverAudioFile(from sourceURL: URL) {
        let assetsDir = packageURL.appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let fileName = "voiceover-\(UUID().uuidString).\(ext)"
        let relPath = "assets/\(fileName)"
        let destURL = packageURL.appendingPathComponent(relPath)
        try? FileManager.default.copyItem(at: sourceURL, to: destURL)

        let startMs = committedSourceTimeMs
        let maxDur = metadata.durationMs

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let asset = AVURLAsset(url: destURL)
            let cmDur = (try? await asset.load(.duration)) ?? CMTime(seconds: 3.0, preferredTimescale: 600)
            let rawDurMs = max(500.0, CMTimeGetSeconds(cmDur) * 1000.0)
            let clampedStart = max(0.0, min(maxDur - 400.0, startMs))
            let clampedDur = min(rawDurMs, max(400.0, maxDur - clampedStart))

            let newVO = VoiceoverSegment(
                sourceStartMs: clampedStart,
                durationMs: clampedDur,
                relativePath: relPath,
                volume: 1.0,
                attachMode: .synchronized,
                hideRecording: false,
                disabled: false,
                trackIndex: self.document.timeline.voiceovers.firstFreeVoiceoverTrack(
                    startMs: clampedStart,
                    endMs: clampedStart + clampedDur
                )
            )
            self.mutate { doc in
                doc.timeline.setVoiceoverTrack(newVO.trackIndex, hidden: false)
                doc.timeline.voiceovers.append(newVO)
                doc.timeline.normalizeVoiceoverTracks()
            }
            await self.loadVoiceoverWaveform(for: newVO)
            self.selectVoiceover(newVO.id)
            self.scrollToTimelineTrack("track_voiceovers")
            self.showToast("Voiceover added")
        }
    }

    public func moveVoiceover(id: String, desiredStartMs: Double, durationMs: Double) {
        let earliestSourceMs = document.timeline.slices.map(\.sourceStartMs).min() ?? 0.0
        let latestSourceMs = document.timeline.slices.map(\.sourceEndMs).max() ?? metadata.durationMs
        let span = max(250.0, durationMs)

        mutate { doc in
            guard let trackIndex = doc.timeline.voiceovers.first(where: { $0.id == id })?.trackIndex else { return }
            let sorted = doc.timeline.voiceovers
                .filter { $0.trackIndex == trackIndex }
                .sorted { $0.sourceStartMs < $1.sourceStartMs }
            guard let sortedIdx = sorted.firstIndex(where: { $0.id == id }) else { return }

            let lowerBound = sortedIdx > 0
                ? max(earliestSourceMs, sorted[sortedIdx - 1].sourceEndMs)
                : earliestSourceMs
            let upperBound = sortedIdx + 1 < sorted.count
                ? min(latestSourceMs, sorted[sortedIdx + 1].sourceStartMs)
                : latestSourceMs
            guard upperBound - lowerBound >= span else { return }

            let clampedStart = max(lowerBound, min(upperBound - span, desiredStartMs))
            if let realIdx = doc.timeline.voiceovers.firstIndex(where: { $0.id == id }) {
                doc.timeline.voiceovers[realIdx].sourceStartMs = clampedStart
                doc.timeline.voiceovers[realIdx].durationMs = span
            }
            doc.timeline.voiceovers.sort { $0.sourceStartMs < $1.sourceStartMs }
        }
    }

    /// Moves a voiceover to another track, or to a new one past the last. The segment snaps back when the target has no room.
    public func moveVoiceoverToTrack(id: String, targetTrackIndex: Int) {
        let voiceovers = document.timeline.voiceovers
        guard let segment = voiceovers.first(where: { $0.id == id }) else { return }
        let target = Swift.max(0, Swift.min(voiceovers.voiceoverTrackCount, targetTrackIndex))
        guard target != segment.trackIndex else { return }
        guard voiceovers.isVoiceoverRangeFree(
            trackIndex: target,
            startMs: segment.sourceStartMs,
            endMs: segment.sourceEndMs,
            ignoringId: id
        ) else { return }
        mutate { doc in
            if let idx = doc.timeline.voiceovers.firstIndex(where: { $0.id == id }) {
                doc.timeline.voiceovers[idx].trackIndex = target
            }
            doc.timeline.normalizeVoiceoverTracks()
        }
    }

    public func applyVoiceoverVolumeToAllOthers(fromId id: String) {
        mutate { doc in
            guard let src = doc.timeline.voiceovers.first(where: { $0.id == id }) else { return }
            for idx in doc.timeline.voiceovers.indices {
                doc.timeline.voiceovers[idx].volume = src.volume
            }
        }
        showToast("Volume applied to all voiceovers")
    }

    public func toggleVoiceoverDisabled(id: String) {
        mutate { doc in
            if let idx = doc.timeline.voiceovers.firstIndex(where: { $0.id == id }) {
                doc.timeline.voiceovers[idx].disabled.toggle()
            }
        }
    }

    public func deleteVoiceover(id: String) {
        mutate { doc in
            doc.timeline.voiceovers.removeAll { $0.id == id }
            doc.timeline.normalizeVoiceoverTracks()
        }
        if selectedVoiceoverId == id {
            selectedVoiceoverId = nil
        }
    }

    public func deleteAllVoiceovers() {
        mutate { doc in
            doc.timeline.voiceovers.removeAll()
        }
        selectedVoiceoverId = nil
    }

    // MARK: - Built-In & Custom Background Audio

    public var isPreviewingBackgroundAudio: Bool = false
    public var loadingBackgroundAudioTrackName: String? = nil
    @ObservationIgnored private var backgroundAudioPreviewPlayer: AVAudioPlayer?

    public nonisolated static func builtInBackgroundTrackFileURL(named trackName: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("NativeScreen/BackgroundAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let slug = trackName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return dir.appendingPathComponent("\(slug).wav")
    }

    public func resolvedBackgroundAudioFileURL() -> URL? {
        guard let rel = document.audio.backgroundMusic.relativePath, !rel.isEmpty else {
            return nil
        }
        let inPackage = packageURL.appendingPathComponent(rel)
        if FileManager.default.fileExists(atPath: inPackage.path) {
            return inPackage
        }
        let inAssets = packageURL.appendingPathComponent("assets", isDirectory: true).appendingPathComponent(rel)
        if FileManager.default.fileExists(atPath: inAssets.path) {
            return inAssets
        }
        let builtInURL = Self.builtInBackgroundTrackFileURL(named: rel)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: builtInURL.path),
           let size = attrs[.size] as? Int64, size > 64_000 {
            return builtInURL
        }
        return nil
    }

    public func selectBuiltInBackgroundTrack(_ trackName: String) {
        stopBackgroundAudioPreview()
        let isCurrentlySelected = (document.audio.backgroundMusic.relativePath == trackName)
        if isCurrentlySelected {
            withAnimation(.easeInOut(duration: 0.18)) {
                loadingBackgroundAudioTrackName = nil
            }
            mutate { $0.audio.backgroundMusic.relativePath = nil }
            return
        }
        mutate {
            $0.audio.backgroundMusic.relativePath = trackName
            $0.audio.backgroundMusic.muted = false
        }
        // If already cached on disk, play immediately with zero lag!
        // Otherwise synthesize on demand in the background while showing a smooth fade-in loading indicator on the selected pill button.
        if resolvedBackgroundAudioFileURL() != nil {
            withAnimation(.easeInOut(duration: 0.18)) {
                loadingBackgroundAudioTrackName = nil
            }
            if !isPlaying {
                toggleBackgroundAudioPreview()
            }
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                loadingBackgroundAudioTrackName = trackName
            }
            Task.detached(priority: .userInitiated) { [weak self] in
                _ = Self.ensureSynthesizedBuiltInBackgroundTrack(named: trackName)
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if self.loadingBackgroundAudioTrackName == trackName {
                            self.loadingBackgroundAudioTrackName = nil
                        }
                    }
                    guard self.document.audio.backgroundMusic.relativePath == trackName else { return }
                    self.renderRevision &+= 1
                    if !self.isPlaying {
                        self.toggleBackgroundAudioPreview()
                    }
                }
            }
        }
    }

    public func importCustomBackgroundAudioFile(from sourceURL: URL) {
        stopBackgroundAudioPreview()
        let assetsDir = packageURL.appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let destFileName = "bg-\(sourceURL.lastPathComponent)"
        let destURL = assetsDir.appendingPathComponent(destFileName)
        try? FileManager.default.removeItem(at: destURL)
        try? FileManager.default.copyItem(at: sourceURL, to: destURL)
        mutate {
            $0.audio.backgroundMusic.relativePath = "assets/\(destFileName)"
            $0.audio.backgroundMusic.muted = false
        }
        showToast("Background audio file added")
    }

    public func toggleBackgroundAudioPreview() {
        if isPreviewingBackgroundAudio {
            stopBackgroundAudioPreview()
            return
        }
        guard let url = resolvedBackgroundAudioFileURL() else { return }
        if isPlaying {
            isPlaying = false
        }
        if let player = try? AVAudioPlayer(contentsOf: url) {
            player.numberOfLoops = -1
            player.volume = Float(min(1.0, max(0.05, document.audio.backgroundMusic.volume * 2.5)))
            player.prepareToPlay()
            player.play()
            backgroundAudioPreviewPlayer = player
            isPreviewingBackgroundAudio = true
        }
    }

    public func updateBackgroundAudioPreviewVolume() {
        backgroundAudioPreviewPlayer?.volume = Float(min(1.0, max(0.02, document.audio.backgroundMusic.volume * 2.5)))
    }

    public func stopBackgroundAudioPreview() {
        backgroundAudioPreviewPlayer?.stop()
        backgroundAudioPreviewPlayer = nil
        isPreviewingBackgroundAudio = false
    }

    public nonisolated static func ensureSynthesizedBuiltInBackgroundTrack(named trackName: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("NativeScreen/BackgroundAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let slug = trackName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let outURL = dir.appendingPathComponent("\(slug).wav")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path),
           let size = attrs[.size] as? Int64, size > 64_000 {
            return outURL
        }

        let sampleRate = 44_100
        let durationSec = 16.0
        let totalFrames = Int(Double(sampleRate) * durationSec)
        var pcm = [Int16](repeating: 0, count: totalFrames * 2)

        // Distinct chord progressions & tempos per track (`Sunny Lo-Fi`, `Lean Groove`, `Bright Lounge`, `Chill Hop`, etc.)
        let progression: [[Double]]
        let bpm: Double
        let padBrightness: Double

        switch slug {
        case "lean-groove", "upbeat-spark", "pulse-drive":
            bpm = 108.0
            padBrightness = 0.45
            progression = [
                [220.00, 277.18, 329.63, 415.30], // A maj7
                [185.00, 220.00, 277.18, 329.63], // F#m7
                [146.83, 185.00, 220.00, 277.18], // D maj7
                [164.81, 207.65, 246.94, 329.63]  // E7
            ]
        case "bright-lounge", "warm-horizon", "velvet-keys":
            bpm = 92.0
            padBrightness = 0.35
            progression = [
                [174.61, 220.00, 261.63, 329.63], // F maj7
                [164.81, 196.00, 246.94, 293.66], // Em7
                [146.83, 174.61, 220.00, 261.63], // Dm7
                [130.81, 164.81, 196.00, 246.94]  // C maj7
            ]
        case "chill-hop", "midnight-study", "soft-rain":
            bpm = 78.0
            padBrightness = 0.25
            progression = [
                [146.83, 174.61, 220.00, 261.63], // Dm7
                [196.00, 246.94, 293.66, 349.23], // G7
                [130.81, 164.81, 196.00, 246.94], // C maj7
                [110.00, 138.59, 164.81, 196.00]  // A7
            ]
        default: // "sunny-lo-fi" and others
            bpm = 84.0
            padBrightness = 0.30
            progression = [
                [130.81, 164.81, 196.00, 246.94, 293.66], // C maj9
                [110.00, 130.81, 164.81, 196.00, 246.94], // Am9
                [146.83, 174.61, 220.00, 261.63, 329.63], // Dm9
                [98.00,  146.83, 174.61, 220.00, 246.94]  // G13
            ]
        }

        let secPerBeat = 60.0 / bpm
        let secPerBar = secPerBeat * 4.0

        for i in 0..<totalFrames {
            let t = Double(i) / Double(sampleRate)
            let barIdx = Int(t / secPerBar) % progression.count
            let barPhase = t.truncatingRemainder(dividingBy: secPerBar)
            let beatPhase = t.truncatingRemainder(dividingBy: secPerBeat)
            let chord = progression[barIdx]

            // 1. Warm Rhodes Electric Piano Chord Pad + Gentle Tremolo
            let barEnv = min(1.0, barPhase / 0.06) * exp(-barPhase * 0.42)
            let tremoloL = 0.88 + 0.12 * sin(2.0 * .pi * 3.2 * t)
            let tremoloR = 0.88 + 0.12 * cos(2.0 * .pi * 3.2 * t)

            var padSumL = 0.0
            var padSumR = 0.0
            for (nIdx, freq) in chord.enumerated() {
                let detune = 1.0 + Double(nIdx - 2) * 0.0008
                let fundamental = sin(2.0 * .pi * freq * detune * t)
                let harmonic2 = sin(2.0 * .pi * freq * 2.0 * t) * padBrightness * exp(-barPhase * 1.4)
                let voice = (fundamental + harmonic2) / Double(chord.count)
                let pan = 0.5 + Double(nIdx - chord.count / 2) * 0.12
                padSumL += voice * (1.0 - pan * 0.4)
                padSumR += voice * (0.6 + pan * 0.4)
            }

            // 2. Warm Sub-Bass on Beats 1 and 2.5
            let rootFreq = chord[0] * 0.5
            let bassTime = (barPhase < secPerBeat * 2.5) ? barPhase : (barPhase - secPerBeat * 2.5)
            let bassEnv = min(1.0, bassTime / 0.015) * exp(-bassTime * 3.2)
            let bassSample = sin(2.0 * .pi * rootFreq * t) * bassEnv * 0.34

            // 3. Soft Lo-Fi Kick (Beats 1 & 3) and Gentle Brush Hat (Eighth notes)
            let isBeat1Or3 = (Int(barPhase / secPerBeat) % 2 == 0)
            let kickEnv = isBeat1Or3 ? exp(-beatPhase * 22.0) : 0.0
            let kickFreq = 52.0 + 95.0 * exp(-beatPhase * 38.0)
            let kickSample = sin(2.0 * .pi * kickFreq * t) * kickEnv * 0.28

            let eighthPhase = t.truncatingRemainder(dividingBy: secPerBeat * 0.5)
            let hatEnv = exp(-eighthPhase * 48.0) * 0.035
            let pseudoNoise = sin(Double(i) * 1.73205) * cos(Double(i) * 2.41421)
            let hatSample = pseudoNoise * hatEnv

            // Smooth loop crossfade at start/end
            let loopFade = min(1.0, min(t / 0.08, (durationSec - t) / 0.15))

            let left = (padSumL * barEnv * tremoloL * 0.52 + bassSample + kickSample + hatSample) * loopFade
            let right = (padSumR * barEnv * tremoloR * 0.52 + bassSample + kickSample + hatSample) * loopFade

            pcm[i * 2] = Int16(max(-32000.0, min(32000.0, left * 26000.0)))
            pcm[i * 2 + 1] = Int16(max(-32000.0, min(32000.0, right * 26000.0)))
        }

        // Write standard 44-byte RIFF WAV header + 16-bit stereo PCM data
        let dataByteCount = UInt32(pcm.count * MemoryLayout<Int16>.size)
        var wavData = Data(capacity: 44 + Int(dataByteCount))
        wavData.append("RIFF".data(using: .ascii)!)
        var riffChunkSize = UInt32(36 + dataByteCount).littleEndian
        wavData.append(Data(bytes: &riffChunkSize, count: 4))
        wavData.append("WAVEfmt ".data(using: .ascii)!)
        var fmtChunkSize = UInt32(16).littleEndian
        var audioFormat = UInt16(1).littleEndian
        var numChannels = UInt16(2).littleEndian
        var sRate = UInt32(sampleRate).littleEndian
        var byteRate = UInt32(sampleRate * 2 * 2).littleEndian
        var blockAlign = UInt16(4).littleEndian
        var bitsPerSample = UInt16(16).littleEndian
        wavData.append(Data(bytes: &fmtChunkSize, count: 4))
        wavData.append(Data(bytes: &audioFormat, count: 2))
        wavData.append(Data(bytes: &numChannels, count: 2))
        wavData.append(Data(bytes: &sRate, count: 4))
        wavData.append(Data(bytes: &byteRate, count: 4))
        wavData.append(Data(bytes: &blockAlign, count: 2))
        wavData.append(Data(bytes: &bitsPerSample, count: 2))
        wavData.append("data".data(using: .ascii)!)
        var dataSizeLE = dataByteCount.littleEndian
        wavData.append(Data(bytes: &dataSizeLE, count: 4))
        pcm.withUnsafeBytes { rawBuf in
            wavData.append(contentsOf: rawBuf)
        }
        try? wavData.write(to: outURL, options: .atomic)
        return outURL
    }
}
