namespace NativeScreen.Core;

public static class CaptionLineLayout
{
    public sealed class Line
    {
        public double StartMs { get; init; }
        public double EndMs { get; init; }
        public required IReadOnlyList<CaptionSegment> Words { get; init; }
    }

    public readonly record struct DisplayedWord(string Text, double Opacity, bool IsSpokenNow);

    public static List<Line> Lines(IReadOnlyList<CaptionSegment> segments)
    {
        var words = segments.Where(word => !word.IsHidden).OrderBy(word => word.SourceStartMs).ToList();
        var lines = new List<Line>();
        var bucket = new List<CaptionSegment>();
        void Flush()
        {
            if (bucket.Count == 0)
            {
                return;
            }

            lines.Add(new Line
            {
                StartMs = bucket[0].SourceStartMs,
                EndMs = bucket[^1].SourceEndMs,
                Words = bucket.ToList()
            });
            bucket.Clear();
        }

        foreach (var word in words)
        {
            if (bucket.Count > 0)
            {
                var prev = bucket[^1];
                var gap = word.SourceStartMs - prev.SourceEndMs;
                var sentence = prev.Text.EndsWith('.') || prev.Text.EndsWith('?') || prev.Text.EndsWith('!');
                if (gap >= 750 || sentence || bucket.Count >= 6)
                {
                    Flush();
                }
            }

            bucket.Add(word);
        }

        Flush();
        return lines;
    }

    public static Line? ActiveLine(CaptionsConfig config, double timeMs)
    {
        var all = Lines(config.Segments);
        var lo = 0;
        var hi = all.Count;
        while (lo < hi)
        {
            var mid = (lo + hi) / 2;
            if (all[mid].StartMs - 140 <= timeMs)
            {
                lo = mid + 1;
            }
            else
            {
                hi = mid;
            }
        }

        for (var idx = lo - 1; idx >= 0; idx--)
        {
            var line = all[idx];
            if (timeMs <= line.EndMs + 320)
            {
                return line;
            }

            if (line.EndMs + 320 < timeMs - 10_000)
            {
                break;
            }
        }

        return null;
    }

    public static List<DisplayedWord> DisplayedWords(Line line, CaptionsConfig config, double timeMs)
    {
        if (line.Words.Count == 0)
        {
            return [];
        }

        IReadOnlyList<CaptionSegment> segments;
        if (config.WordsReveal == CaptionWordsReveal.WordByWord)
        {
            CaptionSegment? current = null;
            foreach (var word in line.Words)
            {
                if (word.SourceStartMs <= timeMs)
                {
                    current = word;
                }
            }

            segments = [current ?? line.Words[0]];
        }
        else if (config.LineGrowth == CaptionLineGrowth.FullLine)
        {
            segments = line.Words;
        }
        else
        {
            var spoken = line.Words.Where(word => word.SourceStartMs <= timeMs + 40).ToList();
            segments = spoken.Count == 0 ? [line.Words[0]] : spoken;
        }

        var result = new List<DisplayedWord>(segments.Count);
        foreach (var word in segments)
        {
            var spokenNow = timeMs >= word.SourceStartMs && timeMs <= word.SourceEndMs + 120;
            var future = timeMs < word.SourceStartMs;
            var opacity = config.WordAnimation switch
            {
                CaptionWordAnimation.FadeIn => future ? 0.38 : 1,
                CaptionWordAnimation.SlideIn => future ? 0.25 : 1,
                _ => future ? 0 : 1
            };
            result.Add(new DisplayedWord(word.Text, opacity, spokenNow));
        }

        return result;
    }
}
