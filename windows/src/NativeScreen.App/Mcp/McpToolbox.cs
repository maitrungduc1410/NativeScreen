using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using NativeScreen.Core;
using NativeScreen.Export;
using NativeScreen.Media;

namespace NativeScreen.App;

/// <summary>
/// The MCP tools. Names, descriptions and schemas come from the macOS app's Resources/MCPTools.json, shipped as content, so
/// both apps list the same tools; each one runs on the UI thread against the objects the UI uses (spec/06 ADR-52).
/// </summary>
internal sealed class McpToolbox
{
    private readonly Dictionary<string, (string Project, double Progress)> exports = [];

    public McpToolbox()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Mcp", "MCPTools.json");
        (Instructions, Definitions) = File.Exists(path) ? McpDocument.LoadTools(File.ReadAllText(path)) : ("", []);
    }

    public string Instructions { get; }

    public JsonArray Definitions { get; }

    /// <summary>Tools that change the project, its playhead or its window (spec/06 ADR-65).</summary>
    private static readonly HashSet<string> BlockedDuringExport =
    [
        "close_project", "delete_project", "rename_project", "update_project", "add_item", "update_item", "delete_item",
        "split_item", "undo", "redo", "render_frame", "run_action", "set_background", "apply_preset", "export_video"
    ];

    public async Task<JsonObject> Call(string name, JsonObject raw, Action<double, string>? progress, CancellationToken cancel)
    {
        var args = new McpArgs(raw);
        try
        {
            McpDocument.ValidateArguments(Definitions, name, raw);
            if (BlockedDuringExport.Contains(name) && Editor(args).McpSession.IsExportRunning)
            {
                throw new McpToolException($"This project is exporting. Wait for the export to finish before calling {name}.");
            }

            return name switch
            {
                "get_status" => Ok(Status()),
                "list_projects" => Ok(ListProjects(args)),
                "open_project" => Ok(await OpenProject(args)),
                "create_project_from_video" => Ok(await CreateFromVideo(args)),
                "close_project" => Ok(CloseProject(args)),
                "delete_project" => Ok(await DeleteProject(args)),
                "rename_project" => Ok(RenameProject(args)),
                "save_project" => Ok(SaveProject(args)),
                "get_project" => Ok(GetProject(args)),
                "update_project" => Ok(UpdateProject(args)),
                "add_item" => Ok(AddItem(args)),
                "update_item" => Ok(UpdateItem(args)),
                "delete_item" => Ok(DeleteItem(args)),
                "split_item" => Ok(SplitItem(args)),
                "undo" => Ok(History(args, redo: false)),
                "redo" => Ok(History(args, redo: true)),
                "render_frame" => await RenderFrame(args),
                "run_action" => Ok(RunAction(args)),
                "list_options" => Ok(ListOptions(args)),
                "set_background" => Ok(SetBackground(args)),
                "apply_preset" => Ok(ApplyPreset(args)),
                "list_capture_targets" => Ok(ListCaptureTargets()),
                "start_recording" => Ok(StartRecording(args)),
                "control_recording" => Ok(await ControlRecording(args)),
                "get_settings" => Ok(GetSettings()),
                "update_settings" => Ok(UpdateSettings(args)),
                "export_video" => Ok(await ExportVideo(args, progress, cancel)),
                "export_frame" => Ok(await ExportFrame(args)),
                _ => throw new McpToolException("Unknown tool: " + name)
            };
        }
        catch (McpToolException exception)
        {
            return Failure(exception.Message);
        }
        catch (Exception exception) when (Trace(name, exception))
        {
            throw;
        }
        catch (OperationCanceledException)
        {
            return Failure("Cancelled.");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException or JsonException or ArgumentException or SharpGen.Runtime.SharpGenException or System.Runtime.InteropServices.COMException)
        {
            return Failure(exception.Message);
        }
    }

    /// <summary>NS_MCP_TRACE=&lt;file&gt;: every tool failure other than a plain refusal is appended with its stack. Never filters.</summary>
    private static bool Trace(string tool, Exception exception)
    {
        if (Environment.GetEnvironmentVariable("NS_MCP_TRACE") is { Length: > 0 } file)
        {
            File.AppendAllText(file, $"{DateTime.Now:HH:mm:ss} {tool}: {exception}\n\n");
        }

        return false;
    }

    private static JsonObject Ok(JsonObject value) => new()
    {
        ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = value.ToJsonString() }),
        ["structuredContent"] = value
    };

    private static JsonObject Failure(string message) => new()
    {
        ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = message }),
        ["isError"] = true
    };

    // MARK: Projects

    /// <summary>project: an editor id, a package path (opened if needed), or nothing for the frontmost editor.</summary>
    private static EditorWindow Editor(McpArgs args)
    {
        if (args.String("project") is { } value)
        {
            if (Projects.Editors.Values.FirstOrDefault(editor => string.Equals(editor.McpId, value, StringComparison.OrdinalIgnoreCase)) is { } byId)
            {
                return byId;
            }

            var full = FullPath(value).TrimEnd(Path.DirectorySeparatorChar);
            if (Projects.Editors.TryGetValue(full, out var byPath))
            {
                return byPath;
            }

            throw new McpToolException($"No open project with id or path {value}. Use get_status or list_projects, then open_project.");
        }

        if (Projects.Active is { } active)
        {
            return active;
        }

        throw new McpToolException(Projects.Editors.Count == 0
            ? "No project is open. Use open_project, list_projects or start_recording."
            : "Several projects are open; pass project (an id from get_status).");
    }

    private static string FullPath(string path) =>
        Path.GetFullPath(path.StartsWith('~') ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + path[1..] : path);

    private static JsonObject Summary(EditorWindow editor) => new()
    {
        ["id"] = editor.McpId,
        ["name"] = editor.McpSession.Document.Name,
        ["path"] = editor.McpSource.PackagePath,
        ["isFrontmost"] = ReferenceEquals(Projects.Active, editor),
        ["hasUnsavedChanges"] = editor.McpHasUnsavedChanges,
        ["timelineDurationMs"] = editor.McpSession.DurationMs
    };

    private JsonObject Status()
    {
        var recording = new JsonObject
        {
            ["state"] = RecordingHudWindow.McpState,
            ["mode"] = RecordingHudWindow.McpMode,
            ["elapsedSeconds"] = RecordingHudWindow.McpElapsedSeconds
        };
        if (RecordingHudWindow.McpLastError is { } error)
        {
            recording["lastError"] = error;
        }

        return new JsonObject
        {
            ["app"] = new JsonObject { ["version"] = McpServer.AppVersion, ["platform"] = "windows" },
            ["projects"] = new JsonArray(Projects.Editors.Values.OrderBy(editor => editor.McpSession.Document.Name, StringComparer.CurrentCulture).Select(editor => (JsonNode)Summary(editor)).ToArray()),
            ["recording"] = recording,
            ["exports"] = new JsonArray(exports.Select(item => (JsonNode)new JsonObject { ["id"] = item.Key, ["project"] = item.Value.Project, ["progress"] = item.Value.Progress }).ToArray())
        };
    }

    private static JsonObject ListProjects(McpArgs args)
    {
        var limit = args.Int("limit") ?? 30;
        var folder = AppSettings.Shared.ProjectsDirectory;
        var paths = AppSettings.Shared.RecentProjects.Where(path => File.Exists(Path.Combine(path, "project.json"))).ToList();
        if (Directory.Exists(folder))
        {
            foreach (var path in Directory.EnumerateDirectories(folder, "*" + ProjectStore.PackageExtension))
            {
                if (!paths.Exists(item => string.Equals(Path.GetFullPath(item), Path.GetFullPath(path), StringComparison.OrdinalIgnoreCase)) && File.Exists(Path.Combine(path, "project.json")))
                {
                    paths.Add(path);
                }
            }
        }

        var projects = new JsonArray();
        foreach (var (path, modified) in paths.Select(path => (path, File.GetLastWriteTimeUtc(Path.Combine(path, "project.json")))).OrderByDescending(item => item.Item2).Take(limit))
        {
            var entry = new JsonObject
            {
                ["name"] = Path.GetFileNameWithoutExtension(path.TrimEnd(Path.DirectorySeparatorChar)),
                ["path"] = Path.GetFullPath(path),
                ["modified"] = modified.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture)
            };
            if (Projects.Editors.TryGetValue(Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar), out var open))
            {
                entry["openId"] = open.McpId;
            }

            projects.Add(entry);
        }

        return new JsonObject { ["projectsFolder"] = folder, ["projects"] = projects };
    }

    private static async Task<JsonObject> OpenProject(McpArgs args)
    {
        var path = FullPath(args.Required("path"));
        if (!File.Exists(Path.Combine(path, "project.json")))
        {
            throw new McpToolException("Not a Native Screen project: " + path);
        }

        return Summary(await Projects.OpenAndGet(path) ?? throw new McpToolException("Could not open " + path + "."));
    }

    private static async Task<JsonObject> CreateFromVideo(McpArgs args)
    {
        var path = FullPath(args.Required("path"));
        if (!File.Exists(path))
        {
            throw new McpToolException("File not found: " + path);
        }

        var package = await Task.Run(() => VideoProjectImporter.BuildPackage(path, AppSettings.Shared.ProjectsDirectory, DateTimeOffset.UtcNow));
        var editor = await Projects.OpenAndGet(package) ?? throw new McpToolException($"The project was created at {package} but could not be opened.");
        return Summary(editor);
    }

    private static JsonObject CloseProject(McpArgs args)
    {
        var editor = Editor(args);
        var path = editor.McpSource.PackagePath;
        editor.McpSave();
        editor.Close();
        return new JsonObject { ["closed"] = path };
    }

    private static async Task<JsonObject> DeleteProject(McpArgs args)
    {
        var editor = Editor(args);
        var path = editor.McpSource.PackagePath;
        editor.McpPause();
        await editor.McpDeleteProject();
        if (path is not null && Directory.Exists(path))
        {
            throw new McpToolException($"Could not move {path} to the Recycle Bin.");
        }

        return new JsonObject { ["movedToRecycleBin"] = path };
    }

    private static JsonObject RenameProject(McpArgs args)
    {
        var editor = Editor(args);
        editor.McpSession.StartNewUndoStep();
        editor.McpSession.Rename(args.Required("name"));
        return Summary(editor);
    }

    private static JsonObject SaveProject(McpArgs args)
    {
        var editor = Editor(args);
        editor.McpSave();
        return Summary(editor);
    }

    // MARK: Document

    private JsonObject GetProject(McpArgs args)
    {
        var editor = Editor(args);
        var session = editor.McpSession;
        var document = McpDocument.ToJson(session.Document);
        if (args.Bool("include_transcript") != true && document["captions"] is JsonObject captions)
        {
            captions.Remove("segments");
        }

        var slices = new JsonArray();
        foreach (var mapped in session.Mapper.MappedSlices)
        {
            slices.Add(new JsonObject
            {
                ["id"] = mapped.Slice.Id,
                ["sourceStartMs"] = mapped.Slice.SourceStartMs,
                ["sourceEndMs"] = mapped.Slice.SourceEndMs,
                ["speed"] = mapped.Slice.Speed,
                ["timelineStartMs"] = mapped.TimelineStartMs,
                ["timelineEndMs"] = mapped.TimelineEndMs
            });
        }

        var shortcuts = new JsonArray();
        foreach (var cluster in session.Shortcuts())
        {
            shortcuts.Add(new JsonObject
            {
                ["id"] = cluster.Id,
                ["trackId"] = cluster.TrackId,
                ["keys"] = cluster.Label,
                ["sourceStartMs"] = cluster.DisplayStartMs,
                ["sourceEndMs"] = cluster.DisplayEndMs,
                ["isCustom"] = !cluster.Id.StartsWith("telemetry_", StringComparison.Ordinal),
                ["hidden"] = SegmentEdits.IsShortcutHidden(session.Document, cluster)
            });
        }

        var source = editor.McpSource;
        var tracks = source.Project?.Metadata.Tracks;
        var info = new JsonObject
        {
            ["id"] = editor.McpId,
            ["path"] = source.PackagePath,
            ["hasUnsavedChanges"] = editor.McpHasUnsavedChanges,
            ["canUndo"] = session.History.CanUndo,
            ["canRedo"] = session.History.CanRedo,
            ["sourceDurationMs"] = session.SourceDurationMs,
            ["timelineDurationMs"] = session.DurationMs,
            ["playheadTimelineMs"] = session.PlayheadTimelineMs,
            ["isPlaying"] = session.IsPlaying,
            ["sourcePixelSize"] = new JsonObject { ["width"] = source.SourceWidth, ["height"] = source.SourceHeight },
            ["captureMode"] = source.Project?.IsCameraOnly == true ? "camera" : (source.Project?.Metadata.CaptureTarget.Mode ?? CaptureTargetMode.Display).ToString().ToLowerInvariant(),
            ["recorded"] = new JsonObject
            {
                ["camera"] = source.HasCamera,
                ["microphone"] = tracks?.MicrophoneAudio is not null,
                ["systemAudio"] = tracks?.SystemAudio is not null,
                ["cursor"] = session.CursorEvents.Count > 0,
                ["clicks"] = session.ClickEvents.Count,
                ["keystrokes"] = session.KeyEvents.Count
            },
            ["slices"] = slices,
            ["shortcuts"] = shortcuts,
            ["transcriptWordCount"] = session.Document.Captions.Segments.Count,
            ["isGeneratingTranscript"] = editor.McpTools.IsTranscribing
        };
        return new JsonObject { ["info"] = info, ["document"] = document };
    }

    private static JsonObject UpdateProject(McpArgs args)
    {
        var session = Editor(args).McpSession;
        var patch = args.Object("patch") ?? throw new McpToolException("Missing argument: patch");
        var next = McpDocument.Patch(session.Document, patch);
        var changed = ProjectJson.Serialize(next) != ProjectJson.Serialize(session.Document);
        if (changed)
        {
            session.ReplaceDocument(next);
        }

        return new JsonObject { ["changed"] = changed };
    }

    // MARK: Timeline items

    private static JsonObject AddItem(McpArgs args)
    {
        var editor = Editor(args);
        var session = editor.McpSession;
        var kind = args.Required("kind");
        session.StartNewUndoStep();
        switch (kind)
        {
            case "caption_track":
                return new JsonObject { ["id"] = session.AddCaptionTrack(), ["kind"] = kind };
            case "shortcut_track":
                string? created = null;
                session.Mutate(document => created = TimelineEdits.AddShortcutTrack(document));
                return new JsonObject { ["id"] = created, ["kind"] = kind };
        }

        var start = args.RequiredDouble("sourceStartMs");
        var end = args.RequiredDouble("sourceEndMs");
        var duration = session.SourceDurationMs;
        if (start < 0 || end <= start || start >= duration)
        {
            throw new McpToolException($"sourceStartMs and sourceEndMs must be inside 0...{(int)duration} with end after start.");
        }

        end = Math.Min(end, duration);
        var document = session.Document;
        var before = McpDocument.ItemIds(document);
        string? id = null;
        switch (kind)
        {
            case "zoom":
                McpDocument.RequireFree(document.Timeline.Zooms.Select(item => (item.Id, item.SourceStartMs, item.SourceEndMs)), start, end, "zoom");
                if (end - start < 350)
                {
                    throw new McpToolException("A zoom must last at least 350 ms.");
                }

                session.AddZoomInRange(start, end);
                break;
            case "camera_layout":
                McpDocument.RequireFree(document.Timeline.CameraLayouts.Select(item => (item.Id, item.SourceStartMs, item.SourceEndMs)), start, end, "camera layout");
                var type = CameraTimelineLayoutType.CameraOverlay;
                if (args.String("layoutType") is { } layoutName)
                {
                    type = McpDocument.Parse<CameraTimelineLayoutType>(layoutName)
                        ?? throw new McpToolException($"Unknown layoutType {layoutName}. Allowed: {string.Join(", ", McpDocument.Values<CameraTimelineLayoutType>().Select(item => item!.GetValue<string>()))}");
                }

                session.AddCameraLayoutInRange(type, start, end);
                break;
            case "caption":
                var requestedTrack = args.String("trackId");
                if (requestedTrack == "new" || (requestedTrack is null && document.Captions.CaptionTracks.Count == 0))
                {
                    session.AddCaptionTrack(start, end, args.String("text") ?? "New caption");
                    break;
                }

                var trackId = requestedTrack ?? document.Captions.CaptionTracks[0].Id;
                if (!session.Document.Captions.CaptionTracks.Exists(track => track.Id == trackId))
                {
                    throw new McpToolException("No caption track " + trackId + ".");
                }

                McpDocument.RequireFree(session.Document.Captions.CaptionBlocks.Where(item => item.TrackId == trackId).Select(item => (item.Id, item.SourceStartMs, item.SourceEndMs)), start, end,
                    "caption on that track (pass another trackId, or trackId \"new\" for a new track)");
                session.AddCaption(trackId, start, end, args.String("text") ?? "New caption");
                break;
            case "mask":
                if (end - start < 300)
                {
                    throw new McpToolException("A mask must last at least 300 ms.");
                }

                id = AddMask(session, args, start, end);
                break;
            case "annotation":
            {
                if (end - start < AnnotationItem.MinDurationMs)
                {
                    throw new McpToolException("An annotation must last at least 220 ms.");
                }

                var annotationKind = AnnotationKind.Text;
                if (args.String("annotationKind") is { } kindName)
                {
                    annotationKind = McpDocument.Parse<AnnotationKind>(kindName)
                        ?? throw new McpToolException($"Unknown annotationKind {kindName}. Allowed: {string.Join(", ", McpDocument.Values<AnnotationKind>().Select(item => item!.GetValue<string>()))}");
                }

                if (args.String("trackId") is { } annotationTrackId)
                {
                    var track = document.Timeline.AnnotationTracks.Find(item => item.Id == annotationTrackId)
                        ?? throw new McpToolException($"No annotation track {annotationTrackId}.");
                    McpDocument.RequireFree(track.Items.Select(item => (item.Id, item.SourceStartMs, item.SourceEndMs)), start, end, "annotation on that track", tolerance: AnnotationTrack.OverlapToleranceMs);
                    session.AddAnnotationInRange(annotationTrackId, start, end);
                    id = session.SelectedAnnotationId;
                    if (id is not null && session.Annotation(id)?.Kind != annotationKind)
                    {
                        session.UpdateAnnotation(id, item => item.Kind = annotationKind);
                    }
                }
                else
                {
                    session.AddAnnotationInTimeRange(annotationKind, start, end);
                    id = session.SelectedAnnotationId;
                }

                if (id is not null && args.String("text") is { } annotationText)
                {
                    session.UpdateAnnotation(id, item => item.Text = annotationText);
                }

                if (id is not null && args.String("imagePath") is { } imagePath)
                {
                    var file = Environment.ExpandEnvironmentVariables(imagePath);
                    if (!File.Exists(file) || editor.McpSource.PackagePath is not { } package)
                    {
                        session.DeleteAnnotation(id);
                        throw new McpToolException($"No image at {imagePath}.");
                    }

                    var name = Guid.NewGuid().ToString().ToUpperInvariant() + Path.GetExtension(file).ToLowerInvariant();
                    Directory.CreateDirectory(Path.Combine(package, "assets", "annotations"));
                    File.Copy(file, Path.Combine(package, "assets", "annotations", name));
                    var stored = "assets/annotations/" + name;
                    session.UpdateAnnotation(id, item =>
                    {
                        item.ImagePath = stored;
                        item.Kind = AnnotationKind.Image;
                    });
                }

                break;
            }

            case "shortcut":
                var shortcutsBefore = session.Document.Captions.CustomShortcuts.Select(item => item.Id).ToHashSet();
                session.AddCustomShortcut(args.String("trackId"), start, end);
                id = session.Document.Captions.CustomShortcuts.Select(item => item.Id).FirstOrDefault(item => !shortcutsBefore.Contains(item));
                if (id is not null)
                {
                    var keys = new JsonObject { ["primaryKey"] = args.String("primaryKey") ?? "K" };
                    keys["modifiers"] = args.Raw["modifiers"] is JsonArray modifiers ? modifiers.DeepClone() : new JsonArray();
                    session.ReplaceDocument(McpDocument.PatchItem(session.Document, "custom_shortcut", id, keys));
                }

                break;
            default:
                throw new McpToolException("Unknown kind: " + kind);
        }

        id ??= McpDocument.ItemIds(session.Document).Except(before).FirstOrDefault()
            ?? throw new McpToolException("Nothing was added (the range may overlap another item or be too short).");
        if (args.Object("properties") is { } properties)
        {
            PatchItem(session, kind == "shortcut" ? "custom_shortcut" : kind, id, properties);
        }

        return new JsonObject { ["id"] = id, ["kind"] = kind };
    }

    private static string AddMask(EditorSession session, McpArgs args, double start, double end)
    {
        var type = MaskType.Blur;
        if (args.String("maskType") is { } typeName)
        {
            type = McpDocument.Parse<MaskType>(typeName) ?? throw new McpToolException($"Unknown maskType {typeName}. Allowed: blur, spotlight");
        }

        var rect = new Rect01(0.36, 0.43, 0.28, 0.14);
        if (args.Object("rect01") is { } patch)
        {
            var merged = McpDocument.MergePatch(JsonNode.Parse(JsonSerializer.Serialize(rect, ProjectJson.Options)), patch)!;
            rect = JsonSerializer.Deserialize<Rect01>(merged.ToJsonString(), ProjectJson.Options) ?? rect;
        }

        var requested = args.String("trackId");
        if (requested is not null && !session.Document.Timeline.MaskTracks.Exists(track => track.Id == requested))
        {
            throw new McpToolException("No mask track " + requested + ".");
        }

        if (requested is not null)
        {
            McpDocument.RequireFree(session.Document.Timeline.MaskTracks.First(track => track.Id == requested).Items.Select(item => (item.Id, item.SourceStartMs, item.SourceEndMs)), start, end, "mask on that track");
        }

        var item = new MaskItem
        {
            Id = EditorSession.NewId(),
            SourceStartMs = start,
            SourceEndMs = end,
            Type = type,
            Style = MaskStyle.Gaussian,
            Intensity = type == MaskType.Spotlight ? 50 : 36,
            CornerRadius = 12,
            Keyframes = [new MaskKeyframe { SourceMs = start, Rect01 = Clamp(rect) }]
        };
        session.Mutate(document =>
        {
            var tracks = document.Timeline.MaskTracks;
            var index = requested is not null
                ? tracks.FindIndex(track => track.Id == requested)
                : tracks.FindIndex(track => !track.Items.Exists(other => !(end <= other.SourceStartMs + 30 || start >= other.SourceEndMs - 30)));
            if (index >= 0)
            {
                tracks[index].IsHidden = false;
                tracks[index].Items.Add(item);
                tracks[index].Items.Sort((a, b) => a.SourceStartMs.CompareTo(b.SourceStartMs));
            }
            else
            {
                tracks.Add(new MaskTrack { Id = EditorSession.NewId(), Name = "Masks", Items = [item] });
            }
        });
        return item.Id;
    }

    private static Rect01 Clamp(Rect01 rect)
    {
        var width = Math.Clamp(rect.Width, 0.01, 1);
        var height = Math.Clamp(rect.Height, 0.01, 1);
        return new Rect01(Math.Clamp(rect.X, 0, 1 - width), Math.Clamp(rect.Y, 0, 1 - height), width, height);
    }

    private static JsonObject UpdateItem(McpArgs args)
    {
        var session = Editor(args).McpSession;
        var patch = args.Object("patch") ?? throw new McpToolException("Missing argument: patch");
        var kind = args.Required("kind");
        var id = args.Required("id");
        session.StartNewUndoStep();
        PatchItem(session, kind, id, patch);
        return new JsonObject { ["id"] = id, ["kind"] = kind };
    }

    private static void PatchItem(EditorSession session, string kind, string id, JsonObject patch)
    {
        patch = (JsonObject)patch.DeepClone();
        if (kind == "annotation" && patch["layer"] is { } layer)
        {
            var move = layer.GetValue<string>() switch
            {
                "front" => AnnotationLayerMove.Front,
                "forward" => AnnotationLayerMove.Forward,
                "backward" => AnnotationLayerMove.Backward,
                "back" => AnnotationLayerMove.Back,
                _ => throw new McpToolException("layer must be one of: front, forward, backward, back.")
            };
            if (session.Annotation(id) is null)
            {
                throw new McpToolException("No annotation with id " + id + ".");
            }

            patch.Remove("layer");
            session.MoveAnnotationLayer(id, move);
            if (patch.Count == 0)
            {
                return;
            }
        }

        if (kind == "caption" && patch["text"]?.GetValue<string>() is { } text)
        {
            if (!session.Document.Captions.CaptionBlocks.Exists(block => block.Id == id))
            {
                throw new McpToolException("No caption with id " + id + ".");
            }

            patch.Remove("text");
            session.UpdateCaptionText(id, text);
            if (patch.Count == 0)
            {
                return;
            }
        }

        session.ReplaceDocument(McpDocument.PatchItem(session.Document, kind, id, patch));
    }

    private static JsonObject DeleteItem(McpArgs args)
    {
        var editor = Editor(args);
        var session = editor.McpSession;
        var kind = args.Required("kind");
        var id = args.String("id") ?? "";
        var document = session.Document;
        session.StartNewUndoStep();
        void Require(bool exists)
        {
            if (!exists)
            {
                throw new McpToolException($"No {kind} with id {id}.");
            }
        }

        switch (kind)
        {
            case "slice":
                Require(document.Timeline.Slices.Exists(item => item.Id == id));
                if (document.Timeline.Slices.Count <= 1)
                {
                    throw new McpToolException("The last clip cannot be deleted.");
                }

                session.Mutate(next => next.Timeline.Slices.RemoveAll(item => item.Id == id));
                break;
            case "zoom":
                Require(document.Timeline.Zooms.Exists(item => item.Id == id));
                session.Mutate(next => next.Timeline.Zooms.RemoveAll(item => item.Id == id));
                break;
            case "mask":
                Require(document.Timeline.MaskTracks.Exists(track => track.Items.Exists(item => item.Id == id)));
                session.DeleteMask(id);
                break;
            case "annotation":
                Require(session.Annotation(id) is not null);
                session.DeleteAnnotation(id);
                break;
            case "annotation_track":
                Require(document.Timeline.AnnotationTracks.Exists(item => item.Id == id));
                session.DeleteTimelineTrack(new DeletableTimelineTrack(DeletableTrackKind.Annotation, id));
                break;
            case "camera_layout":
                Require(document.Timeline.CameraLayouts.Exists(item => item.Id == id));
                session.DeleteLayout(id);
                break;
            case "voiceover":
                Require(document.Timeline.Voiceovers.Exists(item => item.Id == id));
                session.DeleteVoiceover(id);
                break;
            case "caption":
                Require(document.Captions.CaptionBlocks.Exists(item => item.Id == id));
                session.DeleteCaption(id);
                break;
            case "shortcut":
                var cluster = session.Shortcuts().FirstOrDefault(item => item.Id == id)
                    ?? throw new McpToolException($"No shortcut with id {id}. Shortcut ids are in get_project info.shortcuts.");
                session.DeleteShortcut(cluster);
                break;
            case "caption_track":
                Require(document.Captions.CaptionTracks.Exists(item => item.Id == id));
                session.DeleteTimelineTrack(new DeletableTimelineTrack(DeletableTrackKind.Caption, id));
                break;
            case "mask_track":
                Require(document.Timeline.MaskTracks.Exists(item => item.Id == id));
                session.DeleteTimelineTrack(new DeletableTimelineTrack(DeletableTrackKind.Mask, id));
                break;
            case "shortcut_track":
                Require(document.Captions.ShortcutTracks.Exists(item => item.Id == id));
                session.DeleteTimelineTrack(new DeletableTimelineTrack(DeletableTrackKind.Shortcut, id));
                break;
            case "voiceover_track":
                Require(int.TryParse(id, NumberStyles.Integer, CultureInfo.InvariantCulture, out var index) && document.Timeline.Voiceovers.Exists(item => item.TrackIndex == index));
                if (!session.DeleteTimelineTrack(new DeletableTimelineTrack(DeletableTrackKind.Voiceover, Index: index)))
                {
                    throw new McpToolException("A voiceover is being recorded.");
                }

                break;
            case "camera_layouts_track":
                session.DeleteTimelineTrack(new DeletableTimelineTrack(DeletableTrackKind.CameraLayouts));
                break;
            default:
                throw new McpToolException("Unknown kind: " + kind);
        }

        return new JsonObject { ["deleted"] = kind, ["id"] = id };
    }

    private static JsonObject SplitItem(McpArgs args)
    {
        var session = Editor(args).McpSession;
        var kind = args.Required("kind");
        var id = args.Required("id");
        var timelineMs = args.RequiredDouble("atTimelineMs");
        var sourceMs = session.Mapper.SourceTime(timelineMs).SourceMs;
        var before = ProjectJson.Serialize(session.Document);
        session.StartNewUndoStep();
        switch (kind)
        {
            case "slice":
                if (!session.Document.Timeline.Slices.Exists(item => item.Id == id))
                {
                    throw new McpToolException("No slice with id " + id + ".");
                }

                session.SplitSlice(timelineMs);
                break;
            case "zoom": session.SplitZoom(id, sourceMs); break;
            case "mask": session.SplitMask(id, sourceMs); break;
            case "annotation": session.SplitAnnotation(id, sourceMs); break;
            case "caption": session.SplitCaption(id, sourceMs); break;
            case "camera_layout": session.SplitLayout(id, sourceMs); break;
            case "voiceover": session.SplitVoiceover(id, sourceMs); break;
            default: throw new McpToolException("Unknown kind: " + kind);
        }

        if (ProjectJson.Serialize(session.Document) == before)
        {
            throw new McpToolException("Nothing was split: check the id and that the time is inside the item, away from its edges.");
        }

        return new JsonObject { ["split"] = kind, ["id"] = id, ["atSourceMs"] = sourceMs };
    }

    private static JsonObject History(McpArgs args, bool redo)
    {
        var session = Editor(args).McpSession;
        var steps = Math.Clamp(args.Int("steps") ?? 1, 1, 50);
        var done = 0;
        for (; done < steps; done++)
        {
            if (redo ? !session.History.CanRedo : !session.History.CanUndo)
            {
                break;
            }

            if (redo)
            {
                session.Redo();
            }
            else
            {
                session.Undo();
            }
        }

        return new JsonObject { ["steps"] = done, ["canUndo"] = session.History.CanUndo, ["canRedo"] = session.History.CanRedo };
    }

    // MARK: Frames

    /// <summary>The composited frame at the playhead, through the export renderer. Moves the editor's playhead there.</summary>
    private static async Task<(byte[] Bytes, int Width, int Height, double TimelineMs)> Frame(McpArgs args, int defaultHeight, bool jpeg)
    {
        var editor = Editor(args);
        editor.McpPause();
        if (args.Double("timelineMs") is { } ms)
        {
            editor.McpSeek(ms);
        }

        var session = editor.McpSession;
        var height = Math.Clamp(args.Int("height") ?? defaultHeight, 240, 4320);
        var file = Path.Combine(Path.GetTempPath(), $"ns-mcp-{Guid.NewGuid():N}" + (jpeg ? ".jpg" : ".png"));
        try
        {
            await new ProjectExporter(editor.McpExportSource()).ExportStillAsync(file, session.SourceAtPlayhead, height, jpeg);
            var bytes = await File.ReadAllBytesAsync(file);
            var (width, imageHeight) = ImageSize(bytes);
            return (bytes, width, imageHeight, session.PlayheadTimelineMs);
        }
        finally
        {
            File.Delete(file);
        }
    }

    private static (int Width, int Height) ImageSize(byte[] bytes)
    {
        if (bytes.Length > 24 && bytes[0] == 0x89 && bytes[1] == 0x50)
        {
            return ((bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19], (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23]);
        }

        for (var at = 2; at + 9 < bytes.Length;)
        {
            if (bytes[at] != 0xFF)
            {
                break;
            }

            var marker = bytes[at + 1];
            var length = (bytes[at + 2] << 8) | bytes[at + 3];
            if (marker is >= 0xC0 and <= 0xC3)
            {
                return ((bytes[at + 7] << 8) | bytes[at + 8], (bytes[at + 5] << 8) | bytes[at + 6]);
            }

            at += 2 + length;
        }

        return (0, 0);
    }

    private static async Task<JsonObject> RenderFrame(McpArgs args)
    {
        var (bytes, width, height, timelineMs) = await Frame(args, 720, jpeg: false);
        return new JsonObject
        {
            ["content"] = new JsonArray(
                new JsonObject { ["type"] = "image", ["data"] = Convert.ToBase64String(bytes), ["mimeType"] = "image/png" },
                new JsonObject { ["type"] = "text", ["text"] = $"Frame at {(int)timelineMs} ms (timeline), {width}×{height}." })
        };
    }

    private static async Task<JsonObject> ExportFrame(McpArgs args)
    {
        var path = FullPath(args.Required("outputPath"));
        var extension = Path.GetExtension(path).ToLowerInvariant();
        if (extension is not (".png" or ".jpg" or ".jpeg"))
        {
            throw new McpToolException("outputPath must end in .png or .jpg.");
        }

        var (bytes, width, height, timelineMs) = await Frame(args, 1440, extension != ".png");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        await File.WriteAllBytesAsync(path, bytes);
        return new JsonObject { ["path"] = path, ["width"] = width, ["height"] = height, ["timelineMs"] = timelineMs };
    }

    // MARK: Actions and options

    private static JsonObject RunAction(McpArgs args)
    {
        var editor = Editor(args);
        var session = editor.McpSession;
        var action = args.Required("action");
        session.StartNewUndoStep();
        switch (action)
        {
            case "regenerate_auto_zooms":
                if (session.ClickEvents.Count == 0 && session.KeyEvents.Count == 0)
                {
                    throw new McpToolException("This project has no recorded clicks or typing to make zooms from.");
                }

                session.RegenerateAutoZooms();
                return new JsonObject { ["zooms"] = session.Document.Timeline.Zooms.Count };
            case "generate_transcript":
                editor.McpTools.GenerateTranscript();
                return new JsonObject { ["started"] = true, ["note"] = "Poll get_project until info.isGeneratingTranscript is false." };
            case "remove_filler_words":
                RequireTranscript(session);
                session.Mutate(document => TranscriptEditing.RemoveFillers(document, session.SourceDurationMs));
                break;
            case "tighten_pauses":
                RequireTranscript(session);
                session.Mutate(TranscriptEditing.TightenPauses);
                break;
            case "reset_cuts":
                session.ResetAllSlices();
                break;
            case "scan_sensitive_data":
                editor.McpTools.SetHideSensitive(true);
                break;
            case "scan_faces":
                editor.McpTools.SetHideFaces(true);
                break;
            case "play":
                editor.McpPlay();
                break;
            case "pause":
                editor.McpPause();
                break;
            default:
                throw new McpToolException("Unknown action: " + action);
        }

        return new JsonObject { ["done"] = action };
    }

    private static void RequireTranscript(EditorSession session)
    {
        if (session.Document.Captions.Segments.Count == 0)
        {
            throw new McpToolException("There is no transcript yet. Run generate_transcript first.");
        }
    }

    private static List<(WallpaperItem Item, string Category)> AllWallpapers() =>
    [
        .. EditorTools.SystemWallpapers().Select(item => (item, "Windows")),
        .. BundledWallpaperCatalog.Categories.SelectMany(category => BundledWallpaperCatalog.Items(category).Select(item => (item, category)))
    ];

    private static JsonObject ListOptions(McpArgs args)
    {
        switch (args.Required("kind"))
        {
            case "wallpapers":
                return new JsonObject { ["wallpapers"] = new JsonArray(AllWallpapers().Select(item => (JsonNode)new JsonObject { ["name"] = item.Item.Id, ["category"] = item.Category }).ToArray()) };
            case "mesh_presets":
                return new JsonObject { ["meshPresets"] = new JsonArray(MeshPreset.BuiltIn.Select(item => (JsonNode)new JsonObject { ["id"] = item.Id, ["name"] = item.Name, ["category"] = item.Category }).ToArray()) };
            case "cursor_themes":
                var root = Path.Combine(AppContext.BaseDirectory, "Assets", "Cursors", "sets");
                IEnumerable<string> themes = Directory.Exists(root) ? Directory.GetDirectories(root).Select(Path.GetFileName).OfType<string>().Order() : Array.Empty<string>();
                return new JsonObject
                {
                    ["cursorThemes"] = new JsonArray(themes.Select(id => (JsonNode)new JsonObject
                    {
                        ["id"] = id,
                        ["name"] = CursorThemeCards.DisplayName(id),
                        ["variantIds"] = new JsonArray(CursorThemeCards.PointerVariants(id).Select(variant => (JsonNode)variant.Id).ToArray())
                    }).ToArray())
                };
            case "presets":
                var presets = new ProjectPresetStore(EditorTools.PresetsDirectory).Load();
                return new JsonObject
                {
                    ["presets"] = new JsonArray(presets.Select(item => (JsonNode)new JsonObject { ["id"] = item.Id, ["name"] = item.Name, ["isDefault"] = item.Id == AppSettings.Shared.DefaultPresetId }).ToArray())
                };
            case "background_music":
                return new JsonObject
                {
                    ["backgroundMusic"] = new JsonArray(BuiltInBackgroundMusic.Genres.SelectMany(BuiltInBackgroundMusic.Tracks).Distinct().Select(item => (JsonNode)item).ToArray()),
                    ["note"] = "Set audio.backgroundMusic.relativePath to one of these names with update_project."
                };
            case "enums":
                return new JsonObject { ["enums"] = McpDocument.EnumOptions() };
            case var other:
                throw new McpToolException("Unknown kind: " + other);
        }
    }

    private static JsonObject SetBackground(McpArgs args)
    {
        var editor = Editor(args);
        var session = editor.McpSession;
        session.StartNewUndoStep();
        if (args.String("wallpaper") is { } name)
        {
            var match = AllWallpapers().Select(item => item.Item).FirstOrDefault(item => string.Equals(item.Id, name, StringComparison.OrdinalIgnoreCase))
                ?? throw new McpToolException($"No wallpaper named {name}. Use list_options kind wallpapers.");
            editor.McpTools.SelectWallpaper(match);
        }
        else if (args.String("imagePath") is { } imagePath)
        {
            var path = FullPath(imagePath);
            if (!File.Exists(path))
            {
                throw new McpToolException("Not an image: " + imagePath);
            }

            editor.McpTools.SetBackgroundImage(path);
        }
        else if (args.String("meshPresetId") is { } meshId)
        {
            if (!MeshPreset.BuiltIn.Any(item => item.Id == meshId))
            {
                throw new McpToolException($"No mesh preset {meshId}. Use list_options kind mesh_presets.");
            }

            session.Mutate(document =>
            {
                document.Background.Type = BackgroundType.Mesh;
                document.Background.MeshPresetId = meshId;
            });
        }
        else if (args.String("solidColor") is { } color)
        {
            session.Mutate(document =>
            {
                document.Background.Type = BackgroundType.Solid;
                document.Background.SolidColor = color;
            });
        }
        else if (args.Raw["gradient"] is JsonArray { Count: 2 } colors)
        {
            var from = colors[0]?.GetValue<string>() ?? "#000000";
            var to = colors[1]?.GetValue<string>() ?? "#000000";
            session.Mutate(document =>
            {
                document.Background.Type = BackgroundType.Gradient;
                document.Background.Gradient.Stops = [new GradientStopConfig(from, 0), new GradientStopConfig(to, 1)];
            });
        }
        else
        {
            throw new McpToolException("Pass one of wallpaper, imagePath, meshPresetId, solidColor or gradient.");
        }

        return new JsonObject { ["background"] = McpDocument.ToJson(session.Document)["background"]?.DeepClone() };
    }

    private static JsonObject ApplyPreset(McpArgs args)
    {
        var session = Editor(args).McpSession;
        var name = args.Required("name");
        var preset = new ProjectPresetStore(EditorTools.PresetsDirectory).Load()
            .Find(item => string.Equals(item.Name, name, StringComparison.CurrentCultureIgnoreCase) || item.Id == name)
            ?? throw new McpToolException($"No preset named {name}. Use list_options kind presets.");
        session.StartNewUndoStep();
        session.Mutate(preset.Apply);
        return new JsonObject { ["applied"] = preset.Name };
    }

    // MARK: Recording

    private static JsonObject ListCaptureTargets()
    {
        static JsonArray Devices(IEnumerable<CaptureDeviceInfo> list) =>
            new(list.Select(item => (JsonNode)new JsonObject { ["id"] = item.Id, ["name"] = item.Name, ["isDefault"] = item.IsDefault }).ToArray());

        var choices = RecordingHudWindow.McpChoices;
        return new JsonObject
        {
            ["displays"] = new JsonArray(CaptureTargets.Displays().Select(display => (JsonNode)new JsonObject
            {
                ["id"] = display.Id,
                ["name"] = display.Name,
                ["width"] = Math.Round(display.Bounds.Width / display.Scale),
                ["height"] = Math.Round(display.Bounds.Height / display.Scale),
                ["isMain"] = display.IsPrimary
            }).ToArray()),
            ["windows"] = new JsonArray(CaptureTargets.WindowsFrontToBack().Take(40).Select(window => (JsonNode)new JsonObject
            {
                ["id"] = (long)window.Handle,
                ["app"] = window.AppName,
                ["title"] = window.Title,
                ["bounds"] = new JsonObject { ["x"] = window.Bounds.X, ["y"] = window.Bounds.Y, ["width"] = window.Bounds.Width, ["height"] = window.Bounds.Height }
            }).ToArray()),
            ["cameras"] = Devices(WebcamRecorder.Cameras()),
            ["microphones"] = Devices(AudioTrackRecorder.Microphones()),
            ["audioApps"] = new JsonArray(AudioApps.List().Select(app => (JsonNode)new JsonObject { ["id"] = app.Id, ["name"] = app.Name }).ToArray()),
            ["current"] = new JsonObject
            {
                ["cameraId"] = choices.CameraId,
                ["microphoneId"] = choices.MicrophoneId,
                ["systemAudio"] = choices.SystemAudio,
                ["countdownSeconds"] = AppSettings.Shared.CountdownSeconds
            }
        };
    }

    private static JsonObject StartRecording(McpArgs args)
    {
        var target = args.Object("target") ?? throw new McpToolException("Missing argument: target.type");
        var targetArgs = new McpArgs(target);
        var chosen = targetArgs.Required("type") switch
        {
            "display" => DisplayTarget(targetArgs.Long("displayId")),
            "window" => WindowTarget(targetArgs.Long("windowId") ?? throw new McpToolException("Missing argument: target.windowId")),
            "area" => AreaTarget(targetArgs.Object("rect")),
            "camera" => RecordingHudWindow.McpCameraTarget(),
            _ => throw new McpToolException("target.type must be display, window, area or camera.")
        };

        (bool, CaptureDeviceInfo?) camera = (false, null);
        if (args.Has("cameraId"))
        {
            camera = (true, args.String("cameraId") is { } cameraId
                ? WebcamRecorder.Cameras().FirstOrDefault(item => item.Id == cameraId) ?? throw new McpToolException($"No camera {cameraId}. Use list_capture_targets.")
                : null);
        }

        (bool, CaptureDeviceInfo?) microphone = (false, null);
        if (args.Has("microphoneId"))
        {
            microphone = (true, args.String("microphoneId") is { } microphoneId
                ? AudioTrackRecorder.Microphones().FirstOrDefault(item => item.Id == microphoneId) ?? throw new McpToolException($"No microphone {microphoneId}. Use list_capture_targets.")
                : null);
        }

        var countdown = args.Int("countdownSeconds");
        if (countdown is not null and not (0 or 3 or 5 or 10))
        {
            throw new McpToolException("countdownSeconds must be 0, 3, 5 or 10.");
        }

        RecordingHudWindow.McpStart(chosen, camera, microphone, args.Bool("systemAudio"), countdown);
        return new JsonObject
        {
            ["started"] = true,
            ["mode"] = McpDocument.Name(chosen.Mode),
            ["countdownSeconds"] = countdown ?? AppSettings.Shared.CountdownSeconds,
            ["note"] = "Use control_recording stop to finish; get_status shows the state."
        };
    }

    private static CaptureTarget DisplayTarget(long? id)
    {
        var displays = CaptureTargets.Displays();
        var display = id is { } wanted
            ? displays.FirstOrDefault(item => item.Id == wanted) ?? throw new McpToolException($"No display {wanted}. Use list_capture_targets.")
            : displays.FirstOrDefault(item => item.IsPrimary) ?? displays[0];
        return new CaptureTarget(CaptureTargetMode.Display, display, null, display.Bounds);
    }

    private static CaptureTarget WindowTarget(long id)
    {
        var window = CaptureTargets.WindowsFrontToBack().FirstOrDefault(item => (long)item.Handle == id)
            ?? throw new McpToolException($"No window {id}. Use list_capture_targets.");
        return new CaptureTarget(CaptureTargetMode.Window, CaptureTargets.DisplayOf(window.Bounds), window, window.Bounds);
    }

    /// <summary>An area in screen points from the top left of the main display, turned into pixels at the main display's scale.</summary>
    private static CaptureTarget AreaTarget(JsonObject? rect)
    {
        var area = rect is null ? null : new McpArgs(rect);
        if (area?.Double("x") is not { } x || area.Double("y") is not { } y || area.Double("width") is not { } width || area.Double("height") is not { } height || width < 64 || height < 64)
        {
            throw new McpToolException("target.rect needs x, y, width and height (at least 64 points).");
        }

        var displays = CaptureTargets.Displays();
        var scale = (displays.FirstOrDefault(item => item.IsPrimary) ?? displays[0]).Scale;
        var pixels = new NativeScreen.Media.PixelRect((int)Math.Round(x * scale), (int)Math.Round(y * scale), (int)Math.Round(width * scale), (int)Math.Round(height * scale));
        return new CaptureTarget(CaptureTargetMode.Area, CaptureTargets.DisplayOf(pixels), null, pixels);
    }

    private static async Task<JsonObject> ControlRecording(McpArgs args)
    {
        switch (args.Required("action"))
        {
            case "pause":
                return new JsonObject { ["state"] = await RecordingHudWindow.McpPause(true) };
            case "resume":
                return new JsonObject { ["state"] = await RecordingHudWindow.McpPause(false) };
            case "stop":
                var package = await RecordingHudWindow.McpStop();
                var key = Path.GetFullPath(package).TrimEnd(Path.DirectorySeparatorChar);
                var editor = Projects.Editors.TryGetValue(key, out var opened) ? opened : await Projects.OpenAndGet(package);
                var result = new JsonObject { ["stopped"] = true };
                result["project"] = editor is null ? new JsonObject { ["path"] = package } : Summary(editor);
                return result;
            case "restart":
                await RecordingHudWindow.McpRestart();
                return new JsonObject { ["restarted"] = true };
            case "cancel":
                return new JsonObject { ["cancelled"] = await RecordingHudWindow.McpCancel() };
            case var other:
                throw new McpToolException("Unknown action: " + other);
        }
    }

    // MARK: Settings

    private static readonly string[] AfterRecordingValues = ["project", "export", "clipboard"];

    private static JsonObject GetSettings()
    {
        var settings = AppSettings.Shared;
        return new JsonObject
        {
            ["general"] = new JsonObject
            {
                ["appearance"] = settings.Appearance,
                ["language"] = string.IsNullOrEmpty(settings.Language) ? "system" : settings.Language,
                ["launchAtLogin"] = false,
                ["allowedValues"] = new JsonObject
                {
                    ["appearance"] = new JsonArray("dark", "light"),
                    ["language"] = new JsonArray(new[] { "system" }.Concat(Loc.Languages.Select(item => item.Id)).Select(item => (JsonNode)item).ToArray())
                }
            },
            ["recording"] = new JsonObject
            {
                ["countdownSeconds"] = settings.CountdownSeconds,
                ["afterRecording"] = settings.AfterRecording,
                ["autoCreateZooms"] = settings.AutoCreateZooms,
                ["highlightRecordedArea"] = settings.HighlightRecordedArea,
                ["allowedValues"] = new JsonObject
                {
                    ["countdownSeconds"] = new JsonArray(0, 3, 5, 10),
                    ["afterRecording"] = new JsonArray(AfterRecordingValues.Select(item => (JsonNode)item).ToArray())
                }
            },
            ["editing"] = new JsonObject
            {
                ["autosave"] = settings.AutosaveEnabled,
                ["projectsDirectory"] = settings.ProjectsDirectory,
                ["presetsDirectory"] = EditorTools.PresetsDirectory
            },
            ["quickExport"] = JsonNode.Parse(ProjectJson.Serialize(settings.QuickExport)),
            ["notes"] = new JsonArray("On Windows, launchAtLogin, hideDesktopIcons, hideDockIcon, cameraMaxResolution, useLastProjectSettings and presetsDirectory cannot be changed here.")
        };
    }

    private static JsonObject UpdateSettings(McpArgs args)
    {
        var patch = args.Object("patch") ?? throw new McpToolException("Missing argument: patch");
        var settings = AppSettings.Shared;
        var general = new McpArgs(patch["general"] as JsonObject ?? []);
        var recording = new McpArgs(patch["recording"] as JsonObject ?? []);
        var editing = new McpArgs(patch["editing"] as JsonObject ?? []);
        var notes = new List<string>();

        // Everything is checked first, so a bad value changes nothing.
        var appearance = general.String("appearance");
        if (appearance is not null and not ("dark" or "light"))
        {
            throw new McpToolException($"Unknown appearance {appearance}.");
        }

        var language = general.String("language");
        if (language is not null && language != "system" && !Array.Exists(Loc.Languages, item => item.Id == language))
        {
            throw new McpToolException($"Unknown language {language}.");
        }

        var countdown = recording.Int("countdownSeconds");
        if (countdown is not null and not (0 or 3 or 5 or 10))
        {
            throw new McpToolException("countdownSeconds must be 0, 3, 5 or 10.");
        }

        var after = recording.String("afterRecording");
        if (after is not null && !AfterRecordingValues.Contains(after))
        {
            throw new McpToolException($"Unknown afterRecording {after}.");
        }

        ExportSettings? quick = null;
        if (patch["quickExport"] is JsonObject quickPatch)
        {
            quick = ExportPatched(settings.QuickExport, quickPatch);
        }

        if (appearance is not null)
        {
            AppTheme.Set(appearance == "light" ? Microsoft.UI.Xaml.ElementTheme.Light : Microsoft.UI.Xaml.ElementTheme.Dark);
        }

        if (language is not null)
        {
            var value = language == "system" ? "" : language;
            if (value != settings.Language)
            {
                settings.Language = value;
                notes.Add("The language applies after Native Screen restarts.");
            }
        }

        if (countdown is { } seconds)
        {
            settings.CountdownSeconds = seconds;
        }

        if (after is not null)
        {
            settings.AfterRecording = after;
        }

        if (recording.Bool("autoCreateZooms") is { } autoZooms)
        {
            settings.AutoCreateZooms = autoZooms;
        }

        if (recording.Bool("highlightRecordedArea") is { } highlight)
        {
            settings.HighlightRecordedArea = highlight;
        }

        if (editing.Bool("autosave") is { } autosave)
        {
            settings.AutosaveEnabled = autosave;
        }

        if (editing.String("projectsDirectory") is { } folder)
        {
            settings.ProjectsDirectory = FullPath(folder);
        }

        if (quick is not null)
        {
            settings.QuickExport = quick;
        }

        settings.Save();
        var result = GetSettings();
        if (notes.Count > 0)
        {
            result["notes"] = new JsonArray(notes.Select(item => (JsonNode)item).ToArray());
        }

        return result;
    }

    private static ExportSettings ExportPatched(ExportSettings current, JsonObject patch)
    {
        var merged = McpDocument.MergePatch(JsonNode.Parse(ProjectJson.Serialize(current)), patch)!;
        ExportSettings next;
        try
        {
            next = ProjectJson.Deserialize<ExportSettings>(merged.ToJsonString());
        }
        catch (JsonException exception)
        {
            throw new McpToolException($"Invalid value at {exception.Path?.TrimStart('$', '.')}: {exception.Message.Split(" Path:")[0]}");
        }

        if (!ExportPlan.IsAvailableOnWindows(next.Format))
        {
            throw new McpToolException("ProRes export is not available on Windows. Use mp4 or gif.");
        }

        next.Normalize();
        return next;
    }

    // MARK: Export

    private async Task<JsonObject> ExportVideo(McpArgs args, Action<double, string>? progress, CancellationToken cancel)
    {
        var editor = Editor(args);
        var session = editor.McpSession;
        var settings = args.Bool("useQuickExportSettings") == true ? AppSettings.Shared.QuickExport : new ExportSettings();
        if (args.Object("config") is { } config)
        {
            var targetKey = config["target"];
            config = (JsonObject)config.DeepClone();
            config.Remove("target");
            settings = ExportPatched(settings, config);
            _ = targetKey;
        }
        else
        {
            settings = ExportPatched(settings, []);
        }

        var target = args.String("target") ?? "file";
        if (target is not ("file" or "clipboard"))
        {
            throw new McpToolException("target must be file or clipboard.");
        }

        var extension = settings.Format == ExportFormat.Gif ? ".gif" : ".mp4";
        var cleanName = string.Concat(session.Document.Name.Split(Path.GetInvalidFileNameChars())).Trim();
        cleanName = cleanName.Length == 0 ? "export" : cleanName;
        string path;
        if (target == "clipboard")
        {
            path = Path.Combine(Directory.CreateTempSubdirectory("ns-clipboard-").FullName, cleanName + extension);
        }
        else if (args.String("outputPath") is { } output)
        {
            path = FullPath(output);
            if (!string.Equals(Path.GetExtension(path), extension, StringComparison.OrdinalIgnoreCase))
            {
                path += extension;
            }
        }
        else
        {
            path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), cleanName + extension);
        }

        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        if (File.Exists(path))
        {
            File.Delete(path);
        }

        var exportId = Guid.NewGuid().ToString();
        exports[exportId] = (session.Document.Name, 0);
        editor.McpPause();
        // Stop in the editor and the client's cancel request both end the export.
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        var showShare = editor.McpBeginExport(stop);
        editor.McpToast("Exporting video...");
        var started = DateTime.UtcNow;
        var lastReported = -1.0;
        try
        {
            var both = settings.Format == ExportFormat.Mp4 && settings.Mp4Codec == Mp4CodecOption.Both;
            var passes = both ? 2 : 1;
            var pass = 0;
            var reporter = new Progress<ExportProgress>(update =>
            {
                var share = (pass + update.Encoded / (double)Math.Max(1, update.Total)) / passes;
                exports[exportId] = (session.Document.Name, share);
                showShare(share);
                if (share - lastReported >= 0.02 || share >= 1)
                {
                    lastReported = share;
                    progress?.Invoke(share, $"Exporting {(int)(share * 100)}%");
                }
            });
            var exporter = new ProjectExporter(editor.McpExportSource());
            if (both)
            {
                await exporter.RunAsync(path, Codec(settings, Mp4CodecOption.H264), reporter, stop.Token);
                pass = 1;
                var hevc = Path.Combine(Path.GetDirectoryName(path) ?? "", Path.GetFileNameWithoutExtension(path) + "-hevc.mp4");
                await exporter.RunAsync(hevc, Codec(settings, Mp4CodecOption.H265), reporter, stop.Token);
            }
            else
            {
                await exporter.RunAsync(path, settings, reporter, stop.Token);
            }
        }
        catch (OperationCanceledException) when (!cancel.IsCancellationRequested)
        {
            // The client did not ask for this, so it still needs an answer.
            throw new McpToolException("The export was stopped in the editor.");
        }
        finally
        {
            exports.Remove(exportId);
            editor.McpEndExport();
        }

        cancel.ThrowIfCancellationRequested();
        if (target == "clipboard")
        {
            var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
            package.SetStorageItems([await Windows.Storage.StorageFile.GetFileFromPathAsync(path)]);
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
        }

        editor.McpToast("Export finished");
        return new JsonObject
        {
            ["path"] = path,
            ["target"] = target,
            ["bytes"] = new FileInfo(path).Length,
            ["seconds"] = (DateTime.UtcNow - started).TotalSeconds,
            ["config"] = JsonNode.Parse(ProjectJson.Serialize(settings))
        };
    }

    private static ExportSettings Codec(ExportSettings settings, Mp4CodecOption codec)
    {
        var copy = ProjectJson.Clone(settings);
        copy.Mp4Codec = codec;
        return copy;
    }
}

/// <summary>Typed reads of tool arguments.</summary>
internal sealed class McpArgs(JsonObject raw)
{
    public JsonObject Raw { get; } = raw;

    public bool Has(string key) => Raw.ContainsKey(key);

    public string? String(string key) => Raw[key] is JsonValue value && value.TryGetValue<string>(out var text) && text.Length > 0 ? text : null;

    public string Required(string key) => String(key) ?? throw new McpToolException("Missing argument: " + key);

    public double? Double(string key) => Raw[key] is JsonValue value && value.TryGetValue<double>(out var number) ? number : null;

    public double RequiredDouble(string key) => Double(key) ?? throw new McpToolException("Missing argument: " + key);

    public int? Int(string key) => Double(key) is { } number ? (int)Math.Round(number) : null;

    public long? Long(string key) => Double(key) is { } number ? (long)Math.Round(number) : null;

    public bool? Bool(string key) => Raw[key] is JsonValue value && value.TryGetValue<bool>(out var flag) ? flag : null;

    public JsonObject? Object(string key) => Raw[key] as JsonObject;
}
