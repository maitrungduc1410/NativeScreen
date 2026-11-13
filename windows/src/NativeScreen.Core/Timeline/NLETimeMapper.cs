namespace NativeScreen.Core;

public sealed class NLETimeMapper
{
    public sealed class MappedSlice
    {
        public required ClipSlice Slice { get; init; }
        public double TimelineStartMs { get; init; }
        public double TimelineEndMs { get; init; }
    }

    public IReadOnlyList<MappedSlice> MappedSlices { get; }
    public double TotalTimelineDurationMs { get; }

    public NLETimeMapper(IReadOnlyList<ClipSlice> slices)
    {
        var built = new List<MappedSlice>(slices.Count);
        var current = 0.0;
        foreach (var slice in slices)
        {
            var duration = slice.TimelineDurationMs;
            if (duration <= 0)
            {
                continue;
            }

            var end = current + duration;
            built.Add(new MappedSlice
            {
                Slice = slice,
                TimelineStartMs = current,
                TimelineEndMs = end
            });
            current = end;
        }

        MappedSlices = built;
        TotalTimelineDurationMs = Math.Max(1, current);
    }

    /// <summary>
    /// Where a range of the recording shows on the timeline: from the first kept part to the last. Null when no slice keeps any of
    /// it. The segment's own times never change, so it comes back when a slice grows over it again.
    /// </summary>
    public (double Start, double End)? TimelineSpan(double sourceStartMs, double sourceEndMs)
    {
        double? earliest = null;
        double? latest = null;
        foreach (var mapped in MappedSlices)
        {
            var overlapStart = Math.Max(sourceStartMs, mapped.Slice.SourceStartMs);
            var overlapEnd = Math.Min(sourceEndMs, mapped.Slice.SourceEndMs);
            if (overlapEnd > overlapStart)
            {
                var speed = Math.Max(0.1, mapped.Slice.Speed);
                var start = mapped.TimelineStartMs + (overlapStart - mapped.Slice.SourceStartMs) / speed;
                var end = mapped.TimelineStartMs + (overlapEnd - mapped.Slice.SourceStartMs) / speed;
                earliest = Math.Min(earliest ?? start, start);
                latest = Math.Max(latest ?? end, end);
            }
        }

        return earliest is { } first && latest is { } last && last > first ? (first, last) : null;
    }

    public (double SourceMs, ClipSlice? Slice) SourceTime(double timelineMs)
    {
        if (MappedSlices.Count == 0)
        {
            return (Math.Max(0, timelineMs), null);
        }

        var clamped = Math.Max(0, Math.Min(TotalTimelineDurationMs, timelineMs));
        foreach (var item in MappedSlices)
        {
            // A slice owns [start, end): a cut boundary belongs to the incoming slice, except the movie end (ADR-86).
            if (clamped >= item.TimelineStartMs && (clamped < item.TimelineEndMs || clamped == TotalTimelineDurationMs))
            {
                var offset = clamped - item.TimelineStartMs;
                var source = item.Slice.SourceStartMs + offset * item.Slice.Speed;
                return (Math.Min(item.Slice.SourceEndMs, source), item.Slice);
            }
        }

        var last = MappedSlices[^1];
        return (last.Slice.SourceEndMs, last.Slice);
    }

    public int SliceIndex(double timelineMs)
    {
        var clamped = Math.Max(0, Math.Min(TotalTimelineDurationMs, timelineMs));
        for (var i = 0; i < MappedSlices.Count; i++)
        {
            var item = MappedSlices[i];
            if (clamped >= item.TimelineStartMs && clamped <= item.TimelineEndMs)
            {
                return i;
            }
        }

        return -1;
    }

    public double? TimelineTime(double sourceMs)
    {
        foreach (var item in MappedSlices)
        {
            if (sourceMs >= item.Slice.SourceStartMs && sourceMs <= item.Slice.SourceEndMs)
            {
                var offset = sourceMs - item.Slice.SourceStartMs;
                return item.TimelineStartMs + offset / Math.Max(0.1, item.Slice.Speed);
            }
        }

        return null;
    }

    public double? TimelineTime(double sourceMs, double referenceTimelineMs)
    {
        MappedSlice? item = null;
        foreach (var candidate in MappedSlices)
        {
            if (referenceTimelineMs >= candidate.TimelineStartMs && (referenceTimelineMs < candidate.TimelineEndMs
                || (referenceTimelineMs == TotalTimelineDurationMs && candidate.TimelineEndMs == TotalTimelineDurationMs)))
            {
                item = candidate;
                break;
            }
        }

        if (item is null || sourceMs < item.Slice.SourceStartMs || sourceMs > item.Slice.SourceEndMs)
        {
            return null;
        }

        return item.TimelineStartMs + (sourceMs - item.Slice.SourceStartMs) / Math.Max(0.1, item.Slice.Speed);
    }
}
