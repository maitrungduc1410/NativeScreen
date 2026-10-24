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

    // Playback & Selection State
    public var playheadTimelineMs: Double = 0.0
    public var isPlaying: Bool = false
    public var selectedSliceId: String?
    public var selectedZoomId: String?
    public var selectedMaskId: String?
    public var selectedInspectorTab: InspectorTab = .background

    // Cached NLE Mapper & 120Hz Spring Trajectory Solver
    public private(set) var timeMapper: NLETimeMapper
    public private(set) var trajectorySolver: SpringTrajectorySolver

    // Value-Type Snapshot Undo/Redo Stack
    private var undoStack: [ProjectDocument] = []
    private var redoStack: [ProjectDocument] = []
    private var interactiveEditSnapshot: ProjectDocument?
    private let maxUndoDepth = 150
    private var saveTask: Task<Void, Never>?

    // Incrementing token used to notify the Metal preview view (`MTKView.needsDisplay = true`) on any state/scrub change
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
        self.packageURL = packageURL
        self.document = document
        self.metadata = metadata
        self.cursorEvents = cursorEvents
        self.clickEvents = clickEvents
        self.keyEvents = keyEvents
        self.timeMapper = NLETimeMapper(slices: document.timeline.slices)
        self.trajectorySolver = SpringTrajectorySolver(
            durationMs: metadata.durationMs,
            cursorEvents: cursorEvents,
            clickEvents: clickEvents,
            document: document
        )
        self.selectedSliceId = document.timeline.slices.first?.id
    }

    // MARK: - Load & Save `.nativescreen` Bundle

    public static func load(from packageURL: URL) throws -> ProjectSession {
        let projectJSONURL = packageURL.appendingPathComponent("project.json")
        let recordingDir = packageURL.appendingPathComponent("recording", isDirectory: true)
        let metadataJSONURL = recordingDir.appendingPathComponent("metadata.json")

        let decoder = JSONDecoder()
        let docData = try Data(contentsOf: projectJSONURL)
        let document = try decoder.decode(ProjectDocument.self, from: docData)

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

    /// Begin a continuous drag/slider interaction so intermediate drag frames coalesce into a single Undo step.
    public func beginInteractiveEdit() {
        if interactiveEditSnapshot == nil {
            interactiveEditSnapshot = document
        }
    }

    /// Commit a continuous drag/slider interaction.
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

    /// Apply a discrete mutation with automatic Undo snapshot recording.
    public func mutate(_ mutation: (inout ProjectDocument) -> Void) {
        let before = interactiveEditSnapshot ?? document
        var next = document
        mutation(&next)
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
        rebuildDerivedState()
        scheduleAutoSave()
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
        rebuildDerivedState()
        scheduleAutoSave()
    }

    private func pushUndoSnapshot(_ snapshot: ProjectDocument) {
        undoStack.append(snapshot)
        if undoStack.count > maxUndoDepth {
            undoStack.removeFirst(undoStack.count - maxUndoDepth)
        }
        redoStack.removeAll()
    }

    private func rebuildDerivedState() {
        timeMapper = NLETimeMapper(slices: document.timeline.slices)
        trajectorySolver = SpringTrajectorySolver(
            durationMs: metadata.durationMs,
            cursorEvents: cursorEvents,
            clickEvents: clickEvents,
            document: document
        )
        if playheadTimelineMs > timeMapper.totalTimelineDurationMs {
            playheadTimelineMs = timeMapper.totalTimelineDurationMs
        }
        renderRevision &+= 1
    }

    // MARK: - Current Playhead Helpers

    public var currentSourceTimeMs: Double {
        timeMapper.sourceTime(forTimelineMs: playheadTimelineMs).sourceMs
    }

    public var currentActiveSlice: ClipSlice? {
        timeMapper.sourceTime(forTimelineMs: playheadTimelineMs).slice
    }

    public func seek(toTimelineMs timelineMs: Double) {
        let clamped = max(0.0, min(timeMapper.totalTimelineDurationMs, timelineMs))
        if abs(clamped - playheadTimelineMs) > 0.01 {
            playheadTimelineMs = clamped
            renderRevision &+= 1
        }
    }

    // MARK: - NLE Timeline Editing Actions (Split, Trim, Zooms, Multi-Track Masks)

    /// Splits the active clip slice at the current playhead (`⌘B`).
    public func splitSliceAtPlayhead() {
        let currentTimeline = playheadTimelineMs
        for (index, mapped) in timeMapper.mappedSlices.enumerated() {
            if currentTimeline > mapped.timelineStartMs + 150.0 && currentTimeline < mapped.timelineEndMs - 150.0 {
                let offsetTimeline = currentTimeline - mapped.timelineStartMs
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
                return
            }
        }
    }

    public func deleteSelectedSlice() {
        guard let sliceId = selectedSliceId, document.timeline.slices.count > 1 else { return }
        mutate { doc in
            doc.timeline.slices.removeAll { $0.id == sliceId }
            selectedSliceId = doc.timeline.slices.first?.id
        }
    }

    public func addZoomAtPlayhead() {
        let srcMs = currentSourceTimeMs
        let endMs = min(metadata.durationMs, srcMs + 3500.0)
        let startMs = max(0.0, endMs - 3500.0)
        let cursorState = trajectorySolver.evaluate(atSourceMs: srcMs).cursor
        let newZoom = ZoomBlock(
            sourceStartMs: startMs,
            sourceEndMs: endMs,
            scale: 1.8,
            mode: .followCursor,
            presentation: .screen,
            manualCenter01: cursorState.position01
        )
        mutate { doc in
            doc.timeline.zooms.append(newZoom)
            doc.timeline.zooms.sort { $0.sourceStartMs < $1.sourceStartMs }
        }
        selectedZoomId = newZoom.id
        selectedInspectorTab = .zoom
    }

    public func regenerateAutoZooms() {
        let generated = AutoZoomClusterGenerator.generateZooms(
            clicks: clickEvents,
            keys: keyEvents,
            durationMs: metadata.durationMs,
            defaultScale: 1.8
        )
        mutate { doc in
            doc.timeline.zooms = generated
        }
    }

    /// Adds a new Blur or Spotlight Mask at the current playhead. Automatically places it on an available track
    /// or creates a new parallel Mask Track if existing tracks already have an overlapping mask at that timestamp!
    public func addMaskAtPlayhead(type: MaskType = .blur, style: MaskStyle = .gaussian) {
        let srcMs = currentSourceTimeMs
        let endMs = min(metadata.durationMs, srcMs + 5000.0)
        let startMs = max(0.0, min(srcMs, endMs - 1500.0))

        // Offset slightly if multiple masks exist at this frame so user sees each new box clearly
        let existingCount = activeMasks(atSourceMs: srcMs).count
        let offset = Double(existingCount % 4) * 0.05
        let initialRect = Rect01(
            x: min(0.65, 0.25 + offset),
            y: min(0.65, 0.30 + offset),
            width: 0.32,
            height: 0.16
        )

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
                !track.items.contains(where: { !(endMs <= $0.sourceStartMs || startMs >= $0.sourceEndMs) })
            }) {
                doc.timeline.maskTracks[freeTrackIndex].items.append(item)
            } else {
                let newTrackNumber = doc.timeline.maskTracks.count + 1
                let newTrack = MaskTrack(
                    name: "Blur Track \(newTrackNumber)",
                    items: [item]
                )
                doc.timeline.maskTracks.append(newTrack)
            }
        }
        selectedMaskId = item.id
        selectedInspectorTab = .masks
    }

    public func addEmptyMaskTrack() {
        mutate { doc in
            let nextNum = doc.timeline.maskTracks.count + 1
            doc.timeline.maskTracks.append(MaskTrack(name: "Blur Track \(nextNum)"))
        }
    }

    public func activeMasks(atSourceMs sourceMs: Double) -> [MaskItem] {
        var result: [MaskItem] = []
        for track in document.timeline.maskTracks {
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

    // MARK: - Copy Chosen System/Custom Wallpaper into `.nativescreen/assets/` for Cross-Platform Portability

    public func selectSystemWallpaper(_ item: SystemWallpaperItem) {
        let assetsDir = packageURL.appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let destFileName = "background-\(item.id).jpg"
        let destURL = assetsDir.appendingPathComponent(destFileName)

        if !FileManager.default.fileExists(atPath: destURL.path) {
            if let nsImage = NSImage(contentsOf: item.fullImageURL),
               let tiff = nsImage.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let jpgData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) {
                try? jpgData.write(to: destURL, options: .atomic)
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
}
