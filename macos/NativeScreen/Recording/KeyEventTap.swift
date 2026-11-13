import AppKit
import CoreGraphics

/// Key-down events from every app through a listen-only event tap, which needs Input Monitoring. The App Store build
/// records keystrokes this way: `NSEvent.addGlobalMonitorForEvents(.keyDown)` needs Accessibility, which a sandboxed
/// app cannot be given (ADR-85). The tap only reads; it never changes or swallows an event.
@MainActor
final class KeyEventTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    fileprivate let handler: (NSEvent) -> Void

    /// Nil when Input Monitoring is not granted yet; `requestAccess()` asks for it.
    init?(handler: @escaping (NSEvent) -> Void) {
        self.handler = handler
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: keyEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return nil
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func invalidate() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        source = nil
        tap = nil
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    static var hasAccess: Bool { CGPreflightListenEventAccess() }

    /// Shows the system prompt the first time; later calls only report the current state.
    @discardableResult
    static func requestAccess() -> Bool { CGRequestListenEventAccess() }
}

/// Runs on the main run loop, where the tap's source is installed.
nonisolated private func keyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<KeyEventTap>.fromOpaque(userInfo).takeUnretainedValue()
    MainActor.assumeIsolated {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            owner.reenable()
        case .keyDown:
            if let nsEvent = NSEvent(cgEvent: event) {
                owner.handler(nsEvent)
            }
        default:
            break
        }
    }
    return Unmanaged.passUnretained(event)
}
