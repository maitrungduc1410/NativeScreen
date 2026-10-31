import Foundation
import Observation

/// App-wide editor display preferences toggled from the `View` menu, shared by every open editor window
/// and persisted in `UserDefaults`.
@Observable
@MainActor
public final class EditorViewPreferences {
    public static let shared = EditorViewPreferences()

    public var showAudioWaveform: Bool {
        didSet { save(showAudioWaveform, Keys.showAudioWaveform) }
    }
    /// Smooth (spline) waveform vs. one bar per bin.
    public var smoothWaveform: Bool {
        didSet { save(smoothWaveform, Keys.smoothWaveform) }
    }
    /// Restart from the beginning instead of stopping at the end of the timeline.
    public var loopPlayback: Bool {
        didSet { save(loopPlayback, Keys.loopPlayback) }
    }
    public var alwaysShowTimelineScrollbar: Bool {
        didSet { save(alwaysShowTimelineScrollbar, Keys.alwaysShowTimelineScrollbar) }
    }
    public var showEditorSidebar: Bool {
        didSet { save(showEditorSidebar, Keys.showEditorSidebar) }
    }
    public var showEditorTimeline: Bool {
        didSet { save(showEditorTimeline, Keys.showEditorTimeline) }
    }

    private enum Keys {
        static let showAudioWaveform = "NativeScreen.View.ShowAudioWaveform"
        static let smoothWaveform = "NativeScreen.View.SmoothWaveform"
        static let loopPlayback = "NativeScreen.View.LoopPlayback"
        static let alwaysShowTimelineScrollbar = "NativeScreen.View.AlwaysShowTimelineScrollbar"
        static let showEditorSidebar = "NativeScreen.View.ShowEditorSidebar"
        static let showEditorTimeline = "NativeScreen.View.ShowEditorTimeline"
    }

    private init() {
        let defaults = UserDefaults.standard
        func load(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        showAudioWaveform = load(Keys.showAudioWaveform, true)
        smoothWaveform = load(Keys.smoothWaveform, true)
        loopPlayback = load(Keys.loopPlayback, false)
        alwaysShowTimelineScrollbar = load(Keys.alwaysShowTimelineScrollbar, false)
        showEditorSidebar = load(Keys.showEditorSidebar, true)
        showEditorTimeline = load(Keys.showEditorTimeline, true)
    }

    private func save(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
