import AppKit
import Foundation

/// NativeScreen's own UI language, independent of the system's. Stored where macOS keeps the per-app choice from
/// System Settings (`AppleLanguages` in the app's domain), so the two stay in sync. Takes effect on next launch.
/// Strings live in `Localizable.xcstrings`; see ADR-44 in `spec/06`.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = ""
    case english = "en"
    case german = "de"
    case spanish = "es"
    case french = "fr"
    case portuguese = "pt-BR"
    case vietnamese = "vi"
    case japanese = "ja"
    case chinese = "zh-Hans"

    public var id: String { rawValue }

    /// Each language in its own words, so people can find theirs whatever the app is showing now.
    public var title: String {
        switch self {
        case .system: String(localized: "System")
        case .english: "English"
        case .german: "Deutsch"
        case .spanish: "Español"
        case .french: "Français"
        case .portuguese: "Português (Brasil)"
        case .vietnamese: "Tiếng Việt"
        case .japanese: "日本語"
        case .chinese: "简体中文"
        }
    }

    private static let key = "AppleLanguages"

    /// Reads only the app's own domain; the global `AppleLanguages` is the system order.
    public static var current: AppLanguage {
        guard let domain = Bundle.main.bundleIdentifier,
              let code = (UserDefaults.standard.persistentDomain(forName: domain)?[key] as? [String])?.first
        else { return .system }
        // System Settings may add a region, e.g. "vi-VN".
        return allCases.first { $0 != .system && (code == $0.rawValue || code.hasPrefix($0.rawValue + "-")) } ?? .system
    }

    /// The language this run started with; the UI only changes language on relaunch.
    public static let atLaunch = current

    /// Quits (unsaved projects still ask first) and opens the app again once this process is gone.
    @MainActor
    public static func relaunch() {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [
            "-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done; open \"$0\"",
            Bundle.main.bundlePath,
        ]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }

    public static func choose(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: key)
        }
    }
}

extension String {
    /// Looks the string up in `Localizable.xcstrings` at runtime. For components that take a plain `String`
    /// (tooltips, segment titles, pill labels): call sites pass English literals and the component translates
    /// when it draws. Strings with no entry, such as file names, come back unchanged.
    public var localizedUI: String {
        Bundle.main.localizedString(forKey: self, value: self, table: nil)
    }
}
