import Foundation
import CoreGraphics
import UniformTypeIdentifiers

/// Annotation tracks: text and arrows drawn over the video. Items on one track never overlap, like masks.
extension ProjectSession {

    // MARK: Lookup

    /// Items shown at `sourceMs` with their geometry at that moment (keyframes resolved), bottom layer first. The first
    /// track (the top row on the timeline) draws on top.
    public func activeAnnotations(atSourceMs sourceMs: Double) -> [AnnotationItem] {
        var result: [AnnotationItem] = []
        for track in document.timeline.annotationTracks.reversed() where !track.isHidden {
            for item in track.items where !item.disabled && sourceMs >= item.sourceStartMs && sourceMs <= item.sourceEndMs {
                result.append(item.keyframes.isEmpty ? item : item.resolved(atSourceMs: sourceMs))
            }
        }
        return result
    }

    /// Steps are numbered by when they start (then by layer, top first), skipping disabled ones and hidden tracks.
    public var annotationStepNumbers: [String: Int] {
        var steps: [(start: Double, track: Int, id: String)] = []
        for (t, track) in document.timeline.annotationTracks.enumerated() where !track.isHidden {
            for item in track.items where item.kind == .step && !item.disabled {
                steps.append((item.sourceStartMs, t, item.id))
            }
        }
        steps.sort { $0.start != $1.start ? $0.start < $1.start : $0.track < $1.track }
        var numbers: [String: Int] = [:]
        for (i, step) in steps.enumerated() { numbers[step.id] = i + 1 }
        return numbers
    }

    public func annotation(id: String) -> AnnotationItem? {
        for track in document.timeline.annotationTracks {
            if let item = track.items.first(where: { $0.id == id }) { return item }
        }
        return nil
    }

    public var outputCanvasAspect: Double {
        document.canvas.effectiveAspectRatio(
            sourceWidth: Double(metadata.captureTarget.pixelSize.width),
            sourceHeight: Double(metadata.captureTarget.pixelSize.height)
        )
    }

    /// Maps between full-frame recording coordinates and a canvas of `canvasSize` (top-left origin) at `sourceMs`,
    /// with the crop, layout and zoom the compositor uses.
    public func canvasTransform(atSourceMs sourceMs: Double, canvasSize: CGSize) -> CanvasCoordinateTransform {
        let camera = evaluatedCamera(atSourceMs: sourceMs)
        let crop = document.canvas.cropRect01
        let stage = MetalFrameCompositor.resolvedStageLayout(
            session: self,
            sourceTimeMs: sourceMs,
            canvasRect: CGRect(origin: .zero, size: canvasSize),
            screenSourceSize: CGSize(
                width: max(16.0, CGFloat(max(640, metadata.captureTarget.pixelSize.width)) * CGFloat(crop.width)),
                height: max(16.0, CGFloat(max(400, metadata.captureTarget.pixelSize.height)) * CGFloat(crop.height))
            ),
            zoomScale: camera.scale
        )
        return CanvasCoordinateTransform(
            canvasSize: canvasSize,
            screenRectBottomLeft: stage.screenRect,
            cropRect01: crop,
            cameraCenter01: camera.isLoupeMode ? .center : camera.center01,
            cameraScale: camera.isLoupeMode ? 1.0 : camera.scale
        )
    }

    // MARK: Selection

    public func selectAnnotation(_ id: String?) {
        clearTimelineSelection()
        selectedAnnotationId = id
    }

    // MARK: Adding

    private var annotationSourceBounds: (start: Double, end: Double) {
        let start = document.timeline.slices.map(\.sourceStartMs).min() ?? 0.0
        let end = document.timeline.slices.map(\.sourceEndMs).max() ?? max(500.0, metadata.durationMs)
        return (start, end)
    }

    /// A new item placed in the middle of what is visible at `sourceMs`, so it lands on screen even when zoomed in.
    private func newAnnotation(kind: AnnotationKind, sourceStartMs: Double, sourceEndMs: Double) -> AnnotationItem {
        let transform = canvasTransform(atSourceMs: sourceStartMs, canvasSize: CGSize(width: 1000, height: 1000 / max(0.1, outputCanvasAspect)))
        let visible = transform.visibleScreenRect
        func source(_ fx: CGFloat, _ fy: CGFloat) -> Point01 {
            let p = transform.sourcePoint01(fromCanvasPoint: CGPoint(
                x: visible.minX + visible.width * fx,
                y: visible.minY + visible.height * fy
            ))
            return Point01(x: min(1.0, max(0.0, p.x)), y: min(1.0, max(0.0, p.y)))
        }
        // The first click from just before the item to a few seconds in is usually what it is about: point at it.
        let click = firstRecordedClick(from: sourceStartMs - 300, to: min(sourceEndMs, sourceStartMs + 2500))
        let clickCanvas = click.map { transform.canvasPoint(fromSource01: $0) }
        func near(_ dx: CGFloat, _ dy: CGFloat) -> Point01? {
            guard let c = clickCanvas else { return nil }
            let p = transform.sourcePoint01(fromCanvasPoint: CGPoint(x: c.x + dx * visible.width, y: c.y + dy * visible.height))
            return Point01(x: min(1.0, max(0.0, p.x)), y: min(1.0, max(0.0, p.y)))
        }
        switch kind {
        case .text:
            return AnnotationItem(
                sourceStartMs: sourceStartMs,
                sourceEndMs: sourceEndMs,
                kind: .text,
                text: String(localized: "Add your text"),
                position01: near(0, -0.12) ?? source(0.5, 0.3)
            )
        case .arrow:
            return AnnotationItem(
                sourceStartMs: sourceStartMs,
                sourceEndMs: sourceEndMs,
                kind: .arrow,
                from01: near(-0.14, 0.14) ?? source(0.36, 0.64),
                to01: click ?? source(0.5, 0.5)
            )
        case .image:
            return AnnotationItem(
                sourceStartMs: sourceStartMs,
                sourceEndMs: sourceEndMs,
                kind: .image,
                position01: source(0.5, 0.5),
                maxWidthRatio: 0.25,
                cornerRatio: 0.01
            )
        case .pen:
            // A short wave under the click, as a starting point; strokes usually come from drawing while recording.
            let center = clickCanvas.map { CGPoint(x: ($0.x - visible.minX) / max(1, visible.width), y: ($0.y - visible.minY) / max(1, visible.height)) }
                ?? CGPoint(x: 0.5, y: 0.5)
            let a = source(center.x - 0.1, center.y + 0.04)
            let b = source(center.x + 0.1, center.y + 0.08)
            let points = (0...16).map { i -> Point01 in
                let t = Double(i) / 16
                return Point01(x: t, y: 0.5 + 0.4 * sin(t * .pi * 4))
            }
            return AnnotationItem(
                sourceStartMs: sourceStartMs,
                sourceEndMs: sourceEndMs,
                kind: .pen,
                position01: Point01(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5),
                strokeRatio: 0.005,
                size01: Size01(width: AnnotationItem.clampedSize(abs(b.x - a.x)), height: AnnotationItem.clampedSize(abs(b.y - a.y))),
                points01: points,
                pointTimesMs: points.indices.map { Double($0) * 25 },
                enter: .draw,
                exit: .fade,
                animationMs: 300
            )
        case .rectangle, .ellipse:
            let center = clickCanvas.map { CGPoint(x: ($0.x - visible.minX) / max(1, visible.width), y: ($0.y - visible.minY) / max(1, visible.height)) }
                ?? CGPoint(x: 0.5, y: 0.5)
            let a = source(center.x - 0.12, center.y - 0.08)
            let b = source(center.x + 0.12, center.y + 0.08)
            return AnnotationItem(
                sourceStartMs: sourceStartMs,
                sourceEndMs: sourceEndMs,
                kind: kind,
                position01: Point01(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5),
                size01: Size01(width: AnnotationItem.clampedSize(abs(b.x - a.x)), height: AnnotationItem.clampedSize(abs(b.y - a.y))),
                enter: .draw,
                exit: .fade,
                animationMs: 400
            )
        case .step:
            return AnnotationItem(
                sourceStartMs: sourceStartMs,
                sourceEndMs: sourceEndMs,
                kind: .step,
                position01: near(-0.045, -0.06) ?? source(0.5, 0.5),
                fontSizeRatio: 0.036,
                enter: .pop,
                exit: .fade
            )
        }
    }

    private func insertAnnotation(_ item: AnnotationItem, preferredTrackId: String? = nil) {
        var targetTrackId = ""
        mutate { doc in
            func isFree(_ track: AnnotationTrack) -> Bool {
                !track.items.contains { !(item.sourceEndMs <= $0.sourceStartMs + 20.0 || item.sourceStartMs >= $0.sourceEndMs - 20.0) }
            }
            let index = preferredTrackId.flatMap { id in doc.timeline.annotationTracks.firstIndex { $0.id == id && isFree($0) } }
                ?? doc.timeline.annotationTracks.firstIndex(where: isFree)
            if let index {
                doc.timeline.annotationTracks[index].isHidden = false
                doc.timeline.annotationTracks[index].items.append(item)
                doc.timeline.annotationTracks[index].items.sort { $0.sourceStartMs < $1.sourceStartMs }
                targetTrackId = doc.timeline.annotationTracks[index].id
            } else {
                let track = AnnotationTrack(name: AnnotationTrack.defaultName(index: doc.timeline.annotationTracks.count), items: [item])
                doc.timeline.annotationTracks.append(track)
                targetTrackId = track.id
            }
        }
        selectAnnotation(item.id)
        if !targetTrackId.isEmpty {
            scrollToTimelineTrack("track_annotation_\(targetTrackId)")
        }
    }

    public func addAnnotationAtPlayhead(kind: AnnotationKind) {
        isPlaying = false
        let bounds = annotationSourceBounds
        let srcMs = committedSourceTimeMs
        let end = min(bounds.end, srcMs + 3000.0)
        let start = max(bounds.start, min(srcMs, end - 1000.0))
        guard end - start >= AnnotationItem.minDurationMs else { return }
        insertAnnotation(newAnnotation(kind: kind, sourceStartMs: start, sourceEndMs: end))
    }

    /// Adds an item over `sourceStartMs...sourceEndMs` on the first track free then (a new track if none).
    public func addAnnotationInTimeRange(kind: AnnotationKind, sourceStartMs: Double, sourceEndMs: Double) {
        insertAnnotation(newAnnotation(kind: kind, sourceStartMs: sourceStartMs, sourceEndMs: sourceEndMs))
    }

    /// Adds an item in an empty span of a track (the `+` shown when hovering a track). It copies the kind and look of
    /// the item before it, so a run of steps keeps one style.
    public func addAnnotationInRange(trackId: String, sourceStartMs: Double, sourceEndMs: Double) {
        guard sourceEndMs - sourceStartMs >= AnnotationItem.minDurationMs else { return }
        let track = document.timeline.annotationTracks.first { $0.id == trackId }
        let reference = track?.items.last { $0.sourceEndMs <= sourceStartMs + 1.0 } ?? track?.items.first
        var item = newAnnotation(kind: reference?.kind ?? .text, sourceStartMs: sourceStartMs, sourceEndMs: sourceEndMs)
        if let reference {
            let fresh = item
            item = reference
            item.id = fresh.id
            item.sourceStartMs = sourceStartMs
            item.sourceEndMs = sourceEndMs
            item.disabled = false
            if reference.anchor == .screen {
                item.position01 = fresh.position01
                item.from01 = fresh.from01
                item.to01 = fresh.to01
            }
        }
        insertAnnotation(item, preferredTrackId: trackId)
    }

    // MARK: Editing

    public func updateAnnotation(id: String, _ change: (inout AnnotationItem) -> Void) {
        mutate { doc in
            for t in doc.timeline.annotationTracks.indices {
                if let i = doc.timeline.annotationTracks[t].items.firstIndex(where: { $0.id == id }) {
                    change(&doc.timeline.annotationTracks[t].items[i])
                    return
                }
            }
        }
        renderRevision &+= 1
    }

    /// Changes what the item is pinned to and keeps it where it is on screen at the playhead.
    public func setAnnotationAnchor(id: String, anchor: AnnotationAnchor) {
        guard let item = annotation(id: id), item.anchor != anchor else { return }
        let size = CGSize(width: 1000, height: 1000 / max(0.1, outputCanvasAspect))
        let srcMs = min(item.sourceEndMs, max(item.sourceStartMs, committedSourceTimeMs))
        let transform = canvasTransform(atSourceMs: srcMs, canvasSize: size)
        func convert(_ p: Point01) -> Point01 {
            switch anchor {
            case .canvas:
                let c = transform.canvasPoint(fromSource01: p)
                return Point01(x: min(1, max(0, Double(c.x / size.width))), y: min(1, max(0, Double(c.y / size.height))))
            case .screen:
                let s = transform.sourcePoint01(fromCanvasPoint: CGPoint(x: CGFloat(p.x) * size.width, y: CGFloat(p.y) * size.height))
                return Point01(x: min(1, max(0, s.x)), y: min(1, max(0, s.y)))
            }
        }
        func convertGeometry(_ k: AnnotationKeyframe) -> AnnotationKeyframe {
            var k = k
            // A shape keeps its size on screen: convert two corners, not only the center.
            let a0 = convert(Point01(x: k.position01.x - k.size01.width * 0.5, y: k.position01.y - k.size01.height * 0.5))
            let a1 = convert(Point01(x: k.position01.x + k.size01.width * 0.5, y: k.position01.y + k.size01.height * 0.5))
            k.size01 = Size01(width: AnnotationItem.clampedSize(abs(a1.x - a0.x)), height: AnnotationItem.clampedSize(abs(a1.y - a0.y)))
            k.position01 = convert(k.position01)
            k.from01 = convert(k.from01)
            k.to01 = convert(k.to01)
            return k
        }
        updateAnnotation(id: id) { a in
            a.applyGeometry(convertGeometry(a.keyframe(atSourceMs: 0)))
            a.keyframes = a.keyframes.map(convertGeometry)
            a.anchor = anchor
        }
    }

    private func neighborBounds(trackIndex: Int, id: String) -> (lower: Double, upper: Double)? {
        let bounds = annotationSourceBounds
        let items = document.timeline.annotationTracks[trackIndex].items.sorted { $0.sourceStartMs < $1.sourceStartMs }
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return nil }
        let lower = idx > 0 ? max(bounds.start, items[idx - 1].sourceEndMs) : bounds.start
        let upper = idx + 1 < items.count ? min(bounds.end, items[idx + 1].sourceStartMs) : bounds.end
        return (lower, upper)
    }

    private func trackIndex(ofAnnotation id: String) -> Int? {
        document.timeline.annotationTracks.firstIndex { $0.items.contains { $0.id == id } }
    }

    public func moveAnnotation(id: String, desiredStartMs: Double, durationMs: Double) {
        guard let t = trackIndex(ofAnnotation: id), let (lower, upper) = neighborBounds(trackIndex: t, id: id) else { return }
        let span = max(AnnotationItem.minDurationMs, durationMs)
        guard upper - lower >= span else { return }
        let start = max(lower, min(upper - span, desiredStartMs))
        updateAnnotation(id: id) { a in
            a.shiftTime(by: start - a.sourceStartMs)
            a.sourceEndMs = start + span
        }
    }

    /// Moves one edge. Neighbors on the track stop it, edge to edge.
    public func resizeAnnotation(id: String, newStartMs: Double, newEndMs: Double) {
        guard let t = trackIndex(ofAnnotation: id),
              let (lower, upper) = neighborBounds(trackIndex: t, id: id),
              let current = annotation(id: id) else { return }
        let minDur = AnnotationItem.minDurationMs
        let isLeft = abs(newEndMs - current.sourceEndMs) < 0.5
        updateAnnotation(id: id) { a in
            if isLeft {
                a.sourceStartMs = max(lower, min(a.sourceEndMs - minDur, newStartMs))
            } else {
                a.sourceEndMs = max(a.sourceStartMs + minDur, min(upper, newEndMs))
            }
        }
    }

    /// Moves an item to another track, or to a new one above or below all of them. It stays where it was when the
    /// target track is busy at that time.
    public func moveAnnotationToTrack(id: String, targetTrackIndex: Int) {
        mutate { doc in
            guard let from = doc.timeline.annotationTracks.firstIndex(where: { $0.items.contains { $0.id == id } }),
                  from != targetTrackIndex,
                  let i = doc.timeline.annotationTracks[from].items.firstIndex(where: { $0.id == id }) else { return }
            let item = doc.timeline.annotationTracks[from].items[i]
            if targetTrackIndex < 0 || targetTrackIndex >= doc.timeline.annotationTracks.count {
                doc.timeline.annotationTracks[from].items.remove(at: i)
                let track = AnnotationTrack(name: "", items: [item])
                if targetTrackIndex < 0 {
                    doc.timeline.annotationTracks.insert(track, at: 0)
                } else {
                    doc.timeline.annotationTracks.append(track)
                }
                return
            }
            let busy = doc.timeline.annotationTracks[targetTrackIndex].items.contains {
                !(item.sourceEndMs <= $0.sourceStartMs + 20.0 || item.sourceStartMs >= $0.sourceEndMs - 20.0)
            }
            guard !busy else { return }
            doc.timeline.annotationTracks[from].items.remove(at: i)
            doc.timeline.annotationTracks[targetTrackIndex].items.append(item)
            doc.timeline.annotationTracks[targetTrackIndex].items.sort { $0.sourceStartMs < $1.sourceStartMs }
        }
    }

    public func splitAnnotation(id: String, atSourceMs sourceMs: Double) {
        guard let original = annotation(id: id) else { return }
        guard sourceMs > original.sourceStartMs + 180.0 && sourceMs < original.sourceEndMs - 180.0 else {
            showToast("Can't cut item shorter than 0.2s", durationMs: 2000)
            return
        }
        var secondId = ""
        mutate { doc in
            for t in doc.timeline.annotationTracks.indices {
                guard let i = doc.timeline.annotationTracks[t].items.firstIndex(where: { $0.id == id }) else { continue }
                var first = original
                first.id = UUID().uuidString
                first.sourceEndMs = sourceMs
                var second = original
                second.id = UUID().uuidString
                second.sourceStartMs = sourceMs
                if !original.keyframes.isEmpty {
                    // Each half keeps its own keyframes plus one at the cut, so neither jumps.
                    let atCut = original.resolved(atSourceMs: sourceMs).keyframe(atSourceMs: sourceMs)
                    first.keyframes = original.keyframes.filter { $0.sourceMs < sourceMs - 1 } + [atCut]
                    second.keyframes = [atCut] + original.keyframes.filter { $0.sourceMs > sourceMs + 1 }
                }
                secondId = second.id
                doc.timeline.annotationTracks[t].items.replaceSubrange(i...i, with: [first, second])
                return
            }
        }
        if !secondId.isEmpty {
            selectAnnotation(secondId)
        }
    }

    public func deleteAnnotation(id: String) {
        mutate { doc in
            for t in doc.timeline.annotationTracks.indices {
                doc.timeline.annotationTracks[t].items.removeAll { $0.id == id }
            }
        }
        if selectedAnnotationId == id {
            selectedAnnotationId = nil
        }
    }

    // MARK: Geometry edits and keyframes

    /// Changes an item as it is shown at `sourceMs`. Without keyframes that is the item itself; with keyframes the new
    /// geometry goes into the keyframe at that moment (within 120 ms), or a new one. Other fields change directly.
    public func editAnnotationGeometry(id: String, atSourceMs sourceMs: Double, _ change: (inout AnnotationItem) -> Void) {
        updateAnnotation(id: id) { item in
            guard !item.keyframes.isEmpty else {
                change(&item)
                return
            }
            var shown = item.resolved(atSourceMs: sourceMs)
            change(&shown)
            let edited = shown.keyframe(atSourceMs: sourceMs)
            var keyframes = item.keyframes
            if let i = keyframes.firstIndex(where: { abs($0.sourceMs - sourceMs) < 120 }) {
                keyframes[i] = AnnotationKeyframe(
                    sourceMs: keyframes[i].sourceMs,
                    position01: edited.position01,
                    from01: edited.from01,
                    to01: edited.to01,
                    size01: edited.size01,
                    rotationDegrees: edited.rotationDegrees
                )
            } else {
                keyframes.append(edited)
                keyframes.sort { $0.sourceMs < $1.sourceMs }
            }
            shown.applyGeometry(item.keyframe(atSourceMs: 0))
            shown.keyframes = keyframes
            item = shown
        }
    }

    /// Adds a keyframe at the playhead holding where the item is now. The first one also pins the start, so the item
    /// moves from where it began.
    public func addAnnotationKeyframe(id: String) {
        guard let item = annotation(id: id) else { return }
        let t = min(item.sourceEndMs, max(item.sourceStartMs, committedSourceTimeMs))
        updateAnnotation(id: id) { a in
            let here = a.resolved(atSourceMs: t).keyframe(atSourceMs: t)
            if a.keyframes.isEmpty && t - a.sourceStartMs > 120 {
                a.keyframes.append(a.keyframe(atSourceMs: a.sourceStartMs))
            }
            a.keyframes.removeAll { abs($0.sourceMs - t) < 120 }
            a.keyframes.append(here)
            a.keyframes.sort { $0.sourceMs < $1.sourceMs }
        }
    }

    public func removeAnnotationKeyframe(id: String, at index: Int) {
        updateAnnotation(id: id) { a in
            guard a.keyframes.indices.contains(index) else { return }
            // The last keyframe left becomes the item's own geometry.
            if a.keyframes.count == 1 { a.applyGeometry(a.keyframes[0]) }
            a.keyframes.remove(at: index)
        }
    }

    /// Stops the motion, keeping the item where it is at the playhead.
    public func clearAnnotationKeyframes(id: String) {
        guard let item = annotation(id: id) else { return }
        let t = min(item.sourceEndMs, max(item.sourceStartMs, committedSourceTimeMs))
        updateAnnotation(id: id) { a in
            a.applyGeometry(a.resolved(atSourceMs: t).keyframe(atSourceMs: t))
            a.keyframes = []
        }
    }

    // MARK: Recorded clicks

    /// Where the pointer went down, from `start` to `end`, in recording coordinates.
    public func recordedClicks(from start: Double, to end: Double) -> [Point01] {
        clickEvents
            .filter { $0.type == "down" && $0.t >= start && $0.t <= end }
            .map { Point01(x: $0.x, y: $0.y) }
    }

    private func firstRecordedClick(from start: Double, to end: Double) -> Point01? {
        clickEvents.first { $0.type == "down" && $0.t >= start && $0.t <= end }.map { Point01(x: $0.x, y: $0.y) }
    }

    // MARK: Images

    /// Copies a picture into `assets/annotations/` and returns its path relative to the package.
    public func importAnnotationImage(from url: URL) -> String? {
        let dir = packageURL.appendingPathComponent("assets/annotations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let name = "\(UUID().uuidString).\(ext)"
        do {
            try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(name))
            return "assets/annotations/\(name)"
        } catch {
            showToast("Could not copy the image")
            return nil
        }
    }

    public func addImageAnnotation(from url: URL) {
        guard let path = importAnnotationImage(from: url) else { return }
        isPlaying = false
        let bounds = annotationSourceBounds
        let srcMs = committedSourceTimeMs
        let end = min(bounds.end, srcMs + 3000.0)
        let start = max(bounds.start, min(srcMs, end - 1000.0))
        guard end - start >= AnnotationItem.minDurationMs else { return }
        var item = newAnnotation(kind: .image, sourceStartMs: start, sourceEndMs: end)
        item.imagePath = path
        insertAnnotation(item)
    }

    public func replaceAnnotationImage(id: String, from url: URL) {
        guard let path = importAnnotationImage(from: url) else { return }
        updateAnnotation(id: id) { $0.imagePath = path }
    }

    // MARK: Custom cursors

    public enum CustomCursorSlot: Sendable { case pointer, hand }

    /// Copies a picture into `assets/cursors/` and uses it for the arrow or the hand. The tip starts at the top left for
    /// the arrow and near the top middle for the hand, and can be moved in the Cursor inspector.
    public func setCustomCursor(_ slot: CustomCursorSlot, from url: URL) {
        let dir = packageURL.appendingPathComponent("assets/cursors", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let name = "\(UUID().uuidString).\(ext)"
        do {
            try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(name))
        } catch {
            showToast("Could not copy the image")
            return
        }
        let image = CustomCursorImage(
            imagePath: "assets/cursors/\(name)",
            hotspot01: slot == .pointer ? Point01(x: 0.0, y: 0.0) : Point01(x: 0.45, y: 0.05)
        )
        mutate { doc in
            switch slot {
            case .pointer: doc.cursor.customPointer = image
            case .hand: doc.cursor.customHand = image
            }
        }
    }

    public func setCustomCursorHotspot(_ slot: CustomCursorSlot, _ hotspot: Point01) {
        let clamped = Point01(x: min(1, max(0, hotspot.x)), y: min(1, max(0, hotspot.y)))
        mutate { doc in
            switch slot {
            case .pointer: doc.cursor.customPointer?.hotspot01 = clamped
            case .hand: doc.cursor.customHand?.hotspot01 = clamped
            }
        }
    }

    public func removeCustomCursor(_ slot: CustomCursorSlot) {
        mutate { doc in
            switch slot {
            case .pointer: doc.cursor.customPointer = nil
            case .hand: doc.cursor.customHand = nil
            }
        }
    }

    // MARK: Styles

    public func applyAnnotationStyle(_ style: AnnotationStyle, to id: String) {
        updateAnnotation(id: id) { style.apply(to: &$0) }
    }

    /// Applies a style to every annotation, one undo step.
    public func applyAnnotationStyleToAll(_ style: AnnotationStyle) {
        mutate { doc in
            for t in doc.timeline.annotationTracks.indices {
                for i in doc.timeline.annotationTracks[t].items.indices {
                    style.apply(to: &doc.timeline.annotationTracks[t].items[i])
                }
            }
        }
    }

    // MARK: Layers

    public enum AnnotationLayerMove: String, CaseIterable, Sendable {
        case front, forward, backward, back

        public var title: String {
            switch self {
            case .front: return "Bring to front"
            case .forward: return "Bring forward"
            case .backward: return "Send backward"
            case .back: return "Send to back"
            }
        }

        public var systemImage: String {
            switch self {
            case .front: return "square.3.layers.3d.top.filled"
            case .forward: return "square.2.layers.3d.top.filled"
            case .backward: return "square.2.layers.3d.bottom.filled"
            case .back: return "square.3.layers.3d.bottom.filled"
            }
        }
    }

    /// Layers are tracks: the first track draws on top. An item moves to the next track up or down when it is free at
    /// that time, and otherwise a new track is made right past it, so the item always ends up above (or below) what was
    /// in the way.
    public func moveAnnotationLayer(id: String, _ move: AnnotationLayerMove) {
        mutate { doc in
            guard let from = doc.timeline.annotationTracks.firstIndex(where: { $0.items.contains { $0.id == id } }),
                  let i = doc.timeline.annotationTracks[from].items.firstIndex(where: { $0.id == id }) else { return }
            let item = doc.timeline.annotationTracks[from].items[i]
            let count = doc.timeline.annotationTracks.count
            func isFree(_ t: Int) -> Bool {
                !doc.timeline.annotationTracks[t].items.contains {
                    $0.id != id && !(item.sourceEndMs <= $0.sourceStartMs + 20.0 || item.sourceStartMs >= $0.sourceEndMs - 20.0)
                }
            }
            /// `target` is an existing track to join, or nil with `insertAt` for a new one.
            var target: Int?
            var insertAt = 0
            switch move {
            case .forward:
                guard from > 0 else { return }
                if isFree(from - 1) { target = from - 1 } else { insertAt = from - 1 }
            case .front:
                guard from > 0 else { return }
                if isFree(0) { target = 0 } else { insertAt = 0 }
            case .backward:
                guard from < count - 1 else { return }
                if isFree(from + 1) { target = from + 1 } else { insertAt = from + 2 }
            case .back:
                guard from < count - 1 else { return }
                if isFree(count - 1) { target = count - 1 } else { insertAt = count }
            }
            if let target {
                doc.timeline.annotationTracks[target].items.append(item)
                doc.timeline.annotationTracks[target].items.sort { $0.sourceStartMs < $1.sourceStartMs }
                doc.timeline.annotationTracks[target].isHidden = false
                doc.timeline.annotationTracks[from].items.remove(at: i)
            } else {
                doc.timeline.annotationTracks[from].items.remove(at: i)
                doc.timeline.annotationTracks.insert(AnnotationTrack(name: "", items: [item]), at: insertAt)
            }
        }
        selectedAnnotationId = id
        renderRevision &+= 1
    }

    // MARK: Copy, paste and duplicate

    public func copyAnnotation(id: String) {
        guard let item = annotation(id: id) else { return }
        copiedAnnotation = item
        copiedZoomBlock = nil
        copiedMaskItem = nil
        showToast("Annotation copied")
    }

    public func cutAnnotation(id: String) {
        guard annotation(id: id) != nil else { return }
        copyAnnotation(id: id)
        deleteAnnotation(id: id)
    }

    /// Pastes the copied item at the playhead, on the first track free then.
    public func pasteAnnotation() {
        guard var item = copiedAnnotation else { return }
        let bounds = annotationSourceBounds
        let duration = max(AnnotationItem.minDurationMs, item.sourceEndMs - item.sourceStartMs)
        let start = max(bounds.start, min(committedSourceTimeMs, bounds.end - duration))
        item.id = UUID().uuidString
        item.shiftTime(by: start - item.sourceStartMs)
        item.sourceEndMs = min(bounds.end, start + duration)
        guard item.sourceEndMs - item.sourceStartMs >= AnnotationItem.minDurationMs else { return }
        insertAnnotation(item)
    }

    /// A copy right after the item on its own track when it fits there, otherwise at the same time on another track.
    public func duplicateAnnotation(id: String) {
        guard let original = annotation(id: id), let t = trackIndex(ofAnnotation: id) else { return }
        let duration = original.sourceEndMs - original.sourceStartMs
        var copy = original
        copy.id = UUID().uuidString
        let bounds = annotationSourceBounds
        let after = original.sourceEndMs
        let fitsAfter = after + duration <= bounds.end + 0.5
            && !document.timeline.annotationTracks[t].items.contains {
                $0.id != id && !(after + duration <= $0.sourceStartMs + 20.0 || after >= $0.sourceEndMs - 20.0)
            }
        if fitsAfter {
            copy.shiftTime(by: after - original.sourceStartMs)
            insertAnnotation(copy, preferredTrackId: document.timeline.annotationTracks[t].id)
        } else {
            insertAnnotation(copy)
        }
    }

    public func toggleAnnotationTrackVisibility(trackId: String) {
        mutate { doc in
            if let t = doc.timeline.annotationTracks.firstIndex(where: { $0.id == trackId }) {
                doc.timeline.annotationTracks[t].isHidden.toggle()
            }
        }
    }
}
