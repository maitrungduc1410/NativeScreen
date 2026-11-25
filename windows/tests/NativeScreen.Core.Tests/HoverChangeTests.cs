using NativeScreen.Core;
using Xunit.Abstractions;

namespace NativeScreen.Core.Tests;

/// <summary>
/// The macOS hover checks in <c>MotionRegressionChecks</c> (spec/06 ADR-108), same synthetic frames and thresholds: a menu
/// item lighting up under the cursor is found on the frame it shows, content scrolling under the cursor and a click's own
/// effect are not, and the planned tip is on the highlight when it shows.
/// </summary>
public sealed class HoverChangeTests(ITestOutputHelper output)
{
    private static readonly MotionPointSize Points = new(400, 300);

    // Hover tolerance (4 pt) x accepted error ratio (0.75), plus half a point, as on macOS.
    private const double HoverTolerance = 4;
    private const double HoverBudget = HoverTolerance * 0.75 + 0.5;

    private static readonly List<CursorSampleEvent> Sweep =
        [.. Enumerable.Range(0, 151).Select(i => i * 8.0).Select(t => new CursorSampleEvent { T = t, X = (100 + 0.2 * t) / 400, Y = 0.5 })];

    /// <summary>An NV12 frame at 800x600 pixels for 400x300 points, resampled like a recording.</summary>
    private static HoverChangeDetector.Frame Frame(double t, Func<int, int, byte> luma, Func<int, int, byte>? cb = null)
    {
        const int width = 800, height = 600;
        var nv12 = new byte[width * height * 3 / 2];
        for (var py = 0; py < height; py++)
        {
            for (var px = 0; px < width; px++)
            {
                nv12[py * width + px] = luma(px / 2, py / 2);
            }
        }

        for (var cy = 0; cy < height / 2; cy++)
        {
            for (var cx = 0; cx < width / 2; cx++)
            {
                nv12[width * height + cy * width + cx * 2] = cb?.Invoke(cx, cy) ?? 128;
                nv12[width * height + cy * width + cx * 2 + 1] = 128;
            }
        }

        return HoverChangeDetector.Frame.FromNv12(nv12, width, height, t, Points);
    }

    private static Func<int, int, byte> Band(double t) => (x, y) => t >= 400 && x >= 170 && x <= 330 && y >= 138 && y <= 162 ? (byte)120 : (byte)60;

    private static Func<int, int, byte> Scrolling(double t) => (_, y) => (y + (int)(t * 0.12)) / 6 % 2 == 0 ? (byte)40 : (byte)160;

    private static List<double> Detect(List<ClickEvent> clicks, Func<double, Func<int, int, byte>> luma)
    {
        var detector = new HoverChangeDetector.Detector(new HoverChangeDetector.CursorPath(Sweep, clicks, Points));
        var found = new List<double>();
        for (var i = 0; i <= 60; i++)
        {
            var t = i * 1000.0 / 60;
            if (detector.Add(Frame(t, luma(t))) is double change)
            {
                found.Add(change);
            }
        }

        return found;
    }

    [Fact]
    public void AHighlightUnderTheCursorIsFoundOnTheFrameItShows()
    {
        var highlight = Detect([], Band);
        // Frames until the reference catches up (120 ms) still show the change, so it is found again 50 ms apart.
        Assert.NotEmpty(highlight);
        Assert.InRange(highlight[0], 400, 417);
        Assert.All(highlight, t => Assert.True(t <= 400 + 120));
    }

    [Fact]
    public void AHighlightFromAClickIsNotAHover() =>
        Assert.Empty(Detect([new ClickEvent { T = 450, Type = "down", X = 0.45, Y = 0.5 }], Band));

    [Fact]
    public void ContentScrollingUnderTheCursorIsNotAHover()
    {
        List<ClickEvent> wheel = [.. Enumerable.Range(0, 63).Select(i => new ClickEvent { T = i * 16.0, Type = "scroll", X = 0.5, Y = 0.5 })];
        Assert.Empty(Detect(wheel, Scrolling));
    }

    [Fact]
    public void EveryRowAMenuSweepLightsIsFound()
    {
        // Sweeping down a menu: the highlight steps one 22 pt row at a time. Each step is a change, though the old row is just
        // above the cursor and a one-row shift of the picture would line the highlight up.
        List<CursorSampleEvent> menuSweep = [.. Enumerable.Range(0, 151).Select(i => i * 8.0).Select(t => new CursorSampleEvent { T = t, X = 0.5, Y = (60 + 0.25 * Math.Max(0, Math.Min(t - 300, 900))) / 300 })];
        static int MenuRow(double t) => (int)((60 + 0.25 * Math.Max(0, Math.Min(t - 300, 900)) - 50) / 22);
        var detector = new HoverChangeDetector.Detector(new HoverChangeDetector.CursorPath(menuSweep, [], Points));
        var found = new List<double>();
        var rowEntries = new List<double>();
        for (var i = 0; i <= 90; i++)
        {
            var t = i * 1000.0 / 60;
            if (i > 0 && MenuRow(t) != MenuRow((i - 1) * 1000.0 / 60))
            {
                rowEntries.Add(t);
            }

            var lit = MenuRow(t);
            var frame = Frame(t, (x, y) =>
            {
                var row = (y - 50) / 22;
                var text = x > 150 && x < 150 + 20 + row * 9 && (y - 50) % 22 > 7 && (y - 50) % 22 < 15 && x % 3 == 0;
                return y >= 50 && row == lit && x > 100 && x < 300 ? (byte)(text ? 230 : 120) : (byte)(text ? 200 : 60);
            });
            if (detector.Add(frame) is double change)
            {
                found.Add(change);
            }
        }

        var caught = rowEntries.Count(entry => found.Any(t => t >= entry && t <= entry + 17));
        output.WriteLine($"menu sweep: {caught} of {rowEntries.Count} row changes found");
        Assert.True(rowEntries.Count >= 8 && caught == rowEntries.Count, $"menu sweep: {caught} of {rowEntries.Count}");
    }

    [Fact]
    public void ScrollingExplainsAShiftedPictureButNotAHighlight()
    {
        var probe = new HoverChangeDetector.Detector(new HoverChangeDetector.CursorPath(Sweep, [], Points));
        Assert.True(probe.IsExplainedByScrolling(Frame(0, Scrolling(0)), Frame(120, Scrolling(120)), 200, 150), "scrolling explains a shifted picture");
        Assert.False(probe.IsExplainedByScrolling(Frame(300, Band(300)), Frame(420, Band(420)), 184, 150), "scrolling does not explain a highlight");
    }

    [Fact]
    public void TheTipIsOnTheHighlightWhenItShows()
    {
        var highlight = Detect([], Band);
        var document = new ProjectDocument { Name = "Hover checks" };
        document.Timeline.Slices = [new ClipSlice { Id = "s", SourceStartMs = 0, SourceEndMs = 12000 }];
        document.Cursor.StopMovementInLastPartMs = 0;
        document.Cursor.RemoveShakeThresholdPx = 0;
        document.Cursor.KeepInSyncWithHovers = true;
        document.Camera.Enabled = false;
        var at = highlight.Count > 0 ? highlight[0] : 400;
        double Error(IReadOnlyList<double> hovers) => Points.Distance(
            new PlaybackTrajectorySolver(12000, Sweep, [], document, Points, hoverChangeTimesMs: hovers).EvaluateAtTimeline(at).Cursor.Position01,
            new Point01(180 / 400.0, 0.5));
        var synced = Error(highlight);
        var unsynced = Error([]);
        output.WriteLine($"hover tip error: synced {synced} pt, unsynced {unsynced} pt");
        Assert.True(synced <= HoverBudget, $"synced {synced} pt");
        Assert.True(unsynced > HoverTolerance, $"unsynced {unsynced} pt");
    }

    [Fact]
    public void AMacFileLoadsAsIs()
    {
        var stored = System.Text.Json.JsonSerializer.Deserialize<HoverChangeDetector.Stored>("""{"version":2,"videoDurationMs":5000,"changeTimesMs":[400.5,1200]}""");
        Assert.NotNull(stored);
        Assert.Equal(HoverChangeDetector.CurrentVersion, stored.Version);
        Assert.Equal([400.5, 1200], stored.ChangeTimesMs);
        Assert.Contains("\"changeTimesMs\"", System.Text.Json.JsonSerializer.Serialize(stored));
    }
}
