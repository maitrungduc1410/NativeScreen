import AppKit
import StoreKit
import SwiftUI

/// Asks for an App Store rating with the system prompt, right after a video export succeeds (`spec/06` ADR-111).
/// Only the Mac App Store build asks; the direct build has no store page to rate.
///
/// The system decides whether the prompt shows (at most three times a year per Apple ID, never when the user turned
/// in-app ratings off) and never says whether it did or whether the user rated, so this only keeps the app from
/// asking too early or too often. Windows follows the same rules in `ReviewPrompt.cs`.
@MainActor
enum ReviewPrompt {
    /// Successful video exports before the first ask.
    static let exportsBeforeAsking = 5
    /// Days since the first successful export, so the user has come back to the app at least once.
    static let daysAfterFirstExport = 3.0
    /// Days between asks, on top of asking at most once per app version.
    static let daysBetweenAsks = 120.0
    /// After a file export Finder comes to the front. The ask waits for the user to come back, but not longer than this.
    private static let returnWindowSeconds = 600.0
    /// So the prompt does not cover the export finishing.
    private static let delaySeconds = 1.5

    private enum Keys {
        static let exports = "NativeScreen.Review.SuccessfulExports"
        static let firstExport = "NativeScreen.Review.FirstExportDate"
        static let lastAsked = "NativeScreen.Review.LastAskedDate"
        static let lastAskedVersion = "NativeScreen.Review.LastAskedVersion"
    }

    private static var pending: Task<Void, Never>?

    /// Called once per successful video export from the editor.
    static func noteSuccessfulExport(_ requestReview: RequestReviewAction) {
        #if APPSTORE
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.firstExport) == nil {
            defaults.set(Date(), forKey: Keys.firstExport)
        }
        defaults.set(defaults.integer(forKey: Keys.exports) + 1, forKey: Keys.exports)
        guard isDue() else { return }

        pending?.cancel()
        pending = Task { @MainActor in
            guard await becomesActive(within: returnWindowSeconds) else { return }
            try? await Task.sleep(for: .seconds(delaySeconds))
            // Never in the middle of something: a new recording or export may have started meanwhile.
            let recorder = RecordingCoordinator.shared
            guard !Task.isCancelled, NSApp.isActive, !recorder.isRecording, !recorder.isCountingDown, isDue() else { return }
            defaults.set(Date(), forKey: Keys.lastAsked)
            defaults.set(appVersion, forKey: Keys.lastAskedVersion)
            requestReview()
        }
        #endif
    }

    #if APPSTORE
    /// The app's App Store page with the review sheet open. For the Settings and menu items: the system prompt may
    /// show nothing when called, which a button the user pressed must never do.
    private static let writeReviewURL = URL(string: "macappstore://apps.apple.com/app/id6834245341?action=write-review")!

    /// Opens the review page. Counts as an ask, so the automatic prompt does not follow soon after.
    static func openStorePage() {
        UserDefaults.standard.set(Date(), forKey: Keys.lastAsked)
        UserDefaults.standard.set(appVersion, forKey: Keys.lastAskedVersion)
        NSWorkspace.shared.open(writeReviewURL)
    }
    #endif

    private static func isDue() -> Bool {
        #if DEBUG
        // Debug builds always show the system prompt (and never send a rating), so this lets it be checked on demand.
        if ProcessInfo.processInfo.environment["NS_REVIEW_PROMPT"] == "1" { return true }
        #endif
        let defaults = UserDefaults.standard
        let now = Date()
        guard defaults.integer(forKey: Keys.exports) >= exportsBeforeAsking,
              let first = defaults.object(forKey: Keys.firstExport) as? Date,
              now.timeIntervalSince(first) >= daysAfterFirstExport * 86_400,
              defaults.string(forKey: Keys.lastAskedVersion) != appVersion else { return false }
        if let last = defaults.object(forKey: Keys.lastAsked) as? Date {
            return now.timeIntervalSince(last) >= daysBetweenAsks * 86_400
        }
        return true
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// True once the app is active, waiting for the user to come back from Finder for up to `seconds`.
    private static func becomesActive(within seconds: Double) async -> Bool {
        if NSApp.isActive { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
