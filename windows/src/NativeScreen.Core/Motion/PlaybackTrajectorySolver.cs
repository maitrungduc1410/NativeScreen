namespace NativeScreen.Core;

/// <summary>
/// Springs run on edited time (spec/06 ADR-86, the macOS `PlaybackTrajectorySolver`). Source-contiguous slices share history,
/// so a speed change keeps the motion going; a real cut or a reused source range starts a fresh trajectory, initialized at its
/// targets, and nothing ever interpolates between runs.
/// </summary>
public sealed class PlaybackTrajectorySolver
{
    private sealed record Run(double Start, double End, SpringTrajectorySolver Solver);

    private readonly List<Run> runs;

    public NLETimeMapper Mapper { get; }

    /// <summary>False for camera-only recordings and projects made from a video: no cursor is drawn.</summary>
    public bool HasRecordedCursor { get; }

    /// <param name="reusingCursorFrom">The previous solver, when only zooms, camera or crop changed: runs with the same span keep their cursor.</param>
    public PlaybackTrajectorySolver(
        double durationMs,
        IReadOnlyList<CursorSampleEvent> cursorEvents,
        IReadOnlyList<ClickEvent> clickEvents,
        ProjectDocument document,
        MotionPointSize? pointSize = null,
        PlaybackTrajectorySolver? reusingCursorFrom = null)
    {
        HasRecordedCursor = cursorEvents.Count > 0;
        var size = pointSize ?? MotionPointSize.Reference;
        var valid = document.Timeline.Slices.Where(slice => slice.TimelineDurationMs > 0 && double.IsFinite(slice.TimelineDurationMs)).ToList();
        List<ClipSlice> slices = valid.Count == 0 ? [new ClipSlice { SourceStartMs = 0, SourceEndMs = Math.Max(1, durationMs) }] : valid;
        Mapper = new NLETimeMapper(slices);

        // Expand recording-time pause holds before stretching time. Slow 60 Hz footage is still continuous motion.
        var expanded = new List<CursorSampleEvent>(cursorEvents.Count);
        for (var i = 0; i < cursorEvents.Count; i++)
        {
            var e = cursorEvents[i];
            if (i > 0)
            {
                var previous = cursorEvents[i - 1];
                if (e.T - previous.T > 48)
                {
                    expanded.Add(new CursorSampleEvent { T = e.T - 16, X = previous.X, Y = previous.Y, C = previous.C });
                }
            }

            expanded.Add(e);
        }

        var firstRetained = CursorTelemetry.Sample(expanded, Mapper.MappedSlices[0].Slice.SourceStartMs, holdPauses: false);
        var groups = new List<List<NLETimeMapper.MappedSlice>>();
        foreach (var item in Mapper.MappedSlices)
        {
            if (groups.Count > 0 && Math.Abs(groups[^1][^1].Slice.SourceEndMs - item.Slice.SourceStartMs) < 0.001)
            {
                groups[^1].Add(item);
            }
            else
            {
                groups.Add([item]);
            }
        }

        var zooms = document.Timeline.Zooms;
        runs = new List<Run>(groups.Count);
        for (var index = 0; index < groups.Count; index++)
        {
            var group = groups[index];
            var start = group[0].TimelineStartMs;
            var end = group[^1].TimelineEndMs;
            var projectedCursor = new List<CursorSampleEvent>();
            var projectedClicks = new List<ClickEvent>();
            var projectedZooms = new List<ZoomBlock>();

            // A retained run may begin while a button is held. Do not inherit its old spring state or ripple.
            var heldButtons = new Dictionary<string, ClickEvent>();
            foreach (var click in clickEvents)
            {
                if (click.T >= group[0].Slice.SourceStartMs)
                {
                    continue;
                }

                var button = click.Button ?? "left";
                if (click.Type == "down")
                {
                    heldButtons[button] = click;
                }
                else if (click.Type == "up")
                {
                    heldButtons.Remove(button);
                }
            }

            foreach (var click in heldButtons.Values)
            {
                var position = CursorTelemetry.Sample(expanded, group[0].Slice.SourceStartMs, holdPauses: false);
                projectedClicks.Add(new ClickEvent { T = 0, Type = "held", Button = click.Button, X = position.X, Y = position.Y });
            }

            for (var itemIndex = 0; itemIndex < group.Count; itemIndex++)
            {
                var item = group[itemIndex];
                var slice = item.Slice;
                var speed = Math.Max(0.1, slice.Speed);
                double Time(double source) => item.TimelineStartMs - start + (source - slice.SourceStartMs) / speed;

                var boundary = CursorTelemetry.Sample(expanded, slice.SourceStartMs, holdPauses: false);
                projectedCursor.Add(new CursorSampleEvent { T = Time(slice.SourceStartMs), X = boundary.X, Y = boundary.Y, C = boundary.C });
                // Only project retained telemetry. Lookahead can never see discarded footage.
                var lo = 0;
                var hi = expanded.Count;
                while (lo < hi)
                {
                    var mid = (lo + hi) / 2;
                    if (expanded[mid].T <= slice.SourceStartMs)
                    {
                        lo = mid + 1;
                    }
                    else
                    {
                        hi = mid;
                    }
                }

                for (var i = lo; i < expanded.Count && expanded[i].T < slice.SourceEndMs; i++)
                {
                    var e = expanded[i];
                    projectedCursor.Add(new CursorSampleEvent { T = Time(e.T), X = e.X, Y = e.Y, C = e.C });
                }

                boundary = CursorTelemetry.Sample(expanded, slice.SourceEndMs, holdPauses: false);
                projectedCursor.Add(new CursorSampleEvent { T = Time(slice.SourceEndMs), X = boundary.X, Y = boundary.Y, C = boundary.C });

                foreach (var click in clickEvents)
                {
                    if (click.T >= slice.SourceStartMs && (click.T < slice.SourceEndMs || (itemIndex == group.Count - 1 && click.T == slice.SourceEndMs)))
                    {
                        projectedClicks.Add(new ClickEvent { T = Time(click.T), Type = click.Type, Button = click.Button, X = click.X, Y = click.Y, Count = click.Count, Dx = click.Dx, Dy = click.Dy });
                    }
                }

                foreach (var zoom in zooms)
                {
                    var a = Math.Max(zoom.SourceStartMs, slice.SourceStartMs);
                    var b = Math.Min(zoom.SourceEndMs, slice.SourceEndMs);
                    if (b <= a)
                    {
                        continue;
                    }

                    if (projectedZooms.Count > 0 && projectedZooms[^1].Id == zoom.Id && Math.Abs(projectedZooms[^1].SourceEndMs - Time(a)) < 0.001)
                    {
                        projectedZooms[^1].SourceEndMs = Time(b);
                    }
                    else
                    {
                        var projected = ProjectJson.Clone(zoom);
                        projected.SourceStartMs = Time(a);
                        projected.SourceEndMs = Time(b);
                        projectedZooms.Add(projected);
                    }
                }
            }

            projectedCursor.Sort((x, y) => x.T.CompareTo(y.T));
            projectedClicks.Sort((x, y) => x.T.CompareTo(y.T));
            var projectedDocument = ProjectJson.Clone(document);
            projectedDocument.Timeline.Zooms = [.. projectedZooms.OrderBy(zoom => zoom.SourceStartMs)];
            // Ending options belong to the edited movie, not to each cut.
            if (index != groups.Count - 1)
            {
                projectedDocument.Cursor.StopMovementInLastPartMs = 0;
                projectedDocument.Cursor.LoopBackToStartMs = null;
            }

            SpringTrajectorySolver? reusable = null;
            if (reusingCursorFrom is { } old && index < old.runs.Count && old.runs[index].Start == start && old.runs[index].End == end)
            {
                reusable = old.runs[index].Solver;
            }

            runs.Add(new Run(start, end, new SpringTrajectorySolver(
                end - start, projectedCursor, projectedClicks, projectedDocument, size, reusable,
                startsAtCut: index > 0 || group[0].Slice.SourceStartMs > 0,
                loopTarget01: new Point01(firstRetained.X, firstRetained.Y),
                telemetryUsesPlaybackTime: true)));
        }
    }

    public double TotalTimelineDurationMs => Mapper.TotalTimelineDurationMs;

    /// <summary>Cursor and camera at edited time. Rendering must use this: a reused source range has its own trajectory.</summary>
    public (SpringTrajectorySolver.CursorFrameState Cursor, SpringTrajectorySolver.CameraFrameState Camera) EvaluateAtTimeline(double timelineMs)
    {
        var t = Math.Max(0, Math.Min(Mapper.TotalTimelineDurationMs, timelineMs));
        var lo = 0;
        var hi = runs.Count;
        while (lo < hi)
        {
            var mid = (lo + hi) / 2;
            if (runs[mid].Start <= t)
            {
                lo = mid + 1;
            }
            else
            {
                hi = mid;
            }
        }

        var run = runs[Math.Max(0, lo - 1)];
        return run.Solver.Evaluate(t - run.Start);
    }

    /// <summary>Source-only callers (editing helpers) take the first retained occurrence of <paramref name="sourceMs"/>.</summary>
    public (SpringTrajectorySolver.CursorFrameState Cursor, SpringTrajectorySolver.CameraFrameState Camera) EvaluateAtSource(double sourceMs) =>
        EvaluateAtTimeline(Mapper.TimelineTime(sourceMs) ?? 0);

    /// <summary>Whether both edited times are in one continuous run (motion blur never samples across a cut).</summary>
    public bool IsSameRun(double a, double b)
    {
        foreach (var run in runs)
        {
            if (a >= run.Start && a < run.End && b >= run.Start && b < run.End)
            {
                return true;
            }
        }

        return false;
    }
}
