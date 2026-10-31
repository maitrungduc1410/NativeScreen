import SwiftUI
import AppKit

/// `Native Screen > Settings…` (⌘,). Native toolbar tabs; only options the app actually supports.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            RecordingSettingsTab()
                .tabItem { Label("Recording", systemImage: "record.circle") }
            EditingSettingsTab()
                .tabItem { Label("Editing", systemImage: "pencil.and.outline") }
            QuickExportSettingsTab()
                .tabItem { Label("Quick export", systemImage: "square.and.arrow.up") }
            ShortcutsSettingsTab()
                .tabItem { Label("Shortcuts", systemImage: "command.circle") }
        }
        .frame(width: 720)
    }
}

// MARK: - Building blocks

/// Title + explanation on the left, control on the right.
private struct SettingsRow<Control: View>: View {
    let title: String
    var description: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let description {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.vertical, 10)
    }
}

private struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }
}

private struct DirectoryRow: View {
    let title: String
    let path: String
    let onChoose: (URL) -> Void

    var body: some View {
        SettingsRow(title: title, description: (path as NSString).abbreviatingWithTildeInPath) {
            HStack(spacing: 8) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                Button("Change directory…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = URL(fileURLWithPath: path)
                    panel.prompt = "Choose"
                    if panel.runModal() == .OK, let url = panel.url {
                        onChoose(url)
                    }
                }
            }
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Bindable private var settings = AppSettings.shared
    @State private var isConfirmingReset = false

    var body: some View {
        SettingsPage {
            SettingsRow(
                title: "Start Native Screen at login",
                description: "Automatically start Native Screen when you log in to your Mac."
            ) {
                Toggle("", isOn: $settings.launchAtLogin)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            SettingsRow(
                title: "Appearance",
                description: "Light, dark, or follow the system setting. Also available in the command menu (⌘K)."
            ) {
                Picker("", selection: $settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Divider().padding(.vertical, 8)

            Button(role: .destructive) {
                isConfirmingReset = true
            } label: {
                Text("Reset preferences")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .confirmationDialog(
                "Reset all preferences?",
                isPresented: $isConfirmingReset
            ) {
                Button("Reset", role: .destructive) {
                    AppSettings.shared.resetAllPreferences()
                }
            } message: {
                Text("Settings return to their defaults. Your projects and presets are not deleted.")
            }
        }
    }
}

// MARK: - Recording

private struct RecordingSettingsTab: View {
    @Bindable private var settings = AppSettings.shared
    @Bindable private var recorder = RecordingCoordinator.shared

    var body: some View {
        SettingsPage {
            DirectoryRow(title: "Save new projects to", path: settings.projectsDirectoryPath) { url in
                settings.projectsDirectoryPath = url.path
            }

            SettingsRow(title: "Countdown", description: "Time before the recording starts.") {
                Picker("", selection: $recorder.countdownOption) {
                    ForEach(RecordingCountdownOption.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            SettingsRow(
                title: "Highlight recorded area during recording",
                description: "The part of the screen that is not being recorded is slightly dimmed."
            ) {
                Toggle("", isOn: $recorder.highlightRecordedArea).toggleStyle(.switch).labelsHidden()
            }

            SettingsRow(title: "Hide desktop icons while recording") {
                Toggle("", isOn: $recorder.hideDesktopIcons).toggleStyle(.switch).labelsHidden()
            }

            SettingsRow(
                title: "Hide Dock icon while recording",
                description: "The app stays reachable from the recording bar and the menu bar icon."
            ) {
                Toggle("", isOn: $recorder.hideDockIcon).toggleStyle(.switch).labelsHidden()
            }

            SettingsRow(
                title: "Create zooms automatically",
                description: "Analyze clicks and typing during the recording and add zooms to every new project."
            ) {
                Toggle("", isOn: $recorder.autoCreateZooms).toggleStyle(.switch).labelsHidden()
            }

            SettingsRow(title: "After recording", description: "What happens when you stop a recording.") {
                Picker("", selection: $recorder.afterRecordingAction) {
                    ForEach(RecordingCoordinator.AfterRecordingAction.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }

            SettingsRow(
                title: "Maximum camera resolution",
                description: "Highest resolution the camera is recorded at, if supported. Higher resolutions look better but use more resources while recording."
            ) {
                Picker("", selection: $recorder.cameraMaxResolution) {
                    ForEach(CameraMaxResolutionOption.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

// MARK: - Editing

private struct EditingSettingsTab: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        SettingsPage {
            SettingsRow(
                title: "Use last project settings as default for new recordings",
                description: "New projects start with the style of the last project you edited. A preset marked as default is used instead when there is one."
            ) {
                Toggle("", isOn: $settings.useLastProjectSettings).toggleStyle(.switch).labelsHidden()
            }

            SettingsRow(
                title: "Use autosave",
                description: "Save project changes automatically. When off, save with ⌘S; closing a project with unsaved changes asks first."
            ) {
                Toggle("", isOn: $settings.autosaveEnabled).toggleStyle(.switch).labelsHidden()
            }

            DirectoryRow(title: "Save presets in", path: settings.presetsDirectoryPath) { url in
                settings.presetsDirectoryPath = url.path
            }
        }
    }
}

// MARK: - Quick export

private struct QuickExportSettingsTab: View {
    @Bindable private var settings = AppSettings.shared

    private var config: Binding<HardwareVideoExporter.ExportConfiguration> {
        Binding(
            get: { settings.quickExportConfig },
            set: { newValue in
                var normalized = newValue
                normalized.normalizeForConstraints()
                settings.quickExportConfig = normalized
            }
        )
    }

    var body: some View {
        SettingsPage {
            Text("Used by Quick export to clipboard (⌥⌘C), Quick export to file (⌥⌘S), and the Export actions after recording.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)

            SettingsRow(title: "Format") {
                Picker("", selection: config.format) {
                    ForEach(HardwareVideoExporter.ExportFormat.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            SettingsRow(title: "Frame rate") {
                Picker("", selection: config.fps) {
                    ForEach(config.wrappedValue.format.allowedFPSModes, id: \.self) { Text("\($0) FPS").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }

            SettingsRow(title: "Resolution") {
                Picker("", selection: config.resolutionHeight) {
                    ForEach(config.wrappedValue.enabledResolutionHeights, id: \.self) {
                        Text(HardwareVideoExporter.ExportConfiguration.resolutionLabel(forHeight: $0)).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            switch config.wrappedValue.format {
            case .mp4:
                SettingsRow(title: "Compression", description: config.wrappedValue.compression.descriptionText) {
                    Picker("", selection: config.compression) {
                        ForEach(HardwareVideoExporter.ExportCompression.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow(title: "Codec", description: config.wrappedValue.mp4Codec.descriptionText) {
                    Picker("", selection: config.mp4Codec) {
                        ForEach(HardwareVideoExporter.MP4CodecOption.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            case .prores:
                SettingsRow(title: "ProRes profile", description: config.wrappedValue.proResProfile.descriptionText) {
                    Picker("", selection: config.proResProfile) {
                        ForEach(HardwareVideoExporter.ProResProfileOption.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            case .gif:
                SettingsRow(title: "High quality") {
                    Toggle("", isOn: config.gifHighQuality).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "Disable loop") {
                    Toggle("", isOn: config.gifDisableLoop).toggleStyle(.switch).labelsHidden()
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: settings.quickExportConfig.format)
    }
}

// MARK: - Shortcuts

/// Read-only reference of the keyboard shortcuts the app supports (they are not customizable yet).
private struct ShortcutsSettingsTab: View {
    private enum Section: String, CaseIterable, Identifiable {
        case recording = "Recording"
        case editing = "Editing"
        var id: String { rawValue }
    }

    private struct Shortcut: Identifiable {
        let icon: String
        let title: String
        let keys: String
        var id: String { title }
    }

    @State private var section: Section = .recording

    private let recordingShortcuts: [Shortcut] = [
        Shortcut(icon: "record.circle", title: "New recording", keys: "⌃ ⌘ ↩"),
        Shortcut(icon: "rectangle.inset.bottomleft.filled", title: "Record entire display", keys: "⌥ ⌘ 3"),
        Shortcut(icon: "macwindow", title: "Record single window", keys: "⌥ ⌘ 4"),
        Shortcut(icon: "rectangle.dashed", title: "Record area", keys: "⌥ ⌘ 5"),
        Shortcut(icon: "record.circle", title: "Show / hide recording widget", keys: "⌥ ⌘ '")
    ]

    private let editingShortcuts: [Shortcut] = [
        Shortcut(icon: "playpause", title: "Play or pause", keys: "Space"),
        Shortcut(icon: "scissors", title: "Split clip at playhead", keys: "C"),
        Shortcut(icon: "scissors", title: "Split mode (hold)", keys: "⌥"),
        Shortcut(icon: "arrow.left.and.right", title: "Previous / next frame", keys: "← →"),
        Shortcut(icon: "arrow.left.and.right", title: "Jump back 2s / forward 1s", keys: "⇧ ← →"),
        Shortcut(icon: "backward.end", title: "Go to start / end", keys: "⌘ ← →"),
        Shortcut(icon: "trash", title: "Delete selected item", keys: "⌫"),
        Shortcut(icon: "doc.on.doc", title: "Copy / cut / paste zoom or mask", keys: "⌘ C  ⌘ X  ⌘ V"),
        Shortcut(icon: "plus.square.on.square", title: "Duplicate zoom", keys: "⌘ D"),
        Shortcut(icon: "eye.slash", title: "Hide or show camera", keys: "H"),
        Shortcut(icon: "plus.magnifyingglass", title: "Zoom timeline in / out", keys: "⌘ +  ⌘ −"),
        Shortcut(icon: "command", title: "Command menu", keys: "⌘ K"),
        Shortcut(icon: "sidebar.right", title: "Sidebar tabs", keys: "⌘ 1 … ⌘ 0"),
        Shortcut(icon: "arrow.uturn.backward", title: "Undo / redo", keys: "⌘ Z  ⇧ ⌘ Z"),
        Shortcut(icon: "square.and.arrow.down", title: "Save", keys: "⌘ S"),
        Shortcut(icon: "square.and.arrow.up", title: "Export", keys: "⇧ ⌘ E"),
        Shortcut(icon: "doc.on.clipboard", title: "Quick export to clipboard", keys: "⌥ ⌘ C"),
        Shortcut(icon: "square.and.arrow.up", title: "Quick export to file", keys: "⌥ ⌘ S")
    ]

    var body: some View {
        SettingsPage {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)

            ForEach(section == .recording ? recordingShortcuts : editingShortcuts) { shortcut in
                HStack(spacing: 12) {
                    Image(systemName: shortcut.icon)
                        .frame(width: 20)
                        .foregroundStyle(.secondary)
                    Text(shortcut.title)
                        .font(.system(size: 13))
                    Spacer()
                    Text(shortcut.keys)
                        .font(.system(size: 12.5, weight: .medium).monospaced())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.10)))
                }
                .padding(.vertical, 6)
            }

            Text(section == .recording
                 ? "Recording shortcuts work while Native Screen is the active app."
                 : "Editing shortcuts work in a project window.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
        }
    }
}
