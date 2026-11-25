using System.Globalization;
using NativeScreen.Core;
using Xunit.Abstractions;

namespace NativeScreen.Rendering.Tests;

/// <summary>NS_TEST_HOVER_SHIFT=&lt;package&gt; scans with the telemetry moved earlier and later, to find how far the cursor clock is from the video's.</summary>
public sealed class HoverClockTests(ITestOutputHelper output)
{
    [Fact]
    public void FindsTheTelemetryOffset()
    {
        if (Environment.GetEnvironmentVariable("NS_TEST_HOVER_SHIFT") is not { Length: > 0 } package)
        {
            return;
        }

        var project = new LoadedProject(package);
        var video = Path.Combine(package, "recording", project.Metadata.Tracks.DisplayVideo);
        var clicks = CursorTelemetry.WithoutDrawing(project.ClickEvents);
        foreach (var shift in new[] { -400, -300, -250, -200, -150, -100, -50, 0, 50, 100 })
        {
            var cursor = project.CursorEvents.Select(e => new CursorSampleEvent { T = e.T + shift, X = e.X, Y = e.Y, C = e.C }).ToList();
            var moved = clicks.Select(c => new ClickEvent { T = c.T + shift, Type = c.Type, Button = c.Button, X = c.X, Y = c.Y, Count = c.Count, Dx = c.Dx, Dy = c.Dy }).ToList();
            var stored = NativeScreen.Intelligence.HoverChangeScanner.Scan(video, cursor, moved, project.PointSize, null, CancellationToken.None);
            output.WriteLine(string.Create(CultureInfo.InvariantCulture, $"telemetry {shift,5} ms: {stored.ChangeTimesMs.Count} highlights"));
        }
    }
}
