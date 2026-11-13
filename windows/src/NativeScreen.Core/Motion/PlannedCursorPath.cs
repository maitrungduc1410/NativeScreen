namespace NativeScreen.Core;

/// <summary>The planned cursor (spec/06 ADR-87), sampled every playback millisecond, in capture points.</summary>
public sealed class PlannedCursorPath
{
    private readonly double startMs;
    private readonly float[] xs;
    private readonly float[] ys;

    internal PlannedCursorPath(double startMs, float[] xs, float[] ys)
    {
        this.startMs = startMs;
        this.xs = xs;
        this.ys = ys;
    }

    internal static PlannedCursorPath Simulate(CursorPathPlanner.Simulation simulation, CursorPathPlanner.LeadCurve lead, CursorPathPlanner.SpeedCurve speed, double durationMs)
    {
        var start = Math.Min(0, Math.Floor(simulation.Path.StartMs));
        var initial = simulation.Target(lead, start);
        var end = Math.Max(start, Math.Ceiling(durationMs));
        var xs = new List<float>((int)(end - start) + 1) { (float)initial.X };
        var ys = new List<float>((int)(end - start) + 1) { (float)initial.Y };
        simulation.Run(lead, speed, start, end, CursorPathPlanner.SpringState.Resting(initial), (_, x, y) =>
        {
            xs.Add((float)x);
            ys.Add((float)y);
        });
        return new PlannedCursorPath(start, [.. xs], [.. ys]);
    }

    /// <summary>The planned tip in points at <paramref name="t"/> ms, linear between whole milliseconds.</summary>
    public (double X, double Y) Position(double t)
    {
        var offset = t - startMs;
        if (offset <= 0)
        {
            return (xs[0], ys[0]);
        }

        var last = xs.Length - 1;
        if (offset >= last)
        {
            return (xs[last], ys[last]);
        }

        var i = (int)offset;
        var f = offset - i;
        return (xs[i] + (double)(xs[i + 1] - xs[i]) * f, ys[i] + (double)(ys[i + 1] - ys[i]) * f);
    }
}
