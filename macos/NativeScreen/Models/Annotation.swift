import Foundation

// MARK: - Annotations (`timeline.annotationTracks`)

public enum AnnotationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case text
    case arrow
    case rectangle
    case ellipse
    /// A numbered badge. Steps are numbered 1, 2, 3... in the order they appear (`ProjectSession.annotationStepNumbers`).
    case step
    /// A picture copied into the package (`imagePath`), `maxWidthRatio` of the frame wide.
    case image
    /// A freehand stroke (`points01` inside its `size01` box), usually drawn live while recording. `highlighter`
    /// makes it a wide, see-through marker.
    case pen

    public var id: String { rawValue }

    /// Kinds sized by `size01` that zoom with the recording: they frame something, so they must keep framing it.
    public var isShape: Bool { self == .rectangle || self == .ellipse || self == .pen }
    /// Kinds the Add annotation menu offers. A pen stroke only comes from drawing.
    public var isAddable: Bool { self != .pen }
    /// Kinds that can be drawn on progressively.
    public var supportsDrawOn: Bool { self == .arrow || isShape }
    public var canRotate: Bool { self != .arrow }

    public var systemImage: String {
        switch self {
        case .text: return "textformat"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .step: return "1.circle"
        case .image: return "photo"
        case .pen: return "pencil.tip"
        }
    }

    public var title: String {
        switch self {
        case .text: return "Text"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .step: return "Step"
        case .image: return "Image"
        case .pen: return "Drawing"
        }
    }
}

/// Where an item is at one moment. Between keyframes the geometry eases from one to the next.
public struct AnnotationKeyframe: Codable, Equatable, Hashable, Sendable {
    public var sourceMs: Double
    public var position01: Point01
    public var from01: Point01
    public var to01: Point01
    public var size01: Size01
    public var rotationDegrees: Double

    public init(sourceMs: Double, position01: Point01, from01: Point01, to01: Point01, size01: Size01, rotationDegrees: Double) {
        self.sourceMs = sourceMs
        self.position01 = position01
        self.from01 = from01
        self.to01 = to01
        self.size01 = size01
        self.rotationDegrees = rotationDegrees
    }
}

public struct Size01: Codable, Equatable, Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// What an annotation is pinned to.
/// - `screen`: the recording. Its points use the full-frame coordinates masks use, so it stays on what it points at
///   through zoom, pan, crop and layout changes.
/// - `canvas`: the output frame. It stays put whatever the recording does.
public enum AnnotationAnchor: String, Codable, CaseIterable, Identifiable, Sendable {
    case screen
    case canvas

    public var id: String { rawValue }
}

public enum AnnotationAnimation: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case fade
    /// Scales up from 60% with a little overshoot (down to 60% when leaving).
    case pop
    /// Moves up into place (and on up when leaving) while fading.
    case rise
    /// Draws the line on (and off). Text and steps fade instead.
    case draw
    /// Slides in from the left (and out to the right) while fading.
    case slide
    /// Types the text in one character at a time (and erases it when leaving). Other kinds fade instead.
    case typewriter

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: return "None"
        case .fade: return "Fade"
        case .pop: return "Pop"
        case .rise: return "Rise"
        case .draw: return "Draw"
        case .slide: return "Slide"
        case .typewriter: return "Typewriter"
        }
    }

    public func isOffered(for kind: AnnotationKind) -> Bool {
        switch self {
        case .draw: return kind.supportsDrawOn
        case .typewriter: return kind == .text
        default: return true
        }
    }
}

/// How an item looks at one moment of its enter and exit animations.
public struct AnnotationAnimationState: Equatable, Sendable {
    public var opacity: Double = 1.0
    public var scale: Double = 1.0
    /// Downward offset as a share of the output frame's shorter side.
    public var offsetY: Double = 0.0
    /// Share of the line drawn, 0...1.
    public var drawProgress: Double = 1.0
    /// Rightward offset as a share of the output frame's shorter side.
    public var offsetX: Double = 0.0
    /// Share of a text's characters shown, 0...1.
    public var reveal: Double = 1.0

    public static let rest = AnnotationAnimationState()
}

public enum AnnotationTextBackground: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case solid

    public var id: String { rawValue }
}

/// One annotation on a track. Every kind keeps every field, so changing the kind or patching one field never loses the rest.
/// Sizes are shares of the output frame, never of the zoomed recording: a zoom moves an annotation but does not enlarge it.
public struct AnnotationItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let defaultArrowColor = "#FF5A36"
    public static let defaultTextColor = "#FFFFFF"
    public static let defaultTextBackgroundColor = "#16161D"
    public static let minDurationMs = 220.0

    public var id: String
    public var sourceStartMs: Double
    public var sourceEndMs: Double
    public var kind: AnnotationKind
    public var anchor: AnnotationAnchor

    /// Text, and the center of its box.
    public var text: String
    public var position01: Point01
    /// Font size as a share of the output frame's shorter side.
    public var fontSizeRatio: Double
    /// Lines wrap at this share of the output frame's width.
    public var maxWidthRatio: Double
    public var bold: Bool
    public var textBackground: AnnotationTextBackground
    public var backgroundColor: String

    /// Arrow from its tail to its head. `bend` pushes the middle sideways by this share of the arrow's length
    /// (positive bends to the left of the direction of travel).
    public var from01: Point01
    public var to01: Point01
    public var bend: Double
    /// Line width as a share of the output frame's shorter side.
    public var strokeRatio: Double

    /// A rectangle or ellipse: its size around `position01`, in the same units as its points (so a screen-pinned shape
    /// zooms with what it frames).
    public var size01: Size01
    /// Clockwise, about the center. Arrows ignore it: their ends set their direction.
    public var rotationDegrees: Double
    /// Fill of a rectangle or ellipse, in `color`, from 0 (outline only) to 1.
    public var fillOpacity: Double
    /// Corner radius of a rectangle as a share of the output frame's shorter side.
    public var cornerRatio: Double

    /// An image's file, relative to the package (`assets/annotations/...`).
    public var imagePath: String
    /// Geometry over time. Empty: the item stays where its own fields put it.
    public var keyframes: [AnnotationKeyframe]

    /// A pen stroke: its points inside the `size01` box around `position01` (0...1, top-left origin), and when each was
    /// drawn, in ms after the first. Drawing on replays the stroke at the speed it was drawn.
    public var points01: [Point01]
    public var pointTimesMs: [Double]
    /// A pen stroke drawn as a wide, see-through marker.
    public var highlighter: Bool
    /// Indices into `points01` where a new stroke begins (the pen was lifted before it). Empty: one stroke.
    public var strokeStarts: [Int]

    /// Text color for text, line color for an arrow or shape, badge color for a step, as `#RRGGBB`.
    public var color: String
    public var enter: AnnotationAnimation
    public var exit: AnnotationAnimation
    public var animationMs: Double
    public var disabled: Bool

    public init(
        id: String = UUID().uuidString,
        sourceStartMs: Double,
        sourceEndMs: Double,
        kind: AnnotationKind,
        anchor: AnnotationAnchor = .screen,
        text: String = "",
        position01: Point01 = .center,
        fontSizeRatio: Double = 0.042,
        maxWidthRatio: Double = 0.5,
        bold: Bool = true,
        textBackground: AnnotationTextBackground = .solid,
        backgroundColor: String = AnnotationItem.defaultTextBackgroundColor,
        from01: Point01 = Point01(x: 0.4, y: 0.6),
        to01: Point01 = .center,
        bend: Double = 0.18,
        strokeRatio: Double = 0.007,
        size01: Size01 = Size01(width: 0.22, height: 0.12),
        rotationDegrees: Double = 0.0,
        fillOpacity: Double = 0.0,
        cornerRatio: Double = 0.012,
        imagePath: String = "",
        keyframes: [AnnotationKeyframe] = [],
        points01: [Point01] = [],
        pointTimesMs: [Double] = [],
        highlighter: Bool = false,
        strokeStarts: [Int] = [],
        color: String? = nil,
        enter: AnnotationAnimation = .fade,
        exit: AnnotationAnimation = .fade,
        animationMs: Double = 250.0,
        disabled: Bool = false
    ) {
        self.id = id
        self.sourceStartMs = sourceStartMs
        self.sourceEndMs = sourceEndMs
        self.kind = kind
        self.anchor = anchor
        self.text = text
        self.position01 = position01
        self.fontSizeRatio = fontSizeRatio
        self.maxWidthRatio = maxWidthRatio
        self.bold = bold
        self.textBackground = textBackground
        self.backgroundColor = backgroundColor
        self.from01 = from01
        self.to01 = to01
        self.bend = bend
        self.strokeRatio = strokeRatio
        self.size01 = size01
        self.rotationDegrees = rotationDegrees
        self.fillOpacity = fillOpacity
        self.cornerRatio = cornerRatio
        self.imagePath = imagePath
        self.keyframes = keyframes
        self.points01 = points01
        self.pointTimesMs = pointTimesMs
        self.highlighter = highlighter
        self.strokeStarts = strokeStarts
        self.color = color ?? Self.defaultColor(for: kind)
        self.enter = enter
        self.exit = exit
        self.animationMs = animationMs
        self.disabled = disabled
    }

    enum CodingKeys: String, CodingKey {
        case id, sourceStartMs, sourceEndMs, kind, anchor
        case text, position01, fontSizeRatio, maxWidthRatio, bold, textBackground, backgroundColor
        case from01, to01, bend, strokeRatio
        case size01, rotationDegrees, fillOpacity, cornerRatio, imagePath, keyframes
        case points01, pointTimesMs, highlighter, strokeStarts
        case color, enter, exit, animationMs, disabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AnnotationItem(sourceStartMs: 0, sourceEndMs: 0, kind: .text)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.sourceStartMs = try c.decode(Double.self, forKey: .sourceStartMs)
        self.sourceEndMs = try c.decode(Double.self, forKey: .sourceEndMs)
        self.kind = try c.decodeIfPresent(AnnotationKind.self, forKey: .kind) ?? .text
        self.anchor = try c.decodeIfPresent(AnnotationAnchor.self, forKey: .anchor) ?? .screen
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.position01 = try c.decodeIfPresent(Point01.self, forKey: .position01) ?? defaults.position01
        self.fontSizeRatio = Self.clampedFontSize(try c.decodeIfPresent(Double.self, forKey: .fontSizeRatio) ?? defaults.fontSizeRatio)
        self.maxWidthRatio = Self.clampedMaxWidth(try c.decodeIfPresent(Double.self, forKey: .maxWidthRatio) ?? defaults.maxWidthRatio)
        self.bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? defaults.bold
        self.textBackground = try c.decodeIfPresent(AnnotationTextBackground.self, forKey: .textBackground) ?? defaults.textBackground
        self.backgroundColor = try c.decodeIfPresent(String.self, forKey: .backgroundColor) ?? defaults.backgroundColor
        self.from01 = try c.decodeIfPresent(Point01.self, forKey: .from01) ?? defaults.from01
        self.to01 = try c.decodeIfPresent(Point01.self, forKey: .to01) ?? defaults.to01
        self.bend = Self.clampedBend(try c.decodeIfPresent(Double.self, forKey: .bend) ?? defaults.bend)
        self.strokeRatio = Self.clampedStroke(try c.decodeIfPresent(Double.self, forKey: .strokeRatio) ?? defaults.strokeRatio)
        let size = try c.decodeIfPresent(Size01.self, forKey: .size01) ?? defaults.size01
        self.size01 = Size01(width: Self.clampedSize(size.width), height: Self.clampedSize(size.height))
        self.rotationDegrees = Self.normalizedRotation(try c.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0.0)
        self.fillOpacity = min(1.0, max(0.0, try c.decodeIfPresent(Double.self, forKey: .fillOpacity) ?? 0.0))
        self.cornerRatio = Self.clampedCorner(try c.decodeIfPresent(Double.self, forKey: .cornerRatio) ?? defaults.cornerRatio)
        self.imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath) ?? ""
        self.keyframes = (try c.decodeIfPresent([AnnotationKeyframe].self, forKey: .keyframes) ?? []).sorted { $0.sourceMs < $1.sourceMs }
        self.points01 = try c.decodeIfPresent([Point01].self, forKey: .points01) ?? []
        let times = try c.decodeIfPresent([Double].self, forKey: .pointTimesMs) ?? []
        // Times are only used when there is one per point.
        self.pointTimesMs = times.count == points01.count ? times : []
        self.highlighter = try c.decodeIfPresent(Bool.self, forKey: .highlighter) ?? false
        let pointCount = points01.count
        self.strokeStarts = (try c.decodeIfPresent([Int].self, forKey: .strokeStarts) ?? [])
            .filter { $0 > 0 && $0 < pointCount }
            .sorted()
        self.color = try c.decodeIfPresent(String.self, forKey: .color) ?? Self.defaultColor(for: kind)
        self.enter = try c.decodeIfPresent(AnnotationAnimation.self, forKey: .enter) ?? defaults.enter
        self.exit = try c.decodeIfPresent(AnnotationAnimation.self, forKey: .exit) ?? defaults.exit
        self.animationMs = Self.clampedAnimation(try c.decodeIfPresent(Double.self, forKey: .animationMs) ?? defaults.animationMs)
        self.disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
    }

    // MARK: Limits (shared by the inspector, the canvas handles and the decoder)

    public static let fontSizeRange: ClosedRange<Double> = 0.015...0.2
    public static let maxWidthRange: ClosedRange<Double> = 0.1...1.0
    public static let strokeRange: ClosedRange<Double> = 0.002...0.03
    public static let bendRange: ClosedRange<Double> = -0.8...0.8
    public static let animationRange: ClosedRange<Double> = 0.0...1500.0
    public static let sizeRange: ClosedRange<Double> = 0.01...1.5
    public static let cornerRange: ClosedRange<Double> = 0.0...0.1

    public static func defaultColor(for kind: AnnotationKind) -> String {
        kind == .text ? defaultTextColor : defaultArrowColor
    }

    public static func clampedFontSize(_ v: Double) -> Double { min(fontSizeRange.upperBound, max(fontSizeRange.lowerBound, v)) }
    public static func clampedMaxWidth(_ v: Double) -> Double { min(maxWidthRange.upperBound, max(maxWidthRange.lowerBound, v)) }
    public static func clampedStroke(_ v: Double) -> Double { min(strokeRange.upperBound, max(strokeRange.lowerBound, v)) }
    public static func clampedBend(_ v: Double) -> Double { min(bendRange.upperBound, max(bendRange.lowerBound, v)) }
    public static func clampedAnimation(_ v: Double) -> Double { min(animationRange.upperBound, max(animationRange.lowerBound, v)) }
    public static func clampedSize(_ v: Double) -> Double { min(sizeRange.upperBound, max(sizeRange.lowerBound, v)) }
    public static func clampedCorner(_ v: Double) -> Double { min(cornerRange.upperBound, max(cornerRange.lowerBound, v)) }
    /// -180 < degrees <= 180.
    public static func normalizedRotation(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        var d = v.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// The enter and exit animations at `sourceMs`. Each lasts `animationMs`, capped at half the item so they never overlap.
    public func animationState(atSourceMs sourceMs: Double) -> AnnotationAnimationState {
        let duration = max(1.0, sourceEndMs - sourceStartMs)
        let span = min(animationMs, duration * 0.5)
        var state = AnnotationAnimationState.rest
        guard span > 0.5 else { return state }

        func smooth(_ t: Double) -> Double { t * t * (3.0 - 2.0 * t) }
        func easeOutCubic(_ t: Double) -> Double { 1.0 - pow(1.0 - t, 3.0) }
        func easeOutBack(_ t: Double) -> Double {
            let c1 = 1.70158, c3 = c1 + 1.0
            return 1.0 + c3 * pow(t - 1.0, 3.0) + c1 * pow(t - 1.0, 2.0)
        }
        func apply(_ animation: AnnotationAnimation, progress p: Double, entering: Bool) {
            guard p < 1.0 else { return }
            switch animation {
            case .none:
                return
            case .fade:
                state.opacity *= smooth(p)
            case .pop:
                state.opacity *= smooth(min(1.0, p * 1.6))
                state.scale *= 0.6 + 0.4 * (entering ? easeOutBack(p) : smooth(p))
            case .rise:
                state.opacity *= smooth(p)
                // Enters from below; leaves upward.
                state.offsetY += (entering ? 1.0 : -1.0) * 0.035 * (1.0 - easeOutCubic(p))
            case .draw:
                if kind == .pen, entering, let strokeMs = pointTimesMs.last, strokeMs > 1 {
                    // A drawn stroke replays at the speed it was drawn, whatever the animation length.
                    state.drawProgress = min(state.drawProgress, min(1.0, max(0.0, (sourceMs - sourceStartMs) / strokeMs)))
                } else if kind.supportsDrawOn {
                    state.drawProgress = min(state.drawProgress, smooth(p))
                } else {
                    state.opacity *= smooth(p)
                }
            case .slide:
                state.opacity *= smooth(p)
                // In from the left, out to the right.
                state.offsetX += (entering ? -1.0 : 1.0) * 0.06 * (1.0 - easeOutCubic(p))
            case .typewriter:
                if kind == .text {
                    state.reveal = min(state.reveal, p)
                } else {
                    state.opacity *= smooth(p)
                }
            }
        }
        // Only a stroke with drawing time replays by its clock: a dot (one point, or all at 0 ms) would stay at progress 0
        // and never show, so it draws on over the animation instead.
        if enter == .draw, kind == .pen, let strokeMs = pointTimesMs.last, strokeMs > 1 {
            apply(enter, progress: 0, entering: true)
        } else {
            apply(enter, progress: min(1.0, max(0.0, (sourceMs - sourceStartMs) / span)), entering: true)
        }
        apply(exit, progress: min(1.0, max(0.0, (sourceEndMs - sourceMs) / span)), entering: false)
        return state
    }

    // MARK: Keyframes

    /// This item's geometry as a keyframe at `sourceMs`.
    public func keyframe(atSourceMs sourceMs: Double) -> AnnotationKeyframe {
        AnnotationKeyframe(sourceMs: sourceMs, position01: position01, from01: from01, to01: to01, size01: size01, rotationDegrees: rotationDegrees)
    }

    public mutating func applyGeometry(_ k: AnnotationKeyframe) {
        position01 = k.position01
        from01 = k.from01
        to01 = k.to01
        size01 = k.size01
        rotationDegrees = k.rotationDegrees
    }

    /// The item with its geometry at `sourceMs`. Before the first keyframe and after the last, it holds; between two it
    /// eases (smoothstep). Rotation takes the shorter way round.
    public func resolved(atSourceMs sourceMs: Double) -> AnnotationItem {
        guard let first = keyframes.first, let last = keyframes.last else { return self }
        var item = self
        if keyframes.count == 1 || sourceMs <= first.sourceMs {
            item.applyGeometry(first)
            return item
        }
        if sourceMs >= last.sourceMs {
            item.applyGeometry(last)
            return item
        }
        let i = keyframes.lastIndex { $0.sourceMs <= sourceMs } ?? 0
        let a = keyframes[i], b = keyframes[min(i + 1, keyframes.count - 1)]
        let raw = (sourceMs - a.sourceMs) / max(0.001, b.sourceMs - a.sourceMs)
        let t = raw * raw * (3.0 - 2.0 * raw)
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        func mix(_ p: Point01, _ q: Point01) -> Point01 { Point01(x: mix(p.x, q.x), y: mix(p.y, q.y)) }
        let turn = Self.normalizedRotation(b.rotationDegrees - a.rotationDegrees)
        item.applyGeometry(AnnotationKeyframe(
            sourceMs: sourceMs,
            position01: mix(a.position01, b.position01),
            from01: mix(a.from01, b.from01),
            to01: mix(a.to01, b.to01),
            size01: Size01(width: mix(a.size01.width, b.size01.width), height: mix(a.size01.height, b.size01.height)),
            rotationDegrees: Self.normalizedRotation(a.rotationDegrees + turn * t)
        ))
        return item
    }

    /// Keyframes stay with the item when it moves in time.
    public mutating func shiftTime(by delta: Double) {
        sourceStartMs += delta
        sourceEndMs += delta
        for i in keyframes.indices { keyframes[i].sourceMs += delta }
    }

    /// Short label for the timeline and accessibility.
    public var displayTitle: String {
        if kind == .text {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return kind.title.localizedUI
    }
}

public struct AnnotationTrack: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var isHidden: Bool
    public var items: [AnnotationItem]

    public init(id: String = UUID().uuidString, name: String, isHidden: Bool = false, items: [AnnotationItem] = []) {
        self.id = id
        self.name = name
        self.isHidden = isHidden
        self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case id, name, isHidden, items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Annotations"
        self.isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        self.items = try c.decodeIfPresent([AnnotationItem].self, forKey: .items) ?? []
    }

    public static func defaultName(index: Int) -> String {
        index == 0 ? "Annotations" : "Annotations \(index + 1)"
    }

    /// Neighbors on a track may touch by this much: the timeline's drags, layer moves and duplicates allow it.
    public static let overlapToleranceMs = 20.0

    /// Whether two items on this track overlap in time by more than `overlapToleranceMs` (a track must not).
    public var hasOverlaps: Bool {
        let sorted = items.sorted { $0.sourceStartMs < $1.sourceStartMs }
        return zip(sorted, sorted.dropFirst()).contains { $1.sourceStartMs < $0.sourceEndMs - Self.overlapToleranceMs }
    }

    /// `items` on as few tracks as possible with no overlap on any: in start order, each item goes on the first track
    /// whose last item has ended, or on a new one. That uses as many tracks as items are ever shown at once.
    /// The first track keeps `id` and `name`; the others are named `name 2`, `name 3`...
    public static func packed(_ items: [AnnotationItem], id: String = UUID().uuidString, name: String, isHidden: Bool = false) -> [AnnotationTrack] {
        var tracks: [AnnotationTrack] = []
        var ends: [Double] = []
        for item in items.sorted(by: { ($0.sourceStartMs, $0.sourceEndMs) < ($1.sourceStartMs, $1.sourceEndMs) }) {
            if let index = ends.firstIndex(where: { $0 - overlapToleranceMs <= item.sourceStartMs }) {
                tracks[index].items.append(item)
                ends[index] = item.sourceEndMs
            } else {
                let n = tracks.count
                tracks.append(AnnotationTrack(
                    id: n == 0 ? id : UUID().uuidString,
                    name: n == 0 ? name : "\(name) \(n + 1)",
                    isHidden: isHidden,
                    items: [item]
                ))
                ends.append(item.sourceEndMs)
            }
        }
        return tracks
    }
}

/// A look that can be applied to any annotation. `accentColor` is the line, shape and step color and a text's plate;
/// `textColor` is a text's letters.
public struct AnnotationStyle: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var accentColor: String
    public var textColor: String
    public var textBackground: AnnotationTextBackground
    public var bold: Bool
    public var strokeRatio: Double
    public var fillOpacity: Double
    public var cornerRatio: Double
    public var enter: AnnotationAnimation
    public var exit: AnnotationAnimation
    public var animationMs: Double

    public init(
        id: String = UUID().uuidString,
        name: String,
        accentColor: String,
        textColor: String,
        textBackground: AnnotationTextBackground = .solid,
        bold: Bool = true,
        strokeRatio: Double = 0.007,
        fillOpacity: Double = 0.0,
        cornerRatio: Double = 0.012,
        enter: AnnotationAnimation = .fade,
        exit: AnnotationAnimation = .fade,
        animationMs: Double = 250
    ) {
        self.id = id
        self.name = name
        self.accentColor = accentColor
        self.textColor = textColor
        self.textBackground = textBackground
        self.bold = bold
        self.strokeRatio = strokeRatio
        self.fillOpacity = fillOpacity
        self.cornerRatio = cornerRatio
        self.enter = enter
        self.exit = exit
        self.animationMs = animationMs
    }

    /// The look of `item`, to save as a style.
    public init(name: String, from item: AnnotationItem) {
        self.init(
            name: name,
            accentColor: item.kind == .text ? item.backgroundColor : item.color,
            textColor: item.kind == .text ? item.color : AnnotationItem.defaultTextColor,
            textBackground: item.textBackground,
            bold: item.bold,
            strokeRatio: item.strokeRatio,
            fillOpacity: item.fillOpacity,
            cornerRatio: item.cornerRatio,
            enter: item.enter,
            exit: item.exit,
            animationMs: item.animationMs
        )
    }

    /// Sets the look and keeps what the item is and where it is. An animation the kind cannot play is left as it was.
    public func apply(to item: inout AnnotationItem) {
        if item.kind == .text {
            item.color = textColor
            item.backgroundColor = accentColor
            item.textBackground = textBackground
            item.bold = bold
        } else {
            item.color = accentColor
        }
        item.strokeRatio = AnnotationItem.clampedStroke(strokeRatio)
        item.fillOpacity = min(1, max(0, fillOpacity))
        item.cornerRatio = AnnotationItem.clampedCorner(cornerRatio)
        if enter.isOffered(for: item.kind) { item.enter = enter }
        if exit.isOffered(for: item.kind) { item.exit = exit }
        item.animationMs = AnnotationItem.clampedAnimation(animationMs)
    }

    public static let builtIn: [AnnotationStyle] = [
        AnnotationStyle(id: "builtin.coral", name: "Coral", accentColor: "#FF5A36", textColor: "#FFFFFF"),
        AnnotationStyle(
            id: "builtin.highlighter", name: "Highlighter", accentColor: "#FFD60A", textColor: "#16161D",
            strokeRatio: 0.01, fillOpacity: 0.18, cornerRatio: 0.008
        ),
        AnnotationStyle(id: "builtin.clean", name: "Clean white", accentColor: "#FFFFFF", textColor: "#16161D", strokeRatio: 0.005),
        AnnotationStyle(id: "builtin.ocean", name: "Ocean", accentColor: "#2F7BFF", textColor: "#FFFFFF", enter: .pop, exit: .fade),
        AnnotationStyle(
            id: "builtin.ink", name: "Ink", accentColor: "#16161D", textColor: "#FFFFFF",
            textBackground: .solid, strokeRatio: 0.006, enter: .rise, exit: .rise, animationMs: 300
        ),
    ]
}
