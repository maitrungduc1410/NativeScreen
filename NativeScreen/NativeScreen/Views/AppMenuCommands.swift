import SwiftUI
import AppKit

/// Main menu bar (`File`, `Edit`, `Record`, `Export`, `View`, `Window`).
/// Editor commands act on the project whose editor window is key (`ProjectWorkspaceStore.activeSession`).
/// Shortcuts the editor's key monitor already handles (⌘S, ⌘Z, ⌘1…) are consumed there first, so the menu
/// only runs them when picked with the mouse.
struct AppMenuCommands: Commands {
    @Bindable var workspace: ProjectWorkspaceStore
    @Bindable var recorder: RecordingCoordinator
    @Bindable var preferences: EditorViewPreferences

    private var session: ProjectSession? { workspace.activeSession }

    var body: some Commands {
        // MARK: File
        CommandGroup(replacing: .newItem) {
            Menu("Open recent") {
                ForEach(workspace.recentProjectURLs.prefix(15), id: \.path) { url in
                    Button(url.deletingPathExtension().lastPathComponent) {
                        workspace.openOrFocusProject(at: url)
                    }
                }
                if !workspace.recentProjectURLs.isEmpty {
                    Divider()
                    Button("Clear menu") { workspace.clearRecentProjects() }
                }
            }
            .disabled(workspace.recentProjectURLs.isEmpty)

            Divider()

            Button("Open project…", systemImage: "folder") { workspace.promptOpenProjectDialog() }
                .keyboardShortcut("o", modifiers: [.command])
            Button("Open last project", systemImage: "arrow.counterclockwise") { workspace.openLastProject() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(workspace.recentProjectURLs.isEmpty)
            Button("Show previous projects", systemImage: "folder") { workspace.revealProjectsFolder() }

            Divider()

            Button("Create project from video…", systemImage: "folder") { VideoProjectImporter.promptAndCreateProject() }
            Button("Create interactive showcase project", systemImage: "sparkles.rectangle.stack") {
                _ = recorder.createInteractiveSampleProject()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()

            Button("Import preset…", systemImage: "square.and.arrow.down") { ProjectPresetsStore.shared.promptImportPresets() }
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save", systemImage: "square.and.arrow.down") { session?.saveProjectWithToast() }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(session == nil)
            Button("Save as…", systemImage: "square.and.arrow.down") { workspace.saveActiveProjectAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(session == nil)
            Button("Show project in Finder", systemImage: "folder") {
                if let session { NSWorkspace.shared.activateFileViewerSelecting([session.packageURL]) }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(session == nil)

            Divider()

            Button("Remove project", systemImage: "trash") { session?.pendingEditorCommand = .removeProject }
                .disabled(session == nil)
        }

        // MARK: Edit
        CommandGroup(replacing: .undoRedo) {
            Button("Undo", systemImage: "arrow.uturn.backward") {
                if !Self.sendToTextResponder(Selector(("undo:"))) { session?.undo() }
            }
            .keyboardShortcut("z", modifiers: [.command])
            Button("Redo", systemImage: "arrow.uturn.forward") {
                if !Self.sendToTextResponder(Selector(("redo:"))) { session?.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                if !Self.sendToTextResponder(#selector(NSText.cut(_:))), let session {
                    if let id = session.selectedMaskId {
                        session.cutMaskToClipboard(id: id)
                    } else if let id = session.selectedZoomId {
                        session.cutZoomToClipboard(id: id)
                    }
                }
            }
            .keyboardShortcut("x", modifiers: [.command])
            Button("Copy") {
                if !Self.sendToTextResponder(#selector(NSText.copy(_:))), let session {
                    if let id = session.selectedMaskId {
                        session.copyMaskToClipboard(id: id)
                    } else if let id = session.selectedZoomId {
                        session.copyZoomToClipboard(id: id)
                    } else {
                        session.copyCurrentFrameToClipboard()
                    }
                }
            }
            .keyboardShortcut("c", modifiers: [.command])
            Button("Paste") {
                if !Self.sendToTextResponder(#selector(NSText.paste(_:))) { session?.pasteFromClipboard() }
            }
            .keyboardShortcut("v", modifiers: [.command])
            Button("Paste and Match Style") {
                _ = Self.sendToTextResponder(#selector(NSTextView.pasteAsPlainText(_:)))
            }
            .keyboardShortcut("v", modifiers: [.command, .option, .shift])
            Button("Delete") {
                if !Self.sendToTextResponder(#selector(NSText.delete(_:))) { session?.deleteSelectedTimelineItem() }
            }
            Button("Select All") {
                _ = Self.sendToTextResponder(#selector(NSText.selectAll(_:)))
            }
            .keyboardShortcut("a", modifiers: [.command])
        }

        // MARK: Record
        CommandMenu("Record") {
            Button("New recording…", systemImage: "record.circle") { recorder.showRecordingHUD() }
                .keyboardShortcut(.return, modifiers: [.command, .control])
                .disabled(recorder.isRecording)

            Divider()

            Button("Record display", systemImage: "rectangle.inset.bottomleft.filled") { recorder.showRecordingHUD(mode: .display) }
                .keyboardShortcut("3", modifiers: [.command, .option])
                .disabled(recorder.isRecording)
            Button("Record window", systemImage: "macwindow") { recorder.showRecordingHUD(mode: .window) }
                .keyboardShortcut("4", modifiers: [.command, .option])
                .disabled(recorder.isRecording)
            Button("Record area", systemImage: "rectangle.dashed") { recorder.showRecordingHUD(mode: .area) }
                .keyboardShortcut("5", modifiers: [.command, .option])
                .disabled(recorder.isRecording)

            Button("Record this project window", systemImage: "macwindow.badge.plus") {
                if let window = workspace.activeEditorCaptureWindow {
                    recorder.startRecordingWindow(window)
                }
            }
            .disabled(recorder.isRecording || session == nil)

            Picker("After Recording", selection: $recorder.afterRecordingAction) {
                ForEach(RecordingCoordinator.AfterRecordingAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }
            .pickerStyle(.inline)

            Toggle("Automatically create zooms", isOn: $recorder.autoCreateZooms)
        }

        // MARK: Export
        CommandMenu("Export") {
            Button("Export…", systemImage: "square.and.arrow.up") { session?.pendingEditorCommand = .showExportSheet }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(session == nil)

            Divider()

            Button("Quick export to clipboard", systemImage: "doc.on.clipboard") { session?.pendingEditorCommand = .quickExport(.clipboard) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(session == nil)
            Button("Quick export to file…", systemImage: "square.and.arrow.up") { session?.pendingEditorCommand = .quickExport(.file) }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(session == nil)
            Button("Show previous clipboard exports", systemImage: "folder") {
                let recent = ProjectWorkspaceStore.recentClipboardExports(limit: 1)
                NSWorkspace.shared.activateFileViewerSelecting(
                    recent.isEmpty ? [ProjectWorkspaceStore.clipboardExportsDirectory] : recent
                )
            }

            Divider()

            Button("Extract raw recording files…", systemImage: "square.and.arrow.down") { workspace.extractRawRecordingFiles() }
                .disabled(session == nil)

            Divider()

            Button("Export current frame as image…", systemImage: "photo") { session?.openStillFrameExportModal() }
                .disabled(session == nil)
        }

        // MARK: View
        CommandGroup(before: .toolbar) {
            ForEach(ProjectSession.InspectorTab.allCases) { tab in
                let availability = session?.inspectorTabAvailability(tab)
                Button(tab.tooltipTitle, systemImage: tab.systemImage) {
                    guard let session else { return }
                    session.clearTimelineSelection()
                    session.selectedInspectorTab = tab
                }
                .modifier(OptionalShortcut(badge: tab.shortcutBadge))
                .disabled(availability?.canApply != true)
            }

            Divider()

            Toggle(isOn: $preferences.showAudioWaveform) { Label("Show audio waveform", systemImage: "waveform") }
            Toggle(isOn: $preferences.smoothWaveform) { Label("Smooth waveform", systemImage: "waveform.path") }
                .disabled(!preferences.showAudioWaveform)

            Divider()

            Toggle(isOn: $preferences.loopPlayback) { Label("Loop playback", systemImage: "repeat") }
            Toggle(isOn: $preferences.alwaysShowTimelineScrollbar) { Label("Always show timeline scrollbar", systemImage: "chevron.up.chevron.down") }
            Toggle(isOn: $preferences.showEditorSidebar) { Label("Show editor sidebar", systemImage: "sidebar.right") }
            Toggle(isOn: $preferences.showEditorTimeline) { Label("Show editor timeline", systemImage: "rectangle.bottomthird.inset.filled") }

            Divider()

            Toggle(isOn: Binding(
                get: { recorder.isHUDVisible },
                set: { _ in recorder.toggleRecordingHUD() }
            )) {
                Label("Show recording widget", systemImage: "record.circle")
            }
            .keyboardShortcut("'", modifiers: [.command, .option])
            .disabled(recorder.isRecording)
        }

        // MARK: Window
        CommandGroup(after: .windowArrangement) {
            Divider()
            Button("Reset windows positions", systemImage: "macwindow") { workspace.resetWindowPositions() }
        }
    }

    /// Sends a standard edit action to the focused text field, if there is one. Returns `false` when no text input is
    /// focused, so the caller applies the action to the timeline instead.
    private static func sendToTextResponder(_ action: Selector) -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder, responder is NSText else { return false }
        return NSApp.sendAction(action, to: nil, from: nil)
    }
}

/// SwiftUI appends `CommandMenu`s after `View`. This puts the top-level menus in editing-workflow order
/// (`File, Edit, Record, Export, View, Window, Help`) and re-applies it whenever SwiftUI rebuilds the menu bar.
@MainActor
enum MainMenuOrder {
    private static let order = ["File", "Edit", "Record", "Export", "View", "Window", "Help"]
    private static var isApplying = false
    private static var observer: NSObjectProtocol?

    private static var trackingObserver: NSObjectProtocol?

    static func install() {
        apply()
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { note in
            guard let menu = note.object as? NSMenu, menu === NSApp.mainMenu else { return }
            MainActor.assumeIsolated { apply() }
        }
        // macOS 27 hides menu item images unless the item opts in, and SwiftUI has no modifier for it. Opt every
        // item that has an icon in right before the menu bar opens (SwiftUI may have rebuilt items since last time).
        trackingObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            guard let menu = note.object as? NSMenu, menu === NSApp.mainMenu else { return }
            MainActor.assumeIsolated { showAppItemImages(in: menu) }
        }
    }

    /// Only the app's own menus: the application menu, `Help` and the system `Window` items keep AppKit's default.
    private static func showAppItemImages(in mainMenu: NSMenu) {
        for top in mainMenu.items.dropFirst() {
            guard let submenu = top.submenu, top.title != "Help" else { continue }
            if top.title == "Window" {
                showItemImages(in: submenu) { $0.title == "Reset windows positions" }
            } else {
                showItemImages(in: submenu) { _ in true }
            }
        }
    }

    private static func showItemImages(in menu: NSMenu, where include: (NSMenuItem) -> Bool) {
        guard #available(macOS 27.0, *) else { return }
        for item in menu.items {
            if item.image != nil && include(item) && item.preferredImageVisibility != .visible {
                item.preferredImageVisibility = .visible
            }
            if let submenu = item.submenu {
                showItemImages(in: submenu, where: include)
            }
        }
    }

    static func apply() {
        guard !isApplying, let mainMenu = NSApp.mainMenu, mainMenu.items.count > 1 else { return }
        showAppItemImages(in: mainMenu)
        // The editor has no split-view sidebar, but AppKit still adds a dead `Toggle Sidebar` item to `Help`.
        if let help = mainMenu.items.first(where: { $0.title == "Help" })?.submenu,
           let toggleSidebar = help.items.first(where: { $0.action == #selector(NSSplitViewController.toggleSidebar(_:)) }) {
            help.removeItem(toggleSidebar)
        }
        let ordered = order.compactMap { title in mainMenu.items.first(where: { $0.title == title }) }
        // Index 0 is the application menu; everything we know about follows it in `order`.
        let current = Array(mainMenu.items.dropFirst().filter { ordered.contains($0) })
        guard current != ordered else { return }
        isApplying = true
        defer { isApplying = false }
        for (offset, item) in ordered.enumerated() {
            mainMenu.removeItem(item)
            mainMenu.insertItem(item, at: min(1 + offset, mainMenu.items.count))
        }
    }
}

/// Turns an inspector tab badge like `"⌘ 3"` into a menu key equivalent.
private struct OptionalShortcut: ViewModifier {
    let badge: String?

    func body(content: Content) -> some View {
        if let key = badge?.split(separator: " ").last?.first {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: [.command])
        } else {
            content
        }
    }
}
