import Foundation
import AppKit
import CoreGraphics

/// Records 60-120Hz normalized cursor coordinates, mouse clicks/scrolls, and keyboard activity into append-only `.jsonl` files.
public final class TelemetryRecorder {
    private let cursorAppender: JSONLinesAppender
    private let clicksAppender: JSONLinesAppender
    private let keysAppender: JSONLinesAppender
    private let startTimeUptimeSec: TimeInterval
    private var captureLogicalBounds: CGRect // Quartz global coordinates (top-left origin)

    private var samplingTimer: DispatchSourceTimer?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private let queue = DispatchQueue(label: "com.nativescreen.telemetry", qos: .userInteractive)
    private var isPausedInternal: Bool = false
    private var pauseStartUptimeSec: TimeInterval?
    private var accumulatedPausedSec: TimeInterval = 0.0

    public init(
        telemetryDirectoryURL: URL,
        captureLogicalBounds: CGRect
    ) {
        self.cursorAppender = JSONLinesAppender(fileURL: telemetryDirectoryURL.appendingPathComponent("cursor.jsonl"))
        self.clicksAppender = JSONLinesAppender(fileURL: telemetryDirectoryURL.appendingPathComponent("clicks.jsonl"))
        self.keysAppender = JSONLinesAppender(fileURL: telemetryDirectoryURL.appendingPathComponent("keys.jsonl"))
        self.startTimeUptimeSec = ProcessInfo.processInfo.systemUptime
        self.captureLogicalBounds = captureLogicalBounds
    }

    public func setPaused(_ paused: Bool) {
        queue.async {
            guard self.isPausedInternal != paused else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if paused {
                self.pauseStartUptimeSec = now
            } else if let pStart = self.pauseStartUptimeSec {
                self.accumulatedPausedSec += max(0.0, now - pStart)
                self.pauseStartUptimeSec = nil
            }
            self.isPausedInternal = paused
        }
    }

    public func start() {
        // 1. 120Hz Cursor Position Sampler
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.sampleCurrentMousePosition()
        }
        timer.resume()
        self.samplingTimer = timer

        // 2. Global + Local Mouse Click, Scroll & Keystroke Monitors
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .scrollWheel, .keyDown
        ]

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleNSEvent(event)
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleNSEvent(event)
            return event
        }
    }

    public func stop() {
        samplingTimer?.cancel()
        samplingTimer = nil
        if let global = globalEventMonitor {
            NSEvent.removeMonitor(global)
            globalEventMonitor = nil
        }
        if let local = localEventMonitor {
            NSEvent.removeMonitor(local)
            localEventMonitor = nil
        }
        queue.sync {
            cursorAppender.close()
            clicksAppender.close()
            keysAppender.close()
        }
    }

    private func elapsedMs() -> Double {
        let now = ProcessInfo.processInfo.systemUptime
        let activePause = pauseStartUptimeSec.map { max(0.0, now - $0) } ?? 0.0
        return max(0.0, (now - startTimeUptimeSec - accumulatedPausedSec - activePause) * 1000.0)
    }

    private func normalizedMousePoint() -> Point01 {
        let cocoaMouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080.0
        let quartzX = cocoaMouse.x
        let quartzY = primaryHeight - cocoaMouse.y

        let normX = (quartzX - captureLogicalBounds.origin.x) / max(1.0, captureLogicalBounds.width)
        let normY = (quartzY - captureLogicalBounds.origin.y) / max(1.0, captureLogicalBounds.height)
        return Point01(x: normX, y: normY)
    }

    private func sampleCurrentMousePosition() {
        guard !isPausedInternal else { return }
        let t = elapsedMs()
        let pt = normalizedMousePoint()
        let sample = CursorSampleEvent(t: t, x: pt.x, y: pt.y, c: "arrow")
        cursorAppender.append(sample)
    }

    private func handleNSEvent(_ event: NSEvent) {
        guard !isPausedInternal else { return }
        let t = elapsedMs()
        let pt = normalizedMousePoint()

        switch event.type {
        case .leftMouseDown:
            let ev = ClickEvent(t: t, type: "down", button: "left", x: pt.x, y: pt.y, count: event.clickCount)
            queue.async { self.clicksAppender.append(ev) }
        case .leftMouseUp:
            let ev = ClickEvent(t: t, type: "up", button: "left", x: pt.x, y: pt.y, count: event.clickCount)
            queue.async { self.clicksAppender.append(ev) }
        case .rightMouseDown:
            let ev = ClickEvent(t: t, type: "down", button: "right", x: pt.x, y: pt.y, count: event.clickCount)
            queue.async { self.clicksAppender.append(ev) }
        case .rightMouseUp:
            let ev = ClickEvent(t: t, type: "up", button: "right", x: pt.x, y: pt.y, count: event.clickCount)
            queue.async { self.clicksAppender.append(ev) }
        case .scrollWheel:
            let ev = ClickEvent(
                t: t,
                type: "scroll",
                button: nil,
                x: pt.x,
                y: pt.y,
                count: nil,
                dx: Double(event.scrollingDeltaX),
                dy: Double(event.scrollingDeltaY)
            )
            queue.async { self.clicksAppender.append(ev) }
        case .keyDown:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasCommandOrCtrl = flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
            if hasCommandOrCtrl {
                var mods: [String] = []
                var symbols = ""
                if flags.contains(.control) { mods.append("ctrl"); symbols += "⌃" }
                if flags.contains(.option) { mods.append("opt"); symbols += "⌥" }
                if flags.contains(.shift) { mods.append("shift"); symbols += "⇧" }
                if flags.contains(.command) { mods.append("cmd"); symbols += "⌘" }
                let chars = (event.charactersIgnoringModifiers ?? "").uppercased()
                let keyEv = KeyStrokeEvent(
                    t: t,
                    kind: "shortcut",
                    modifiers: mods,
                    key: chars,
                    label: symbols + chars
                )
                queue.async { self.keysAppender.append(keyEv) }
            } else {
                let keyEv = KeyStrokeEvent(t: t, kind: "typing")
                queue.async { self.keysAppender.append(keyEv) }
            }
        default:
            break
        }
    }
}
