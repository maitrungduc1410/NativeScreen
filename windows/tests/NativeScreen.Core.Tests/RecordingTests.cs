using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class RecordingTests
{
    [Fact]
    public void PauseDropsSamplesInsideTheGapAndRewritesTheRest()
    {
        var pauses = new PauseTimeline();
        pauses.SetPaused(true, 1000);
        pauses.SetPaused(false, 1500);
        Assert.Null(pauses.OffsetMs(1200));
        Assert.Equal(500, pauses.OffsetMs(2000));
        Assert.Equal(0, pauses.OffsetMs(400));
    }

    [Fact]
    public void RecordingMathAndTelemetryRoundTrip()
    {
        Assert.Equal(8_000_000, RecordingRates.DisplayBitrate(100, 100));
        Assert.Equal(1920 * 1080 * 4, RecordingRates.DisplayBitrate(1920, 1080));
        Assert.Equal("pointer", CursorKindMap.FromWindowsCursor("IDC_HAND"));
        Assert.Equal("ibeam", CursorKindMap.FromWindowsCursor("IDC_IBEAM"));
        var point = CaptureCoordinates.Normalize(640, 360, 0, 0, 1280, 720);
        Assert.Equal(0.5, point.X, 6);
        Assert.Equal(0.5, point.Y, 6);

        var dir = Directory.CreateTempSubdirectory("nativescreen-telemetry");
        try
        {
            var path = Path.Combine(dir.FullName, RecordingLayout.CursorTelemetry);
            TelemetryLog.Append(path, new CursorSampleEvent { T = 10, X = 0.25, Y = 0.5, C = "arrow" });
            var loaded = JsonLines.Load<CursorSampleEvent>(path);
            Assert.Equal(10, loaded[0].T);
            Assert.Equal("arrow", loaded[0].C);
        }
        finally
        {
            dir.Delete(true);
        }
    }
}
