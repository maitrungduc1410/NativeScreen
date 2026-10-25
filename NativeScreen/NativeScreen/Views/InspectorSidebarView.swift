import SwiftUI
import AppKit

/// Native macOS Inspector Sidebar with dark pill selectors,
/// non-truncating responsive controls, and quick "Reset" buttons on sliders.
public struct InspectorSidebarView: View {
    @Bindable var session: ProjectSession
    @State private var systemWallpapers: [SystemWallpaperItem] = []
    @State private var isRotationSectionExpanded: Bool = true
    @State private var isAdvancedCursorSectionExpanded: Bool = false
    @State private var lastRememberedIdleMs: Double = 2000.0
    @State private var lastRememberedLoopMs: Double = 1000.0
    @State private var lastRememberedShakeThreshold: Double = 4.0

    public init(session: ProjectSession) {
        self.session = session
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Vertical Icon Navigation Rail with Instant Speech-Bubble Tooltips (Left side, style)
            VStack(spacing: 10) {
                ForEach(ProjectSession.InspectorTab.allCases) { tab in
                    let isSelected = (session.selectedInspectorTab == tab)
                    InstantTooltipButton(
                        tooltip: tab.rawValue,
                        edge: .leading,
                        isActive: isSelected,
                        activeColor: Color.white.opacity(0.11),
                        size: 38,
                        cornerRadius: 9
                    ) {
                        session.selectedInspectorTab = tab
                    } label: {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isSelected ? Color(red: 0.62, green: 0.52, blue: 1.0) : .secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 7)
            .frame(maxHeight: .infinity)
            .background(Color(red: 0.07, green: 0.07, blue: 0.09))
            .zIndex(50)

            Divider()

            // Active Inspector Content Panel
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    Text(session.selectedInspectorTab.rawValue)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)

                    switch session.selectedInspectorTab {
                    case .background:
                        backgroundInspector
                    case .cursor:
                        cursorInspector
                    case .zoom:
                        zoomInspector
                    case .masks:
                        masksInspector
                    case .audio:
                        audioAndSliceInspector
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 332)
            .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        }
        .onAppear {
            if systemWallpapers.isEmpty {
                systemWallpapers = SystemWallpaperCatalog.discoverSystemWallpapers()
            }
        }
    }

    // MARK: - 1. Background & Frame Style Inspector

    @ViewBuilder
    private var backgroundInspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Pill selector (Mesh, macOS, Gradient, Color)
            HStack(spacing: 6) {
                ForEach([BackgroundType.mesh, .wallpaper, .gradient, .solid]) { mode in
                    let isSelected = (session.document.background.type == mode)
                    Button {
                        session.mutate { $0.background.type = mode }
                    } label: {
                        Text(mode.label)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? .white : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                isSelected
                                    ? Color.white.opacity(0.14)
                                    : Color.white.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(isSelected ? Color.white.opacity(0.28) : Color.clear, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            switch session.document.background.type {
            case .mesh:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Wallpaper Presets")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            if let random = MeshPreset.builtIn.randomElement() {
                                session.mutate {
                                    $0.background.type = .mesh
                                    $0.background.meshPresetId = random.id
                                }
                            }
                        } label: {
                            Label("Random", systemImage: "wand.and.stars")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(MeshPreset.builtIn) { preset in
                            let isSelected = (session.document.background.meshPresetId == preset.id)
                            Button {
                                session.mutate {
                                    $0.background.type = .mesh
                                    $0.background.meshPresetId = preset.id
                                }
                            } label: {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: preset.colorsHex.map { Color(hex: $0) },
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(height: 38)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(isSelected ? Color.white : Color.white.opacity(0.12), lineWidth: isSelected ? 2 : 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(preset.name)
                        }
                    }
                }

            case .wallpaper:
                VStack(alignment: .leading, spacing: 8) {
                    Text("macOS System Wallpapers")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(systemWallpapers) { item in
                            let isSelected = (session.document.background.systemWallpaperName == item.name)
                            Button {
                                session.selectSystemWallpaper(item)
                            } label: {
                                VStack(spacing: 4) {
                                    if let nsImg = SystemWallpaperCatalog.cachedThumbnailImage(for: item) {
                                        Image(nsImage: nsImg)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(height: 44)
                                            .frame(maxWidth: .infinity)
                                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                    .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 2)
                                            )
                                    } else {
                                        RoundedRectangle(cornerRadius: 7)
                                            .fill(Color.secondary.opacity(0.2))
                                            .frame(height: 44)
                                    }
                                    Text(item.name)
                                        .font(.system(size: 9))
                                        .lineLimit(1)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

            case .gradient, .solid, .image:
                HStack {
                    Text("Hex Color")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("#1E1E2E", text: Binding(
                        get: { session.document.background.solidColor },
                        set: { hex in session.mutate { $0.background.solidColor = hex } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
                }
            }

            Divider()

            coalescedSlider(
                title: "Background blur",
                value: Binding(
                    get: { session.document.background.blurRadius },
                    set: { v in session.mutate { $0.background.blurRadius = v } }
                ),
                range: 0...60,
                defaultValue: 0.0
            )

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

            coalescedSlider(
                title: "Shadow intensity",
                value: Binding(
                    get: { session.document.frameStyle.shadow.intensity },
                    set: { v in session.mutate { $0.frameStyle.shadow.intensity = v } }
                ),
                range: 0...1.0,
                defaultValue: 0.42
            )
        }
    }

    // MARK: - 2. Cursor & Spring Physics Inspector (Layout & Full 24 Cursor Sets + Variants)

    @ViewBuilder
    private var cursorInspector: some View {
        let cursor = session.document.cursor
        let normalizedThemeId = CursorThemePreset.normalizeThemeId(cursor.themeId)
        let activeTheme = CursorThemePreset.theme(withId: normalizedThemeId)

        VStack(alignment: .leading, spacing: 18) {
            if let slice = session.currentActiveSlice, slice.hideCursor {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("Cursor is hidden in this part of the recording, so you will not see changes you make to it.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.88))
                    }
                    Button {
                        session.selectedInspectorTab = .audio
                    } label: {
                        Text("Open clip settings")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }

                // 2. Cursor style (Single-row horizontal ScrollView with "App Store style" ~50% half-card peek on the right edge + auto-center on click!)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Cursor style")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))

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
                            if normalizedThemeId != "macos" && normalizedThemeId != "macos-tahoe" {
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
                                .foregroundStyle(.white.opacity(0.45))

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
                                                            .fill(Color.white.opacity(isVarSelected ? 0.08 : 0.04))
                                                    )
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                            .strokeBorder(
                                                                isVarSelected
                                                                    ? Color(red: 0.44, green: 0.34, blue: 0.98)
                                                                    : Color.white.opacity(0.08),
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
                VStack(alignment: .leading, spacing: 16) {
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

                // 5. Click effect (`None` | `Circle` | `Ripple`) & Click sound (`None` | `Magic Mouse™` | `MX Master™`)
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Click effect")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))

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
                            .foregroundStyle(.white.opacity(0.92))

                        let normalizedSoundSet: String? = {
                            switch cursor.clickEffect.soundSet {
                            case "apple-magic-mouse", "magic-mouse": return "apple-magic-mouse"
                            case "logitech-mx-master", "mx-master": return "logitech-mx-master"
                            default: return nil
                            }
                        }()

                        HStack(spacing: 6) {
                            inspectorPillOptionButton(title: "None", isSelected: normalizedSoundSet == nil) {
                                session.mutate { $0.cursor.clickEffect.soundSet = nil }
                            }
                            inspectorPillOptionButton(title: "Magic Mouse™", isSelected: normalizedSoundSet == "apple-magic-mouse") {
                                session.mutate { $0.cursor.clickEffect.soundSet = "apple-magic-mouse" }
                                CursorClickSoundPlayer.shared.playClickSound(
                                    soundSet: "apple-magic-mouse",
                                    volume: session.document.cursor.clickEffect.soundVolume
                                )
                            }
                            inspectorPillOptionButton(title: "MX Master™", isSelected: normalizedSoundSet == "logitech-mx-master") {
                                session.mutate { $0.cursor.clickEffect.soundSet = "logitech-mx-master" }
                                CursorClickSoundPlayer.shared.playClickSound(
                                    soundSet: "logitech-mx-master",
                                    volume: session.document.cursor.clickEffect.soundVolume
                                )
                            }
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
                                .foregroundStyle(.white.opacity(0.92))
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.white.opacity(0.04))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
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
                                    .foregroundStyle(.white.opacity(0.88))
                                Text("Rotate while moving")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.92))
                            }

                            Text("How the cursor rotates as it chases the mouse.")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.45))

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
                                .foregroundStyle(.white.opacity(0.45))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if cursor.rotationMode == .tilt {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Tilt amount")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.92))
                                Text("How strongly horizontal movement leans the cursor.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.45))

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
                                    .foregroundStyle(.white.opacity(0.92))
                                Text("Near the end of the video, the last mouse movement often leads to clicking \"Stop Recording,\" which you might not want to be visible. Adjust how long before the end of the video the mouse cursor will stop moving.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.45))
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

    // MARK: - 3. Auto-Zoom & Camera Motion Blur Inspector

    @ViewBuilder
    private var zoomInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button {
                    session.addZoomAtPlayhead()
                } label: {
                    Label("Add Zoom", systemImage: "plus.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .controlSize(.small)

                Button {
                    session.regenerateAutoZooms()
                } label: {
                    Label("Auto-Cluster", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let zoomId = session.selectedZoomId,
               let zoom = session.document.timeline.zooms.first(where: { $0.id == zoomId }) {
                Divider()
                Text("Selected Zoom")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                coalescedSlider(
                    title: String(format: "Zoom Depth (%.1fx)", zoom.scale),
                    value: Binding(
                        get: { zoom.scale },
                        set: { v in
                            session.mutate { doc in
                                if let idx = doc.timeline.zooms.firstIndex(where: { $0.id == zoomId }) {
                                    doc.timeline.zooms[idx].scale = v
                                }
                            }
                        }
                    ),
                    range: 1.1...3.5,
                    defaultValue: 1.8
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("Focus Target")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Picker("", selection: Binding(
                        get: { zoom.mode },
                        set: { m in
                            session.mutate { doc in
                                if let idx = doc.timeline.zooms.firstIndex(where: { $0.id == zoomId }) {
                                    doc.timeline.zooms[idx].mode = m
                                }
                            }
                        }
                    )) {
                        Text("Follow Cursor").tag(ZoomMode.followCursor)
                        Text("Manual Center").tag(ZoomMode.manual)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Button(role: .destructive) {
                    session.deleteZoom(zoomId: zoomId)
                } label: {
                    Label("Delete Selected Zoom", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            // Camera Animation Presets
            VStack(alignment: .leading, spacing: 6) {
                Text("Screen animation style")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    cameraSpringPresetButton(
                        title: "Focused",
                        icon: "scope",
                        preset: .focusedCamera
                    )
                    cameraSpringPresetButton(
                        title: "Smooth",
                        icon: "point.topleft.down.to.point.bottomright.curvepath",
                        preset: .smoothCamera
                    )
                }
            }

            // Cursor Animation Presets (`Smooth`, `Medium`, `Rapid`)
            VStack(alignment: .leading, spacing: 6) {
                Text("Cursor animation style")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    cursorSpringPresetButton(
                        title: "Smooth",
                        icon: "cursorarrow.click.2",
                        preset: SpringConfig(stiffness: 470.0, damping: 70.0, mass: 3.0)
                    )
                    cursorSpringPresetButton(
                        title: "Medium",
                        icon: "cursorarrow.click",
                        preset: SpringConfig(stiffness: 340.0, damping: 60.0, mass: 3.0)
                    )
                    cursorSpringPresetButton(
                        title: "Rapid",
                        icon: "cursorarrow.motionlines",
                        preset: SpringConfig(stiffness: 530.0, damping: 40.0, mass: 1.0)
                    )
                }
            }

            coalescedSlider(
                title: "Camera motion blur",
                value: Binding(
                    get: { session.document.motion.motionBlurIntensity },
                    set: { v in session.mutate { $0.motion.motionBlurIntensity = v } }
                ),
                range: 0.0...1.5,
                defaultValue: 0.0
            )

            Toggle("Avoid empty area when zooming", isOn: Binding(
                get: { session.document.motion.avoidEmptyBoundsWhenZooming },
                set: { v in session.mutate { $0.motion.avoidEmptyBoundsWhenZooming = v } }
            ))
            .font(.system(size: 12))
        }
    }

    @ViewBuilder
    private func cursorSpringPresetButton(title: String, icon: String, preset: SpringConfig) -> some View {
        let cur = session.document.cursor.spring
        let isRapid = abs(cur.stiffness - 530.0) < 10.0
        let isMedium = abs(cur.stiffness - 340.0) < 10.0
        let isSelected: Bool = {
            if abs(preset.stiffness - 530.0) < 10.0 { return isRapid }
            if abs(preset.stiffness - 340.0) < 10.0 { return isMedium }
            return !isRapid && !isMedium // Default (`Smooth`)
        }()
        Button {
            session.mutate { $0.cursor.spring = preset }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(isSelected ? .white : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color(red: 0.44, green: 0.34, blue: 0.98).opacity(0.28) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color(red: 0.54, green: 0.44, blue: 1.0) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func cameraSpringPresetButton(title: String, icon: String, preset: SpringConfig) -> some View {
        let cam = session.document.motion.cameraSpring
        let isFocused = abs(cam.stiffness - SpringConfig.focusedCamera.stiffness) < 10.0
        let isSelected = (abs(preset.stiffness - SpringConfig.focusedCamera.stiffness) < 10.0) ? isFocused : !isFocused
        Button {
            session.mutate { $0.motion.cameraSpring = preset }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isSelected ? .white : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color(red: 0.44, green: 0.34, blue: 0.98).opacity(0.28) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color(red: 0.54, green: 0.44, blue: 1.0) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
                ?? session.activeMasks(atSourceMs: session.currentSourceTimeMs).first?.id
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

    // MARK: - 5. Audio & Clip Slice Speed Inspector

    @ViewBuilder
    private var audioAndSliceInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            coalescedSlider(
                title: "System audio volume",
                value: Binding(
                    get: { session.document.audio.systemAudioVolume },
                    set: { v in session.mutate { $0.audio.systemAudioVolume = v } }
                ),
                range: 0...1.5,
                defaultValue: 1.0
            )

            coalescedSlider(
                title: "Microphone volume",
                value: Binding(
                    get: { session.document.audio.microphoneVolume },
                    set: { v in session.mutate { $0.audio.microphoneVolume = v } }
                ),
                range: 0...1.5,
                defaultValue: 1.0
            )

            Toggle("Voice enhancement", isOn: Binding(
                get: { session.document.audio.voiceEnhancement },
                set: { v in session.mutate { $0.audio.voiceEnhancement = v } }
            ))
            .font(.system(size: 12))

            if let sliceId = session.selectedSliceId,
               let slice = session.document.timeline.slices.first(where: { $0.id == sliceId }) {
                Divider()
                Text("Selected Clip Slice")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                coalescedSlider(
                    title: String(format: "Slice system audio (%d%%)", Int(round((slice.muted ? 0.0 : slice.systemAudioVolume) * 100))),
                    value: Binding(
                        get: { slice.muted ? 0.0 : slice.systemAudioVolume },
                        set: { v in
                            session.setSliceSystemAudioVolume(id: sliceId, volume: v)
                        }
                    ),
                    range: 0.0...1.5,
                    defaultValue: 1.0
                )

                coalescedSlider(
                    title: String(format: "Playback speed (%.2fx)", slice.speed),
                    value: Binding(
                        get: { slice.speed },
                        set: { v in
                            session.mutate { doc in
                                if let idx = doc.timeline.slices.firstIndex(where: { $0.id == sliceId }) {
                                    doc.timeline.slices[idx].speed = v
                                }
                            }
                        }
                    ),
                    range: 0.25...4.0,
                    defaultValue: 1.0
                )

                if session.document.timeline.slices.count > 1 {
                    Button(role: .destructive) {
                        session.deleteSelectedSlice()
                    } label: {
                        Label("Delete Selected Clip", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
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
            .fill(Color.white.opacity(0.07))
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
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                    }
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                }
                if let desc = description {
                    Text(desc)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
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
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(isSelected ? 0.96 : 0.80))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(isSelected ? 0.08 : 0.035))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color(red: 0.50, green: 0.44, blue: 0.78).opacity(0.85) : Color.white.opacity(0.06),
                            lineWidth: 1.0
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func inspectorCollapsibleSection<Content: View>(
        title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                    Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(0.06))
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
                            .fill(Color.white.opacity(0.035))
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
        defaultValue: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
            }

            coalescedSliderRowOnly(value: value, range: range, defaultValue: defaultValue)
        }
    }

    @ViewBuilder
    private func coalescedSliderRowOnly(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        defaultValue: Double
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

            Button {
                withAnimation(.easeOut(duration: 0.14)) {
                    value.wrappedValue = defaultValue
                }
            } label: {
                Text("Reset")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isModified ? .white.opacity(0.95) : .white.opacity(0.28))
                    .frame(width: 66, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(isModified ? 0.07 : 0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(isModified ? 0.14 : 0.06), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!isModified)
        }
    }
}

/// Interactive Cursor Style card that displays the active cursor SVG sprite (and cycles through its variants on hover when unselected, `ve` component!).
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
                        .fill(Color.white.opacity(isSelected ? 0.08 : (isHovered ? 0.065 : 0.04)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isSelected
                                ? Color(red: 0.44, green: 0.34, blue: 0.98)
                                : Color.white.opacity(isHovered ? 0.16 : 0.08),
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
}
