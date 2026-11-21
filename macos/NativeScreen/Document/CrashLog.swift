import AppKit
import Darwin
import Foundation
import MetricKit

/// One text file per crash or caught error in `Logs` of the app's data folder, with the machine, what went wrong and the
/// last steps the app took (`spec/06` ADR-103). The same files and notice as Windows (ADR-98).
///
/// Three layers, since none catches everything:
/// - An uncaught Objective-C exception (`NSApplicationCrashOnExceptions` makes AppKit stop swallowing them) is written
///   with its reason and stack from a normal context.
/// - A fatal signal (a Swift runtime trap, a bad memory access, an abort) is written from the signal handler, which may
///   only call async-signal-safe functions. It writes into a file opened at launch (`crash-pending.txt`), which the next
///   launch names after its time. It has the stack but not the text of a `fatalError`.
/// - MetricKit hands the next launch the system's own crash, hang, CPU and disk-write reports, which also cover what the
///   handlers miss (a hang, a kill by the system). They are saved as `diagnostic-...json`.
enum CrashLog {
    static let crashPrefix = "crash-"
    static let errorPrefix = "error-"
    static let diagnosticPrefix = "diagnostic-"
    private static let pendingName = "crash-pending.txt"
    private static let keepPerKind = 10
    private static let breadcrumbCount = 100
    private static let breadcrumbBytes = 256
    private static let headerBytes = 4096
    private static let exceptionBytes = 1024
    private static let lastSeenKey = "NativeScreen.LastSeenCrashLog"

    static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("NativeScreen/Logs", isDirectory: true)
    }

    // Plain C memory the signal handler reads; it must not touch Swift objects, locks or the allocator.
    private nonisolated(unsafe) static var header = UnsafeMutablePointer<CChar>.allocate(capacity: headerBytes)
    private nonisolated(unsafe) static var breadcrumbs = UnsafeMutablePointer<CChar>.allocate(capacity: breadcrumbCount * breadcrumbBytes)
    private nonisolated(unsafe) static var nextBreadcrumb = 0
    /// The last Objective-C exception thrown, caught or not. AppKit ends the app on an exception in an event handler
    /// with a trap of its own, which runs no uncaught-exception handler, so this is how the crash file gets its reason.
    private nonisolated(unsafe) static var lastException = UnsafeMutablePointer<CChar>.allocate(capacity: exceptionBytes)
    private nonisolated(unsafe) static var previousPreprocessor: ExceptionPreprocessor?
    private nonisolated(unsafe) static var pendingFD: Int32 = -1
    /// Set once a crash file is written, so the abort that follows an exception does not write a second one.
    private nonisolated(unsafe) static var crashWritten: Int32 = 0
    private nonisolated(unsafe) static var lock = os_unfair_lock()
    private static let startUptime = ProcessInfo.processInfo.systemUptime
    private static let metricSubscriber = MetricSubscriber()

    // MARK: - Start

    /// Called first thing in `main`, before AppKit starts.
    static func start() {
        header.initialize(repeating: 0, count: headerBytes)
        breadcrumbs.initialize(repeating: 0, count: breadcrumbCount * breadcrumbBytes)
        lastException.initialize(repeating: 0, count: exceptionBytes)
        // An exception in an AppKit event handler is logged and swallowed by default; this makes it end the app instead,
        // through the uncaught-exception handler, so it is written down.
        UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        namePendingCrash()
        setHeader(describeApp() + "\n" + describeMachine(includeDisplays: false))
        pendingFD = open(folder.appendingPathComponent(pendingName).path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        // `backtrace` loads its unwinder on first use, which allocates: do it now, not inside a signal handler.
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 4)
        _ = backtrace(&frames, 4)
        NSSetUncaughtExceptionHandler { exception in CrashLog.writeException(exception) }
        installExceptionPreprocessor()
        for signal in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE, SIGSYS] {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = { signal, _, _ in CrashLog.handleSignal(signal) }
            action.sa_flags = SA_SIGINFO | SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, nil)
        }
        installAlternateStack()
        note("launched")
    }

    /// Once AppKit runs: the displays join the header, and MetricKit starts delivering reports.
    @MainActor
    static func didFinishLaunching() {
        setHeader(describeApp() + "\n" + describeMachine(includeDisplays: true))
        MXMetricManager.shared.add(metricSubscriber)
        #if DEBUG
        CrashTest.runIfAsked()
        #endif
    }

    // MARK: - Breadcrumbs and errors

    /// A step worth knowing after a crash. Kept in memory only; written with the next crash or error.
    static func note(_ step: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - startUptime
        let line = String(format: "%10.0f ms  ", elapsed * 1000) + step
        os_unfair_lock_lock(&lock)
        let slot = breadcrumbs + (nextBreadcrumb % breadcrumbCount) * breadcrumbBytes
        copyCString(line, to: slot, capacity: breadcrumbBytes)
        nextBreadcrumb += 1
        os_unfair_lock_unlock(&lock)
    }

    /// An error the app recovered from, with what the user was doing. Never throws.
    @discardableResult
    static func writeError(_ what: String, error: Error? = nil) -> URL? {
        var body = what
        if let error {
            let ns = error as NSError
            body += "\n\n\(ns.domain) \(ns.code): \(ns.localizedDescription)"
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                body += "\nUnderlying: \(underlying.domain) \(underlying.code): \(underlying.localizedDescription)"
            }
        }
        body += "\n\nStack:\n" + Thread.callStackSymbols.joined(separator: "\n")
        return writeFile(prefix: errorPrefix, title: "Native Screen error, the app kept running", body: body)
    }

    // MARK: - Files

    /// The newest crash file, or nil.
    static func newestCrash() -> URL? {
        files(prefix: crashPrefix).first
    }

    /// The local time a crash file names, read from its name.
    static func time(of file: URL) -> Date {
        let name = file.deletingPathExtension().lastPathComponent
        let stamp = String(name.dropFirst(crashPrefix.count).prefix(19))
        return fileStampFormatter.date(from: stamp)
            ?? ((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date())
    }

    /// The newest crash the user has not been told about, marked as seen.
    static func takeUnseenCrash() -> URL? {
        guard let crash = newestCrash() else { return nil }
        let seen = UserDefaults.standard.string(forKey: lastSeenKey) ?? ""
        guard crash.lastPathComponent > seen else { return nil }
        UserDefaults.standard.set(crash.lastPathComponent, forKey: lastSeenKey)
        return crash
    }

    private static func files(prefix: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { $0.hasPrefix(prefix) && $0 != pendingName }
            .sorted(by: >)
            .map { folder.appendingPathComponent($0) }
    }

    private static func prune(prefix: String) {
        for old in files(prefix: prefix).dropFirst(keepPerKind) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    private static func uniqueURL(prefix: String, date: Date, ext: String) -> URL {
        let stamp = fileStampFormatter.string(from: date)
        var url = folder.appendingPathComponent("\(prefix)\(stamp).\(ext)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(prefix)\(stamp)-\(suffix).\(ext)")
            suffix += 1
        }
        return url
    }

    private static func writeFile(prefix: String, title: String, body: String) -> URL? {
        let now = Date()
        let text = """
        \(title)
        Time: \(timeLine(now))
        \(String(cString: header))

        \(body)

        Last steps (oldest first):
        \(breadcrumbLines())
        """
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(prefix: prefix, date: now, ext: "txt")
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        prune(prefix: prefix)
        return url
    }

    /// The crash the last run wrote from its signal handler gets the time it was written in its name.
    private static func namePendingCrash() {
        let pending = folder.appendingPathComponent(pendingName)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: pending.path),
              (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else { return }
        let date = attributes[.modificationDate] as? Date ?? Date()
        let target = uniqueURL(prefix: crashPrefix, date: date, ext: "txt")
        // The signal handler cannot format a date; the time it was written goes in now.
        if let text = try? String(contentsOf: pending, encoding: .utf8) {
            let timed = text.replacingOccurrences(of: "Time: the time this file was last changed", with: "Time: \(timeLine(date))")
            try? timed.write(to: pending, atomically: false, encoding: .utf8)
        }
        try? FileManager.default.moveItem(at: pending, to: target)
        prune(prefix: crashPrefix)
    }

    private static func timeLine(_ date: Date) -> String {
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let utc = DateFormatter()
        utc.locale = local.locale
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = local.dateFormat
        return "\(local.string(from: date)) local, \(utc.string(from: date)) UTC"
    }

    private static func breadcrumbLines() -> String {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let first = max(0, nextBreadcrumb - breadcrumbCount)
        return (first..<nextBreadcrumb)
            .map { String(cString: breadcrumbs + ($0 % breadcrumbCount) * breadcrumbBytes) }
            .joined(separator: "\n")
    }

    // MARK: - Exceptions and signals

    private static func writeException(_ exception: NSException) {
        guard OSAtomicCompareAndSwap32(0, 1, &crashWritten) else { return }
        let body = """
        Uncaught exception: \(exception.name.rawValue)
        Reason: \(exception.reason ?? "none")
        User info: \(exception.userInfo.map { "\($0)" } ?? "none")

        Stack:
        \(exception.callStackSymbols.joined(separator: "\n"))
        """
        _ = writeFile(prefix: crashPrefix, title: "Native Screen crash: uncaught exception, the app closed", body: body)
    }

    /// Runs inside the signal handler: only `write`, `backtrace_symbols_fd`, plain memory reads and `raise`.
    private static func handleSignal(_ signal: Int32) {
        if OSAtomicCompareAndSwap32(0, 1, &crashWritten), pendingFD >= 0 {
            let fd = pendingFD
            writeRaw(fd, "Native Screen crash: signal ")
            writeRaw(fd, signalName(signal))
            writeRaw(fd, ", the app closed\nTime: the time this file was last changed\n")
            writeRaw(fd, header)
            if lastException[0] != 0 {
                writeRaw(fd, "\n\nLast Objective-C exception thrown (the cause when it ended the app; it may have been caught):\n")
                writeRaw(fd, lastException)
            }
            writeRaw(fd, "\n\nStack:\n")
            var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
            let count = frames.withUnsafeMutableBufferPointer { backtrace($0.baseAddress, 128) }
            frames.withUnsafeMutableBufferPointer { backtrace_symbols_fd($0.baseAddress, count, fd) }
            writeRaw(fd, "\nLast steps (oldest first):\n")
            let last = nextBreadcrumb
            var index = max(0, last - breadcrumbCount)
            while index < last {
                writeRaw(fd, breadcrumbs + (index % breadcrumbCount) * breadcrumbBytes)
                writeRaw(fd, "\n")
                index += 1
            }
            fsync(fd)
        }
        // The system's own handler writes its crash report too.
        var action = sigaction()
        action.__sigaction_u.__sa_handler = SIG_DFL
        sigemptyset(&action.sa_mask)
        sigaction(signal, &action, nil)
        raise(signal)
    }

    private static func signalName(_ signal: Int32) -> StaticString {
        switch signal {
        case SIGABRT: "SIGABRT (abort, often a Swift fatal error or an exception)"
        case SIGSEGV: "SIGSEGV (bad memory access)"
        case SIGBUS: "SIGBUS (bad memory access)"
        case SIGILL: "SIGILL (illegal instruction)"
        case SIGTRAP: "SIGTRAP (a Swift runtime check failed, such as a nil unwrap, an index out of range or fatalError, or AppKit ended the app on an exception)"
        case SIGFPE: "SIGFPE (arithmetic error)"
        case SIGSYS: "SIGSYS (bad system call)"
        default: "unknown"
        }
    }

    private static func writeRaw(_ fd: Int32, _ text: StaticString) {
        _ = Darwin.write(fd, text.utf8Start, text.utf8CodeUnitCount)
    }

    private static func writeRaw(_ fd: Int32, _ text: UnsafePointer<CChar>) {
        _ = Darwin.write(fd, text, strlen(text))
    }

    private typealias ExceptionPreprocessor = @convention(c) (AnyObject?) -> AnyObject?
    private typealias SetExceptionPreprocessor = @convention(c) (ExceptionPreprocessor?) -> ExceptionPreprocessor?

    /// `objc_setExceptionPreprocessor` sees every exception as it is thrown. It is not in the Swift overlay, so it is
    /// looked up by name.
    private static func installExceptionPreprocessor() {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_setExceptionPreprocessor") else { return }
        let setPreprocessor = unsafeBitCast(symbol, to: SetExceptionPreprocessor.self)
        previousPreprocessor = setPreprocessor { object in
            if let exception = object as? NSException {
                CrashLog.copyCString("\(exception.name.rawValue): \(exception.reason ?? "no reason")", to: CrashLog.lastException, capacity: CrashLog.exceptionBytes)
            }
            return CrashLog.previousPreprocessor?(object) ?? object
        }
    }

    /// A stack overflow leaves no stack for the handler; it runs on this one instead.
    private static func installAlternateStack() {
        let size = Int(SIGSTKSZ) * 4
        var stack = stack_t()
        stack.ss_sp = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        stack.ss_size = size
        stack.ss_flags = 0
        sigaltstack(&stack, nil)
    }

    private static func setHeader(_ text: String) {
        copyCString(text, to: header, capacity: headerBytes)
    }

    private static func copyCString(_ text: String, to destination: UnsafeMutablePointer<CChar>, capacity: Int) {
        var bytes = Array(text.utf8.prefix(capacity - 1))
        // A cut in the middle of a multi-byte character would leave invalid UTF-8.
        while let last = bytes.last, last & 0xC0 == 0x80 { bytes.removeLast() }
        if let last = bytes.last, last >= 0xC0 { bytes.removeLast() }
        bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { UnsafeMutableRawPointer(destination).copyMemory(from: $0, byteCount: buffer.count) }
        }
        destination[bytes.count] = 0
    }

    // MARK: - Machine

    private static func describeApp() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        #if APPSTORE
        let channel = "Mac App Store"
        #else
        let channel = "GitHub"
        #endif
        #if DEBUG
        let configuration = ", Debug"
        #else
        let configuration = ""
        #endif
        return "App: Native Screen \(version) (\(build), \(channel) build\(configuration))"
    }

    private static func describeMachine(includeDisplays: Bool) -> String {
        let info = ProcessInfo.processInfo
        var lines = [
            "macOS: \(info.operatingSystemVersionString)",
            "Mac: \(sysctlString("hw.model") ?? "?"), \(sysctlString("machdep.cpu.brand_string") ?? "?"), \(info.processorCount) cores, \(info.physicalMemory / 1_073_741_824) GB RAM",
            "Language: \(Locale.preferredLanguages.first ?? "?")",
        ]
        if includeDisplays {
            let displays = NSScreen.screens.map { screen in
                let size = screen.frame.size
                return "\(Int(size.width))x\(Int(size.height)) @\(screen.backingScaleFactor)x \(screen.maximumFramesPerSecond) Hz"
            }
            lines.append("Displays: " + (displays.isEmpty ? "none" : displays.joined(separator: "; ")))
        }
        return lines.joined(separator: "\n")
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }

    // MARK: - MetricKit

    /// Saves the system's diagnostic reports from earlier runs (crashes, hangs, CPU and disk-write exceptions).
    private final class MetricSubscriber: NSObject, MXMetricManagerSubscriber {
        func didReceive(_ payloads: [MXDiagnosticPayload]) {
            for payload in payloads {
                try? FileManager.default.createDirectory(at: CrashLog.folder, withIntermediateDirectories: true)
                let url = CrashLog.uniqueURL(prefix: CrashLog.diagnosticPrefix, date: payload.timeStampEnd, ext: "json")
                try? payload.jsonRepresentation().write(to: url, options: .atomic)
            }
            CrashLog.prune(prefix: CrashLog.diagnosticPrefix)
        }
    }
}

extension CrashLog {
    /// A Debug run started with `NS_CRASH_TEST`. It shares the installed app's data folder, so it leaves the AI agent
    /// socket and interrupted recordings alone.
    static var isCrashTestRun: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["NS_CRASH_TEST"] != nil
        #else
        false
        #endif
    }
}

#if DEBUG
/// `NS_CRASH_TEST=<kind>` (Debug builds only) fails on purpose 2 s after launch, to check what each path writes:
/// `swift` (a nil unwrap), `objc` (an exception in an event handler), `segv` (a bad pointer), `background` (a trap off the
/// main thread), `error` (an error file, the app keeps running), `notice` (only the notice for the newest unseen crash).
/// Test runs other than `notice` skip the notice.
private enum CrashTest {
    @MainActor
    static func runIfAsked() {
        guard let kind = ProcessInfo.processInfo.environment["NS_CRASH_TEST"] else { return }
        CrashLog.note("crash test \(kind) in 2 s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            switch kind {
            case "swift":
                let missing: Int? = Int("not a number")
                CrashLog.note("about to unwrap nil")
                print(missing!)
            case "objc":
                NSArray().object(at: 3)
            case "segv":
                let pointer = UnsafeMutablePointer<Int>(bitPattern: 0x10)!
                pointer.pointee = 1
            case "background":
                Thread.detachNewThread {
                    CrashLog.note("background thread")
                    let values = [1, 2, 3]
                    print(values[Int("7") ?? 0])
                }
            case "error":
                CrashLog.writeError("Crash test error", error: NSError(domain: "CrashTest", code: 42, userInfo: [NSLocalizedDescriptionKey: "A test error"]))
            default:
                break
            }
        }
    }
}
#endif

/// What the crash notice and `Settings > General > Troubleshooting` do with the crash files.
@MainActor
enum CrashReports {
    /// Shown once at launch when the newest crash is one the user has not been told about.
    static func showNoticeIfNew() {
        // A crash test would otherwise stop at the notice for the crash before it.
        if CrashLog.isCrashTestRun, ProcessInfo.processInfo.environment["NS_CRASH_TEST"] != "notice" { return }
        guard let crash = CrashLog.takeUnseenCrash() else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: "Native Screen closed unexpectedly on %@.".localizedUI, formatted(CrashLog.time(of: crash)))
        alert.addButton(withTitle: "Open log folder".localizedUI)
        alert.addButton(withTitle: "Copy crash report".localizedUI)
        alert.addButton(withTitle: "Close".localizedUI)
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: openLogFolder()
        case .alertSecondButtonReturn: copyNewest()
        default: break
        }
    }

    /// Finder with the newest crash file selected, or the log folder when there is none.
    static func openLogFolder() {
        if let crash = CrashLog.newestCrash() {
            NSWorkspace.shared.activateFileViewerSelecting([crash])
        } else {
            try? FileManager.default.createDirectory(at: CrashLog.folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(CrashLog.folder)
        }
    }

    /// The newest crash file's text on the clipboard.
    static func copyNewest() {
        guard let crash = CrashLog.newestCrash(), let text = try? String(contentsOf: crash, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// "Last crash: <date>" or "No crashes recorded".
    static var lastCrashText: String {
        guard let crash = CrashLog.newestCrash() else { return "No crashes recorded".localizedUI }
        return String(format: "Last crash: %@".localizedUI, formatted(CrashLog.time(of: crash)))
    }

    private static func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
