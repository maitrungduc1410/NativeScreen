import SwiftUI
import AppKit
import Combine
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
    @State private var isShowingPresetsPopover = false
    @State private var exportConfig = HardwareVideoExporter.ExportConfiguration()
    @State private var isExporting = false
    @State private var exportProgress: Double = 0.0
    @State private var exportStartedAtMs: Double = 0.0
    @State private var exportMeasurementStart: (progress01: Double, atMs: Double)?
    @State private var exportLatestSample: (progress01: Double, atMs: Double)?
    @State private var activeExportDestinationLabel: String = ""
    @State private var activeExportTask: Task<Void, Never>?
    @State private var exportError: String?
    @State private var keyEventMonitor: Any?
    @State private var flagsChangedMonitor: Any?
    @State private var mouseDownMonitor: Any?
    @State private var isOptionKeyHeldForSplit = false

    public init(session: ProjectSession) {
        self.session = session
    }

    private var isModalOverlayActive: Bool {
        isShowingCommandMenu || isShowingExportSheet || isExporting || session.isShowingStillFrameExportModal || session.isShowingCameraCropModal
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // 1. UNIFIED DARK WINDOW HEADER BAR (Matches Header & 2!)
                let centerY = max(24.0, trafficLightCenterY)
                ZStack {
                    // Left Controls (Placed after macOS traffic lights 🔴 🟡 🟢 — 36pt buttons, 6pt radius & 16pt icons!)
                    HStack(spacing: 4) {
                        InstantTooltipButton(
                            tooltip: "Show project in Finder",
                            shortcutBadge: "⇧ ⌘ O",
                            edge: .bottom,
                            size: 36,
                            cornerRadius: 6
                        ) {
                            NSWorkspace.shared.activateFileViewerSelecting([session.packageURL])
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 15.5, weight: .regular))
                                .foregroundStyle(.ink.opacity(0.85))
                        }

                        InstantTooltipButton(
                            tooltip: "Remove project",
                            edge: .bottom,
                            size: 36,
                            cornerRadius: 6
                        ) {
                            moveProjectToTrash()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 15.0, weight: .regular))
                                .foregroundStyle(.ink.opacity(0.78))
                        }

                        Spacer()
                    }
                    .padding(.leading, trafficLightRightEdgeX + 12)
                    .frame(height: 36)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, max(6.0, centerY - 18.0))

                    // Center: In-Place Editable Project Title (`Name` bright + `.nativescreen` dimmed)
                    HStack(spacing: 0) {
                        if isEditingProjectName {
                            HStack(spacing: 2) {
                                TextField("Project name", text: $draftProjectName)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(.ink)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .focused($isTitleFieldFocused)
                                    .onSubmit {
                                        commitProjectRename()
                                    }

                                Text(".nativescreen")
                                    .font(.system(size: 13.5, weight: .regular))
                                    .foregroundStyle(.ink.opacity(0.38))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                GeometryReader { proxy in
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color.ink.opacity(0.10))
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
                                        .foregroundStyle(.ink.opacity(0.95))

                                    Text(".nativescreen")
                                        .font(.system(size: 13.5, weight: .regular))
                                        .foregroundStyle(.ink.opacity(0.38))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(isHoveringTitle ? Color.ink.opacity(0.08) : Color.clear)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                withAnimation(.easeOut(duration: 0.12)) {
                                    isHoveringTitle = hovering
                                }
                            }
                        }
                    }
                    .frame(height: 36)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, max(6.0, centerY - 18.0))

                    // Right Controls: Command Menu (`⌘`) | Undo & Redo | Presets | Export ( & 2!)
                    HStack(spacing: 10) {
                        Spacer()

                        // 1. Command Menu Button (`command.circle` — "Show command menu... ⌘ K")
                        InstantTooltipButton(
                            tooltip: "Show command menu...",
                            shortcutBadge: "⌘ K",
                            edge: .bottom,
                            isActive: isShowingCommandMenu,
                            size: 36,
                            cornerRadius: 6
                        ) {
                            withAnimation(.easeOut(duration: 0.14)) {
                                isShowingCommandMenu.toggle()
                            }
                        } label: {
                            Image(systemName: "command.circle")
                                .font(.system(size: 16.5, weight: .regular))
                                .foregroundStyle(.ink.opacity(0.88))
                        }

                        Rectangle()
                            .fill(Color.ink.opacity(0.12))
                            .frame(width: 1, height: 18)

                        // 2. Undo & Redo Buttons (36pt hitbox, 6pt radius & 15.5pt icons)
                        HStack(spacing: 2) {
                            InstantTooltipButton(
                                tooltip: "Undo",
                                shortcutBadge: "⌘ Z",
                                edge: .bottom,
                                isDisabled: !session.canUndo,
                                size: 36,
                                cornerRadius: 6
                            ) {
                                session.undo()
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 15.0, weight: .medium))
                                    .foregroundStyle(.ink.opacity(0.90))
                            }
                            .keyboardShortcut("z", modifiers: [.command])

                            InstantTooltipButton(
                                tooltip: "Redo",
                                shortcutBadge: "⇧ ⌘ Z",
                                edge: .bottom,
                                isDisabled: !session.canRedo,
                                size: 36,
                                cornerRadius: 6
                            ) {
                                session.redo()
                            } label: {
                                Image(systemName: "arrow.uturn.forward")
                                    .font(.system(size: 15.0, weight: .medium))
                                    .foregroundStyle(.ink.opacity(0.90))
                            }
                            .keyboardShortcut("Z", modifiers: [.command, .shift])
                        }

                        Rectangle()
                            .fill(Color.ink.opacity(0.12))
                            .frame(width: 1, height: 18)

                        // 2B. Presets Button
                        SubToolbarPillButton(
                            tooltip: nil,
                            edge: .bottom,
                            isActive: isShowingPresetsPopover,
                            height: 36,
                            horizontalPadding: 12,
                            cornerRadius: 6,
                            action: {
                                isShowingPresetsPopover.toggle()
                            }
                        ) {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 13.0, weight: .medium))
                                    .foregroundStyle(.ink.opacity(0.90))
                                Text("Presets")
                                    .font(.system(size: 13.0, weight: .regular))
                                    .foregroundStyle(.ink.opacity(0.92))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10.0, weight: .medium))
                                    .foregroundStyle(.ink.opacity(0.55))
                            }
                            .fixedSize()
                        }
                        .popover(isPresented: $isShowingPresetsPopover, arrowEdge: .bottom) {
                            PresetsPopoverView(session: session)
                        }

                        Rectangle()
                            .fill(Color.ink.opacity(0.12))
                            .frame(width: 1, height: 18)

                        // 3. Prominent Purple Export Button (`height: 36`, `radius: 6`, `#4D2FF5`)
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
                            .frame(height: 36)
                            .background(
                                Color(red: 0.302, green: 0.184, blue: 0.961),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                            .foregroundStyle(.white)
                            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut("e", modifiers: [.command])
                    }
                    .padding(.trailing, 14)
                    .frame(height: 36)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, max(6.0, centerY - 18.0))
                }
                .frame(height: max(52.0, centerY + 26.0))
                .background(Color.surface(red: 0.05, green: 0.05, blue: 0.07))
                .background(
                    HeaderDoubleClickZoomView()
                )
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
                                        .foregroundStyle(.ink.opacity(0.92))
                                } else {
                                    HStack(spacing: 4) {
                                        Text(session.document.canvas.aspectRatioPreset.titleName)
                                            .font(.system(size: 12.5, weight: .regular))
                                            .foregroundStyle(.ink.opacity(0.95))

                                        Text(session.document.canvas.aspectRatioPreset.ratioString)
                                            .font(.system(size: 12.5, weight: .regular))
                                            .foregroundStyle(.ink.opacity(0.45))
                                    }
                                }

                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.ink.opacity(0.50))
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
                                    .foregroundStyle(hasCustomCrop ? Color(red: 0.58, green: 0.52, blue: 1.0) : .ink.opacity(0.88))

                                Text("Crop")
                                    .font(.system(size: 12.5, weight: .regular))
                                    .foregroundStyle(hasCustomCrop ? Color(red: 0.58, green: 0.52, blue: 1.0) : .ink.opacity(0.88))
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
                                                : .ink.opacity(0.88)
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
                                    .foregroundStyle(.ink.opacity(0.88))

                                Text("Export frame")
                                    .font(.system(size: 12.5, weight: .regular))
                                    .foregroundStyle(.ink.opacity(0.88))
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
                    .background(Color.surface(red: 0.03, green: 0.03, blue: 0.04))
                    .zIndex(75)

                    GeometryReader { geo in
                        let targetAspect = session.document.canvas.effectiveAspectRatio(
                            sourceWidth: Double(session.metadata.captureTarget.pixelSize.width),
                            sourceHeight: Double(session.metadata.captureTarget.pixelSize.height)
                        )

                        ZStack {
                            Color.surface(red: 0.03, green: 0.03, blue: 0.04)

                            AnimatableAspectCanvasContainer(
                                session: session,
                                containerSize: geo.size,
                                aspect: targetAspect,
                                isHoveringPreviewCanvas: $isHoveringPreviewCanvas
                            )
                            .animation(.spring(response: 0.30, dampingFraction: 0.86), value: targetAspect)

                            // Floating Left Quick Dock
                            HStack {
                                VStack(spacing: 12) {
                                    // Group 1: Zooms
                                    VStack(spacing: 0) {
                                        quickDockIconButton(
                                            icon: "arrow.up.left.and.down.right.magnifyingglass",
                                            tooltip: "Classic zoom"
                                        ) {
                                            session.addZoomAtPlayhead(presentation: .screen)
                                        }

                                        quickDockIconButton(
                                            icon: "sparkle.magnifyingglass",
                                            tooltip: "Loupe zoom"
                                        ) {
                                            session.addZoomAtPlayhead(presentation: .loupe)
                                        }
                                    }

                                    // Group 1B: Camera Layouts
                                    if session.hasRecordedCamera {
                                        VStack(spacing: 0) {
                                            ForEach(CameraTimelineLayoutType.allCases) { layoutType in
                                                quickDockIconButton(
                                                    icon: layoutType.quickDockIcon,
                                                    tooltip: "\(layoutType.label) layout"
                                                ) {
                                                    session.addCameraLayoutAtPlayhead(type: layoutType)
                                                }
                                            }
                                        }
                                    }

                                    // Group 2: Masks
                                    VStack(spacing: 0) {
                                        quickDockIconButton(
                                            icon: "circle.filled.pattern.diagonalline.rectangle",
                                            tooltip: "Sensitive data mask",
                                            isActive: session.pendingAddMaskType == .blur
                                        ) {
                                            session.beginInteractiveMaskSelection(type: .blur, style: .gaussian)
                                        }

                                        quickDockIconButton(
                                            icon: "circle.rectangle.filled.pattern.diagonalline",
                                            tooltip: "Highlight mask",
                                            isActive: session.pendingAddMaskType == .spotlight
                                        ) {
                                            session.beginInteractiveMaskSelection(type: .spotlight, style: .dim)
                                        }
                                    }

                                    // Group 3: Keyboard Shortcuts & Voiceover
                                    VStack(spacing: 0) {
                                        quickDockIconButton(
                                            icon: "command",
                                            tooltip: "Add shortcut track"
                                        ) {
                                            session.addShortcutTrack()
                                        }

                                        quickDockIconButton(
                                            icon: session.isRecordingVoiceover ? "stop.circle.fill" : "mic.badge.plus",
                                            tooltip: session.isRecordingVoiceover ? "Stop voiceover recording" : "Record voiceover",
                                            isActive: session.isRecordingVoiceover
                                        ) {
                                            session.startVoiceoverRecording()
                                        }
                                    }
                                }
                                .padding(6)
                                .background(
                                    Color.surface(red: 0.11, green: 0.11, blue: 0.13).opacity(0.94),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(.ink.opacity(0.10), lineWidth: 1)
                                )
                                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
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
                                size: 36,
                                cornerRadius: 6
                            ) {
                                isOptionKeyHeldForSplit = false
                                session.isSplitModeActive.toggle()
                                if !session.isSplitModeActive {
                                    NSCursor.arrow.set()
                                }
                            } label: {
                                Image(systemName: "scissors")
                                    .font(.system(size: 15.0, weight: .medium))
                                    .foregroundStyle(
                                        session.isSplitModeActive
                                            ? Color(red: 0.65, green: 0.58, blue: 1.0)
                                            : .ink.opacity(0.88)
                                    )
                            }

                            Spacer()
                        }
                        .padding(.leading, 14)

                    // Center: Playhead + 3 Transport Buttons with Hover Highlight & Top Tooltips
                    HStack(spacing: 12) {
                            LivePlayheadTimecodeTextView(session: session)

                            InstantTooltipButton(
                                tooltip: "Jump to start",
                                edge: .top,
                                size: 36,
                                cornerRadius: 6
                            ) {
                                session.isPlaying = false
                                session.seek(toTimelineMs: 0.0)
                            } label: {
                                Image(systemName: "backward.end")
                                    .font(.system(size: 14.5, weight: .regular))
                                    .foregroundStyle(.ink.opacity(0.88))
                            }

                            InstantTooltipButton(
                                tooltip: session.isPlaying ? "Pause (Space)" : "Play (Space)",
                                edge: .top,
                                size: 40,
                                cornerRadius: 6
                            ) {
                                session.togglePlayPause()
                            } label: {
                                Image(systemName: session.isPlaying ? "pause.circle" : "play.circle")
                                    .font(.system(size: 25, weight: .regular))
                                    .foregroundStyle(.ink.opacity(0.95))
                            }
                            .keyboardShortcut(.space, modifiers: [])

                            InstantTooltipButton(
                                tooltip: "Jump to end",
                                edge: .top,
                                size: 36,
                                cornerRadius: 6
                            ) {
                                session.isPlaying = false
                                session.seek(toTimelineMs: session.timeMapper.totalTimelineDurationMs)
                            } label: {
                                Image(systemName: "forward.end")
                                    .font(.system(size: 14.5, weight: .regular))
                                    .foregroundStyle(.ink.opacity(0.88))
                            }

                            let totalTimeText = formatTimecode(session.timeMapper.totalTimelineDurationMs)
                            Button {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(totalTimeText, forType: .string)
                                session.showToast("Copied to clipboard")
                            } label: {
                                Text(totalTimeText)
                                    .font(.system(size: 12.5, weight: .regular, design: .default).monospacedDigit())
                                    .foregroundStyle(.secondary.opacity(0.75))
                                    .frame(width: 64, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        // Right: Playback Speed (`1x`) + Timeline Zoom Slider
                        HStack(spacing: 10) {
                            Spacer()

                            // Playback Speed Button (`1x` — Opens Native Liquid Glass NSMenu on click)
                            InstantTooltipButton(
                                tooltip: "Playback speed",
                                edge: .top,
                                isActive: abs(session.previewPlaybackRate - 1.0) > 0.01,
                                size: 36,
                                cornerRadius: 6
                            ) {
                                NativeSegmentContextMenuPresenter.shared.presentPlaybackSpeedMenu(session: session)
                            } label: {
                                Text(String(format: "%gx", session.previewPlaybackRate))
                                    .font(.system(size: 12.5, weight: .regular).monospacedDigit())
                                    .foregroundStyle(.ink.opacity(0.92))
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
                    .background(Color.surface(red: 0.03, green: 0.03, blue: 0.04))
                    .zIndex(70)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(1)

                if EditorViewPreferences.shared.showEditorSidebar {
                    InspectorSidebarView(session: session)
                        .zIndex(90)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if EditorViewPreferences.shared.showEditorTimeline {
                Divider()

                // 3. BOTTOM MULTI-TRACK NLE TIMELINE
                MultiTrackTimelineView(session: session)
                    .frame(height: 245)
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(!isModalOverlayActive)
            .environment(\.isTooltipAndHoverBlocked, isModalOverlayActive)

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

            // 5. EXPORT SETTINGS MODAL OVERLAY
            if isShowingExportSheet && !isExporting {
                ExportSettingsModalView(
                    session: session,
                    config: $exportConfig,
                    errorMessage: exportError,
                    onStartExport: {
                        runHardwareExport()
                    },
                    onCancel: {
                        withAnimation(.easeOut(duration: 0.14)) {
                            isShowingExportSheet = false
                            exportError = nil
                        }
                    }
                )
                .zIndex(550)
                .transition(.opacity)
            }

            // 6. FULL-WINDOW DARK EXPORT PROGRESS OVERLAY
            if isExporting {
                ExportingFullOverlayView(
                    projectName: session.document.name,
                    destinationPath: activeExportDestinationLabel,
                    progress: exportProgress,
                    startedAtMs: exportStartedAtMs,
                    measurementStart: exportMeasurementStart,
                    latestSample: exportLatestSample,
                    onStopExport: {
                        cancelActiveExport()
                    }
                )
                .zIndex(600)
                .transition(.opacity)
            }

            // 7. CAMERA CROP MODAL OVERLAY
            if session.isShowingCameraCropModal {
                CameraCropModalView(session: session)
                    .zIndex(580)
                    .transition(.opacity)
            }

            // 8. BOTTOM-CENTER TOAST NOTIFICATION
            if let toastMessage = session.activeToastMessage {
                VStack {
                    Spacer()
                    BottomToastBannerView(message: toastMessage)
                        .padding(.bottom, 18)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .zIndex(750)
                .transition(.move(edge: .bottom).combined(with: .opacity))
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
        .sheet(isPresented: $session.isShowingStillFrameExportModal) {
            ExportStillFrameModalView(session: session) {
                session.isShowingStillFrameExportModal = false
            }
        }
        .onChange(of: isModalOverlayActive) { _, active in
            if active {
                SharedFloatingTooltipWindowController.shared.hideTooltip()
            }
        }
        .onChange(of: isTitleFieldFocused) { _, focused in
            if !focused && isEditingProjectName {
                commitProjectRename()
            }
        }
        .onAppear {
            installEditorKeyMonitor()
            performPendingEditorCommand()
        }
        .onDisappear {
            removeEditorKeyMonitor()
        }
        .onChange(of: session.pendingEditorCommand) { _, _ in
            performPendingEditorCommand()
        }
    }

    /// Runs a command requested from the app menu (or by the recorder's `After Recording` setting).
    private func performPendingEditorCommand() {
        guard let command = session.pendingEditorCommand else { return }
        session.pendingEditorCommand = nil
        guard !isExporting else { return }
        switch command {
        case .showExportSheet:
            session.isPlaying = false
            withAnimation(.easeOut(duration: 0.14)) {
                isShowingCommandMenu = false
                isShowingExportSheet = true
            }
        case .quickExport(let target):
            // Uses `Settings > Quick export`, without showing the Export modal (whose own settings are kept).
            isShowingCommandMenu = false
            let modalConfig = exportConfig
            exportConfig = AppSettings.shared.quickExportConfig
            exportConfig.target = target
            runHardwareExport()
            exportConfig = modalConfig
        case .showCommandMenu:
            withAnimation(.easeOut(duration: 0.14)) {
                isShowingCommandMenu = true
            }
        case .removeProject:
            moveProjectToTrash()
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
        let wasPlaying = session.isPlaying
        if wasPlaying {
            session.isPlaying = false
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete this project?"
        alert.informativeText = "This action cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    try? FileManager.default.trashItem(at: session.packageURL, resultingItemURL: nil)
                    window.close()
                }
            }
        } else {
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                try? FileManager.default.trashItem(at: session.packageURL, resultingItemURL: nil)
                NSApp.keyWindow?.close()
            }
        }
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

            if isExporting {
                if event.keyCode == 53 { // ESC stops active export
                    cancelActiveExport()
                    return nil
                }
                return nil
            }

            if isShowingExportSheet {
                if event.keyCode == 53 { // ESC closes Export modal
                    withAnimation(.easeOut(duration: 0.14)) {
                        isShowingExportSheet = false
                        exportError = nil
                    }
                    return nil
                }
                if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter triggers Export
                    runHardwareExport()
                    return nil
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
            case 53: // ESC: Exit Camera Crop Modal, Add Mask Mode, Split Mode, close open Segment Editor / clear selection, or return Sidebar to General
                if session.isShowingCameraCropModal {
                    withAnimation(.easeOut(duration: 0.14)) {
                        session.isShowingCameraCropModal = false
                    }
                    return nil
                }
                if session.pendingAddMaskType != nil {
                    session.cancelInteractiveMaskSelection()
                    return nil
                }
                if session.isSplitModeActive {
                    isOptionKeyHeldForSplit = false
                    session.isSplitModeActive = false
                    NSCursor.arrow.set()
                    return nil
                }
                if session.selectedSliceId != nil
                    || session.selectedMaskId != nil
                    || session.selectedZoomId != nil
                    || session.selectedShortcutId != nil {
                    withAnimation(.easeOut(duration: 0.14)) {
                        session.clearTimelineSelection()
                    }
                    return nil
                }
                if session.selectedInspectorTab != .background {
                    withAnimation(.easeOut(duration: 0.14)) {
                        session.selectedInspectorTab = .background
                    }
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

            case 1: // `S`
                if flags == .command {
                    session.saveProjectWithToast()
                    return nil
                }
                return event

            case 51, 117: // Delete / Forward Delete
                session.deleteSelectedTimelineItem()
                return nil

            case 8: // 'C' key: Split at current time (or Copy with ⌘C; ⌥⌘C is `Quick export to clipboard` in the menu)
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags == .command {
                    if let mId = session.selectedMaskId {
                        session.copyMaskToClipboard(id: mId)
                        return nil
                    }
                    if let zId = session.selectedZoomId {
                        session.copyZoomToClipboard(id: zId)
                        return nil
                    }
                    session.copyCurrentFrameToClipboard()
                    return nil
                } else if flags.isEmpty {
                    session.splitAtCurrentTimeShortcut()
                    return nil
                }
                return event

            case 9: // 'V' key with ⌘V: Paste from clipboard
                if flags.contains(.command) {
                    session.pasteFromClipboard()
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

            case 4: // 'H' key: Toggle Hide Camera
                if flags.isEmpty {
                    session.mutate { $0.camera.enabled.toggle() }
                    return nil
                }
                return event

            case 18: // `⌘ 1` General (Background)
                if flags == .command {
                    session.clearTimelineSelection()
                    session.selectedInspectorTab = .background
                    return nil
                }
                return event

            case 19: // `⌘ 2` Cursor
                if flags == .command {
                    if session.inspectorTabAvailability(.cursor).canApply {
                        session.clearTimelineSelection()
                        session.selectedInspectorTab = .cursor
                    }
                    return nil
                }
                return event

            case 20: // `⌘ 3` Camera Layout
                if flags == .command {
                    if session.inspectorTabAvailability(.cameraLayout).canApply {
                        session.clearTimelineSelection()
                        session.selectedInspectorTab = .cameraLayout
                    }
                    return nil
                }
                return event

            case 21: // `⌘ 4` Camera Style
                if flags == .command {
                    if session.inspectorTabAvailability(.cameraStyle).canApply {
                        session.clearTimelineSelection()
                        session.selectedInspectorTab = .cameraStyle
                    }
                    return nil
                }
                return event

            case 23: // `⌘ 5` Captions
                if flags == .command {
                    if session.inspectorTabAvailability(.captions).canApply {
                        session.clearTimelineSelection()
                        session.selectedInspectorTab = .captions
                    }
                    return nil
                }
                return event

            case 22: // `⌘ 6` Edit by transcript
                if flags == .command {
                    if session.inspectorTabAvailability(.transcript).canApply {
                        session.clearTimelineSelection()
                        session.selectedInspectorTab = .transcript
                    }
                    return nil
                }
                return event

            case 26: // `⌘ 7` Audio
                if flags == .command {
                    if session.inspectorTabAvailability(.audio).canApply {
                        session.clearTimelineSelection()
                        session.selectedInspectorTab = .audio
                    }
                    return nil
                }
                return event

            case 28: // `⌘ 8` Keyboard Shortcuts
                if flags == .command {
                    if session.inspectorTabAvailability(.shortcuts).canApply {
                        session.clearTimelineSelection()
                        session.selectedInspectorTab = .shortcuts
                    }
                    return nil
                }
                return event

            case 25: // `⌘ 9` Animations (Zoom)
                if flags == .command {
                    session.clearTimelineSelection()
                    session.selectedInspectorTab = .zoom
                    return nil
                }
                return event

            case 29: // `⌘ 0` Device Frame
                if flags == .command {
                    session.clearTimelineSelection()
                    session.selectedInspectorTab = .deviceFrame
                    return nil
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
    private func quickDockIconButton(
        icon: String,
        tooltip: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        // Square control (`width: 38, height: 38, radius: 5, iconSize: 16`)
        InstantTooltipButton(
            tooltip: tooltip,
            edge: .trailing,
            isActive: isActive,
            size: 38,
            cornerRadius: 5,
            action: action
        ) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isActive ? Color(red: 0.72, green: 0.64, blue: 1.0) : .ink.opacity(0.95))
        }
    }

    // MARK: - Export Execution & Cooperative Cancellation (`Stop export`)

    private func runHardwareExport() {
        session.isPlaying = false
        exportConfig.normalizeForConstraints()

        let outURL: URL
        let isClipboardExport = (exportConfig.target == .clipboard)

        if isClipboardExport {
            let ext = exportConfig.format.fileExtension
            let cleanName = session.document.name.replacingOccurrences(of: "/", with: "-")
            outURL = ProjectWorkspaceStore.clipboardExportsDirectory
                .appendingPathComponent("\(cleanName)-\(Int(Date().timeIntervalSince1970)).\(ext)")
            activeExportDestinationLabel = "Clipboard (\(cleanName).\(ext))"
        } else {
            // Ensure NSSavePanel opens in expanded mode by default (showing the sidebar, file browser table, and "New Folder" button)
            UserDefaults.standard.set(true, forKey: "NSNavPanelExpandedStateForSaveMode")

            let savePanel = NSSavePanel()
            savePanel.message = "Where to save new recording export?"
            savePanel.canCreateDirectories = true
            savePanel.showsTagField = false
            savePanel.isExtensionHidden = false
            switch exportConfig.format {
            case .mp4:
                savePanel.allowedContentTypes = [.mpeg4Movie]
            case .prores:
                savePanel.allowedContentTypes = [.quickTimeMovie]
            case .gif:
                savePanel.allowedContentTypes = [.gif]
            }
            savePanel.nameFieldStringValue = "\(session.document.name).\(exportConfig.format.fileExtension)"

            guard savePanel.runModal() == .OK, let chosenURL = savePanel.url else { return }

            // When exporting MP4 with `Both` codec, a companion `<name>-hevc.mp4` file is also written.
            // If `<name>-hevc.mp4` already exists on disk (and wasn't already covered by NSSavePanel's primary file check), confirm replacement!
            if exportConfig.format == .mp4 && exportConfig.mp4Codec == .both {
                let baseName = chosenURL.deletingPathExtension().lastPathComponent
                let hevcURL = chosenURL.deletingLastPathComponent().appendingPathComponent("\(baseName)-hevc.mp4")
                if !FileManager.default.fileExists(atPath: chosenURL.path) && FileManager.default.fileExists(atPath: hevcURL.path) {
                    let alert = NSAlert()
                    alert.alertStyle = .critical
                    if let cautionIcon = NSImage(named: NSImage.cautionName) {
                        alert.icon = cautionIcon
                    }
                    alert.messageText = "“\(hevcURL.lastPathComponent)” already exists. Do you want to replace it?"
                    let folderName = hevcURL.deletingLastPathComponent().lastPathComponent
                    alert.informativeText = folderName == "Desktop"
                        ? "A file or folder with the same name already exists on the Desktop. Replacing it will overwrite its current contents."
                        : "A file or folder with the same name already exists in the folder \(folderName). Replacing it will overwrite its current contents."
                    let replaceBtn = alert.addButton(withTitle: "Replace")
                    replaceBtn.hasDestructiveAction = true
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
            }

            outURL = chosenURL
            activeExportDestinationLabel = chosenURL.path
        }

        let nowMs = ProcessInfo.processInfo.systemUptime * 1000.0
        exportStartedAtMs = nowMs
        exportMeasurementStart = nil
        exportLatestSample = nil
        exportProgress = 0.0
        exportError = nil
        isExporting = true
        DockProgressIndicatingController.shared.setProgress(0.0)

        let capturedConfig = exportConfig
        activeExportTask?.cancel()
        activeExportTask = Task { @MainActor in
            do {
                try await HardwareVideoExporter.exportProject(
                    session: session,
                    outputURL: outURL,
                    config: capturedConfig
                ) { progress in
                    recordExportProgressSample(progress)
                    DockProgressIndicatingController.shared.setProgress(progress)
                }

                guard !Task.isCancelled else { return }

                DockProgressIndicatingController.shared.setProgress(nil)
                isExporting = false
                isShowingExportSheet = false
                activeExportTask = nil

                if isClipboardExport {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.writeObjects([outURL as NSURL])
                    NSSound.beep()
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([outURL])
                }
            } catch is CancellationError {
                DockProgressIndicatingController.shared.setProgress(nil)
                isExporting = false
                activeExportTask = nil
            } catch {
                if Task.isCancelled {
                    DockProgressIndicatingController.shared.setProgress(nil)
                    isExporting = false
                    activeExportTask = nil
                    return
                }
                DockProgressIndicatingController.shared.setProgress(nil)
                isExporting = false
                activeExportTask = nil
                exportError = error.localizedDescription
            }
        }
    }

    private func recordExportProgressSample(_ progress01: Double) {
        let clamped = min(1.0, max(0.0, progress01))
        if let latest = exportLatestSample, abs(latest.progress01 - clamped) < 0.0001 {
            return
        }
        exportProgress = clamped
        if clamped <= 0.0 {
            exportMeasurementStart = nil
            exportLatestSample = nil
            return
        }
        let nowMs = ProcessInfo.processInfo.systemUptime * 1000.0
        let sample = (progress01: clamped, atMs: nowMs)
        let prev = exportLatestSample
        exportLatestSample = sample

        // Matches `ExportTimeEstimator.reportProgress`:
        // Keep `measurementStart` anchored at the initial sample (or reset only if progress jumped backwards or stalled >5s).
        if exportMeasurementStart == nil {
            // Anchor measurement to the start of the export (`exportStartedAtMs` at `progress01 = 0`) so cumulative throughput is accurate from frame 0!
            exportMeasurementStart = (progress01: 0.0, atMs: exportStartedAtMs)
        } else if let prev, (clamped < prev.progress01 || (nowMs - prev.atMs) > 5000.0) {
            exportMeasurementStart = sample
        }
    }

    private func cancelActiveExport() {
        activeExportTask?.cancel()
        activeExportTask = nil
        DockProgressIndicatingController.shared.setProgress(nil)
        withAnimation(.easeOut(duration: 0.15)) {
            isExporting = false
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

/// Isolated 120Hz timecode text view so `ProjectEditorWindowView.body` is NEVER invalidated during playback or timeline hover skimming!
private struct LivePlayheadTimecodeTextView: View {
    @Bindable var session: ProjectSession

    var body: some View {
        let totalSec = max(0.0, session.effectivePreviewTimelineMs / 1000.0)
        let mins = Int(totalSec) / 60
        let secs = Int(totalSec) % 60
        let hundredths = Int((totalSec - floor(totalSec)) * 100)
        let timeString = String(format: "%02d:%02d.%02d", mins, secs, hundredths)

        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(timeString, forType: .string)
            session.showToast("Copied to clipboard")
        } label: {
            Text(timeString)
                .font(.system(size: 12.5, weight: .regular, design: .default).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Bottom-Center Toast Pill
private struct BottomToastBannerView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.96))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(red: 0.16, green: 0.08, blue: 0.25).opacity(0.94))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1.0)
                    .padding(1.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.65), lineWidth: 1.2)
            )
            .shadow(color: .black.opacity(0.45), radius: 14, y: 5)
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
            // Camera, captions and keycaps are rendered inside the Metal frame (same pass as export).
            MetalPreviewView(session: session, canvasAspect: aspect)
            InteractiveMaskCanvasOverlayView(session: session, canvasSize: fittedSize)
            ShortcutKeycapHitTargetsView(session: session, canvasSize: fittedSize)

            ReelModeSafeZoneOverlayView(session: session, canvasSize: fittedSize)
                .opacity(session.isReelModeActive ? 1.0 : 0.0)
                .scaleEffect(session.isReelModeActive ? 1.0 : 0.985)
                .animation(.easeInOut(duration: 0.22), value: session.isReelModeActive)

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.ink.opacity(isHoveringPreviewCanvas ? 0.035 : 0.0))
                .allowsHitTesting(false)
        }
        .frame(width: fittedSize.width, height: fittedSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    Color.ink.opacity(isHoveringPreviewCanvas ? 0.28 : 0.08),
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

/// Invisible hover / click targets over the keycaps the Metal preview draws, placed from the compositor's last frame.
/// Hover brightens the keycaps (drawn by the compositor); click opens the shortcut editor.
private struct ShortcutKeycapHitTargetsView: View {
    @Bindable var session: ProjectSession
    let canvasSize: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(session.previewShortcutHitRects01.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                let rect = entry.value
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: rect.width * canvasSize.width, height: rect.height * canvasSize.height)
                    .offset(x: rect.minX * canvasSize.width, y: rect.minY * canvasSize.height)
                    .onHover { hovering in
                        if hovering {
                            session.hoveredShortcutId = entry.key
                        } else if session.hoveredShortcutId == entry.key {
                            session.hoveredShortcutId = nil
                        }
                    }
                    .onTapGesture {
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                            session.selectShortcut(entry.key)
                        }
                    }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }
}

private struct HeaderDoubleClickZoomView: NSViewRepresentable {
    func makeNSView(context: Context) -> HeaderDragAndZoomNSView {
        HeaderDragAndZoomNSView()
    }

    func updateNSView(_ nsView: HeaderDragAndZoomNSView, context: Context) {}

    final class HeaderDragAndZoomNSView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                guard let win = window else { return }
                ProjectWorkspaceStore.shared.toggleWindowZoom(win)
            } else {
                window?.performDrag(with: event)
            }
        }
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
    /// Bumped only by arrow-key navigation: hovering a row must never scroll the list under the mouse.
    @State private var keyboardScrollRequest: Int = 0
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

        let isDarkNow = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        items.append(EditorCommandItem(
            id: "toggleAppearance",
            group: "Editor",
            title: isDarkNow ? "Switch to light appearance" : "Switch to dark appearance",
            icon: isDarkNow ? "sun.max" : "moon",
            shortcutBadge: nil
        ) {
            withAnimation(.easeInOut(duration: 0.2)) {
                AppSettings.shared.toggleAppearance()
            }
        })

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

        // 6B. Camera Layouts, Voiceovers & Device Mockups
        items.append(EditorCommandItem(
            id: "addCameraLayoutAtPlayhead",
            group: "Camera Layout",
            title: "Add camera layout at playhead",
            icon: "inset.filled.rectangle.and.person.filled"
        ) {
            session.addCameraLayoutAtPlayhead(type: .cameraOverlay)
        })

        items.append(EditorCommandItem(
            id: "recordVoiceover",
            group: "Voiceover",
            title: session.isRecordingVoiceover ? "Stop voiceover recording" : "Record voiceover...",
            icon: "mic.badge.plus"
        ) {
            session.startVoiceoverRecording()
        })

        items.append(EditorCommandItem(
            id: "importVoiceoverAudio",
            group: "Voiceover",
            title: "Upload voiceover audio file...",
            icon: "waveform.badge.plus"
        ) {
            session.promptImportVoiceoverAudioFile()
        })

        items.append(EditorCommandItem(
            id: "toggleDeviceMockup",
            group: "Device",
            title: session.document.frameStyle.deviceMockup.enabled ? "Disable device mockup" : "Use device mockup",
            icon: "laptopcomputer.and.iphone"
        ) {
            session.mutate { $0.frameStyle.deviceMockup.enabled.toggle() }
            session.selectedInspectorTab = .deviceFrame
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
            id: "saveProject",
            group: "Project",
            title: "Save",
            icon: "square.and.arrow.down",
            shortcutBadge: "⌘ S"
        ) {
            session.saveProjectWithToast()
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
            Color.surface(red: 0.03, green: 0.035, blue: 0.05).opacity(0.82)
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
                        .foregroundStyle(.ink.opacity(0.92))
                        .tint(Color(red: 0.44, green: 0.34, blue: 0.98))
                        .focused($isSearchFocused)
                        .onKeyPress(.downArrow) {
                            let count = filteredCommands.count
                            if count > 0 {
                                selectedIndex = (selectedIndex + 1) % count
                                keyboardScrollRequest &+= 1
                            }
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            let count = filteredCommands.count
                            if count > 0 {
                                selectedIndex = (selectedIndex - 1 + count) % count
                                keyboardScrollRequest &+= 1
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
                                .foregroundStyle(.ink.opacity(0.42))
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .frame(height: 60)

                Rectangle()
                    .fill(Color.ink.opacity(0.10))
                    .frame(height: 1)

                // 2. Scrollable Grouped Command List (`max-height: 360px`)
                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        if filteredCommands.isEmpty {
                            Text("No matching commands")
                                .font(.system(size: 13.5, weight: .regular))
                                .foregroundStyle(.ink.opacity(0.45))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 36)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(groupedFilteredCommands.enumerated()), id: \.element.group) { groupIdx, section in
                                    if groupIdx > 0 {
                                        Rectangle()
                                            .fill(Color.ink.opacity(0.08))
                                            .frame(height: 1)
                                            .padding(.vertical, 4)
                                    }

                                    Text(section.group)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.ink.opacity(0.45))
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
                    .onChange(of: keyboardScrollRequest) { _, _ in
                        // Scroll just enough to reveal the keyboard-selected row (no recentering).
                        withAnimation(.easeOut(duration: 0.10)) {
                            scrollProxy.scrollTo(selectedIndex)
                        }
                    }
                }
            }
            .frame(width: 616)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.surface(red: 0.118, green: 0.118, blue: 0.125).opacity(0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.ink.opacity(0.18), lineWidth: 1)
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
                            : .ink.opacity(0.88)
                    )
                    .frame(width: 20, alignment: .center)

                Text(item.title)
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(
                        item.isDestructive
                            ? Color(red: 1.0, green: 0.35, blue: 0.32)
                            : .ink.opacity(0.95)
                    )
                    .lineLimit(1)

                Spacer(minLength: 12)

                if let badge = item.shortcutBadge, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.ink.opacity(0.78))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.ink.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.ink.opacity(0.10), lineWidth: 0.8)
                        )
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHighlighted ? Color.ink.opacity(0.09) : Color.clear)
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

// MARK: - 5. Export Settings Modal

private struct ExportSettingsModalView: View {
    @Bindable var session: ProjectSession
    @Binding var config: HardwareVideoExporter.ExportConfiguration
    let errorMessage: String?
    let onStartExport: () -> Void
    let onCancel: () -> Void

    @State private var isAdvancedExpanded: Bool = false
    @State private var isHoveringPrimaryExport: Bool = false
    @State private var isHoveringCancel: Bool = false
    @State private var isHoveringAdvancedToggle: Bool = false

    private let purpleAccent = Color(red: 0.302, green: 0.184, blue: 0.961) // `#4D2FF5`
    private let purpleBorder = Color(red: 0.44, green: 0.34, blue: 0.98)

    private var canvasAspect: Double {
        let sourceW = Double(session.metadata.captureTarget.pixelSize.width)
        let sourceH = Double(session.metadata.captureTarget.pixelSize.height)
        return session.document.canvas.effectiveAspectRatio(sourceWidth: sourceW, sourceHeight: sourceH)
    }

    private var outputPixels: (width: Int, height: Int) {
        config.outputPixelSize(canvasAspect: canvasAspect)
    }

    private var durationMs: Double {
        max(500.0, session.timeMapper.totalTimelineDurationMs)
    }

    private var estimatedTimeText: String {
        HardwareVideoExporter.estimateExportDurationString(
            config: config,
            canvasAspect: canvasAspect,
            durationMs: durationMs
        )
    }

    private var estimatedSizeText: String {
        HardwareVideoExporter.estimateOutputSizeString(
            config: config,
            canvasAspect: canvasAspect,
            durationMs: durationMs,
            hasAudio: !session.audioWaveformSamples.isEmpty
        )
    }

    var body: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture {
                    onCancel()
                }

            // Main Export Settings Card
            VStack(alignment: .leading, spacing: 28) {
                // TOP 2-COLUMN GRID
                VStack(alignment: .leading, spacing: 26) {
                    // Row 1: Format (Left) + Frame rate (Right)
                    HStack(alignment: .top, spacing: 36) {
                        // Left Column: Format
                        VStack(alignment: .leading, spacing: 11) {
                            sectionHeader(icon: "video", title: "Format", badgeIcon: true)

                            HStack(spacing: 6) {
                                ForEach(HardwareVideoExporter.ExportFormat.allCases) { fmt in
                                    selectionPillButton(
                                        label: fmt.label,
                                        isSelected: config.format == fmt
                                    ) {
                                        withAnimation(.easeInOut(duration: 0.14)) {
                                            config.format = fmt
                                            if fmt == .gif && config.fps > 30 {
                                                config.fps = 15
                                            } else if fmt != .gif && config.fps < 24 {
                                                config.fps = 60
                                            }
                                            config.normalizeForConstraints()
                                        }
                                    }
                                }
                            }
                        }
                        .frame(width: 224, alignment: .leading)

                        // Right Column: Frame rate
                        VStack(alignment: .leading, spacing: 11) {
                            sectionHeader(icon: "camera.aperture", title: "Frame rate")

                            Menu {
                                ForEach(config.format.allowedFPSModes, id: \.self) { fpsOption in
                                    Button {
                                        config.fps = fpsOption
                                    } label: {
                                        Text("\(fpsOption) FPS")
                                    }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Text("\(config.fps)")
                                        .font(.system(size: 13.5, weight: .regular).monospacedDigit())
                                        .foregroundStyle(.ink.opacity(0.95))
                                    Text("FPS")
                                        .font(.system(size: 13.5, weight: .regular))
                                        .foregroundStyle(.ink.opacity(0.42))
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 10.5, weight: .regular))
                                        .foregroundStyle(.ink.opacity(0.65))
                                        .padding(.leading, 4)
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(Color.ink.opacity(0.04))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .fixedSize()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Row 2: Resolution (Left) + Compression / Profile / GIF Quality (Right)
                    HStack(alignment: .top, spacing: 36) {
                        // Left Column: Resolution + Pixel Dimensions
                        VStack(alignment: .leading, spacing: 11) {
                            sectionHeader(icon: "rectangle.dashed", title: "Resolution")

                            HStack(spacing: 6) {
                                ForEach(config.format.allResolutionHeights, id: \.self) { resH in
                                    let isEnabled = config.enabledResolutionHeights.contains(resH)
                                    selectionPillButton(
                                        label: HardwareVideoExporter.ExportConfiguration.resolutionLabel(forHeight: resH),
                                        isSelected: config.resolutionHeight == resH,
                                        isDisabled: !isEnabled
                                    ) {
                                        guard isEnabled else { return }
                                        config.resolutionHeight = resH
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(outputPixels.width)px × \(outputPixels.height)px")
                                    .font(.system(size: 13, weight: .regular).monospacedDigit())
                                    .foregroundStyle(.ink.opacity(0.36))

                                if config.format == .gif && config.resolutionHeight >= 1080 {
                                    Text("Will result in a large file size")
                                        .font(.system(size: 12.5, weight: .regular))
                                        .foregroundStyle(.ink.opacity(0.36))
                                }
                            }
                            .padding(.top, 2)
                        }
                        .frame(width: 224, alignment: .leading)

                        // Right Column: Format-Specific Quality & Advanced Controls
                        VStack(alignment: .leading, spacing: 16) {
                            switch config.format {
                            case .mp4:
                                VStack(alignment: .leading, spacing: 11) {
                                    sectionHeader(icon: "scribble.variable", title: "Compression")

                                    HStack(spacing: 6) {
                                        ForEach(HardwareVideoExporter.ExportCompression.allCases) { comp in
                                            selectionPillButton(
                                                label: comp.label,
                                                isSelected: config.compression == comp
                                            ) {
                                                withAnimation(.easeInOut(duration: 0.12)) {
                                                    config.compression = comp
                                                    config.normalizeForConstraints()
                                                }
                                            }
                                        }
                                    }

                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(config.compression.descriptionText)
                                            .font(.system(size: 13, weight: .regular))
                                            .foregroundStyle(.ink.opacity(0.36))
                                            .fixedSize(horizontal: false, vertical: true)
                                            .lineSpacing(2)

                                        Text("Quality setting does not impact export speed.")
                                            .font(.system(size: 13, weight: .regular))
                                            .foregroundStyle(.ink.opacity(0.36))
                                    }
                                    .padding(.top, 2)
                                }

                                // Advanced Accordion (`Codec: H.264 | HEVC | Both`)
                                VStack(alignment: .leading, spacing: 12) {
                                    Button {
                                        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                                            isAdvancedExpanded.toggle()
                                        }
                                    } label: {
                                        HStack {
                                            Text("Advanced")
                                                .font(.system(size: 13.5, weight: .regular))
                                                .foregroundStyle(.ink.opacity(0.90))

                                            Spacer()

                                            Image(systemName: isAdvancedExpanded ? "chevron.up" : "chevron.down")
                                                .font(.system(size: 11, weight: .regular))
                                                .foregroundStyle(.ink.opacity(0.75))
                                                .frame(width: 26, height: 26)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                        .fill(Color.ink.opacity(isHoveringAdvancedToggle ? 0.10 : 0.06))
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                        .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
                                                )
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .onHover { isHoveringAdvancedToggle = $0 }

                                    if isAdvancedExpanded {
                                        VStack(alignment: .leading, spacing: 10) {
                                            sectionHeader(icon: "film", title: "Codec")

                                            let codecChoices: [HardwareVideoExporter.MP4CodecOption] = (config.target == .file)
                                                ? [.h264, .h265, .both]
                                                : [.h264, .h265]

                                            HStack(spacing: 6) {
                                                ForEach(codecChoices) { codecOpt in
                                                    selectionPillButton(
                                                        label: codecOpt.label,
                                                        isSelected: config.mp4Codec == codecOpt
                                                    ) {
                                                        config.mp4Codec = codecOpt
                                                    }
                                                }
                                            }

                                            Text(config.mp4Codec.descriptionText)
                                                .font(.system(size: 12.5, weight: .regular))
                                                .foregroundStyle(.ink.opacity(0.36))
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        .padding(.top, 2)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                    }
                                }
                                .padding(.top, 4)

                            case .prores:
                                VStack(alignment: .leading, spacing: 11) {
                                    sectionHeader(icon: "film", title: "Profile")

                                    HStack(spacing: 6) {
                                        ForEach(HardwareVideoExporter.ProResProfileOption.allCases) { prof in
                                            selectionPillButton(
                                                label: prof.label,
                                                isSelected: config.proResProfile == prof
                                            ) {
                                                config.proResProfile = prof
                                            }
                                        }
                                    }

                                    Text(config.proResProfile.descriptionText)
                                        .font(.system(size: 13, weight: .regular))
                                        .foregroundStyle(.ink.opacity(0.36))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.top, 2)
                                }

                            case .gif:
                                VStack(alignment: .leading, spacing: 12) {
                                    Toggle(isOn: $config.gifHighQuality) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("High quality")
                                                .font(.system(size: 13.5, weight: .regular))
                                                .foregroundStyle(.ink.opacity(0.92))
                                            Text("Keeps more detail and fewer compression artifacts, for a larger file. Turn off for the best balance of file size and quality.")
                                                .font(.system(size: 12.5, weight: .regular))
                                                .foregroundStyle(.ink.opacity(0.38))
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .toggleStyle(.switch)
                                    .tint(purpleAccent)

                                    Toggle(isOn: $config.gifDisableLoop) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Disable loop")
                                                .font(.system(size: 13.5, weight: .regular))
                                                .foregroundStyle(.ink.opacity(0.92))
                                            Text("Exported GIF will only play once and then stop.")
                                                .font(.system(size: 12.5, weight: .regular))
                                                .foregroundStyle(.ink.opacity(0.38))
                                        }
                                    }
                                    .toggleStyle(.switch)
                                    .tint(purpleAccent)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Error Banner (if any)
                if let err = errorMessage, !err.isEmpty {
                    Text(err)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.42))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.red.opacity(0.12))
                        )
                }

                // BOTTOM SECTION: `Export to` + Action Buttons + Live Estimation Line
                VStack(alignment: .leading, spacing: 14) {
                    Text("Export to")
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(.ink.opacity(0.90))

                    HStack(spacing: 10) {
                        // Left: `File` | `Clipboard` Target Pills
                        HStack(spacing: 6) {
                            ForEach(HardwareVideoExporter.ExportTarget.allCases) { tgt in
                                selectionPillButton(
                                    label: tgt.label,
                                    icon: tgt.iconName,
                                    isSelected: config.target == tgt,
                                    height: 38
                                ) {
                                    config.target = tgt
                                    config.normalizeForConstraints()
                                }
                            }
                        }

                        Spacer()

                        // Right: Primary Purple Action (`Export to file... ↵`) + `Cancel`
                        HStack(spacing: 8) {
                            Button(action: onStartExport) {
                                HStack(spacing: 8) {
                                    Image(systemName: config.target.iconName)
                                        .font(.system(size: 13, weight: .regular))
                                    Text(config.target.primaryButtonTitle)
                                        .font(.system(size: 13.5, weight: .regular))
                                    Image(systemName: "return")
                                        .font(.system(size: 11, weight: .regular))
                                        .foregroundStyle(.white.opacity(0.75))
                                        .padding(.leading, 2)
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .frame(height: 38)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(isHoveringPrimaryExport ? Color(red: 0.35, green: 0.23, blue: 0.99) : purpleAccent)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .onHover { isHoveringPrimaryExport = $0 }

                            Button(action: onCancel) {
                                Text("Cancel")
                                    .font(.system(size: 13.5, weight: .regular))
                                    .foregroundStyle(.ink.opacity(0.90))
                                    .padding(.horizontal, 18)
                                    .frame(height: 38)
                                    .background(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(Color.ink.opacity(isHoveringCancel ? 0.09 : 0.04))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .onHover { isHoveringCancel = $0 }
                        }
                    }

                    // Bottom-Right Estimation Line (`Estimation — Export time 19 seconds — Output size 35–85MB`)
                    HStack {
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("Estimation — Export time \(estimatedTimeText) — Output size \(estimatedSizeText)")
                                .font(.system(size: 12.5, weight: .regular).monospacedDigit())
                                .foregroundStyle(.ink.opacity(0.30))

                            if config.format == .gif {
                                Text("GIF files are much larger than MP4 files. Use MP4 when you can.")
                                    .font(.system(size: 12.0, weight: .regular))
                                    .foregroundStyle(.ink.opacity(0.26))
                            } else if config.format == .prores {
                                Text("ProRes is made for editing apps. Use MP4 to share.")
                                    .font(.system(size: 12.0, weight: .regular))
                                    .foregroundStyle(.ink.opacity(0.26))
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(width: 740)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.surface(red: 0.067, green: 0.067, blue: 0.078))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.ink.opacity(0.09), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.68), radius: 38, x: 0, y: 18)
        }
        .onAppear {
            if config.mp4Codec != .h264 {
                isAdvancedExpanded = true
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(icon: String, title: String, badgeIcon: Bool = false) -> some View {
        HStack(spacing: 8) {
            if badgeIcon {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.black.opacity(0.9))
                    .frame(width: 17, height: 15)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.ink.opacity(0.92))
                    )
            } else {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.92))
            }

            Text(title)
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(.ink.opacity(0.92))
        }
    }

    @ViewBuilder
    private func selectionPillButton(
        label: String,
        icon: String? = nil,
        isSelected: Bool,
        isDisabled: Bool = false,
        height: CGFloat = 36,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12.5, weight: .regular))
                }
                Text(label)
                    .font(.system(size: 13.5, weight: .regular))
            }
            .foregroundStyle(
                isDisabled
                    ? .ink.opacity(0.28)
                    : (isSelected ? .ink : .ink.opacity(0.86))
            )
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        isSelected
                            ? purpleAccent.opacity(0.18)
                            : Color.ink.opacity(0.038)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? purpleBorder
                            : Color.ink.opacity(0.06),
                        lineWidth: isSelected ? 1.35 : 1.0
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

// MARK: - 6. Full-Window Exporting Status Overlay

private struct ExportingFullOverlayView: View {
    let projectName: String
    let destinationPath: String
    let progress: Double
    let startedAtMs: Double
    let measurementStart: (progress01: Double, atMs: Double)?
    let latestSample: (progress01: Double, atMs: Double)?
    let onStopExport: () -> Void

    @State private var nowUptimeMs: Double = ProcessInfo.processInfo.systemUptime * 1000.0
    @State private var isHoveringStop: Bool = false

    private let clockTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    private let purpleAccent = Color(red: 0.302, green: 0.184, blue: 0.961) // `#4D2FF5`

    private var elapsedMs: Double {
        let liveNow = max(nowUptimeMs, latestSample?.atMs ?? nowUptimeMs)
        return max(0.0, liveNow - startedAtMs)
    }

    /// Computes live remaining time in ms.
    private var timeLeftMs: Double? {
        guard let start = measurementStart, let latest = latestSample else { return nil }
        if latest.progress01 >= 1.0 { return 0.0 }
        let liveNow = max(nowUptimeMs, latest.atMs)
        // If no sample arrived for >5s, consider stalled
        if liveNow - latest.atMs > 5000.0 { return nil }
        let measuredSpanMs = latest.atMs - start.atMs
        // Require at least 800ms of measurement (or >=8% progress) before displaying ETA
        if measuredSpanMs < 800.0 && latest.progress01 < 0.08 { return nil }
        let progressDelta = latest.progress01 - start.progress01
        guard progressDelta > 0.005 else { return nil }
        let msPerFullProgress = measuredSpanMs / progressDelta
        let estimatedCompletionMs = latest.atMs + (1.0 - latest.progress01) * msPerFullProgress
        return max(0.0, estimatedCompletionMs - liveNow)
    }

    /// Matches `q` and `J` (0 decimals for <5min total, 1 decimal for >5min, 2 decimals for >30min).
    private var percentageText: String {
        let totalEstMs = elapsedMs + (timeLeftMs ?? 0.0)
        let pct = min(100.0, max(0.0, progress * 100.0))
        if totalEstMs > 30.0 * 60_000.0 {
            return String(format: "%.2f%%", pct)
        } else if totalEstMs > 5.0 * 60_000.0 {
            return String(format: "%.1f%%", pct)
        } else {
            return "\(Int(floor(pct)))%"
        }
    }

    private func formatMMSS(_ ms: Double, roundCeil: Bool) -> String {
        let rawSec = max(0.0, ms / 1000.0)
        let totalSec = Int(roundCeil ? ceil(rawSec) : floor(rawSec))
        let mins = totalSec / 60
        let secs = totalSec % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private var infoTooltipText: String {
        if destinationPath.isEmpty {
            return projectName
        }
        return "\(projectName) → \(destinationPath)"
    }

    var body: some View {
        ZStack {
            // Full-window solid dark background (`position: fixed; inset: 0; background`)
            Color(red: 0.035, green: 0.035, blue: 0.045)
                .ignoresSafeArea()

            VStack(spacing: 52) {
                // Center Progress Stack (`max-width: 320px`)
                VStack(spacing: 12) {
                    // Header: `Exporting video • 33% ⓘ`
                    HStack(spacing: 6) {
                        Text("Exporting video • \(percentageText)")
                            .font(.system(size: 19, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.96))

                        InstantTooltipButton(
                            tooltip: infoTooltipText,
                            edge: .top,
                            size: 22,
                            cornerRadius: 6
                        ) {
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 14.5, weight: .regular))
                                .foregroundStyle(.white.opacity(0.48))
                        }
                    }

                    // Purple Progress Bar (`320pt × 6pt`)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.11))
                                .frame(height: 6)

                            Capsule(style: .continuous)
                                .fill(purpleAccent)
                                .frame(
                                    width: max(6, geo.size.width * CGFloat(min(1.0, max(0.0, progress)))),
                                    height: 6
                                )
                                .animation(.easeOut(duration: 0.12), value: progress)
                        }
                    }
                    .frame(width: 320, height: 6)

                    // Time Elapsed & Remaining ETA (`00:04 • 00:06 left`)
                    Group {
                        if progress <= 0.001 {
                            Text("Preparing export...")
                        } else if let remainingMs = timeLeftMs {
                            Text("\(formatMMSS(elapsedMs, roundCeil: false)) • \(formatMMSS(remainingMs, roundCeil: true)) left")
                        } else {
                            Text("\(formatMMSS(elapsedMs, roundCeil: false)) • Estimating time left...")
                        }
                    }
                    .font(.system(size: 13.5, weight: .regular).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                }
                .frame(width: 320)

                // `Stop export` Button
                Button(action: onStopExport) {
                    Text("Stop export")
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 18)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.white.opacity(isHoveringStop ? 0.09 : 0.045))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { isHoveringStop = $0 }
            }
        }
        .onReceive(clockTimer) { _ in
            nowUptimeMs = ProcessInfo.processInfo.systemUptime * 1000.0
        }
    }
}

// MARK: - 7. Presets Popover

private struct PresetsPopoverView: View {
    @Bindable var session: ProjectSession
    @Bindable private var store = ProjectPresetsStore.shared

    @State private var newPresetName: String = ""
    @State private var editingPresetId: String? = nil
    @State private var editingPresetName: String = ""
    @State private var hoveredPresetId: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.presets.isEmpty {
                Text("Presets will help you re-use the same project settings across projects")
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.55))
                    .padding(.vertical, 8)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(store.presets) { preset in
                            presetRowView(preset: preset)
                        }
                    }
                }
                .frame(maxHeight: 280)

                Text("Presets are not auto-updated. If you apply preset and then modify project settings - remember to update presets to reflect those changes.")
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Create new preset row
            HStack(spacing: 8) {
                TextField("New preset name...", text: $newPresetName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.0, weight: .regular))
                    .foregroundStyle(.ink)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.ink.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.ink.opacity(0.10), lineWidth: 1)
                    )
                    .onSubmit {
                        createNewPreset()
                    }

                Button {
                    createNewPreset()
                } label: {
                    Text("Create new preset")
                        .font(.system(size: 13.0, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(red: 0.302, green: 0.184, blue: 0.961))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .frame(width: 420)
        .background(Color.surface(red: 0.08, green: 0.08, blue: 0.10))
    }

    private func createNewPreset() {
        let trimmed = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.addPreset(name: trimmed, from: session)
        newPresetName = ""
    }

    @ViewBuilder
    private func presetRowView(preset: ProjectPreset) -> some View {
        let isHovered = (hoveredPresetId == preset.id)
        let matchesProject = preset.matchesDocument(session.document)
        let isDefault = (store.defaultPresetId == preset.id)

        HStack(spacing: 0) {
            if editingPresetId == preset.id {
                TextField("Preset name", text: $editingPresetName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.0, weight: .medium))
                    .foregroundStyle(.ink)
                    .padding(.leading, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onSubmit {
                        store.renamePreset(preset, to: editingPresetName)
                        editingPresetId = nil
                    }
            } else {
                Button {
                    store.applyPreset(preset, to: session)
                } label: {
                    HStack(spacing: 8) {
                        Text(preset.name)
                            .font(.system(size: 13.0, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.95))
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        if matchesProject {
                            presetBadge("Matches project")
                        }
                        if isDefault {
                            presetBadge("Default")
                        }
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 6)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to apply")
            }

            // Gear Options Menu
            Menu {
                Button("Rename...") {
                    editingPresetName = preset.name
                    editingPresetId = preset.id
                }

                Button {
                    store.toggleDefaultPreset(preset)
                } label: {
                    if isDefault {
                        Label("Use as default for new projects", systemImage: "checkmark")
                    } else {
                        Text("Use as default for new projects")
                    }
                }

                if !matchesProject {
                    Button("Update to match currently edited project") {
                        store.syncPresetWithProject(preset, session: session)
                    }
                }

                Divider()

                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.fileURL(for: preset)])
                }

                Divider()

                Button("Remove...", role: .destructive) {
                    store.removePreset(preset)
                }
            } label: {
                Image(systemName: "gear")
                    .font(.system(size: 13.0, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.68))
                    .frame(width: 34, height: 36)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.trailing, 4)
            .help("Preset options...")
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.ink.opacity(0.07) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering in
            hoveredPresetId = hovering ? preset.id : nil
        }
    }

    @ViewBuilder
    private func presetBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.0, weight: .medium))
            .foregroundStyle(.ink.opacity(0.58))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.ink.opacity(0.08))
            )
    }
}

