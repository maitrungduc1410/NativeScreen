import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// `File > Create project from video…`: turns any movie file into a `.nativescreen` project.
/// The video becomes `recording/display.<ext>` (its audio, if any, is the system-audio track). There is no cursor,
/// click or key telemetry, so the editor offers manual zoom positioning instead of cursor-following zooms.
@MainActor
enum VideoProjectImporter {
    static func promptAndCreateProject() {
        let panel = NSOpenPanel()
        panel.message = "Choose a video to create a project from"
        panel.prompt = "Create Project"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await createProject(from: url)
        }
    }

    static func createProject(from videoURL: URL) async {
        do {
            let packageURL = try await buildPackage(from: videoURL)
            ProjectWorkspaceStore.shared.openOrFocusProject(at: packageURL)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not create a project from “\(videoURL.lastPathComponent)”"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private static func buildPackage(from videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw importError("The file has no video track.")
        }
        let durationMs = CMTimeGetSeconds(try await asset.load(.duration)) * 1000.0
        guard durationMs.isFinite, durationMs > 100.0 else {
            throw importError("The video is empty or too short.")
        }
        let (naturalSize, transform, fps) = try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let displaySize = naturalSize.applying(transform)
        let width = Int(abs(displaySize.width).rounded())
        let height = Int(abs(displaySize.height).rounded())
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty

        let name = videoURL.deletingPathExtension().lastPathComponent
        let packageURL = uniquePackageURL(named: name)
        let recordingDir = packageURL.appendingPathComponent("recording", isDirectory: true)
        let telemetryDir = recordingDir.appendingPathComponent("telemetry", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: telemetryDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: packageURL.appendingPathComponent("assets", isDirectory: true), withIntermediateDirectories: true)

        let ext = videoURL.pathExtension.isEmpty ? "mp4" : videoURL.pathExtension.lowercased()
        let displayName = "display.\(ext)"
        let destination = recordingDir.appendingPathComponent(displayName)
        do {
            // Copy off the main actor: instant on APFS (clone), but a cross-volume copy of a long video takes a while.
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: videoURL, to: destination)
            }.value
        } catch {
            try? fm.removeItem(at: packageURL)
            throw error
        }

        let tracks = RecordingTracksMetadata(
            displayVideo: displayName,
            systemAudio: hasAudio ? displayName : nil,
            windowTelemetry: nil
        )
        for telemetry in [tracks.cursorTelemetry, tracks.clicksTelemetry, tracks.keysTelemetry] {
            fm.createFile(atPath: recordingDir.appendingPathComponent(telemetry).path, contents: Data())
        }

        let metadata = RecordingMetadata(
            durationMs: durationMs,
            captureTarget: CaptureTargetMetadata(
                mode: .display,
                displayId: 0,
                windowTitle: videoURL.lastPathComponent,
                logicalBounds: LogicalBounds(x: 0, y: 0, width: Double(width), height: Double(height)),
                pixelSize: PixelDimensions(width: width, height: height),
                scaleFactor: 1.0,
                refreshRate: fps > 0 ? Double(fps) : 60.0,
                windowBorderRadius: 0.0
            ),
            tracks: tracks
        )

        var doc = ProjectDocument(
            name: name,
            camera: CameraConfig(enabled: false),
            timeline: TimelineConfig(
                slices: [ClipSlice(sourceStartMs: 0.0, sourceEndMs: durationMs, speed: 1.0)],
                zooms: [],
                maskTracks: []
            )
        )
        if let defaultPreset = ProjectPresetsStore.shared.defaultPreset {
            defaultPreset.apply(to: &doc)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: recordingDir.appendingPathComponent("metadata.json"), options: .atomic)
        try encoder.encode(doc).write(to: packageURL.appendingPathComponent("project.json"), options: .atomic)
        return packageURL
    }

    private static func uniquePackageURL(named name: String) -> URL {
        let dir = ProjectWorkspaceStore.defaultProjectsDirectory
        var candidate = dir.appendingPathComponent("\(name).nativescreen", isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(name) \(suffix).nativescreen", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private static func importError(_ message: String) -> NSError {
        NSError(domain: "NativeScreenImport", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
