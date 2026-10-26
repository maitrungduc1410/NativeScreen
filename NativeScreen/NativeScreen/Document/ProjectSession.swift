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
    public var playheadTimelineMs: Double = 0.0
    public var hoverSkimTimelineMs: Double? = nil
    public var isPlaying: Bool = false
    public var previewPlaybackRate: Double = 1.0
    public var isSplitModeActive: Bool = false
    public var timelineZoom: Double = 1.0
    public var isReelModeActive: Bool = false
    public var reelPlatformStyle: ReelPlatformStyle = .tiktok
    public var isShowingStillFrameExportModal: Bool = false
    public var selectedSliceId: String?
    public var selectedZoomId: String?
    public var selectedMaskId: String?
    public var selectedShortcutId: String?
    public var pendingAddMaskType: MaskType? = nil
    public var pendingAddMaskStyle: MaskStyle = .gaussian
    public var isDraggingTimelineSegment: Bool = false
    public var scrollToTrackTargetId: String? = nil
    public var scrollToTrackRevision: Int = 0
    public var selectedInspectorTab: InspectorTab = .background

    // Audio Waveform Envelope Samples (`0.0 ... 1.0`, ~240 buckets across `metadata.durationMs`)
    public var audioWaveformSamples: [Float] = []

    // Clipboard for Zoom / Mask Copy & Cut (`⌘C` / `⌘X`)
    public var copiedZoomBlock: ZoomBlock?
    public var copiedMaskItem: MaskItem?

    // Cached NLE Mapper & 120Hz Spring Trajectory Solver
    public private(set) var timeMapper: NLETimeMapper
    public private(set) var trajectorySolver: SpringTrajectorySolver

    private var lastMappedSlices: [ClipSlice]
    private var lastSolverCursorConfig: CursorConfig
    private var lastSolverMotionConfig: MotionConfig
    private var lastSolverZooms: [ZoomBlock]
    private var lastSolverZoomTrackHidden: Bool

    // Value-Type Snapshot Undo/Redo Stack
    private var undoStack: [ProjectDocument] = []
    private var redoStack: [ProjectDocument] = []
    private var interactiveEditSnapshot: ProjectDocument?
    private let maxUndoDepth = 150
    private var saveTask: Task<Void, Never>?

    // Incrementing token used to notify the Metal preview view (`MTKView.needsDisplay = true`) on any state/scrub/skim change
    public var renderRevision: UInt64 = 0

    public enum InspectorTab: String, CaseIterable, Identifiable {
        case background = "Background"
        case cursor = "Cursor"
        case zoom = "Zoom"
        case masks = "Masks"
        case audio = "Audio"
        case shortcuts = "Shortcuts"

        public var id: String { rawValue }

        public var systemImage: String {
            switch self {
            case .background: return "swatchpalette"
            case .cursor: return "cursorarrow.motionlines"
            case .zoom: return "plus.magnifyingglass"
            case .masks: return "eye.slash.circle"
            case .audio: return "waveform"
            case .shortcuts: return "command"
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
        self.selectedSliceId = cleanedDoc.timeline.slices.first?.id
        self.audioWaveformSamples = Self.generateProceduralWaveform(durationMs: metadata.durationMs)

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

    private func scheduleAutoSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self = self else { return }
            try? self.saveNow()
        }
    }

    // MARK: - Value-Type Snapshot Undo / Redo (`⌘Z` / `⇧⌘Z`)

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func beginInteractiveEdit() {
        isDraggingTimelineSegment = true
        if interactiveEditSnapshot == nil {
            interactiveEditSnapshot = document
        }
    }

    public func endInteractiveEdit() {
        isDraggingTimelineSegment = false
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

        let needsSpringRebuild = forceSpringRebuild
            || document.cursor != lastSolverCursorConfig
            || document.motion != lastSolverMotionConfig
            || document.timeline.zooms != lastSolverZooms
            || document.timeline.isZoomTrackHidden != lastSolverZoomTrackHidden

        if needsSpringRebuild {
            lastSolverCursorConfig = document.cursor
            lastSolverMotionConfig = document.motion
            lastSolverZooms = document.timeline.zooms
            lastSolverZoomTrackHidden = document.timeline.isZoomTrackHidden
            trajectorySolver = SpringTrajectorySolver(
                durationMs: metadata.durationMs,
                cursorEvents: cursorEvents,
                clickEvents: clickEvents,
                document: document
            )
        }

        if playheadTimelineMs > timeMapper.totalTimelineDurationMs {
            playheadTimelineMs = timeMapper.totalTimelineDurationMs
        }
        renderRevision &+= 1
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

    public func selectSlice(_ id: String?) {
        selectedSliceId = id
        selectedZoomId = nil
        selectedMaskId = nil
        selectedShortcutId = nil
        pendingAddMaskType = nil
        renderRevision &+= 1
    }

    public func selectZoom(_ id: String?) {
        selectedZoomId = id
        selectedMaskId = nil
        selectedShortcutId = nil
        pendingAddMaskType = nil
        if id != nil {
            selectedInspectorTab = .zoom
        }
        renderRevision &+= 1
    }

    public func selectMask(_ id: String?) {
        selectedMaskId = id
        selectedZoomId = nil
        selectedShortcutId = nil
        if id != nil {
            selectedInspectorTab = .masks
        }
        renderRevision &+= 1
    }

    public func selectShortcut(_ id: String?) {
        selectedShortcutId = id
        selectedZoomId = nil
        selectedMaskId = nil
        pendingAddMaskType = nil
        if id != nil {
            selectedInspectorTab = .shortcuts
        }
        renderRevision &+= 1
    }

    public func deleteSelectedTimelineItem() {
        if let shortcutId = selectedShortcutId,
           let cluster = detectedShortcutClusters.first(where: { $0.id == shortcutId }) {
            deleteShortcut(cluster)
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
        guard timelineMs > mapped.timelineStartMs + 100.0 && timelineMs < mapped.timelineEndMs - 100.0 else { return }

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
        mutate { doc in
            guard let idx = doc.timeline.zooms.firstIndex(where: { $0.id == id }) else { return }
            let original = doc.timeline.zooms[idx]
            guard sourceMs > original.sourceStartMs + 200.0 && sourceMs < original.sourceEndMs - 200.0 else { return }

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
        mutate { doc in
            for tIdx in doc.timeline.maskTracks.indices {
                if let mIdx = doc.timeline.maskTracks[tIdx].items.firstIndex(where: { $0.id == id }) {
                    let original = doc.timeline.maskTracks[tIdx].items[mIdx]
                    guard sourceMs > original.sourceStartMs + 180.0 && sourceMs < original.sourceEndMs - 180.0 else { return }

                    let rectAtSplit = original.interpolatedRect(at: sourceMs)
                    var firstHalf = original
                    firstHalf.id = UUID().uuidString
                    firstHalf.sourceEndMs = sourceMs

                    var secondHalf = original
                    secondHalf.id = UUID().uuidString
                    secondHalf.sourceStartMs = sourceMs
                    secondHalf.keyframes = [MaskKeyframe(sourceMs: secondHalf.sourceStartMs, rect01: rectAtSplit)]

                    doc.timeline.maskTracks[tIdx].items.replaceSubrange(mIdx...mIdx, with: [firstHalf, secondHalf])
                    selectedMaskId = secondHalf.id
                    return
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
            mode: .followCursor,
            presentation: presentation,
            manualCenter01: cursorState.position01,
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
        let midMs = (sourceStartMs + sourceStartMs) * 0.5
        let cursorState = trajectorySolver.evaluate(atSourceMs: midMs).cursor
        let newZoom = ZoomBlock(
            sourceStartMs: sourceStartMs,
            sourceEndMs: sourceEndMs,
            scale: 1.8,
            mode: .followCursor,
            presentation: .screen,
            manualCenter01: cursorState.position01
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
        DispatchQueue.global(qos: .utility).async { [weak self] in
            if let cgImage = SystemWallpaperCatalog.downsampleCGImage(at: sourceURL, maxPixelSize: 2560) {
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
            includeShortcutOverlay: true
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

    public func setSliceSystemAudioVolume(id: String, volume: Double) {
        mutate { doc in
            if let idx = doc.timeline.slices.firstIndex(where: { $0.id == id }) {
                let clamped = max(0.0, min(2.0, volume))
                doc.timeline.slices[idx].systemAudioVolume = clamped
                doc.timeline.slices[idx].muted = (clamped <= 0.001)
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
        }
    }

    public func cutZoomToClipboard(id: String) {
        copyZoomToClipboard(id: id)
        deleteZoom(zoomId: id)
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
                return
            }
        }
    }

    public func cutMaskToClipboard(id: String) {
        copyMaskToClipboard(id: id)
        deleteMask(maskId: id)
    }

    /// Splits whichever item is currently selected at `currentSourceTimeMs` (or splits the Clip at Playhead) when pressing `C`.
    public func splitAtCurrentTimeShortcut() {
        let srcMs = currentSourceTimeMs
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

    /// Toggles `disabled` on the selected Zoom or Mask when pressing `D`.
    public func toggleDisableSelectedShortcut() {
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
        let url = videoFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              let audioTrack = tracks.first else {
            return
        }

        let durationSec = max(1.0, metadata.durationMs / 1000.0)
        // Extract at the high-density 800 bins/sec so the mip-pyramid has full resolution!
        let targetBinCount = max(256, min(16384, Int(durationSec * 240.0)))
        let extracted: [Float]? = await Task.detached(priority: .utility) {
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
                var data = Data(count: length)
                data.withUnsafeMutableBytes { rawBuffer in
                    if let baseAddress = rawBuffer.baseAddress {
                        CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: baseAddress)
                        let int16Ptr = baseAddress.assumingMemoryBound(to: Int16.self)
                        let totalSamples = length / MemoryLayout<Int16>.size
                        // Subdivide each CMSampleBuffer into 128-sample chunks so every syllable peak/valley is captured!
                        let chunkSize = 128
                        var offset = 0
                        while offset < totalSamples {
                            let end = min(totalSamples, offset + chunkSize)
                            var maxSample: Float = 0.0
                            var i = offset
                            while i < end {
                                let v = abs(Float(int16Ptr[i])) / 32768.0
                                if v > maxSample { maxSample = v }
                                i += 2
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
            let referencePeak = max(0.03, sortedPeaks[p95Idx])

            let finalCount = min(targetBinCount, rawPeaks.count)
            var buckets = [Float](repeating: 0.04, count: finalCount)
            for b in 0..<finalCount {
                let startIdx = (b * rawPeaks.count) / finalCount
                let endIdx = max(startIdx + 1, ((b + 1) * rawPeaks.count) / finalCount)
                var localMax: Float = 0
                for j in startIdx..<min(rawPeaks.count, endIdx) {
                    localMax = max(localMax, rawPeaks[j])
                }
                let normalized = min(1.0, localMax / referencePeak)
                buckets[b] = min(0.98, max(0.03, pow(normalized, 0.62)))
            }
            return buckets
        }.value

        if let realSamples = extracted {
            self.audioWaveformSamples = realSamples
        }
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

        return sanitized.sorted { $0.displayStartMs < $1.displayStartMs }
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
        // Canonical order (`fg` / `g`):
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
        // Note:, timeline order is `["Meta", "Shift", "Alt", "Ctrl"]` (or `⌥ ⌃` as shown in)
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
}
