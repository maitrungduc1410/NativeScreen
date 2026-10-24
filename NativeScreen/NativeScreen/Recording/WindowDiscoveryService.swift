import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import ScreenCaptureKit

public struct CapturableWindowInfo: Identifiable, Equatable {
    public let id: UInt32 // CGWindowID
    public let pid: pid_t
    public let title: String
    public let appName: String
    public let bundleId: String?
    public let bounds: CGRect // Quartz global screen coordinates (origin top-left of primary screen)
    public let borderRadius: Double

    public var appIcon: NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }
}

public struct WindowSizePreset: Identifiable {
    public let id: String
    public let label: String
    public let width: Int
    public let height: Int

    public static let presets: [WindowSizePreset] = [
        WindowSizePreset(id: "1280x720", label: "16:9 HD (1280 × 720)", width: 1280, height: 720),
        WindowSizePreset(id: "1600x900", label: "16:9 HD+ (1600 × 900)", width: 1600, height: 900),
        WindowSizePreset(id: "1920x1080", label: "16:9 Full HD (1920 × 1080)", width: 1920, height: 1080),
        WindowSizePreset(id: "1440x900", label: "16:10 MacBook (1440 × 900)", width: 1440, height: 900),
        WindowSizePreset(id: "1080x1080", label: "1:1 Square (1080 × 1080)", width: 1080, height: 1080),
        WindowSizePreset(id: "608x1080", label: "9:16 Vertical (608 × 1080)", width: 608, height: 1080)
    ]
}

public enum WindowDiscoveryService {
    /// Returns the `CGDirectDisplayID` for a given `NSScreen`.
    public static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
    }

    /// Returns the global Quartz rectangle (origin at top-left of primary screen, Y increasing downwards) for any `NSScreen`.
    public static func quartzFrame(for screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let qx = screen.frame.minX
        let qy = primaryHeight - screen.frame.maxY
        return CGRect(x: qx, y: qy, width: screen.frame.width, height: screen.frame.height)
    }

    /// Converts a global Quartz rectangle into local SwiftUI top-left coordinates on the given `NSScreen`.
    public static func localTopLeftRect(fromQuartzRect quartzRect: CGRect, on screen: NSScreen) -> CGRect {
        let screenQuartz = quartzFrame(for: screen)
        return CGRect(
            x: quartzRect.origin.x - screenQuartz.origin.x,
            y: quartzRect.origin.y - screenQuartz.origin.y,
            width: quartzRect.width,
            height: quartzRect.height
        )
    }

    /// Current mouse location in global Quartz coordinates (origin top-left of primary display).
    public static func currentMouseQuartzPoint() -> CGPoint {
        let cocoaMouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080.0
        return CGPoint(x: cocoaMouse.x, y: primaryHeight - cocoaMouse.y)
    }

    /// Returns the `NSScreen` currently containing the mouse cursor.
    public static func screenUnderMouse() -> NSScreen? {
        let cocoaMouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(cocoaMouse, $0.frame, false) } ?? NSScreen.main
    }

    /// Lists all normal on-screen windows across ALL connected monitors in front-to-back Z-order using `CGWindowListCopyWindowInfo`.
    public static func listFrontToBackWindows(excludingPIDs: Set<pid_t> = [ProcessInfo.processInfo.processIdentifier]) -> [CapturableWindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var results: [CapturableWindowInfo] = []
        for entry in infoList {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let windowID = entry[kCGWindowNumber as String] as? UInt32,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  !excludingPIDs.contains(ownerPID),
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 120, bounds.height >= 90 else {
                continue
            }

            let alpha = (entry[kCGWindowAlpha as String] as? Double) ?? 1.0
            guard alpha > 0.05 else { continue }

            let ownerName = (entry[kCGWindowOwnerName as String] as? String) ?? "Application"
            let windowTitle = (entry[kCGWindowName as String] as? String) ?? ""
            let runningApp = NSRunningApplication(processIdentifier: ownerPID)
            let bundleId = runningApp?.bundleIdentifier

            if bundleId == "com.apple.dock" || bundleId == "com.apple.WindowManager" || bundleId == "com.apple.controlcenter" {
                continue
            }

            results.append(
                CapturableWindowInfo(
                    id: windowID,
                    pid: ownerPID,
                    title: windowTitle,
                    appName: runningApp?.localizedName ?? ownerName,
                    bundleId: bundleId,
                    bounds: bounds,
                    borderRadius: 12.0
                )
            )
        }
        return results
    }

    /// Hit-tests the topmost window under the current mouse location across all connected monitors.
    public static func topmostWindowUnderMouse() -> CapturableWindowInfo? {
        let quartzPoint = currentMouseQuartzPoint()
        let windows = listFrontToBackWindows()
        return windows.first { $0.bounds.contains(quartzPoint) }
    }

    /// Brings the target application & window to the front before starting window capture.
    public static func bringWindowToFront(_ window: CapturableWindowInfo) {
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            app.activate()
        }
    }

    /// Resizes a target application's window using macOS Accessibility API (`AXUIElement`).
    @discardableResult
    public static func resizeWindow(_ window: CapturableWindowInfo, toWidth width: Double, height: Double) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            return false
        }

        let appElement = AXUIElementCreateApplication(window.pid)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let axWindows = windowsRef as? [AXUIElement], let targetAXWindow = axWindows.first else {
            return false
        }

        var newSize = CGSize(width: width, height: height)
        guard let sizeValue = AXValueCreate(.cgSize, &newSize) else {
            return false
        }
        return AXUIElementSetAttributeValue(targetAXWindow, kAXSizeAttribute as CFString, sizeValue) == .success
    }
}
