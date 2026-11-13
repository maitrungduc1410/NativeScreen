namespace NativeScreen.Core;

public static class AutoZoomClusterGenerator
{
    public static List<ZoomBlock> GenerateZooms(
        IReadOnlyList<ClickEvent> clicks,
        IReadOnlyList<KeyStrokeEvent> keys,
        double durationMs,
        double defaultScale = 2)
    {
        var downClicks = clicks
            .Where(click => click.Type == "down" && click.T < durationMs - 1000)
            .OrderBy(click => click.T)
            .ToList();
        if (downClicks.Count == 0)
        {
            return [];
        }

        const double leadInMs = 300;
        const double holdAfterClickMs = 2500;
        const double clusterGapMs = 2500;
        const double holdAfterTypingMs = 1500;
        const double minZoomDurationMs = 2200;
        var maxAutoZoomEndMs = Math.Max(600, durationMs - 800);

        var blocks = new List<ZoomBlock>();
        var clusterStart = Math.Max(0, downClicks[0].T - leadInMs);
        var clusterEnd = Math.Min(maxAutoZoomEndMs, downClicks[0].T + holdAfterClickMs);
        var centerX = downClicks[0].X;
        var centerY = downClicks[0].Y;
        var clickCount = 1;

        for (var i = 1; i < downClicks.Count; i++)
        {
            var click = downClicks[i];
            var prev = downClicks[i - 1];
            if (click.T - prev.T <= clusterGapMs)
            {
                clusterEnd = Math.Min(maxAutoZoomEndMs, Math.Max(clusterEnd, click.T + holdAfterClickMs));
                centerX += click.X;
                centerY += click.Y;
                clickCount++;
            }
            else
            {
                clusterEnd = ExtendForTyping(clusterStart, clusterEnd, keys, holdAfterTypingMs, maxAutoZoomEndMs);
                if (clusterEnd - clusterStart < minZoomDurationMs)
                {
                    clusterEnd = Math.Min(maxAutoZoomEndMs, clusterStart + minZoomDurationMs);
                }

                blocks.Add(Make(clusterStart, clusterEnd, defaultScale, centerX / clickCount, centerY / clickCount));
                clusterStart = Math.Max(clusterEnd + 250, click.T - leadInMs);
                clusterEnd = Math.Min(maxAutoZoomEndMs, click.T + holdAfterClickMs);
                centerX = click.X;
                centerY = click.Y;
                clickCount = 1;
            }
        }

        clusterEnd = ExtendForTyping(clusterStart, clusterEnd, keys, holdAfterTypingMs, maxAutoZoomEndMs);
        if (clusterEnd - clusterStart < minZoomDurationMs)
        {
            clusterEnd = Math.Min(maxAutoZoomEndMs, clusterStart + minZoomDurationMs);
        }

        if (clusterEnd > clusterStart + 400)
        {
            blocks.Add(Make(clusterStart, clusterEnd, defaultScale, centerX / clickCount, centerY / clickCount));
        }

        return NormalizeNonOverlappingZooms(MergeCloseZooms(blocks), durationMs);
    }

    /// Two zooms less than this far apart become one: a shorter gap only zooms out and straight back in.
    public const double MergeGapMs = 2500;

    /// Joins neighbouring zooms whose gap is under <see cref="MergeGapMs"/>. The joined zoom spans both, and its center
    /// is the duration-weighted mean of their centers. Same as the macOS `mergeCloseZooms`.
    internal static List<ZoomBlock> MergeCloseZooms(IReadOnlyList<ZoomBlock> blocks)
    {
        var result = new List<ZoomBlock>();
        foreach (var block in blocks.OrderBy(zoom => zoom.SourceStartMs))
        {
            if (result.Count == 0 || block.SourceStartMs - result[^1].SourceEndMs >= MergeGapMs)
            {
                result.Add(block);
                continue;
            }

            var last = result[^1];
            var lastMs = last.SourceEndMs - last.SourceStartMs;
            var blockMs = block.SourceEndMs - block.SourceStartMs;
            var total = Math.Max(1, lastMs + blockMs);
            last.ManualCenter01 = new Point01(
                (last.ManualCenter01.X * lastMs + block.ManualCenter01.X * blockMs) / total,
                (last.ManualCenter01.Y * lastMs + block.ManualCenter01.Y * blockMs) / total);
            last.SourceEndMs = Math.Max(last.SourceEndMs, block.SourceEndMs);
        }

        return result;
    }

    public static List<ZoomBlock> NormalizeNonOverlappingZooms(IReadOnlyList<ZoomBlock> zooms, double durationMs)
    {
        var sorted = zooms.OrderBy(zoom => zoom.SourceStartMs).ToList();
        var result = new List<ZoomBlock>();
        foreach (var zoom in sorted)
        {
            var minStart = result.Count == 0 ? 0 : result[^1].SourceEndMs;
            zoom.SourceStartMs = Math.Max(minStart, zoom.SourceStartMs);
            zoom.SourceEndMs = Math.Min(durationMs, zoom.SourceEndMs);
            if (zoom.SourceEndMs - zoom.SourceStartMs >= 200)
            {
                result.Add(zoom);
            }
        }

        return result;
    }

    private static ZoomBlock Make(double start, double end, double scale, double x, double y) => new()
    {
        SourceStartMs = start,
        SourceEndMs = end,
        Scale = scale,
        Mode = ZoomMode.FollowCursor,
        Presentation = ZoomPresentation.Screen,
        ManualCenter01 = new Point01(x, y)
    };

    private static double ExtendForTyping(
        double startMs,
        double endMs,
        IReadOnlyList<KeyStrokeEvent> keys,
        double holdMs,
        double maxDurationMs)
    {
        var currentEnd = endMs;
        foreach (var key in keys)
        {
            if (key.T >= startMs && key.T <= currentEnd + 800)
            {
                currentEnd = Math.Min(maxDurationMs, Math.Max(currentEnd, key.T + holdMs));
            }
        }

        return currentEnd;
    }
}
