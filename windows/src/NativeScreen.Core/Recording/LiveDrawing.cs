using System.Text.Json.Serialization;

namespace NativeScreen.Core;

/// <summary>Drawing tools offered while recording (spec/02 §3.5, spec/06 ADR-79).</summary>
public enum LiveDrawingTool
{
    [JsonStringEnumMemberName("pen")] Pen,
    [JsonStringEnumMemberName("highlighter")] Highlighter,
    [JsonStringEnumMemberName("arrow")] Arrow,
    [JsonStringEnumMemberName("rectangle")] Rectangle
}

public static class LiveDrawingTools
{
    public static readonly string[] Palette = ["#FF3B30", "#FFCC00", "#34C759", "#0A84FF", "#FFFFFF"];

    /// <summary>Strokes fade together this long after drawing stops, unless they stay until cleared.</summary>
    public const double FadeAfterMs = 3000;

    /// <summary>Line width as a share of the shorter side of the recorded area.</summary>
    public static double StrokeRatio(this LiveDrawingTool tool) => tool switch
    {
        LiveDrawingTool.Pen => 0.005,
        LiveDrawingTool.Highlighter => 0.022,
        _ => 0.006
    };

    public static string Title(this LiveDrawingTool tool) => tool switch
    {
        LiveDrawingTool.Pen => "Pen",
        LiveDrawingTool.Highlighter => "Highlighter",
        LiveDrawingTool.Arrow => "Arrow",
        _ => "Rectangle"
    };
}

/// <summary>
/// One line of `drawings.jsonl`. A stroke has a tool, a color and points `[x, y, ms after t]` normalized to the recorded area;
/// `clear` ends every stroke still shown and `undo` ends the newest. `t` is the recording time, pauses removed.
/// </summary>
public sealed class LiveDrawingEvent
{
    public string Type { get; set; } = "stroke";
    public double T { get; set; }
    public LiveDrawingTool? Tool { get; set; }
    public string? Color { get; set; }
    public List<double[]>? Points { get; set; }
    /// <summary>How long a stroke stays after it is finished; null keeps it until cleared.</summary>
    public double? FadeAfterMs { get; set; }

    public static LiveDrawingEvent Stroke(double t, LiveDrawingTool tool, string color, List<double[]> points, double? fadeAfterMs) =>
        new() { Type = "stroke", T = t, Tool = tool, Color = color, Points = points, FadeAfterMs = fadeAfterMs };

    public static LiveDrawingEvent Clear(double t) => new() { Type = "clear", T = t };

    public static LiveDrawingEvent Undo(double t) => new() { Type = "undo", T = t };

    private sealed class Drawn(LiveDrawingEvent @event, double start, double finish, int clearEpoch)
    {
        public LiveDrawingEvent Event { get; } = @event;
        public double Start { get; } = start;
        public double Finish { get; } = finish;
        public int ClearEpoch { get; } = clearEpoch;
        public double? UndoneAt { get; set; }
    }

    /// <summary>
    /// The strokes as annotations on `Live drawing` tracks. Strokes drawn without a pause longer than the fade (or, when they
    /// stay, until a clear) are one burst and leave together, as on screen. In a burst, pen strokes of one tool and color
    /// become one multi-stroke `pen` item; arrows and rectangles stay items of their own, and an undone stroke ends on its
    /// own when it was undone. The items are packed on as few tracks as possible. Empty when nothing was drawn.
    /// </summary>
    public static List<AnnotationTrack> AnnotationTracks(IReadOnlyList<LiveDrawingEvent> events, double durationMs)
    {
        // Replay the log in the order things happened: a stroke is written when it is finished.
        var strokes = new List<Drawn>();
        var shown = new List<int>();
        var clearTimes = new List<double>();
        var logged = events.Select(e => (At: e.Type == "stroke" ? e.T + Math.Max(0, e.Points is { Count: > 0 } p && p[^1].Length >= 3 ? p[^1][2] : 0) : e.T, Event: e));
        foreach (var (at, e) in logged.OrderBy(entry => entry.At))
        {
            switch (e.Type)
            {
                case "clear":
                    clearTimes.Add(e.T);
                    shown.Clear();
                    break;
                case "undo":
                    if (shown.Count > 0)
                    {
                        strokes[shown[^1]].UndoneAt = e.T;
                        shown.RemoveAt(shown.Count - 1);
                    }

                    break;
                default:
                    if (e.Tool is null || e.Points is null || !e.Points.Any(point => point.Length >= 3))
                    {
                        continue;
                    }

                    strokes.Add(new Drawn(e, e.T, at, clearTimes.Count));
                    shown.Add(strokes.Count - 1);
                    break;
            }
        }

        if (strokes.Count == 0)
        {
            return [];
        }

        // Bursts, in start order.
        var bursts = new List<List<Drawn>>();
        var lastActivity = double.NegativeInfinity;
        foreach (var stroke in strokes.OrderBy(s => s.Start))
        {
            var previous = bursts.Count > 0 ? bursts[^1][^1] : null;
            var fade = previous?.Event.FadeAfterMs;
            var isNew = previous is null || previous.ClearEpoch != stroke.ClearEpoch || (fade is { } f && stroke.Start > lastActivity + f);
            if (isNew)
            {
                bursts.Add([stroke]);
                lastActivity = stroke.Finish;
            }
            else
            {
                bursts[^1].Add(stroke);
                lastActivity = Math.Max(lastActivity, stroke.Finish);
            }
        }

        var items = new List<AnnotationItem>();
        foreach (var burst in bursts)
        {
            var lastFinish = burst.Max(s => s.Finish);
            var end = burst[^1].Event.FadeAfterMs is { } fadeMs ? lastFinish + fadeMs : durationMs;
            var epoch = burst[0].ClearEpoch;
            if (epoch < clearTimes.Count)
            {
                end = Math.Min(end, clearTimes[epoch]);
            }

            end = Math.Min(end, durationMs);
            var pens = new Dictionary<string, List<Drawn>>();
            var penOrder = new List<string>();
            foreach (var stroke in burst)
            {
                if (stroke.Event.Tool is not { } tool)
                {
                    continue;
                }

                if (stroke.UndoneAt is { } undone)
                {
                    if (Annotation([stroke.Event], tool, Math.Min(end, undone), durationMs) is { } item)
                    {
                        items.Add(item);
                    }
                }
                else if (tool is LiveDrawingTool.Pen or LiveDrawingTool.Highlighter)
                {
                    var key = $"{tool}|{stroke.Event.Color ?? ""}";
                    if (!pens.TryGetValue(key, out var group))
                    {
                        penOrder.Add(key);
                        pens[key] = group = [];
                    }

                    group.Add(stroke);
                }
                else if (Annotation([stroke.Event], tool, end, durationMs) is { } item)
                {
                    items.Add(item);
                }
            }

            foreach (var key in penOrder)
            {
                var group = pens[key];
                if (group[0].Event.Tool is { } tool && Annotation(group.Select(s => s.Event).ToList(), tool, end, durationMs) is { } item)
                {
                    items.Add(item);
                }
            }
        }

        return AnnotationTrack.Packed(items, null, "Live drawing");
    }

    /// <summary>One item from strokes of one tool and color (several only for pen and highlighter), shown until `end`.</summary>
    private static AnnotationItem? Annotation(IReadOnlyList<LiveDrawingEvent> events, LiveDrawingTool tool, double rawEnd, double durationMs)
    {
        if (events.Count == 0)
        {
            return null;
        }

        var firstEvent = events[0];
        var start = Math.Max(0, Math.Min(firstEvent.T, durationMs - AnnotationItem.MinDurationMs));
        var end = Math.Max(start + AnnotationItem.MinDurationMs, rawEnd);
        var color = firstEvent.Color ?? AnnotationItem.DefaultArrowColor;
        static Point01 P(double[] v) => new(v[0], v[1]);

        switch (tool)
        {
            case LiveDrawingTool.Arrow:
            case LiveDrawingTool.Rectangle:
            {
                var points = (firstEvent.Points ?? []).Where(point => point.Length >= 3).ToList();
                if (points.Count == 0)
                {
                    return null;
                }

                var a = points[0];
                var b = points[^1];
                var drawnMs = Math.Max(0, b[2]);
                if (tool == LiveDrawingTool.Arrow)
                {
                    return new AnnotationItem
                    {
                        SourceStartMs = start,
                        SourceEndMs = end,
                        Kind = AnnotationKind.Arrow,
                        From01 = P(a),
                        To01 = P(b),
                        Bend = 0,
                        StrokeRatio = tool.StrokeRatio(),
                        Color = color,
                        Enter = AnnotationAnimation.Draw,
                        Exit = AnnotationAnimation.Fade,
                        AnimationMs = Math.Max(120, Math.Min(600, drawnMs))
                    };
                }

                return new AnnotationItem
                {
                    SourceStartMs = start,
                    SourceEndMs = end,
                    Kind = AnnotationKind.Rectangle,
                    Position01 = new Point01((a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5),
                    StrokeRatio = tool.StrokeRatio(),
                    Size01 = new Size01(AnnotationItem.ClampedSize(Math.Abs(b[0] - a[0])), AnnotationItem.ClampedSize(Math.Abs(b[1] - a[1]))),
                    CornerRatio = 0.006,
                    Color = color,
                    Enter = AnnotationAnimation.Draw,
                    Exit = AnnotationAnimation.Fade,
                    AnimationMs = Math.Max(120, Math.Min(600, drawnMs))
                };
            }

            default:
            {
                // Every point with its time after the first stroke began; a new stroke starts where the pen went down again.
                var all = new List<(double X, double Y, double T)>();
                var strokeStarts = new List<int>();
                foreach (var e in events)
                {
                    var points = (e.Points ?? []).Where(point => point.Length >= 3).ToList();
                    if (points.Count == 0)
                    {
                        continue;
                    }

                    if (all.Count > 0)
                    {
                        strokeStarts.Add(all.Count);
                    }

                    var offset = e.T - firstEvent.T;
                    var last = all.Count > 0 ? all[^1].T : 0;
                    foreach (var point in points)
                    {
                        // Times must not go back, or the replay would skip.
                        last = Math.Max(last, offset + Math.Max(0, point[2]));
                        all.Add((point[0], point[1], last));
                    }
                }

                if (all.Count == 0)
                {
                    return null;
                }

                var minX = all.Min(p => p.X);
                var maxX = all.Max(p => p.X);
                var minY = all.Min(p => p.Y);
                var maxY = all.Max(p => p.Y);
                var width = Math.Max(0.01, maxX - minX);
                var height = Math.Max(0.01, maxY - minY);
                var cx = (minX + maxX) * 0.5;
                var cy = (minY + maxY) * 0.5;
                return new AnnotationItem
                {
                    SourceStartMs = start,
                    SourceEndMs = end,
                    Kind = AnnotationKind.Pen,
                    Position01 = new Point01(cx, cy),
                    StrokeRatio = tool.StrokeRatio(),
                    Size01 = new Size01(width, height),
                    Points01 = all.Select(p => new Point01((p.X - cx) / width + 0.5, (p.Y - cy) / height + 0.5)).ToList(),
                    PointTimesMs = all.Select(p => p.T).ToList(),
                    Highlighter = tool == LiveDrawingTool.Highlighter,
                    StrokeStarts = strokeStarts,
                    Color = color,
                    Enter = AnnotationAnimation.Draw,
                    Exit = AnnotationAnimation.Fade,
                    AnimationMs = 300
                };
            }
        }
    }
}
