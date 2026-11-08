using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace NativeScreen.Core;

/// <summary>A tool failure the agent should see as text (isError), not a protocol error (spec/06 ADR-52).</summary>
public sealed class McpToolException(string message) : Exception(message);

/// <summary>
/// The document edits behind the MCP tools: JSON merge patches against the same JSON as project.json, validated by reading
/// the result back before anything changes, and the overlap rules items on one track follow (spec/06 ADR-52).
/// </summary>
public static class McpDocument
{
    /// <summary>RFC 7386: objects merge key by key, null removes a key, anything else replaces the target.</summary>
    public static JsonNode? MergePatch(JsonNode? target, JsonNode? patch)
    {
        if (patch is not JsonObject patchObject)
        {
            return patch?.DeepClone();
        }

        var result = target is JsonObject targetObject ? (JsonObject)targetObject.DeepClone() : new JsonObject();
        foreach (var (key, value) in patchObject)
        {
            if (value is null)
            {
                result.Remove(key);
            }
            else
            {
                var merged = MergePatch(result[key], value);
                result.Remove(key);
                result[key] = merged;
            }
        }

        return result;
    }

    /// <summary>
    /// The file options, except that an enum must be one of its names. The file reader also takes numbers, which would let a
    /// patch store a value the macOS app cannot read.
    /// </summary>
    public static JsonSerializerOptions StrictOptions { get; } = Strict();

    private static JsonSerializerOptions Strict()
    {
        var options = new JsonSerializerOptions(ProjectJson.Options);
        for (var index = options.Converters.Count - 1; index >= 0; index--)
        {
            if (options.Converters[index] is JsonStringEnumConverter)
            {
                options.Converters[index] = new JsonStringEnumConverter(null, allowIntegerValues: false);
            }
        }

        return options;
    }

    public static JsonObject ToJson(ProjectDocument document) => (JsonObject)JsonNode.Parse(ProjectJson.Serialize(document))!;

    /// <summary>Reads a document back; a value of the wrong type names its path.</summary>
    public static ProjectDocument FromJson(JsonNode node)
    {
        try
        {
            return JsonSerializer.Deserialize<ProjectDocument>(node.ToJsonString(), StrictOptions) ?? throw new McpToolException("The document is empty.");
        }
        catch (JsonException exception)
        {
            var path = string.IsNullOrEmpty(exception.Path) ? "root" : exception.Path.TrimStart('$', '.');
            throw new McpToolException($"Invalid value at {path}: {FirstLine(exception.Message)}");
        }
    }

    /// <summary>A whole-document patch. The id and schema version never change.</summary>
    public static ProjectDocument Patch(ProjectDocument document, JsonObject patch)
    {
        var next = FromJson(MergePatch(ToJson(document), patch)!);
        next.Id = document.Id;
        next.SchemaVersion = document.SchemaVersion;
        return next;
    }

    /// <summary>A patch of one timeline element, found by kind and id. Its id never changes.</summary>
    public static ProjectDocument PatchItem(ProjectDocument document, string kind, string id, JsonObject patch)
    {
        var json = ToJson(document);
        var element = FindElement(json, kind, id) ?? throw new McpToolException($"No {kind} with id {id}.");
        var cleaned = (JsonObject)patch.DeepClone();
        cleaned.Remove("id");
        var patched = (JsonObject)MergePatch(element, cleaned)!;
        foreach (var (key, _) in element.ToList())
        {
            element.Remove(key);
        }

        foreach (var (key, value) in patched.ToList())
        {
            patched.Remove(key);
            element[key] = value;
        }

        var next = FromJson(json);
        next.Timeline.Zooms.Sort((a, b) => a.SourceStartMs.CompareTo(b.SourceStartMs));
        next.Timeline.CameraLayouts.Sort((a, b) => a.SourceStartMs.CompareTo(b.SourceStartMs));
        RequireNoOverlaps(next, id);
        return next;
    }

    private static JsonObject? FindElement(JsonObject document, string kind, string id)
    {
        JsonArray? Array(params string[] path)
        {
            JsonNode? node = document;
            foreach (var key in path)
            {
                node = node?[key];
            }

            return node as JsonArray;
        }

        JsonObject? In(JsonArray? array) => array?.OfType<JsonObject>().FirstOrDefault(item => item["id"]?.GetValue<string>() == id);

        return kind switch
        {
            "slice" => In(Array("timeline", "slices")),
            "zoom" => In(Array("timeline", "zooms")),
            "camera_layout" => In(Array("timeline", "cameraLayouts")),
            "voiceover" => In(Array("timeline", "voiceovers")),
            "mask_track" => In(Array("timeline", "maskTracks")),
            "mask" => Array("timeline", "maskTracks")?.OfType<JsonObject>().Select(track => In(track["items"] as JsonArray)).FirstOrDefault(item => item is not null),
            "caption" => In(Array("captions", "captionBlocks")),
            "caption_track" => In(Array("captions", "captionTracks")),
            "shortcut_track" => In(Array("captions", "shortcutTracks")),
            "custom_shortcut" => In(Array("captions", "customShortcuts")),
            _ => throw new McpToolException($"Unknown kind: {kind}")
        };
    }

    /// <summary>Items on one track may touch but not overlap: the timeline cannot show it, and the preview would stack them.</summary>
    public static void RequireFree(IEnumerable<(string Id, double Start, double End)> items, double start, double end, string what, string? ignoring = null)
    {
        foreach (var item in items)
        {
            if (item.Id != ignoring && start < item.End - 1 && end > item.Start + 1)
            {
                throw new McpToolException($"Overlaps the {what} {item.Id} ({(int)item.Start}–{(int)item.End} ms).");
            }
        }
    }

    /// <summary>After an update: the changed item may not overlap another one. Overlaps it did not cause are left alone.</summary>
    public static void RequireNoOverlaps(ProjectDocument document, string id)
    {
        void Check(List<(string Id, double Start, double End)> items, string what)
        {
            if (items.Find(item => item.Id == id) is { Id: not null } changed)
            {
                RequireFree(items, changed.Start, changed.End, what, id);
            }
        }

        Check(document.Timeline.Zooms.Select(item => (item.Id, item.SourceStartMs, item.SourceEndMs)).ToList(), "zoom");
        Check(document.Timeline.CameraLayouts.Select(item => (item.Id, item.SourceStartMs, item.SourceEndMs)).ToList(), "camera layout");
        foreach (var track in document.Timeline.MaskTracks)
        {
            Check(track.Items.Select(item => (item.Id, item.SourceStartMs, item.SourceEndMs)).ToList(), "mask");
        }

        foreach (var track in document.Captions.CaptionTracks)
        {
            Check(document.Captions.CaptionBlocks.Where(item => item.TrackId == track.Id).Select(item => (item.Id, item.SourceStartMs, item.SourceEndMs)).ToList(), "caption");
        }
    }

    /// <summary>Every item id in the document, to find the one an add created.</summary>
    public static HashSet<string> ItemIds(ProjectDocument document)
    {
        var ids = new HashSet<string>(document.Timeline.Zooms.Select(item => item.Id));
        ids.UnionWith(document.Timeline.CameraLayouts.Select(item => item.Id));
        ids.UnionWith(document.Timeline.MaskTracks.SelectMany(track => track.Items).Select(item => item.Id));
        ids.UnionWith(document.Captions.CaptionBlocks.Select(item => item.Id));
        ids.UnionWith(document.Captions.CustomShortcuts.Select(item => item.Id));
        return ids;
    }

    /// <summary>The tool list from MCPTools.json with $ref to its definitions inlined, since clients do not resolve them.</summary>
    public static (string Instructions, JsonArray Tools) LoadTools(string json)
    {
        var root = JsonNode.Parse(json) as JsonObject ?? new JsonObject();
        var definitions = root["definitions"] as JsonObject ?? new JsonObject();
        var tools = new JsonArray();
        foreach (var tool in root["tools"] as JsonArray ?? [])
        {
            tools.Add(InlineRefs(tool, definitions));
        }

        return (root["instructions"]?.GetValue<string>() ?? "", tools);
    }

    private static JsonNode? InlineRefs(JsonNode? node, JsonObject definitions)
    {
        switch (node)
        {
            case JsonObject value:
                if (value["$ref"]?.GetValue<string>() is { } reference && reference.StartsWith("#/definitions/", StringComparison.Ordinal)
                    && definitions[reference["#/definitions/".Length..]] is { } resolved)
                {
                    return resolved.DeepClone();
                }

                var copy = new JsonObject();
                foreach (var (key, child) in value)
                {
                    copy[key] = InlineRefs(child, definitions);
                }

                return copy;
            case JsonArray array:
                var items = new JsonArray();
                foreach (var child in array)
                {
                    items.Add(InlineRefs(child, definitions));
                }

                return items;
            default:
                return node?.DeepClone();
        }
    }

    /// <summary>The values of each enum field, by its path in the document, the same paths as on macOS.</summary>
    public static JsonObject EnumOptions() => new()
    {
        ["canvas.aspectRatioMode"] = Values<AspectRatioMode>(),
        ["canvas.aspectRatioPreset"] = Values<AspectRatioPreset>(),
        ["background.type"] = Values<BackgroundType>(),
        ["background.gradient.type"] = Values<GradientType>(),
        ["frameStyle.deviceMockup.matchMode"] = Values<DeviceFrameMatchMode>(),
        ["cursor.clickEffect.visualStyle"] = Values<ClickEffectStyle>(),
        ["cursor.rotationMode"] = Values<CursorRotationMode>(),
        ["camera.layoutMode"] = Values<CameraLayoutMode>(),
        ["camera.aspectRatioPreset"] = Values<CameraAspectRatioPreset>(),
        ["camera.colorGradePreset"] = Values<CameraColorGradePreset>(),
        ["camera.shape"] = Values<CameraShape>(),
        ["audio.microphoneAudioPreset"] = Values<MicrophoneAudioPreset>(),
        ["captions.fontStyle (and every CaptionStyle.fontStyle)"] = Values<CaptionFontStyle>(),
        ["captions.wordsReveal (and CaptionStyle.wordsReveal)"] = Values<CaptionWordsReveal>(),
        ["captions.lineGrowth (and CaptionStyle.lineGrowth)"] = Values<CaptionLineGrowth>(),
        ["captions.wordAnimation (and CaptionStyle.wordAnimation)"] = Values<CaptionWordAnimation>(),
        ["captions.colorTheme (and CaptionStyle.colorTheme)"] = Values<CaptionColorTheme>(),
        ["ShortcutStyleConfig.dockPosition"] = Values<ShortcutDockPosition>(),
        ["ShortcutStyleConfig.colorMode"] = Values<ShortcutColorMode>(),
        ["timeline.zooms[].mode"] = Values<ZoomMode>(),
        ["timeline.zooms[].presentation"] = Values<ZoomPresentation>(),
        ["timeline.maskTracks[].items[].type"] = Values<MaskType>(),
        ["timeline.maskTracks[].items[].style"] = Values<MaskStyle>(),
        ["timeline.cameraLayouts[].layoutType"] = Values<CameraTimelineLayoutType>(),
        ["timeline.voiceovers[].attachMode"] = Values<VoiceoverAttachMode>()
    };

    /// <summary>An enum's values as the file stores them.</summary>
    public static JsonArray Values<T>() where T : struct, Enum
    {
        var array = new JsonArray();
        foreach (var value in Enum.GetValues<T>())
        {
            array.Add(Name(value));
        }

        return array;
    }

    public static string Name<T>(T value) where T : struct, Enum
    {
        var field = typeof(T).GetField(value.ToString());
        return field?.GetCustomAttribute<JsonStringEnumMemberNameAttribute>()?.Name ?? JsonSerializer.Serialize(value, ProjectJson.Options).Trim('"');
    }

    public static T? Parse<T>(string? text) where T : struct, Enum
    {
        foreach (var value in Enum.GetValues<T>())
        {
            if (string.Equals(Name(value), text, StringComparison.Ordinal))
            {
                return value;
            }
        }

        return null;
    }

    private static string FirstLine(string text)
    {
        var end = text.IndexOf(" Path:", StringComparison.Ordinal);
        return (end > 0 ? text[..end] : text).Trim();
    }
}
