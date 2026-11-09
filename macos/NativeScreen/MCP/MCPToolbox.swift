import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The MCP tools. Definitions (names, descriptions, input schemas) live in `Resources/MCPTools.json`, shared with
/// the Windows app; this type runs them on the main actor against the same objects the UI uses.
@MainActor
final class MCPToolbox {
    let instructions: String
    let definitions: [[String: Any]]

    /// Exports started by agents, for `get_status`.
    private var activeExports: [String: (project: String, progress: Double)] = [:]

    init() {
        guard let url = Bundle.main.url(forResource: "MCPTools", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            instructions = ""
            definitions = []
            return
        }
        instructions = root["instructions"] as? String ?? ""
        let shared = root["definitions"] as? [String: Any] ?? [:]
        let tools = root["tools"] as? [[String: Any]] ?? []
        // Clients do not resolve `$ref` across files, so shared definitions are inlined here.
        definitions = tools.map { Self.inlineRefs($0, definitions: shared) as? [String: Any] ?? $0 }
    }

    private static func inlineRefs(_ value: Any, definitions: [String: Any]) -> Any {
        if let object = value as? [String: Any] {
            if let ref = object["$ref"] as? String, ref.hasPrefix("#/definitions/"),
               let resolved = definitions[String(ref.dropFirst("#/definitions/".count))] {
                return resolved
            }
            return object.mapValues { inlineRefs($0, definitions: definitions) }
        }
        if let array = value as? [Any] {
            return array.map { inlineRefs($0, definitions: definitions) }
        }
        return value
    }

    // MARK: - Dispatch

    /// Checks the top-level arguments against the tool's schema. Omitting `project` means the frontmost editor, so a
    /// misspelled key must fail rather than be ignored: it would otherwise run the tool on the wrong project.
    private func validate(tool name: String, arguments raw: [String: Any]) throws {
        guard let schema = definitions.first(where: { $0["name"] as? String == name })?["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any]
        else { return }
        let unknown = raw.keys.filter { properties[$0] == nil }.sorted()
        if !unknown.isEmpty {
            let accepted = properties.isEmpty ? "no arguments" : properties.keys.sorted().joined(separator: ", ")
            throw MCPToolError("Unknown argument \(unknown.joined(separator: ", ")) for \(name). It accepts: \(accepted).")
        }
        for key in schema["required"] as? [String] ?? [] {
            let value = raw[key]
            if value == nil || value is NSNull || (value as? String)?.isEmpty == true {
                throw MCPToolError("Missing argument: \(key)")
            }
        }
    }

    func call(name: String, arguments raw: [String: Any], progress: MCPProgress?) async -> [String: Any] {
        let args = MCPArguments(raw: raw)
        do {
            try validate(tool: name, arguments: raw)
            switch name {
            case "get_status": return ok(getStatus())
            case "list_projects": return ok(listProjects(args))
            case "open_project": return ok(try openProject(args))
            case "create_project_from_video": return ok(try await createProjectFromVideo(args))
            case "close_project": return ok(try closeProject(args))
            case "delete_project": return ok(try deleteProject(args))
            case "rename_project": return ok(try renameProject(args))
            case "save_project": return ok(try saveProject(args))
            case "get_project": return ok(try getProject(args))
            case "update_project": return ok(try updateProject(args))
            case "add_item": return ok(try addItem(args))
            case "update_item": return ok(try updateItem(args))
            case "delete_item": return ok(try deleteItem(args))
            case "split_item": return ok(try splitItem(args))
            case "undo": return ok(try history(args, redo: false))
            case "redo": return ok(try history(args, redo: true))
            case "render_frame": return try await renderFrame(args)
            case "run_action": return ok(try runAction(args))
            case "list_options": return ok(try listOptions(args))
            case "set_background": return ok(try setBackground(args))
            case "apply_preset": return ok(try applyPreset(args))
            case "list_capture_targets": return ok(listCaptureTargets())
            case "start_recording": return ok(try startRecording(args))
            case "control_recording": return ok(try await controlRecording(args))
            case "get_settings": return ok(getSettings())
            case "update_settings": return ok(try updateSettings(args))
            case "export_video": return ok(try await exportVideo(args, progress: progress))
            case "export_frame": return ok(try await exportFrame(args))
            default: throw MCPToolError("Unknown tool: \(name)")
            }
        } catch let error as MCPToolError {
            return failure(error.message)
        } catch is CancellationError {
            return failure("Cancelled.")
        } catch {
            return failure(error.localizedDescription)
        }
    }

    private func ok(_ value: Any) -> [String: Any] {
        var result: [String: Any] = ["content": [["type": "text", "text": MCPJSON.text(value)]]]
        if let object = value as? [String: Any] {
            result["structuredContent"] = object
        }
        return result
    }

    private func failure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    // MARK: - Projects

    /// `project` argument: a session id, a package path (opened if needed), or nothing for the frontmost editor.
    private func session(_ args: MCPArguments) throws -> ProjectSession {
        let workspace = ProjectWorkspaceStore.shared
        if let value = args.string("project") {
            if let uuid = UUID(uuidString: value), let session = workspace.session(for: uuid) {
                return session
            }
            let url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
            if let open = workspace.sessionsByID.values.first(where: { $0.packageURL.standardizedFileURL == url }) {
                return open
            }
            guard url.pathExtension == "nativescreen", FileManager.default.fileExists(atPath: url.path),
                  let opened = workspace.openOrFocusProject(at: url)
            else { throw MCPToolError("No open project with id or path \(value). Use get_status or list_projects.") }
            return opened
        }
        if let active = workspace.activeSession { return active }
        let open = Array(workspace.sessionsByID.values)
        if open.count == 1 { return open[0] }
        throw MCPToolError(open.isEmpty
            ? "No project is open. Use open_project, list_projects or start_recording."
            : "Several projects are open; pass project (an id from get_status).")
    }

    private func summary(_ session: ProjectSession) -> [String: Any] {
        [
            "id": session.id.uuidString,
            "name": session.document.name,
            "path": session.packageURL.path,
            "isFrontmost": ProjectWorkspaceStore.shared.activeSession === session,
            "hasUnsavedChanges": session.hasUnsavedChanges,
            "timelineDurationMs": session.timeMapper.totalTimelineDurationMs,
        ]
    }

    private func getStatus() -> [String: Any] {
        let recorder = RecordingCoordinator.shared
        let state: String
        if recorder.isRecording {
            state = recorder.isRecordingPaused ? "paused" : "recording"
        } else if recorder.isCountingDown {
            state = "counting_down"
        } else if recorder.isPickingTarget {
            state = "picking_target"
        } else {
            state = "idle"
        }
        var recording: [String: Any] = [
            "state": state,
            "mode": recorder.selectedMode.rawValue,
            "elapsedSeconds": recorder.recordingElapsedSeconds,
        ]
        if let error = recorder.lastErrorMessage { recording["lastError"] = error }
        return [
            "app": ["version": MCPServer.appVersion],
            "projects": ProjectWorkspaceStore.shared.sessionsByID.values
                .sorted { $0.document.name < $1.document.name }
                .map(summary),
            "recording": recording,
            "exports": activeExports.map { ["id": $0.key, "project": $0.value.project, "progress": $0.value.progress] },
        ]
    }

    private func listProjects(_ args: MCPArguments) -> [String: Any] {
        let limit = args.int("limit") ?? 30
        let fm = FileManager.default
        var urls = ProjectWorkspaceStore.shared.recentProjectURLs.filter { fm.fileExists(atPath: $0.path) }
        let folder = URL(fileURLWithPath: AppSettings.shared.projectsDirectoryPath, isDirectory: true)
        let found = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "nativescreen" } ?? []
        for url in found where !urls.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            urls.append(url)
        }
        func modified(_ url: URL) -> Date {
            let projectJSON = url.appendingPathComponent("project.json")
            return (try? fm.attributesOfItem(atPath: projectJSON.path)[.modificationDate] as? Date) ?? .distantPast
        }
        let sorted = urls.map { ($0, modified($0)) }.sorted { $0.1 > $1.1 }.prefix(limit)
        let iso = ISO8601DateFormatter()
        let open = ProjectWorkspaceStore.shared.sessionsByID.values
        return [
            "projectsFolder": folder.path,
            "projects": sorted.map { url, date in
                var entry: [String: Any] = [
                    "name": url.deletingPathExtension().lastPathComponent,
                    "path": url.path,
                    "modified": iso.string(from: date),
                ]
                if let session = open.first(where: { $0.packageURL.standardizedFileURL == url.standardizedFileURL }) {
                    entry["openId"] = session.id.uuidString
                }
                return entry
            },
        ]
    }

    private func openProject(_ args: MCPArguments) throws -> [String: Any] {
        let path = (try args.requiredString("path") as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path) else {
            throw MCPToolError("Not a Native Screen project: \(path)")
        }
        guard let session = ProjectWorkspaceStore.shared.openOrFocusProject(at: url) else {
            throw MCPToolError("Could not open \(path).")
        }
        return summary(session)
    }

    private func createProjectFromVideo(_ args: MCPArguments) async throws -> [String: Any] {
        let path = (try args.requiredString("path") as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { throw MCPToolError("File not found: \(path)") }
        let packageURL = try await VideoProjectImporter.buildPackage(from: url)
        guard let session = ProjectWorkspaceStore.shared.openOrFocusProject(at: packageURL) else {
            throw MCPToolError("The project was created at \(packageURL.path) but could not be opened.")
        }
        return summary(session)
    }

    private func closeProject(_ args: MCPArguments) throws -> [String: Any] {
        let session = try session(args)
        try session.saveNow()
        ProjectWorkspaceStore.shared.closeEditorWindow(for: session)
        return ["closed": session.packageURL.path]
    }

    private func deleteProject(_ args: MCPArguments) throws -> [String: Any] {
        let session = try session(args)
        let path = session.packageURL.path
        session.isPlaying = false
        ProjectWorkspaceStore.shared.trashProject(session)
        guard !FileManager.default.fileExists(atPath: path) else { throw MCPToolError("Could not move \(path) to the Trash.") }
        ProjectWorkspaceStore.shared.closeEditorWindow(for: session)
        return ["movedToTrash": path]
    }

    private func renameProject(_ args: MCPArguments) throws -> [String: Any] {
        let session = try session(args)
        session.startNewUndoStep()
        session.renameProject(to: try args.requiredString("name"))
        return summary(session)
    }

    private func saveProject(_ args: MCPArguments) throws -> [String: Any] {
        let session = try session(args)
        try session.saveNow()
        return summary(session)
    }

    // MARK: - Document

    private func getProject(_ args: MCPArguments) throws -> [String: Any] {
        let session = try session(args)
        guard var document = try MCPJSON.object(session.document) as? [String: Any] else {
            throw MCPToolError("Could not encode the project.")
        }
        let words = session.document.captions.segments.count
        if args.bool("include_transcript") != true, var captions = document["captions"] as? [String: Any] {
            captions["segments"] = nil
            document["captions"] = captions
        }

        var timelineStart = 0.0
        let slices: [[String: Any]] = session.document.timeline.slices.map { slice in
            let start = timelineStart
            timelineStart += slice.timelineDurationMs
            return [
                "id": slice.id,
                "sourceStartMs": slice.sourceStartMs,
                "sourceEndMs": slice.sourceEndMs,
                "speed": slice.speed,
                "timelineStartMs": start,
                "timelineEndMs": timelineStart,
            ]
        }
        let shortcuts: [[String: Any]] = session.detectedShortcutClusters.map { cluster in
            [
                "id": cluster.id,
                "trackId": cluster.trackId,
                "keys": cluster.compactTimelineLabel,
                "sourceStartMs": cluster.displayStartMs,
                "sourceEndMs": cluster.displayEndMs,
                "isCustom": cluster.isCustomSegment,
                "hidden": session.isShortcutHidden(cluster),
            ]
        }
        var info: [String: Any] = [
            "id": session.id.uuidString,
            "path": session.packageURL.path,
            "hasUnsavedChanges": session.hasUnsavedChanges,
            "canUndo": session.canUndo,
            "canRedo": session.canRedo,
            "sourceDurationMs": session.metadata.durationMs,
            "timelineDurationMs": session.timeMapper.totalTimelineDurationMs,
            "playheadTimelineMs": session.playheadTimelineMs,
            "isPlaying": session.isPlaying,
            "sourcePixelSize": [
                "width": session.metadata.captureTarget.pixelSize.width,
                "height": session.metadata.captureTarget.pixelSize.height,
            ],
            "recorded": [
                "camera": session.hasRecordedCamera,
                "microphone": session.microphoneAudioFileURL != nil,
                "systemAudio": session.metadata.tracks.systemAudio != nil,
                "cursor": session.hasRecordedCursor,
                "clicks": session.clickEvents.count,
                "keystrokes": session.keyEvents.count,
            ],
            "slices": slices,
            "shortcuts": shortcuts,
            "transcriptWordCount": words,
            "isGeneratingTranscript": session.isGeneratingTranscript,
        ]
        if let error = session.transcriptErrorMessage { info["transcriptError"] = error }
        return ["info": info, "document": document]
    }

    private func updateProject(_ args: MCPArguments) throws -> [String: Any] {
        let session = try session(args)
        guard let patch = args.object("patch") else { throw MCPToolError("Missing argument: patch") }
        var next = try MCPJSON.patched(session.document, with: patch)
        next.id = session.document.id
        next.schemaVersion = session.document.schemaVersion
        let changed = next != session.document
        session.startNewUndoStep()
        session.mutate { $0 = next }
        return ["changed": changed]
    }

    // MARK: - Timeline items

    /// Every item id currently in the document, to find the one an `add` created.
    private func allItemIDs(_ doc: ProjectDocument) -> Set<String> {
        var ids = Set(doc.timeline.zooms.map(\.id))
        ids.formUnion(doc.timeline.cameraLayouts.map(\.id))
        ids.formUnion(doc.timeline.maskTracks.flatMap { $0.items.map(\.id) })
        ids.formUnion(doc.captions.captionBlocks.map(\.id))
        ids.formUnion(doc.captions.customShortcuts.map(\.id))
        return ids
    }

    private func addItem(_ args: MCPArguments) throws -> [String: Any] {
        let session = try session(args)
        let kind = try args.requiredString("kind")
        session.startNewUndoStep()

        switch kind {
        case "caption_track":
            return ["id": session.addCaptionTrack()]
        case "shortcut_track":
            return ["id": session.addShortcutTrack()]
        default:
            break
        }

        let start = try args.requiredDouble("sourceStartMs")
        let end = try args.requiredDouble("sourceEndMs")
        let duration = session.metadata.durationMs
        guard start >= 0, end > start, start < duration else {
            throw MCPToolError("sourceStartMs and sourceEndMs must be inside 0...\(Int(duration)) with end after start.")
        }
        let clampedEnd = min(end, duration)
        let before = allItemIDs(session.document)
        var newID: String?
        let doc = session.document
        switch kind {
        case "zoom":
            try Self.requireFree(doc.timeline.zooms.map { ($0.id, $0.sourceStartMs, $0.sourceEndMs) }, start, clampedEnd, what: "zoom")
        case "camera_layout":
            try Self.requireFree(doc.timeline.cameraLayouts.map { ($0.id, $0.sourceStartMs, $0.sourceEndMs) }, start, clampedEnd, what: "camera layout")
        case "caption":
            if let trackId = args.string("trackId") ?? doc.captions.captionTracks.first?.id {
                try Self.requireFree(
                    doc.captions.captionBlocks.filter { $0.trackId == trackId }.map { ($0.id, $0.sourceStartMs, $0.sourceEndMs) },
                    start, clampedEnd, what: "caption on that track (pass another trackId, or trackId \"new\" for a new track)"
                )
            }
        case "mask":
            if let trackId = args.string("trackId"), let track = doc.timeline.maskTracks.first(where: { $0.id == trackId }) {
                try Self.requireFree(track.items.map { ($0.id, $0.sourceStartMs, $0.sourceEndMs) }, start, clampedEnd, what: "mask on that track")
            }
        default:
            break
        }

        switch kind {
        case "zoom":
            guard clampedEnd - start >= 350 else { throw MCPToolError("A zoom must last at least 350 ms.") }
            session.addZoomInRange(sourceStartMs: start, sourceEndMs: clampedEnd)
        case "mask":
            guard clampedEnd - start >= 300 else { throw MCPToolError("A mask must last at least 300 ms.") }
            newID = try addMask(session, args: args, start: start, end: clampedEnd)
        case "camera_layout":
            let type = try args.string("layoutType").map { value -> CameraTimelineLayoutType in
                guard let type = CameraTimelineLayoutType(rawValue: value) else {
                    throw MCPToolError("Unknown layoutType \(value). Allowed: \(CameraTimelineLayoutType.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                return type
            } ?? .cameraOverlay
            session.addCameraLayoutInRange(sourceStartMs: start, sourceEndMs: clampedEnd, type: type)
        case "caption":
            let text = args.string("text") ?? "New caption"
            let requested = args.string("trackId")
            if requested == "new" || (requested == nil && session.document.captions.captionTracks.isEmpty) {
                // A caption track is never empty, so it is created holding a starter caption; that caption becomes this one.
                let trackId = session.addCaptionTrack()
                session.mutate { doc in
                    guard let index = doc.captions.captionBlocks.firstIndex(where: { $0.trackId == trackId }) else { return }
                    doc.captions.captionBlocks[index].sourceStartMs = start
                    doc.captions.captionBlocks[index].sourceEndMs = clampedEnd
                    doc.captions.captionBlocks[index].customText = text
                }
            } else {
                let trackId = requested ?? session.document.captions.captionTracks[0].id
                guard session.document.captions.captionTracks.contains(where: { $0.id == trackId }) else {
                    throw MCPToolError("No caption track \(trackId).")
                }
                session.addCaption(trackId: trackId, sourceStartMs: start, sourceEndMs: clampedEnd, text: text)
            }
        case "shortcut":
            newID = session.addCustomShortcut(
                trackId: args.string("trackId"),
                sourceStartMs: start,
                sourceEndMs: clampedEnd,
                modifiers: (args.raw["modifiers"] as? [String]) ?? [],
                primaryKey: args.string("primaryKey") ?? "K"
            )
        default:
            throw MCPToolError("Unknown kind: \(kind)")
        }

        let id = newID ?? allItemIDs(session.document).subtracting(before).first
        guard let id else { throw MCPToolError("Nothing was added (the range may overlap another item or be too short).") }
        if let properties = args.object("properties") {
            let itemKind = kind == "shortcut" ? "custom_shortcut" : kind
            try patchItem(session, kind: itemKind, id: id, patch: properties)
        }
        return ["id": id, "kind": kind]
    }

    /// Items on one track may touch but not overlap (the timeline cannot show it, and the preview stacks them).
    private static func requireFree(_ items: [(String, Double, Double)], _ start: Double, _ end: Double, what: String, ignoring: String? = nil) throws {
        if let hit = items.first(where: { $0.0 != ignoring && start < $0.2 - 1 && end > $0.1 + 1 }) {
            throw MCPToolError("Overlaps the \(what) \(hit.0) (\(Int(hit.1))–\(Int(hit.2)) ms).")
        }
    }

    /// After an update: the changed item must not overlap another one (overlaps it did not cause are left alone).
    private static func requireNoOverlaps(_ items: [(String, Double, Double)], what: String, involving id: String) throws {
        guard let item = items.first(where: { $0.0 == id }) else { return }
        try requireFree(items, item.1, item.2, what: what, ignoring: id)
    }

    private func addMask(_ session: ProjectSession, args: MCPArguments, start: Double, end: Double) throws -> String {
        let type = try args.string("maskType").map { value -> MaskType in
            guard let type = MaskType(rawValue: value) else { throw MCPToolError("Unknown maskType \(value). Allowed: blur, spotlight") }
            return type
        } ?? .blur
        var rect = Rect01(x: 0.36, y: 0.43, width: 0.28, height: 0.14)
        if let r = args.object("rect01") {
            rect = try MCPJSON.patched(rect, with: r)
        }
        let item = MaskItem(
            sourceStartMs: start,
            sourceEndMs: end,
            type: type,
            style: .gaussian,
            intensity: type == .spotlight ? 50.0 : 36.0,
            cornerRadius: 12.0,
            keyframes: [MaskKeyframe(sourceMs: start, rect01: rect.clamped())]
        )
        let requestedTrack = args.string("trackId")
        if let requestedTrack, !session.document.timeline.maskTracks.contains(where: { $0.id == requestedTrack }) {
            throw MCPToolError("No mask track \(requestedTrack).")
        }
        session.mutate { doc in
            let index = requestedTrack.flatMap { id in doc.timeline.maskTracks.firstIndex { $0.id == id } }
                ?? doc.timeline.maskTracks.firstIndex { track in
                    !track.items.contains { !(end <= $0.sourceStartMs + 30 || start >= $0.sourceEndMs - 30) }
                }
            if let index {
                doc.timeline.maskTracks[index].isHidden = false
                doc.timeline.maskTracks[index].items.append(item)
                doc.timeline.maskTracks[index].items.sort { $0.sourceStartMs < $1.sourceStartMs }
            } else {
                doc.timeline.maskTracks.append(MaskTrack(name: "Masks", isHidden: false, items: [item]))
            }
        }
        return item.id
    }

    private func updateItem(_ args: MCPArguments) throws -> [String: Any] {
        let session = try session(args)
        guard let patch = args.object("patch") else { throw MCPToolError("Missing argument: patch") }
        let kind = try args.requiredString("kind")
        let id = try args.requiredString("id")
        session.startNewUndoStep()
        try patchItem(session, kind: kind, id: id, patch: patch)
        return ["id": id, "kind": kind]
    }

    private func patchElement<T: Codable & Identifiable>(_ items: inout [T], id: String, patch: Any) throws where T.ID == String {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw MCPToolError("No item with id \(id).") }
        var patch = patch as? [String: Any] ?? [:]
        patch["id"] = nil // ids never change
        items[index] = try MCPJSON.patched(items[index], with: patch)
    }

    private func patchItem(_ session: ProjectSession, kind: String, id: String, patch: [String: Any]) throws {
        var patch = patch
        if kind == "caption", let text = patch.removeValue(forKey: "text") as? String {
            guard session.document.captions.captionBlocks.contains(where: { $0.id == id }) else {
                throw MCPToolError("No caption with id \(id).")
            }
            session.updateCaptionText(id: id, text: text)
            if patch.isEmpty { return }
        }
        var doc = session.document
        switch kind {
        case "slice": try patchElement(&doc.timeline.slices, id: id, patch: patch)
        case "zoom": try patchElement(&doc.timeline.zooms, id: id, patch: patch)
        case "camera_layout": try patchElement(&doc.timeline.cameraLayouts, id: id, patch: patch)
        case "voiceover": try patchElement(&doc.timeline.voiceovers, id: id, patch: patch)
        case "caption": try patchElement(&doc.captions.captionBlocks, id: id, patch: patch)
        case "caption_track": try patchElement(&doc.captions.captionTracks, id: id, patch: patch)
        case "mask_track": try patchElement(&doc.timeline.maskTracks, id: id, patch: patch)
        case "shortcut_track": try patchElement(&doc.captions.shortcutTracks, id: id, patch: patch)
        case "custom_shortcut": try patchElement(&doc.captions.customShortcuts, id: id, patch: patch)
        case "mask":
            guard let t = doc.timeline.maskTracks.firstIndex(where: { $0.items.contains { $0.id == id } }) else {
                throw MCPToolError("No mask with id \(id).")
            }
            try patchElement(&doc.timeline.maskTracks[t].items, id: id, patch: patch)
        default:
            throw MCPToolError("Unknown kind: \(kind)")
        }
        doc.timeline.zooms.sort { $0.sourceStartMs < $1.sourceStartMs }
        doc.timeline.cameraLayouts.sort { $0.sourceStartMs < $1.sourceStartMs }
        try Self.requireNoOverlaps(doc.timeline.zooms.map { ($0.id, $0.sourceStartMs, $0.sourceEndMs) }, what: "zoom", involving: id)
        try Self.requireNoOverlaps(doc.timeline.cameraLayouts.map { ($0.id, $0.sourceStartMs, $0.sourceEndMs) }, what: "camera layout", involving: id)
        for track in doc.timeline.maskTracks {
            try Self.requireNoOverlaps(track.items.map { ($0.id, $0.sourceStartMs, $0.sourceEndMs) }, what: "mask", involving: id)
        }
        for track in doc.captions.captionTracks {
            try Self.requireNoOverlaps(
                doc.captions.captionBlocks.filter { $0.trackId == track.id }.map { ($0.id, $0.sourceStartMs, $0.sourceEndMs) },
                what: "caption", involving: id
            )
        }
        session.mutate { $0 = doc }
    }

    private func deleteItem(_ args: MCPArguments) throws -> [String: Any] {
        let session = try session(args)
        let kind = try args.requiredString("kind")
        let id = args.string("id") ?? ""
        let doc = session.document
        session.startNewUndoStep()
        func require(_ exists: Bool) throws {
            if !exists { throw MCPToolError("No \(kind) with id \(id).") }
        }

        switch kind {
        case "slice":
            try require(doc.timeline.slices.contains { $0.id == id })
            guard doc.timeline.slices.count > 1 else { throw MCPToolError("The last clip cannot be deleted.") }
            session.mutate { $0.timeline.slices.removeAll { $0.id == id } }
            session.selectSlice(session.document.timeline.slices.first?.id)
        case "zoom":
            try require(doc.timeline.zooms.contains { $0.id == id })
            session.deleteZoom(zoomId: id)
        case "mask":
            try require(doc.timeline.maskTracks.contains { $0.items.contains { $0.id == id } })
            session.deleteMask(maskId: id)
        case "camera_layout":
            try require(doc.timeline.cameraLayouts.contains { $0.id == id })
            session.deleteCameraLayout(id: id)
        case "voiceover":
            try require(doc.timeline.voiceovers.contains { $0.id == id })
            session.deleteVoiceover(id: id)
        case "caption":
            try require(doc.captions.captionBlocks.contains { $0.id == id })
            session.deleteCaption(id: id)
        case "shortcut":
            guard let cluster = session.detectedShortcutClusters.first(where: { $0.id == id }) else {
                throw MCPToolError("No shortcut with id \(id). Shortcut ids are in get_project info.shortcuts.")
            }
            session.deleteShortcut(cluster)
        case "caption_track":
            guard let track = doc.captions.captionTracks.first(where: { $0.id == id }) else { return try notFound(kind, id) }
            session.deleteTimelineTrack(.caption(id: id), displayName: track.name)
        case "mask_track":
            guard let track = doc.timeline.maskTracks.first(where: { $0.id == id }) else { return try notFound(kind, id) }
            session.deleteTimelineTrack(.mask(id: id), displayName: track.name)
        case "shortcut_track":
            guard let track = doc.captions.shortcutTracks.first(where: { $0.id == id }) else { return try notFound(kind, id) }
            session.deleteTimelineTrack(.shortcut(id: id), displayName: track.name)
        case "voiceover_track":
            guard let index = Int(id), doc.timeline.voiceovers.contains(where: { $0.trackIndex == index }) else {
                return try notFound(kind, id)
            }
            guard !session.isRecordingVoiceover else { throw MCPToolError("A voiceover is being recorded.") }
            let name = index == 0 ? "Voiceovers".localizedUI : String(format: "Voiceovers %lld".localizedUI, index + 1)
            session.deleteTimelineTrack(.voiceover(index: index), displayName: name)
        case "camera_layouts_track":
            session.deleteTimelineTrack(.cameraLayouts, displayName: "Layouts")
        default:
            throw MCPToolError("Unknown kind: \(kind)")
        }
        return ["deleted": kind, "id": id]
    }

    private func notFound(_ kind: String, _ id: String) throws -> [String: Any] {
        throw MCPToolError("No \(kind) with id \(id).")
    }

    private func splitItem(_ args: MCPArguments) throws -> [String: Any] {
        let session = try session(args)
        let kind = try args.requiredString("kind")
        let id = try args.requiredString("id")
        let timelineMs = try args.requiredDouble("atTimelineMs")
        let sourceMs = session.timeMapper.sourceTime(forTimelineMs: timelineMs).sourceMs
        let before = session.document
        session.startNewUndoStep()
        switch kind {
        case "slice": session.splitSlice(id: id, atTimelineMs: timelineMs)
        case "zoom": session.splitZoom(id: id, atSourceMs: sourceMs)
        case "mask": session.splitMask(id: id, atSourceMs: sourceMs)
        case "caption": session.splitCaption(id: id, atSourceMs: sourceMs)
        case "camera_layout": session.splitCameraLayout(id: id, atSourceMs: sourceMs)
        case "voiceover": session.splitVoiceover(id: id, atSourceMs: sourceMs)
        default: throw MCPToolError("Unknown kind: \(kind)")
        }
        guard session.document != before else {
            throw MCPToolError("Nothing was split: check the id and that the time is inside the item, away from its edges.")
        }
        return ["split": kind, "id": id, "atSourceMs": sourceMs]
    }

    private func history(_ args: MCPArguments, redo: Bool) throws -> [String: Any] {
        let session = try session(args)
        let steps = max(1, min(50, args.int("steps") ?? 1))
        var done = 0
        for _ in 0..<steps {
            if redo {
                guard session.canRedo else { break }
                session.redo()
            } else {
                guard session.canUndo else { break }
                session.undo()
            }
            done += 1
        }
        return ["steps": done, "canUndo": session.canUndo, "canRedo": session.canRedo]
    }

    // MARK: - Frames

    private func renderedFrame(_ session: ProjectSession, args: MCPArguments, defaultHeight: Int) async throws -> CGImage {
        session.isPlaying = false
        session.setHoverSkimTimelineMs(nil)
        if let ms = args.double("timelineMs") {
            session.seek(toTimelineMs: ms)
        }
        let height = Double(max(240, min(4320, args.int("height") ?? defaultHeight)))
        guard let image = await session.renderCurrentCompositedCGImage(targetHeight: height) else {
            throw MCPToolError("Could not render the frame.")
        }
        return image
    }

    private func encode(_ image: CGImage, type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func renderFrame(_ args: MCPArguments) async throws -> [String: Any] {
        let session = try session(args)
        let image = try await renderedFrame(session, args: args, defaultHeight: 720)
        guard let png = encode(image, type: .png) else { throw MCPToolError("Could not encode the frame.") }
        return [
            "content": [
                ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
                ["type": "text", "text": "Frame at \(Int(session.playheadTimelineMs)) ms (timeline), \(image.width)×\(image.height)."],
            ],
        ]
    }

    private func exportFrame(_ args: MCPArguments) async throws -> [String: Any] {
        let session = try session(args)
        let path = (try args.requiredString("outputPath") as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg"].contains(ext) else { throw MCPToolError("outputPath must end in .png or .jpg.") }
        let image = try await renderedFrame(session, args: args, defaultHeight: 1440)
        guard let data = encode(image, type: ext == "png" ? .png : .jpeg) else { throw MCPToolError("Could not encode the frame.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return ["path": url.path, "width": image.width, "height": image.height, "timelineMs": session.playheadTimelineMs]
    }

    // MARK: - Actions & options

    private func runAction(_ args: MCPArguments) throws -> [String: Any] {
        let session = try session(args)
        let action = try args.requiredString("action")
        session.startNewUndoStep()
        switch action {
        case "regenerate_auto_zooms":
            guard !session.clickEvents.isEmpty || !session.keyEvents.isEmpty else {
                throw MCPToolError("This project has no recorded clicks or typing to make zooms from.")
            }
            session.regenerateAutoZooms()
            return ["zooms": session.document.timeline.zooms.count]
        case "generate_transcript":
            session.generateLocalOnDeviceTranscript()
            return ["started": true, "note": "Poll get_project until info.isGeneratingTranscript is false."]
        case "remove_filler_words":
            try requireTranscript(session)
            session.removeAllFillerWordsFromTranscript()
        case "tighten_pauses":
            try requireTranscript(session)
            session.tightenAllPausesInTranscript()
        case "reset_cuts":
            session.resetAllSlicesTrimAndCuts()
        case "scan_sensitive_data":
            session.setHideSensitiveData(enabled: true)
        case "scan_faces":
            session.setHideFaces(enabled: true)
        case "play":
            if !session.isPlaying { session.togglePlayPause() }
        case "pause":
            session.isPlaying = false
        default:
            throw MCPToolError("Unknown action: \(action)")
        }
        return ["done": action]
    }

    private func requireTranscript(_ session: ProjectSession) throws {
        guard !session.document.captions.segments.isEmpty else {
            throw MCPToolError("There is no transcript yet. Run generate_transcript first.")
        }
    }

    private static let backgroundMusic = [
        "Sunny Lo-Fi", "Lean Groove", "Bright Lounge", "Chill Hop", "Upbeat Spark", "Warm Horizon",
        "Pulse Drive", "Midnight Study", "Velvet Keys", "Soft Rain",
    ]

    private func allWallpapers() -> [SystemWallpaperItem] {
        SystemWallpaperCatalog.discoverSystemWallpapers() + BundledWallpaperCatalog.allItems
    }

    private func listOptions(_ args: MCPArguments) throws -> [String: Any] {
        switch try args.requiredString("kind") {
        case "wallpapers":
            return ["wallpapers": allWallpapers().map { item -> [String: Any] in
                [
                    "name": item.name,
                    "category": item.isBundled ? (BundledWallpaperCatalog.category(ofWallpaperNamed: item.name) ?? "") : "macOS",
                ]
            }]
        case "mesh_presets":
            return ["meshPresets": MeshPreset.builtIn.map { ["id": $0.id, "name": $0.name, "category": $0.category] }]
        case "cursor_themes":
            return ["cursorThemes": CursorThemePreset.allThemes.map { theme -> [String: Any] in
                ["id": theme.id, "name": theme.name, "subtitle": theme.subtitle, "variantIds": theme.pointerVariants.map(\.id)]
            }]
        case "presets":
            let store = ProjectPresetsStore.shared
            return ["presets": store.presets.map { ["id": $0.id, "name": $0.name, "isDefault": $0.id == store.defaultPresetId] }]
        case "background_music":
            return ["backgroundMusic": Self.backgroundMusic, "note": "Set audio.backgroundMusic.relativePath to one of these names with update_project."]
        case "enums":
            return ["enums": Self.enumOptions]
        case let other:
            throw MCPToolError("Unknown kind: \(other)")
        }
    }

    private static func values<T: CaseIterable & RawRepresentable>(_: T.Type) -> [String] where T.RawValue == String {
        T.allCases.map(\.rawValue)
    }

    /// Enum fields by their path in the document (`[]` marks an array element).
    private static var enumOptions: [String: [String]] {
        [
            "canvas.aspectRatioMode": values(AspectRatioMode.self),
            "canvas.aspectRatioPreset": values(AspectRatioPreset.self),
            "background.type": values(BackgroundType.self),
            "background.gradient.type": values(GradientType.self),
            "frameStyle.deviceMockup.matchMode": values(DeviceFrameMatchMode.self),
            "cursor.clickEffect.visualStyle": values(ClickEffectStyle.self),
            "cursor.rotationMode": values(CursorRotationMode.self),
            "camera.layoutMode": values(CameraLayoutMode.self),
            "camera.aspectRatioPreset": values(CameraAspectRatioPreset.self),
            "camera.colorGradePreset": values(CameraColorGradePreset.self),
            "camera.shape": values(CameraShape.self),
            "audio.microphoneAudioPreset": values(MicrophoneAudioPreset.self),
            "captions.fontStyle (and every CaptionStyle.fontStyle)": values(CaptionFontStyle.self),
            "captions.wordsReveal (and CaptionStyle.wordsReveal)": values(CaptionWordsReveal.self),
            "captions.lineGrowth (and CaptionStyle.lineGrowth)": values(CaptionLineGrowth.self),
            "captions.wordAnimation (and CaptionStyle.wordAnimation)": values(CaptionWordAnimation.self),
            "captions.colorTheme (and CaptionStyle.colorTheme)": values(CaptionColorTheme.self),
            "ShortcutStyleConfig.dockPosition": values(ShortcutDockPosition.self),
            "ShortcutStyleConfig.colorMode": values(ShortcutColorMode.self),
            "timeline.zooms[].mode": values(ZoomMode.self),
            "timeline.zooms[].presentation": values(ZoomPresentation.self),
            "timeline.maskTracks[].items[].type": values(MaskType.self),
            "timeline.maskTracks[].items[].style": values(MaskStyle.self),
            "timeline.cameraLayouts[].layoutType": values(CameraTimelineLayoutType.self),
            "timeline.voiceovers[].attachMode": values(VoiceoverAttachMode.self),
        ]
    }

    private func setBackground(_ args: MCPArguments) throws -> [String: Any] {
        let session = try session(args)
        session.startNewUndoStep()
        if let name = args.string("wallpaper") {
            let all = allWallpapers()
            guard let item = all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw MCPToolError("No wallpaper named \(name). Use list_options kind wallpapers.")
            }
            session.selectSystemWallpaper(item)
        } else if let path = args.string("imagePath") {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard NSImage(contentsOf: url) != nil else { throw MCPToolError("Not an image: \(path)") }
            session.selectCustomBackgroundImage(from: url)
        } else if let meshId = args.string("meshPresetId") {
            guard MeshPreset.builtIn.contains(where: { $0.id == meshId }) else {
                throw MCPToolError("No mesh preset \(meshId). Use list_options kind mesh_presets.")
            }
            session.mutate {
                $0.background.type = .mesh
                $0.background.meshPresetId = meshId
            }
        } else if let color = args.string("solidColor") {
            session.mutate {
                $0.background.type = .solid
                $0.background.solidColor = color
            }
        } else if let colors = args.raw["gradient"] as? [String], colors.count == 2 {
            session.mutate {
                $0.background.type = .gradient
                $0.background.gradient.stops = [
                    GradientStopConfig(color: colors[0], location: 0.0),
                    GradientStopConfig(color: colors[1], location: 1.0),
                ]
            }
        } else {
            throw MCPToolError("Pass one of wallpaper, imagePath, meshPresetId, solidColor or gradient.")
        }
        return ["background": (try? MCPJSON.object(session.document.background)) ?? [:]]
    }

    private func applyPreset(_ args: MCPArguments) throws -> [String: Any] {
        let session = try session(args)
        let name = try args.requiredString("name")
        let store = ProjectPresetsStore.shared
        guard let preset = store.presets.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id == name }) else {
            throw MCPToolError("No preset named \(name). Use list_options kind presets.")
        }
        session.startNewUndoStep()
        store.applyPreset(preset, to: session)
        return ["applied": preset.name]
    }

    // MARK: - Recording

    private func listCaptureTargets() -> [String: Any] {
        let recorder = RecordingCoordinator.shared
        let main = CGMainDisplayID()
        let displays: [[String: Any]] = NSScreen.screens.map { screen in
            let id = WindowDiscoveryService.displayID(for: screen)
            return [
                "id": Int(id),
                "name": screen.localizedName,
                "width": screen.frame.width,
                "height": screen.frame.height,
                "isMain": id == main,
            ]
        }
        let windows: [[String: Any]] = WindowDiscoveryService.listFrontToBackWindows(resolveCornerRadius: false).prefix(40).map { win in
            [
                "id": Int(win.id),
                "app": win.appName,
                "title": win.title,
                "bundleId": win.bundleId ?? "",
                "bounds": ["x": win.bounds.minX, "y": win.bounds.minY, "width": win.bounds.width, "height": win.bounds.height],
            ]
        }
        func devices(_ list: [CapturableMediaDeviceInfo]) -> [[String: Any]] {
            list.map { ["id": $0.id, "name": $0.name, "isDefault": $0.isDefault] }
        }
        return [
            "displays": displays,
            "windows": windows,
            "cameras": devices(recorder.availableCameraDevices()),
            "microphones": devices(recorder.availableMicrophoneDevices()),
            "audioApps": recorder.runningAudioApps().map { ["id": $0.id, "name": $0.name] },
            "current": [
                "cameraId": recorder.selectedCameraDeviceID as Any? ?? NSNull(),
                "microphoneId": (recorder.captureMicrophone ? recorder.selectedMicrophoneDeviceID : nil) as Any? ?? NSNull(),
                "systemAudio": recorder.captureSystemAudio,
                "countdownSeconds": recorder.countdownOption.rawValue,
            ],
        ]
    }

    private func startRecording(_ args: MCPArguments) throws -> [String: Any] {
        let recorder = RecordingCoordinator.shared
        guard !recorder.isRecording, !recorder.isCountingDown else {
            throw MCPToolError("A recording is already running. Use control_recording.")
        }
        guard let target = args.object("target"), let type = target["type"] as? String else {
            throw MCPToolError("Missing argument: target.type")
        }
        let targetArgs = MCPArguments(raw: target)

        if args.has("cameraId") {
            if let id = args.string("cameraId") {
                guard let camera = recorder.availableCameraDevices().first(where: { $0.id == id }) else {
                    throw MCPToolError("No camera \(id). Use list_capture_targets.")
                }
                recorder.selectedCameraDeviceID = camera.id
                recorder.selectedCameraName = camera.name
            } else {
                recorder.selectedCameraDeviceID = nil
                recorder.selectedCameraName = nil
            }
        }
        if args.has("microphoneId") {
            if let id = args.string("microphoneId") {
                guard let mic = recorder.availableMicrophoneDevices().first(where: { $0.id == id }) else {
                    throw MCPToolError("No microphone \(id). Use list_capture_targets.")
                }
                recorder.selectedMicrophoneDeviceID = mic.id
                recorder.selectedMicrophoneName = mic.name
                recorder.captureMicrophone = true
            } else {
                recorder.captureMicrophone = false
                recorder.selectedMicrophoneDeviceID = nil
                recorder.selectedMicrophoneName = nil
            }
        }
        if let systemAudio = args.bool("systemAudio") {
            recorder.captureSystemAudio = systemAudio
            if systemAudio && !recorder.systemAudioFromAllApps && recorder.selectedSystemAudioAppBundleIDs.isEmpty {
                recorder.systemAudioFromAllApps = true
            }
        }

        recorder.showRecordingHUD()
        switch type {
        case "display":
            let id = targetArgs.int("displayId").map { CGDirectDisplayID($0) } ?? CGMainDisplayID()
            guard NSScreen.screens.contains(where: { WindowDiscoveryService.displayID(for: $0) == id }) else {
                throw MCPToolError("No display \(id). Use list_capture_targets.")
            }
            recorder.selectedMode = .display
            recorder.hoveredDisplayID = id
        case "window":
            guard let windowId = targetArgs.int("windowId") else { throw MCPToolError("Missing argument: target.windowId") }
            guard let window = WindowDiscoveryService.listFrontToBackWindows(resolveCornerRadius: false)
                .first(where: { Int($0.id) == windowId })
            else { throw MCPToolError("No window \(windowId). Use list_capture_targets.") }
            recorder.selectedMode = .window
            recorder.hoveredWindow = WindowDiscoveryService.withCornerRadius(window)
        case "area":
            guard let rect = targetArgs.object("rect"),
                  let x = (rect["x"] as? NSNumber)?.doubleValue, let y = (rect["y"] as? NSNumber)?.doubleValue,
                  let w = (rect["width"] as? NSNumber)?.doubleValue, let h = (rect["height"] as? NSNumber)?.doubleValue,
                  w >= 64, h >= 64
            else { throw MCPToolError("target.rect needs x, y, width and height (at least 64 points).") }
            recorder.selectedMode = .area
            recorder.selectedAreaRectQuartz = CGRect(x: x, y: y, width: w, height: h)
        default:
            throw MCPToolError("target.type must be display, window or area.")
        }

        // A countdown asked for here applies to this recording only, not to the user's setting.
        let savedCountdown = recorder.countdownOption
        if let seconds = args.int("countdownSeconds") {
            guard let option = RecordingCountdownOption(rawValue: seconds) else {
                throw MCPToolError("countdownSeconds must be 0, 3, 5 or 10.")
            }
            recorder.countdownOption = option
        }
        recorder.requestStartRecording()
        let countdown = recorder.countdownOption.rawValue
        recorder.countdownOption = savedCountdown
        return [
            "started": true,
            "mode": recorder.selectedMode.rawValue,
            "countdownSeconds": countdown,
            "note": "Use control_recording stop to finish; get_status shows the state.",
        ]
    }

    private func controlRecording(_ args: MCPArguments) async throws -> [String: Any] {
        let recorder = RecordingCoordinator.shared
        let action = try args.requiredString("action")
        switch action {
        case "pause", "resume":
            guard recorder.isRecording else { throw MCPToolError("Nothing is being recorded.") }
            if recorder.isRecordingPaused != (action == "pause") { recorder.togglePauseRecording() }
            return ["state": recorder.isRecordingPaused ? "paused" : "recording"]
        case "stop":
            if recorder.isCountingDown { recorder.skipCountdownAndStartImmediately() }
            for _ in 0..<40 where !recorder.isRecording { try await Task.sleep(for: .milliseconds(100)) }
            guard recorder.isRecording else { throw MCPToolError(recorder.lastErrorMessage ?? "Nothing is being recorded.") }
            let before = Set(ProjectWorkspaceStore.shared.sessionsByID.keys)
            await recorder.stopRecordingAndOpenEditor()
            let created = ProjectWorkspaceStore.shared.sessionsByID.values.first { !before.contains($0.id) }
                ?? ProjectWorkspaceStore.shared.activeSession
            guard let created else { throw MCPToolError("The recording stopped but no project was opened.") }
            return ["stopped": true, "project": summary(created)]
        case "restart":
            guard recorder.isRecording else { throw MCPToolError("Nothing is being recorded.") }
            await recorder.restartCurrentRecording()
            return ["restarted": true]
        case "cancel":
            if recorder.isCountingDown {
                recorder.cancelCountdown()
                return ["cancelled": "countdown"]
            }
            guard recorder.isRecording else { throw MCPToolError("Nothing is being recorded.") }
            await recorder.discardCurrentRecording()
            return ["cancelled": "recording"]
        default:
            throw MCPToolError("Unknown action: \(action)")
        }
    }

    // MARK: - Settings

    private func getSettings() -> [String: Any] {
        let settings = AppSettings.shared
        let recorder = RecordingCoordinator.shared
        return [
            "general": [
                "appearance": settings.appearance.rawValue,
                "language": AppLanguage.current.rawValue,
                "launchAtLogin": settings.launchAtLogin,
                "allowedValues": [
                    "appearance": AppSettings.Appearance.allCases.map(\.rawValue),
                    "language": AppLanguage.allCases.map(\.rawValue),
                ],
            ],
            "recording": [
                "countdownSeconds": recorder.countdownOption.rawValue,
                "afterRecording": recorder.afterRecordingAction.rawValue,
                "autoCreateZooms": recorder.autoCreateZooms,
                "hideDesktopIcons": recorder.hideDesktopIcons,
                "hideDockIcon": recorder.hideDockIcon,
                "highlightRecordedArea": recorder.highlightRecordedArea,
                "cameraMaxResolution": recorder.cameraMaxResolution.rawValue,
                "allowedValues": [
                    "countdownSeconds": RecordingCountdownOption.allCases.map(\.rawValue),
                    "afterRecording": RecordingCoordinator.AfterRecordingAction.allCases.map(\.rawValue),
                    "cameraMaxResolution": CameraMaxResolutionOption.allCases.map(\.rawValue),
                ],
            ],
            "editing": [
                "useLastProjectSettings": settings.useLastProjectSettings,
                "autosave": settings.autosaveEnabled,
                "projectsDirectory": settings.projectsDirectoryPath,
                "presetsDirectory": settings.presetsDirectoryPath,
            ],
            "quickExport": (try? MCPJSON.object(settings.quickExportConfig)) ?? [:],
        ]
    }

    private func updateSettings(_ args: MCPArguments) throws -> [String: Any] {
        guard let patch = args.object("patch") else { throw MCPToolError("Missing argument: patch") }
        let settings = AppSettings.shared
        let recorder = RecordingCoordinator.shared
        var notes: [String] = []

        // Validate everything first, so a bad value changes nothing.
        let general = patch["general"] as? [String: Any] ?? [:]
        let recording = patch["recording"] as? [String: Any] ?? [:]
        let editing = patch["editing"] as? [String: Any] ?? [:]
        let appearance = try (general["appearance"] as? String).map { value -> AppSettings.Appearance in
            guard let v = AppSettings.Appearance(rawValue: value) else { throw MCPToolError("Unknown appearance \(value).") }
            return v
        }
        let language = try (general["language"] as? String).map { value -> AppLanguage in
            guard let v = AppLanguage(rawValue: value) else { throw MCPToolError("Unknown language \(value).") }
            return v
        }
        let countdown = try (recording["countdownSeconds"] as? NSNumber).map { value -> RecordingCountdownOption in
            guard let v = RecordingCountdownOption(rawValue: value.intValue) else { throw MCPToolError("countdownSeconds must be 0, 3, 5 or 10.") }
            return v
        }
        let after = try (recording["afterRecording"] as? String).map { value -> RecordingCoordinator.AfterRecordingAction in
            guard let v = RecordingCoordinator.AfterRecordingAction(rawValue: value) else { throw MCPToolError("Unknown afterRecording \(value).") }
            return v
        }
        let cameraMax = try (recording["cameraMaxResolution"] as? String).map { value -> CameraMaxResolutionOption in
            guard let v = CameraMaxResolutionOption(rawValue: value) else { throw MCPToolError("Unknown cameraMaxResolution \(value).") }
            return v
        }
        var quick: HardwareVideoExporter.ExportConfiguration?
        if let quickPatch = patch["quickExport"] {
            var config = try MCPJSON.patched(settings.quickExportConfig, with: quickPatch)
            config.normalizeForConstraints()
            quick = config
        }

        if let appearance { settings.appearance = appearance }
        if let language, language != AppLanguage.current {
            AppLanguage.choose(language)
            notes.append("The language applies after Native Screen restarts.")
        }
        if let value = (general["launchAtLogin"] as? NSNumber)?.boolValue { settings.launchAtLogin = value }
        if let countdown { recorder.countdownOption = countdown }
        if let after { recorder.afterRecordingAction = after }
        if let cameraMax { recorder.cameraMaxResolution = cameraMax }
        if let v = (recording["autoCreateZooms"] as? NSNumber)?.boolValue { recorder.autoCreateZooms = v }
        if let v = (recording["hideDesktopIcons"] as? NSNumber)?.boolValue { recorder.hideDesktopIcons = v }
        if let v = (recording["hideDockIcon"] as? NSNumber)?.boolValue { recorder.hideDockIcon = v }
        if let v = (recording["highlightRecordedArea"] as? NSNumber)?.boolValue { recorder.highlightRecordedArea = v }
        if let v = (editing["useLastProjectSettings"] as? NSNumber)?.boolValue { settings.useLastProjectSettings = v }
        if let v = (editing["autosave"] as? NSNumber)?.boolValue { settings.autosaveEnabled = v }
        if let v = editing["projectsDirectory"] as? String { settings.projectsDirectoryPath = (v as NSString).expandingTildeInPath }
        if let v = editing["presetsDirectory"] as? String { settings.presetsDirectoryPath = (v as NSString).expandingTildeInPath }
        if let quick { settings.quickExportConfig = quick }

        var result = getSettings()
        if !notes.isEmpty { result["notes"] = notes }
        return result
    }

    // MARK: - Export

    private func exportVideo(_ args: MCPArguments, progress: MCPProgress?) async throws -> [String: Any] {
        let session = try session(args)
        var config = args.bool("useQuickExportSettings") == true
            ? AppSettings.shared.quickExportConfig
            : HardwareVideoExporter.ExportConfiguration()
        if let patch = args.object("config") {
            config = try MCPJSON.patched(config, with: patch)
        }
        if let target = args.string("target") {
            guard let value = HardwareVideoExporter.ExportTarget(rawValue: target) else {
                throw MCPToolError("target must be file or clipboard.")
            }
            config.target = value
        }
        config.normalizeForConstraints()

        let ext = config.format.fileExtension
        let cleanName = session.document.name.replacingOccurrences(of: "/", with: "-")
        let outURL: URL
        if config.target == .clipboard {
            try FileManager.default.createDirectory(at: ProjectWorkspaceStore.clipboardExportsDirectory, withIntermediateDirectories: true)
            outURL = ProjectWorkspaceStore.clipboardExportsDirectory
                .appendingPathComponent("\(cleanName)-\(Int(Date().timeIntervalSince1970)).\(ext)")
        } else if let path = args.string("outputPath") {
            var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if url.pathExtension.lowercased() != ext { url = url.appendingPathExtension(ext) }
            outURL = url
        } else {
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
            outURL = desktop.appendingPathComponent("\(cleanName).\(ext)")
        }
        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: outURL.path) {
            try FileManager.default.removeItem(at: outURL)
        }

        let exportID = UUID().uuidString
        activeExports[exportID] = (session.document.name, 0)
        defer {
            activeExports[exportID] = nil
            DockProgressIndicatingController.shared.setProgress(nil)
        }
        session.isPlaying = false
        session.showToast("Exporting video...")
        DockProgressIndicatingController.shared.setProgress(0)
        let started = Date()
        var lastReported = -1.0
        try await HardwareVideoExporter.exportProject(session: session, outputURL: outURL, config: config) { [weak self] fraction in
            self?.activeExports[exportID]?.progress = fraction
            DockProgressIndicatingController.shared.setProgress(fraction)
            if fraction - lastReported >= 0.02 || fraction >= 1 {
                lastReported = fraction
                progress?.report(fraction, "Exporting \(Int(fraction * 100))%")
            }
        }
        try Task.checkCancellation()

        if config.target == .clipboard {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([outURL as NSURL])
        }
        session.showToast("Export finished")
        let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? NSNumber)?.intValue ?? 0
        return [
            "path": outURL.path,
            "target": config.target.rawValue,
            "bytes": size,
            "seconds": Date().timeIntervalSince(started),
            "config": (try? MCPJSON.object(config)) ?? [:],
        ]
    }
}
