using System.Diagnostics;
using System.Globalization;
using NativeScreen.Core;
using NativeScreen.Intelligence;
using Xunit.Abstractions;

namespace NativeScreen.Rendering.Tests;

/// <summary>
/// NS_TEST_HOVER=&lt;.nativescreen package&gt; scans the project's screen video for hover highlights (spec/06 ADR-108) and reports
/// the times, how far the planned tip is from the recorded cursor at each one with and without sync, and the scan time. It
/// reads the package and writes nothing into it.
/// </summary>
public sealed class HoverScanTests(ITestOutputHelper output)
{
    [Fact]
    public void ScansARecordedProject()
    {
        if (Environment.GetEnvironmentVariable("NS_TEST_HOVER") is not { Length: > 0 } package)
        {
            return;
        }

        var project = new LoadedProject(package);
        var video = Path.Combine(package, "recording", project.Metadata.Tracks.DisplayVideo);
        var clicks = CursorTelemetry.WithoutDrawing(project.ClickEvents);
        if (Environment.GetEnvironmentVariable("NS_TEST_HOVER_PLAIN") == "1")
        {
            using var plain = new NativeScreen.Media.VideoFileReader(video);
            var plainPool = new VideoFramePool();
            IEnumerable<HoverChangeDetector.Nv12Frame> Plain(Func<double, bool> wanted)
            {
                while (plain.ReadNext(plainPool, wanted) is { } frame)
                {
                    yield return new HoverChangeDetector.Nv12Frame(frame.Nv12, frame.Width, frame.Height, frame.PresentationMs);
                }
            }

            var old = HoverChangeDetector.Scan(Plain, b => { if (b.Length > 0) plainPool.Return(b); }, plain.DurationMs, project.CursorEvents, clicks, project.PointSize, _ => true);
            output.WriteLine("plain reader times: " + string.Join(", ", old!.ChangeTimesMs.Select(t => t.ToString("F1", CultureInfo.InvariantCulture))));
        }

        var watch = Stopwatch.StartNew();
        var stored = HoverChangeScanner.Scan(video, project.CursorEvents, clicks, project.PointSize, null, CancellationToken.None);
        watch.Stop();
        Assert.NotNull(stored);
        output.WriteLine(string.Create(CultureInfo.InvariantCulture, $"scan {watch.Elapsed.TotalSeconds:F2} s, video {stored.VideoDurationMs:F0} ms, {stored.ChangeTimesMs.Count} highlights"));
        output.WriteLine("times: " + string.Join(", ", stored.ChangeTimesMs.Select(t => t.ToString("F1", CultureInfo.InvariantCulture))));

        var document = project.Document;
        document.Cursor.KeepInSyncWithHovers = true;
        var synced = new PlaybackTrajectorySolver(project.Metadata.DurationMs, project.CursorEvents, project.ClickEvents, document, project.PointSize, hoverChangeTimesMs: stored.ChangeTimesMs);
        var unsynced = new PlaybackTrajectorySolver(project.Metadata.DurationMs, project.CursorEvents, project.ClickEvents, document, project.PointSize);
        var mapper = new NLETimeMapper(document.Timeline.Slices);
        foreach (var t in stored.ChangeTimesMs)
        {
            if (mapper.TimelineTime(t) is not double timeline)
            {
                continue;
            }

            var recorded = CursorTelemetry.Sample(project.CursorEvents, t);
            var point = new Point01(recorded.X, recorded.Y);
            var a = project.PointSize.Distance(synced.EvaluateAtTimeline(timeline).Cursor.Position01, point);
            var b = project.PointSize.Distance(unsynced.EvaluateAtTimeline(timeline).Cursor.Position01, point);
            output.WriteLine(string.Create(CultureInfo.InvariantCulture, $"  {t,8:F1} ms  tip error synced {a,5:F1} pt, unsynced {b,5:F1} pt"));
        }
    }
}
