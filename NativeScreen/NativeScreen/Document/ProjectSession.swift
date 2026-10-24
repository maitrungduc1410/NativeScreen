import Foundation
import SwiftUI
import Observation
import AppKit

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
    public var isSplitModeActive: Bool = false
    public var selectedSliceId: String?
    public var selectedZoomId: String?
    public var selectedMaskId: String?
    public var selectedInspectorTab: InspectorTab = .background

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

        public var id: String { rawValue }

        public var systemImage: String {
            switch self {
            case .background: return "swatchpalette"
            case .cursor: return "cursorarrow.motionlines"
            case .zoom: return "plus.magnifyingglass"
            case .masks: return "eye.slash.circle"
            case .audio: return "waveform"
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
        self.document = updatedDoc

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
        if interactiveEditSnapshot == nil {
            interactiveEditSnapshot = document
        }
    }

    public func endInteractiveEdit() {
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

    public func selectSlice(_ id: String?) {
        selectedSliceId = id
        selectedZoomId = nil
        selectedMaskId = nil
    }

    public func selectZoom(_ id: String?) {
        selectedZoomId = id
        selectedMaskId = nil
        if id != nil {
            selectedInspectorTab = .zoom
        }
    }

    public func selectMask(_ id: String?) {
        selectedMaskId = id
        selectedZoomId = nil
        if id != nil {
            selectedInspectorTab = .masks
        }
    }

    public func deleteSelectedTimelineItem() {
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
            let gap = 40.0
            guard sourceMs > original.sourceStartMs + 200.0 && sourceMs < original.sourceEndMs - 200.0 else { return }

            var firstHalf = original
            firstHalf.id = UUID().uuidString
            firstHalf.sourceEndMs = sourceMs - gap * 0.5

            var secondHalf = original
            secondHalf.id = UUID().uuidString
            secondHalf.sourceStartMs = sourceMs + gap * 0.5

            doc.timeline.zooms.replaceSubrange(idx...idx, with: [firstHalf, secondHalf])
            selectedZoomId = secondHalf.id
        }
    }

    public func splitMask(id: String, atSourceMs sourceMs: Double) {
        mutate { doc in
            for tIdx in doc.timeline.maskTracks.indices {
                if let mIdx = doc.timeline.maskTracks[tIdx].items.firstIndex(where: { $0.id == id }) {
                    let original = doc.timeline.maskTracks[tIdx].items[mIdx]
                    let gap = 40.0
                    guard sourceMs > original.sourceStartMs + 180.0 && sourceMs < original.sourceEndMs - 180.0 else { return }

                    let rectAtSplit = original.interpolatedRect(at: sourceMs)
                    var firstHalf = original
                    firstHalf.id = UUID().uuidString
                    firstHalf.sourceEndMs = sourceMs - gap * 0.5

                    var secondHalf = original
                    secondHalf.id = UUID().uuidString
                    secondHalf.sourceStartMs = sourceMs + gap * 0.5
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

    /// Moves a ZoomBlock horizontally while strictly preserving its exact `durationMs` (NEVER resizes!).
    public func moveZoom(id: String, desiredStartMs: Double, durationMs: Double) {
        let earliestSourceMs = document.timeline.slices.map(\.sourceStartMs).min() ?? 0.0
        let latestSourceMs = document.timeline.slices.map(\.sourceEndMs).max() ?? metadata.durationMs
        let minGap = 40.0
        let span = max(300.0, durationMs)

        mutate { doc in
            let sorted = doc.timeline.zooms.sorted { $0.sourceStartMs < $1.sourceStartMs }
            guard let sortedIdx = sorted.firstIndex(where: { $0.id == id }) else { return }

            let lowerBound = sortedIdx > 0
                ? max(earliestSourceMs, sorted[sortedIdx - 1].sourceEndMs + minGap)
                : earliestSourceMs
            let upperBound = sortedIdx + 1 < sorted.count
                ? min(latestSourceMs, sorted[sortedIdx + 1].sourceStartMs - minGap)
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

    /// Resizes ONLY the left/start or right/end edge of a ZoomBlock (only triggered by the 2 edge handles).
    public func resizeZoom(id: String, newStartMs: Double, newEndMs: Double) {
        let earliestSourceMs = document.timeline.slices.map(\.sourceStartMs).min() ?? 0.0
        let latestSourceMs = document.timeline.slices.map(\.sourceEndMs).max() ?? metadata.durationMs
        let minDuration = 300.0
        let minGap = 40.0

        mutate { doc in
            let sorted = doc.timeline.zooms.sorted { $0.sourceStartMs < $1.sourceStartMs }
            guard let sortedIdx = sorted.firstIndex(where: { $0.id == id }) else { return }

            let lowerBound = sortedIdx > 0
                ? max(earliestSourceMs, sorted[sortedIdx - 1].sourceEndMs + minGap)
                : earliestSourceMs
            let upperBound = sortedIdx + 1 < sorted.count
                ? min(latestSourceMs, sorted[sortedIdx + 1].sourceStartMs - minGap)
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

    /// Moves a MaskItem horizontally while strictly preserving its exact `durationMs` (NEVER resizes!).
    public func moveMask(id: String, desiredStartMs: Double, durationMs: Double) {
        let earliestSourceMs = document.timeline.slices.map(\.sourceStartMs).min() ?? 0.0
        let latestSourceMs = document.timeline.slices.map(\.sourceEndMs).max() ?? metadata.durationMs
        let minGap = 30.0
        let span = max(250.0, durationMs)

        mutate { doc in
            for tIdx in doc.timeline.maskTracks.indices {
                let items = doc.timeline.maskTracks[tIdx].items.sorted { $0.sourceStartMs < $1.sourceStartMs }
                guard let sortedIdx = items.firstIndex(where: { $0.id == id }) else { continue }

                let lowerBound = sortedIdx > 0
                    ? max(earliestSourceMs, items[sortedIdx - 1].sourceEndMs + minGap)
                    : earliestSourceMs
                let upperBound = sortedIdx + 1 < items.count
                    ? min(latestSourceMs, items[sortedIdx + 1].sourceStartMs - minGap)
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

    /// Resizes ONLY the left/start or right/end edge of a MaskItem (only triggered by the 2 edge handles).
    public func resizeMask(id: String, newStartMs: Double, newEndMs: Double) {
        let earliestSourceMs = document.timeline.slices.map(\.sourceStartMs).min() ?? 0.0
        let latestSourceMs = document.timeline.slices.map(\.sourceEndMs).max() ?? metadata.durationMs
        let minDuration = 250.0
        let minGap = 30.0

        mutate { doc in
            for tIdx in doc.timeline.maskTracks.indices {
                let items = doc.timeline.maskTracks[tIdx].items.sorted { $0.sourceStartMs < $1.sourceStartMs }
                guard let sortedIdx = items.firstIndex(where: { $0.id == id }) else { continue }

                let lowerBound = sortedIdx > 0
                    ? max(earliestSourceMs, items[sortedIdx - 1].sourceEndMs + minGap)
                    : earliestSourceMs
                let upperBound = sortedIdx + 1 < items.count
                    ? min(latestSourceMs, items[sortedIdx + 1].sourceStartMs - minGap)
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

    public func addZoomAtPlayhead() {
        let srcMs = committedSourceTimeMs
        let maxDur = metadata.durationMs
        let cursorState = trajectorySolver.evaluate(atSourceMs: srcMs).cursor

        let sorted = document.timeline.zooms.sorted { $0.sourceStartMs < $1.sourceStartMs }
        if let containing = sorted.first(where: { srcMs >= $0.sourceStartMs && srcMs <= $0.sourceEndMs }) {
            selectZoom(containing.id)
            return
        }

        let prevEnd = sorted.last(where: { $0.sourceEndMs <= srcMs })?.sourceEndMs ?? 0.0
        let nextStart = sorted.first(where: { $0.sourceStartMs >= srcMs })?.sourceStartMs ?? maxDur
        let minGap = 50.0
        let availStart = prevEnd + (prevEnd > 0 ? minGap : 0)
        let availEnd = nextStart - (nextStart < maxDur ? minGap : 0)
        guard availEnd - availStart >= 400.0 else { return }

        let desiredDuration = min(3200.0, availEnd - availStart)
        let startMs = max(availStart, min(availEnd - desiredDuration, srcMs))
        let endMs = min(availEnd, startMs + desiredDuration)

        let newZoom = ZoomBlock(
            sourceStartMs: startMs,
            sourceEndMs: endMs,
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
    }

    public func addMaskAtPlayhead(type: MaskType = .blur, style: MaskStyle = .gaussian) {
        let srcMs = committedSourceTimeMs
        let maxDur = metadata.durationMs
        let endMs = min(maxDur, srcMs + 4500.0)
        let startMs = max(0.0, min(srcMs, endMs - 1200.0))

        let camState = trajectorySolver.evaluate(atSourceMs: srcMs).camera
        let invScale = 1.0 / max(1.0, camState.scale)
        let existingCount = activeMasks(atSourceMs: srcMs).count
        let offset = Double(existingCount % 4) * 0.03 * invScale

        let boxW = max(0.08, 0.28 * invScale)
        let boxH = max(0.06, 0.14 * invScale)
        let boxX = camState.center01.x - boxW * 0.5 + offset
        let boxY = camState.center01.y - boxH * 0.5 + offset
        let initialRect = Rect01(x: boxX, y: boxY, width: boxW, height: boxH).clamped()

        let item = MaskItem(
            sourceStartMs: startMs,
            sourceEndMs: endMs,
            type: type,
            style: style,
            intensity: 36.0,
            cornerRadius: 10.0,
            keyframes: [MaskKeyframe(sourceMs: startMs, rect01: initialRect)]
        )

        mutate { doc in
            if let freeTrackIndex = doc.timeline.maskTracks.firstIndex(where: { track in
                !track.items.contains(where: { !(endMs <= $0.sourceStartMs + 30.0 || startMs >= $0.sourceEndMs - 30.0) })
            }) {
                doc.timeline.maskTracks[freeTrackIndex].isHidden = false
                doc.timeline.maskTracks[freeTrackIndex].items.append(item)
                doc.timeline.maskTracks[freeTrackIndex].items.sort { $0.sourceStartMs < $1.sourceStartMs }
            } else {
                let newTrackNumber = doc.timeline.maskTracks.count + 1
                let newTrack = MaskTrack(
                    name: newTrackNumber == 1 ? "Masks" : "Masks \(newTrackNumber)",
                    isHidden: false,
                    items: [item]
                )
                doc.timeline.maskTracks.append(newTrack)
            }
        }
        selectMask(item.id)
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

        if !FileManager.default.fileExists(atPath: destURL.path) {
            if let cgImage = SystemWallpaperCatalog.downsampleCGImage(at: item.fullImageURL, maxPixelSize: 2560) {
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                if let jpgData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) {
                    try? jpgData.write(to: destURL, options: .atomic)
                }
            } else {
                try? FileManager.default.copyItem(at: item.fullImageURL, to: destURL)
            }
        }

        mutate { doc in
            doc.background.type = .wallpaper
            doc.background.systemWallpaperName = item.name
            doc.background.wallpaperRelativePath = "assets/\(destFileName)"
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
}
