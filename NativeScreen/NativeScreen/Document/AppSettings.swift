import Foundation
import AppKit
import Observation
import ServiceManagement

/// App preferences shown in the Settings window that are not owned by another store
/// (recording options live on `RecordingCoordinator`, view options on `EditorViewPreferences`).
@Observable
@MainActor
public final class AppSettings {
    public static let shared = AppSettings()

    public enum Appearance: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .system: return String(localized: "System")
            case .light: return String(localized: "Light")
            case .dark: return String(localized: "Dark")
            }
        }
    }

    public var appearance: Appearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }

    /// Where new recordings and imported videos are saved.
    public var projectsDirectoryPath: String {
        didSet { UserDefaults.standard.set(projectsDirectoryPath, forKey: Keys.projectsDirectory) }
    }

    /// Where style presets are stored.
    public var presetsDirectoryPath: String {
        didSet {
            UserDefaults.standard.set(presetsDirectoryPath, forKey: Keys.presetsDirectory)
            ProjectPresetsStore.shared.loadPresetsFromDisk()
        }
    }

    /// New projects start with the style of the last edited project (a preset marked default still wins).
    public var useLastProjectSettings: Bool {
        didSet { UserDefaults.standard.set(useLastProjectSettings, forKey: Keys.useLastProjectSettings) }
    }

    /// Save edits automatically. When off, edits are saved with ⌘S and the editor asks before closing unsaved work.
    public var autosaveEnabled: Bool {
        didSet { UserDefaults.standard.set(autosaveEnabled, forKey: Keys.autosave) }
    }

    /// Settings used by `Quick export` and by the recorder's `After Recording > Export…` actions.
    public var quickExportConfig: HardwareVideoExporter.ExportConfiguration {
        didSet {
            if let data = try? JSONEncoder().encode(quickExportConfig) {
                UserDefaults.standard.set(data, forKey: Keys.quickExport)
            }
        }
    }

    public var launchAtLogin: Bool {
        get {
            access(keyPath: \.launchAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.launchAtLogin) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    enum Keys {
        static let appearance = "NativeScreen.Settings.Appearance"
        static let projectsDirectory = "NativeScreen.Settings.ProjectsDirectory"
        static let presetsDirectory = "NativeScreen.Settings.PresetsDirectory"
        static let useLastProjectSettings = "NativeScreen.Settings.UseLastProjectSettings"
        static let autosave = "NativeScreen.Settings.Autosave"
        static let quickExport = "NativeScreen.Settings.QuickExport"
        static let lastProjectStyle = "NativeScreen.Settings.LastProjectStyle"
    }

    static let defaultProjectsDirectoryPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Native Screen Projects", isDirectory: true).path

    nonisolated static var defaultPresetsDirectoryPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("NativeScreen/Presets", isDirectory: true).path
    }

    private init() {
        let defaults = UserDefaults.standard
        appearance = defaults.string(forKey: Keys.appearance).flatMap(Appearance.init(rawValue:)) ?? .system
        projectsDirectoryPath = defaults.string(forKey: Keys.projectsDirectory) ?? Self.defaultProjectsDirectoryPath
        presetsDirectoryPath = defaults.string(forKey: Keys.presetsDirectory) ?? Self.defaultPresetsDirectoryPath
        useLastProjectSettings = defaults.bool(forKey: Keys.useLastProjectSettings)
        autosaveEnabled = defaults.object(forKey: Keys.autosave) == nil ? true : defaults.bool(forKey: Keys.autosave)
        if let data = defaults.data(forKey: Keys.quickExport),
           let config = try? JSONDecoder().decode(HardwareVideoExporter.ExportConfiguration.self, from: data) {
            quickExportConfig = config
        } else {
            var config = HardwareVideoExporter.ExportConfiguration()
            config.resolutionHeight = 1080
            config.compression = .socialMedia
            quickExportConfig = config
        }
    }

    public func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// `Toggle appearance` in the command menu: flips between light and dark (from System, flips the current look).
    public func toggleAppearance() {
        let isDarkNow = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        appearance = isDarkNow ? .light : .dark
    }

    // MARK: - Last project style

    /// Remembers the style of a project the user worked on, for `Use last project settings`.
    public func rememberLastProjectStyle(_ document: ProjectDocument) {
        let preset = ProjectPreset(name: "Last project", from: document)
        if let data = try? JSONEncoder().encode(preset) {
            UserDefaults.standard.set(data, forKey: Keys.lastProjectStyle)
        }
    }

    /// Style for a brand-new project: the default preset if one is set, otherwise the last project's style when enabled.
    public func presetForNewProject() -> ProjectPreset? {
        if let preset = ProjectPresetsStore.shared.defaultPreset {
            return preset
        }
        guard useLastProjectSettings,
              let data = UserDefaults.standard.data(forKey: Keys.lastProjectStyle) else { return nil }
        return try? JSONDecoder().decode(ProjectPreset.self, from: data)
    }

    // MARK: - Reset

    /// Clears every saved preference (projects, presets and recordings on disk are untouched).
    public func resetAllPreferences() {
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        appearance = .system
        projectsDirectoryPath = Self.defaultProjectsDirectoryPath
        presetsDirectoryPath = Self.defaultPresetsDirectoryPath
        useLastProjectSettings = false
        autosaveEnabled = true
        var config = HardwareVideoExporter.ExportConfiguration()
        config.resolutionHeight = 1080
        config.compression = .socialMedia
        quickExportConfig = config
    }
}
