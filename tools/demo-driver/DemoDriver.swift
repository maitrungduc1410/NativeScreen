// DemoDriver: shows the demo page in a plain window (no URL bar) and plays scripted takes with real mouse and
// keyboard events, so screen recorders see real clicks and keystrokes.
// Usage: DemoDriver.app/Contents/MacOS/DemoDriver <page.html> <control-dir>
// Write a take path to <control-dir>/cmd; the driver runs it and writes "done" to <control-dir>/status.
import AppKit
import WebKit
import ApplicationServices

final class Driver: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    let pageURL: URL
    let controlDir: URL
    var window: NSWindow!
    var web: WKWebView!
    var loaded = false
    var cursor = CGPoint.zero
    var playing: NSSound?
    /// Folder of the take being played; relative `file` paths in a take resolve against it.
    var takeDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    init(page: URL, control: URL) {
        pageURL = page
        controlDir = control
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.screens[0]
        let size = NSSize(width: 1280, height: 800)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2 - 20)
        window = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Mapleboard"
        let config = WKWebViewConfiguration()
        web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        web.navigationDelegate = self
        window.contentView = web
        web.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        cursor = CGEvent(source: nil)?.location ?? .zero
        writeGeometry()
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }

    /// Window id and content rect in global points (top-left origin), for the recorder.
    func writeGeometry() {
        let content = window.convertToScreen(web.frame)
        let primaryH = NSScreen.screens[0].frame.height
        let info: [String: Any] = [
            "windowId": window.windowNumber,
            "trusted": AXIsProcessTrusted(),
            "content": ["x": content.minX, "y": primaryH - content.maxY, "width": content.width, "height": content.height],
            "frame": ["x": window.frame.minX, "y": primaryH - window.frame.maxY, "width": window.frame.width, "height": window.frame.height],
        ]
        let data = try! JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted])
        try? data.write(to: controlDir.appendingPathComponent("geometry.json"))
    }

    var busy = false
    func poll() {
        guard !busy, loaded else { return }
        let cmd = controlDir.appendingPathComponent("cmd")
        guard let text = try? String(contentsOf: cmd, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: cmd)
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if path == "quit" { NSApp.terminate(nil); return }
        busy = true
        writeStatus("running")
        writeGeometry()
        Task { @MainActor in
            do {
                takeDir = URL(fileURLWithPath: path).deletingLastPathComponent()
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let steps = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
                for step in steps { try await run(step) }
                writeStatus("done")
            } catch {
                writeStatus("error: \(error)")
            }
            busy = false
        }
    }

    func writeStatus(_ s: String) {
        try? s.write(to: controlDir.appendingPathComponent("status"), atomically: true, encoding: .utf8)
    }

    // MARK: Steps

    func run(_ step: [String: Any]) async throws {
        let op = step["op"] as! String
        switch op {
        case "wait":
            try await sleep(ms(step["ms"], 500))
        case "reload":
            loaded = false
            web.reload()
            while !loaded { try await sleep(50) }
            try await sleep(ms(step["ms"], 600))
        case "js":
            _ = try? await web.evaluateJavaScript(step["code"] as! String)
        case "front":
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        case "move":
            let target = try await point(for: step)
            try await glide(to: target, ms: ms(step["ms"], 0))
        case "click":
            if step["sel"] != nil || step["x"] != nil || step["gx"] != nil {
                let target = try await point(for: step)
                try await glide(to: target, ms: ms(step["ms"], 0))
                try await sleep(ms(step["settle"], 120))
            }
            click(count: (step["count"] as? Int) ?? 1)
            try await sleep(ms(step["after"], 250))
        case "type":
            let text = step["text"] as! String
            let cps = (step["cps"] as? Double) ?? 11
            for ch in text {
                typeChar(ch)
                let base = 1000.0 / cps
                try await sleep(base * Double.random(in: 0.6...1.4) + (ch == " " ? base * 0.4 : 0))
            }
        case "key":
            key(step["key"] as! String, mods: (step["mods"] as? [String]) ?? [])
            try await sleep(ms(step["after"], 300))
        case "scroll":
            let lines = (step["lines"] as? Int) ?? 5
            let steps = abs(lines) * 3
            for _ in 0..<steps {
                let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(lines > 0 ? -8 : 8), wheel2: 0, wheel3: 0)
                e?.location = cursor
                e?.post(tap: .cghidEventTap)
                try await sleep(16)
            }
        case "play":
            // Plays an audio file from this process, so a window recording of the driver captures it.
            let sound = NSSound(contentsOf: URL(fileURLWithPath: step["file"] as! String, relativeTo: takeDir), byReference: true)
            playing = sound
            sound?.play()
        case "place":
            // Brings another app to the front and moves its frontmost window to x/y/width/height (global points).
            try place(app: step["app"] as! String, frame: CGRect(x: ms(step["x"], 0), y: ms(step["y"], 0),
                                                                width: ms(step["width"], 800), height: ms(step["height"], 600)))
            try await sleep(ms(step["after"], 300))
        case "rects":
            // Element rects relative to the window content (points), for masks.
            let sels = step["sels"] as! [String]
            var out: [String: Any] = [:]
            for s in sels { if let r = try await rect(s) { out[s] = ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height] } }
            let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted])
            try data.write(to: controlDir.appendingPathComponent(step["file"] as? String ?? "rects.json"))
        default:
            throw NSError(domain: "DemoDriver", code: 1, userInfo: [NSLocalizedDescriptionKey: "unknown op \(op)"])
        }
    }

    func place(app name: String, frame: CGRect) throws {
        guard let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else {
            throw NSError(domain: "DemoDriver", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(name) is not running"])
        }
        running.activate()
        let ax = AXUIElementCreateApplication(running.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &value) == .success
                || AXUIElementCopyAttributeValue(ax, kAXMainWindowAttribute as CFString, &value) == .success,
              let win = value else {
            throw NSError(domain: "DemoDriver", code: 4, userInfo: [NSLocalizedDescriptionKey: "\(name) has no window"])
        }
        var origin = frame.origin, size = frame.size
        let w = win as! AXUIElement
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    }

    func ms(_ v: Any?, _ d: Double) -> Double { (v as? Double) ?? (v as? Int).map(Double.init) ?? d }
    func sleep(_ ms: Double) async throws { try await Task.sleep(nanoseconds: UInt64(max(0, ms) * 1_000_000)) }

    func rect(_ sel: String) async throws -> CGRect? {
        let js = "(() => { const e = document.querySelector(\(jsString(sel))); if (!e) return null; e.scrollIntoViewIfNeeded && false; const r = e.getBoundingClientRect(); return [r.x, r.y, r.width, r.height]; })()"
        guard let a = try await web.evaluateJavaScript(js) as? [Double] else { return nil }
        return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
    }

    func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        let json = String(data: data, encoding: .utf8)!
        return String(json.dropFirst().dropLast())
    }

    /// Global point (top-left origin) for a step: a selector with fx/fy (fraction inside the element, default center),
    /// gx/gy in global points, or x/y as fractions of the window content.
    func point(for step: [String: Any]) async throws -> CGPoint {
        let content = window.convertToScreen(web.frame)
        let primaryH = NSScreen.screens[0].frame.height
        let top = primaryH - content.maxY
        if let sel = step["sel"] as? String {
            guard let r = try await rect(sel) else { throw NSError(domain: "DemoDriver", code: 2, userInfo: [NSLocalizedDescriptionKey: "no element \(sel)"]) }
            let fx = (step["fx"] as? Double) ?? 0.5, fy = (step["fy"] as? Double) ?? 0.5
            return CGPoint(x: content.minX + r.minX + r.width * fx, y: top + r.minY + r.height * fy)
        }
        if let gx = step["gx"], let gy = step["gy"] { return CGPoint(x: ms(gx, 0), y: ms(gy, 0)) }
        let x = (step["x"] as? Double) ?? 0.5, y = (step["y"] as? Double) ?? 0.5
        return CGPoint(x: content.minX + content.width * x, y: top + content.height * y)
    }

    /// Moves along a gently curved path with ease in and out, like a hand.
    func glide(to target: CGPoint, ms requested: Double) async throws {
        let start = cursor
        let dist = hypot(target.x - start.x, target.y - start.y)
        if dist < 1 { return }
        let duration = requested > 0 ? requested : min(1100, max(350, 260 + dist * 0.9))
        let steps = max(2, Int(duration / 8))
        let bend = CGFloat.random(in: -0.18...0.18) * dist
        let mid = CGPoint(x: (start.x + target.x) / 2, y: (start.y + target.y) / 2)
        let normal = CGPoint(x: -(target.y - start.y) / dist, y: (target.x - start.x) / dist)
        let control = CGPoint(x: mid.x + normal.x * bend, y: mid.y + normal.y * bend)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            let u = CGFloat(e)
            let p = CGPoint(
                x: (1 - u) * (1 - u) * start.x + 2 * (1 - u) * u * control.x + u * u * target.x,
                y: (1 - u) * (1 - u) * start.y + 2 * (1 - u) * u * control.y + u * u * target.y)
            moveTo(p)
            try await sleep(8)
        }
    }

    func moveTo(_ p: CGPoint) {
        cursor = p
        if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) {
            e.post(tap: .cghidEventTap)
        } else {
            CGWarpMouseCursorPosition(p)
        }
    }

    func click(count: Int) {
        for n in 1...count {
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: cursor, mouseButton: .left)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            down?.post(tap: .cghidEventTap)
            usleep(70_000)
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: cursor, mouseButton: .left)
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            up?.post(tap: .cghidEventTap)
            usleep(60_000)
        }
    }

    func typeChar(_ ch: Character) {
        var utf16 = Array(String(ch).utf16)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            e?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            e?.post(tap: .cghidEventTap)
            usleep(down ? 40_000 : 5_000)
        }
    }

    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "down": 125, "up": 126, "left": 123, "right": 124,
        "/": 44,
    ]

    func key(_ name: String, mods: [String]) {
        guard let code = Driver.keyCodes[name] else { return }
        var flags: CGEventFlags = []
        var modCodes: [CGKeyCode] = []
        for m in mods {
            switch m {
            case "cmd": flags.insert(.maskCommand); modCodes.append(55)
            case "shift": flags.insert(.maskShift); modCodes.append(56)
            case "alt": flags.insert(.maskAlternate); modCodes.append(58)
            case "ctrl": flags.insert(.maskControl); modCodes.append(59)
            default: break
            }
        }
        var current: CGEventFlags = []
        for (i, mc) in modCodes.enumerated() {
            current.insert([CGEventFlags.maskCommand, .maskShift, .maskAlternate, .maskControl][["cmd", "shift", "alt", "ctrl"].firstIndex(of: mods[i])!])
            let e = CGEvent(keyboardEventSource: nil, virtualKey: mc, keyDown: true)
            e?.flags = current
            e?.post(tap: .cghidEventTap)
            usleep(60_000)
        }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
            usleep(down ? 90_000 : 30_000)
        }
        for mc in modCodes.reversed() {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: mc, keyDown: false)
            e?.flags = []
            e?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
    }
}

let args = CommandLine.arguments
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let driver = Driver(page: URL(fileURLWithPath: args[1]), control: URL(fileURLWithPath: args[2]))
app.delegate = driver
app.run()
