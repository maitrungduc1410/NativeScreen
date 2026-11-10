using System.Text.Json;
using System.Text.Json.Serialization;

namespace NativeScreen.Core;

public sealed class LogicalBounds
{
    public double X { get; set; }
    public double Y { get; set; }
    public double Width { get; set; }
    public double Height { get; set; }
}

public sealed class PixelDimensions
{
    public int Width { get; set; }
    public int Height { get; set; }
}

public sealed class CaptureTargetMetadata
{
    [JsonConverter(typeof(CaptureTargetModeConverter))]
    public CaptureTargetMode Mode { get; set; } = CaptureTargetMode.Display;
    public long DisplayId { get; set; }
    public long? WindowId { get; set; }
    public string? AppBundleId { get; set; }
    public string? AppName { get; set; }
    public string? WindowTitle { get; set; }
    public LogicalBounds LogicalBounds { get; set; } = new();
    public PixelDimensions PixelSize { get; set; } = new();
    public double ScaleFactor { get; set; } = 2;
    public double RefreshRate { get; set; } = 60;
    public double WindowBorderRadius { get; set; } = 16;

    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Extra { get; set; }
}

public sealed class RecordingTracksMetadata
{
    public string DisplayVideo { get; set; } = "display.mp4";
    public string? WebcamVideo { get; set; }
    public string? MicrophoneAudio { get; set; }
    public string? SystemAudio { get; set; }
    public string CursorTelemetry { get; set; } = "telemetry/cursor.jsonl";
    public string ClicksTelemetry { get; set; } = "telemetry/clicks.jsonl";
    public string KeysTelemetry { get; set; } = "telemetry/keys.jsonl";
    public string? WindowTelemetry { get; set; } = "telemetry/window.jsonl";

    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Extra { get; set; }
}

public sealed class RecordingMetadata
{
    public string FormatVersion { get; set; } = "1.0.0";
    public string AppVersion { get; set; } = "1.0.0";
    public string Platform { get; set; } = "macos";
    public string CreatedAt { get; set; } = "";
    public double DurationMs { get; set; }
    public CaptureTargetMetadata CaptureTarget { get; set; } = new();
    public RecordingTracksMetadata Tracks { get; set; } = new();

    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Extra { get; set; }
}

public sealed class CursorSampleEvent
{
    public double T { get; set; }
    public double X { get; set; }
    public double Y { get; set; }
    public string C { get; set; } = "arrow";
}

public sealed class ClickEvent
{
    public double T { get; set; }
    public string Type { get; set; } = "";
    public string? Button { get; set; }
    public double X { get; set; }
    public double Y { get; set; }
    public int? Count { get; set; }
    public double? Dx { get; set; }
    public double? Dy { get; set; }
}

public sealed class KeyStrokeEvent
{
    public double T { get; set; }
    public string Kind { get; set; } = "";
    public List<string>? Modifiers { get; set; }
    public string? Key { get; set; }
    public string? Label { get; set; }
}

public static class JsonLines
{
    public static List<T> Load<T>(string path)
    {
        if (!File.Exists(path))
        {
            return [];
        }

        var results = new List<T>();
        foreach (var line in File.ReadLines(path))
        {
            var trimmed = line.Trim();
            if (trimmed.Length == 0)
            {
                continue;
            }

            var item = JsonSerializer.Deserialize<T>(trimmed, ProjectJson.Options);
            if (item is not null)
            {
                results.Add(item);
            }
        }

        return results;
    }
}
