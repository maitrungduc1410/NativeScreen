import AppKit
import Foundation
import Observation

// MARK: - Live drawing while recording

/// Drawing on the screen while recording. The strokes are shown to the presenter on clear panels that the capture
/// leaves out, and saved as timed events (`recording/telemetry/drawings.jsonl`). When the project is made they become
/// annotations on a `Live drawing` track, so the video stays clean and every stroke can still be edited.
public enum LiveDrawingTool: String, Codable, CaseIterable, Identifiable, Sendable {
    case pen
    case highlighter
    case arrow
    case rectangle

    public var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        }
    }

    var title: String {
        switch self {
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        }
    }

    /// Line width as a share of the shorter side of the recorded area.
    var strokeRatio: Double {
        switch self {
        case .pen: return 0.005
        case .highlighter: return 0.022
        case .arrow, .rectangle: return 0.006
        }
    }
}

/// One line of `drawings.jsonl`. A stroke has a tool, a color and points; `clear` ends every stroke still shown and
/// `undo` ends the last one. Times are recording times in ms (pauses removed), points are normalized to the recorded
/// area like the cursor (`x`, `y`, ms after `t`).
public struct LiveDrawingEvent: Codable, Equatable, Sendable {
    public var type: String
    public var t: Double
    public var tool: LiveDrawingTool?
    public var color: String?
    public var points: [[Double]]?
    /// How long a stroke stays after it is finished; nil keeps it until cleared.
    public var fadeAfterMs: Double?

    static func stroke(t: Double, tool: LiveDrawingTool, color: String, points: [[Double]], fadeAfterMs: Double?) -> Self {
        LiveDrawingEvent(type: "stroke", t: t, tool: tool, color: color, points: points, fadeAfterMs: fadeAfterMs)
    }

    static func clear(t: Double) -> Self { LiveDrawingEvent(type: "clear", t: t) }
    static func undo(t: Double) -> Self { LiveDrawingEvent(type: "undo", t: t) }

    init(type: String, t: Double, tool: LiveDrawingTool? = nil, color: String? = nil, points: [[Double]]? = nil, fadeAfterMs: Double? = nil) {
        self.type = type
        self.t = t
        self.tool = tool
        self.color = color
        self.points = points
        self.fadeAfterMs = fadeAfterMs
    }

    /// The strokes as annotations on `Live drawing` tracks. Strokes drawn without a pause longer than the fade (or, when
    /// they stay, until a clear) are one burst and leave together, as on screen. In a burst, pen strokes of one tool and
    /// color become one multi-stroke `pen` item; arrows and rectangles stay items of their own, and an undone stroke
    /// ends on its own when it was undone. The items are packed on as few tracks as possible. Empty when nothing was
    /// drawn.
    public static func annotationTracks(from events: [LiveDrawingEvent], durationMs: Double) -> [AnnotationTrack] {
        struct Stroke {
            var event: LiveDrawingEvent
            var start: Double
            var finish: Double
            var undoneAt: Double?
            /// How many clears came before it: strokes between two clears go away together at the second.
            var clearEpoch: Int
        }
        // Replay the log in the order things happened: a stroke is written when it is finished.
        var strokes: [Stroke] = []
        var shown: [Int] = []
        var clearTimes: [Double] = []
        let logged = events.map { event -> (Double, LiveDrawingEvent) in
            guard event.type == "stroke" else { return (event.t, event) }
            return (event.t + max(0, event.points?.last.flatMap { $0.count >= 3 ? $0[2] : nil } ?? 0), event)
        }
        for (at, event) in logged.sorted(by: { $0.0 < $1.0 }) {
            switch event.type {
            case "clear":
                clearTimes.append(event.t)
                shown.removeAll()
            case "undo":
                if let last = shown.popLast() { strokes[last].undoneAt = event.t }
            default:
                guard event.tool != nil, let points = event.points, points.contains(where: { $0.count >= 3 }) else { continue }
                strokes.append(Stroke(event: event, start: event.t, finish: at, clearEpoch: clearTimes.count))
                shown.append(strokes.count - 1)
            }
        }
        guard !strokes.isEmpty else { return [] }

        // Bursts, in start order.
        var bursts: [[Stroke]] = []
        var lastActivity = -Double.infinity
        for stroke in strokes.sorted(by: { $0.start < $1.start }) {
            let previous = bursts.last?.last
            let fade = previous?.event.fadeAfterMs
            let isNew = previous == nil
                || previous?.clearEpoch != stroke.clearEpoch
                || (fade.map { stroke.start > lastActivity + $0 } ?? false)
            if isNew {
                bursts.append([stroke])
                lastActivity = stroke.finish
            } else {
                bursts[bursts.count - 1].append(stroke)
                lastActivity = max(lastActivity, stroke.finish)
            }
        }

        var items: [AnnotationItem] = []
        for burst in bursts {
            let lastFinish = burst.map(\.finish).max() ?? 0
            var end = burst.last?.event.fadeAfterMs.map { lastFinish + $0 } ?? durationMs
            if let epoch = burst.first?.clearEpoch, epoch < clearTimes.count { end = min(end, clearTimes[epoch]) }
            end = min(end, durationMs)

            var pens: [String: [Stroke]] = [:]
            var penOrder: [String] = []
            for stroke in burst {
                guard let tool = stroke.event.tool else { continue }
                if let undone = stroke.undoneAt {
                    if let item = annotation(for: [stroke.event], tool: tool, end: min(end, undone), durationMs: durationMs) {
                        items.append(item)
                    }
                } else if tool == .pen || tool == .highlighter {
                    let key = "\(tool.rawValue)|\(stroke.event.color ?? "")"
                    if pens[key] == nil { penOrder.append(key) }
                    pens[key, default: []].append(stroke)
                } else if let item = annotation(for: [stroke.event], tool: tool, end: end, durationMs: durationMs) {
                    items.append(item)
                }
            }
            for key in penOrder {
                guard let group = pens[key], let tool = group.first?.event.tool,
                      let item = annotation(for: group.map(\.event), tool: tool, end: end, durationMs: durationMs) else { continue }
                items.append(item)
            }
        }
        return AnnotationTrack.packed(items, name: "Live drawing")
    }

    /// One item from strokes of one tool and color (several only for pen and highlighter), shown until `end`.
    private static func annotation(for events: [LiveDrawingEvent], tool: LiveDrawingTool, end rawEnd: Double, durationMs: Double) -> AnnotationItem? {
        guard let firstEvent = events.first else { return nil }
        let start = max(0.0, min(firstEvent.t, durationMs - AnnotationItem.minDurationMs))
        let end = max(start + AnnotationItem.minDurationMs, rawEnd)
        let color = firstEvent.color ?? AnnotationItem.defaultArrowColor
        func p(_ v: [Double]) -> Point01 { Point01(x: v[0], y: v[1]) }

        switch tool {
        case .arrow, .rectangle:
            let points = (firstEvent.points ?? []).filter { $0.count >= 3 }
            guard let a = points.first, let b = points.last else { return nil }
            let drawnMs = max(0.0, b[2])
            if tool == .arrow {
                return AnnotationItem(
                    sourceStartMs: start,
                    sourceEndMs: end,
                    kind: .arrow,
                    from01: p(a),
                    to01: p(b),
                    bend: 0,
                    strokeRatio: tool.strokeRatio,
                    color: color,
                    enter: .draw,
                    exit: .fade,
                    animationMs: max(120, min(600, drawnMs))
                )
            }
            return AnnotationItem(
                sourceStartMs: start,
                sourceEndMs: end,
                kind: .rectangle,
                position01: Point01(x: (a[0] + b[0]) * 0.5, y: (a[1] + b[1]) * 0.5),
                strokeRatio: tool.strokeRatio,
                size01: Size01(width: AnnotationItem.clampedSize(abs(b[0] - a[0])), height: AnnotationItem.clampedSize(abs(b[1] - a[1]))),
                cornerRatio: 0.006,
                color: color,
                enter: .draw,
                exit: .fade,
                animationMs: max(120, min(600, drawnMs))
            )
        case .pen, .highlighter:
            // Every point with its time after the first stroke began; a new stroke starts where the pen went down again.
            var all: [[Double]] = []
            var strokeStarts: [Int] = []
            for event in events {
                let points = (event.points ?? []).filter { $0.count >= 3 }
                guard !points.isEmpty else { continue }
                if !all.isEmpty { strokeStarts.append(all.count) }
                let offset = event.t - firstEvent.t
                var last = all.last?[2] ?? 0
                for point in points {
                    // Times must not go back, or the replay would skip.
                    last = max(last, offset + max(0, point[2]))
                    all.append([point[0], point[1], last])
                }
            }
            guard !all.isEmpty else { return nil }
            let xs = all.map { $0[0] }, ys = all.map { $0[1] }
            let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
            let width = max(0.01, maxX - minX), height = max(0.01, maxY - minY)
            let cx = (minX + maxX) * 0.5, cy = (minY + maxY) * 0.5
            return AnnotationItem(
                sourceStartMs: start,
                sourceEndMs: end,
                kind: .pen,
                position01: Point01(x: cx, y: cy),
                strokeRatio: tool.strokeRatio,
                size01: Size01(width: width, height: height),
                points01: all.map { Point01(x: ($0[0] - cx) / width + 0.5, y: ($0[1] - cy) / height + 0.5) },
                pointTimesMs: all.map { $0[2] },
                highlighter: tool == .highlighter,
                strokeStarts: strokeStarts,
                color: color,
                enter: .draw,
                exit: .fade,
                animationMs: 300
            )
        }
    }
}

/// The clear, full-screen panels the presenter draws on.
final class LiveDrawingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@Observable
@MainActor
public final class LiveDrawingController {
    public static let shared = LiveDrawingController()

    public static let palette = ["#FF3B30", "#FFCC00", "#34C759", "#0A84FF", "#FFFFFF"]
    private static let fadeAfterMs = 3000.0
    private let toolKey = "NativeScreen.LiveDrawing.Tool"
    private let colorKey = "NativeScreen.LiveDrawing.Color"
    private let stayKey = "NativeScreen.LiveDrawing.StayUntilCleared"

    public private(set) var isDrawing = false
    public private(set) var isPrepared = false
    public var tool: LiveDrawingTool {
        didSet { UserDefaults.standard.set(tool.rawValue, forKey: toolKey) }
    }
    public var color: String {
        didSet { UserDefaults.standard.set(color, forKey: colorKey) }
    }
    /// Strokes stay on screen (and in the video) until cleared, instead of fading after 3 s.
    public var staysUntilCleared: Bool {
        didSet { UserDefaults.standard.set(staysUntilCleared, forKey: stayKey) }
    }

    @ObservationIgnored private var panels: [LiveDrawingPanel] = []
    @ObservationIgnored private var appender: JSONLinesAppender?
    @ObservationIgnored private var captureBoundsQuartz: CGRect = .zero
    @ObservationIgnored private var timelineMs: (() -> Double?)?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var recordingFadeAfterMs: Double? = 3000

    private init() {
        let d = UserDefaults.standard
        tool = d.string(forKey: toolKey).flatMap(LiveDrawingTool.init(rawValue:)) ?? .pen
        color = d.string(forKey: colorKey) ?? Self.palette[0]
        staysUntilCleared = d.bool(forKey: stayKey)
    }

    /// Puts clear, click-through panels on every screen. Called before the capture filter is built, so the filter
    /// leaves them out (`sharingType = .none`); a window shown later would be recorded.
    func prepare() {
        tearDown()
        for screen in NSScreen.screens {
            let panel = LiveDrawingPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            // Above app windows, under the speaker notes and the recording bar.
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.sharingType = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = LiveDrawingCanvasView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.controller = self
            panel.contentView = view
            panel.setFrame(screen.frame, display: false)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        isPrepared = true
    }

    /// Starts saving strokes for the recording that is now running.
    func begin(captureBoundsQuartz: CGRect, telemetryDirectory: URL, timelineMs: @escaping () -> Double?) {
        // Fade or stay is fixed for the whole recording, so the screen and the saved strokes always agree; changing
        // the option applies to the next recording.
        recordingFadeAfterMs = staysUntilCleared ? nil : Self.fadeAfterMs
        self.captureBoundsQuartz = captureBoundsQuartz
        self.timelineMs = timelineMs
        appender = JSONLinesAppender(fileURL: telemetryDirectory.appendingPathComponent("drawings.jsonl"))
    }

    func tearDown() {
        setDrawing(false)
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        appender?.close()
        appender = nil
        timelineMs = nil
        isPrepared = false
    }

    public func setDrawing(_ on: Bool) {
        guard isDrawing != on else { return }
        guard !on || (isPrepared && appender != nil) else { return }
        isDrawing = on
        for panel in panels {
            panel.ignoresMouseEvents = !on
        }
        if on {
            // The panel under the pointer takes the keys (Esc, ⌘Z, the tool numbers) without activating the app.
            let mouse = NSEvent.mouseLocation
            (panels.first { $0.frame.contains(mouse) } ?? panels.first)?.makeKey()
            NSCursor.crosshair.push()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.window is LiveDrawingPanel else { return event }
                return MainActor.assumeIsolated { self?.handleKey(event) ?? false } ? nil : event
            }
        } else {
            NSCursor.pop()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            panels.forEach { $0.resignKey() }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        if event.keyCode == 53 { setDrawing(false); return true } // Esc
        if flags == .command, event.charactersIgnoringModifiers == "z" { undo(); return true }
        guard flags.isEmpty else { return false }
        switch event.charactersIgnoringModifiers {
        case "1": tool = .pen
        case "2": tool = .highlighter
        case "3": tool = .arrow
        case "4": tool = .rectangle
        case "c": clear()
        default:
            if event.keyCode == 51 { clear(); return true } // Delete
            return false
        }
        return true
    }

    public func clear() {
        guard let t = timelineMs?() else { return }
        appender?.append(LiveDrawingEvent.clear(t: t))
        canvases.forEach { $0.clearAll() }
    }

    public func undo() {
        guard let t = timelineMs?() else { return }
        // Only a stroke still on screen can be taken back.
        guard let canvas = canvases.max(by: { $0.lastStrokeTime < $1.lastStrokeTime }), canvas.removeLast() else { return }
        appender?.append(LiveDrawingEvent.undo(t: t))
    }

    private var canvases: [LiveDrawingCanvasView] { panels.compactMap { $0.contentView as? LiveDrawingCanvasView } }

    /// Saves a finished stroke drawn at `screenPoints` (Cocoa screen coordinates) with their uptimes.
    fileprivate func finish(screenPoints: [(CGPoint, TimeInterval)], tool: LiveDrawingTool, color: String) {
        guard let firstUptime = screenPoints.first?.1, let t = timelineMs?() else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let bounds = captureBoundsQuartz
        let elapsedSinceStart = (ProcessInfo.processInfo.systemUptime - firstUptime) * 1000
        let points = screenPoints.map { point, uptime -> [Double] in
            let quartzY = primaryHeight - point.y
            return [
                (point.x - bounds.minX) / max(1, bounds.width),
                (quartzY - bounds.minY) / max(1, bounds.height),
                ((uptime - firstUptime) * 1000).rounded(),
            ]
        }
        appender?.append(LiveDrawingEvent.stroke(
            t: max(0, t - elapsedSinceStart),
            tool: tool,
            color: color,
            points: points,
            fadeAfterMs: recordingFadeAfterMs
        ))
    }

    fileprivate var fadeAfterSeconds: TimeInterval? { recordingFadeAfterMs.map { $0 / 1000 } }

    /// When the pen last went down or up, on any screen. Strokes fade together, `fadeAfterSeconds` after drawing stops,
    /// so a word or a sketch goes away as a whole (the project does the same, `annotationTracks`).
    @ObservationIgnored fileprivate var lastActivityUptime: TimeInterval = 0
    @ObservationIgnored fileprivate var isStrokeInProgress = false

    /// The recorded area's shorter side in screen points, for stroke widths that match the video.
    fileprivate var strokeReferenceLength: CGFloat {
        let side = min(captureBoundsQuartz.width, captureBoundsQuartz.height)
        return side > 1 ? side : (NSScreen.main?.frame.height ?? 900)
    }
}

/// Draws the strokes on one screen and turns mouse drags into strokes.
final class LiveDrawingCanvasView: NSView {
    weak var controller: LiveDrawingController?

    private struct Stroke {
        var tool: LiveDrawingTool
        var color: NSColor
        var points: [(CGPoint, TimeInterval)]
        var finishedAt: TimeInterval?
    }

    private var strokes: [Stroke] = []
    private var current: Stroke?
    private var fadeTimer: Timer?

    private(set) var lastStrokeTime: TimeInterval = 0

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        controller.isStrokeInProgress = true
        controller.lastActivityUptime = ProcessInfo.processInfo.systemUptime
        let point = convert(event.locationInWindow, from: nil)
        current = Stroke(
            tool: controller.tool,
            color: NSColor(hexString: controller.color),
            points: [(point, ProcessInfo.processInfo.systemUptime)]
        )
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard current != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let last = current?.points.last?.0, hypot(point.x - last.x, point.y - last.y) < 1.5 { return }
        current?.points.append((point, ProcessInfo.processInfo.systemUptime))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard var stroke = current, let window, let controller else { return }
        current = nil
        let now = ProcessInfo.processInfo.systemUptime
        controller.isStrokeInProgress = false
        controller.lastActivityUptime = now
        stroke.finishedAt = now
        // Arrows and rectangles need some size; a click is not a shape.
        if stroke.tool == .arrow || stroke.tool == .rectangle {
            guard let a = stroke.points.first?.0, let b = stroke.points.last?.0, hypot(b.x - a.x, b.y - a.y) > 8 else {
                needsDisplay = true
                return
            }
        }
        strokes.append(stroke)
        lastStrokeTime = now
        let screenPoints = stroke.points.map { (window.convertPoint(toScreen: $0.0), $0.1) }
        controller.finish(screenPoints: screenPoints, tool: stroke.tool, color: controller.color)
        scheduleFade()
        needsDisplay = true
    }

    func clearAll() {
        strokes.removeAll()
        current = nil
        needsDisplay = true
    }

    /// Removes the newest stroke; false when there is none.
    func removeLast() -> Bool {
        guard !strokes.isEmpty else { return false }
        strokes.removeLast()
        lastStrokeTime = strokes.last?.finishedAt ?? 0
        needsDisplay = true
        return true
    }

    private func scheduleFade() {
        guard fadeTimer == nil else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickFade() }
        }
    }

    private func tickFade() {
        guard let controller, let fade = controller.fadeAfterSeconds else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Matches the annotation's 300 ms fade-out, `fade` seconds after the last stroke anywhere.
        if !controller.isStrokeInProgress, controller.lastActivityUptime + fade + 0.3 < now {
            strokes.removeAll()
        }
        if strokes.isEmpty {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let controller else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let reference = controller.strokeReferenceLength
        var alpha: CGFloat = 1
        if let fade = controller.fadeAfterSeconds, !controller.isStrokeInProgress {
            let t = now - controller.lastActivityUptime - fade
            if t > 0 { alpha = CGFloat(max(0, 1 - t / 0.3)) }
        }
        for stroke in strokes + (current.map { [$0] } ?? []) {
            draw(stroke, alpha: alpha, reference: reference, in: ctx)
        }
    }

    private func draw(_ stroke: Stroke, alpha: CGFloat, reference: CGFloat, in ctx: CGContext) {
        guard let first = stroke.points.first?.0, let last = stroke.points.last?.0 else { return }
        let width = max(1.5, CGFloat(stroke.tool.strokeRatio) * reference)
        ctx.saveGState()
        ctx.setLineCap(stroke.tool == .highlighter ? .butt : .round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(stroke.color.cgColor)
        ctx.setFillColor(stroke.color.cgColor)
        ctx.setAlpha(alpha * (stroke.tool == .highlighter ? 0.42 : 1))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        switch stroke.tool {
        case .pen, .highlighter:
            ctx.move(to: first)
            for (point, _) in stroke.points.dropFirst() { ctx.addLine(to: point) }
            if stroke.points.count == 1 { ctx.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
            ctx.strokePath()
        case .rectangle:
            let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: min(rect.width, rect.height, reference * 0.006 * 2) / 2, cornerHeight: min(rect.width, rect.height, reference * 0.006 * 2) / 2, transform: nil))
            ctx.strokePath()
        case .arrow:
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head = max(width * 3.2, 12)
            let base = CGPoint(x: last.x - cos(angle) * head * 0.8, y: last.y - sin(angle) * head * 0.8)
            ctx.move(to: first)
            ctx.addLine(to: base)
            ctx.strokePath()
            ctx.move(to: last)
            ctx.addLine(to: CGPoint(x: last.x - cos(angle - 0.45) * head, y: last.y - sin(angle - 0.45) * head))
            ctx.addLine(to: CGPoint(x: last.x - cos(angle + 0.45) * head, y: last.y - sin(angle + 0.45) * head))
            ctx.closePath()
            ctx.fillPath()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}
