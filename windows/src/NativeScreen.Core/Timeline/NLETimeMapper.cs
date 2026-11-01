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

    public (double SourceMs, ClipSlice? Slice) SourceTime(double timelineMs)
    {
        if (MappedSlices.Count == 0)
        {
            return (Math.Max(0, timelineMs), null);
        }

        var clamped = Math.Max(0, Math.Min(TotalTimelineDurationMs, timelineMs));
        foreach (var item in MappedSlices)
        {
            if (clamped >= item.TimelineStartMs && clamped <= item.TimelineEndMs)
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
            if (referenceTimelineMs >= candidate.TimelineStartMs && referenceTimelineMs < candidate.TimelineEndMs)
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
