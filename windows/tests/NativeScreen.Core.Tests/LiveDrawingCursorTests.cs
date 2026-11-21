using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

/// <summary>While a stroke is drawn on the screen, the cursor in the video stays on the pen (spec/06 ADR-102).</summary>
public sealed class LiveDrawingCursorTests
{
    private const double DurationMs = 4000;

    [Fact]
    public void TheCursorStaysOnTheLineBeingDrawn()
    {
        // A quick stroke from left to right, then the pointer rests.
        var cursor = new List<CursorSampleEvent>();
        var points = new List<double[]>();
        for (var t = 0.0; t <= DurationMs; t += 16)
        {
            var progress = Math.Clamp((t - 1000) / 600, 0, 1);
            var x = 0.2 + 0.6 * progress;
            cursor.Add(new CursorSampleEvent { T = t, X = x, Y = 0.5, C = "arrow" });
            if (t >= 1000 && t <= 1600)
            {
                points.Add([x, 0.5, t - 1000]);
            }
        }

        LiveDrawingEvent[] drawings = [LiveDrawingEvent.Stroke(1000, LiveDrawingTool.Pen, "#FF3B30", points, 3000)];
        var clicks = CursorTelemetry.WithDrawingStrokes([], drawings);
        Assert.Equal([CursorTelemetry.DrawStart, CursorTelemetry.DrawEnd], clicks.Select(click => click.Type));

        var document = new ProjectDocument();
        var free = new PlaybackTrajectorySolver(DurationMs, cursor, [], document);
        var held = new PlaybackTrajectorySolver(DurationMs, cursor, clicks, document);
        var freeLag = points.Max(point => Math.Abs(free.EvaluateAtSource(1000 + point[2]).Cursor.Position01.X - point[0]));
        var heldLag = points.Max(point => Math.Abs(held.EvaluateAtSource(1000 + point[2]).Cursor.Position01.X - point[0]));

        // Without the stroke the spring trails the pen by a few percent of the width; with it, the cursor is on the line.
        Assert.True(freeLag > 0.02, $"free {freeLag}");
        Assert.True(heldLag < 0.005, $"held {heldLag}");
    }

    [Fact]
    public void DrawingNeitherPressesTheCursorNorMakesRipples()
    {
        var points = new List<double[]> { new[] { 0.3, 0.3, 0.0 }, new[] { 0.4, 0.4, 300.0 } };
        var clicks = CursorTelemetry.WithDrawingStrokes([], [LiveDrawingEvent.Stroke(500, LiveDrawingTool.Pen, "#FF3B30", points, null)]);
        Assert.Empty(SpringTrajectorySolver.ButtonPresses(clicks));
        Assert.DoesNotContain(clicks, click => click.Type == "down");
        Assert.Equal([(500.0, 800.0)], CursorTelemetry.HeldIntervals(clicks, DurationMs));
    }
}
