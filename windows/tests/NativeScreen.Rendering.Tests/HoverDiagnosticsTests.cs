using System.Globalization;
using NativeScreen.Core;
using NativeScreen.Media;
using Xunit.Abstractions;

namespace NativeScreen.Rendering.Tests;

/// <summary>
/// NS_TEST_HOVER_WHY=&lt;package&gt;;&lt;fromMs&gt;;&lt;toMs&gt; prints, for every frame in that range, what the hover detector saw
/// (spec/06 ADR-108): movement, click, the probe against the reference frame and the settled test. Reads only.
/// </summary>
public sealed class HoverDiagnosticsTests(ITestOutputHelper output)
{
    [Fact]
    public void ExplainsEachFrame()
    {
        if (Environment.GetEnvironmentVariable("NS_TEST_HOVER_WHY") is not { Length: > 0 } spec)
        {
            return;
        }

        var parts = spec.Split(';');
        var package = parts[0];
        var from = double.Parse(parts[1], CultureInfo.InvariantCulture);
        var to = double.Parse(parts[2], CultureInfo.InvariantCulture);
        var project = new LoadedProject(package);
        var s = HoverChangeDetector.Settings.Standard;
        var clicks = CursorTelemetry.WithoutDrawing(project.ClickEvents);
        var path = new HoverChangeDetector.CursorPath(project.CursorEvents, clicks, project.PointSize);
        var probe = new HoverChangeDetector.Detector(path, s);
        var detector = new HoverChangeDetector.Detector(path, s);
        var history = new List<HoverChangeDetector.Frame>();
        using var reader = StagedVideoReader.TryOpen(Path.Combine(package, "recording", project.Metadata.Tracks.DisplayVideo))!;
        var pool = new VideoFramePool();
        foreach (var raw in reader.Read(pool, t => t >= from - 1500 && t <= to))
        {
            if (raw.Nv12.Length == 0)
            {
                continue;
            }

            var frame = HoverChangeDetector.Frame.FromNv12(raw.Nv12, raw.Width, raw.Height, raw.PresentationMs, project.PointSize);
            pool.Return(raw.Nv12);
            var t = frame.TimeMs;
            var found = t >= from ? detector.Add(frame) : null;
            if (t < from)
            {
                detector.Remember(frame);
            }

            history.Add(frame);
            if (history.Count > 60)
            {
                history.RemoveAt(0);
            }

            if (t < from)
            {
                continue;
            }

            var move = path.FreeMovementPt(t, s.MovementWindowMs);
            var click = path.HasClick(t - s.ClickExclusionBeforeMs, t + s.ClickExclusionAfterMs);
            var cursor = path.Position(t) ?? (0, 0);
            var cx = (int)Math.Round(cursor.X, MidpointRounding.AwayFromZero);
            var cy = (int)Math.Round(cursor.Y, MidpointRounding.AwayFromZero);
            var reference = history.LastOrDefault(f => f.TimeMs <= t - s.ReferenceLagMs);
            var settled = reference is null ? null : history.LastOrDefault(f => f.TimeMs <= reference.TimeMs - s.SettledForMs);
            var line = string.Create(CultureInfo.InvariantCulture, $"{t,8:F1} move {move,5:F1} click {(click ? 1 : 0)} at ({cx},{cy})");
            if (reference is not null && probe.Compare(reference, frame, cx, cy) is { } p)
            {
                line += string.Create(CultureInfo.InvariantCulture, $" ref {t - reference.TimeMs,4:F0} changed {p.ChangedFraction:F2} coherent {p.CoherentFraction:F2} q[{string.Join(" ", p.QuarterCoherentFractions.Select(q => q.ToString("F2", CultureInfo.InvariantCulture)))}]");
                if (settled is not null && settled.TimeMs != reference.TimeMs && probe.Compare(settled, reference, cx, cy) is { } before)
                {
                    line += string.Create(CultureInfo.InvariantCulture, $" before[{string.Join(" ", before.QuarterChangedFractions.Select(q => q.ToString("F2", CultureInfo.InvariantCulture)))}] all {before.ChangedFraction:F2}");
                }
            }
            else
            {
                line += " no reference";
            }

            output.WriteLine(line + (found is not null ? "  <== FOUND" : ""));
        }
    }
}
