namespace NativeScreen.Core;

/// <summary>
/// Segment snapping on the timeline. While an item is dragged or trimmed, its edges stick to nearby edges of items on every
/// track, clip boundaries, the playhead and both ends of the timeline (spec/06 ADR-43). All times are timeline times.
/// </summary>
public sealed class TimelineSnapController
{
    /// <summary>Edges within this many points of a target snap to it.</summary>
    public const double ThresholdPoints = 8;

    private List<double> targets = [];
    private double thresholdMs;

    /// <summary>Timeline time of the guide line while an edge is snapped, null otherwise.</summary>
    public double? GuideTimelineMs { get; private set; }

    /// <summary>Collects targets once per drag, so moving the dragged item never feeds back into its own targets.</summary>
    public void Begin(IEnumerable<double> snapTargets, double pointsPerMs)
    {
        GuideTimelineMs = null;
        if (pointsPerMs <= 0)
        {
            targets = [];
            thresholdMs = 0;
            return;
        }

        targets = snapTargets.ToList();
        thresholdMs = ThresholdPoints / pointsPerMs;
    }

    /// <summary>Shifts a moved item so whichever of its edges is closer to a target lands on it.</summary>
    public double SnapMove(double startMs, double durationMs)
    {
        var start = Nearest(startMs);
        var end = Nearest(startMs + durationMs);
        switch (start, end)
        {
            case ({ } s, { } e):
                return Math.Abs(s - startMs) <= Math.Abs(e - (startMs + durationMs)) ? Show(s, s) : Show(e, e - durationMs);
            case ({ } s, null):
                return Show(s, s);
            case (null, { } e):
                return Show(e, e - durationMs);
            default:
                GuideTimelineMs = null;
                return startMs;
        }
    }

    /// <summary>Snaps one trimmed edge.</summary>
    public double SnapEdge(double ms)
    {
        if (Nearest(ms) is not { } target)
        {
            GuideTimelineMs = null;
            return ms;
        }

        return Show(target, target);
    }

    public void End()
    {
        targets = [];
        thresholdMs = 0;
        GuideTimelineMs = null;
    }

    private double Show(double guide, double result)
    {
        GuideTimelineMs = guide;
        return result;
    }

    private double? Nearest(double ms)
    {
        if (thresholdMs <= 0)
        {
            return null;
        }

        double? best = null;
        var bestDistance = thresholdMs;
        foreach (var target in targets)
        {
            var distance = Math.Abs(target - ms);
            if (distance <= bestDistance)
            {
                best = target;
                bestDistance = distance;
            }
        }

        return best;
    }
}

public static class TimelineSnapTargets
{
    /// <summary>
    /// Every edge an item can snap to, in timeline time, leaving out the item being dragged by id, so a neighbor touching it
    /// still counts.
    /// </summary>
    public static List<double> Collect(EditorSession session, string excludingItemId)
    {
        var mapper = session.Mapper;
        var targets = new List<double> { 0, mapper.TotalTimelineDurationMs, session.PlayheadTimelineMs };
        foreach (var mapped in mapper.MappedSlices)
        {
            targets.Add(mapped.TimelineStartMs);
            targets.Add(mapped.TimelineEndMs);
        }

        void Add(string id, double start, double end)
        {
            if (id != excludingItemId && mapper.TimelineSpan(start, end) is { } span)
            {
                targets.Add(span.Start);
                targets.Add(span.End);
            }
        }

        var timeline = session.Document.Timeline;
        foreach (var zoom in timeline.Zooms)
        {
            Add(zoom.Id, zoom.SourceStartMs, zoom.SourceEndMs);
        }

        foreach (var track in timeline.MaskTracks)
        {
            foreach (var item in track.Items)
            {
                Add(item.Id, item.SourceStartMs, item.SourceEndMs);
            }
        }

        foreach (var layout in timeline.CameraLayouts)
        {
            Add(layout.Id, layout.SourceStartMs, layout.SourceEndMs);
        }

        foreach (var voiceover in timeline.Voiceovers)
        {
            Add(voiceover.Id, voiceover.SourceStartMs, voiceover.SourceStartMs + voiceover.DurationMs);
        }

        foreach (var block in session.Document.Captions.CaptionBlocks)
        {
            Add(block.Id, block.SourceStartMs, block.SourceEndMs);
        }

        foreach (var cluster in session.Shortcuts())
        {
            Add(cluster.Id, cluster.DisplayStartMs, cluster.DisplayEndMs);
        }

        return targets;
    }
}
