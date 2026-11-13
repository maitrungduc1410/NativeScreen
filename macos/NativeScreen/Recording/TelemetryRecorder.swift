import Foundation
import AppKit
import CoreGraphics

/// Records 60-120Hz normalized cursor coordinates, mouse clicks/scrolls, and keyboard activity into append-only `.jsonl` files.
public final class TelemetryRecorder {
    private let cursorAppender: JSONLinesAppender
    private let clicksAppender: JSONLinesAppender
    private let keysAppender: JSONLinesAppender
    private var startTimeUptimeSec: TimeInterval?
    private var captureLogicalBounds: CGRect // Quartz global coordinates (top-left origin)

    private var samplingTimer: DispatchSourceTimer?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    /// App Store build only: keystrokes from every app (ADR-85).
    private var keyEventTap: KeyEventTap?
    private let queue = DispatchQueue(label: "com.nativescreen.telemetry", qos: .userInteractive)
    private var isPausedInternal: Bool = false
    private var pauseStartUptimeSec: TimeInterval?
    private var accumulatedPausedSec: TimeInterval = 0.0

    /// `NSCursor.currentSystem` returns a new object every time, so it never equals `NSCursor.iBeam` and the like.
    /// A cursor is recognized by its hotspot and shape, as ratios so an enlarged system pointer still matches.
    private struct CursorShape: Hashable {
        let hotX: Int
        let hotY: Int
        let aspect: Int

        init(_ cursor: NSCursor) {
            let size = cursor.image.size
            hotX = Int((cursor.hotSpot.x / max(1.0, size.width) * 100.0).rounded())
            hotY = Int((cursor.hotSpot.y / max(1.0, size.height) * 100.0).rounded())
            aspect = Int((size.width / max(1.0, size.height) * 100.0).rounded())
        }
    }

    /// Names as in `spec/02` §3.1. Open and closed hand have the same shape, so `closedHandImageData` tells them apart.
    private let knownCursorKinds: [CursorShape: String] = [
        CursorShape(.iBeam): "iBeam",
        CursorShape(.pointingHand): "pointingHand",
        CursorShape(.crosshair): "crosshair",
        CursorShape(.openHand): "openHand",
    ]
    private let closedHandImageData = NSCursor.closedHand.image.tiffRepresentation

    public init(
        telemetryDirectoryURL: URL,
        captureLogicalBounds: CGRect
    ) {
        self.cursorAppender = JSONLinesAppender(fileURL: telemetryDirectoryURL.appendingPathComponent("cursor.jsonl"))
        self.clicksAppender = JSONLinesAppender(fileURL: telemetryDirectoryURL.appendingPathComponent("clicks.jsonl"))
        self.keysAppender = JSONLinesAppender(fileURL: telemetryDirectoryURL.appendingPathComponent("keys.jsonl"))
        self.startTimeUptimeSec = nil
        self.captureLogicalBounds = captureLogicalBounds
    }

    /// Synchronizes the telemetry `t = 0.0ms` epoch with the exact `systemUptime` of the first captured video frame (`SCStream` `firstSampleTime`),
    /// and immediately writes the initial `t = 0.0ms` cursor sample so telemetry and video are 100% locked in phase!
    public func markFirstVideoFrameArrived(atUptimeSec firstFrameUptimeSec: TimeInterval) {
        queue.async {
            guard self.startTimeUptimeSec == nil else { return }
            self.startTimeUptimeSec = firstFrameUptimeSec
            let pt = self.normalizedMousePoint()
            let kind = self.detectCurrentSystemCursorKind()
            let sample = CursorSampleEvent(t: 0.0, x: pt.x, y: pt.y, c: kind)
            self.cursorAppender.append(sample)
        }
    }

    /// `uptimeSec` must be the same value passed to `ScreenCaptureEngine.setPaused` so cursor time and video time drop the same span.
    public func setPaused(_ paused: Bool, atUptime uptimeSec: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        queue.async {
            guard self.isPausedInternal != paused else { return }
            let now = uptimeSec
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

        #if APPSTORE
        // Global key monitors need Accessibility, which the sandbox rules out: the tap delivers every keystroke,
        // including the ones typed into this app, so the monitors below only take mouse events.
        let monitorMask = mask.subtracting(.keyDown)
        KeyEventTap.requestAccess()
        keyEventTap = KeyEventTap { [weak self] event in
            // Drawing on the screen is not a shortcut in the recording.
            guard !(NSApp.keyWindow is LiveDrawingPanel) else { return }
            self?.handleNSEvent(event)
        }
        #else
        let monitorMask = mask
        #endif

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: monitorMask) { [weak self] event in
            self?.handleNSEvent(event)
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: monitorMask) { [weak self] event in
            // Drawing on the screen is not a click or a shortcut in the recording (the strokes are saved on their own).
            if !(event.window is LiveDrawingPanel) {
                self?.handleNSEvent(event)
            }
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
        keyEventTap?.invalidate()
        keyEventTap = nil
        queue.sync {
            cursorAppender.close()
            clicksAppender.close()
            keysAppender.close()
        }
    }

    /// The recording time now (ms, pauses removed), on the cursor's clock. Nil before the first frame.
    public func currentTimelineMs() -> Double? {
        queue.sync { elapsedMs() }
    }

    private func elapsedMs() -> Double? {
        guard let startSec = startTimeUptimeSec else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        let activePause = pauseStartUptimeSec.map { max(0.0, now - $0) } ?? 0.0
        return max(0.0, (now - startSec - accumulatedPausedSec - activePause) * 1000.0)
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

    private func detectCurrentSystemCursorKind() -> String {
        guard let current = NSCursor.currentSystem else { return "arrow" }
        let kind = knownCursorKinds[CursorShape(current)] ?? "arrow"
        if kind == "openHand", current.image.tiffRepresentation == closedHandImageData {
            return "closedHand"
        }
        return kind
    }

    private func sampleCurrentMousePosition() {
        guard !isPausedInternal, let t = elapsedMs() else { return }
        let pt = normalizedMousePoint()
        let kind = detectCurrentSystemCursorKind()
        let sample = CursorSampleEvent(t: t, x: pt.x, y: pt.y, c: kind)
        cursorAppender.append(sample)
    }

    private func handleNSEvent(_ event: NSEvent) {
        guard !isPausedInternal, let t = elapsedMs() else { return }
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
            if event.isARepeat {
                return
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var mods: [String] = []
            if flags.contains(.capsLock) { mods.append("CapsLock") }
            if flags.contains(.command) { mods.append("Meta") }
            if flags.contains(.shift) { mods.append("Shift") }
            if flags.contains(.option) { mods.append("Alt") }
            if flags.contains(.control) { mods.append("Ctrl") }

            let keyName = Self.canonicalKeyName(for: event)
            let hasCommandOrCtrlOrOpt = flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
            let isSpecialSingleKey = Self.isSpecialStandaloneKey(keyName)
            let kind = (hasCommandOrCtrlOrOpt || isSpecialSingleKey) ? "shortcut" : "typing"

            var displayParts = mods.map { Self.symbolForModifier($0) }
            if let k = keyName, !k.isEmpty {
                displayParts.append(Self.symbolForKey(k))
            }
            let label = displayParts.joined(separator: " ")

            let keyEv = KeyStrokeEvent(
                t: t,
                kind: kind,
                modifiers: mods.isEmpty ? nil : mods,
                key: keyName,
                label: label.isEmpty ? nil : label
            )
            queue.async { self.keysAppender.append(keyEv) }
        default:
            break
        }
    }

    private static func canonicalKeyName(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 36, 76: return "Enter"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"        // Backspace (⌫)
        case 117: return "ForwardDelete" // Forward Delete (⌦)
        case 53: return "Escape"
        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "PageUp"
        case 121: return "PageDown"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:
            guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else {
                return nil
            }
            let trimmed = chars.trimmingCharacters(in: .controlCharacters)
            guard !trimmed.isEmpty else { return nil }
            return trimmed.uppercased()
        }
    }

    private static func isSpecialStandaloneKey(_ key: String?) -> Bool {
        guard let k = key else { return false }
        switch k {
        case "Delete", "ForwardDelete", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown",
             "Home", "End", "PageUp", "PageDown",
             "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12":
            return true
        default:
            return false
        }
    }

    private static func symbolForModifier(_ mod: String) -> String {
        switch mod {
        case "Meta", "cmd": return "⌘"
        case "Shift", "shift": return "⇧"
        case "Alt", "opt": return "⌥"
        case "Ctrl", "ctrl", "Control": return "⌃"
        case "CapsLock": return "⇪"
        default: return mod
        }
    }

    private static func symbolForKey(_ key: String) -> String {
        switch key {
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
        default: return key.uppercased()
        }
    }
}
