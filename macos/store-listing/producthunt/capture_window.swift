// Captures the frontmost Native Screen editor window into raw/<name>.png, at full Retina resolution, without the
// system shadow. Run from the repository root: swift macos/store-listing/producthunt/capture_window.swift 1-editor
import AppKit

// An optional second argument picks the editor whose title starts with it, e.g. "Mapleboard demo".
let args = Array(CommandLine.arguments.dropFirst())
let name = args.first ?? "capture"
let titlePrefix = args.dropFirst().first
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let windows = list.filter {
    let title = ($0[kCGWindowName as String] as? String) ?? ""
    return ($0[kCGWindowOwnerName as String] as? String)?.hasPrefix("Native Screen") == true
        && ($0[kCGWindowLayer as String] as? Int) == 0
        && title.contains(".nativescreen")
        && (titlePrefix.map { title.hasPrefix($0 + " ") || title.hasPrefix($0 + ".") } ?? true)
}
guard let window = windows.first, let id = window[kCGWindowNumber as String] as? Int else {
    print("No Native Screen editor window on screen. Windows seen:")
    for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
        print(" -", w[kCGWindowOwnerName as String] ?? "?", "|", w[kCGWindowName as String] ?? "")
    }
    exit(1)
}
let path = "macos/store-listing/producthunt/raw/\(name).png"
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
task.arguments = ["-x", "-o", "-l", "\(id)", path]
try task.run()
task.waitUntilExit()
print("captured \(window[kCGWindowName as String] ?? "") -> \(path)")
