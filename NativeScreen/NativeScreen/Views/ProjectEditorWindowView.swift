import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Full Native macOS Editor Window for a single `.nativescreen` project session.
/// Multiple instances of `ProjectEditorWindowView` can run concurrently for simultaneous multi-project editing.
public struct ProjectEditorWindowView: View {
    @Bindable var session: ProjectSession

    @State private var isShowingExportSheet = false
    @State private var exportCodec: HardwareVideoExporter.ExportCodec = .h264
    @State private var exportResolution: HardwareVideoExporter.ExportResolution = .qhd2k
    @State private var isExporting = false
    @State private var exportProgress: Double = 0.0
    @State private var exportError: String?

    public init(session: ProjectSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Canvas Control Bar
            HStack(spacing: 14) {
                // Aspect Ratio Picker
                Picker("Aspect Ratio", selection: Binding(
                    get: { session.document.canvas.aspectRatioPreset },
                    set: { preset in
                        session.mutate {
                            $0.canvas.aspectRatioMode = .preset
                            $0.canvas.aspectRatioPreset = preset
                        }
                    }
                )) {
                    ForEach(AspectRatioPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 150)

                Button {
                    session.addMaskAtPlayhead(type: .blur, style: .gaussian)
                } label: {
                    Label("Add Blur Region", systemImage: "eye.slash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                // Snapshot Undo / Redo Buttons
                HStack(spacing: 6) {
                    Button {
                        session.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!session.canUndo)
                    .keyboardShortcut("z", modifiers: [.command])
                    .help("Undo (⌘Z)")

                    Button {
                        session.redo()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .disabled(!session.canRedo)
                    .keyboardShortcut("Z", modifiers: [.command, .shift])
                    .help("Redo (⇧⌘Z)")
                }

                Button {
                    isShowingExportSheet = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider()

            // Center Area: Metal GPU Preview Canvas + Right Inspector Sidebar
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    // GPU Preview Container
                    GeometryReader { geo in
                        let aspect = session.document.canvas.effectiveAspectRatio(
                            sourceWidth: Double(session.metadata.captureTarget.pixelSize.width),
                            sourceHeight: Double(session.metadata.captureTarget.pixelSize.height)
                        )
                        let fittedSize = fitPreviewCanvas(in: geo.size, aspect: aspect)

                        ZStack {
                            Color.black.opacity(0.92)

                            ZStack {
                                MetalPreviewView(session: session)
                                InteractiveMaskCanvasOverlayView(session: session, canvasSize: fittedSize)
                            }
                            .frame(width: fittedSize.width, height: fittedSize.height)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    // Transport Playback Bar
                    HStack(spacing: 18) {
                        Text(formatTimecode(session.playheadTimelineMs))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Button {
                            session.isPlaying = false
                            session.seek(toTimelineMs: 0.0)
                        } label: {
                            Image(systemName: "backward.end.fill")
                        }
                        .buttonStyle(.plain)

                        Button {
                            session.isPlaying.toggle()
                        } label: {
                            Image(systemName: session.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.space, modifiers: [])

                        Button {
                            session.isPlaying = false
                            session.seek(toTimelineMs: session.timeMapper.totalTimelineDurationMs)
                        } label: {
                            Image(systemName: "forward.end.fill")
                        }
                        .buttonStyle(.plain)

                        Text(formatTimecode(session.timeMapper.totalTimelineDurationMs))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                }

                Divider()

                InspectorSidebarView(session: session)
            }

            Divider()

            // Bottom Multi-Track NLE Timeline
            MultiTrackTimelineView(session: session)
                .frame(height: 225)
        }
        .navigationTitle("\(session.document.name).nativescreen")
        .sheet(isPresented: $isShowingExportSheet) {
            exportModalSheet
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
        let availW = max(120, container.width - 36)
        let availH = max(120, container.height - 28)
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
