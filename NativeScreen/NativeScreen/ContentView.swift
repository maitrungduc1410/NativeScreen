import SwiftUI
import AppKit

/// NativeScreen Launch Hub & Multi-Project Manager.
/// Allows launching the floating Recording HUD (`NSPanel`), creating an instant interactive demo project,
/// or opening multiple `.nativescreen` projects simultaneously in separate Editor windows.
struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable private var workspace = ProjectWorkspaceStore.shared
    @Bindable private var recorder = RecordingCoordinator.shared

    var body: some View {
        HStack(spacing: 0) {
            // Left Column: Brand & Quick Recording Actions
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: "record.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.indigo)
                        Text("NativeScreen")
                            .font(.system(size: 24, weight: .bold))
                    }
                    Text("100% Native macOS & Metal Engine • 0% Idle CPU")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Primary Actions
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        recorder.onRecordingCompleted = { newSession in
                            openWindow(id: "project-editor", value: newSession.id)
                        }
                        recorder.showRecordingHUD()
                    } label: {
                        HStack {
                            Image(systemName: "macwindow.badge.plus")
                                .font(.system(size: 16, weight: .semibold))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("New Screen Recording")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Display, Smart Window Picker, or Area")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            Spacer()
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(Color.indigo, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Button {
                        if let demoSession = recorder.createInteractiveSampleProject() {
                            openWindow(id: "project-editor", value: demoSession.id)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "sparkles.tv")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.teal)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Create Interactive Showcase Project")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Test 120Hz Auto-Zoom & Multi-Track Blur")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        promptOpenProjectPackage()
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                            Text("Open .nativescreen Project…")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                if let err = recorder.lastErrorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()

                Button {
                    NSWorkspace.shared.open(ProjectWorkspaceStore.defaultProjectsDirectory)
                } label: {
                    Label("Open Projects Folder in Finder", systemImage: "folder.badge.gearshape")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .frame(width: 310)
            .background(.ultraThinMaterial)

            Divider()

            // Right Column: Recent `.nativescreen` Projects (Supports opening multiple concurrently!)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Recent Projects (.nativescreen)")
                        .font(.headline)
                    Spacer()
                    Text("Multi-window enabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if workspace.recentProjectURLs.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("No recent .nativescreen projects yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Click 'New Screen Recording' or 'Create Interactive Showcase Project' on the left.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(workspace.recentProjectURLs, id: \.path) { url in
                                HStack(spacing: 12) {
                                    Image(systemName: "play.rectangle.on.rectangle.fill")
                                        .font(.system(size: 20))
                                        .foregroundStyle(.indigo)
                                        .frame(width: 38, height: 38)
                                        .background(Color.indigo.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(url.deletingPathExtension().lastPathComponent)
                                            .font(.system(size: 13, weight: .semibold))
                                        Text(url.path)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    Button("Open Editor") {
                                        if let session = workspace.openOrFocusProject(at: url) {
                                            openWindow(id: "project-editor", value: session.id)
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                                .padding(10)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 740, minHeight: 440)
        .onAppear {
            recorder.onRecordingCompleted = { newSession in
                openWindow(id: "project-editor", value: newSession.id)
            }
        }
    }

    private func promptOpenProjectPackage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Open Project"

        if panel.runModal() == .OK {
            for url in panel.urls where url.pathExtension.lowercased() == "nativescreen" {
                if let session = workspace.openOrFocusProject(at: url) {
                    openWindow(id: "project-editor", value: session.id)
                }
            }
        }
    }
}
