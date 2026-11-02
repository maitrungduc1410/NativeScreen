import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// Native macOS Inspector Sidebar with dark pill selectors,
/// non-truncating responsive controls, and quick "Reset" buttons on sliders.
public struct InspectorSidebarView: View {
    @Bindable var session: ProjectSession
    @Bindable private var whisperManager = WhisperModelDownloadManager.shared
    @State private var systemWallpapers: [SystemWallpaperItem] = []
    @State private var wallpaperThumbnailRevision: Int = 0
    @State private var isRotationSectionExpanded: Bool = false
    @State private var isAdvancedCursorSectionExpanded: Bool = false
    @State private var isAdvancedShadowSectionExpanded: Bool = false
    @State private var isAdvancedZoomSegmentExpanded: Bool = false
    @State private var isCameraSizeDuringZoomExpanded: Bool = false
    @State private var isAdvancedCameraStyleExpanded: Bool = false
    @State private var isRegenerateTranscriptExpanded: Bool = false
    @State private var editingTranscriptWordId: String? = nil
    @State private var editingTranscriptDraftText: String = ""
    @State private var selectedTranscriptWordId: String? = nil
    @State private var wallpaperCategory: String = "macOS"
    @State private var gradientHueShift: Double = 0.5
    @State private var isHoveringImageDropZone: Bool = false
    @State private var selectedShortcutTrackId: String = "default-shortcuts-track"
    @State private var isRecordingShortcutKeys: Bool = false
    @State private var shortcutKeyRecorderMonitor: Any? = nil
    @State private var hoveredScreenAnimPreset: String? = nil
    @State private var hoveredCursorAnimPreset: String? = nil
    @State private var selectedAudioGenre: String = "Lo-Fi"
    @State private var webcamThumbnailRevision: Int = 0
    @State private var lastRememberedIdleMs: Double = 2000.0
    @State private var lastRememberedLoopMs: Double = 1000.0
    @State private var lastRememberedShakeThreshold: Double = 4.0
    @State private var isEditingSensitiveCustomPhrases: Bool = false
    @State private var draftSensitiveCustomPhrases: String = ""

    public init(session: ProjectSession) {
        self.session = session
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Vertical Icon Navigation Rail with Purple Active Dot Indicator
            VStack(spacing: 4) {
                ForEach(ProjectSession.InspectorTab.allCases) { tab in
                    let availability = session.inspectorTabAvailability(tab)
                    let isTabDisabled = !availability.canApply
                    let isSelected = (session.selectedInspectorTab == tab) && !isTabDisabled
                    let displayTooltip = isTabDisabled ? (availability.disabledTooltip ?? tab.tooltipTitle) : tab.tooltipTitle

                    InstantTooltipButton(
                        tooltip: displayTooltip,
                        shortcutBadge: isTabDisabled ? nil : tab.shortcutBadge,
                        edge: .leading,
                        isActive: isSelected,
                        isDisabled: isTabDisabled,
                        allowHoverWhenDisabled: true,
                        size: 38,
                        cornerRadius: 6
                    ) {
                        guard !isTabDisabled else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            session.clearTimelineSelection()
                            session.selectedInspectorTab = tab
                        }
                    } label: {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 15.5, weight: .medium))
                            .foregroundStyle(
                                isSelected
                                    ? Color(red: 0.65, green: 0.58, blue: 0.99)
                                    : .ink.opacity(0.85)
                            )
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
            .background(Color.surface(red: 0.04, green: 0.04, blue: 0.055))
            .zIndex(50)

            // Active Inspector Content Panel (Wrapped in the rounded dark container with spacious 24pt section rhythm!)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    if let zoomId = session.selectedZoomId,
                       let zoom = session.document.timeline.zooms.first(where: { $0.id == zoomId }) {
                        zoomSegmentEditor(zoom: zoom)
                    } else if let layoutId = session.selectedCameraLayoutId,
                              let layoutSeg = session.document.timeline.cameraLayouts.first(where: { $0.id == layoutId }) {
                        cameraLayoutSegmentEditor(segment: layoutSeg)
                    } else if let voiceoverId = session.selectedVoiceoverId,
                              let voSeg = session.document.timeline.voiceovers.first(where: { $0.id == voiceoverId }) {
                        voiceoverSegmentEditor(voiceover: voSeg)
                    } else if let shortcutId = session.selectedShortcutId,
                              let cluster = session.detectedShortcutClusters.first(where: { $0.id == shortcutId }) {
                        shortcutSegmentEditor(cluster: cluster)
                    } else {
                        switch session.selectedInspectorTab {
                        case .background:
                            backgroundInspector
                        case .cursor:
                            cursorInspector
                        case .cameraLayout:
                            cameraLayoutInspector
                        case .cameraStyle:
                            cameraStyleInspector
                        case .captions:
                            captionsInspector
                        case .transcript:
                            transcriptEditorInspector
                        case .zoom:
                            zoomInspector
                        case .deviceFrame:
                            deviceFrameInspector
                        case .masks:
                            masksInspector
                        case .audio:
                            audioAndSliceInspector
                        case .shortcuts:
                            shortcutsInspector
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.surface(red: 0.08, green: 0.08, blue: 0.10))
                )
                .padding(.vertical, 8)
                .padding(.trailing, 8)
            }
            .frame(width: 344)
            .background(Color.surface(red: 0.04, green: 0.04, blue: 0.055))
        }
        .onAppear {
            if systemWallpapers.isEmpty {
                let items = SystemWallpaperCatalog.discoverSystemWallpapers()
                systemWallpapers = items
                SystemWallpaperCatalog.preloadThumbnailsInBackground(for: items) {
                    wallpaperThumbnailRevision &+= 1
                }
            }
        }
    }

    // MARK: - 1. Background & Frame Style Inspector

    private static let curatedSolidColors: [String] = [
        "#4776E6", "#8E54E9", "#1E1E2E", "#0F172A", "#2563EB", "#7C3AED", "#DB2777", "#EA580C",
        "#059669", "#0D9488", "#4F46E5", "#9333EA", "#E11D48", "#D97706", "#16A34A", "#0284C7"
    ]

    private static let curatedGradientPairs: [(String, String)] = [
        ("#E2E8F0", "#CBD5E1"), ("#BFDBFE", "#93C5FD"), ("#FED7AA", "#FDBA74"), ("#C7D2FE", "#A5B4FC"),
        ("#CCFBF1", "#99F6E4"), ("#D9F99D", "#BEF264"), ("#FDBA74", "#F472B6"), ("#FDE047", "#F97316"),
        ("#FB7185", "#EA580C"), ("#F97316", "#EAB308"), ("#C084FC", "#FDBA74"), ("#FB923C", "#4F46E5"),
        ("#38BDF8", "#60A5FA"), ("#22D3EE", "#3B82F6"), ("#2DD4BF", "#0284C7"), ("#34D399", "#059669"),
        ("#4ADE80", "#1E3A8A"), ("#38BDF8", "#1E40AF"), ("#4776E6", "#8E54E9"), ("#7C3AED", "#DB2777"),
        ("#0EA5E9", "#312E81"), ("#EC4899", "#6366F1"), ("#F472B6", "#60A5FA"), ("#38BDF8", "#A855F7"),
        ("#1E293B", "#0F172A"), ("#1E3A8A", "#0F172A"), ("#7F1D1D", "#1E1B4B"), ("#C026D3", "#31102F"),
        ("#64748B", "#334155"), ("#27272A", "#09090B")
    ]

    @ViewBuilder
    private var backgroundInspector: some View {
        let bgType = session.document.background.type
        let isWallpaperMode = (bgType == .mesh || bgType == .wallpaper)
        let activeTopModeId: String = {
            if isWallpaperMode { return "Wallpaper" }
            switch bgType {
            case .gradient: return "Gradient"
            case .solid: return "Color"
            case .image: return "Image"
            default: return "Wallpaper"
            }
        }()

        VStack(alignment: .leading, spacing: 24) {
            // 1. Background Type Selector (`Wallpaper` | `Gradient` | `Color` | `Image` — Horizontal Scroll + Auto-Center on Click!)
            VStack(alignment: .leading, spacing: 10) {
                Text("Background")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.92))

                ScrollViewReader { modeProxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            inspectorPillOptionButton(title: "Wallpaper", isSelected: isWallpaperMode) {
                                session.mutate { $0.background.type = (wallpaperCategory == "macOS" ? .wallpaper : .mesh) }
                                withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                                    modeProxy.scrollTo("Wallpaper", anchor: .center)
                                }
                            }
                            .id("Wallpaper")

                            inspectorPillOptionButton(title: "Gradient", isSelected: bgType == .gradient) {
                                session.mutate { $0.background.type = .gradient }
                                withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                                    modeProxy.scrollTo("Gradient", anchor: .center)
                                }
                            }
                            .id("Gradient")

                            inspectorPillOptionButton(title: "Color", isSelected: bgType == .solid) {
                                session.mutate { $0.background.type = .solid }
                                withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                                    modeProxy.scrollTo("Color", anchor: .center)
                                }
                            }
                            .id("Color")

                            inspectorPillOptionButton(title: "Image", isSelected: bgType == .image) {
                                session.mutate { $0.background.type = .image }
                                withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                                    modeProxy.scrollTo("Image", anchor: .center)
                                }
                            }
                            .id("Image")
                        }
                        .padding(.vertical, 2)
                        .padding(.trailing, 18)
                    }
                    .padding(.trailing, -18)
                    .onChange(of: activeTopModeId) { _, newId in
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                            modeProxy.scrollTo(newId, anchor: .center)
                        }
                    }
                }
            }

            if isWallpaperMode {
                // 2A. Wallpaper Category Pills + Full-Width `Pick random wallpaper` + 8-Column Grid
                VStack(alignment: .leading, spacing: 12) {
                    Text("Wallpaper")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.ink.opacity(0.92))

                    ScrollViewReader { catProxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(["All", "macOS", "Mesh", "Spring", "Sunset", "Radiant"], id: \.self) { cat in
                                    let displayTitle = (cat == "All") ? "★" : cat
                                    inspectorPillOptionButton(title: displayTitle, isSelected: wallpaperCategory == cat) {
                                        wallpaperCategory = cat
                                        session.mutate {
                                            $0.background.type = (cat == "macOS") ? .wallpaper : .mesh
                                        }
                                        withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                                            catProxy.scrollTo(cat, anchor: .center)
                                        }
                                    }
                                    .id(cat)
                                }
                            }
                            .padding(.vertical, 2)
                            .padding(.trailing, 18)
                        }
                        .padding(.trailing, -18)
                    }

                    Button {
                        if wallpaperCategory == "macOS", let randomSys = systemWallpapers.randomElement() {
                            session.selectSystemWallpaper(randomSys)
                        } else if let randomPreset = MeshPreset.builtIn.randomElement() {
                            session.mutate {
                                $0.background.type = .mesh
                                $0.background.meshPresetId = randomPreset.id
                            }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 13, weight: .regular))
                            Text("Pick random wallpaper")
                                .font(.system(size: 13, weight: .regular))
                        }
                        .foregroundStyle(.ink.opacity(0.92))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.ink.opacity(0.035))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    // 8-Column Square Thumbnail Grid
                    let filteredMeshPresets: [MeshPreset] = {
                        if wallpaperCategory == "macOS" { return [] }
                        if wallpaperCategory == "All" || wallpaperCategory == "Mesh" { return MeshPreset.builtIn }
                        let sub = MeshPreset.builtIn.filter { $0.category.caseInsensitiveCompare(wallpaperCategory) == .orderedSame }
                        return sub.isEmpty ? MeshPreset.builtIn : sub
                    }()
                    let showSystemItems = (wallpaperCategory == "All" || wallpaperCategory == "macOS" || wallpaperCategory == "Spring" || wallpaperCategory == "Sunset")

                    let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(filteredMeshPresets) { preset in
                            let isSelected = (session.document.background.type == .mesh && session.document.background.meshPresetId == preset.id)
                            Button {
                                session.mutate {
                                    $0.background.type = .mesh
                                    $0.background.meshPresetId = preset.id
                                }
                            } label: {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: preset.colorsHex.map { Color(hex: $0) },
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .aspectRatio(1.0, contentMode: .fit)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(isSelected ? Color.ink : Color.ink.opacity(0.12), lineWidth: isSelected ? 1.5 : 0.8)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }

                        if showSystemItems {
                            let _ = wallpaperThumbnailRevision
                            ForEach(systemWallpapers) { item in
                                let isSelected = (session.document.background.type == .wallpaper && session.document.background.systemWallpaperName == item.name)
                                Button {
                                    session.selectSystemWallpaper(item)
                                } label: {
                                    Color.clear
                                        .aspectRatio(1.0, contentMode: .fit)
                                        .overlay {
                                            if let nsImg = SystemWallpaperCatalog.cachedThumbnailImage(for: item) {
                                                Image(nsImage: nsImg)
                                                    .resizable()
                                                    .scaledToFill()
                                            } else {
                                                Color.secondary.opacity(0.2)
                                            }
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .strokeBorder(isSelected ? Color.ink : Color.ink.opacity(0.12), lineWidth: isSelected ? 1.5 : 0.8)
                                        )
                                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                coalescedSlider(
                    title: "Background blur",
                    value: Binding(
                        get: { session.document.background.blurRadius },
                        set: { v in session.mutate { $0.background.blurRadius = v } }
                    ),
                    range: 0...60,
                    defaultValue: 0.0,
                    showResetButton: false
                )

            } else if bgType == .gradient {
                // 2B. Background Gradient (`Swatch 1 + #HEX` + `Swatch 2 + #HEX` + Magic Wand + `Hue` Slider + 30 Gradient Presets)
                let stop0Hex = session.document.background.gradient.stops.first?.color ?? "#4776E6"
                let stop1Hex = session.document.background.gradient.stops.dropFirst().first?.color ?? "#8E54E9"

                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Background Gradient")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.92))

                        HStack(spacing: 5) {
                            ColorSwatchPickerButton(
                                hexColor: Binding(
                                    get: { stop0Hex },
                                    set: { newHex in
                                        session.mutate { doc in
                                            if doc.background.gradient.stops.isEmpty {
                                                doc.background.gradient.stops = [
                                                    GradientStopConfig(color: newHex, location: 0.0),
                                                    GradientStopConfig(color: stop1Hex, location: 1.0)
                                                ]
                                            } else {
                                                doc.background.gradient.stops[0].color = newHex
                                            }
                                        }
                                    }
                                ),
                                size: 32
                            )

                            HexInputBox(
                                hexColor: Binding(
                                    get: { stop0Hex },
                                    set: { newHex in
                                        session.mutate { doc in
                                            if !doc.background.gradient.stops.isEmpty {
                                                doc.background.gradient.stops[0].color = newHex
                                            }
                                        }
                                    }
                                ),
                                width: nil,
                                height: 32
                            )

                            ColorSwatchPickerButton(
                                hexColor: Binding(
                                    get: { stop1Hex },
                                    set: { newHex in
                                        session.mutate { doc in
                                            if doc.background.gradient.stops.count < 2 {
                                                doc.background.gradient.stops = [
                                                    GradientStopConfig(color: stop0Hex, location: 0.0),
                                                    GradientStopConfig(color: newHex, location: 1.0)
                                                ]
                                            } else {
                                                doc.background.gradient.stops[1].color = newHex
                                            }
                                        }
                                    }
                                ),
                                size: 32
                            )

                            HexInputBox(
                                hexColor: Binding(
                                    get: { stop1Hex },
                                    set: { newHex in
                                        session.mutate { doc in
                                            if doc.background.gradient.stops.count >= 2 {
                                                doc.background.gradient.stops[1].color = newHex
                                            }
                                        }
                                    }
                                ),
                                width: nil,
                                height: 32
                            )

                            Button {
                                if let pair = Self.curatedGradientPairs.randomElement() {
                                    session.mutate { doc in
                                        doc.background.gradient.stops = [
                                            GradientStopConfig(color: pair.0, location: 0.0),
                                            GradientStopConfig(color: pair.1, location: 1.0)
                                        ]
                                    }
                                }
                            } label: {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 13.0, weight: .regular))
                                    .foregroundStyle(.ink.opacity(0.90))
                                    .frame(width: 32, height: 32)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.ink.opacity(0.035))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(Color.ink.opacity(0.09), lineWidth: 1)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help("Pick random gradient")
                        }
                    }

                    // `🎨 Hue` Slider (`paintpalette` + `Hue`)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 7) {
                            Image(systemName: "paintpalette")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.ink.opacity(0.90))
                            Text("Hue")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.ink.opacity(0.92))
                        }

                        Slider(
                            value: Binding(
                                get: { gradientHueShift },
                                set: { newVal in
                                    let delta = newVal - gradientHueShift
                                    gradientHueShift = newVal
                                    session.mutate { doc in
                                        let c0 = Color.shiftHue(ofHex: stop0Hex, by: delta)
                                        let c1 = Color.shiftHue(ofHex: stop1Hex, by: delta)
                                        doc.background.gradient.stops = [
                                            GradientStopConfig(color: c0, location: 0.0),
                                            GradientStopConfig(color: c1, location: 1.0)
                                        ]
                                    }
                                }
                            ),
                            in: 0.0...1.0
                        )
                        .tint(Color(red: 0.44, green: 0.34, blue: 0.98))
                        .controlSize(.regular)
                    }

                    // 8-Column Grid of 30 Curated Gradient Swatches
                    let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(Array(Self.curatedGradientPairs.enumerated()), id: \.offset) { _, pair in
                            let isSelected = (stop0Hex.caseInsensitiveCompare(pair.0) == .orderedSame && stop1Hex.caseInsensitiveCompare(pair.1) == .orderedSame)
                            Button {
                                session.mutate { doc in
                                    doc.background.gradient.stops = [
                                        GradientStopConfig(color: pair.0, location: 0.0),
                                        GradientStopConfig(color: pair.1, location: 1.0)
                                    ]
                                }
                            } label: {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [Color(hex: pair.0), Color(hex: pair.1)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .aspectRatio(1.0, contentMode: .fit)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(isSelected ? Color.ink : Color.ink.opacity(0.12), lineWidth: isSelected ? 1.5 : 0.8)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

            } else if bgType == .solid {
                // 2C. Background Color (`36×36pt` Color Swatch Picker + `#HEX` Input + Magic Wand & 5!)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Background Color")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.ink.opacity(0.92))

                    HStack(spacing: 8) {
                        ColorSwatchPickerButton(
                            hexColor: Binding(
                                get: { session.document.background.solidColor },
                                set: { hex in session.mutate { $0.background.solidColor = hex } }
                            )
                        )

                        HexInputBox(
                            hexColor: Binding(
                                get: { session.document.background.solidColor },
                                set: { hex in session.mutate { $0.background.solidColor = hex } }
                            ),
                            width: 112
                        )

                        Button {
                            if let randomHex = Self.curatedSolidColors.randomElement() {
                                session.mutate { $0.background.solidColor = randomHex }
                            }
                        } label: {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 13.5, weight: .regular))
                                .foregroundStyle(.ink.opacity(0.90))
                                .frame(width: 36, height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.ink.opacity(0.035))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.ink.opacity(0.09), lineWidth: 1)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Pick random color")
                    }
                }

            } else if bgType == .image {
                // 2D. Background Image (`Click to select, drop image, or press ⌘ V while hovering.` + `Background blur`)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Background Image")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.ink.opacity(0.92))

                    Button {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.image]
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            session.selectCustomBackgroundImage(from: url)
                        }
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "photo")
                                .font(.system(size: 22, weight: .regular))
                                .foregroundStyle(.ink.opacity(0.62))

                            Text("Click to select, drop image, or press ⌘ V while\nhovering.")
                                .font(.system(size: 12.5, weight: .regular))
                                .foregroundStyle(.ink.opacity(0.46))
                                .multilineTextAlignment(.center)
                                .lineSpacing(2)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 112)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.ink.opacity(isHoveringImageDropZone ? 0.05 : 0.025))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    isHoveringImageDropZone
                                        ? Color(red: 0.44, green: 0.34, blue: 0.98)
                                        : Color.ink.opacity(0.08),
                                    lineWidth: 1
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isHoveringImageDropZone = hovering
                    }
                    .onDrop(of: [.fileURL, .image], isTargeted: $isHoveringImageDropZone) { providers in
                        guard let first = providers.first else { return false }
                        if first.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                            first.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                                if let data = data as? Data,
                                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                                    Task { @MainActor in
                                        session.selectCustomBackgroundImage(from: url)
                                    }
                                }
                            }
                            return true
                        }
                        return false
                    }
                    .onPasteCommand(of: [.image, .fileURL]) { _ in
                        let pb = NSPasteboard.general
                        if let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
                           let firstImg = imgs.first {
                            session.selectCustomBackgroundNSImage(firstImg)
                        } else if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
                                  let firstURL = urls.first {
                            session.selectCustomBackgroundImage(from: firstURL)
                        }
                    }

                    coalescedSlider(
                        title: "Background blur",
                        value: Binding(
                            get: { session.document.background.blurRadius },
                            set: { v in session.mutate { $0.background.blurRadius = v } }
                        ),
                        range: 0...60,
                        defaultValue: 0.0,
                        showResetButton: false
                    )
                }
            }

            inspectorDivider

            // 4. Padding, Screen rounded corners & Inset toggle
            VStack(alignment: .leading, spacing: 22) {
                coalescedSlider(
                    title: "Padding",
                    value: Binding(
                        get: { session.document.canvas.paddingRatio },
                        set: { v in session.mutate { $0.canvas.paddingRatio = v } }
                    ),
                    range: 0.0...0.30,
                    defaultValue: 0.10
                )

                coalescedSlider(
                    title: "Screen rounded corners",
                    value: Binding(
                        get: { session.document.frameStyle.borderRadius },
                        set: { v in session.mutate { $0.frameStyle.borderRadius = v } }
                    ),
                    range: 0...44,
                    defaultValue: 16.0
                )

                inspectorToggleRow(
                    title: "Inset",
                    icon: nil,
                    description: "Add inset around the screen.",
                    isOn: Binding(
                        get: { session.document.frameStyle.inset.enabled },
                        set: { v in session.mutate { $0.frameStyle.inset.enabled = v } }
                    )
                )
            }

            inspectorDivider

            // 5. Shadow (`Classic` | `Directional` + `Advanced shadow settings`)
            VStack(alignment: .leading, spacing: 16) {
                coalescedSlider(
                    title: "Shadow",
                    value: Binding(
                        get: { session.document.frameStyle.shadow.intensity },
                        set: { v in session.mutate { $0.frameStyle.shadow.intensity = v } }
                    ),
                    range: 0.0...0.85,
                    defaultValue: 0.42
                )

                HStack(spacing: 6) {
                    let isDir = session.document.frameStyle.shadow.isDirectional
                    inspectorPillOptionButton(title: "Classic", isSelected: !isDir) {
                        session.mutate { $0.frameStyle.shadow.isDirectional = false }
                    }
                    inspectorPillOptionButton(title: "Directional", isSelected: isDir) {
                        session.mutate { $0.frameStyle.shadow.isDirectional = true }
                    }
                }

                inspectorCollapsibleSection(
                    title: "Advanced shadow settings",
                    isExpanded: $isAdvancedShadowSectionExpanded
                ) {
                    VStack(alignment: .leading, spacing: 18) {
                        coalescedSlider(
                            title: "Shadow Distance",
                            value: Binding(
                                get: { session.document.frameStyle.shadow.distance },
                                set: { v in session.mutate { $0.frameStyle.shadow.distance = v } }
                            ),
                            range: 0...80,
                            defaultValue: 22.0
                        )

                        coalescedSlider(
                            title: "Shadow Angle",
                            value: Binding(
                                get: { session.document.frameStyle.shadow.angleDegrees },
                                set: { v in session.mutate { $0.frameStyle.shadow.angleDegrees = v } }
                            ),
                            range: 0...180,
                            defaultValue: 90.0
                        )

                        coalescedSlider(
                            title: "Shadow Blur",
                            value: Binding(
                                get: { session.document.frameStyle.shadow.blur },
                                set: { v in session.mutate { $0.frameStyle.shadow.blur = v } }
                            ),
                            range: 0...60,
                            defaultValue: 36.0
                        )
                    }
                }
            }

            inspectorDivider

            // 6. Hide sensitive data (OCR) & Hide faces
            VStack(alignment: .leading, spacing: 16) {
                inspectorToggleRow(
                    title: "Hide sensitive data",
                    icon: "lock.fill",
                    description: "Covers emails, phone numbers, card numbers and keys shown in the recording",
                    isOn: Binding(
                        get: { session.document.background.hideSensitiveData },
                        set: { enabled in
                            withAnimation(.easeOut(duration: 0.16)) {
                                session.setHideSensitiveData(enabled: enabled)
                            }
                        }
                    )
                )

                if session.document.background.hideSensitiveData {
                    if session.isScanningSensitiveData {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Scanning recording for sensitive data on device…")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(.ink.opacity(0.75))
                        }
                    }

                    // Review Before Sharing Warning Card
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12.5, weight: .semibold))
                            Text("Review Before Sharing")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(Color(red: 0.96, green: 0.67, blue: 0.25))

                        Text("Some private details may still be visible in parts of your recording. Watch it in full before you share it.")
                            .font(.system(size: 12.0, weight: .regular))
                            .foregroundStyle(Color(red: 0.92, green: 0.64, blue: 0.28))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(red: 0.24, green: 0.18, blue: 0.11).opacity(0.55))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color(red: 0.56, green: 0.42, blue: 0.24).opacity(0.55), lineWidth: 1)
                    )

                    let hasPhrases = !session.document.background.sensitiveDataCustomPhrases.isEmpty
                    if !isEditingSensitiveCustomPhrases && !hasPhrases {
                        Button {
                            draftSensitiveCustomPhrases = session.document.background.sensitiveDataCustomPhrases.joined(separator: ", ")
                            withAnimation(.easeOut(duration: 0.14)) {
                                isEditingSensitiveCustomPhrases = true
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Add custom phrases")
                                    .font(.system(size: 12.5, weight: .medium))
                            }
                            .foregroundStyle(.ink.opacity(0.90))
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.ink.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Custom phrases")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.ink.opacity(0.92))

                            Text("Names, clients or other words, separated by commas")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(.ink.opacity(0.42))

                            TextField(
                                "Jane Appleseed, Acme Inc.",
                                text: Binding(
                                    get: {
                                        isEditingSensitiveCustomPhrases
                                            ? draftSensitiveCustomPhrases
                                            : session.document.background.sensitiveDataCustomPhrases.joined(separator: ", ")
                                    },
                                    set: { newVal in
                                        draftSensitiveCustomPhrases = newVal
                                        session.updateSensitiveDataCustomPhrases(newVal)
                                    }
                                )
                            )
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundStyle(.ink)
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.ink.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.ink.opacity(0.09), lineWidth: 1)
                            )
                            .onSubmit {
                                session.updateSensitiveDataCustomPhrases(draftSensitiveCustomPhrases)
                                if session.document.background.sensitiveDataCustomPhrases.isEmpty {
                                    isEditingSensitiveCustomPhrases = false
                                }
                            }
                        }
                    }
                }
            }

            inspectorDivider

            VStack(alignment: .leading, spacing: 14) {
                inspectorToggleRow(
                    title: "Hide faces",
                    icon: "face.dashed.fill",
                    description: "Blurs people's faces shown in the recording, like avatars and video calls",
                    isOn: Binding(
                        get: { session.document.background.hideFaces },
                        set: { enabled in
                            withAnimation(.easeOut(duration: 0.16)) {
                                session.setHideFaces(enabled: enabled)
                            }
                        }
                    )
                )

                if session.document.background.hideFaces {
                    if session.isScanningFaces {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Detecting faces in recording on device…")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(.ink.opacity(0.75))
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12.5, weight: .semibold))
                            Text("Review Before Sharing")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(Color(red: 0.96, green: 0.67, blue: 0.25))

                        Text("Some private details may still be visible in parts of your recording. Watch it in full before you share it.")
                            .font(.system(size: 12.0, weight: .regular))
                            .foregroundStyle(Color(red: 0.92, green: 0.64, blue: 0.28))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(red: 0.24, green: 0.18, blue: 0.11).opacity(0.55))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color(red: 0.56, green: 0.42, blue: 0.24).opacity(0.55), lineWidth: 1)
                    )
                }
            }
        }
    }

    // MARK: - 2. Cursor & Spring Physics Inspector (Cursor Themes + Variants)

    @ViewBuilder
    private var cursorInspector: some View {
        let cursor = session.document.cursor
        let normalizedThemeId = CursorThemePreset.normalizeThemeId(cursor.themeId)
        let activeTheme = CursorThemePreset.theme(withId: normalizedThemeId)

        VStack(alignment: .leading, spacing: 24) {
            if session.isCursorHiddenAtPreviewTime {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("Cursor is hidden in this part of the recording, so you will not see changes you make to it.")
                            .font(.system(size: 12))
                            .foregroundStyle(.ink.opacity(0.88))
                    }
                    Button {
                        session.selectedInspectorTab = .audio
                    } label: {
                        Text("Open clip settings")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(Color.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(Color.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.yellow.opacity(0.28), lineWidth: 1)
                )
            }

            if cursor.hidden {
                inspectorToggleRow(
                    title: "Hide cursor",
                    icon: "eye.slash",
                    description: nil,
                    isOn: Binding(
                        get: { session.document.cursor.hidden },
                        set: { v in session.mutate { $0.cursor.hidden = v } }
                    )
                )
            } else {
                // 1. Cursor size slider + Reset
                VStack(alignment: .leading, spacing: 6) {
                    coalescedSlider(
                        title: "Cursor size",
                        value: Binding(
                            get: { session.document.cursor.scale },
                            set: { v in session.mutate { $0.cursor.scale = v } }
                        ),
                        range: 0.5...3.5,
                        defaultValue: 1.6
                    )

                    if cursor.scale < 0.75 {
                        Text("With small cursor size, consider disabling mouse cursor motion blur as it might reduce cursor visibility")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.ink.opacity(0.45))
                    }
                }

                // 2. Cursor style (Single-row horizontal ScrollView with "App Store style" ~50% half-card peek on the right edge + auto-center on click!)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Cursor style")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.ink.opacity(0.92))

                    ScrollViewReader { scrollProxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(CursorThemePreset.allThemes) { theme in
                                    let isSelected = (normalizedThemeId == theme.id)
                                    let previewVariantId = isSelected ? cursor.variantId : nil

                                    CursorStyleHorizontalCardView(
                                        theme: theme,
                                        selectedVariantId: previewVariantId,
                                        isSelected: isSelected,
                                        cardSize: 50,
                                        iconSize: 31
                                    ) {
                                        session.mutate {
                                            $0.cursor.themeId = theme.id
                                            if !theme.pointerVariants.isEmpty {
                                                let currentVar = $0.cursor.variantId
                                                if currentVar == nil || !theme.pointerVariants.contains(where: { $0.id == currentVar }) {
                                                    $0.cursor.variantId = theme.pointerVariants.first?.id
                                                }
                                            } else {
                                                $0.cursor.variantId = nil
                                            }
                                        }
                                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                            scrollProxy.scrollTo(theme.id, anchor: .center)
                                        }
                                    }
                                    .id(theme.id)
                                }
                            }
                            .padding(.vertical, 2)
                            .padding(.trailing, 18)
                        }
                        .padding(.trailing, -18)
                        .onAppear {
                            if normalizedThemeId != CursorThemePreset.preferredOrder.first {
                                DispatchQueue.main.async {
                                    scrollProxy.scrollTo(normalizedThemeId, anchor: .center)
                                }
                            }
                        }
                        .onChange(of: normalizedThemeId) { _, newId in
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                scrollProxy.scrollTo(newId, anchor: .center)
                            }
                        }
                    }

                    // Variant Row (Shown whenever the selected cursor set has multiple variants, with ~50% half-card peek on the right edge!)
                    if !activeTheme.pointerVariants.isEmpty {
                        let activeVariantId = cursor.variantId
                            .flatMap { id in activeTheme.pointerVariants.contains(where: { $0.id == id }) ? id : nil }
                            ?? activeTheme.pointerVariants[0].id

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Variant")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.ink.opacity(0.45))

                            ScrollViewReader { variantProxy in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(activeTheme.pointerVariants) { variant in
                                            let isVarSelected = (activeVariantId == variant.id)

                                            Button {
                                                session.mutate {
                                                    $0.cursor.variantId = variant.id
                                                }
                                                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                                    variantProxy.scrollTo(variant.id, anchor: .center)
                                                }
                                            } label: {
                                                Image(nsImage: CursorSpriteProvider.shared.previewNSImage(themeId: activeTheme.id, variantId: variant.id))
                                                    .resizable()
                                                    .interpolation(.high)
                                                    .aspectRatio(contentMode: .fit)
                                                    .frame(width: 26, height: 26)
                                                    .frame(width: 48, height: 48)
                                                    .background(
                                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                            .fill(Color(white: isVarSelected ? 0.54 : 0.48))
                                                    )
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                            .strokeBorder(
                                                                isVarSelected
                                                                    ? Color(red: 0.44, green: 0.34, blue: 0.98)
                                                                    : Color.ink.opacity(0.08),
                                                                lineWidth: isVarSelected ? 1.5 : 1.0
                                                            )
                                                    )
                                                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                            }
                                            .buttonStyle(.plain)
                                            .id(variant.id)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                    .padding(.trailing, 18)
                                }
                                .padding(.trailing, -18)
                                .onAppear {
                                    if activeVariantId != activeTheme.pointerVariants.first?.id {
                                        DispatchQueue.main.async {
                                            variantProxy.scrollTo(activeVariantId, anchor: .center)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }

                // 3. Always use pointer cursor
                inspectorToggleRow(
                    title: "Always use pointer cursor",
                    icon: nil,
                    description: "Don't change cursor, even if selecting text, etc.",
                    isOn: Binding(
                        get: { session.document.cursor.alwaysUsePointer },
                        set: { v in session.mutate { $0.cursor.alwaysUsePointer = v } }
                    )
                )

                inspectorDivider

                // 4. Hide cursor if not moving + Loop cursor position + Hide cursor (`eye.slash`)
                VStack(alignment: .leading, spacing: 20) {
                    inspectorToggleRow(
                        title: "Hide cursor if not moving",
                        icon: nil,
                        description: nil,
                        isOn: Binding(
                            get: { session.document.cursor.hideWhenIdleAfterMs != nil },
                            set: { enabled in
                                session.mutate {
                                    if enabled {
                                        $0.cursor.hideWhenIdleAfterMs = lastRememberedIdleMs
                                    } else {
                                        if let current = $0.cursor.hideWhenIdleAfterMs {
                                            lastRememberedIdleMs = current
                                        }
                                        $0.cursor.hideWhenIdleAfterMs = nil
                                    }
                                }
                            }
                        )
                    )

                    if let idleMs = cursor.hideWhenIdleAfterMs {
                        coalescedSlider(
                            title: "Hide not moving cursor after",
                            value: Binding(
                                get: { idleMs / 1000.0 },
                                set: { sec in
                                    lastRememberedIdleMs = sec * 1000.0
                                    session.mutate { $0.cursor.hideWhenIdleAfterMs = sec * 1000.0 }
                                }
                            ),
                            range: 0.5...5.0,
                            defaultValue: 2.0
                        )
                    }

                    inspectorToggleRow(
                        title: "Loop cursor position",
                        icon: nil,
                        description: "Near the end of the video, cursor will move back to its initial position",
                        isOn: Binding(
                            get: { session.document.cursor.loopBackToStartMs != nil },
                            set: { enabled in
                                session.mutate {
                                    if enabled {
                                        $0.cursor.loopBackToStartMs = lastRememberedLoopMs
                                    } else {
                                        if let current = $0.cursor.loopBackToStartMs {
                                            lastRememberedLoopMs = current
                                        }
                                        $0.cursor.loopBackToStartMs = nil
                                    }
                                }
                            }
                        )
                    )

                    if let loopMs = cursor.loopBackToStartMs {
                        coalescedSlider(
                            title: "Loop cursor position duration",
                            value: Binding(
                                get: { loopMs / 1000.0 },
                                set: { sec in
                                    lastRememberedLoopMs = sec * 1000.0
                                    session.mutate { $0.cursor.loopBackToStartMs = sec * 1000.0 }
                                }
                            ),
                            range: 1.0...4.0,
                            defaultValue: 1.0
                        )
                    }

                    inspectorToggleRow(
                        title: "Hide cursor",
                        icon: "eye.slash",
                        description: nil,
                        isOn: Binding(
                            get: { session.document.cursor.hidden },
                            set: { v in session.mutate { $0.cursor.hidden = v } }
                        )
                    )
                }

                inspectorDivider

                // 5. Click effect (`None` | `Circle` | `Ripple`) & Click sound (`None` | `Soft` | `Crisp`)
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Click effect")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.ink.opacity(0.92))

                        HStack(spacing: 6) {
                            let currentVisual: ClickEffectStyle = {
                                switch cursor.clickEffect.visualStyle {
                                case .none: return .none
                                case .circle: return .circle
                                case .ripple, .pulse, .ring: return .ripple
                                }
                            }()

                            inspectorPillOptionButton(title: "None", isSelected: currentVisual == .none) {
                                session.mutate { $0.cursor.clickEffect.visualStyle = .none }
                            }
                            inspectorPillOptionButton(title: "Circle", isSelected: currentVisual == .circle) {
                                session.mutate { $0.cursor.clickEffect.visualStyle = .circle }
                            }
                            inspectorPillOptionButton(title: "Ripple", isSelected: currentVisual == .ripple) {
                                session.mutate { $0.cursor.clickEffect.visualStyle = .ripple }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Click sound")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.ink.opacity(0.92))

                        let normalizedSoundSet = CursorClickSoundPlayer.normalizedSoundSet(cursor.clickEffect.soundSet)

                        ScrollViewReader { soundProxy in
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    inspectorPillOptionButton(title: "None", isSelected: normalizedSoundSet == nil, horizontalPadding: 12) {
                                        session.mutate { $0.cursor.clickEffect.soundSet = nil }
                                        withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                                            soundProxy.scrollTo("none", anchor: .center)
                                        }
                                    }
                                    .id("none")

                                    ForEach(CursorClickSoundPlayer.soundSets, id: \.id) { sound in
                                        inspectorPillOptionButton(title: sound.title, isSelected: normalizedSoundSet == sound.id, horizontalPadding: 12) {
                                            session.mutate { $0.cursor.clickEffect.soundSet = sound.id }
                                            CursorClickSoundPlayer.shared.playClickSound(
                                                soundSet: sound.id,
                                                volume: session.document.cursor.clickEffect.soundVolume
                                            )
                                            withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                                                soundProxy.scrollTo(sound.id, anchor: .center)
                                            }
                                        }
                                        .id(sound.id)
                                    }
                                }
                                .padding(.vertical, 2)
                                .padding(.trailing, 18)
                            }
                            .padding(.trailing, -18)
                        }

                        if let activeSound = normalizedSoundSet {
                            coalescedSlider(
                                title: "Click sound volume",
                                icon: "computermouse",
                                value: Binding(
                                    get: { session.document.cursor.clickEffect.soundVolume },
                                    set: { v in session.mutate { $0.cursor.clickEffect.soundVolume = v } }
                                ),
                                range: 0.0...1.0,
                                defaultValue: 0.50
                            )

                            Button {
                                CursorClickSoundPlayer.shared.playClickSound(
                                    soundSet: activeSound,
                                    volume: session.document.cursor.clickEffect.soundVolume
                                )
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "speaker.wave.2")
                                        .font(.system(size: 13, weight: .medium))
                                    Text("Play click sound preview")
                                        .font(.system(size: 12.5, weight: .medium))
                                }
                                .foregroundStyle(.ink.opacity(0.92))
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.ink.opacity(0.04))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.ink.opacity(0.10), lineWidth: 1)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                inspectorDivider

                // 6. Collapsible `Rotation` Section
                inspectorCollapsibleSection(
                    title: "Rotation",
                    isExpanded: $isRotationSectionExpanded
                ) {
                    VStack(alignment: .leading, spacing: 16) {
                        coalescedSlider(
                            title: "Rotate cursor",
                            value: Binding(
                                get: { session.document.cursor.baseRotationDegrees },
                                set: { v in session.mutate { $0.cursor.baseRotationDegrees = v } }
                            ),
                            range: -180.0...180.0,
                            defaultValue: 0.0
                        )

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 7) {
                                Image(systemName: "cursorarrow.motionlines")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.ink.opacity(0.88))
                                Text("Rotate while moving")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.ink.opacity(0.92))
                            }

                            Text("How the cursor rotates as it chases the mouse.")
                                .font(.system(size: 12))
                                .foregroundStyle(.ink.opacity(0.45))

                            HStack(spacing: 6) {
                                ForEach(CursorRotationMode.allCases) { mode in
                                    let isSelected = (cursor.rotationMode == mode)
                                    inspectorPillOptionButton(title: mode.label, isSelected: isSelected) {
                                        session.mutate {
                                            $0.cursor.rotationMode = mode
                                            $0.cursor.velocityRotationEnabled = true
                                        }
                                    }
                                }
                                Spacer()
                            }

                            Text(cursor.rotationMode.descriptionText)
                                .font(.system(size: 12))
                                .foregroundStyle(.ink.opacity(0.45))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if cursor.rotationMode == .tilt {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Tilt amount")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.ink.opacity(0.92))
                                Text("How strongly horizontal movement leans the cursor.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.ink.opacity(0.45))

                                coalescedSliderRowOnly(
                                    value: Binding(
                                        get: { session.document.cursor.velocityRotationIntensity },
                                        set: { v in
                                            session.mutate {
                                                $0.cursor.velocityRotationIntensity = v
                                                $0.cursor.velocityRotationEnabled = (v > 0.01)
                                            }
                                        }
                                    ),
                                    range: 0.0...2.0,
                                    defaultValue: 0.5
                                )
                                .padding(.top, 3)
                            }
                        }
                    }
                }

                // 7. Collapsible `Advanced` Section
                inspectorCollapsibleSection(
                    title: "Advanced",
                    isExpanded: $isAdvancedCursorSectionExpanded
                ) {
                    VStack(alignment: .leading, spacing: 18) {
                        if cursor.loopBackToStartMs == nil {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Stop cursor movement at the end of the video")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.ink.opacity(0.92))
                                Text("Near the end of the video, the last mouse movement often leads to clicking \"Stop Recording,\" which you might not want to be visible. Adjust how long before the end of the video the mouse cursor will stop moving.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.ink.opacity(0.45))
                                    .fixedSize(horizontal: false, vertical: true)

                                coalescedSliderRowOnly(
                                    value: Binding(
                                        get: { session.document.cursor.stopMovementInLastPartMs },
                                        set: { v in session.mutate { $0.cursor.stopMovementInLastPartMs = v } }
                                    ),
                                    range: 0.0...5000.0,
                                    defaultValue: 0.0
                                )
                                .padding(.top, 2)
                            }
                        }

                        inspectorToggleRow(
                            title: "Remove cursor shakes",
                            icon: nil,
                            description: "If you use some accessibility apps that can control your mouse, it is possible those apps will cause sudden, short movements of your mouse. This option allows trying to detect and remove them.",
                            isOn: Binding(
                                get: { session.document.cursor.removeShakeThresholdPx > 0.01 },
                                set: { enabled in
                                    session.mutate {
                                        if enabled {
                                            $0.cursor.removeShakeThresholdPx = max(1.0, lastRememberedShakeThreshold)
                                        } else {
                                            if $0.cursor.removeShakeThresholdPx > 0.01 {
                                                lastRememberedShakeThreshold = $0.cursor.removeShakeThresholdPx
                                            }
                                            $0.cursor.removeShakeThresholdPx = 0.0
                                        }
                                    }
                                }
                            )
                        )

                        if cursor.removeShakeThresholdPx > 0.01 {
                            coalescedSlider(
                                title: "Remove cursor shakes threshold",
                                value: Binding(
                                    get: { session.document.cursor.removeShakeThresholdPx },
                                    set: { v in
                                        lastRememberedShakeThreshold = v
                                        session.mutate { $0.cursor.removeShakeThresholdPx = v }
                                    }
                                ),
                                range: 1.0...20.0,
                                defaultValue: 4.0
                            )
                        }

                        inspectorToggleRow(
                            title: "Optimize cursor changes",
                            icon: nil,
                            description: "NativeScreen will try to minimize rapid cursor changes (eg when quickly moving over some elements) when this option is enabled.",
                            isOn: Binding(
                                get: { session.document.cursor.optimizeCursorChanges },
                                set: { v in session.mutate { $0.cursor.optimizeCursorChanges = v } }
                            )
                        )

                        inspectorToggleRow(
                            title: "Keep cursor in sync with hovers",
                            icon: nil,
                            description: "When something lights up under the moving mouse, like a menu item or a button, the cursor gets there just in time, setting off a little earlier or moving a little faster, so the highlight never shows before the cursor does.",
                            isOn: Binding(
                                get: { session.document.cursor.keepInSyncWithHovers },
                                set: { v in session.mutate { $0.cursor.keepInSyncWithHovers = v } }
                            )
                        )
                    }
                }
            }
        }
    }

    // MARK: - 3. Animations

    @ViewBuilder
    private var zoomInspector: some View {
        let camSpring = session.document.motion.cameraSpring
        let isFocusedCam = abs(camSpring.stiffness - SpringConfig.focusedCamera.stiffness) < 10.0

        let curSpring = session.document.cursor.spring
        let isCursorSmoothEnabled = session.document.cursor.smoothMovementEnabled
        let activeCursorPresetName: String = {
            if !isCursorSmoothEnabled { return "None" }
            if abs(curSpring.stiffness - 530.0) < 15.0 { return "Rapid" }
            if abs(curSpring.stiffness - 340.0) < 15.0 { return "Medium" }
            return "Smooth"
        }()

        let screenDescriptionText: String? = {
            guard let hovered = hoveredScreenAnimPreset else { return nil }
            if hovered == "Focused" {
                return "Animation stabilizes quickly making it easier to follow and read the content"
            }
            return "Animation is more fluid. Great for more creative content not focused on reading"
        }()

        let hoveredScreenSpring: SpringConfig? = {
            guard let hovered = hoveredScreenAnimPreset else { return nil }
            return (hovered == "Focused") ? .focusedCamera : .smoothCamera
        }()

        let hoveredCursorSpring: SpringConfig? = {
            guard let hovered = hoveredCursorAnimPreset else { return nil }
            switch hovered {
            case "Smooth": return SpringConfig(stiffness: 470.0, damping: 70.0, mass: 3.0)
            case "Medium": return SpringConfig(stiffness: 340.0, damping: 60.0, mass: 3.0)
            case "Rapid":  return SpringConfig(stiffness: 530.0, damping: 40.0, mass: 1.0)
            case "None":   return SpringConfig(stiffness: 2500.0, damping: 200.0, mass: 0.2)
            default: return nil
            }
        }()

        VStack(alignment: .leading, spacing: 26) {
            // 1. Screen animation style (`Focused` | `Smooth` + Live Description & Moving Dot on Hover)
            VStack(alignment: .leading, spacing: 12) {
                Text("Screen animation style")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.ink.opacity(0.92))

                HStack(spacing: 8) {
                    animationPresetCardButton(
                        title: "Focused",
                        icon: "target",
                        isSelected: isFocusedCam,
                        width: 96,
                        height: 76,
                        onHoverChanged: { hovering in
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                hoveredScreenAnimPreset = hovering ? "Focused" : nil
                            }
                        }
                    ) {
                        session.mutate { $0.motion.cameraSpring = .focusedCamera }
                    }

                    animationPresetCardButton(
                        title: "Smooth",
                        icon: "point.topleft.down.to.point.bottomright.curvepath",
                        isSelected: !isFocusedCam,
                        width: 96,
                        height: 76,
                        onHoverChanged: { hovering in
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                hoveredScreenAnimPreset = hovering ? "Smooth" : nil
                            }
                        }
                    ) {
                        session.mutate { $0.motion.cameraSpring = .smoothCamera }
                    }

                    Spacer()
                }

                if let desc = screenDescriptionText, let spring = hoveredScreenSpring {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(desc)
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.48))
                            .fixedSize(horizontal: false, vertical: true)

                        SpringPhysicsDemoDotView(spring: spring)
                            .id("screen_dot_\(hoveredScreenAnimPreset ?? "")")
                    }
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            // 2. Cursor animation style (`Smooth` | `Medium` | `Rapid` | `None` + Moving Dot on Hover)
            VStack(alignment: .leading, spacing: 12) {
                Text("Cursor animation style")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.ink.opacity(0.92))

                HStack(spacing: 8) {
                    animationPresetCardButton(
                        title: "Smooth",
                        icon: "cursorarrow.click.2",
                        isSelected: activeCursorPresetName == "Smooth",
                        width: nil,
                        height: 74,
                        onHoverChanged: { hovering in
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                hoveredCursorAnimPreset = hovering ? "Smooth" : nil
                            }
                        }
                    ) {
                        session.mutate {
                            $0.cursor.smoothMovementEnabled = true
                            $0.cursor.spring = SpringConfig(stiffness: 470.0, damping: 70.0, mass: 3.0)
                        }
                    }

                    animationPresetCardButton(
                        title: "Medium",
                        icon: "cursorarrow.click",
                        isSelected: activeCursorPresetName == "Medium",
                        width: nil,
                        height: 74,
                        onHoverChanged: { hovering in
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                hoveredCursorAnimPreset = hovering ? "Medium" : nil
                            }
                        }
                    ) {
                        session.mutate {
                            $0.cursor.smoothMovementEnabled = true
                            $0.cursor.spring = SpringConfig(stiffness: 340.0, damping: 60.0, mass: 3.0)
                        }
                    }

                    animationPresetCardButton(
                        title: "Rapid",
                        icon: "cursorarrow.motionlines",
                        isSelected: activeCursorPresetName == "Rapid",
                        width: nil,
                        height: 74,
                        onHoverChanged: { hovering in
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                hoveredCursorAnimPreset = hovering ? "Rapid" : nil
                            }
                        }
                    ) {
                        session.mutate {
                            $0.cursor.smoothMovementEnabled = true
                            $0.cursor.spring = SpringConfig(stiffness: 530.0, damping: 40.0, mass: 1.0)
                        }
                    }

                    animationPresetCardButton(
                        title: "None",
                        icon: "cursorarrow",
                        isSelected: activeCursorPresetName == "None",
                        width: nil,
                        height: 74,
                        onHoverChanged: { hovering in
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                hoveredCursorAnimPreset = hovering ? "None" : nil
                            }
                        }
                    ) {
                        session.mutate {
                            $0.cursor.smoothMovementEnabled = false
                        }
                    }
                }

                if let spring = hoveredCursorSpring {
                    SpringPhysicsDemoDotView(spring: spring)
                        .id("cursor_dot_\(hoveredCursorAnimPreset ?? "")")
                        .padding(.top, 4)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            inspectorDivider

            // 3. Motion blur (`0.0 ... 1.0`, default = `1.0` max & 4!)
            VStack(alignment: .leading, spacing: 8) {
                Text("Motion blur")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.ink.opacity(0.92))

                Text("Elements that are moving will have a cinematic motion blur effect applied")
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)

                Slider(
                    value: Binding(
                        get: { min(1.0, max(0.0, session.document.motion.motionBlurIntensity)) },
                        set: { v in session.mutate { $0.motion.motionBlurIntensity = v } }
                    ),
                    in: 0.0...1.0
                ) { editing in
                    if editing {
                        session.beginInteractiveEdit()
                    } else {
                        session.endInteractiveEdit()
                    }
                }
                .tint(Color(red: 0.44, green: 0.34, blue: 0.98))
                .controlSize(.regular)
                .padding(.top, 4)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: hoveredScreenAnimPreset)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: hoveredCursorAnimPreset)
    }

    @ViewBuilder
    private func animationPresetCardButton(
        title: String,
        icon: String,
        isSelected: Bool,
        width: CGFloat?,
        height: CGFloat,
        onHoverChanged: @escaping (Bool) -> Void,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.ink.opacity(isSelected ? 0.98 : 0.88))

                Text(title)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.ink.opacity(isSelected ? 0.98 : 0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, width == nil ? 9 : 14)
            .frame(width: width, height: height, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.ink.opacity(isSelected ? 0.075 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? Color(red: 0.44, green: 0.34, blue: 0.98)
                            : Color.ink.opacity(0.05),
                        lineWidth: isSelected ? 1.3 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            onHoverChanged(hovering)
        }
    }

    // MARK: - 4. Multi-Track Masks & Sensitive Data Blur Inspector

    @ViewBuilder
    private var masksInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Masks stay locked to the source clip coordinates (even while zooming). Drag or resize directly on the preview.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            // Non-truncating 3-button row
            HStack(spacing: 6) {
                Button {
                    session.addMaskAtPlayhead(type: .blur, style: .gaussian)
                } label: {
                    Label("Blur", systemImage: "eye.slash.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.62, green: 0.23, blue: 0.44))

                Button {
                    session.addMaskAtPlayhead(type: .blur, style: .pixelate)
                } label: {
                    Label("Pixelate", systemImage: "square.grid.3x3.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)

                Button {
                    session.addMaskAtPlayhead(type: .spotlight, style: .dim)
                } label: {
                    Label("Spotlight", systemImage: "flashlight.on.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }

            let activeOrSelectedMaskId = session.selectedMaskId
                ?? session.activeMaskIdAtPreviewTime
                ?? session.document.timeline.maskTracks.first?.items.first?.id

            if let maskId = activeOrSelectedMaskId,
               let mask = findMask(byId: maskId) {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Mask Mode")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Picker("", selection: Binding(
                        get: { mask.type },
                        set: { newType in
                            updateMask(id: maskId) {
                                $0.type = newType
                                if newType == .spotlight && ($0.intensity < 5.0 || $0.intensity > 95.0) {
                                    $0.intensity = 50.0
                                }
                            }
                        }
                    )) {
                        Text("Sensitive data").tag(MaskType.blur)
                        Text("Highlight").tag(MaskType.spotlight)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if mask.type == .blur {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Blur Filter Style")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        Picker("", selection: Binding(
                            get: { mask.style },
                            set: { newStyle in updateMask(id: maskId) { $0.style = newStyle } }
                        )) {
                            Text("Gaussian").tag(MaskStyle.gaussian)
                            Text("Pixelate").tag(MaskStyle.pixelate)
                            Text("Solid").tag(MaskStyle.solid)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    coalescedSlider(
                        title: "Blur intensity",
                        value: Binding(
                            get: { mask.intensity },
                            set: { v in updateMask(id: maskId) { $0.intensity = v } }
                        ),
                        range: 4...160,
                        defaultValue: 36.0
                    )
                } else {
                    coalescedSlider(
                        title: String(format: "Highlight intensity (%d%%)", Int(round(mask.intensity))),
                        value: Binding(
                            get: { mask.intensity },
                            set: { v in updateMask(id: maskId) { $0.intensity = v } }
                        ),
                        range: 0...95,
                        defaultValue: 50.0
                    )
                }

                coalescedSlider(
                    title: "Corner radius",
                    value: Binding(
                        get: { mask.cornerRadius },
                        set: { v in updateMask(id: maskId) { $0.cornerRadius = v } }
                    ),
                    range: 0...120,
                    defaultValue: 12.0
                )

                Button(role: .destructive) {
                    session.deleteMask(maskId: maskId)
                } label: {
                    Label("Delete Mask Region", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - 5. Audio Inspector

    @ViewBuilder
    private var audioAndSliceInspector: some View {
        let isCameraVisibleAndMicMuted = session.document.camera.enabled && session.document.audio.muteMicrophone

        VStack(alignment: .leading, spacing: 24) {
            // 1. Microphone Section
            VStack(alignment: .leading, spacing: 14) {
                Text("Microphone")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.ink.opacity(0.45))

                inspectorToggleRow(
                    title: "Mute microphone",
                    icon: nil,
                    description: nil,
                    isOn: Binding(
                        get: { session.document.audio.muteMicrophone },
                        set: { v in session.mutate { $0.audio.muteMicrophone = v } }
                    )
                )

                if !session.document.audio.muteMicrophone {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Microphone audio mode")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.92))

                        ScrollViewReader { scrollProxy in
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(MicrophoneAudioPreset.allCases) { preset in
                                        inspectorPillOptionButton(
                                            title: preset.label,
                                            isSelected: session.document.audio.microphoneAudioPreset == preset
                                        ) {
                                            session.mutate { $0.audio.microphoneAudioPreset = preset }
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                                scrollProxy.scrollTo(preset.id, anchor: .center)
                                            }
                                        }
                                        .id(preset.id)
                                    }
                                }
                                .padding(.vertical, 1)
                            }
                            .onAppear {
                                scrollProxy.scrollTo(session.document.audio.microphoneAudioPreset.id, anchor: .center)
                            }
                        }

                        Text(session.document.audio.microphoneAudioPreset.descriptionText)
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.42))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if isCameraVisibleAndMicMuted {
                    // Warning Card + `Hide camera` Button from
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Color(red: 0.96, green: 0.67, blue: 0.25))

                        Text("Your selfie camera video is still visible, but it will be muted. Consider hiding it in camera settings.")
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundStyle(Color(red: 0.92, green: 0.64, blue: 0.28))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(red: 0.24, green: 0.18, blue: 0.11).opacity(0.55))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color(red: 0.56, green: 0.42, blue: 0.24).opacity(0.55), lineWidth: 1)
                    )

                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            session.mutate { $0.camera.enabled = false }
                        }
                    } label: {
                        Text("Hide camera")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.ink.opacity(0.92))
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.ink.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("Microphone is muted.")
                            .font(.system(size: 12.5, weight: .regular))
                    }
                    .foregroundStyle(Color(red: 0.92, green: 0.64, blue: 0.28))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(red: 0.24, green: 0.18, blue: 0.11).opacity(0.45))
                    )
                }
            }

            inspectorDivider

            // 2. System audio section
            VStack(alignment: .leading, spacing: 14) {
                Text("System audio")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.ink.opacity(0.45))

                inspectorToggleRow(
                    title: "Mute system audio",
                    icon: nil,
                    description: nil,
                    isOn: Binding(
                        get: { session.document.audio.muteSystemAudio },
                        set: { v in session.mutate { $0.audio.muteSystemAudio = v } }
                    )
                )

                if session.document.audio.muteSystemAudio {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("System audio is muted.")
                            .font(.system(size: 12.5, weight: .regular))
                    }
                    .foregroundStyle(Color(red: 0.92, green: 0.64, blue: 0.28))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(red: 0.24, green: 0.18, blue: 0.11).opacity(0.45))
                    )
                }
            }

            inspectorDivider

            // 3. Background audio section
            VStack(alignment: .leading, spacing: 14) {
                Text("Background audio")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.ink.opacity(0.45))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(["Lo-Fi", "Commercial", "Electronic", "Instrumental"], id: \.self) { genre in
                            inspectorPillOptionButton(title: genre, isSelected: selectedAudioGenre == genre) {
                                selectedAudioGenre = genre
                            }
                        }
                    }
                }

                let genreTracks: [String] = {
                    switch selectedAudioGenre {
                    case "Commercial": return ["Upbeat Spark", "Warm Horizon", "Bright Lounge", "Lean Groove"]
                    case "Electronic": return ["Pulse Drive", "Lean Groove", "Midnight Study", "Sunny Lo-Fi"]
                    case "Instrumental": return ["Velvet Keys", "Soft Rain", "Warm Horizon", "Chill Hop"]
                    default: return ["Sunny Lo-Fi", "Lean Groove", "Bright Lounge", "Chill Hop"]
                    }
                }()

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(genreTracks, id: \.self) { trackName in
                            let isSelected = (session.document.audio.backgroundMusic.relativePath == trackName)
                            let isTrackLoading = (session.loadingBackgroundAudioTrackName == trackName)
                            inspectorPillOptionButton(
                                title: trackName,
                                isSelected: isSelected,
                                isLoading: isTrackLoading
                            ) {
                                session.selectBuiltInBackgroundTrack(trackName)
                            }
                        }
                    }
                }

                inspectorDivider

                if let selectedTrack = session.document.audio.backgroundMusic.relativePath {
                    let displayTrackTitle = URL(fileURLWithPath: selectedTrack).deletingPathExtension().lastPathComponent
                        .replacingOccurrences(of: "bg-", with: "")
                    let isPreparingSelectedTrack = (session.loadingBackgroundAudioTrackName == selectedTrack)

                    // Play / Stop Preview Button
                    Button {
                        session.toggleBackgroundAudioPreview()
                    } label: {
                        HStack(spacing: 8) {
                            ZStack {
                                if isPreparingSelectedTrack {
                                    ProgressView()
                                        .controlSize(.small)
                                        .scaleEffect(0.75)
                                        .transition(.opacity)
                                } else {
                                    Image(systemName: session.isPreviewingBackgroundAudio ? "stop.circle" : "play.circle")
                                        .font(.system(size: 14, weight: .medium))
                                        .transition(.opacity)
                                }
                            }
                            .frame(width: 15, height: 15)
                            .animation(.easeInOut(duration: 0.18), value: isPreparingSelectedTrack)

                            Text("\(session.isPreviewingBackgroundAudio ? "Stop" : "Play") \(displayTrackTitle)")
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(Color(red: 0.65, green: 0.56, blue: 1.0))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color(red: 0.302, green: 0.184, blue: 0.961).opacity(0.16))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color(red: 0.44, green: 0.34, blue: 0.98).opacity(0.45), lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    inspectorToggleRow(
                        title: "Mute background audio",
                        icon: nil,
                        description: nil,
                        isOn: Binding(
                            get: { session.document.audio.backgroundMusic.muted },
                            set: { v in
                                session.mutate { $0.audio.backgroundMusic.muted = v }
                                if v {
                                    session.stopBackgroundAudioPreview()
                                }
                            }
                        )
                    )

                    if !session.document.audio.backgroundMusic.muted {
                        coalescedSlider(
                            title: "Background audio volume",
                            icon: "hifispeaker",
                            value: Binding(
                                get: { session.document.audio.backgroundMusic.volume },
                                set: { v in
                                    session.mutate { $0.audio.backgroundMusic.volume = v }
                                    session.updateBackgroundAudioPreviewVolume()
                                }
                            ),
                            range: 0.0...1.0,
                            defaultValue: 0.08
                        )
                    }

                    Button {
                        session.stopBackgroundAudioPreview()
                        session.mutate { $0.audio.backgroundMusic.relativePath = nil }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "hifispeaker.badge.minus")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("Remove background audio")
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.ink.opacity(0.88))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.ink.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.audio]
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            session.importCustomBackgroundAudioFile(from: url)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "hifispeaker.badge.plus")
                                .font(.system(size: 13.5, weight: .medium))
                            Text("Add background audio")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(Color(red: 0.65, green: 0.56, blue: 1.0))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.ink.opacity(0.035))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            inspectorDivider

            // 4. Voiceovers Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Voiceovers")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.ink.opacity(0.45))

                HStack(spacing: 8) {
                    Button {
                        session.startVoiceoverRecording()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: session.isRecordingVoiceover ? "stop.circle.fill" : "record.circle")
                                .font(.system(size: 13.5, weight: .semibold))
                            Text(session.isRecordingVoiceover ? "Stop Recording" : "Record voiceover")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .foregroundStyle(session.isRecordingVoiceover ? Color.ink : Color(red: 1.0, green: 0.45, blue: 0.45))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(session.isRecordingVoiceover ? Color.red : Color.red.opacity(0.14))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        session.promptImportVoiceoverAudioFile()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform.badge.plus")
                                .font(.system(size: 13.0, weight: .medium))
                            Text("Upload audio…")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .foregroundStyle(.ink.opacity(0.90))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.ink.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 5B. Camera Layout Inspector

    @ViewBuilder
    private var cameraLayoutInspector: some View {
        let cam = session.document.camera
        let isHidden = !cam.enabled

        VStack(alignment: .leading, spacing: 22) {
            // 1. `Hide camera` Toggle (`eye.slash`)
            inspectorToggleRow(
                title: "Hide camera",
                icon: "eye.slash",
                description: nil,
                isOn: Binding(
                    get: { isHidden },
                    set: { hide in
                        session.mutate { $0.camera.enabled = !hide }
                    }
                )
            )

            if !isHidden {
                inspectorDivider

                // 2. `Default layout` Cards (`Camera overlay` | `Split screen` | `Camera cutout` & 5!)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Default layout")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.ink.opacity(0.92))

                    HStack(spacing: 8) {
                        ForEach(CameraLayoutMode.allCases) { mode in
                            cameraLayoutThumbnailCard(
                                mode: mode,
                                isSelected: cam.layoutMode == mode
                            ) {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    session.mutate { $0.camera.layoutMode = mode }
                                }
                            }
                        }
                    }
                }

                inspectorDivider

                // 3. `Camera Position` 8-Point Perimeter Dot Grid ( & 5!)
                if cam.layoutMode == .overlay {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Camera Position")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.92))

                        CameraPerimeterPositionGridPicker(
                            position01: Binding(
                                get: { cam.position01 },
                                set: { pt in
                                    session.mutate { $0.camera.position01 = pt }
                                }
                            )
                        )
                    }

                    inspectorDivider

                    // 4. `Camera aspect ratio` (`16:9` | `4:3` | `1:1` | `3:4` | `9:16` & 5!)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Camera aspect ratio")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.92))

                        HStack(spacing: 6) {
                            ForEach(CameraAspectRatioPreset.allCases) { preset in
                                inspectorPillOptionButton(
                                    title: preset.rawValue,
                                    isSelected: cam.aspectRatioPreset == preset,
                                    horizontalPadding: 11
                                ) {
                                    session.mutate { $0.camera.aspectRatioPreset = preset }
                                }
                            }
                        }
                    }

                    // 5. `Camera Size` Slider + Reset
                    coalescedSlider(
                        title: "Camera Size",
                        value: Binding(
                            get: { cam.sizeRatio },
                            set: { v in session.mutate { $0.camera.sizeRatio = v } }
                        ),
                        range: 0.15...0.75,
                        defaultValue: 0.56
                    )

                    // 6. `Camera size during zoom` Collapsible Section (`magnifyingglass.circle` & 5!)
                    inspectorCollapsibleSection(
                        title: "Camera size during zoom",
                        icon: "magnifyingglass.circle",
                        isExpanded: $isCameraSizeDuringZoomExpanded
                    ) {
                        VStack(alignment: .leading, spacing: 14) {
                            inspectorToggleRow(
                                title: "Make smaller during zoom",
                                icon: nil,
                                description: "When zooming in, the camera will shrink to avoid covering the recording itself.",
                                isOn: Binding(
                                    get: { cam.makeSmallerDuringZoom },
                                    set: { v in session.mutate { $0.camera.makeSmallerDuringZoom = v } }
                                )
                            )

                            if cam.makeSmallerDuringZoom {
                                coalescedSlider(
                                    title: "Size during zoom",
                                    value: Binding(
                                        get: { cam.scaleWhenZoomed },
                                        set: { v in session.mutate { $0.camera.scaleWhenZoomed = v } }
                                    ),
                                    range: 0.25...0.85,
                                    defaultValue: 0.66
                                )
                            }
                        }
                    }
                } else if cam.layoutMode == .splitScreen {
                    // 1. `Split ratio` 3-Card Picker
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Split ratio")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.92))

                        SplitScreenRatioCardsPicker(
                            ratio01: Binding(
                                get: { cam.splitScreenRatio01 },
                                set: { newRatio in
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                                        session.mutate { $0.camera.splitScreenRatio01 = newRatio }
                                    }
                                }
                            ),
                            isFlipped: cam.splitFlip
                        )
                    }

                    // 2. `Flip` Toggle
                    inspectorToggleRow(
                        title: "Flip",
                        icon: nil,
                        description: "If enabled, the layout will be flipped.",
                        isOn: Binding(
                            get: { cam.splitFlip },
                            set: { v in
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                                    session.mutate { $0.camera.splitFlip = v }
                                }
                            }
                        )
                    )

                    // 3. `Fill`
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Fill")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.ink.opacity(0.92))

                            Text(
                                cam.splitEnablePadding
                                    ? "Has padding around and between screen and camera"
                                    : "Split layout fills the entire screen."
                            )
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.42))
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 6)

                        HStack(spacing: 6) {
                            inspectorPillOptionButton(
                                title: "Fullscreen",
                                isSelected: !cam.splitEnablePadding,
                                horizontalPadding: 11
                            ) {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                                    session.mutate { $0.camera.splitEnablePadding = false }
                                }
                            }

                            inspectorPillOptionButton(
                                title: "Padded",
                                isSelected: cam.splitEnablePadding,
                                horizontalPadding: 11
                            ) {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                                    session.mutate {
                                        $0.camera.splitEnablePadding = true
                                        if $0.canvas.paddingRatio < 0.01 {
                                            $0.canvas.paddingRatio = 0.10
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // 4. `Padding` Slider with 3D Cube Icon Badge when `Padded` is selected
                    if cam.splitEnablePadding {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color.ink.opacity(0.06))
                                        .frame(width: 24, height: 22)
                                    Image(systemName: "cube.transparent")
                                        .font(.system(size: 11.5, weight: .regular))
                                        .foregroundStyle(.ink.opacity(0.75))
                                }
                                .help("Padding value is shared across all layouts in the project.")

                                Text("Padding")
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(.ink.opacity(0.92))
                            }

                            coalescedSliderRowOnly(
                                value: Binding(
                                    get: { session.document.canvas.paddingRatio },
                                    set: { v in session.mutate { $0.canvas.paddingRatio = v } }
                                ),
                                range: 0.0...0.40,
                                defaultValue: 0.10
                            )
                        }
                    }
                } else if cam.layoutMode == .cutout {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Camera Position")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.92))

                        CameraCutoutPositionDotBarPicker(
                            positionX01: Binding(
                                get: { cam.cutoutPositionX01 },
                                set: { xVal in
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                                        session.mutate { $0.camera.cutoutPositionX01 = xVal }
                                    }
                                }
                            )
                        )
                    }

                    inspectorDivider

                    coalescedSlider(
                        title: "Camera Size",
                        value: Binding(
                            get: { cam.sizeRatio },
                            set: { v in session.mutate { $0.camera.sizeRatio = v } }
                        ),
                        range: 0.20...0.95,
                        defaultValue: 0.56
                    )

                    inspectorCollapsibleSection(
                        title: "Camera size during zoom",
                        icon: "magnifyingglass.circle",
                        isExpanded: $isCameraSizeDuringZoomExpanded
                    ) {
                        VStack(alignment: .leading, spacing: 14) {
                            inspectorToggleRow(
                                title: "Make smaller during zoom",
                                icon: nil,
                                description: "When zooming in, the camera will shrink to avoid covering the recording itself.",
                                isOn: Binding(
                                    get: { cam.makeSmallerDuringZoom },
                                    set: { v in session.mutate { $0.camera.makeSmallerDuringZoom = v } }
                                )
                            )

                            if cam.makeSmallerDuringZoom {
                                coalescedSlider(
                                    title: "Size during zoom",
                                    value: Binding(
                                        get: { cam.scaleWhenZoomed },
                                        set: { v in session.mutate { $0.camera.scaleWhenZoomed = v } }
                                    ),
                                    range: 0.25...0.85,
                                    defaultValue: 0.66
                                )
                            }
                        }
                    }

                    inspectorDivider

                    // `Edge softness` & `Edge inset` with 3D Cube Icon Badges
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.ink.opacity(0.06))
                                    .frame(width: 24, height: 22)
                                Image(systemName: "cube.transparent")
                                    .font(.system(size: 11.5, weight: .regular))
                                    .foregroundStyle(.ink.opacity(0.75))
                            }
                            Text("Edge softness")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.ink.opacity(0.92))
                        }

                        coalescedSliderRowOnly(
                            value: Binding(
                                get: { cam.cutoutEdgeSoftness },
                                set: { v in session.mutate { $0.camera.cutoutEdgeSoftness = v } }
                            ),
                            range: 0.0...1.0,
                            defaultValue: 0.20
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.ink.opacity(0.06))
                                    .frame(width: 24, height: 22)
                                Image(systemName: "cube.transparent")
                                    .font(.system(size: 11.5, weight: .regular))
                                    .foregroundStyle(.ink.opacity(0.75))
                            }
                            Text("Edge inset")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.ink.opacity(0.92))
                        }

                        coalescedSliderRowOnly(
                            value: Binding(
                                get: { cam.cutoutEdgeInset },
                                set: { v in session.mutate { $0.camera.cutoutEdgeInset = v } }
                            ),
                            range: 0.0...1.0,
                            defaultValue: 0.0
                        )
                    }

                    inspectorDivider

                    inspectorToggleRow(
                        title: "Avoid empty area",
                        icon: nil,
                        description: "Will try to avoid showing too much empty space around the recording",
                        isOn: Binding(
                            get: { cam.cutoutAvoidEmptyArea },
                            set: { v in session.mutate { $0.camera.cutoutAvoidEmptyArea = v } }
                        )
                    )
                }

                inspectorDivider

                // 7. `Camera rounded corners` & `Hide during silence`
                let showCameraRoundedCorners = (cam.layoutMode == .overlay)
                    || (cam.layoutMode == .splitScreen && cam.splitEnablePadding)
                if showCameraRoundedCorners {
                    coalescedSlider(
                        title: "Camera rounded corners",
                        value: Binding(
                            get: { cam.borderRadiusRatio },
                            set: { v in session.mutate { $0.camera.borderRadiusRatio = v } }
                        ),
                        range: 0.0...0.50,
                        defaultValue: 0.22
                    )

                    if cam.layoutMode == .splitScreen && session.document.canvas.paddingRatio <= 0.005 {
                        Text("For split screen layout, when padding is 0, the camera border radius will only be applied during zoom.")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.42))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    inspectorDivider
                }

                inspectorToggleRow(
                    title: "Hide during silence",
                    icon: "person.wave.2.fill",
                    description: "Hide the camera during silence.",
                    isOn: Binding(
                        get: { cam.hideDuringSilenceMs != nil },
                        set: { enabled in
                            session.mutate { $0.camera.hideDuringSilenceMs = enabled ? 5000.0 : nil }
                        }
                    )
                )

                if let minSil = cam.hideDuringSilenceMs {
                    coalescedSlider(
                        title: "Minimum silence duration (\(String(format: "%.1fs", minSil / 1000.0)))",
                        value: Binding(
                            get: { minSil },
                            set: { v in session.mutate { $0.camera.hideDuringSilenceMs = v } }
                        ),
                        range: 2000.0...15000.0,
                        defaultValue: 5000.0
                    )
                }
            }
        }
    }

    // MARK: - 5C. Camera Style Inspector

    @ViewBuilder
    private var cameraStyleInspector: some View {
        let _ = webcamThumbnailRevision
        let cam = session.document.camera
        let hasCrop = (cam.cropRect01 != .full)

        VStack(alignment: .leading, spacing: 22) {
            // 1. `Color grading` 7x2 Thumbnail Grid (`Original` + 12 Filmic Looks + Custom Presets + `+` Menu Button)
            VStack(alignment: .leading, spacing: 10) {
                Text("Color grading")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.92))

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7),
                    spacing: 6
                ) {
                    ForEach(CameraColorGradePreset.allCases) { preset in
                        let isSelected = (cam.selectedCustomColorPresetID == nil && cam.colorGradePreset == preset)
                        Button {
                            session.mutate {
                                $0.camera.selectedCustomColorPresetID = nil
                                $0.camera.colorGradePreset = preset
                            }
                        } label: {
                            Image(
                                nsImage: GradedWebcamPortraitView.cachedGradedPortraitImage(
                                    preset: preset,
                                    intensity: 1.0,
                                    sharpen01: 0.0
                                )
                            )
                            .resizable()
                            .scaledToFill()
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? Color.ink.opacity(0.95) : Color.ink.opacity(0.10),
                                        lineWidth: isSelected ? 1.5 : 1.0
                                    )
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(preset.rawValue)
                    }

                    ForEach(cam.customColorPresets) { custom in
                        let isSelected = (cam.selectedCustomColorPresetID == custom.id)
                        Button {
                            session.mutate {
                                $0.camera.selectedCustomColorPresetID = custom.id
                            }
                        } label: {
                            Image(
                                nsImage: GradedWebcamPortraitView.cachedGradedCustomPresetImage(
                                    customPreset: custom
                                )
                            )
                            .resizable()
                            .scaledToFill()
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? Color.ink.opacity(0.95) : Color.ink.opacity(0.10),
                                        lineWidth: isSelected ? 1.5 : 1.0
                                    )
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(custom.name)
                    }

                    // `+` Menu Button (`Create your color preset...` & `Load your LUT file...`)
                    Menu {
                        Button("Create your color preset...") {
                            ProjectWorkspaceStore.shared.presentColorPresetStudioWindow(for: session)
                        }

                        Button("Load your LUT file...") {
                            let panel = NSOpenPanel()
                            panel.title = "Choose a 3D LUT (.cube) file"
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                session.mutate {
                                    $0.camera.customLUTRelativePath = url.lastPathComponent
                                    $0.camera.selectedCustomColorPresetID = nil
                                    $0.camera.colorGradePreset = .cinema
                                }
                            }
                        }
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.ink.opacity(0.04))
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.ink.opacity(0.14), lineWidth: 1.0)
                            Image(systemName: "plus")
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(.ink.opacity(0.88))
                        }
                        .frame(width: 36, height: 36)
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                if cam.colorGradePreset != .original || cam.selectedCustomColorPresetID != nil {
                    coalescedSlider(
                        title: "Color grading intensity",
                        value: Binding(
                            get: { cam.colorGradeIntensity },
                            set: { v in session.mutate { $0.camera.colorGradeIntensity = v } }
                        ),
                        range: 0.0...1.0,
                        defaultValue: 1.0
                    )
                    .padding(.top, 4)
                }
            }

            // 2. `Sharpen` (`circle.hexagongrid`)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "circle.hexagongrid")
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(.ink.opacity(0.88))
                    Text("Sharpen")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.ink.opacity(0.92))
                }

                coalescedSliderRowOnly(
                    value: Binding(
                        get: { cam.sharpen01 },
                        set: { v in session.mutate { $0.camera.sharpen01 = v } }
                    ),
                    range: 0.0...1.0,
                    defaultValue: 0.0
                )
            }

            inspectorDivider

            // 3. `Crop` (`crop` + `"Crop camera"` / `"Edit crop"` + `"Reset"` — Opens Standalone Camera Crop Window)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "crop")
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(.ink.opacity(0.88))
                    Text("Crop")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.ink.opacity(0.92))
                }

                HStack(spacing: 8) {
                    Button {
                        ProjectWorkspaceStore.shared.presentCameraCropWindow(for: session)
                    } label: {
                        Text(hasCrop ? "Edit crop" : "Crop camera")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.92))
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.ink.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    if hasCrop {
                        Button {
                            session.mutate { $0.camera.cropRect01 = .full }
                        } label: {
                            Text("Reset")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.ink.opacity(0.85))
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.ink.opacity(0.04))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            inspectorDivider

            // 4. `Mirror horizontally` & `Face tracking` (100% On-Device Vision)
            inspectorToggleRow(
                title: "Mirror horizontally",
                icon: nil,
                description: nil,
                isOn: Binding(
                    get: { cam.mirror },
                    set: { v in session.mutate { $0.camera.mirror = v } }
                )
            )

            inspectorToggleRow(
                title: "Face tracking",
                icon: "person.fill.viewfinder",
                description: "NativeScreen will adjust the camera picture to center it on your face. Done locally, no data is sent to the server.",
                isOn: Binding(
                    get: { cam.enableFaceTracking },
                    set: { v in session.mutate { $0.camera.enableFaceTracking = v } }
                )
            )

            inspectorDivider

            // 5. `Advanced` (`Camera delay` -200ms ... +200ms)
            inspectorCollapsibleSection(
                title: "Advanced",
                isExpanded: $isAdvancedCameraStyleExpanded
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.and.person.filled")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.85))
                        Text("Camera delay (\(Int(round(cam.delayAdjustmentMs))) ms)")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.92))
                    }

                    Text("If your lips look out of sync with your voice, raise it when they move after the words, lower it when they move before.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.ink.opacity(0.42))
                        .fixedSize(horizontal: false, vertical: true)

                    coalescedSliderRowOnly(
                        value: Binding(
                            get: { cam.delayAdjustmentMs },
                            set: { v in session.mutate { $0.camera.delayAdjustmentMs = (v / 5.0).rounded() * 5.0 } }
                        ),
                        range: -200.0...200.0,
                        defaultValue: 0.0
                    )
                }
            }
        }
        .onAppear {
            if let url = session.webcamVideoFileURL {
                GradedWebcamPortraitView.preloadFirstFrameIfNeeded(from: url) {
                    webcamThumbnailRevision &+= 1
                }
            }
        }
    }

    // MARK: - 5D. Captions Inspector

    @ViewBuilder
    private var captionsInspector: some View {
        let cap = session.document.captions
        let hasTranscript = !cap.segments.isEmpty

        VStack(alignment: .leading, spacing: 22) {
            if hasTranscript {
                // 1. `Captions` Header + `Disable captions` Toggle
                VStack(alignment: .leading, spacing: 14) {
                    Text("Captions")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.ink.opacity(0.45))

                    inspectorToggleRow(
                        title: "Disable captions",
                        icon: nil,
                        description: nil,
                        isOn: Binding(
                            get: { !cap.enabled },
                            set: { disabled in
                                session.mutate { $0.captions.enabled = !disabled }
                            }
                        )
                    )
                }

                if cap.enabled {
                    // 2. `Caption size` Slider + Reset (`0.02 ... 0.125`, default `0.045`)
                    coalescedSlider(
                        title: "Caption size",
                        value: Binding(
                            get: { cap.fontSizeRatio },
                            set: { v in session.mutate { $0.captions.fontSizeRatio = v } }
                        ),
                        range: 0.02...0.10,
                        defaultValue: 0.045
                    )

                    // 3. `Font style` (`Sans-serif` | `Serif` | `Mono`)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Font style")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.92))

                        HStack(spacing: 6) {
                            ForEach(CaptionFontStyle.allCases) { style in
                                inspectorPillOptionButton(
                                    title: style.label,
                                    isSelected: cap.fontStyle == style
                                ) {
                                    session.mutate { $0.captions.fontStyle = style }
                                }
                            }
                        }
                    }

                    // 4. `Word reveal` (`Line by line` | `Word by word`)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Word reveal")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.92))

                        HStack(spacing: 6) {
                            ForEach(CaptionWordsReveal.allCases) { mode in
                                inspectorPillOptionButton(
                                    title: mode.label,
                                    isSelected: cap.wordsReveal == mode
                                ) {
                                    session.mutate { $0.captions.wordsReveal = mode }
                                }
                            }
                        }

                        Text(cap.wordsReveal.descriptionText)
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.42))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // 5. `Line growth` (`Full line` | `Expanding` | `Centered`)
                    if cap.wordsReveal == .lineByLine {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Line growth")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.ink.opacity(0.92))

                            HStack(spacing: 6) {
                                ForEach(CaptionLineGrowth.allCases) { growth in
                                    inspectorPillOptionButton(
                                        title: growth.label,
                                        isSelected: cap.lineGrowth == growth
                                    ) {
                                        session.mutate { $0.captions.lineGrowth = growth }
                                    }
                                }
                            }

                            Text(cap.lineGrowth.descriptionText)
                                .font(.system(size: 12.5, weight: .regular))
                                .foregroundStyle(.ink.opacity(0.42))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // 6. `Word animation` (`Appear` | `Fade in` | `Slide in`)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Word animation")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.ink.opacity(0.92))

                            HStack(spacing: 6) {
                                ForEach(CaptionWordAnimation.allCases) { anim in
                                    inspectorPillOptionButton(
                                        title: anim.label,
                                        isSelected: cap.wordAnimation == anim
                                    ) {
                                        session.mutate { $0.captions.wordAnimation = anim }
                                    }
                                }
                            }

                            Text(cap.wordAnimation.descriptionText)
                                .font(.system(size: 12.5, weight: .regular))
                                .foregroundStyle(.ink.opacity(0.42))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    // 7. `Color` (`Dark` | `Light`)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Color")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.92))

                        HStack(spacing: 6) {
                            ForEach(CaptionColorTheme.allCases) { theme in
                                inspectorPillOptionButton(
                                    title: theme.label,
                                    isSelected: cap.colorTheme == theme
                                ) {
                                    session.mutate {
                                        $0.captions.colorTheme = theme
                                        $0.captions.textColor = (theme == .dark) ? "#FFFFFF" : "#000000"
                                        $0.captions.backgroundColor = (theme == .dark) ? "#000000CC" : "#FFFFFFE6"
                                    }
                                }
                            }
                        }
                    }

                    // 8. `Caption position` (`Bottom` | `Center`)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Caption position")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.92))

                        let isCenteredY = abs(cap.position01.y - 0.50) < 0.15
                        HStack(spacing: 6) {
                            inspectorPillOptionButton(
                                title: "Bottom",
                                isSelected: !isCenteredY
                            ) {
                                session.mutate { $0.captions.position01 = Point01(x: 0.5, y: 0.88) }
                            }

                            inspectorPillOptionButton(
                                title: "Center",
                                isSelected: isCenteredY
                            ) {
                                session.mutate { $0.captions.position01 = Point01(x: 0.5, y: 0.50) }
                            }
                        }
                    }
                }

                // 9. `Export transcript` (.srt) Button
                Button {
                    session.exportTranscriptAsSRT()
                } label: {
                    Text("Export transcript")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.ink.opacity(0.90))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.ink.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                inspectorDivider

                // 10. `Re-Generate transcript` (100% Local On-Device!)
                inspectorCollapsibleSection(
                    title: "Re-Generate transcript",
                    isExpanded: $isRegenerateTranscriptExpanded
                ) {
                    localTranscriptGeneratorControls(isRegenerating: true)
                }
            } else {
                // Initial Generate Transcript View (100% Local On-Device!)
                Text("Generate transcript")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.ink.opacity(0.45))

                localTranscriptGeneratorControls(isRegenerating: false)
            }
        }
    }

    @ViewBuilder
    private func localTranscriptGeneratorControls(isRegenerating: Bool) -> some View {
        let cap = session.document.captions
        let locales = LocalOnDeviceMediaIntelligence.supportedLocales()

        VStack(alignment: .leading, spacing: 14) {
            if isRegenerating {
                Text("When re-generating transcript, previous transcript (and all changes you made to it) will be lost.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color(red: 0.92, green: 0.64, blue: 0.28))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(red: 0.24, green: 0.18, blue: 0.11).opacity(0.45))
                    )
            }

            // Local Method Selection (`Local` Apple Speech vs `Whisper` OpenAI On-Device with On-Demand Download & Checkmark!)
            let selectedWhisperTier = WhisperModelTier(rawValue: cap.whisperModelTier) ?? .small
            let isSelectedWhisperInstalled = whisperManager.isModelInstalled(selectedWhisperTier)
            let anyWhisperInstalled = (whisperManager.anyInstalledTier != nil)

            VStack(alignment: .leading, spacing: 10) {
                Text("Transcript method")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.92))

                ScrollViewReader { methodScrollProxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            inspectorPillOptionButton(
                                title: "Local (Apple Speech)",
                                isSelected: cap.localModelVariant == "system"
                            ) {
                                session.mutate { $0.captions.localModelVariant = "system" }
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                    methodScrollProxy.scrollTo("system", anchor: .center)
                                }
                            }
                            .id("system")

                            // On-Device Whisper Button with Checkmark Badge & Instant Tooltip when downloaded!
                            Button {
                                if whisperManager.isModelInstalled(selectedWhisperTier) {
                                    session.mutate { $0.captions.localModelVariant = "whisper" }
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                        methodScrollProxy.scrollTo("whisper", anchor: .center)
                                    }
                                } else {
                                    whisperManager.promptUserAndStartDownload(for: selectedWhisperTier) {
                                        session.mutate { $0.captions.localModelVariant = "whisper" }
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                            methodScrollProxy.scrollTo("whisper", anchor: .center)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Text("On-Device Whisper")
                                        .font(.system(size: 12.5, weight: .regular))
                                        .foregroundStyle(.ink.opacity(cap.localModelVariant != "system" ? 0.98 : 0.72))
                                        .lineLimit(1)

                                    if anyWhisperInstalled {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Color(red: 0.25, green: 0.85, blue: 0.48))
                                    }
                                }
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .background(
                                    HoverMagnetBackgroundRepresentable(
                                        tooltip: whisperManager.installedTooltipSummary
                                            ?? "Click to download open-source OpenAI Whisper model (\(selectedWhisperTier.fileName), \(selectedWhisperTier.sizeDescription)) locally",
                                        shortcutBadge: nil,
                                        edge: .top,
                                        cornerRadius: 8,
                                        isActive: cap.localModelVariant != "system",
                                        isDisabled: false,
                                        isRailTab: false,
                                        hasActiveBorder: true,
                                        onViewReady: { _ in }
                                    )
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .id("whisper")
                        }
                        .padding(.vertical, 1)
                    }
                }

                Text(
                    cap.localModelVariant == "system"
                        ? "Transcript will be generated locally using Apple's native speech recognition engine. No data is sent to any server."
                        : "Transcript will be generated using open-source OpenAI Whisper AI model on your Mac. No data is sent to any server."
                )
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.ink.opacity(0.42))
                .fixedSize(horizontal: false, vertical: true)
            }

            // Whisper AI Model Tier Picker (`Base` 142MB | `Small` 466MB | `Medium` 1.5GB) & Live Download Progress Bar
            if cap.localModelVariant != "system" || whisperManager.activeDownloadTier != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("AI model to use")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.ink.opacity(0.92))

                    HStack(spacing: 6) {
                        ForEach(WhisperModelTier.allCases) { tier in
                            let isTierSelected = (selectedWhisperTier == tier)
                            let isTierInstalled = whisperManager.isModelInstalled(tier)

                            Button {
                                session.mutate {
                                    $0.captions.localModelVariant = "whisper"
                                    $0.captions.whisperModelTier = tier.rawValue
                                }
                                if !isTierInstalled && whisperManager.activeDownloadTier == nil {
                                    whisperManager.promptUserAndStartDownload(for: tier)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(tier.label)
                                        .font(.system(size: 12.5, weight: .regular))
                                        .foregroundStyle(.ink.opacity(isTierSelected ? 0.98 : 0.72))

                                    if isTierInstalled {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Color(red: 0.25, green: 0.85, blue: 0.48))
                                    }
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background(
                                    HoverMagnetBackgroundRepresentable(
                                        tooltip: isTierInstalled
                                            ? "Model Whisper \(tier.label) (\(tier.fileName)) is downloaded locally"
                                            : "Click to download Whisper \(tier.label) (\(tier.fileName), \(tier.sizeDescription))",
                                        shortcutBadge: nil,
                                        edge: .top,
                                        cornerRadius: 8,
                                        isActive: isTierSelected,
                                        isDisabled: false,
                                        isRailTab: false,
                                        hasActiveBorder: true,
                                        onViewReady: { _ in }
                                    )
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text(selectedWhisperTier.descriptionText)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.ink.opacity(0.42))
                        .fixedSize(horizontal: false, vertical: true)

                    // Live Download Progress Card with Cancel Button!
                    if let activeTier = whisperManager.activeDownloadTier {
                        let pct = Int(round(whisperManager.downloadProgress01 * 100.0))
                        let mbWritten = Double(whisperManager.downloadedBytes) / 1_048_576.0
                        let mbTotal = Double(max(1, whisperManager.totalBytesExpected)) / 1_048_576.0

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Downloading Whisper \(activeTier.label) (\(activeTier.fileName))… \(pct)%")
                                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                                        .foregroundStyle(.ink.opacity(0.92))
                                }
                                Spacer()
                                Button {
                                    whisperManager.cancelActiveDownload()
                                } label: {
                                    Text("Cancel")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.38))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(Color.red.opacity(0.14))
                                        )
                                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }

                            GeometryReader { geo in
                                let fillW = max(6.0, geo.size.width * CGFloat(whisperManager.downloadProgress01))
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.ink.opacity(0.12))
                                        .frame(height: 6)

                                    Capsule()
                                        .fill(Color(red: 0.44, green: 0.32, blue: 0.98))
                                        .frame(width: fillW, height: 6)
                                }
                            }
                            .frame(height: 6)

                            Text(String(format: "%.1f MB of %.1f MB", mbWritten, mbTotal))
                                .font(.system(size: 11, weight: .regular).monospacedDigit())
                                .foregroundStyle(.ink.opacity(0.45))
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.ink.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
                        )
                    } else if !isSelectedWhisperInstalled {
                        Button {
                            whisperManager.promptUserAndStartDownload(for: selectedWhisperTier)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 12.5, weight: .medium))
                                Text("Download Whisper \(selectedWhisperTier.label) (\(selectedWhisperTier.sizeDescription))")
                                    .font(.system(size: 12.5, weight: .medium))
                            }
                            .foregroundStyle(Color(red: 0.65, green: 0.56, blue: 1.0))
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.ink.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Language Picker (Export-FPS-style compact pill with smooth width interpolation when selecting short/long language names!)
            VStack(alignment: .leading, spacing: 8) {
                Text("Language")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.92))

                Menu {
                    ForEach(locales.prefix(35)) { loc in
                        Button(loc.displayName) {
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                                session.mutate { $0.captions.transcriptLocale = loc.id }
                            }
                        }
                    }
                } label: {
                    let currentName = locales.first(where: { $0.id == cap.transcriptLocale })?.displayName ?? cap.transcriptLocale
                    HStack(spacing: 6) {
                        Text(currentName)
                            .font(.system(size: 13.5, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.95))
                            .lineLimit(1)
                            .contentTransition(.interpolate)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 10.5, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.65))
                            .padding(.leading, 2)
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
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .animation(.spring(response: 0.24, dampingFraction: 0.84), value: cap.transcriptLocale)
            }

            // Keyterms / Prompt
            VStack(alignment: .leading, spacing: 6) {
                Text("Keyterms")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.92))

                Text("Comma-separated list of custom words or product names in your recording.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.42))

                TextField(
                    "e.g. Native Screen, Swift, Metal",
                    text: Binding(
                        get: { cap.customPrompt },
                        set: { v in session.mutate { $0.captions.customPrompt = v } }
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(.ink)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.ink.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.ink.opacity(0.09), lineWidth: 1)
                )
            }

            Button {
                session.generateLocalOnDeviceTranscript()
            } label: {
                HStack(spacing: 8) {
                    if session.isGeneratingTranscript {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Text(session.isGeneratingTranscript ? "Generating on device…" : "Generate transcript")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(red: 0.36, green: 0.24, blue: 0.96))
                )
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(session.isGeneratingTranscript)
        }
    }

    // MARK: - 5E. Edit by Transcript Inspector

    @ViewBuilder
    private var transcriptEditorInspector: some View {
        let cap = session.document.captions
        let segments = cap.segments.sorted { $0.sourceStartMs < $1.sourceStartMs }

        VStack(alignment: .leading, spacing: 20) {
            Text("Edit by transcript")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.ink.opacity(0.45))

            if segments.isEmpty {
                Text("Edit your video by editing its text: delete words to cut them out, remove filler words and long pauses in one click.")
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)

                Text("Generate a transcript first to get started.")
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.42))

                Button {
                    session.generateLocalOnDeviceTranscript()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Generate transcript")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(red: 0.36, green: 0.24, blue: 0.96))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                // 1. One-Click Action Bar: `Remove N filler words` & `Tighten N pauses`
                let fillerCount = session.presentFillerWordSegments.count
                let pauseCount = session.tightenablePauseRangesMs.count

                if fillerCount > 0 || pauseCount > 0 {
                    HStack(spacing: 8) {
                        if fillerCount > 0 {
                            Button {
                                session.removeAllFillerWordsFromTranscript()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "waveform.badge.minus")
                                        .font(.system(size: 12, weight: .medium))
                                    Text("Remove \(fillerCount) filler \(fillerCount == 1 ? "word" : "words")")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundStyle(.ink.opacity(0.92))
                                .padding(.horizontal, 10)
                                .frame(height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.ink.opacity(0.05))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.ink.opacity(0.09), lineWidth: 1)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help("Cut every detected filled pause (\"um\", \"uh\"...) out of the video")
                        }

                        if pauseCount > 0 {
                            Button {
                                session.tightenAllPausesInTranscript()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "timeline.selection")
                                        .font(.system(size: 12, weight: .medium))
                                    Text("Tighten \(pauseCount) \(pauseCount == 1 ? "pause" : "pauses")")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundStyle(.ink.opacity(0.92))
                                .padding(.horizontal, 10)
                                .frame(height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.ink.opacity(0.05))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.ink.opacity(0.09), lineWidth: 1)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help("Shorten every long pause, keeping a natural breath on each side")
                        }
                    }
                }

                // 2. Interactive Word & Pause Token Flow
                let spokenIds = session.spokenTranscriptSegmentIds
                FlowLayoutWrapRow(spacing: 5) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { idx, seg in
                        let isPresentInVideo = session.isSourceRangePresentInSlices(startMs: seg.sourceStartMs, endMs: seg.sourceEndMs)
                        let isSpokenNow = spokenIds.contains(seg.id)
                        let isSelected = (selectedTranscriptWordId == seg.id)
                        let isFiller = LocalOnDeviceMediaIntelligence.isFillerWord(seg.text)

                        if (isPresentInVideo || cap.showDeletedTextInTranscript) && (!seg.isHidden || cap.showHiddenWordsInTranscript) {
                            Button {
                                selectedTranscriptWordId = (selectedTranscriptWordId == seg.id) ? nil : seg.id
                                if let tMs = session.timeMapper.timelineTime(forSourceMs: seg.sourceStartMs + 10.0) {
                                    session.isPlaying = false
                                    session.seek(toTimelineMs: tMs)
                                }
                            } label: {
                                Text(seg.text)
                                    .font(.system(size: 13, weight: isSpokenNow ? .semibold : .regular))
                                    .strikethrough(!isPresentInVideo || seg.isHidden, color: .ink.opacity(0.55))
                                    .underline(isFiller && isPresentInVideo, pattern: .dot, color: Color(red: 0.58, green: 0.46, blue: 1.0))
                                    .foregroundStyle(
                                        !isPresentInVideo
                                            ? Color.red.opacity(0.65)
                                            : (seg.isHidden ? .ink.opacity(0.42) : .ink.opacity(0.95))
                                    )
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2.5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(
                                                isSelected
                                                    ? Color(red: 0.38, green: 0.26, blue: 0.96).opacity(0.48)
                                                    : (isSpokenNow ? Color(red: 0.38, green: 0.26, blue: 0.96).opacity(0.26) : Color.clear)
                                            )
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }

                        // Render `··· 1.3s` Pause Pill between words when gap >= 800ms
                        if idx + 1 < segments.count {
                            let nextSeg = segments[idx + 1]
                            let gapMs = nextSeg.sourceStartMs - seg.sourceEndMs
                            if gapMs >= 800.0 {
                                let isGapPresent = session.isSourceRangePresentInSlices(startMs: seg.sourceEndMs + 100.0, endMs: nextSeg.sourceStartMs - 100.0)
                                if isGapPresent || cap.showDeletedTextInTranscript {
                                    Button {
                                        if isGapPresent {
                                            session.cutTranscriptRangeFromVideo(
                                                startMs: seg.sourceEndMs + 100.0,
                                                endMs: nextSeg.sourceStartMs - 100.0
                                            )
                                        } else {
                                            session.restoreTranscriptRangeToVideo(
                                                startMs: seg.sourceEndMs,
                                                endMs: nextSeg.sourceStartMs
                                            )
                                        }
                                    } label: {
                                        Text(String(format: "··· %.1fs", gapMs / 1000.0))
                                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                                            .strikethrough(!isGapPresent, color: .ink.opacity(0.5))
                                            .foregroundStyle(.ink.opacity(isGapPresent ? 0.55 : 0.32))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(
                                                Capsule()
                                                    .fill(Color.ink.opacity(0.06))
                                            )
                                            .contentShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .help(
                                        isGapPresent
                                            ? "Pause — click to tighten to a natural breath"
                                            : "Tightened pause — click to restore"
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.ink.opacity(0.025))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.ink.opacity(0.06), lineWidth: 1)
                )

                // 3. Selected Word Action Bar
                if let selId = selectedTranscriptWordId,
                   let selSeg = segments.first(where: { $0.id == selId }) {
                    let isPresent = session.isSourceRangePresentInSlices(startMs: selSeg.sourceStartMs, endMs: selSeg.sourceEndMs)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            TextField(
                                "Word",
                                text: Binding(
                                    get: { selSeg.text },
                                    set: { newVal in session.updateCaptionWordText(id: selSeg.id, newText: newVal) }
                                )
                            )
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.ink)
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.ink.opacity(0.05))
                            )

                            if isPresent {
                                Button {
                                    session.cutTranscriptRangeFromVideo(
                                        startMs: max(0.0, selSeg.sourceStartMs - 25.0),
                                        endMs: min(session.metadata.durationMs, selSeg.sourceEndMs + 25.0)
                                    )
                                } label: {
                                    Label("Cut video", systemImage: "scissors")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.ink.opacity(0.92))
                                        .padding(.horizontal, 10)
                                        .frame(height: 32)
                                        .background(
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .fill(Color.red.opacity(0.22))
                                        )
                                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }

                            Button {
                                session.toggleCaptionWordHidden(id: selSeg.id)
                            } label: {
                                Label(selSeg.isHidden ? "Unhide" : "Cut transcript", systemImage: "text.badge.minus")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.ink.opacity(0.88))
                                    .padding(.horizontal, 10)
                                    .frame(height: 32)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(Color.ink.opacity(0.06))
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)

                            if !isPresent || selSeg.isHidden {
                                Button {
                                    session.restoreTranscriptRangeToVideo(
                                        startMs: max(0.0, selSeg.sourceStartMs - 25.0),
                                        endMs: min(session.metadata.durationMs, selSeg.sourceEndMs + 25.0),
                                        segmentId: selSeg.id
                                    )
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color(red: 0.65, green: 0.56, blue: 1.0))
                                        .padding(.horizontal, 10)
                                        .frame(height: 32)
                                        .background(
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .fill(Color.ink.opacity(0.06))
                                        )
                                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Text("Click any word to edit or cut — Cut video removes the spoken segment from the timeline, Cut transcript hides it from captions only.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.38))
                    .fixedSize(horizontal: false, vertical: true)

                inspectorDivider

                // 4. `Show deleted text` & `Show hidden words` Toggles
                inspectorToggleRow(
                    title: "Show deleted text",
                    icon: nil,
                    description: "Keep cut words visible as strikethrough so they can be restored.",
                    isOn: Binding(
                        get: { cap.showDeletedTextInTranscript },
                        set: { v in session.mutate { $0.captions.showDeletedTextInTranscript = v } }
                    )
                )

                inspectorToggleRow(
                    title: "Show hidden words",
                    icon: nil,
                    description: "Keep words hidden from captions visible here so they can be restored.",
                    isOn: Binding(
                        get: { cap.showHiddenWordsInTranscript },
                        set: { v in session.mutate { $0.captions.showHiddenWordsInTranscript = v } }
                    )
                )
            }
        }
    }

    // MARK: - Camera Layout Thumbnail Card & 8-Point Perimeter Dot Grid Helpers

    @ViewBuilder
    private func cameraLayoutThumbnailCard(
        mode: CameraLayoutMode,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    // Wallpaper-tinted dark card background
                    LinearGradient(
                        colors: [
                            Color(red: 0.14, green: 0.15, blue: 0.24),
                            Color(red: 0.08, green: 0.09, blue: 0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    switch mode {
                    case .overlay:
                        // White screen card + bottom-right dark person badge
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.ink)
                            .padding(10)
                            .overlay {
                                Image(systemName: "display")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.black.opacity(0.85))
                            }

                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.surface(red: 0.09, green: 0.09, blue: 0.12))
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.ink.opacity(0.15), lineWidth: 1)
                            Image(systemName: "person")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.ink.opacity(0.92))
                        }
                        .frame(width: 28, height: 26)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(5)

                    case .splitScreen:
                        // Left white screen half + right dark person half
                        HStack(spacing: 0) {
                            ZStack {
                                Color.ink
                                Image(systemName: "display")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(.black.opacity(0.85))
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            ZStack {
                                Color.surface(red: 0.07, green: 0.07, blue: 0.09)
                                Image(systemName: "person")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(.ink.opacity(0.90))
                            }
                            .frame(width: 34)
                        }

                    case .cutout:
                        // White screen card + bottom-right cutout silhouette
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.ink)
                            .padding(10)
                            .overlay {
                                Image(systemName: "display")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.black.opacity(0.85))
                            }

                        Image(systemName: "person.fill")
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(.ink)
                            .shadow(color: .black, radius: 1.5)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .offset(x: -4, y: 3)
                    }
                }
                .frame(height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(isSelected ? Color.ink.opacity(0.65) : Color.clear, lineWidth: 2.0)
                        .padding(-3)
                )

                Text(mode.label)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(.ink.opacity(isSelected ? 0.85 : 0.45))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private struct CameraPerimeterPositionGridPicker: View {
        @Binding var position01: Point01

        private let points: [(x: Double, y: Double)] = [
            (0.0, 0.0), (0.5, 0.0), (1.0, 0.0),
            (0.0, 0.5),             (1.0, 0.5),
            (0.0, 1.0), (0.5, 1.0), (1.0, 1.0)
        ]

        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let padX: CGFloat = 22
                let padY: CGFloat = 20
                let innerW = max(10, w - padX * 2)
                let innerH = max(10, h - padY * 2)

                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.ink.opacity(0.03))
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.ink.opacity(0.06), lineWidth: 1)

                    ForEach(Array(points.enumerated()), id: \.offset) { _, pt in
                        let isSelected = (hypot(position01.x - pt.x, position01.y - pt.y) < 0.18)
                        let cx = padX + CGFloat(pt.x) * innerW
                        let cy = padY + CGFloat(pt.y) * innerH

                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                                position01 = Point01(x: pt.x, y: pt.y)
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(
                                        isSelected
                                            ? Color(red: 0.59, green: 0.48, blue: 0.98)
                                            : Color.ink.opacity(0.08)
                                    )
                                    .frame(width: 20, height: 20)

                                Circle()
                                    .fill(Color.ink)
                                    .frame(width: 4.5, height: 4.5)
                            }
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .position(x: cx, y: cy)
                    }
                }
            }
            .frame(height: 112)
        }
    }

    /// Horizontal 3-Dot `Camera Position` Picker for `Camera cutout` Mode (`Left: 0.0`, `Center: 0.5`, `Right: 1.0` & 3)
    private struct CameraCutoutPositionDotBarPicker: View {
        @Binding var positionX01: Double

        private let xStops: [Double] = [0.0, 0.5, 1.0]

        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let padX: CGFloat = 22
                let innerW = max(10, w - padX * 2)
                let cy = h * 0.5

                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.ink.opacity(0.03))
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.ink.opacity(0.06), lineWidth: 1)

                    ForEach(xStops, id: \.self) { stopX in
                        let isSelected = (abs(positionX01 - stopX) < 0.18)
                        let cx = padX + CGFloat(stopX) * innerW

                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                                positionX01 = stopX
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(
                                        isSelected
                                            ? Color(red: 0.59, green: 0.48, blue: 0.98)
                                            : Color.ink.opacity(0.08)
                                    )
                                    .frame(width: 20, height: 20)

                                Circle()
                                    .fill(Color.ink)
                                    .frame(width: 4.5, height: 4.5)
                            }
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .position(x: cx, y: cy)
                    }
                }
            }
            .frame(height: 44)
        }
    }

    /// 3-Card `Split ratio` Picker
    private struct SplitScreenRatioCardsPicker: View {
        @Binding var ratio01: Double
        let isFlipped: Bool

        private var isAutoSelected: Bool {
            ratio01 <= 0.01
        }

        private var isHalfSelected: Bool {
            abs(ratio01 - 0.5) < 0.05
        }

        private var isTwoThirdsSelected: Bool {
            abs(ratio01 - (2.0 / 3.0)) < 0.05
        }

        var body: some View {
            HStack(spacing: 8) {
                // 1. `Auto` Card
                Button {
                    ratio01 = 0.0
                } label: {
                    ZStack {
                        splitCardBackground(isSelected: isAutoSelected)
                        Text("Auto")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.ink.opacity(isAutoSelected ? 0.96 : 0.72))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)

                // 2. `½ | ½` Card (`screenRatio01 = 0.5`)
                Button {
                    ratio01 = 0.5
                } label: {
                    ZStack {
                        splitCardBackground(isSelected: isHalfSelected)

                        GeometryReader { geo in
                            let w = max(10, geo.size.width - 8)
                            let h = max(10, geo.size.height - 8)
                            HStack(spacing: 2) {
                                splitSubPane(label: "½", isSelected: isHalfSelected)
                                    .frame(width: (w - 2) * 0.5, height: h)
                                splitSubPane(label: "½", isSelected: isHalfSelected)
                                    .frame(width: (w - 2) * 0.5, height: h)
                            }
                            .padding(4)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)

                // 3. `⅔ | ⅓` Card
                Button {
                    ratio01 = 2.0 / 3.0
                } label: {
                    ZStack {
                        splitCardBackground(isSelected: isTwoThirdsSelected)

                        GeometryReader { geo in
                            let w = max(10, geo.size.width - 8)
                            let h = max(10, geo.size.height - 8)
                            let leftShare: CGFloat = isFlipped ? (1.0 / 3.0) : (2.0 / 3.0)
                            let rightShare: CGFloat = 1.0 - leftShare
                            let leftLabel = isFlipped ? "⅓" : "⅔"
                            let rightLabel = isFlipped ? "⅔" : "⅓"

                            HStack(spacing: 2) {
                                splitSubPane(label: leftLabel, isSelected: isTwoThirdsSelected)
                                    .frame(width: (w - 2) * leftShare, height: h)
                                splitSubPane(label: rightLabel, isSelected: isTwoThirdsSelected)
                                    .frame(width: (w - 2) * rightShare, height: h)
                            }
                            .padding(4)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }

        @ViewBuilder
        private func splitCardBackground(isSelected: Bool) -> some View {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    isSelected
                        ? Color(red: 0.36, green: 0.22, blue: 0.98).opacity(0.22)
                        : Color.ink.opacity(0.035)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            isSelected
                                ? Color(red: 0.48, green: 0.36, blue: 1.0)
                                : Color.ink.opacity(0.08),
                            lineWidth: isSelected ? 1.5 : 1.0
                        )
                )
        }

        @ViewBuilder
        private func splitSubPane(label: String, isSelected: Bool) -> some View {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        isSelected
                            ? Color(red: 0.38, green: 0.24, blue: 0.96).opacity(0.25)
                            : Color.ink.opacity(0.03)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(
                                isSelected
                                    ? Color(red: 0.52, green: 0.40, blue: 1.0).opacity(0.45)
                                    : Color.ink.opacity(0.06),
                                lineWidth: 1.0
                            )
                    )

                Text(label)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.ink.opacity(isSelected ? 0.96 : 0.72))
            }
        }
    }

    // MARK: - 6. Dedicated Zoom Segment Editor ( `Close Zoom editor`)

    @ViewBuilder
    private func zoomSegmentEditor(zoom: ZoomBlock) -> some View {
        let zoomId = zoom.id
        let isLoupe = (zoom.presentation == .loupe)
        let isAuto = (zoom.mode == .followCursor)

        VStack(alignment: .leading, spacing: 22) {
            // 1. `← Close Zoom editor` Button
            Button {
                withAnimation(.easeOut(duration: 0.14)) {
                    session.selectedZoomId = nil
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("Close Zoom editor")
                        .font(.system(size: 13, weight: .regular))
                }
                .foregroundStyle(.ink.opacity(0.92))
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
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)

            // 2. `Zoom style` (`Classic` | `Glass Loupe`)
            VStack(alignment: .leading, spacing: 10) {
                Text("Zoom style")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.92))

                HStack(spacing: 8) {
                    segmentLargeOptionButton(
                        title: "Classic",
                        icon: "arrow.up.left.and.down.right.magnifyingglass",
                        isSelected: !isLoupe
                    ) {
                        session.setZoomPresentation(id: zoomId, presentation: .screen)
                    }

                    segmentLargeOptionButton(
                        title: "Glass Loupe",
                        icon: "magnifyingglass.circle.fill",
                        isSelected: isLoupe
                    ) {
                        session.setZoomPresentation(id: zoomId, presentation: .loupe)
                    }
                }
            }

            // 3. `Instant animation` Toggle
            inspectorToggleRow(
                title: "Instant animation",
                icon: nil,
                description: "If enabled, the zoom will be applied instantly without any animation.",
                isOn: Binding(
                    get: { zoom.instantAnimation },
                    set: { val in
                        session.mutate { doc in
                            if let idx = doc.timeline.zooms.firstIndex(where: { $0.id == zoomId }) {
                                doc.timeline.zooms[idx].instantAnimation = val
                            }
                        }
                    }
                )
            )

            inspectorDivider

            // 4. `Zoom position`: `Auto` / `Manual` when a cursor was recorded; projects without a cursor (imported
            //    videos) only have the drag pad.
            VStack(alignment: .leading, spacing: 10) {
                Text("Zoom position")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.92))

                if session.hasRecordedCursor {
                    HStack(spacing: 8) {
                        segmentLargeOptionButton(
                            title: "Auto",
                            icon: "wand.and.stars",
                            isSelected: isAuto
                        ) {
                            session.mutate { doc in
                                if let idx = doc.timeline.zooms.firstIndex(where: { $0.id == zoomId }) {
                                    doc.timeline.zooms[idx].mode = .followCursor
                                }
                            }
                        }

                        segmentLargeOptionButton(
                            title: "Manual",
                            icon: "scope",
                            isSelected: !isAuto
                        ) {
                            session.mutate { doc in
                                if let idx = doc.timeline.zooms.firstIndex(where: { $0.id == zoomId }) {
                                    doc.timeline.zooms[idx].mode = .manual
                                }
                            }
                        }
                    }

                    Text(
                        isAuto
                            ? "Zoomed camera will automatically try to keep the mouse cursor visible."
                            : "Drag the point to choose what the camera focuses on."
                    )
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.42))
                    .fixedSize(horizontal: false, vertical: true)
                }

                if !session.hasRecordedCursor || !isAuto {
                    ZoomPositionPadView(session: session, zoom: zoom)
                        .padding(.top, 2)
                }
            }

            // 5. `Zoom level` Slider + Reset
            VStack(alignment: .leading, spacing: 6) {
                Text("Zoom level")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.92))

                Text("How close to zoom on the cursor during this zoom phase")
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.42))
                    .fixedSize(horizontal: false, vertical: true)

                coalescedSliderRowOnly(
                    value: Binding(
                        get: { zoom.scale },
                        set: { val in
                            session.setZoomScale(id: zoomId, scale: val)
                        }
                    ),
                    range: 1.0...3.5,
                    defaultValue: 1.8
                )
                .padding(.top, 4)
            }

            inspectorDivider

            // 6. `Advanced` Collapsible Section
            inspectorCollapsibleSection(
                title: "Advanced",
                isExpanded: $isAdvancedZoomSegmentExpanded
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    if isLoupe {
                        coalescedSlider(
                            title: "Loupe size",
                            value: Binding(
                                get: { zoom.loupe.radius01 },
                                set: { v in
                                    session.mutate { doc in
                                        if let idx = doc.timeline.zooms.firstIndex(where: { $0.id == zoomId }) {
                                            doc.timeline.zooms[idx].loupe.radius01 = v
                                        }
                                    }
                                }
                            ),
                            range: 0.15...0.60,
                            defaultValue: 0.35
                        )

                        coalescedSlider(
                            title: "Glass bevel refraction",
                            value: Binding(
                                get: { zoom.loupe.bevelRatio },
                                set: { v in
                                    session.mutate { doc in
                                        if let idx = doc.timeline.zooms.firstIndex(where: { $0.id == zoomId }) {
                                            doc.timeline.zooms[idx].loupe.bevelRatio = v
                                        }
                                    }
                                }
                            ),
                            range: 0.08...0.50,
                            defaultValue: 0.25
                        )

                        coalescedSlider(
                            title: "Chromatic aberration",
                            value: Binding(
                                get: { zoom.loupe.chromaticAberration },
                                set: { v in
                                    session.mutate { doc in
                                        if let idx = doc.timeline.zooms.firstIndex(where: { $0.id == zoomId }) {
                                            doc.timeline.zooms[idx].loupe.chromaticAberration = v
                                        }
                                    }
                                }
                            ),
                            range: 0.0...1.2,
                            defaultValue: 0.65
                        )
                    }

                    Button {
                        session.applyZoomLevelToAllOtherZooms(fromId: zoomId)
                    } label: {
                        Text("Apply zoom level to all other zooms")
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.90))
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.ink.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    inspectorToggleRow(
                        title: "Disable zoom",
                        icon: nil,
                        description: nil,
                        isOn: Binding(
                            get: { zoom.disabled },
                            set: { _ in session.toggleZoomDisabled(id: zoomId) }
                        )
                    )
                }
            }

            inspectorDivider

            // 7. `🗑 Remove zoom` Button
            Button {
                session.deleteZoom(zoomId: zoomId)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .regular))
                    Text("Remove zoom")
                        .font(.system(size: 13, weight: .regular))
                }
                .foregroundStyle(.ink.opacity(0.92))
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.ink.opacity(0.035))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 7. Dedicated Shortcut Segment Editor (`← Close Shortcut editor` — Per-Segment Keys, Position, Offset, Color & Delete!)

    @ViewBuilder
    private func shortcutSegmentEditor(cluster: ProjectSession.ShortcutPressCluster) -> some View {
        let isHidden = session.isShortcutHidden(cluster)
        let hasCustomStyleOverride = (session.document.captions.shortcutStyleOverrides[cluster.id] != nil)
        let currentStyle = session.effectiveShortcutStyle(for: cluster)

        VStack(alignment: .leading, spacing: 22) {
            // 1. `← Close Shortcut editor` Button
            Button {
                stopShortcutKeyRecording()
                withAnimation(.easeOut(duration: 0.14)) {
                    session.selectedShortcutId = nil
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("Close Shortcut editor")
                        .font(.system(size: 13, weight: .regular))
                }
                .foregroundStyle(.ink.opacity(0.92))
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
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)

            // 2. Shortcut Keys & Live Key Recorder
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Shortcut keys")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.ink.opacity(0.92))
                    Spacer()
                    Text(cluster.compactTimelineLabel)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color(red: 0.65, green: 0.56, blue: 1.0))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(red: 0.302, green: 0.184, blue: 0.961).opacity(0.20))
                        )
                }

                // Interactive `Record shortcut…` Button
                Button {
                    if isRecordingShortcutKeys {
                        stopShortcutKeyRecording()
                    } else {
                        startShortcutKeyRecording(for: cluster)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isRecordingShortcutKeys ? "record.circle.fill" : "keyboard")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(isRecordingShortcutKeys ? Color.red : .ink.opacity(0.90))
                        Text(isRecordingShortcutKeys ? "Press any shortcut on keyboard… (ESC to cancel)" : "Record shortcut keys…")
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.92))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isRecordingShortcutKeys ? Color.red.opacity(0.16) : Color.ink.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                isRecordingShortcutKeys
                                    ? Color.red.opacity(0.65)
                                    : Color.ink.opacity(0.08),
                                lineWidth: 1
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                // Quick Modifier Toggle Pills (`⌘`, `⇧`, `⌥`, `⌃`, `⇪`) + Primary Key Input
                HStack(spacing: 5) {
                    ForEach([("Meta", "⌘"), ("Shift", "⇧"), ("Alt", "⌥"), ("Ctrl", "⌃"), ("CapsLock", "⇪")], id: \.0) { modKey, modSym in
                        let hasMod = cluster.modifiers.contains(modKey)
                        inspectorPillOptionButton(title: modSym, isSelected: hasMod, horizontalPadding: 10) {
                            var nextMods = cluster.modifiers
                            if let idx = nextMods.firstIndex(of: modKey) {
                                nextMods.remove(at: idx)
                            } else {
                                nextMods.append(modKey)
                            }
                            session.updateShortcutKeys(for: cluster, modifiers: nextMods, primaryKey: cluster.primaryKey)
                        }
                    }

                    TextField("Key", text: Binding(
                        get: { cluster.primaryKey },
                        set: { newKey in
                            session.updateShortcutKeys(for: cluster, modifiers: cluster.modifiers, primaryKey: newKey)
                        }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.ink)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.ink.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.ink.opacity(0.09), lineWidth: 1)
                    )
                }
            }

            // 3. Visibility Toggle (`Show this shortcut`)
            inspectorToggleRow(
                title: "Show this shortcut",
                icon: nil,
                description: "When disabled, this shortcut segment is dimmed on the timeline and hidden in the video.",
                isOn: Binding(
                    get: { !isHidden },
                    set: { shouldShow in
                        if shouldShow == isHidden {
                            session.toggleShortcutHidden(cluster)
                        }
                    }
                )
            )

            inspectorDivider

            // 4. Custom Style Override Toggle (`Customize position & color for this shortcut only`)
            inspectorToggleRow(
                title: "Custom style for this shortcut",
                icon: nil,
                description: "Override the track's default position, offset, and keycap color for this segment.",
                isOn: Binding(
                    get: { hasCustomStyleOverride },
                    set: { enabled in
                        session.mutate { doc in
                            if enabled {
                                doc.captions.shortcutStyleOverrides[cluster.id] = currentStyle
                            } else {
                                doc.captions.shortcutStyleOverrides.removeValue(forKey: cluster.id)
                            }
                        }
                    }
                )
            )

            // 5. Position, Offset X/Y & Keycap Color Controls (Edits either this segment's override or the track's style!)
            shortcutStyleControlsSection(
                style: Binding(
                    get: { session.effectiveShortcutStyle(for: cluster) },
                    set: { updatedStyle in
                        session.mutate { doc in
                            if doc.captions.shortcutStyleOverrides[cluster.id] != nil {
                                doc.captions.shortcutStyleOverrides[cluster.id] = updatedStyle
                            } else if let tIdx = doc.captions.shortcutTracks.firstIndex(where: { $0.id == cluster.trackId }) {
                                doc.captions.shortcutTracks[tIdx].style = updatedStyle
                                if tIdx == 0 {
                                    doc.captions.defaultShortcutStyle = updatedStyle
                                }
                            } else {
                                doc.captions.defaultShortcutStyle = updatedStyle
                            }
                        }
                    }
                )
            )

            inspectorDivider

            // 6. Action Buttons: `Duplicate shortcut` & `🗑 Remove shortcut` (Permanent Delete!)
            VStack(spacing: 8) {
                Button {
                    session.duplicateShortcut(cluster)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.square.on.square")
                            .font(.system(size: 13, weight: .regular))
                        Text("Duplicate shortcut")
                            .font(.system(size: 13, weight: .regular))
                    }
                    .foregroundStyle(.ink.opacity(0.92))
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.ink.opacity(0.035))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    stopShortcutKeyRecording()
                    session.deleteShortcut(cluster)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .regular))
                        Text("Remove shortcut")
                            .font(.system(size: 13, weight: .regular))
                    }
                    .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.red.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.red.opacity(0.22), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .onDisappear {
            stopShortcutKeyRecording()
        }
    }

    private func startShortcutKeyRecording(for cluster: ProjectSession.ShortcutPressCluster) {
        stopShortcutKeyRecording()
        isRecordingShortcutKeys = true
        shortcutKeyRecorderMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // ESC cancels key recording
                stopShortcutKeyRecording()
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var mods: [String] = []
            if flags.contains(.capsLock) { mods.append("CapsLock") }
            if flags.contains(.command) { mods.append("Meta") }
            if flags.contains(.shift) { mods.append("Shift") }
            if flags.contains(.option) { mods.append("Alt") }
            if flags.contains(.control) { mods.append("Ctrl") }

            let keyName: String = {
                switch event.keyCode {
                case 36, 76: return "Enter"
                case 48: return "Tab"
                case 49: return "Space"
                case 51: return "Delete"
                case 117: return "ForwardDelete"
                case 123: return "ArrowLeft"
                case 124: return "ArrowRight"
                case 125: return "ArrowDown"
                case 126: return "ArrowUp"
                default:
                    if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
                        return chars.uppercased()
                    }
                    return "K"
                }
            }()

            session.updateShortcutKeys(for: cluster, modifiers: mods, primaryKey: keyName)
            stopShortcutKeyRecording()
            return nil
        }
    }

    private func stopShortcutKeyRecording() {
        isRecordingShortcutKeys = false
        if let monitor = shortcutKeyRecorderMonitor {
            NSEvent.removeMonitor(monitor)
            shortcutKeyRecorderMonitor = nil
        }
    }

    // MARK: - 7B. Dedicated Camera Layout Segment Editor

    @ViewBuilder
    private func cameraLayoutSegmentEditor(segment: CameraLayoutSegment) -> some View {
        let segId = segment.id

        VStack(alignment: .leading, spacing: 22) {
            // 1. `← Close Camera Layout editor` Button
            Button {
                withAnimation(.easeOut(duration: 0.14)) {
                    session.selectedCameraLayoutId = nil
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("Close Camera Layout editor")
                        .font(.system(size: 13, weight: .regular))
                }
                .foregroundStyle(.ink.opacity(0.92))
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
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)

            // 2. `Disable layout` Toggle
            inspectorToggleRow(
                title: "Disable layout",
                icon: nil,
                description: nil,
                isOn: Binding(
                    get: { segment.disabled },
                    set: { _ in
                        session.toggleCameraLayoutDisabled(id: segId)
                    }
                )
            )

            if !segment.disabled {
                inspectorDivider

                // 3. `Layout type` 5-Card Grid
                VStack(alignment: .leading, spacing: 10) {
                    Text("Layout type")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.ink.opacity(0.92))

                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                        spacing: 10
                    ) {
                        ForEach(CameraTimelineLayoutType.allCases) { type in
                            cameraTimelineLayoutThumbnailCard(
                                type: type,
                                isSelected: segment.layoutType == type
                            ) {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                                    session.mutate { doc in
                                        if let idx = doc.timeline.cameraLayouts.firstIndex(where: { $0.id == segId }) {
                                            doc.timeline.cameraLayouts[idx].layoutType = type
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // 4. Per-Segment `Camera Position` overrides
                if segment.layoutType == .cameraOverlay {
                    inspectorDivider

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Camera Position")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.92))

                        CameraPerimeterPositionGridPicker(
                            position01: Binding(
                                get: { segment.overlayPosition01 ?? session.document.camera.position01 },
                                set: { pt in
                                    session.mutate { doc in
                                        if let idx = doc.timeline.cameraLayouts.firstIndex(where: { $0.id == segId }) {
                                            doc.timeline.cameraLayouts[idx].overlayPosition01 = pt
                                        }
                                    }
                                }
                            )
                        )
                    }
                } else if segment.layoutType == .cutoutCamera {
                    inspectorDivider

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Camera Position")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.92))

                        CameraCutoutPositionDotBarPicker(
                            positionX01: Binding(
                                get: { segment.cutoutPositionX01 ?? session.document.camera.cutoutPositionX01 },
                                set: { xVal in
                                    session.mutate { doc in
                                        if let idx = doc.timeline.cameraLayouts.firstIndex(where: { $0.id == segId }) {
                                            doc.timeline.cameraLayouts[idx].cutoutPositionX01 = xVal
                                        }
                                    }
                                }
                            )
                        )
                    }
                } else if segment.layoutType == .splitScreen {
                    inspectorDivider

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Split ratio")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.92))

                        SplitScreenRatioCardsPicker(
                            ratio01: Binding(
                                get: { session.document.camera.splitScreenRatio01 },
                                set: { newRatio in
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                                        session.mutate { $0.camera.splitScreenRatio01 = newRatio }
                                    }
                                }
                            ),
                            isFlipped: session.document.camera.splitFlip
                        )
                    }

                    inspectorToggleRow(
                        title: "Flip",
                        icon: nil,
                        description: "If enabled, the layout will be flipped.",
                        isOn: Binding(
                            get: { session.document.camera.splitFlip },
                            set: { v in
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                                    session.mutate { $0.camera.splitFlip = v }
                                }
                            }
                        )
                    )
                }
            }

            inspectorDivider

            // 5. `🗑 Remove layout` Button
            Button {
                session.deleteCameraLayout(id: segId)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .regular))
                    Text("Remove layout")
                        .font(.system(size: 13, weight: .regular))
                }
                .foregroundStyle(.ink.opacity(0.92))
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.ink.opacity(0.035))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func cameraTimelineLayoutThumbnailCard(
        type: CameraTimelineLayoutType,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.14, green: 0.15, blue: 0.24),
                            Color(red: 0.08, green: 0.09, blue: 0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    switch type {
                    case .cameraOverlay:
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.ink)
                            .padding(10)
                            .overlay {
                                Image(systemName: "display")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.black.opacity(0.85))
                            }

                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.surface(red: 0.09, green: 0.09, blue: 0.12))
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.ink.opacity(0.15), lineWidth: 1)
                            Image(systemName: "person")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.ink.opacity(0.92))
                        }
                        .frame(width: 28, height: 26)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(5)

                    case .splitScreen:
                        HStack(spacing: 0) {
                            ZStack {
                                Color.ink
                                Image(systemName: "display")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(.black.opacity(0.85))
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            ZStack {
                                Color.surface(red: 0.07, green: 0.07, blue: 0.09)
                                Image(systemName: "person")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(.ink.opacity(0.90))
                            }
                            .frame(width: 34)
                        }

                    case .cutoutCamera:
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.ink)
                            .padding(10)
                            .overlay {
                                Image(systemName: "display")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.black.opacity(0.85))
                            }

                        Image(systemName: "person.fill")
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(.ink)
                            .shadow(color: .black, radius: 1.5)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .offset(x: -4, y: 3)

                    case .fullscreenCamera:
                        Color.surface(red: 0.07, green: 0.07, blue: 0.09)
                        Image(systemName: "person")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.ink.opacity(0.92))

                    case .screenOnly:
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.ink)
                            .padding(10)
                            .overlay {
                                Image(systemName: "display")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.black.opacity(0.85))
                            }
                    }
                }
                .frame(height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(isSelected ? Color.ink.opacity(0.65) : Color.clear, lineWidth: 2.0)
                        .padding(-3)
                )

                Text(type.label)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(.ink.opacity(isSelected ? 0.88 : 0.45))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 7C. Dedicated Voiceover Segment Editor

    @ViewBuilder
    private func voiceoverSegmentEditor(voiceover: VoiceoverSegment) -> some View {
        let voId = voiceover.id
        let otherCount = session.document.timeline.voiceovers.filter { $0.id != voId }.count

        VStack(alignment: .leading, spacing: 22) {
            // 1. `← Close Voiceover editor` Button
            Button {
                withAnimation(.easeOut(duration: 0.14)) {
                    session.selectedVoiceoverId = nil
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("Close Voiceover editor")
                        .font(.system(size: 13, weight: .regular))
                }
                .foregroundStyle(.ink.opacity(0.92))
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
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)

            // 2. `Voiceover volume` Slider (`0% ... 100%`) + `Apply to other voiceovers`
            VStack(alignment: .leading, spacing: 10) {
                coalescedSlider(
                    title: "Voiceover volume",
                    icon: "speaker.wave.2",
                    value: Binding(
                        get: { voiceover.volume },
                        set: { v in
                            session.mutate { doc in
                                if let idx = doc.timeline.voiceovers.firstIndex(where: { $0.id == voId }) {
                                    doc.timeline.voiceovers[idx].volume = v
                                }
                            }
                        }
                    ),
                    range: 0.0...1.0,
                    defaultValue: 1.0
                )

                if otherCount > 0 {
                    Button {
                        session.applyVoiceoverVolumeToAllOthers(fromId: voId)
                    } label: {
                        Text("Apply to other voiceovers")
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.90))
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.ink.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            inspectorDivider

            // 3. `Attach to recording`
            VStack(alignment: .leading, spacing: 10) {
                Text("Attach to recording")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.92))

                HStack(spacing: 6) {
                    ForEach(VoiceoverAttachMode.allCases) { mode in
                        inspectorPillOptionButton(
                            title: mode.label,
                            isSelected: voiceover.attachMode == mode
                        ) {
                            session.mutate { doc in
                                if let idx = doc.timeline.voiceovers.firstIndex(where: { $0.id == voId }) {
                                    doc.timeline.voiceovers[idx].attachMode = mode
                                }
                            }
                        }
                    }
                }

                Text(voiceover.attachMode.descriptionText)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.42))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 4. `Hide & Mute original recording`
            inspectorToggleRow(
                title: "Hide & Mute original recording",
                icon: nil,
                description: "When enabled, the original microphone and webcam recording will be hidden and muted while the voiceover is playing.",
                isOn: Binding(
                    get: { voiceover.hideRecording },
                    set: { v in
                        session.mutate { doc in
                            if let idx = doc.timeline.voiceovers.firstIndex(where: { $0.id == voId }) {
                                doc.timeline.voiceovers[idx].hideRecording = v
                            }
                        }
                    }
                )
            )

            inspectorDivider

            // 5. `Disable` Toggle & `🗑 Remove voiceover` Button
            inspectorToggleRow(
                title: "Disable",
                icon: nil,
                description: nil,
                isOn: Binding(
                    get: { voiceover.disabled },
                    set: { _ in
                        session.toggleVoiceoverDisabled(id: voId)
                    }
                )
            )

            Button {
                session.deleteVoiceover(id: voId)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .regular))
                    Text("Remove voiceover")
                        .font(.system(size: 13, weight: .regular))
                }
                .foregroundStyle(.ink.opacity(0.92))
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.ink.opacity(0.035))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 7D. Device Frame / Mockup Inspector

    private struct DeviceFramePresetItem: Identifiable {
        let id: String
        let name: String
        let icon: String
        let aspectRatio: Double
        let colors: [(id: String, name: String)]
    }

    private static let builtInDeviceFrames: [DeviceFramePresetItem] = [
        DeviceFramePresetItem(
            id: "macbook-pro-16",
            name: "MacBook Pro 16\"",
            icon: "laptopcomputer",
            aspectRatio: 16.0 / 10.0,
            colors: [("space-black", "Space Black"), ("silver", "Silver")]
        ),
        DeviceFramePresetItem(
            id: "macbook-air-15",
            name: "MacBook Air 15\"",
            icon: "laptopcomputer",
            aspectRatio: 16.0 / 10.0,
            colors: [("midnight", "Midnight"), ("starlight", "Starlight"), ("silver", "Silver")]
        ),
        DeviceFramePresetItem(
            id: "iphone-16-pro",
            name: "iPhone 16 Pro",
            icon: "iphone",
            aspectRatio: 9.0 / 19.5,
            colors: [
                ("black-titanium", "Black Titanium"),
                ("natural-titanium", "Natural Titanium"),
                ("desert-titanium", "Desert Titanium"),
                ("white-titanium", "White Titanium")
            ]
        ),
        DeviceFramePresetItem(
            id: "ipad-pro-13",
            name: "iPad Pro 13\"",
            icon: "ipad.landscape",
            aspectRatio: 4.0 / 3.0,
            colors: [("space-black", "Space Black"), ("silver", "Silver")]
        )
    ]

    @ViewBuilder
    private var deviceFrameInspector: some View {
        let mockup = session.document.frameStyle.deviceMockup
        let srcW = Double(max(640, session.metadata.captureTarget.pixelSize.width))
        let srcH = Double(max(400, session.metadata.captureTarget.pixelSize.height))
        let recordingAspect = srcW / srcH
        let filteredDevices: [DeviceFramePresetItem] = {
            if mockup.matchMode == .perfect {
                let matches = Self.builtInDeviceFrames.filter { abs($0.aspectRatio - recordingAspect) < 0.28 }
                return matches.isEmpty ? Self.builtInDeviceFrames : matches
            }
            return Self.builtInDeviceFrames
        }()
        let activeDevice = filteredDevices.first(where: { $0.id == mockup.deviceId }) ?? filteredDevices[0]

        VStack(alignment: .leading, spacing: 22) {
            // 1. `Device` Section
            VStack(alignment: .leading, spacing: 14) {
                Text("Device")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.ink.opacity(0.45))

                inspectorToggleRow(
                    title: "Use device mockup",
                    icon: nil,
                    description: "Wrap recording in device mockup.",
                    isOn: Binding(
                        get: { mockup.enabled },
                        set: { v in
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                                session.mutate {
                                    $0.frameStyle.deviceMockup.enabled = v
                                    if $0.frameStyle.deviceMockup.deviceId == nil {
                                        $0.frameStyle.deviceMockup.deviceId = activeDevice.id
                                    }
                                }
                            }
                        }
                    )
                )
            }

            if mockup.enabled {
                inspectorDivider

                // 2. `Device frames`
                VStack(alignment: .leading, spacing: 14) {
                    Text("Device frames")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.ink.opacity(0.45))

                    HStack(spacing: 8) {
                        ForEach(DeviceFrameMatchMode.allCases) { mode in
                            segmentLargeOptionButton(
                                title: mode.label,
                                icon: mode.iconName,
                                isSelected: mockup.matchMode == mode
                            ) {
                                session.mutate { $0.frameStyle.deviceMockup.matchMode = mode }
                            }
                        }
                    }

                    Text(mockup.matchMode.descriptionText)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.ink.opacity(0.42))
                        .fixedSize(horizontal: false, vertical: true)

                    // Device Model Cards
                    VStack(spacing: 8) {
                        ForEach(filteredDevices) { dev in
                            let isSelected = (activeDevice.id == dev.id)
                            Button {
                                session.mutate {
                                    $0.frameStyle.deviceMockup.deviceId = dev.id
                                    if let firstColor = dev.colors.first?.id,
                                       !dev.colors.contains(where: { $0.id == $0.id && $0.id == mockup.colorVariantId }) {
                                        $0.frameStyle.deviceMockup.colorVariantId = firstColor
                                    }
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: dev.icon)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(.ink.opacity(isSelected ? 0.98 : 0.72))
                                        .frame(width: 22)

                                    Text(dev.name)
                                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                                        .foregroundStyle(.ink.opacity(isSelected ? 0.98 : 0.80))

                                    Spacer()

                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11.5, weight: .bold))
                                            .foregroundStyle(Color(red: 0.60, green: 0.50, blue: 1.0))
                                    }
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 38)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(isSelected ? Color(red: 0.36, green: 0.22, blue: 0.98).opacity(0.22) : Color.ink.opacity(0.035))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(
                                            isSelected ? Color(red: 0.48, green: 0.36, blue: 1.0) : Color.ink.opacity(0.08),
                                            lineWidth: isSelected ? 1.4 : 1.0
                                        )
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Color Finish Variants
                    if activeDevice.colors.count > 1 {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 7) {
                                Image(systemName: "circle.lefthalf.filled.righthalf.striped.horizontal.inverse")
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(.ink.opacity(0.85))
                                Text("Finish")
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(.ink.opacity(0.92))
                            }

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(activeDevice.colors, id: \.id) { cVar in
                                        inspectorPillOptionButton(
                                            title: cVar.name,
                                            isSelected: mockup.colorVariantId == cVar.id
                                        ) {
                                            session.mutate { $0.frameStyle.deviceMockup.colorVariantId = cVar.id }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    // MARK: - 8. Global & Multi-Track Keyboard Shortcuts Inspector

    @ViewBuilder
    private var shortcutsInspector: some View {
        let tracks = session.document.captions.shortcutTracks
        let activeTrackIndex = tracks.firstIndex(where: { $0.id == selectedShortcutTrackId }) ?? 0
        let activeTrack = tracks.indices.contains(activeTrackIndex) ? tracks[activeTrackIndex] : ShortcutTrackConfig()

        VStack(alignment: .leading, spacing: 22) {
            inspectorToggleRow(
                title: "Show shortcuts",
                icon: nil,
                description: "Show pressed shortcut labels in the video.",
                isOn: Binding(
                    get: { session.document.captions.showKeystrokes },
                    set: { v in session.mutate { $0.captions.showKeystrokes = v } }
                )
            )

            // Quick Action Buttons: `+ Add shortcut at playhead` & `+ Add shortcut track`
            HStack(spacing: 8) {
                Button {
                    session.addCustomShortcut(trackId: activeTrack.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Add shortcut")
                            .font(.system(size: 12.5, weight: .regular))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(red: 0.302, green: 0.184, blue: 0.961))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    let newId = session.addShortcutTrack()
                    selectedShortcutTrackId = newId
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.stack.badge.plus")
                            .font(.system(size: 12, weight: .regular))
                        Text("New track")
                            .font(.system(size: 12.5, weight: .regular))
                    }
                    .foregroundStyle(.ink.opacity(0.92))
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.ink.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.ink.opacity(0.09), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if session.document.captions.showKeystrokes {
                coalescedSlider(
                    title: "Shortcut labels size",
                    value: Binding(
                        get: { session.document.captions.shortcutsSizeRatio },
                        set: { v in session.mutate { $0.captions.shortcutsSizeRatio = v } }
                    ),
                    range: 0.075...0.25,
                    defaultValue: 0.11
                )

                inspectorToggleRow(
                    title: "Show single key shortcuts",
                    icon: nil,
                    description: "By default, only 2+ keys shortcuts are shown. Enable this option to show single letter shortcuts as well.",
                    isOn: Binding(
                        get: { session.document.captions.showSingleKeyShortcuts },
                        set: { v in session.mutate { $0.captions.showSingleKeyShortcuts = v } }
                    )
                )

                inspectorDivider

                // Multi-Track Selector (if >1 track exists, or shows current track settings)
                if tracks.count > 1 {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Shortcut track")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.92))

                        ScrollViewReader { trackProxy in
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(tracks) { trk in
                                        inspectorPillOptionButton(
                                            title: trk.name,
                                            isSelected: activeTrack.id == trk.id
                                        ) {
                                            selectedShortcutTrackId = trk.id
                                            withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                                                trackProxy.scrollTo(trk.id, anchor: .center)
                                            }
                                        }
                                        .id(trk.id)
                                    }
                                }
                            }
                        }
                    }
                }

                // Track Position, Offset X/Y & Keycap Color
                shortcutStyleControlsSection(
                    style: Binding(
                        get: {
                            let idx = session.document.captions.shortcutTracks.firstIndex(where: { $0.id == activeTrack.id }) ?? 0
                            if session.document.captions.shortcutTracks.indices.contains(idx) {
                                return session.document.captions.shortcutTracks[idx].style
                            }
                            return session.document.captions.defaultShortcutStyle
                        },
                        set: { newStyle in
                            session.mutate { doc in
                                let idx = doc.captions.shortcutTracks.firstIndex(where: { $0.id == activeTrack.id }) ?? 0
                                if doc.captions.shortcutTracks.indices.contains(idx) {
                                    doc.captions.shortcutTracks[idx].style = newStyle
                                }
                                if idx == 0 {
                                    doc.captions.defaultShortcutStyle = newStyle
                                }
                            }
                        }
                    )
                )
            }
        }
    }

    /// Reusable Position (`Bottom` | `Top` | `Left` | `Right`), Offset (`Horizontal` & `Vertical`), and Keycap Color (`Default` | `Solid` | `Gradient`) controls.
    @ViewBuilder
    private func shortcutStyleControlsSection(style: Binding<ShortcutStyleConfig>) -> some View {
        let current = style.wrappedValue

        VStack(alignment: .leading, spacing: 20) {
            // 1. Position (`Bottom` | `Top` | `Left` | `Right`)
            VStack(alignment: .leading, spacing: 10) {
                Text("Position")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.92))

                HStack(spacing: 6) {
                    ForEach(ShortcutDockPosition.allCases) { pos in
                        inspectorPillOptionButton(
                            title: pos.label,
                            isSelected: current.dockPosition == pos,
                            horizontalPadding: 11
                        ) {
                            style.wrappedValue.dockPosition = pos
                        }
                    }
                }

                if current.dockPosition.isVerticalStack {
                    Text("Keycaps are stacked vertically along the \(current.dockPosition.label.lowercased()) edge.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.ink.opacity(0.42))
                }
            }

            // 2. Fine Position Offset (`Horizontal offset` & `Vertical offset` to avoid captions!)
            coalescedSlider(
                title: "Horizontal offset",
                value: Binding(
                    get: { current.offsetX },
                    set: { style.wrappedValue.offsetX = $0 }
                ),
                range: -0.45...0.45,
                defaultValue: 0.0
            )

            coalescedSlider(
                title: "Vertical offset",
                value: Binding(
                    get: { current.offsetY },
                    set: { style.wrappedValue.offsetY = $0 }
                ),
                range: -0.45...0.45,
                defaultValue: 0.0
            )

            inspectorDivider

            // 3. Keycap Color (`Default` | `Solid` | `Gradient` + Smooth Expandable Color Picker!)
            VStack(alignment: .leading, spacing: 12) {
                Text("Keycap color")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.92))

                HStack(spacing: 6) {
                    ForEach(ShortcutColorMode.allCases) { mode in
                        inspectorPillOptionButton(
                            title: mode.label,
                            isSelected: current.colorMode == mode
                        ) {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                style.wrappedValue.colorMode = mode
                            }
                        }
                    }
                }

                if current.colorMode == .solid {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Key background")
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.65))

                        HStack(spacing: 8) {
                            ColorSwatchPickerButton(
                                hexColor: Binding(
                                    get: { current.solidColorHex },
                                    set: { style.wrappedValue.solidColorHex = $0 }
                                )
                            )

                            HexInputBox(
                                hexColor: Binding(
                                    get: { current.solidColorHex },
                                    set: { style.wrappedValue.solidColorHex = $0 }
                                ),
                                width: 110
                            )

                            Button {
                                if let rand = Self.curatedSolidColors.randomElement() {
                                    style.wrappedValue.solidColorHex = rand
                                }
                            } label: {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 13.5, weight: .regular))
                                    .foregroundStyle(.ink.opacity(0.90))
                                    .frame(width: 36, height: 36)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.ink.opacity(0.035))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(Color.ink.opacity(0.09), lineWidth: 1)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }

                        Text("Text color")
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.65))

                        HStack(spacing: 8) {
                            ColorSwatchPickerButton(
                                hexColor: Binding(
                                    get: { current.textColorHex },
                                    set: { style.wrappedValue.textColorHex = $0 }
                                )
                            )

                            HexInputBox(
                                hexColor: Binding(
                                    get: { current.textColorHex },
                                    set: { style.wrappedValue.textColorHex = $0 }
                                ),
                                width: 110
                            )
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.ink.opacity(0.035))
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))

                } else if current.colorMode == .gradient {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Key gradient")
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.65))

                        HStack(spacing: 5) {
                            ColorSwatchPickerButton(
                                hexColor: Binding(
                                    get: { current.gradientStartHex },
                                    set: { style.wrappedValue.gradientStartHex = $0 }
                                ),
                                size: 32
                            )

                            HexInputBox(
                                hexColor: Binding(
                                    get: { current.gradientStartHex },
                                    set: { style.wrappedValue.gradientStartHex = $0 }
                                ),
                                width: nil,
                                height: 32
                            )

                            ColorSwatchPickerButton(
                                hexColor: Binding(
                                    get: { current.gradientEndHex },
                                    set: { style.wrappedValue.gradientEndHex = $0 }
                                ),
                                size: 32
                            )

                            HexInputBox(
                                hexColor: Binding(
                                    get: { current.gradientEndHex },
                                    set: { style.wrappedValue.gradientEndHex = $0 }
                                ),
                                width: nil,
                                height: 32
                            )

                            Button {
                                if let pair = Self.curatedGradientPairs.randomElement() {
                                    style.wrappedValue.gradientStartHex = pair.0
                                    style.wrappedValue.gradientEndHex = pair.1
                                }
                            } label: {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 13.0, weight: .regular))
                                    .foregroundStyle(.ink.opacity(0.90))
                                    .frame(width: 32, height: 32)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.ink.opacity(0.035))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(Color.ink.opacity(0.09), lineWidth: 1)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }

                        // Mini 8-column preset gradient picker for keycaps
                        let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 8)
                        LazyVGrid(columns: columns, spacing: 5) {
                            ForEach(Array(Self.curatedGradientPairs.prefix(16).enumerated()), id: \.offset) { _, pair in
                                let isSel = (current.gradientStartHex.caseInsensitiveCompare(pair.0) == .orderedSame && current.gradientEndHex.caseInsensitiveCompare(pair.1) == .orderedSame)
                                Button {
                                    style.wrappedValue.gradientStartHex = pair.0
                                    style.wrappedValue.gradientEndHex = pair.1
                                } label: {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [Color(hex: pair.0), Color(hex: pair.1)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .aspectRatio(1.0, contentMode: .fit)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                                .strokeBorder(isSel ? Color.ink : Color.ink.opacity(0.12), lineWidth: isSel ? 1.4 : 0.8)
                                        )
                                        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Text("Text color")
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.65))
                            .padding(.top, 2)

                        HStack(spacing: 8) {
                            ColorSwatchPickerButton(
                                hexColor: Binding(
                                    get: { current.textColorHex },
                                    set: { style.wrappedValue.textColorHex = $0 }
                                )
                            )

                            HexInputBox(
                                hexColor: Binding(
                                    get: { current.textColorHex },
                                    set: { style.wrappedValue.textColorHex = $0 }
                                ),
                                width: 110
                            )
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.ink.opacity(0.035))
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: current.colorMode)
        }
    }

    @ViewBuilder
    private func segmentLargeOptionButton(
        title: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13.5, weight: .regular))
                Text(title)
                    .font(.system(size: 13.5, weight: .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(.ink.opacity(isSelected ? 0.98 : 0.85))
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isSelected
                            ? Color(red: 0.302, green: 0.184, blue: 0.961).opacity(0.16)
                            : Color.ink.opacity(0.035)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? Color(red: 0.44, green: 0.34, blue: 0.98)
                            : Color.ink.opacity(0.06),
                        lineWidth: isSelected ? 1.3 : 1.0
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func findMask(byId id: String) -> MaskItem? {
        for track in session.document.timeline.maskTracks {
            if let found = track.items.first(where: { $0.id == id }) {
                return found
            }
        }
        return nil
    }

    private func updateMask(id: String, mutation: (inout MaskItem) -> Void) {
        session.mutate { doc in
            for tIdx in doc.timeline.maskTracks.indices {
                if let mIdx = doc.timeline.maskTracks[tIdx].items.firstIndex(where: { $0.id == id }) {
                    mutation(&doc.timeline.maskTracks[tIdx].items[mIdx])
                    return
                }
            }
        }
    }

    @ViewBuilder
    private var inspectorDivider: some View {
        Rectangle()
            .fill(Color.ink.opacity(0.07))
            .frame(height: 1)
    }

    @ViewBuilder
    private func inspectorToggleRow(
        title: String,
        icon: String?,
        description: String?,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    if let icon = icon {
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.88))
                    }
                    Text(title)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.ink.opacity(0.92))
                }
                if let desc = description {
                    Text(desc)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.ink.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Color(red: 0.44, green: 0.34, blue: 0.98))
        }
    }

    @ViewBuilder
    private func inspectorPillOptionButton(
        title: String,
        isSelected: Bool,
        isLoading: Bool = false,
        horizontalPadding: CGFloat = 14,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Text(title)
                    .font(.system(size: 13.0, weight: .regular))
                    .foregroundStyle(.ink.opacity(isSelected ? 0.98 : 0.82))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .opacity(isLoading ? 0.25 : 1.0)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                        .tint(.ink)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isLoading)
            .padding(.horizontal, horizontalPadding)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        isSelected
                            ? Color(red: 0.302, green: 0.184, blue: 0.961).opacity(0.16)
                            : Color.ink.opacity(0.038)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? Color(red: 0.44, green: 0.34, blue: 0.98)
                            : Color.ink.opacity(0.06),
                        lineWidth: isSelected ? 1.3 : 1.0
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func inspectorCollapsibleSection<Content: View>(
        title: String,
        icon: String? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 13.5, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.85))
                    }
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.ink.opacity(0.92))
                    Spacer()
                    Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.ink.opacity(0.85))
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.ink.opacity(0.06))
                        )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                content()
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.ink.opacity(0.035))
                    )
            }
        }
    }

    @ViewBuilder
    private func coalescedSlider(
        title: String,
        icon: String? = nil,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        defaultValue: Double,
        showResetButton: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.ink.opacity(0.88))
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.ink.opacity(0.92))
            }

            coalescedSliderRowOnly(
                value: value,
                range: range,
                defaultValue: defaultValue,
                showResetButton: showResetButton
            )
        }
    }

    @ViewBuilder
    private func coalescedSliderRowOnly(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        defaultValue: Double,
        showResetButton: Bool = true
    ) -> some View {
        let isModified = abs(value.wrappedValue - defaultValue) > 0.005

        HStack(spacing: 12) {
            Slider(value: value, in: range) { editing in
                if editing {
                    session.beginInteractiveEdit()
                } else {
                    session.endInteractiveEdit()
                }
            }
            .tint(Color(red: 0.44, green: 0.34, blue: 0.98))
            .controlSize(.regular)

            if showResetButton {
                Button {
                    withAnimation(.easeOut(duration: 0.14)) {
                        value.wrappedValue = defaultValue
                    }
                } label: {
                    Text("Reset")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isModified ? .ink.opacity(0.95) : .ink.opacity(0.28))
                        .frame(width: 66, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.ink.opacity(isModified ? 0.07 : 0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.ink.opacity(isModified ? 0.14 : 0.06), lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!isModified)
            }
        }
    }
}

/// Interactive Spring Physics Demo Dot:
/// Simulates a `10pt` grey circular dot moving back and forth from `0` to `width - 10` using the exact Newtonian spring ODE
/// (`stiffness`, `damping`, `mass`) of the hovered/selected `Screen animation style` or `Cursor animation style`!
private struct SpringPhysicsDemoDotView: View {
    let spring: SpringConfig

    @State private var position01: Double = 0.0
    @State private var velocity01: Double = 0.0
    @State private var target01: Double = 1.0
    @State private var holdCounter: Int = 0

    private let dotSize: CGFloat = 10.0

    var body: some View {
        GeometryReader { geo in
            let travelW = max(10.0, geo.size.width - dotSize)

            Circle()
                .fill(Color.ink.opacity(0.42))
                .frame(width: dotSize, height: dotSize)
                .offset(x: CGFloat(position01) * travelW)
        }
        .frame(height: dotSize)
        .onAppear {
            position01 = 0.0
            velocity01 = 0.0
            target01 = 1.0
            holdCounter = 0
        }
        .task(id: spring) {
            let dt = 1.0 / 60.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                let k = max(5.0, spring.stiffness)
                let c = max(1.0, spring.damping)
                let m = max(0.1, spring.mass)

                let displacement = position01 - target01
                let accel = (-k * displacement - c * velocity01) / m
                velocity01 += accel * dt
                let nextPos = position01 + velocity01 * dt

                // Clamp overshoot just `clamp: true`
                if (target01 > 0.5 && nextPos >= 1.0) || (target01 < 0.5 && nextPos <= 0.0) {
                    position01 = target01
                    velocity01 = 0.0
                } else {
                    position01 = nextPos
                }

                if abs(position01 - target01) < 0.008 && abs(velocity01) < 0.02 {
                    position01 = target01
                    velocity01 = 0.0
                    holdCounter += 1
                    if holdCounter >= 6 { // ~100ms pause at each endpoint
                        holdCounter = 0
                        target01 = (target01 > 0.5) ? 0.0 : 1.0
                    }
                }
            }
        }
    }
}

/// Interactive Cursor Style card that displays the active cursor SVG sprite (and cycles through its variants on hover when unselected).
private struct CursorStyleHorizontalCardView: View {
    let theme: CursorThemePreset
    let selectedVariantId: String?
    let isSelected: Bool
    let cardSize: CGFloat
    let iconSize: CGFloat
    let action: () -> Void

    @State private var isHovered = false
    @State private var hoverVariantIndex: Int = 0
    @State private var hoverCycleTask: Task<Void, Never>?

    var body: some View {
        let displayedVariantId: String? = {
            if isSelected {
                return selectedVariantId
            }
            if isHovered && !theme.pointerVariants.isEmpty {
                let idx = hoverVariantIndex % theme.pointerVariants.count
                return theme.pointerVariants[idx].id
            }
            return selectedVariantId
        }()

        Button(action: action) {
            Image(nsImage: CursorSpriteProvider.shared.previewNSImage(themeId: theme.id, variantId: displayedVariantId))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
                .frame(width: cardSize, height: cardSize)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(white: isSelected ? 0.54 : (isHovered ? 0.51 : 0.48))) // neutral, so dark and light cursors both read
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isSelected
                                ? Color(red: 0.44, green: 0.34, blue: 0.98)
                                : Color.ink.opacity(isHovered ? 0.16 : 0.08),
                            lineWidth: isSelected ? 1.5 : 1.0
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            hoverCycleTask?.cancel()
            if hovering && !isSelected && theme.pointerVariants.count >= 2 {
                hoverCycleTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    while !Task.isCancelled {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            hoverVariantIndex = (hoverVariantIndex + 1) % theme.pointerVariants.count
                        }
                        try? await Task.sleep(for: .milliseconds(950))
                    }
                }
            } else {
                hoverVariantIndex = 0
            }
        }
        .onDisappear {
            hoverCycleTask?.cancel()
        }
    }
}

// MARK: - Visual Color Swatch Button, Hex Box & Interactive 2D HSB Color Picker Popover

private struct ColorSwatchPickerButton: View {
    @Binding var hexColor: String
    var size: CGFloat = 36
    @State private var isShowingPopover = false

    var body: some View {
        Button {
            isShowingPopover.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hex: hexColor))
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.ink.opacity(0.28), lineWidth: 1.2)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowingPopover, arrowEdge: .leading) {
            ColorPickerPopoverView(hexColor: $hexColor)
        }
    }
}

private struct HexInputBox: View {
    @Binding var hexColor: String
    var width: CGFloat? = 96
    var height: CGFloat = 36

    var body: some View {
        TextField("#4776E6", text: $hexColor)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, weight: .regular).monospacedDigit())
            .foregroundStyle(.ink.opacity(0.95))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.ink.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
            )
    }
}

private struct ColorPickerPopoverView: View {
    @Binding var hexColor: String

    @State private var hue: Double = 0.62
    @State private var saturation: Double = 0.75
    @State private var brightness: Double = 0.90

    private static let paletteSwatches: [String] = [
        "#FFFFFF", "#CBD5E1", "#64748B", "#1E293B", "#0F172A", "#18181B", "#EF4444", "#F97316",
        "#F59E0B", "#EAB308", "#84CC16", "#22C55E", "#10B981", "#14B8A6", "#06B6D4", "#0EA5E9",
        "#3B82F6", "#4776E6", "#6366F1", "#4D2FF5", "#8B5CF6", "#8E54E9", "#D946EF", "#EC4899"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 1. 2D Saturation / Brightness Square (`224 × 150`)
            GeometryReader { geo in
                let w = max(1.0, geo.size.width)
                let h = max(1.0, geo.size.height)

                ZStack(alignment: .topLeading) {
                    // Base pure hue
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(hue: hue, saturation: 1.0, brightness: 1.0))

                    // White -> Transparent horizontal saturation gradient
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.ink, .ink.opacity(0.0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    // Transparent -> Black vertical brightness gradient
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.black.opacity(0.0), .black],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    // Circular thumb handle
                    Circle()
                        .strokeBorder(Color.ink, lineWidth: 2.2)
                        .background(Circle().fill(Color(hex: hexColor)))
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                        .offset(
                            x: CGFloat(saturation) * w - 7.0,
                            y: CGFloat(1.0 - brightness) * h - 7.0
                        )
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.ink.opacity(0.14), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            saturation = min(1.0, max(0.0, Double(value.location.x / w)))
                            brightness = min(1.0, max(0.0, 1.0 - Double(value.location.y / h)))
                            hexColor = Color.hexString(hue: hue, saturation: saturation, brightness: brightness)
                        }
                )
            }
            .frame(width: 224, height: 148)

            // 2. Rainbow Hue Bar (`224 × 14`)
            GeometryReader { geo in
                let w = max(1.0, geo.size.width)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: (0...12).map { i in
                                    Color(hue: Double(i) / 12.0, saturation: 1.0, brightness: 1.0)
                                },
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 12)

                    Circle()
                        .fill(Color(hue: hue, saturation: 1.0, brightness: 1.0))
                        .overlay(Circle().strokeBorder(Color.ink, lineWidth: 2))
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.45), radius: 2)
                        .offset(x: CGFloat(hue) * (w - 16.0))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            hue = min(1.0, max(0.0, Double(value.location.x / w)))
                            hexColor = Color.hexString(hue: hue, saturation: saturation, brightness: brightness)
                        }
                )
            }
            .frame(width: 224, height: 16)

            // 3. Curated Quick Swatches (`8 × 3` grid)
            let cols = Array(repeating: GridItem(.flexible(), spacing: 5), count: 8)
            LazyVGrid(columns: cols, spacing: 5) {
                ForEach(Self.paletteSwatches, id: \.self) { swatchHex in
                    let isSel = (hexColor.caseInsensitiveCompare(swatchHex) == .orderedSame)
                    Button {
                        hexColor = swatchHex
                        let hsb = Color.hsbComponents(fromHex: swatchHex)
                        hue = hsb.h
                        saturation = hsb.s
                        brightness = hsb.b
                    } label: {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(hex: swatchHex))
                            .aspectRatio(1.0, contentMode: .fit)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(isSel ? Color.ink : Color.ink.opacity(0.15), lineWidth: isSel ? 1.5 : 0.8)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            // 4. Bottom Hex Input + Native Eyedropper Button
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(hex: hexColor))
                    .frame(width: 28, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.ink.opacity(0.22), lineWidth: 1)
                    )

                TextField("#4776E6", text: $hexColor)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.ink)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.ink.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.ink.opacity(0.10), lineWidth: 1)
                    )

                Button {
                    NSColorSampler().show { sampledColor in
                        if let sampled = sampledColor?.usingColorSpace(.sRGB) {
                            let r = Int(round(sampled.redComponent * 255.0))
                            let g = Int(round(sampled.greenComponent * 255.0))
                            let b = Int(round(sampled.blueComponent * 255.0))
                            let newHex = String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
                            hexColor = newHex
                            let hsb = Color.hsbComponents(fromHex: newHex)
                            hue = hsb.h
                            saturation = hsb.s
                            brightness = hsb.b
                        }
                    }
                } label: {
                    Image(systemName: "eyedropper")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.ink.opacity(0.90))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.ink.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.ink.opacity(0.10), lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Pick color from screen")
            }
        }
        .padding(14)
        .frame(width: 252)
        .background(Color.surface(red: 0.075, green: 0.075, blue: 0.09))
        .onAppear {
            let hsb = Color.hsbComponents(fromHex: hexColor)
            hue = hsb.h
            saturation = hsb.s
            brightness = hsb.b
        }
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var rgb: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }

    static func hsbComponents(fromHex hex: String) -> (h: Double, s: Double, b: Double) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var rgb: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgb)
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        let nsColor = NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
        var h: CGFloat = 0
        var s: CGFloat = 0
        var br: CGFloat = 0
        var a: CGFloat = 0
        nsColor.getHue(&h, saturation: &s, brightness: &br, alpha: &a)
        return (Double(h), Double(s), Double(br))
    }

    static func hexString(hue: Double, saturation: Double, brightness: Double) -> String {
        let nsColor = NSColor(
            hue: CGFloat(min(1.0, max(0.0, hue))),
            saturation: CGFloat(min(1.0, max(0.0, saturation))),
            brightness: CGFloat(min(1.0, max(0.0, brightness))),
            alpha: 1.0
        ).usingColorSpace(.sRGB) ?? NSColor.white
        let r = Int(round(nsColor.redComponent * 255.0))
        let g = Int(round(nsColor.greenComponent * 255.0))
        let b = Int(round(nsColor.blueComponent * 255.0))
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }

    static func shiftHue(ofHex hex: String, by delta: Double) -> String {
        let hsb = hsbComponents(fromHex: hex)
        var nextHue = (hsb.h + delta).truncatingRemainder(dividingBy: 1.0)
        if nextHue < 0 { nextHue += 1.0 }
        return hexString(hue: nextHue, saturation: max(0.15, hsb.s), brightness: max(0.15, hsb.b))
    }
}

/// Wrapping horizontal flow layout for pills, word tokens, and pause badges.
struct FlowLayoutWrapRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 300
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxW {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: maxW, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}

// MARK: - Zoom Position Drag Pad

/// Thumbnail of the recording with a draggable focus point and the zoomed viewport it produces.
/// Dragging writes `manualCenter01` live (one undo step per drag) and parks the playhead inside the zoom,
/// so the preview canvas follows the drag.
private struct ZoomPositionPadView: View {
    @Bindable var session: ProjectSession
    let zoom: ZoomBlock

    @State private var thumbnail: CGImage?
    @State private var isDragging = false
    @State private var isHovering = false

    private var sourceAspect: CGFloat {
        let size = session.metadata.captureTarget.pixelSize
        return CGFloat(max(1, size.width)) / CGFloat(max(1, size.height))
    }

    var body: some View {
        let center = zoom.manualCenter01
        GeometryReader { geo in
            let padSize = geo.size
            let viewport = Self.viewportRect(center: center, scale: zoom.scale, in: padSize)
            let dot = CGPoint(x: CGFloat(center.x) * padSize.width, y: CGFloat(center.y) * padSize.height)

            ZStack(alignment: .topLeading) {
                Group {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1.0)
                            .resizable()
                    } else {
                        Color.ink.opacity(0.05)
                    }
                }
                .frame(width: padSize.width, height: padSize.height)

                // Dim everything outside the zoomed viewport.
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: padSize))
                    p.addRect(viewport)
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))

                Rectangle()
                    .strokeBorder(Color.ink.opacity(0.75), lineWidth: 1)
                    .frame(width: viewport.width, height: viewport.height)
                    .offset(x: viewport.minX, y: viewport.minY)

                Circle()
                    .fill(Color.surface(red: 0.16, green: 0.17, blue: 0.22).opacity(0.92))
                    .overlay(Circle().strokeBorder(Color.ink, lineWidth: 2))
                    .frame(width: 26, height: 26)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                    .scaleEffect(isDragging ? 1.12 : 1.0)
                    .offset(x: dot.x - 13, y: dot.y - 13)
                    .animation(.easeOut(duration: 0.12), value: isDragging)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .top) {
                if isDragging || isHovering {
                    Text("Left \(Int((center.x * 100).rounded()))% · Top \(Int((center.y * 100).rounded()))%")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.ink.opacity(0.95))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.black.opacity(0.78))
                        )
                        .offset(y: -30)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            session.seekIntoZoomForEditing(id: zoom.id)
                            session.beginInteractiveEdit()
                        }
                        session.setZoomManualCenter(
                            id: zoom.id,
                            center01: Point01(
                                x: Double(value.location.x / max(1, padSize.width)),
                                y: Double(value.location.y / max(1, padSize.height))
                            )
                        )
                    }
                    .onEnded { _ in
                        isDragging = false
                        session.endInteractiveEdit()
                    }
            )
        }
        .aspectRatio(sourceAspect, contentMode: .fit)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.ink.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
        )
        .task(id: zoom.id) {
            thumbnail = await Self.loadThumbnail(
                url: session.videoFileURL,
                atSourceMs: (zoom.sourceStartMs + zoom.sourceEndMs) * 0.5
            )
        }
    }

    /// The part of the screen visible at `scale`, centered on `center` and kept inside the frame (the camera clamps the same way).
    private static func viewportRect(center: Point01, scale: Double, in size: CGSize) -> CGRect {
        let s = CGFloat(max(1.0, scale))
        let w = size.width / s
        let h = size.height / s
        let x = min(max(0, CGFloat(center.x) * size.width - w * 0.5), size.width - w)
        let y = min(max(0, CGFloat(center.y) * size.height - h * 0.5), size.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func loadThumbnail(url: URL, atSourceMs ms: Double) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        return try? await generator.image(at: CMTime(seconds: ms / 1000.0, preferredTimescale: 600)).image
    }
}

