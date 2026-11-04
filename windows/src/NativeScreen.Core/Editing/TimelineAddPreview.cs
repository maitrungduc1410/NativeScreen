namespace NativeScreen.Core;

/// <summary>Where the ghost block for adding a segment sits while a row is hovered, in timeline milliseconds.</summary>
public static class TimelineAddPreview
{
    /// <summary>
    /// Centered on the pointer and kept inside the free gap. Null when the pointer is on or next to a block, or when the gap
    /// is too small for one.
    /// </summary>
    public static (double Start, double End)? Span(double hoverMs, IEnumerable<(double Start, double End)> existing, double totalMs, double marginMs, double minimumGapMs, double desiredMs)
    {
        var gapStart = 0.0;
        var gapEnd = totalMs;
        foreach (var (start, end) in existing)
        {
            if (hoverMs >= start - marginMs && hoverMs <= end + marginMs)
            {
                return null;
            }

            if (end <= hoverMs)
            {
                gapStart = Math.Max(gapStart, end);
            }

            if (start >= hoverMs)
            {
                gapEnd = Math.Min(gapEnd, start);
            }
        }

        if (gapEnd - gapStart < minimumGapMs)
        {
            return null;
        }

        var length = Math.Min(desiredMs, gapEnd - gapStart);
        var previewStart = Math.Max(gapStart, Math.Min(gapEnd - length, hoverMs - length * 0.5));
        return (previewStart, Math.Min(gapEnd, previewStart + length));
    }
}
