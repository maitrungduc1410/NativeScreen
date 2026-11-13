using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

/// <summary>
/// The macOS `MotionRegressionChecks` (spec/06 ADR-86 to ADR-88) that need no GPU, with the same synthetic inputs and
/// thresholds: crop space, planned cursor accuracy, playback time, cuts, reused ranges, older recordings and auto zoom.
/// </summary>
public sealed class MotionRegressionTests
{
    private static readonly MotionPointSize Size = MotionPointSize.Reference;

    // Accepted tip error at clicks and drags: 0.75 x 2 points (ADR-87).
    private static readonly double AnchorBudget = 2 * 0.75 + 1e-6;

    private static readonly List<CursorSampleEvent> Stationary = [Sample(0, 0.7, 0.4), Sample(12000, 0.7, 0.4)];

    private static readonly List<CursorSampleEvent> Diagonal = [.. Enumerable.Range(0, 721).Select(i => Sample(i * 1000.0 / 120, 0.1 + i / 900.0, 0.3 + i / 1800.0))];

    private static readonly List<ClickEvent> DragClicks = [Click(1003.5, "down", 0.2338, 0.3669), Click(2309.1, "up", 0.4079, 0.45395)];

    private static bool Same(Point01 a, Point01 b) => a.X == b.X && a.Y == b.Y;

    private static CursorSampleEvent Sample(double t, double x, double y) => new() { T = t, X = x, Y = y };

    private static ClickEvent Click(double t, string type, double x, double y) => new() { T = t, Type = type, X = x, Y = y };

    private static ProjectDocument Document()
    {
        var document = new ProjectDocument { Name = "Motion checks" };
        document.Timeline.Slices = [new ClipSlice { Id = "s", SourceStartMs = 0, SourceEndMs = 12000 }];
        document.Cursor.StopMovementInLastPartMs = 0;
        document.Camera.Enabled = false;
        return document;
    }

    private static PlaybackTrajectorySolver Solver(ProjectDocument document, IReadOnlyList<CursorSampleEvent> cursor, IReadOnlyList<ClickEvent>? clicks = null, MotionPointSize? pointSize = null) =>
        new(12000, cursor, clicks ?? [], document, pointSize ?? Size);

    [Fact]
    public void CropMovesTargetsIntoCropSpaceButKeepsTelemetry()
    {
        var document = Document();
        document.Canvas.CropRect01 = new Rect01(0.25, 0.2, 0.5, 0.6);
        document.Timeline.Zooms = [new ZoomBlock { Id = "z", SourceStartMs = 500, SourceEndMs = 4000, Scale = 2, Mode = ZoomMode.Manual, ManualCenter01 = new Point01(0.5, 0.4), InstantAnimation = true }];
        var cropped = Solver(document, Stationary).EvaluateAtTimeline(1000);
        Assert.True(Math.Abs(cropped.Cursor.Position01.X - 0.7) < 1e-9, "crop keeps original cursor coordinates");
        Assert.True(Math.Abs(MotionGeometry.Cropped(cropped.Cursor.Position01, document.Canvas.CropRect01).X - 0.9) < 1e-9, "crop remaps drawn cursor to 0.9");
        Assert.True(Math.Abs(cropped.Camera.Center01.Y - 1.0 / 3.0) < 1e-9, "crop remaps manual focus");
        Assert.True(MotionGeometry.Cropped(new Point01(0.1, 0.1), document.Canvas.CropRect01).X < 0, "crop preserves outside coordinates");

        document.Timeline.Zooms[0].Presentation = ZoomPresentation.Loupe;
        document.Timeline.Zooms[0].ManualCenter01 = new Point01(0.7, 0.4);
        Assert.True(Math.Abs(Solver(document, Stationary).EvaluateAtTimeline(1000).Camera.LoupeCenter01.X - 0.9) < 1e-9, "crop remaps independent loupe focus");
        document.Timeline.IsZoomTrackHidden = true;
        var hidden = Solver(document, Stationary).EvaluateAtTimeline(1000).Camera;
        Assert.True(hidden.Scale == 1 && hidden.LoupePresence01 == 0, "hidden zoom track disables screen and lens");
    }

    [Fact]
    public void PlannedCursorMeetsClicksAndDragsWithinTolerance()
    {
        var document = Document();
        document.Cursor.RemoveShakeThresholdPx = 8;
        var interaction = Solver(document, Diagonal, DragClicks);
        foreach (var click in DragClicks)
        {
            var tip = interaction.EvaluateAtTimeline(click.T).Cursor.Position01;
            Assert.True(Size.Distance(tip, new Point01(click.X, click.Y)) <= AnchorBudget, $"tip reaches {click.Type} within planner tolerance at fractional timestamp");
        }

        var worst = 0.0;
        for (var t = 1020.3; t <= 2290.0; t += 7.13)
        {
            var raw = CursorTelemetry.Sample(Diagonal, t);
            worst = Math.Max(worst, Size.Distance(interaction.EvaluateAtTimeline(t).Cursor.Position01, new Point01(raw.X, raw.Y)));
        }

        Assert.True(worst <= AnchorBudget, $"drag error within planner tolerance ({worst:0.###} pt)");
        var wave = interaction.EvaluateAtTimeline(1100).Cursor.ClickWaves[^1];
        Assert.True(wave.Position01.X == DragClicks[0].X && wave.Position01.Y == DragClicks[0].Y, "click wave stays on down anchor");

        document.Cursor.SmoothMovementEnabled = false;
        document.Cursor.RemoveShakeThresholdPx = 0;
        Assert.True(Math.Abs(Solver(document, Diagonal).EvaluateAtTimeline(1500).Cursor.Position01.X - 0.3) < 1e-9, "disabled smoothing keeps raw position");
        document.Timeline.Slices[0].Speed = 0.25;
        List<CursorSampleEvent> sixtyHz = [.. Enumerable.Range(0, 61).Select(i => Sample(i * 1000.0 / 60, 0.2 + i / 300.0, 0.5))];
        Assert.True(Math.Abs(Solver(document, sixtyHz).EvaluateAtTimeline(501).Cursor.Position01.X - (0.2 + 125.25 / 5000)) < 1e-9, "slow 60 Hz footage does not become stationary holds");
    }

    [Fact]
    public void ShakeAndHeadingUseCapturePoints()
    {
        var document = Document();
        document.Cursor.SmoothMovementEnabled = false;
        document.Cursor.RemoveShakeThresholdPx = 4;
        List<CursorSampleEvent> smallMove = [Sample(0, 0.5, 0.5), Sample(100, 0.503, 0.5)];
        Assert.Equal(0.5, Solver(document, smallMove, pointSize: new MotionPointSize(800, 600)).EvaluateAtTimeline(500).Cursor.Position01.X);
        Assert.Equal(0.503, Solver(document, smallMove, pointSize: new MotionPointSize(3200, 1800)).EvaluateAtTimeline(500).Cursor.Position01.X);

        document.Cursor.RemoveShakeThresholdPx = 0;
        document.Cursor.RotationMode = CursorRotationMode.Follow;
        document.Cursor.VelocityRotationEnabled = true;
        List<CursorSampleEvent> diagonal = [.. Enumerable.Range(0, 241).Select(i => Sample(i * 1000.0 / 120, 0.2 + i / 1200.0, 0.2 + i / 1200.0))];
        var bearing = Solver(document, diagonal, pointSize: new MotionPointSize(1600, 800)).EvaluateAtTimeline(1200).Cursor.RotationRadians;
        var expected = -Math.Atan(0.5) - Math.PI * 0.75 - document.Cursor.BaseRotationDegrees * Math.PI / 180;
        Assert.True(Math.Abs(bearing - expected) < 0.001, $"follow heading uses physical aspect ratio ({bearing} vs {expected})");
    }

    [Fact]
    public void MotionRunsOnPlaybackTimeAndRespectsCuts()
    {
        var one = Document();
        one.Timeline.Zooms = [new ZoomBlock { Id = "z", SourceStartMs = 1000, SourceEndMs = 3000, Scale = 2, Mode = ZoomMode.Manual }];
        var two = ProjectJson.Clone(one);
        two.Timeline.Slices[0].Speed = 2;
        Assert.True(Math.Abs(Solver(one, Stationary).EvaluateAtTimeline(1300).Camera.Scale - Solver(two, Stationary).EvaluateAtTimeline(800).Camera.Scale) < 1e-9, "zoom spring response uses playback milliseconds");
        var late = Solver(one, Stationary).EvaluateAtTimeline(2999).Camera.Scale;
        var after = Solver(one, Stationary).EvaluateAtTimeline(3200).Camera.Scale;
        Assert.True(late > 1.99 && after < late && after > 1, "zoom exit starts after item end");

        var cutDocument = Document();
        cutDocument.Timeline.Slices = [new ClipSlice { Id = "a", SourceStartMs = 0, SourceEndMs = 1003.5 }, new ClipSlice { Id = "b", SourceStartMs = 6000, SourceEndMs = 9000 }];
        cutDocument.Timeline.Zooms = [new ZoomBlock { Id = "z", SourceStartMs = 5000, SourceEndMs = 8000, Scale = 3, Mode = ZoomMode.Manual, ManualCenter01 = new Point01(0.7, 0.3) }];
        List<CursorSampleEvent> cutCursor = [Sample(0, 0.1, 0.2), Sample(5999, 0.8, 0.6), Sample(12000, 0.8, 0.6)];
        var cut = Solver(cutDocument, cutCursor);
        var cutState = cut.EvaluateAtTimeline(1003.5);
        Assert.True(cutState.Cursor.Position01.X == 0.8, "cut resets cursor without interpolation across boundary");
        Assert.True(cutState.Camera.Scale == 3, "cut initializes active zoom without discarded history");
        Assert.Equal(6000, new NLETimeMapper(cutDocument.Timeline.Slices).SourceTime(1003.5).SourceMs);
        Assert.False(cut.IsSameRun(1003.5, 1000), "motion blur cannot cross a cut");

        cutDocument.Timeline.Slices = [new ClipSlice { Id = "a", SourceStartMs = 0, SourceEndMs = 3000 }, new ClipSlice { Id = "b", SourceStartMs = 3000, SourceEndMs = 6000, Speed = 2 }];
        Assert.True(Solver(cutDocument, Diagonal).IsSameRun(3001, 2999), "source-contiguous speed changes share motion history");
        cutDocument.Timeline.Slices = [new ClipSlice { Id = "a", SourceStartMs = 0, SourceEndMs = 1000 }, new ClipSlice { Id = "b", SourceStartMs = 0, SourceEndMs = 1000, HideCursor = true }];
        Assert.False(Solver(cutDocument, Diagonal).IsSameRun(1100, 100), "reused source ranges get separate trajectories");
        Assert.Equal(2000, new NLETimeMapper(cutDocument.Timeline.Slices).TimelineTime(1000, 2000));

        var held = Document();
        held.Timeline.Slices = [new ClipSlice { Id = "h", SourceStartMs = 1500, SourceEndMs = 3000 }];
        var heldCursor = Solver(held, Diagonal, DragClicks).EvaluateAtTimeline(30.5).Cursor;
        var heldRaw = CursorTelemetry.Sample(Diagonal, 1530.5);
        Assert.True(Size.Distance(heldCursor.Position01, new Point01(heldRaw.X, heldRaw.Y)) <= AnchorBudget, "drag held through trim stays within planner tolerance");
        Assert.True(heldCursor.ClickWaves.Length == 0, "trimmed drag does not synthesize a click ripple");
    }

    [Fact]
    public void OlderRecordingsMoveOntoTheVideoClock()
    {
        Assert.Equal(0, LegacyTelemetryEpoch.OffsetMs([Sample(0, 0.5, 0.5), Sample(12000, 0.5, 0.5)], [], [], 11990));
        List<CursorSampleEvent> legacyCursor = [Sample(1319, 0.2, 0.2), Sample(1400, 0.3, 0.2), Sample(13079, 0.4, 0.4)];
        List<ClickEvent> legacyClicks = [Click(1200, "down", 0.2, 0.2), Click(6137, "down", 0.3, 0.2)];
        var offset = LegacyTelemetryEpoch.OffsetMs(legacyCursor, legacyClicks, [], 11803);
        Assert.True(Math.Abs(offset - 1276) < 1e-9, "legacy telemetry offset is how far events run past the video");
        var corrected = LegacyTelemetryEpoch.Corrected(legacyCursor, legacyClicks, [], offset);
        Assert.True(corrected.Clicks.Count == 1 && Math.Abs(corrected.Clicks[0].T - 4861) < 1e-9, "legacy correction drops events from before capture");
        Assert.True(corrected.Cursor.Count == 3 && Math.Abs(corrected.Cursor[0].T - 43) < 1e-9, "legacy correction keeps every cursor sample on the video clock");
        Assert.Equal(1319, legacyCursor[0].T);

        var far = CursorTelemetry.InsertingClicks([Click(50, "down", 0.9, 0.9)], [Sample(0, 0.1, 0.1), Sample(100, 0.1, 0.1)], holdPauses: false, Size);
        Assert.True(far.All(e => e.X == 0.1), "a click far from the recorded cursor does not move the path");
        var warp = CursorTelemetry.InsertingClicks([Click(50, "up", 0.1, 0.1)], [Sample(45, 0.1, 0.1), Sample(57, 0.6, 0.6)], holdPauses: false, Size);
        Assert.Contains(warp, e => e.T == 50 && e.X == 0.1);
    }

    [Theory]
    [InlineData(true, 0.0)]
    [InlineData(false, 0.0)]
    [InlineData(true, 80.0)]
    public void AFlickEndingOnAClickArrivesOnTimeAndKeepsTheGlide(bool syncHovers, double gap)
    {
        static double Ease(double u) => u * u * (3 - 2 * u);
        List<CursorSampleEvent> flick = [.. Enumerable.Range(0, 481).Select(i =>
        {
            var t = i * 1000.0 / 120;
            var u = Math.Clamp((t - 500) / 150, 0, 1);
            return Sample(t, 0.2 + 0.5 * Ease(u), 0.3 + 0.2 * Ease(u));
        })];
        var document = Document();
        document.Cursor.RemoveShakeThresholdPx = 0;
        document.Cursor.KeepInSyncWithHovers = syncHovers;
        var clickMs = 650 + gap;
        var solver = Solver(document, flick, [Click(clickMs, "down", 0.7, 0.5), Click(clickMs + 80, "up", 0.7, 0.5)]);
        Assert.True(Size.Distance(solver.EvaluateAtTimeline(clickMs).Cursor.Position01, new Point01(0.7, 0.5)) <= AnchorBudget, "tip reaches the click");
        var previous = solver.EvaluateAtTimeline(0).Cursor.Position01;
        var previousRaw = CursorTelemetry.Sample(flick, 0);
        double previousSpeed = 0, worstJump = 0, peak = 0, rawPeak = 0;
        for (var frame = 1; frame <= 150; frame++)
        {
            var t = frame * 1000.0 / 60;
            var p = solver.EvaluateAtTimeline(t).Cursor.Position01;
            var raw = CursorTelemetry.Sample(flick, t);
            var speed = Size.Distance(p, previous) / (1000.0 / 60);
            if (frame > 1)
            {
                worstJump = Math.Max(worstJump, Math.Abs(speed - previousSpeed));
            }

            peak = Math.Max(peak, speed);
            rawPeak = Math.Max(rawPeak, Size.Distance(raw.X, raw.Y, previousRaw.X, previousRaw.Y) / (1000.0 / 60));
            previous = p;
            previousSpeed = speed;
            previousRaw = raw;
        }

        Assert.True(worstJump < 0.25 * rawPeak, $"no frame-to-frame speed jump ({worstJump} vs {rawPeak})");
        Assert.True(peak < 0.75 * rawPeak, $"keeps the spring glide ({peak} vs {rawPeak})");
    }

    [Fact]
    public void LoupeHasItsOwnCenterAndPrewarmsWhileInvisible()
    {
        var document = Document();
        document.Timeline.Zooms = [new ZoomBlock { Id = "l", SourceStartMs = 0, SourceEndMs = 4000, Scale = 2.4, Mode = ZoomMode.FollowCursor, Presentation = ZoomPresentation.Loupe, InstantAnimation = true }];
        List<CursorSampleEvent> jitter = [.. Enumerable.Range(0, 241).Select(i => Sample(i * 1000.0 / 120, 0.5 + Math.Sin(i * 0.15) * 0.02, 0.5))];
        var loupe = Solver(document, jitter);
        var centers = new List<double>();
        for (var t = 500.0; t <= 1800; t += 20)
        {
            centers.Add(loupe.EvaluateAtTimeline(t).Camera.LoupeCenter01.X);
        }

        Assert.True(centers.Max() - centers.Min() < 0.006, "loupe holds grouped focus with decorative drift only");
        var independent = loupe.EvaluateAtTimeline(1000).Camera;
        Assert.True(Same(independent.Center01, Point01.Center) && !Same(independent.LoupeCenter01, Point01.Center), "loupe and screen camera have independent centers");

        document.Timeline.Zooms =
        [
            new ZoomBlock { Id = "s", SourceStartMs = 0, SourceEndMs = 2000, Scale = 3, Mode = ZoomMode.Manual, ManualCenter01 = new Point01(0.7, 0.4) },
            new ZoomBlock { Id = "l", SourceStartMs = 2000, SourceEndMs = 4000, Scale = 2.4, Mode = ZoomMode.Manual, Presentation = ZoomPresentation.Loupe, ManualCenter01 = new Point01(0.2, 0.6) }
        ];
        var transition = Solver(document, Stationary);
        var before = transition.EvaluateAtTimeline(1999).Camera;
        var inside = transition.EvaluateAtTimeline(2001).Camera;
        Assert.True(inside.Scale > 2.9 && Math.Abs(inside.Center01.X - before.Center01.X) < 0.01, "screen to loupe does not snap screen camera");
        Assert.True(before.LoupePresence01 <= 0.005 && Math.Abs(before.LoupeCenter01.X - 0.2) < 0.05, "invisible loupe prewarms during preceding screen zoom");
    }

    [Fact]
    public void AutoZoomMergesGapsUnderTwoAndAHalfSeconds()
    {
        var merged = AutoZoomClusterGenerator.GenerateZooms([Click(1000, "down", 0.2, 0.3), Click(6000, "down", 0.8, 0.7)], [], 12000);
        Assert.True(merged.Count == 1 && merged[0].SourceStartMs == 700 && merged[0].SourceEndMs == 8500, "nearby auto zoom intervals merge");
        Assert.Equal(2, AutoZoomClusterGenerator.GenerateZooms([Click(1000, "down", 0.2, 0.3), Click(6300, "down", 0.8, 0.7)], [], 12000).Count);
        var typing = AutoZoomClusterGenerator.GenerateZooms([Click(1000, "down", 0.2, 0.3)], [new KeyStrokeEvent { T = 4000, Kind = "typing" }, new KeyStrokeEvent { T = 6000, Kind = "typing" }], 12000);
        Assert.True(typing.Count == 1 && typing[0].SourceEndMs == 7500, "auto zoom retains chained typing hold");
    }
}
