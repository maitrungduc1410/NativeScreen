import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Full Native macOS Editor Window for a single `.nativescreen` project session.
/// Features a unified dark titlebar (no default gray system titlebar), centered in-place editable
/// `ProjectName.nativescreen` title (bright name + dimmed `.nativescreen` suffix), instant tooltips,
/// and keyboard shortcuts.
public struct ProjectEditorWindowView: View {
    @Bindable var session: ProjectSession

    @State private var isEditingProjectName = false
    @State private var draftProjectName = ""
    @State private var isHoveringTitle = false
    @FocusState private var isTitleFieldFocused: Bool

    @State private var isShowingExportSheet = false
    @State private var exportCodec: HardwareVideoExporter.ExportCodec = .h264
    @State private var exportResolution: HardwareVideoExporter.ExportResolution = .qhd2k
    @State private var isExporting = false
    @State private var exportProgress: Double = 0.0
    @State private var exportError: String?
    @State private var keyEventMonitor: Any?

    public init(session: ProjectSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 1. UNIFIED DARK WINDOW HEADER BAR (Replaces macOS default titlebar; traffic lights sit on the left)
            ZStack {
                // Left Controls (Placed after macOS traffic lights 🔴 🟡 🟢)
                HStack(spacing: 6) {
                    InstantTooltipButton(
                        tooltip: "Reveal project in Finder",
                        edge: .bottom,
                        size: 28,
                        cornerRadius: 7
                    ) {
                        NSWorkspace.shared.activateFileViewerSelecting([session.packageURL])
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                    }

                    InstantTooltipButton(
                        tooltip: "Move project to Trash",
                        edge: .bottom,
                        size: 28,
                        cornerRadius: 7
                    ) {
                        moveProjectToTrash()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                    }

                    Spacer()
                }
                .padding(.leading, 78)

                // Center: In-Place Editable Project Title (`Name` bright + `.nativescreen` dimmed)
                HStack(spacing: 0) {
                    if isEditingProjectName {
                        HStack(spacing: 2) {
                            TextField("Project name", text: $draftProjectName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: true, vertical: false)
                                .focused($isTitleFieldFocused)
                                .onSubmit {
                                    commitProjectRename()
                                }

                            Text(".nativescreen")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(0.10))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color(red: 0.48, green: 0.38, blue: 0.98), lineWidth: 1.2)
                        )
                    } else {
                        Button {
                            draftProjectName = session.document.name
                            isEditingProjectName = true
                            isTitleFieldFocused = true
                        } label: {
                            HStack(spacing: 1) {
                                Text(session.document.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.95))

                                Text(".nativescreen")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.35))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(isHoveringTitle ? Color.white.opacity(0.08) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            withAnimation(.easeOut(duration: 0.12)) {
                                isHoveringTitle = hovering
                            }
                        }
                    }
                }

                // Right Controls: Undo, Redo & Export
                HStack(spacing: 8) {
                    Spacer()

                    HStack(spacing: 4) {
                        InstantTooltipButton(
                            tooltip: "Undo (⌘Z)",
                            edge: .bottom,
                            size: 28,
                            cornerRadius: 7
                        ) {
                            session.undo()
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(session.canUndo ? 0.85 : 0.25))
                        }
                        .disabled(!session.canUndo)
                        .keyboardShortcut("z", modifiers: [.command])

                        InstantTooltipButton(
                            tooltip: "Redo (⇧⌘Z)",
                            edge: .bottom,
                            size: 28,
                            cornerRadius: 7
                        ) {
                            session.redo()
                        } label: {
                            Image(systemName: "arrow.uturn.forward")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(session.canRedo ? 0.85 : 0.25))
                        }
                        .disabled(!session.canRedo)
                        .keyboardShortcut("Z", modifiers: [.command, .shift])
                    }

                    Button {
                        isShowingExportSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Export")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .fixedSize()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.44, green: 0.34, blue: 0.98),
                                    Color(red: 0.36, green: 0.26, blue: 0.88)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("e", modifiers: [.command])
                }
                .padding(.trailing, 14)
            }
            .frame(height: 44)
            .background(Color(red: 0.05, green: 0.05, blue: 0.07))
            .zIndex(80)

            Divider()

            // 2. CENTER WORKSPACE: Preview Canvas + Floating Left Quick Dock + Right Inspector Sidebar
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    // Top Sub-Toolbar Right Above Preview Canvas (layout: Aspect Ratio + Preview Quality)
                    HStack(spacing: 16) {
                        Menu {
                            Button("Auto (Match Source)") {
                                session.mutate { $0.canvas.aspectRatioMode = .auto }
                            }
                            Divider()
                            ForEach(AspectRatioPreset.allCases) { preset in
                                Button(preset.label) {
                                    session.mutate {
                                        $0.canvas.aspectRatioMode = .preset
                                        $0.canvas.aspectRatioPreset = preset
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.75))
                                Text(session.document.canvas.aspectRatioMode == .auto
                                     ? "Auto Aspect"
                                     : session.document.canvas.aspectRatioPreset.label)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.88))
                                    .lineLimit(1)
                            }
                            .fixedSize()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()

                        HStack(spacing: 5) {
                            Image(systemName: "dial.high")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text("Preview quality")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text("Full")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity)
                    .background(Color(red: 0.03, green: 0.03, blue: 0.04))

                    GeometryReader { geo in
                        let aspect = session.document.canvas.effectiveAspectRatio(
                            sourceWidth: Double(session.metadata.captureTarget.pixelSize.width),
                            sourceHeight: Double(session.metadata.captureTarget.pixelSize.height)
                        )
                        let fittedSize = fitPreviewCanvas(in: geo.size, aspect: aspect)

                        ZStack {
                            Color(red: 0.03, green: 0.03, blue: 0.04)

                            // GPU Preview + Clean Source-Locked Mask Handle Overlay
                            ZStack {
                                MetalPreviewView(session: session)
                                InteractiveMaskCanvasOverlayView(session: session, canvasSize: fittedSize)
                            }
                            .frame(width: fittedSize.width, height: fittedSize.height)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.55), radius: 20, y: 8)

                            // Floating Left Quick Dock (Instant Tooltip + Smooth Highlight)
                            HStack {
                                VStack(spacing: 8) {
                                    quickDockIconButton(
                                        icon: "plus.magnifyingglass",
                                        tooltip: "Zoom"
                                    ) {
                                        session.addZoomAtPlayhead()
                                    }

                                    quickDockIconButton(
                                        icon: "sparkle.magnifyingglass",
                                        tooltip: "Auto-cluster zooms"
                                    ) {
                                        session.regenerateAutoZooms()
                                    }

                                    quickDockIconButton(
                                        icon: "eye.slash",
                                        tooltip: "Sensitive data mask"
                                    ) {
                                        session.addMaskAtPlayhead(type: .blur, style: .gaussian)
                                    }

                                    quickDockIconButton(
                                        icon: "viewfinder.rectangular",
                                        tooltip: "Spotlight mask"
                                    ) {
                                        session.addMaskAtPlayhead(type: .spotlight, style: .dim)
                                    }
                                }
                                .padding(7)
                                .background(
                                    Color(red: 0.11, green: 0.11, blue: 0.14).opacity(0.94),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                                )
                                .padding(.leading, 14)
                                .zIndex(60)

                                Spacer()
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    // Transport Playback Bar
                    HStack(spacing: 18) {
                        Text(formatTimecode(session.effectivePreviewTimelineMs))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Button {
                            session.isPlaying = false
                            session.seek(toTimelineMs: 0.0)
                        } label: {
                            Image(systemName: "backward.end")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .buttonStyle(.plain)

                        Button {
                            session.isPlaying.toggle()
                        } label: {
                            Image(systemName: session.isPlaying ? "pause.circle" : "play.circle")
                                .font(.system(size: 24, weight: .regular))
                                .foregroundStyle(.white.opacity(0.92))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.space, modifiers: [])

                        Button {
                            session.isPlaying = false
                            session.seek(toTimelineMs: session.timeMapper.totalTimelineDurationMs)
                        } label: {
                            Image(systemName: "forward.end")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .buttonStyle(.plain)

                        Text(formatTimecode(session.timeMapper.totalTimelineDurationMs))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary.opacity(0.7))
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color(red: 0.03, green: 0.03, blue: 0.04))
                }

                Divider()

                InspectorSidebarView(session: session)
            }

            Divider()

            // 3. BOTTOM MULTI-TRACK NLE TIMELINE
            MultiTrackTimelineView(session: session)
                .frame(height: 235)
        }
        .background(WindowTitlebarCleaner())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isShowingExportSheet) {
            exportModalSheet
        }
        .onChange(of: isTitleFieldFocused) { _, focused in
            if !focused && isEditingProjectName {
                commitProjectRename()
            }
        }
        .onAppear {
            installEditorKeyMonitor()
        }
        .onDisappear {
            removeEditorKeyMonitor()
        }
    }

    private func commitProjectRename() {
        isEditingProjectName = false
        session.renameProject(to: draftProjectName)
    }

    private func moveProjectToTrash() {
        try? FileManager.default.trashItem(at: session.packageURL, resultingItemURL: nil)
        NSApp.keyWindow?.close()
    }

    // MARK: - Keyboard Shortcuts (`Delete`/`Backspace`, `ESC`)

    private func installEditorKeyMonitor() {
        removeEditorKeyMonitor()
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let responder = event.window?.firstResponder, responder is NSTextView {
                if event.keyCode == 53 { // ESC while editing title
                    isEditingProjectName = false
                    return nil
                }
                return event
            }
            switch event.keyCode {
            case 53: // ESC: Exit Split Mode or clear selection
                if session.isSplitModeActive {
                    session.isSplitModeActive = false
                    NSCursor.arrow.set()
                    return nil
                }
                if session.selectedMaskId != nil || session.selectedZoomId != nil {
                    session.selectedMaskId = nil
                    session.selectedZoomId = nil
                    return nil
                }
                return event

            case 51, 117: // Delete / Forward Delete
                session.deleteSelectedTimelineItem()
                return nil

            default:
                return event
            }
        }
    }

    private func removeEditorKeyMonitor() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }

    @ViewBuilder
    private func quickDockIconButton(icon: String, tooltip: String, action: @escaping () -> Void) -> some View {
        InstantTooltipButton(
            tooltip: tooltip,
            edge: .trailing,
            size: 32,
            cornerRadius: 9,
            action: action
        ) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.90))
        }
    }

    // MARK: - Hardware Export Sheet

    private var exportModalSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Video (Hardware Accelerated)")
                .font(.title3.bold())

            Form {
                Picker("Codec", selection: $exportCodec) {
                    ForEach(HardwareVideoExporter.ExportCodec.allCases) { c in
                        Text(c.rawValue).tag(c)
                    }
                }
                Picker("Resolution", selection: $exportResolution) {
                    ForEach(HardwareVideoExporter.ExportResolution.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
            }

            if isExporting {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: exportProgress)
                    Text("Rendering via Metal + VideoToolbox: \(Int(exportProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let err = exportError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isShowingExportSheet = false
                }
                .disabled(isExporting)

                Button("Export MP4…") {
                    runHardwareExport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExporting)
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private func runHardwareExport() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.mpeg4Movie]
        savePanel.nameFieldStringValue = "\(session.document.name).mp4"

        guard savePanel.runModal() == .OK, let outURL = savePanel.url else { return }

        isExporting = true
        exportProgress = 0.0
        exportError = nil

        Task {
            do {
                try await HardwareVideoExporter.exportProject(
                    session: session,
                    outputURL: outURL,
                    codec: exportCodec,
                    resolution: exportResolution,
                    fps: 60
                ) { progress in
                    self.exportProgress = progress
                }
                isExporting = false
                isShowingExportSheet = false
                NSWorkspace.shared.activateFileViewerSelecting([outURL])
            } catch {
                isExporting = false
                exportError = error.localizedDescription
            }
        }
    }

    private func fitPreviewCanvas(in container: CGSize, aspect: Double) -> CGSize {
        let availW = max(160, container.width - 96)
        let availH = max(120, container.height - 24)
        var w = availW
        var h = w / max(0.2, aspect)
        if h > availH {
            h = availH
            w = h * max(0.2, aspect)
        }
        return CGSize(width: w, height: h)
    }

    private func formatTimecode(_ ms: Double) -> String {
        let totalSec = max(0.0, ms / 1000.0)
        let mins = Int(totalSec) / 60
        let secs = Int(totalSec) % 60
        let hundredths = Int((totalSec - floor(totalSec)) * 100)
        return String(format: "%02d:%02d.%02d", mins, secs, hundredths)
    }
}

/// Configures the hosting `NSWindow` to hide the default system title text and merge the titlebar seamlessly into our dark header.
private struct WindowTitlebarCleaner: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                window.backgroundColor = NSColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
            }
        }
    }
}
