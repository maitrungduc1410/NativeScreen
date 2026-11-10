using System.Text.Json;

namespace NativeScreen.Core;

public sealed class PauseTimeline
{
    private readonly List<(double Start, double? End)> intervals = [];

    public void SetPaused(bool paused, double hostMs)
    {
        var isPaused = intervals.Count > 0 && intervals[^1].End is null;
        if (isPaused == paused)
        {
            return;
        }

        if (paused)
        {
            intervals.Add((hostMs, null));
        }
        else
        {
            var open = intervals[^1];
            intervals[^1] = (open.Start, hostMs);
        }
    }

    public double? OffsetMs(double hostMs)
    {
        var offset = 0.0;
        foreach (var interval in intervals)
        {
            if (hostMs < interval.Start)
            {
                break;
            }

            if (interval.End is not double end || hostMs < end)
            {
                return null;
            }

            offset += end - interval.Start;
        }

        return offset;
    }
}

public static class RecordingRates
{
    public static int Even(int pixels) => Math.Max(2, pixels & ~1);

    public static int DisplayBitrate(int width, int height)
    {
        var w = Even(width);
        var h = Even(height);
        return Math.Max(8_000_000, w * h * 4);
    }

    public static int WebcamBitrate(int width, int height) => Math.Max(10_000_000, Even(width) * Even(height) * 5);
}

public static class CursorKindMap
{
    public static string FromWindowsCursor(string systemCursor) => systemCursor switch
    {
        "IDC_HAND" => "pointingHand",
        "IDC_IBEAM" => "iBeam",
        "IDC_CROSS" => "crosshair",
        "IDC_SIZEALL" => "openHand",
        _ => "arrow"
    };
}

public static class CaptureCoordinates
{
    public static Point01 Normalize(double x, double y, double originX, double originY, double width, double height) =>
        new((x - originX) / Math.Max(1, width), (y - originY) / Math.Max(1, height));
}

public static class RecordingLayout
{
    public const string DisplayVideo = "recording/display.mp4";
    public const string WebcamVideo = "recording/webcam.mp4";
    public const string MicrophoneAudio = "recording/microphone.m4a";
    public const string CursorTelemetry = "recording/telemetry/cursor.jsonl";
    public const string ClicksTelemetry = "recording/telemetry/clicks.jsonl";
    public const string KeysTelemetry = "recording/telemetry/keys.jsonl";
    public const string WindowTelemetry = "recording/telemetry/window.jsonl";
}

public static class TelemetryLog
{
    public static void Append<T>(string path, T value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.AppendAllText(path, JsonSerializer.Serialize(value, ProjectJson.Compact) + "\n");
    }
}
