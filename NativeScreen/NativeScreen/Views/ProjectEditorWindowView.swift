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
    @State private var isHoveringPreviewCanvas = false
    @State private var titleBarFrameInWindow: CGRect = .zero
    @State private var trafficLightCenterY: CGFloat = 26.0
    @State private var trafficLightRightEdgeX: CGFloat = 82.0
    @State private var cropModalSourceImage: NSImage?
    @FocusState private var isTitleFieldFocused: Bool

    @State private var isShowingExportSheet = false
    @State private var exportCodec: HardwareVideoExporter.ExportCodec = .h264
    @State private var exportResolution: HardwareVideoExporter.ExportResolution = .qhd2k
    @State private var isExporting = false
    @State private var exportProgress: Double = 0.0
    @State private var exportError: String?
    @State private var keyEventMonitor: Any?
    @State private var mouseDownMonitor: Any?

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
                .padding(.leading, trafficLightRightEdgeX + 10)

                // Center: In-Place Editable Project Title (`Name` bright + `.nativescreen` dimmed)
                HStack(spacing: 0) {
                    if isEditingProjectName {
                        HStack(spacing: 2) {
                            TextField("Project name", text: $draftProjectName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .regular))
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
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white.opacity(0.10))
                                    .onAppear {
                                        titleBarFrameInWindow = proxy.frame(in: .global)
                                    }
                                    .onChange(of: proxy.frame(in: .global)) { _, newFrame in
                                        titleBarFrameInWindow = newFrame
                                    }
                            }
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color(red: 0.48, green: 0.38, blue: 0.98), lineWidth: 1.2)
                        )
                    } else {
                        Button {
                            draftProjectName = session.document.name
                            isEditingProjectName = true
                            DispatchQueue.main.async {
                                isTitleFieldFocused = true
                            }
                        } label: {
                            HStack(spacing: 1) {
                                Text(session.document.name)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.95))

                                Text(".nativescreen")
                                    .font(.system(size: 13, weight: .regular))
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
            .frame(height: max(50, trafficLightCenterY * 2.0))
            .background(Color(red: 0.05, green: 0.05, blue: 0.07))
            .zIndex(80)

            Divider()

            // 2. CENTER WORKSPACE: Preview Canvas + Floating Left Quick Dock + Right Inspector Sidebar
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    // Top Sub-Toolbar Right Above Preview Canvas (Consistent Liquid Glass Popovers + Generous Hover Hitboxes)
                    HStack(spacing: 10) {
                        // 1. Output Aspect Ratio Pill Button (With Icon + Bright Name + Dimmed Ratio + Native NSMenu Liquid Glass Menu)
                        SubToolbarPillButton(
                            tooltip: "Output aspect ratio",
                            edge: .top,
                            isActive: false
                        ) {
                            NativeSegmentContextMenuPresenter.shared.presentAspectRatioMenu(session: session, below: nil)
                        } label: {
                            HStack(spacing: 7) {
                                AspectIconView()

                                if session.document.canvas.aspectRatioMode == .auto {
                                    Text("Auto")
                                        .font(.system(size: 12.5, weight: .regular))
                                        .foregroundStyle(.white.opacity(0.92))
                                } else {
                                    HStack(spacing: 4) {
                                        Text(session.document.canvas.aspectRatioPreset.titleName)
                                            .font(.system(size: 12.5, weight: .regular))
                                            .foregroundStyle(.white.opacity(0.95))

                                        Text(session.document.canvas.aspectRatioPreset.ratioString)
                                            .font(.system(size: 12.5, weight: .regular))
                                            .foregroundStyle(.white.opacity(0.45))
                                    }
                                }

                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.50))
                            }
                            .fixedSize()
                        }

                        // 2. Crop Pill Button (Opens Standalone Movable Crop Window tied to this Project Session)
                        let hasCustomCrop = (session.document.canvas.cropRect01 != .full)
                        SubToolbarPillButton(
                            tooltip: "Crop recording",
                            edge: .top,
                            isActive: hasCustomCrop
                        ) {
                            ProjectWorkspaceStore.shared.presentCropWindow(for: session)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "crop")
                                    .font(.system(size: 12.5, weight: .regular))
                                    .foregroundStyle(hasCustomCrop ? Color(red: 0.58, green: 0.52, blue: 1.0) : .white.opacity(0.88))

                                Text("Crop")
                                    .font(.system(size: 12.5, weight: .regular))
                                    .foregroundStyle(hasCustomCrop ? Color(red: 0.58, green: 0.52, blue: 1.0) : .white.opacity(0.88))
                            }
                            .fixedSize()
                        }

                        // 3. Reel Mode Pill Button (Glowing Purple Highlight when active + Native NSMenu Liquid Glass Menu)
                        SubToolbarPillButton(
                            tooltip: "Reel mode overlay",
                            edge: .top,
                            isActive: session.isReelModeActive
                        ) {
                            NativeSegmentContextMenuPresenter.shared.presentReelModeMenu(session: session)
                        } label: {
                            HStack(spacing: 6) {
                                ReelPhoneIconView(isActive: session.isReelModeActive)

                                Text("Reel mode")
                                    .font(.system(size: 12.5, weight: .regular))
                                    .foregroundStyle(
                                        session.isReelModeActive
                                            ? Color(red: 0.58, green: 0.52, blue: 1.0)
                                            : .white.opacity(0.88)
                                    )
                            }
                            .fixedSize()
                        }

                        // 4. Export Still Frame Pill Button (Opens CapCut-style "Export still frames" modal)
                        SubToolbarPillButton(
                            tooltip: "Export still frame",
                            edge: .top,
                            isActive: false
                        ) {
                            session.openStillFrameExportModal()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "camera.viewfinder")
                                    .font(.system(size: 12.5, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.88))

                                Text("Export frame")
                                    .font(.system(size: 12.5, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.88))
                            }
                            .fixedSize()
                        }
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity)
                    .background(Color(red: 0.03, green: 0.03, blue: 0.04))
                    .zIndex(75)

                    GeometryReader { geo in
                        let targetAspect = session.document.canvas.effectiveAspectRatio(
                            sourceWidth: Double(session.metadata.captureTarget.pixelSize.width),
                            sourceHeight: Double(session.metadata.captureTarget.pixelSize.height)
                        )

                        ZStack {
                            Color(red: 0.03, green: 0.03, blue: 0.04)

                            AnimatableAspectCanvasContainer(
                                session: session,
                                containerSize: geo.size,
                                aspect: targetAspect,
                                isHoveringPreviewCanvas: $isHoveringPreviewCanvas
                            )
                            .animation(.spring(response: 0.30, dampingFraction: 0.86), value: targetAspect)

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

                    // Unified Transport Playback & Timeline Bar (layout:
                    // Left = Split Tool `✂️` | Center = Timecodes + Jump Start / Play / Jump End with Top Tooltips | Right = Extract Frame + Timeline Zoom Slider)
                    ZStack {
                        // Left: Split Tool Button (`✂️` only — delete button removed as requested)
                        HStack(spacing: 8) {
                            InstantTooltipButton(
                                tooltip: session.isSplitModeActive ? "Exit Split Tool (ESC)" : "Split clip, zoom, or mask",
                                edge: .top,
                                isActive: session.isSplitModeActive,
                                size: 32,
                                cornerRadius: 8
                            ) {
                                session.isSplitModeActive.toggle()
                            } label: {
                                Image(systemName: "scissors")
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(session.isSplitModeActive ? .white : .white.opacity(0.80))
                            }

                            Spacer()
                        }
                        .padding(.leading, 14)

                        // Center: Timecode + 3 Transport Buttons with Hover Highlight & Top Tooltips
                        HStack(spacing: 16) {
                            Text(formatTimecode(session.effectivePreviewTimelineMs))
                                .font(.system(size: 12.5, weight: .regular, design: .default).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 64, alignment: .trailing)

                            InstantTooltipButton(
                                tooltip: "Jump to start",
                                edge: .top,
                                size: 32,
                                cornerRadius: 8
                            ) {
                                session.isPlaying = false
                                session.seek(toTimelineMs: 0.0)
                            } label: {
                                Image(systemName: "backward.end")
                                    .font(.system(size: 13.5, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.85))
                            }

                            InstantTooltipButton(
                                tooltip: session.isPlaying ? "Pause (Space)" : "Play (Space)",
                                edge: .top,
                                size: 36,
                                cornerRadius: 9
                            ) {
                                session.togglePlayPause()
                            } label: {
                                Image(systemName: session.isPlaying ? "pause.circle" : "play.circle")
                                    .font(.system(size: 26, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.95))
                            }
                            .keyboardShortcut(.space, modifiers: [])

                            InstantTooltipButton(
                                tooltip: "Jump to end",
                                edge: .top,
                                size: 32,
                                cornerRadius: 8
                            ) {
                                session.isPlaying = false
                                session.seek(toTimelineMs: session.timeMapper.totalTimelineDurationMs)
                            } label: {
                                Image(systemName: "forward.end")
                                    .font(.system(size: 13.5, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.85))
                            }

                            Text(formatTimecode(session.timeMapper.totalTimelineDurationMs))
                                .font(.system(size: 12.5, weight: .regular, design: .default).monospacedDigit())
                                .foregroundStyle(.secondary.opacity(0.75))
                                .frame(width: 64, alignment: .leading)
                        }

                        // Right: Playback Speed (`1x`) + Timeline Zoom Slider
                        HStack(spacing: 10) {
                            Spacer()

                            // Playback Speed Button (`1x` — Opens Native Liquid Glass NSMenu on click)
                            InstantTooltipButton(
                                tooltip: "Playback speed",
                                edge: .top,
                                isActive: abs(session.previewPlaybackRate - 1.0) > 0.01,
                                size: 34,
                                cornerRadius: 8
                            ) {
                                NativeSegmentContextMenuPresenter.shared.presentPlaybackSpeedMenu(session: session)
                            } label: {
                                Text(String(format: "%gx", session.previewPlaybackRate))
                                    .font(.system(size: 12.5, weight: .regular).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.92))
                            }

                            Slider(value: $session.timelineZoom, in: 1.0...6.0)
                                .tint(kNativeScreenPurpleAccent)
                                .frame(width: 96)
                                .controlSize(.small)
                        }
                        .padding(.trailing, 14)
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color(red: 0.03, green: 0.03, blue: 0.04))
                    .zIndex(70)
                }
                .zIndex(1)

                Divider()
                    .zIndex(2)

                InspectorSidebarView(session: session)
                    .zIndex(90)
            }

            Divider()

            // 3. BOTTOM MULTI-TRACK NLE TIMELINE
            MultiTrackTimelineView(session: session)
                .frame(height: 255)
        }
        .background(
            WindowTitlebarCleaner { centerY, rightX in
                if abs(centerY - trafficLightCenterY) > 0.5 {
                    trafficLightCenterY = centerY
                }
                if abs(rightX - trafficLightRightEdgeX) > 0.5 {
                    trafficLightRightEdgeX = rightX
                }
            }
        )
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isShowingExportSheet) {
            exportModalSheet
        }
        .sheet(isPresented: $session.isShowingStillFrameExportModal) {
            ExportStillFrameModalView(session: session) {
                session.isShowingStillFrameExportModal = false
            }
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
        guard isEditingProjectName else { return }
        isEditingProjectName = false
        isTitleFieldFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
        session.renameProject(to: draftProjectName)
    }

    private func moveProjectToTrash() {
        try? FileManager.default.trashItem(at: session.packageURL, resultingItemURL: nil)
        NSApp.keyWindow?.close()
    }

    // MARK: - Keyboard Shortcuts (`Delete`/`Backspace`, `ESC`) & Outside Click Title Commit

    private func installEditorKeyMonitor() {
        removeEditorKeyMonitor()

        // Commit in-place filename edit immediately when clicking anywhere outside the title box!
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            if isEditingProjectName, let win = event.window, let contentView = win.contentView {
                // Convert NSEvent window point (bottom-left origin) to SwiftUI top-left global coordinate
                let ptInWindow = event.locationInWindow
                let topBasedPoint = CGPoint(x: ptInWindow.x, y: contentView.bounds.height - ptInWindow.y)
                if !titleBarFrameInWindow.insetBy(dx: -8, dy: -8).contains(topBasedPoint) {
                    commitProjectRename()
                }
            }
            return event
        }

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let responder = event.window?.firstResponder, responder is NSTextView {
                if event.keyCode == 53 { // ESC while editing title
                    isEditingProjectName = false
                    isTitleFieldFocused = false
                    event.window?.makeFirstResponder(nil)
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

            case 8: // 'C' key: Split at current time (or Copy with ⌘C)
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags.contains(.command) {
                    if let mId = session.selectedMaskId {
                        session.copyMaskToClipboard(id: mId)
                        return nil
                    }
                    if let zId = session.selectedZoomId {
                        session.copyZoomToClipboard(id: zId)
                        return nil
                    }
                } else if flags.isEmpty {
                    session.splitAtCurrentTimeShortcut()
                    return nil
                }
                return event

            case 2: // 'D' key: Disable selected (or Duplicate with ⌘D)
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags.contains(.command) {
                    if let zId = session.selectedZoomId {
                        session.duplicateZoom(id: zId)
                        return nil
                    }
                } else if flags.isEmpty {
                    session.toggleDisableSelectedShortcut()
                    return nil
                }
                return event

            case 7: // 'X' key with ⌘X: Cut to clipboard
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags.contains(.command) {
                    if let mId = session.selectedMaskId {
                        session.cutMaskToClipboard(id: mId)
                        return nil
                    }
                    if let zId = session.selectedZoomId {
                        session.cutZoomToClipboard(id: zId)
                        return nil
                    }
                }
                return event

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
        if let mMonitor = mouseDownMonitor {
            NSEvent.removeMonitor(mMonitor)
            mouseDownMonitor = nil
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
        DockProgressIndicatingController.shared.setProgress(0.0)

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
                    DockProgressIndicatingController.shared.setProgress(progress)
                }
                DockProgressIndicatingController.shared.setProgress(nil)
                isExporting = false
                isShowingExportSheet = false
                NSWorkspace.shared.activateFileViewerSelecting([outURL])
            } catch {
                DockProgressIndicatingController.shared.setProgress(nil)
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

/// Animatable container that smoothly interpolates the preview canvas frame (`aspect`) at 120Hz using a spring animation
/// whenever the user switches Aspect Ratio presets (e.g. `16:9` <-> `9:16` <-> `1:1`)!
private struct AnimatableAspectCanvasContainer: View, Animatable {
    @Bindable var session: ProjectSession
    let containerSize: CGSize
    var aspect: Double
    @Binding var isHoveringPreviewCanvas: Bool

    nonisolated var animatableData: Double {
        get { aspect }
        set { aspect = newValue }
    }

    var body: some View {
        let fittedSize = fitCanvas(in: containerSize, aspect: aspect)

        ZStack {
            MetalPreviewView(session: session, canvasAspect: aspect)
            InteractiveMaskCanvasOverlayView(session: session, canvasSize: fittedSize)

            ReelModeSafeZoneOverlayView(session: session, canvasSize: fittedSize)
                .opacity(session.isReelModeActive ? 1.0 : 0.0)
                .scaleEffect(session.isReelModeActive ? 1.0 : 0.985)
                .animation(.easeInOut(duration: 0.22), value: session.isReelModeActive)

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(isHoveringPreviewCanvas ? 0.035 : 0.0))
                .allowsHitTesting(false)
        }
        .frame(width: fittedSize.width, height: fittedSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(isHoveringPreviewCanvas ? 0.28 : 0.08),
                    lineWidth: isHoveringPreviewCanvas ? 1.5 : 1.0
                )
        )
        .shadow(color: .black.opacity(0.55), radius: 20, y: 8)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHoveringPreviewCanvas = hovering
            }
        }
    }

    private func fitCanvas(in container: CGSize, aspect: Double) -> CGSize {
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
}

/// Configures the hosting `NSWindow` to hide the default system title text, merge the titlebar seamlessly into our dark header,
/// and report the exact pixel vertical center (`centerYFromTop`) and right edge (`rightEdgeX`) of the native `🔴 🟡 🟢` traffic lights.
private struct WindowTitlebarCleaner: NSViewRepresentable {
    var onMetricsChanged: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TrafficLightMeasuringView()
        view.onMetricsChanged = onMetricsChanged
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? TrafficLightMeasuringView {
            view.onMetricsChanged = onMetricsChanged
            view.configureWindowAndMeasure()
        }
    }

    private final class TrafficLightMeasuringView: NSView {
        var onMetricsChanged: ((CGFloat, CGFloat) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindowAndMeasure()
        }

        func configureWindowAndMeasure() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let window = self.window else { return }
                if let closeBtn = window.standardWindowButton(.closeButton),
                   let zoomBtn = window.standardWindowButton(.zoomButton) {
                    let closeCenterInWin = closeBtn.convert(
                        CGPoint(x: closeBtn.bounds.midX, y: closeBtn.bounds.midY),
                        to: nil
                    )
                    let zoomRightInWin = zoomBtn.convert(
                        CGPoint(x: zoomBtn.bounds.maxX, y: zoomBtn.bounds.midY),
                        to: nil
                    )
                    let centerYFromTop = max(20.0, min(32.0, window.frame.height - closeCenterInWin.y))
                    let rightX = max(68.0, min(104.0, zoomRightInWin.x))
                    self.onMetricsChanged?(centerYFromTop, rightX)
                }
            }
        }
    }
}
