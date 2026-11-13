namespace NativeScreen.Core;

/// <summary>Recorded cursor telemetry helpers (same as the macOS `CursorTelemetry`).</summary>
public static class CursorTelemetry
{
    /// <summary>Linear position at <paramref name="time"/>. With <paramref name="holdPauses"/>, a gap over 48 ms holds until 16 ms before the next sample.</summary>
    public static CursorSampleEvent Sample(IReadOnlyList<CursorSampleEvent> events, double time, bool holdPauses = true)
    {
        if (events.Count == 0)
        {
            return new CursorSampleEvent { T = time, X = 0.5, Y = 0.5, C = "arrow" };
        }

        var first = events[0];
        if (time <= first.T)
        {
            return first;
        }

        var lo = 0;
        var hi = events.Count;
        while (lo < hi)
        {
            var mid = (lo + hi) / 2;
            if (events[mid].T <= time)
            {
                lo = mid + 1;
            }
            else
            {
                hi = mid;
            }
        }

        var a = events[lo - 1];
        if (lo >= events.Count)
        {
            return a;
        }

        var b = events[lo];
        var start = holdPauses && b.T - a.T > 48 ? b.T - 16 : a.T;
        var f = Math.Clamp((time - start) / Math.Max(0.001, b.T - start), 0, 1);
        return new CursorSampleEvent { T = time, X = a.X + (b.X - a.X) * f, Y = a.Y + (b.Y - a.Y) * f, C = a.C };
    }

    /// <summary>
    /// Replaces samples at a click's time with the click's own position: the click log, not a decimated cursor sample, owns the
    /// tip at the interaction. A click further than <paramref name="maxDistancePt"/> from the recorded cursor (and from both
    /// samples around it) is left out, so the path never darts to it (ADR-88).
    /// </summary>
    public static List<CursorSampleEvent> InsertingClicks(IReadOnlyList<ClickEvent> clicks, IReadOnlyList<CursorSampleEvent> events, bool holdPauses, MotionPointSize pointSize, double maxDistancePt = 16)
    {
        var anchors = clicks.Where(click => click.Type is "down" or "up").OrderBy(click => click.T).ToList();
        if (anchors.Count == 0)
        {
            return events as List<CursorSampleEvent> ?? [.. events];
        }

        var result = new List<CursorSampleEvent>(events.Count + anchors.Count);
        var i = 0;
        foreach (var anchor in anchors)
        {
            while (i < events.Count && events[i].T < anchor.T)
            {
                result.Add(events[i]);
                i++;
            }

            while (i < events.Count && events[i].T == anchor.T)
            {
                i++;
            }

            var recorded = Sample(events, anchor.T, holdPauses);
            // Interpolating across a cursor warp can land far from both samples, so the bracketing samples count too.
            var near = events.Count == 0
                || pointSize.Distance(recorded.X, recorded.Y, anchor.X, anchor.Y) <= maxDistancePt
                || (i > 0 && pointSize.Distance(events[i - 1].X, events[i - 1].Y, anchor.X, anchor.Y) <= maxDistancePt)
                || (i < events.Count && pointSize.Distance(events[i].X, events[i].Y, anchor.X, anchor.Y) <= maxDistancePt);
            result.Add(near ? new CursorSampleEvent { T = anchor.T, X = anchor.X, Y = anchor.Y, C = recorded.C } : recorded);
        }

        for (; i < events.Count; i++)
        {
            result.Add(events[i]);
        }

        return result;
    }

    /// <summary>Button-held intervals, merged. A `held` click marks a button already down when a trimmed run starts.</summary>
    public static List<(double Start, double End)> HeldIntervals(IReadOnlyList<ClickEvent> clicks, double endMs)
    {
        var down = new Dictionary<string, double>();
        var intervals = new List<(double Start, double End)>();
        foreach (var click in clicks.OrderBy(click => click.T))
        {
            var button = click.Button ?? "left";
            if (click.Type is "down" or "held")
            {
                down.TryAdd(button, click.T);
            }
            else if (click.Type == "up" && down.Remove(button, out var start))
            {
                intervals.Add((start, click.T));
            }
        }

        foreach (var start in down.Values)
        {
            intervals.Add((start, Math.Max(start, endMs)));
        }

        var merged = new List<(double Start, double End)>();
        foreach (var interval in intervals.OrderBy(interval => interval.Start))
        {
            if (merged.Count > 0 && interval.Start <= merged[^1].End)
            {
                merged[^1] = (merged[^1].Start, Math.Max(merged[^1].End, interval.End));
            }
            else
            {
                merged.Add(interval);
            }
        }

        return merged;
    }
}
