import Foundation
import Observation
import Sparkle

/// App updates through Sparkle. The feed is `appcast.xml` on the latest GitHub release (`SUFeedURL` in Info.plist),
/// signed with the EdDSA key whose public half the release workflow passes as `SPARKLE_PUBLIC_KEY`. See ADR-53.
///
/// Builds without that key (every local build) have no updater: the menu item and the setting stay hidden, so a
/// development build never replaces itself with a release.
@Observable
@MainActor
public final class AppUpdater {
    public static let shared = AppUpdater()

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// False while a check is already running.
    public private(set) var canCheckForUpdates = false

    public var isAvailable: Bool { controller != nil }

    public var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    private init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.isEmpty, !key.hasPrefix("$(") else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        canCheckForUpdates = controller.updater.canCheckForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    public func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
