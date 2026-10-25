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
    @State private var isShowingCommandMenu = false
    @State private var exportCodec: HardwareVideoExporter.ExportCodec = .h264
    @State private var exportResolution: HardwareVideoExporter.ExportResolution = .qhd2k
    @State private var isExporting = false
    @State private var exportProgress: Double = 0.0
    @State private var exportError: String?
    @State private var keyEventMonitor: Any?
    @State private var flagsChangedMonitor: Any?
    @State private var mouseDownMonitor: Any?
    @State private var isOptionKeyHeldForSplit = false

    public init(session: ProjectSession) {
        self.session = session
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // 1. UNIFIED DARK WINDOW HEADER BAR (Matches Header 1:1 & 2!)
                ZStack {
                    // Left Controls (Placed after macOS traffic lights 🔴 🟡 🟢 — Larger 34pt buttons & 16pt icons!)
                    HStack(spacing: 6) {
                        InstantTooltipButton(
                            tooltip: "Show project in Finder",
                            shortcutBadge: "⇧ ⌘ O",
                            edge: .bottom,
                            size: 34,
                            cornerRadius: 8
                        ) {
                            NSWorkspace.shared.activateFileViewerSelecting([session.packageURL])
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 15.5, weight: .regular))
                                .foregroundStyle(.white.opacity(0.82))
                        }

                        InstantTooltipButton(
                            tooltip: "Remove project",
                            edge: .bottom,
                            size: 34,
                            cornerRadius: 8
                        ) {
                            moveProjectToTrash()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 15.0, weight: .regular))
                                .foregroundStyle(.white.opacity(0.75))
                        }

                        Spacer()
                    }
                    .padding(.leading, trafficLightRightEdgeX + 12)

                    // Center: In-Place Editable Project Title (`Name` bright + `.nativescreen` dimmed)
                    HStack(spacing: 0) {
                        if isEditingProjectName {
                            HStack(spacing: 2) {
                                TextField("Project name", text: $draftProjectName)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(.white)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .focused($isTitleFieldFocused)
                                    .onSubmit {
                                        commitProjectRename()
                                    }

                                Text(".nativescreen")
                                    .font(.system(size: 13.5, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.38))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
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
                                HStack(spacing: 2) {
                                    Text(session.document.name)
                                        .font(.system(size: 13.5, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.95))

                                    Text(".nativescreen")
                                        .font(.system(size: 13.5, weight: .regular))
                                        .foregroundStyle(.white.opacity(0.38))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
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

                    // Right Controls: Command Menu (`⌘`) | Undo & Redo | Export ( & 2!)
                    HStack(spacing: 10) {
                        Spacer()

                        // 1. Command Menu Button (`command.circle` — "Show command menu... ⌘ K")
                        InstantTooltipButton(
                            tooltip: "Show command menu...",
                            shortcutBadge: "⌘ K",
                            edge: .bottom,
                            isActive: isShowingCommandMenu,
                            size: 34,
                            cornerRadius: 8
                        ) {
                            withAnimation(.easeOut(duration: 0.14)) {
                                isShowingCommandMenu.toggle()
                            }
                        } label: {
                            Image(systemName: "command.circle")
                                .font(.system(size: 16.5, weight: .regular))
                                .foregroundStyle(.white.opacity(0.88))
                        }

                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 1, height: 18)

                        // 2. Undo & Redo Buttons (Larger 34pt hitbox & 15.5pt icons)
                        HStack(spacing: 4) {
                            InstantTooltipButton(
                                tooltip: "Undo",
                                shortcutBadge: "⌘ Z",
                                edge: .bottom,
                                isDisabled: !session.canUndo,
                                size: 34,
                                cornerRadius: 8
                            ) {
                                session.undo()
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 15.0, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.90))
                            }
                            .keyboardShortcut("z", modifiers: [.command])

                            InstantTooltipButton(
                                tooltip: "Redo",
                                shortcutBadge: "⇧ ⌘ Z",
                                edge: .bottom,
                                isDisabled: !session.canRedo,
                                size: 34,
                                cornerRadius: 8
                            ) {
                                session.redo()
                            } label: {
                                Image(systemName: "arrow.uturn.forward")
                                    .font(.system(size: 15.0, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.90))
                            }
                            .keyboardShortcut("Z", modifiers: [.command, .shift])
                        }

                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 1, height: 18)

                        // 3. Prominent Purple Export Button (`height: 34`, `#4D2FF5`)
                        Button {
                            isShowingExportSheet = true
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "square.and.arrow.up.fill")
                                    .font(.system(size: 13.0, weight: .semibold))
                                Text("Export")
                                    .font(.system(size: 13.5, weight: .semibold))
                            }
                            .fixedSize()
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                            .background(
                                Color(red: 0.302, green: 0.184, blue: 0.961),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut("e", modifiers: [.command])
                    }
                    .padding(.trailing, 14)
                }
                .frame(height: max(52, trafficLightCenterY * 2.0))
                .background(Color(red: 0.05, green: 0.05, blue: 0.07))
                .zIndex(80)

            Divider()

            // 2. CENTER WORKSPACE: Preview Canvas + Floating Left Quick Dock + Right Inspector Sidebar
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    // Top Sub-Toolbar Right Above Preview Canvas (Consistent Liquid Glass Popovers + Generous Hover Hitboxes)
                    let isVerticalAspectRatio = (session.document.canvas.aspectRatioMode == .preset)
                        && [.vertical9x16, .tall3x4, .portrait4x5].contains(session.document.canvas.aspectRatioPreset)

                    HStack(spacing: 10) {
                        // 1. Output Aspect Ratio Pill Button (With Icon + Bright Name + Dimmed Ratio + Native NSMenu Liquid Glass Menu)
                        SubToolbarPillButton(
                            tooltip: "Output aspect ratio",
                            edge: .top,
                            isActive: false,
                            onActionWithAnchorView: { anchorView in
                                NativeSegmentContextMenuPresenter.shared.presentAspectRatioMenu(session: session, below: anchorView)
                            }
                        ) {
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
                            isActive: hasCustomCrop,
                            action: {
                                ProjectWorkspaceStore.shared.presentCropWindow(for: session)
                            }
                        ) {
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

                        // 3. Reel Mode Pill Button (Shown ONLY for vertical aspect ratios `9:16`, `3:4`, `4:5` with smooth animation, no tooltip)
                        if isVerticalAspectRatio {
                            SubToolbarPillButton(
                                tooltip: nil,
                                edge: .top,
                                isActive: session.isReelModeActive,
                                onActionWithAnchorView: { anchorView in
                                    NativeSegmentContextMenuPresenter.shared.presentReelModeMenu(session: session, below: anchorView)
                                }
                            ) {
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
                            .transition(.opacity.combined(with: .scale(scale: 0.90)))
                        }

                        // 4. Export Still Frame Pill Button (No tooltip since it has explicit text)
                        SubToolbarPillButton(
                            tooltip: nil,
                            edge: .top,
                            isActive: false,
                            action: {
                                session.openStillFrameExportModal()
                            }
                        ) {
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
                    .animation(.spring(response: 0.28, dampingFraction: 0.85), value: isVerticalAspectRatio)
                    .onChange(of: isVerticalAspectRatio) { _, isVertical in
                        if !isVertical && session.isReelModeActive {
                            withAnimation(.easeInOut(duration: 0.20)) {
                                session.isReelModeActive = false
                            }
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
                                        tooltip: "Classic zoom"
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
                        // Left: Split Tool Button (`✂️` — Dual activation: Click to toggle OR Hold Option `⌥` key!)
                        HStack(spacing: 8) {
                            InstantTooltipButton(
                                tooltip: "Split clip (⌥)",
                                edge: .top,
                                isActive: session.isSplitModeActive,
                                size: 32,
                                cornerRadius: 8
                            ) {
                                isOptionKeyHeldForSplit = false
                                session.isSplitModeActive.toggle()
                                if !session.isSplitModeActive {
                                    NSCursor.arrow.set()
                                }
                            } label: {
                                Image(systemName: "scissors")
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(
                                        session.isSplitModeActive
                                            ? Color(red: 0.65, green: 0.55, blue: 1.0)
                                            : .white.opacity(0.85)
                                    )
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

            // 4. COMMAND MENU OVERLAY
            if isShowingCommandMenu {
                CommandMenuOverlayView(
                    session: session,
                    onRequestExportVideo: {
                        isShowingCommandMenu = false
                        isShowingExportSheet = true
                    },
                    onRequestDeleteProject: {
                        isShowingCommandMenu = false
                        moveProjectToTrash()
                    },
                    onClose: {
                        withAnimation(.easeOut(duration: 0.14)) {
                            isShowingCommandMenu = false
                        }
                    }
                )
                .zIndex(500)
                .transition(.opacity)
            }
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

        // Hold `Option` (`⌥`) key to temporarily enable Split Mode (`Split clip (⌥)`), and turn it off immediately on release!
        flagsChangedMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            if let responder = event.window?.firstResponder, responder is NSTextView {
                return event
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isOnlyOptionPressed = (flags == .option)

            if isOnlyOptionPressed {
                if !session.isSplitModeActive {
                    isOptionKeyHeldForSplit = true
                    session.isSplitModeActive = true
                }
            } else {
                if isOptionKeyHeldForSplit {
                    isOptionKeyHeldForSplit = false
                    session.isSplitModeActive = false
                    NSCursor.arrow.set()
                }
            }
            return event
        }

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // `⌘K` toggles the Command Menu from anywhere (even when the search field inside Command Menu is focused!)
            if event.keyCode == 40 && flags == .command {
                withAnimation(.easeOut(duration: 0.14)) {
                    isShowingCommandMenu.toggle()
                }
                return nil
            }

            if isShowingCommandMenu {
                if event.keyCode == 53 { // ESC closes Command Menu
                    withAnimation(.easeOut(duration: 0.14)) {
                        isShowingCommandMenu = false
                    }
                    return nil
                }
                return event
            }

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
                    isOptionKeyHeldForSplit = false
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

            case 123: // Left Arrow (`←`, `⇧ ←`, `⌘ ←`)
                if flags == .command {
                    session.isPlaying = false
                    session.seek(toTimelineMs: 0.0)
                    return nil
                } else if flags == .shift {
                    session.seek(toTimelineMs: session.effectivePreviewTimelineMs - 2000.0)
                    return nil
                } else if flags.isEmpty {
                    let delta = session.isPlaying ? -1000.0 : -(1000.0 / 60.0)
                    session.seek(toTimelineMs: session.effectivePreviewTimelineMs + delta)
                    return nil
                }
                return event

            case 124: // Right Arrow (`→`, `⇧ →`, `⌘ →`)
                if flags == .command {
                    session.isPlaying = false
                    session.seek(toTimelineMs: session.timeMapper.totalTimelineDurationMs)
                    return nil
                } else if flags == .shift {
                    session.seek(toTimelineMs: session.effectivePreviewTimelineMs + 1000.0)
                    return nil
                } else if flags.isEmpty {
                    let delta = session.isPlaying ? 500.0 : (1000.0 / 60.0)
                    session.seek(toTimelineMs: session.effectivePreviewTimelineMs + delta)
                    return nil
                }
                return event

            case 24: // `=` / `+` (`⌘ =` Zoom in timeline)
                if flags.contains(.command) {
                    session.timelineZoom = min(6.0, session.timelineZoom * 1.25)
                    return nil
                }
                return event

            case 27: // `-` (`⌘ -` Zoom out timeline)
                if flags.contains(.command) {
                    session.timelineZoom = max(1.0, session.timelineZoom / 1.25)
                    return nil
                }
                return event

            case 31: // `O` (`⇧ ⌘ O` Show project in Finder)
                if flags == [.command, .shift] {
                    NSWorkspace.shared.activateFileViewerSelecting([session.packageURL])
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
        if let fMonitor = flagsChangedMonitor {
            NSEvent.removeMonitor(fMonitor)
            flagsChangedMonitor = nil
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
            PreviewShortcutKeycapsOverlayView(session: session, canvasSize: fittedSize)

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

// MARK: - Interactive 3D Keycap Overlay on Video Preview

private struct PreviewShortcutKeycapsOverlayView: View {
    @Bindable var session: ProjectSession
    let canvasSize: CGSize

    @State private var isHoveringKeycaps = false

    var body: some View {
        let sourceMs = session.currentSourceTimeMs
        let activeCluster = session.activeShortcutCluster(atSourceMs: sourceMs)
        let keyHeight = max(34.0, canvasSize.height * CGFloat(session.document.captions.shortcutsSizeRatio))
        let spacing = keyHeight * 0.10
        let bottomPadding = max(16.0, canvasSize.height * 0.05)

        ZStack(alignment: .bottom) {
            Color.clear

            if let cluster = activeCluster {
                HStack(spacing: spacing) {
                    ForEach(cluster.keyCaps) { cap in
                        NativeScreen3DKeycapView(
                            cap: cap,
                            keyHeight: keyHeight,
                            isHovered: isHoveringKeycaps
                        )
                    }
                }
                .padding(.bottom, bottomPadding)
                .scaleEffect(isHoveringKeycaps ? 1.02 : 1.0)
                .brightness(isHoveringKeycaps ? 0.08 : 0.0)
                .shadow(color: .black.opacity(0.42), radius: keyHeight * 0.22, y: keyHeight * 0.10)
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.14)) {
                        isHoveringKeycaps = hovering
                    }
                }
                .onTapGesture {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                        session.selectedInspectorTab = .shortcuts
                    }
                }
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -keyHeight * 0.08)).combined(with: .scale(scale: 0.96)),
                        removal: .opacity.combined(with: .scale(scale: 0.96))
                    )
                )
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .bottom)
        .animation(.spring(response: 0.24, dampingFraction: 0.84), value: activeCluster?.id)
    }
}

private struct NativeScreen3DKeycapView: View {
    let cap: ProjectSession.ShortcutKeyCap
    let keyHeight: CGFloat
    let isHovered: Bool

    var body: some View {
        let keyWidth = keyHeight * CGFloat(cap.widthRatio)
        let outerRadius = keyHeight * 0.125 // `qg / Gg = 32 / 256 = 0.125`
        let borderThickness = max(1.2, keyHeight * (3.0 / 256.0))
        let innerRadius = max(2.0, outerRadius - borderThickness)
        let innerPad = (keyHeight - borderThickness * 2.0) * 0.125

        ZStack {
            // 1. Outer 3D Bevel Border Gradient (`#656565` top -> `#191919` bottom)
            RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.396, green: 0.396, blue: 0.396).opacity(isHovered ? 1.0 : 0.92),
                            Color(red: 0.098, green: 0.098, blue: 0.098)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // 2. Inner Keycap Body Gradient (`#2B2B2B` top -> `#191919` bottom)
            RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            isHovered
                                ? Color(red: 0.22, green: 0.22, blue: 0.24)
                                : Color(red: 0.169, green: 0.169, blue: 0.169),
                            isHovered
                                ? Color(red: 0.13, green: 0.13, blue: 0.15)
                                : Color(red: 0.098, green: 0.098, blue: 0.098)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .padding(borderThickness)

            // 3. Keycap Symbol & Label Typography
            Group {
                switch cap.labelPlacement {
                case .center:
                    Text(cap.label)
                        .font(.system(size: keyHeight * 0.33, weight: .regular))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, innerPad)

                case .bottomLeft:
                    VStack(alignment: .leading, spacing: 0) {
                        if let sym = cap.symbol, !sym.isEmpty {
                            Text(sym)
                                .font(.system(size: keyHeight * 0.31, weight: .regular))
                                .foregroundStyle(.white)
                        }
                        Spacer(minLength: 0)
                        if !cap.label.isEmpty {
                            Text(cap.label)
                                .font(.system(size: keyHeight * 0.215, weight: .medium))
                                .foregroundStyle(.white.opacity(0.96))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(borderThickness + innerPad)

                case .bottomCenter:
                    VStack(alignment: .center, spacing: 0) {
                        if let sym = cap.symbol, !sym.isEmpty {
                            Text(sym)
                                .font(.system(size: keyHeight * 0.31, weight: .regular))
                                .foregroundStyle(.white)
                        }
                        Spacer(minLength: 0)
                        if !cap.label.isEmpty {
                            Text(cap.label)
                                .font(.system(size: keyHeight * 0.215, weight: .medium))
                                .foregroundStyle(.white.opacity(0.96))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(borderThickness + innerPad)
                }
            }
        }
        .frame(width: keyWidth, height: keyHeight)
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

// MARK: - Command Menu

private struct EditorCommandItem: Identifiable {
    let id: String
    let group: String
    let title: String
    let icon: String
    let shortcutBadge: String?
    let isDestructive: Bool
    let action: @MainActor () -> Void

    init(
        id: String,
        group: String,
        title: String,
        icon: String,
        shortcutBadge: String? = nil,
        isDestructive: Bool = false,
        action: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.group = group
        self.title = title
        self.icon = icon
        self.shortcutBadge = shortcutBadge
        self.isDestructive = isDestructive
        self.action = action
    }
}

private struct CommandMenuOverlayView: View {
    @Bindable var session: ProjectSession
    let onRequestExportVideo: () -> Void
    let onRequestDeleteProject: () -> Void
    let onClose: () -> Void

    @State private var searchText: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var isSearchFocused: Bool

    private var allCommands: [EditorCommandItem] {
        var items: [EditorCommandItem] = []

        // 1. Playback
        items.append(EditorCommandItem(
            id: "togglePlay",
            group: "Playback",
            title: session.isPlaying ? "Pause" : "Play",
            icon: session.isPlaying ? "pause.circle" : "play.circle",
            shortcutBadge: "Space"
        ) {
            session.togglePlayPause()
        })

        items.append(EditorCommandItem(
            id: "goToFirstFrame",
            group: "Playback",
            title: "Go to first frame",
            icon: "backward.end",
            shortcutBadge: "⌘ ←"
        ) {
            session.isPlaying = false
            session.seek(toTimelineMs: 0.0)
        })

        items.append(EditorCommandItem(
            id: "goToLastFrame",
            group: "Playback",
            title: "Go to last frame",
            icon: "forward.end",
            shortcutBadge: "⌘ →"
        ) {
            session.isPlaying = false
            session.seek(toTimelineMs: session.timeMapper.totalTimelineDurationMs)
        })

        items.append(EditorCommandItem(
            id: "moveBackwards",
            group: "Playback",
            title: "Move backwards",
            icon: "arrow.turn.up.left",
            shortcutBadge: "←"
        ) {
            let delta = session.isPlaying ? -1000.0 : -(1000.0 / 60.0)
            session.seek(toTimelineMs: session.effectivePreviewTimelineMs + delta)
        })

        items.append(EditorCommandItem(
            id: "moveBackwardsFast",
            group: "Playback",
            title: "Move backwards fast",
            icon: "arrow.turn.up.left",
            shortcutBadge: "⇧ ←"
        ) {
            session.seek(toTimelineMs: session.effectivePreviewTimelineMs - 2000.0)
        })

        items.append(EditorCommandItem(
            id: "moveForwards",
            group: "Playback",
            title: "Move forwards",
            icon: "arrow.turn.up.right",
            shortcutBadge: "→"
        ) {
            let delta = session.isPlaying ? 500.0 : (1000.0 / 60.0)
            session.seek(toTimelineMs: session.effectivePreviewTimelineMs + delta)
        })

        items.append(EditorCommandItem(
            id: "moveForwardsFast",
            group: "Playback",
            title: "Move forwards fast",
            icon: "arrow.turn.up.right",
            shortcutBadge: "⇧ →"
        ) {
            session.seek(toTimelineMs: session.effectivePreviewTimelineMs + 1000.0)
        })

        items.append(EditorCommandItem(
            id: "zoomInTimeline",
            group: "Playback",
            title: "Zoom in timeline",
            icon: "plus.magnifyingglass",
            shortcutBadge: "⌘ ="
        ) {
            session.timelineZoom = min(6.0, session.timelineZoom * 1.25)
        })

        items.append(EditorCommandItem(
            id: "zoomOutTimeline",
            group: "Playback",
            title: "Zoom out timeline",
            icon: "minus.magnifyingglass",
            shortcutBadge: "⌘ -"
        ) {
            session.timelineZoom = max(1.0, session.timelineZoom / 1.25)
        })

        // 2. Editor
        if session.canUndo {
            items.append(EditorCommandItem(
                id: "projectUndo",
                group: "Editor",
                title: "Undo",
                icon: "arrow.uturn.backward",
                shortcutBadge: "⌘ Z"
            ) {
                session.undo()
            })
        }

        if session.canRedo {
            items.append(EditorCommandItem(
                id: "projectRedo",
                group: "Editor",
                title: "Redo",
                icon: "arrow.uturn.forward",
                shortcutBadge: "⇧ ⌘ Z"
            ) {
                session.redo()
            })
        }

        items.append(EditorCommandItem(
            id: "toggleSplit",
            group: "Editor",
            title: "Toggle split",
            icon: "scissors",
            shortcutBadge: "⌥"
        ) {
            session.isSplitModeActive.toggle()
        })

        items.append(EditorCommandItem(
            id: "splitAtCurrentTime",
            group: "Editor",
            title: "Split at current time",
            icon: "scissors",
            shortcutBadge: "C"
        ) {
            session.splitAtCurrentTimeShortcut()
        })

        items.append(EditorCommandItem(
            id: "openCropWindow",
            group: "Editor",
            title: "Crop",
            icon: "crop"
        ) {
            ProjectWorkspaceStore.shared.presentCropWindow(for: session)
        })

        // 3. Zoom
        items.append(EditorCommandItem(
            id: "addZoom",
            group: "Zoom",
            title: "Add zoom at current time",
            icon: "plus.magnifyingglass"
        ) {
            session.addZoomAtPlayhead()
        })

        if let zoomId = session.selectedZoomId,
           let zoom = session.document.timeline.zooms.first(where: { $0.id == zoomId }) {
            items.append(EditorCommandItem(
                id: "duplicateZoom",
                group: "Zoom",
                title: "Duplicate zoom",
                icon: "plus",
                shortcutBadge: "⌘ D"
            ) {
                session.duplicateZoom(id: zoomId)
            })

            items.append(EditorCommandItem(
                id: "toggleZoomLoupeMode",
                group: "Zoom",
                title: "Toggle zoom loupe mode",
                icon: "sparkle.magnifyingglass",
                shortcutBadge: "L"
            ) {
                session.setZoomPresentation(id: zoomId, presentation: zoom.presentation == .loupe ? .screen : .loupe)
            })

            items.append(EditorCommandItem(
                id: "setZoomToAuto",
                group: "Zoom",
                title: "Set zoom type to Auto",
                icon: "computermouse",
                shortcutBadge: "A"
            ) {
                session.mutate { doc in
                    if let idx = doc.timeline.zooms.firstIndex(where: { $0.id == zoomId }) {
                        doc.timeline.zooms[idx].mode = .followCursor
                    }
                }
            })

            items.append(EditorCommandItem(
                id: "setZoomToManual",
                group: "Zoom",
                title: "Set zoom type to Manual",
                icon: "hand.tap",
                shortcutBadge: "M"
            ) {
                session.mutate { doc in
                    if let idx = doc.timeline.zooms.firstIndex(where: { $0.id == zoomId }) {
                        doc.timeline.zooms[idx].mode = .manual
                    }
                }
            })

            items.append(EditorCommandItem(
                id: "applyZoomToAll",
                group: "Zoom",
                title: "Apply zoom level to all other zooms",
                icon: "plus.square"
            ) {
                session.applyZoomLevelToAllOtherZooms(fromId: zoomId)
            })

            items.append(EditorCommandItem(
                id: "toggleDisabledZoom",
                group: "Zoom",
                title: zoom.disabled ? "Enable zoom" : "Disable zoom",
                icon: "slash.circle",
                shortcutBadge: "D"
            ) {
                session.toggleZoomDisabled(id: zoomId)
            })

            items.append(EditorCommandItem(
                id: "removeZoom",
                group: "Zoom",
                title: "Remove zoom",
                icon: "trash",
                shortcutBadge: "⌫",
                isDestructive: true
            ) {
                session.deleteZoom(zoomId: zoomId)
            })
        }

        if session.document.timeline.zooms.contains(where: { !$0.disabled }) {
            items.append(EditorCommandItem(
                id: "disableAllZoomRanges",
                group: "Zoom",
                title: "Disable all zoom ranges",
                icon: "slash.circle"
            ) {
                session.mutate { doc in
                    for idx in doc.timeline.zooms.indices {
                        doc.timeline.zooms[idx].disabled = true
                    }
                }
            })
        }

        if session.document.timeline.zooms.contains(where: { $0.disabled }) {
            items.append(EditorCommandItem(
                id: "enableAllZoomRanges",
                group: "Zoom",
                title: "Enable all zoom ranges",
                icon: "checkmark.circle"
            ) {
                session.mutate { doc in
                    for idx in doc.timeline.zooms.indices {
                        doc.timeline.zooms[idx].disabled = false
                    }
                }
            })
        }

        items.append(EditorCommandItem(
            id: "restoreDefaultZoomRanges",
            group: "Zoom",
            title: "Restore default zoom ranges",
            icon: "arrow.clockwise"
        ) {
            session.regenerateAutoZooms()
        })

        if !session.document.timeline.zooms.isEmpty {
            items.append(EditorCommandItem(
                id: "removeAllZoomRanges",
                group: "Zoom",
                title: "Remove all zoom ranges",
                icon: "trash",
                isDestructive: true
            ) {
                session.mutate { $0.timeline.zooms.removeAll() }
            })
        }

        // 4. Masks
        items.append(EditorCommandItem(
            id: "addSensitiveDataMask",
            group: "Masks",
            title: "Add sensitive data mask",
            icon: "eye.slash"
        ) {
            session.addMaskAtPlayhead(type: .blur, style: .gaussian)
        })

        items.append(EditorCommandItem(
            id: "addHighlightMask",
            group: "Masks",
            title: "Add highlight mask",
            icon: "viewfinder.rectangular"
        ) {
            session.addMaskAtPlayhead(type: .spotlight, style: .dim)
        })

        if let maskId = session.selectedMaskId {
            items.append(EditorCommandItem(
                id: "changeMaskTypeToHighlight",
                group: "Masks",
                title: "Change mask type to highlight",
                icon: "viewfinder.rectangular"
            ) {
                session.setMaskType(id: maskId, type: .spotlight)
            })

            items.append(EditorCommandItem(
                id: "changeMaskTypeToSensitiveData",
                group: "Masks",
                title: "Change mask type to sensitive data",
                icon: "eye.slash"
            ) {
                session.setMaskType(id: maskId, type: .blur)
            })

            items.append(EditorCommandItem(
                id: "toggleMaskDisabled",
                group: "Masks",
                title: "Toggle disable mask",
                icon: "slash.circle",
                shortcutBadge: "D"
            ) {
                session.toggleMaskDisabled(id: maskId)
            })

            items.append(EditorCommandItem(
                id: "removeMask",
                group: "Masks",
                title: "Remove mask",
                icon: "trash",
                shortcutBadge: "⌫",
                isDestructive: true
            ) {
                session.deleteMask(maskId: maskId)
            })
        }

        if !session.document.timeline.maskTracks.isEmpty {
            items.append(EditorCommandItem(
                id: "disableAllMasks",
                group: "Masks",
                title: "Disable all masks",
                icon: "slash.circle"
            ) {
                session.mutate { doc in
                    for tIdx in doc.timeline.maskTracks.indices {
                        for mIdx in doc.timeline.maskTracks[tIdx].items.indices {
                            doc.timeline.maskTracks[tIdx].items[mIdx].disabled = true
                        }
                    }
                }
            })

            items.append(EditorCommandItem(
                id: "removeAllMasks",
                group: "Masks",
                title: "Remove all masks",
                icon: "trash",
                isDestructive: true
            ) {
                session.mutate { $0.timeline.maskTracks.removeAll() }
            })
        }

        // 5. Slice
        if let slice = session.currentActiveSlice {
            items.append(EditorCommandItem(
                id: "toggleSliceHideCursor",
                group: "Slice",
                title: "Hide mouse cursor for slice",
                icon: "eye.slash"
            ) {
                session.toggleSliceHideCursor(id: slice.id)
            })

            items.append(EditorCommandItem(
                id: "toggleSliceDisableSmoothMouseMovement",
                group: "Slice",
                title: "Disable smooth mouse movement for slice",
                icon: "slash.circle"
            ) {
                session.toggleSliceDisableSmoothCursor(id: slice.id)
            })

            items.append(EditorCommandItem(
                id: "resetSliceTrim",
                group: "Slice",
                title: "Reset trim",
                icon: "arrow.counterclockwise"
            ) {
                session.resetSliceTrim(id: slice.id)
            })
        }

        if session.document.timeline.slices.count > 1 {
            items.append(EditorCommandItem(
                id: "resetAllSlices",
                group: "Slice",
                title: "Reset trims and cuts for all slices",
                icon: "arrow.counterclockwise.circle",
                isDestructive: true
            ) {
                session.resetAllSlicesTrimAndCuts()
            })
        }

        if !session.activeTypingSuggestions.isEmpty {
            items.append(EditorCommandItem(
                id: "applyAllTypingSuggestions",
                group: "Slice",
                title: "Speed up all typing sections (3×)",
                icon: "keyboard"
            ) {
                session.applyAllTypingSuggestions(speed: 3.0)
            })
        }

        // 6. Shortcuts
        items.append(EditorCommandItem(
            id: "toggleShowShortcuts",
            group: "Shortcuts",
            title: session.document.captions.showKeystrokes ? "Hide keyboard shortcuts" : "Show keyboard shortcuts",
            icon: "command"
        ) {
            session.mutate { $0.captions.showKeystrokes.toggle() }
        })

        items.append(EditorCommandItem(
            id: "toggleShowSingleKeyShortcuts",
            group: "Shortcuts",
            title: session.document.captions.showSingleKeyShortcuts ? "Disable single key shortcuts" : "Enable single key shortcuts",
            icon: "character"
        ) {
            session.mutate { $0.captions.showSingleKeyShortcuts.toggle() }
        })

        // 7. Export & Project
        items.append(EditorCommandItem(
            id: "exportVideo",
            group: "Export",
            title: "Export video...",
            icon: "square.and.arrow.up",
            shortcutBadge: "⌘ E"
        ) {
            onRequestExportVideo()
        })

        items.append(EditorCommandItem(
            id: "exportCurrentFrameAsImage",
            group: "Export",
            title: "Export current frame as image...",
            icon: "camera.viewfinder"
        ) {
            session.openStillFrameExportModal()
        })

        items.append(EditorCommandItem(
            id: "showProjectInFinder",
            group: "Project",
            title: "Show project in Finder",
            icon: "folder",
            shortcutBadge: "⇧ ⌘ O"
        ) {
            NSWorkspace.shared.activateFileViewerSelecting([session.packageURL])
        })

        items.append(EditorCommandItem(
            id: "deleteProject",
            group: "Project",
            title: "Remove project",
            icon: "trash",
            isDestructive: true
        ) {
            onRequestDeleteProject()
        })

        return items
    }

    private var filteredCommands: [EditorCommandItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return allCommands }
        return allCommands.filter {
            $0.title.lowercased().contains(query) || $0.group.lowercased().contains(query)
        }
    }

    private var groupedFilteredCommands: [(group: String, items: [(globalIndex: Int, item: EditorCommandItem)])] {
        var result: [(group: String, items: [(globalIndex: Int, item: EditorCommandItem)])] = []
        for (idx, cmd) in filteredCommands.enumerated() {
            if let lastIdx = result.indices.last, result[lastIdx].group == cmd.group {
                result[lastIdx].items.append((idx, cmd))
            } else {
                result.append((group: cmd.group, items: [(idx, cmd)]))
            }
        }
        return result
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Dimmed Backdrop (`#08090D` at 0.82 opacity — click outside to dismiss)
            Color(red: 0.03, green: 0.035, blue: 0.05).opacity(0.82)
                .ignoresSafeArea()
                .onTapGesture {
                    onClose()
                }

            // Command Menu Modal Card (`max-width: 640px, max-height: 420px, background: #1E1E1EEE, border: 1px solid #FFFFFF2E`)
            VStack(spacing: 0) {
                // 1. Search Input Bar (`height: 60px, padding: 20px`)
                HStack(spacing: 10) {
                    TextField("Type to find a command", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Color(red: 0.89, green: 0.90, blue: 0.91))
                        .tint(Color(red: 0.44, green: 0.34, blue: 0.98))
                        .focused($isSearchFocused)
                        .onKeyPress(.downArrow) {
                            let count = filteredCommands.count
                            if count > 0 {
                                selectedIndex = (selectedIndex + 1) % count
                            }
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            let count = filteredCommands.count
                            if count > 0 {
                                selectedIndex = (selectedIndex - 1 + count) % count
                            }
                            return .handled
                        }
                        .onKeyPress(.return) {
                            executeSelectedCommand()
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            onClose()
                            return .handled
                        }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.42))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .frame(height: 60)

                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 1)

                // 2. Scrollable Grouped Command List (`max-height: 360px`)
                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        if filteredCommands.isEmpty {
                            Text("No matching commands")
                                .font(.system(size: 13.5, weight: .regular))
                                .foregroundStyle(.white.opacity(0.45))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 36)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(groupedFilteredCommands.enumerated()), id: \.element.group) { groupIdx, section in
                                    if groupIdx > 0 {
                                        Rectangle()
                                            .fill(Color.white.opacity(0.08))
                                            .frame(height: 1)
                                            .padding(.vertical, 4)
                                    }

                                    Text(section.group)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.45))
                                        .padding(.horizontal, 20)
                                        .padding(.top, groupIdx == 0 ? 6 : 2)
                                        .padding(.bottom, 2)

                                    ForEach(section.items, id: \.item.id) { entry in
                                        let isHighlighted = (entry.globalIndex == selectedIndex)

                                        CommandMenuRowView(
                                            item: entry.item,
                                            isHighlighted: isHighlighted,
                                            onHover: {
                                                selectedIndex = entry.globalIndex
                                            },
                                            onSelect: {
                                                selectedIndex = entry.globalIndex
                                                executeSelectedCommand()
                                            }
                                        )
                                        .id(entry.globalIndex)
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 6)
                        }
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selectedIndex) { _, newIdx in
                        withAnimation(.easeOut(duration: 0.10)) {
                            scrollProxy.scrollTo(newIdx, anchor: .center)
                        }
                    }
                }
            }
            .frame(width: 616)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.118, green: 0.118, blue: 0.125).opacity(0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.65), radius: 28, y: 12)
            .padding(.top, 140)
        }
        .onAppear {
            selectedIndex = 0
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
        .onChange(of: searchText) { _, _ in
            selectedIndex = 0
        }
    }

    private func executeSelectedCommand() {
        let list = filteredCommands
        guard selectedIndex >= 0 && selectedIndex < list.count else { return }
        let chosen = list[selectedIndex]
        onClose()
        chosen.action()
    }
}

private struct CommandMenuRowView: View {
    let item: EditorCommandItem
    let isHighlighted: Bool
    let onHover: () -> Void
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(
                        item.isDestructive
                            ? Color(red: 1.0, green: 0.35, blue: 0.32)
                            : .white.opacity(0.88)
                    )
                    .frame(width: 20, alignment: .center)

                Text(item.title)
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(
                        item.isDestructive
                            ? Color(red: 1.0, green: 0.35, blue: 0.32)
                            : .white.opacity(0.95)
                    )
                    .lineLimit(1)

                Spacer(minLength: 12)

                if let badge = item.shortcutBadge, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8)
                        )
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHighlighted ? Color.white.opacity(0.09) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                onHover()
            }
        }
    }
}
