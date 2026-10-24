import SwiftUI
import AppKit

/// Native macOS Inspector Sidebar ("80% OS Native Controls") with tabs for:
/// - Background (Mesh Presets, `/System/Library/Desktop Pictures` Wallpapers, Gradients, Padding, Corners, Shadow)
/// - Cursor (Size, Spring Smoothness, Shake Filter, Click Ripple)
/// - Zoom (Auto-Zoom Cluster Regeneration, Selected Zoom Scale & Mode, Motion Blur)
/// - Multi-Track Masks (Add/Configure Unlimited Blur, Pixelate & Spotlight Regions)
/// - Audio & Slice Speed
public struct InspectorSidebarView: View {
    @Bindable var session: ProjectSession
    @State private var systemWallpapers: [SystemWallpaperItem] = []

    public init(session: ProjectSession) {
        self.session = session
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Vertical Icon Rail right-side navigation rail)
            VStack(spacing: 12) {
                ForEach(ProjectSession.InspectorTab.allCases) { tab in
                    Button {
                        session.selectedInspectorTab = tab
                    } label: {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(session.selectedInspectorTab == tab ? Color.accentColor : .secondary)
                            .frame(width: 34, height: 34)
                            .background(
                                session.selectedInspectorTab == tab
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(tab.rawValue)
                }
                Spacer()
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 6)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Active Inspector Panel
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(session.selectedInspectorTab.rawValue)
                        .font(.system(size: 15, weight: .bold))

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
            }
            .frame(width: 276)
            .background(Color(nsColor: .controlBackgroundColor))
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
        VStack(alignment: .leading, spacing: 14) {
            Picker("Mode", selection: Binding(
                get: { session.document.background.type },
                set: { newType in session.mutate { $0.background.type = newType } }
            )) {
                ForEach(BackgroundType.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch session.document.background.type {
            case .mesh:
                Text("Mesh Gradient Presets")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 8) {
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
                                .frame(height: 36)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(preset.name)
                    }
                }

            case .wallpaper:
                Text("macOS System Wallpapers")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
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
                                        .frame(width: 72, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                                        )
                                } else {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(Color.secondary.opacity(0.2))
                                        .frame(width: 72, height: 44)
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

            case .gradient, .solid, .image:
                HStack {
                    Text("Primary Color Hex")
                        .font(.caption)
                    Spacer()
                    TextField("#1E1E2E", text: Binding(
                        get: { session.document.background.solidColor },
                        set: { hex in session.mutate { $0.background.solidColor = hex } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 95)
                }
            }

            Divider()

            coalescedSlider(
                title: "Background Blur",
                value: Binding(
                    get: { session.document.background.blurRadius },
                    set: { v in session.mutate { $0.background.blurRadius = v } }
                ),
                range: 0...60
            )

            coalescedSlider(
                title: "Canvas Padding",
                value: Binding(
                    get: { session.document.canvas.paddingRatio },
                    set: { v in session.mutate { $0.canvas.paddingRatio = v } }
                ),
                range: 0.0...0.30
            )

            coalescedSlider(
                title: "Screen Rounded Corners",
                value: Binding(
                    get: { session.document.frameStyle.borderRadius },
                    set: { v in session.mutate { $0.frameStyle.borderRadius = v } }
                ),
                range: 0...44
            )

            coalescedSlider(
                title: "Shadow Intensity",
                value: Binding(
                    get: { session.document.frameStyle.shadow.intensity },
                    set: { v in session.mutate { $0.frameStyle.shadow.intensity = v } }
                ),
                range: 0...1.0
            )
        }
    }

    // MARK: - 2. Cursor & Spring Physics Inspector

    @ViewBuilder
    private var cursorInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Hide Cursor", isOn: Binding(
                get: { session.document.cursor.hidden },
                set: { v in session.mutate { $0.cursor.hidden = v } }
            ))

            coalescedSlider(
                title: "Cursor Size",
                value: Binding(
                    get: { session.document.cursor.scale },
                    set: { v in session.mutate { $0.cursor.scale = v } }
                ),
                range: 0.5...3.5
            )

            Divider()

            Toggle("Smooth Spring Glide", isOn: Binding(
                get: { session.document.cursor.smoothMovementEnabled },
                set: { v in session.mutate { $0.cursor.smoothMovementEnabled = v } }
            ))

            coalescedSlider(
                title: "Spring Stiffness",
                value: Binding(
                    get: { session.document.cursor.spring.stiffness },
                    set: { v in session.mutate { $0.cursor.spring.stiffness = v } }
                ),
                range: 40...300
            )

            coalescedSlider(
                title: "Spring Damping",
                value: Binding(
                    get: { session.document.cursor.spring.damping },
                    set: { v in session.mutate { $0.cursor.spring.damping = v } }
                ),
                range: 5...35
            )

            coalescedSlider(
                title: "Micro-Shake Filter (px)",
                value: Binding(
                    get: { session.document.cursor.removeShakeThresholdPx },
                    set: { v in session.mutate { $0.cursor.removeShakeThresholdPx = v } }
                ),
                range: 0...20
            )

            Toggle("Loop Cursor Position at End", isOn: Binding(
                get: { session.document.cursor.loopBackToStartMs != nil },
                set: { enabled in session.mutate { $0.cursor.loopBackToStartMs = enabled ? 800.0 : nil } }
            ))
        }
    }

    // MARK: - 3. Auto-Zoom & Camera Motion Blur Inspector

    @ViewBuilder
    private var zoomInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button {
                    session.addZoomAtPlayhead()
                } label: {
                    Label("Add Zoom Block", systemImage: "plus.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    session.regenerateAutoZooms()
                } label: {
                    Label("Auto-Cluster", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let zoomId = session.selectedZoomId,
               let zoom = session.document.timeline.zooms.first(where: { $0.id == zoomId }) {
                Divider()
                Text("Selected Zoom Block")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                coalescedSlider(
                    title: String(format: "Zoom Factor (%.1fx)", zoom.scale),
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
                    range: 1.1...3.5
                )

                Picker("Tracking", selection: Binding(
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

                Button(role: .destructive) {
                    session.mutate { doc in
                        doc.timeline.zooms.removeAll { $0.id == zoomId }
                    }
                    session.selectedZoomId = nil
                } label: {
                    Label("Delete Zoom Block", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            coalescedSlider(
                title: "Camera Motion Blur",
                value: Binding(
                    get: { session.document.motion.motionBlurIntensity },
                    set: { v in session.mutate { $0.motion.motionBlurIntensity = v } }
                ),
                range: 0.0...1.5
            )

            Toggle("Clamp to Screen Edges", isOn: Binding(
                get: { session.document.motion.avoidEmptyBoundsWhenZooming },
                set: { v in session.mutate { $0.motion.avoidEmptyBoundsWhenZooming = v } }
            ))
        }
    }

    // MARK: - 4. Multi-Track Masks & Sensitive Data Blur Inspector

    @ViewBuilder
    private var masksInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Unlimited parallel Blur, Pixelate & Spotlight tracks. Drag boxes directly on the preview canvas.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    session.addMaskAtPlayhead(type: .blur, style: .gaussian)
                } label: {
                    Label("+ Blur", systemImage: "eye.slash.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .controlSize(.small)

                Button {
                    session.addMaskAtPlayhead(type: .blur, style: .pixelate)
                } label: {
                    Label("+ Pixelate", systemImage: "square.grid.3x3.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    session.addMaskAtPlayhead(type: .spotlight, style: .dim)
                } label: {
                    Label("+ Spotlight", systemImage: "flashlight.on.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let maskId = session.selectedMaskId,
               let mask = findMask(byId: maskId) {
                Divider()
                Text("Selected Mask Region")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Type", selection: Binding(
                    get: { mask.type },
                    set: { newType in updateMask(id: maskId) { $0.type = newType } }
                )) {
                    Text("Blur / Redact").tag(MaskType.blur)
                    Text("Spotlight").tag(MaskType.spotlight)
                }
                .pickerStyle(.segmented)

                if mask.type == .blur {
                    Picker("Style", selection: Binding(
                        get: { mask.style },
                        set: { newStyle in updateMask(id: maskId) { $0.style = newStyle } }
                    )) {
                        Text("Gaussian").tag(MaskStyle.gaussian)
                        Text("Pixelate").tag(MaskStyle.pixelate)
                        Text("Solid Box").tag(MaskStyle.solid)
                    }
                    .pickerStyle(.segmented)
                }

                coalescedSlider(
                    title: "Blur / Pixelate Intensity",
                    value: Binding(
                        get: { mask.intensity },
                        set: { v in updateMask(id: maskId) { $0.intensity = v } }
                    ),
                    range: 6...80
                )

                coalescedSlider(
                    title: "Mask Corner Radius",
                    value: Binding(
                        get: { mask.cornerRadius },
                        set: { v in updateMask(id: maskId) { $0.cornerRadius = v } }
                    ),
                    range: 0...40
                )

                Button(role: .destructive) {
                    session.deleteMask(maskId: maskId)
                } label: {
                    Label("Delete Mask Region", systemImage: "trash")
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
                title: "System Audio Volume",
                value: Binding(
                    get: { session.document.audio.systemAudioVolume },
                    set: { v in session.mutate { $0.audio.systemAudioVolume = v } }
                ),
                range: 0...1.5
            )

            coalescedSlider(
                title: "Microphone Volume",
                value: Binding(
                    get: { session.document.audio.microphoneVolume },
                    set: { v in session.mutate { $0.audio.microphoneVolume = v } }
                ),
                range: 0...1.5
            )

            Toggle("Voice Enhancement", isOn: Binding(
                get: { session.document.audio.voiceEnhancement },
                set: { v in session.mutate { $0.audio.voiceEnhancement = v } }
            ))

            if let sliceId = session.selectedSliceId,
               let slice = session.document.timeline.slices.first(where: { $0.id == sliceId }) {
                Divider()
                Text("Selected Clip Slice")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                coalescedSlider(
                    title: String(format: "Clip Playback Speed (%.2fx)", slice.speed),
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
                    range: 0.25...4.0
                )

                if session.document.timeline.slices.count > 1 {
                    Button(role: .destructive) {
                        session.deleteSelectedSlice()
                    } label: {
                        Label("Delete Selected Clip", systemImage: "trash")
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
    private func coalescedSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range) { editing in
                if editing {
                    session.beginInteractiveEdit()
                } else {
                    session.endInteractiveEdit()
                }
            }
            .controlSize(.small)
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
