import SwiftUI
import AppKit

/// Native macOS Inspector Sidebar with dark pill selectors,
/// non-truncating responsive controls, and quick "Reset" buttons on sliders.
public struct InspectorSidebarView: View {
    @Bindable var session: ProjectSession
    @State private var systemWallpapers: [SystemWallpaperItem] = []

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
                        activeColor: Color.white.opacity(0.18),
                        size: 36,
                        cornerRadius: 9
                    ) {
                        session.selectedInspectorTab = tab
                    } label: {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isSelected ? .white : .secondary)
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
                VStack(alignment: .leading, spacing: 18) {
                    Text(session.selectedInspectorTab.rawValue)
                        .font(.system(size: 14, weight: .bold))
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
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 304)
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
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? .white : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                isSelected
                                    ? Color.white.opacity(0.14)
                                    : Color.white.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                                    if let nsImg = NSImage(contentsOf: item.thumbnailURL) {
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

    // MARK: - 2. Cursor & Spring Physics Inspector

    @ViewBuilder
    private var cursorInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Hide cursor", isOn: Binding(
                get: { session.document.cursor.hidden },
                set: { v in session.mutate { $0.cursor.hidden = v } }
            ))
            .font(.system(size: 12))

            coalescedSlider(
                title: "Cursor size",
                value: Binding(
                    get: { session.document.cursor.scale },
                    set: { v in session.mutate { $0.cursor.scale = v } }
                ),
                range: 0.5...3.5,
                defaultValue: 1.6
            )

            Divider()

            Toggle("Smooth spring movement", isOn: Binding(
                get: { session.document.cursor.smoothMovementEnabled },
                set: { v in session.mutate { $0.cursor.smoothMovementEnabled = v } }
            ))
            .font(.system(size: 12))

            coalescedSlider(
                title: "Spring stiffness",
                value: Binding(
                    get: { session.document.cursor.spring.stiffness },
                    set: { v in session.mutate { $0.cursor.spring.stiffness = v } }
                ),
                range: 40...300,
                defaultValue: 125.0
            )

            coalescedSlider(
                title: "Spring damping",
                value: Binding(
                    get: { session.document.cursor.spring.damping },
                    set: { v in session.mutate { $0.cursor.spring.damping = v } }
                ),
                range: 5...35,
                defaultValue: 12.0
            )

            coalescedSlider(
                title: "Remove cursor shake",
                value: Binding(
                    get: { session.document.cursor.removeShakeThresholdPx },
                    set: { v in session.mutate { $0.cursor.removeShakeThresholdPx = v } }
                ),
                range: 0...20,
                defaultValue: 4.0
            )

            Toggle("Loop cursor position before end", isOn: Binding(
                get: { session.document.cursor.loopBackToStartMs != nil },
                set: { enabled in session.mutate { $0.cursor.loopBackToStartMs = enabled ? 800.0 : nil } }
            ))
            .font(.system(size: 12))
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

            coalescedSlider(
                title: "Camera motion blur",
                value: Binding(
                    get: { session.document.motion.motionBlurIntensity },
                    set: { v in session.mutate { $0.motion.motionBlurIntensity = v } }
                ),
                range: 0.0...1.5,
                defaultValue: 0.5
            )

            Toggle("Avoid empty area when zooming", isOn: Binding(
                get: { session.document.motion.avoidEmptyBoundsWhenZooming },
                set: { v in session.mutate { $0.motion.avoidEmptyBoundsWhenZooming = v } }
            ))
            .font(.system(size: 12))
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

            if let maskId = session.selectedMaskId,
               let mask = findMask(byId: maskId) {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Mask Mode")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Picker("", selection: Binding(
                        get: { mask.type },
                        set: { newType in updateMask(id: maskId) { $0.type = newType } }
                    )) {
                        Text("Blur / Redact").tag(MaskType.blur)
                        Text("Spotlight").tag(MaskType.spotlight)
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
                }

                coalescedSlider(
                    title: "Intensity",
                    value: Binding(
                        get: { mask.intensity },
                        set: { v in updateMask(id: maskId) { $0.intensity = v } }
                    ),
                    range: 6...80,
                    defaultValue: 36.0
                )

                coalescedSlider(
                    title: "Corner radius",
                    value: Binding(
                        get: { mask.cornerRadius },
                        set: { v in updateMask(id: maskId) { $0.cornerRadius = v } }
                    ),
                    range: 0...40,
                    defaultValue: 10.0
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
    private func coalescedSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        defaultValue: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))

            HStack(spacing: 8) {
                Slider(value: value, in: range) { editing in
                    if editing {
                        session.beginInteractiveEdit()
                    } else {
                        session.endInteractiveEdit()
                    }
                }
                .tint(Color(red: 0.52, green: 0.42, blue: 0.98))
                .controlSize(.small)

                Button("Reset") {
                    value.wrappedValue = defaultValue
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                .opacity(abs(value.wrappedValue - defaultValue) > 0.005 ? 1.0 : 0.35)
                .disabled(abs(value.wrappedValue - defaultValue) <= 0.005)
            }
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
