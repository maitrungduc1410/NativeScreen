using System.Globalization;

namespace NativeScreen.Core;

/// <summary>Measures a word in stage units. The compositor passes DirectWrite; tests can pass anything.</summary>
public delegate (double Width, double Height) CaptionTextMeasure(string text, CaptionFontStyle style, double fontSize);

/// <summary>
/// Caption timing and animation shared by the preview and the export: both draw the frames returned by <see cref="Frames"/>.
/// Every animated value follows a stiff, clamped spring toward a target that only depends on the time. The state at any time
/// is found by simulating the last moments on a fixed grid, so a frame looks the same when playing, scrubbing or exporting.
/// </summary>
public static class CaptionLineLayout
{
    // Margin kept between a line and the canvas edge, as a share of the shortest side.
    private const double StageMarginRatio = 0.06;
    // Box padding around the words, as a share of the font size.
    private const double BoxPaddingXRatio = 0.5;
    private const double BoxPaddingYRatio = 0.25;
    // How far a Slide in word starts from its place, as a share of the font size.
    private const double SlideInDistanceRatio = 0.75;
    // Opacity of a Fade in word that has not been spoken yet.
    private const double DimmedWordOpacity = 0.5;
    private const double SpringStiffness = 425;
    private const double SpringDamping = 12;
    private const double SpringMass = 1.5;
    private const double StepSeconds = 1.0 / 240.0;
    // A spring from rest has landed well within this time, so older events cannot affect the frame.
    private const double SettleWindowMs = 500;
    // Lines further than this from the playhead are invisible.
    private const double DrawnLineWindowMs = 700;
    private const int MaximumCachedMetrics = 2048;

    private static readonly object CacheGate = new();
    private static readonly Dictionary<(string Text, CaptionFontStyle Style, double Size), (double Width, double Height)> CachedMetrics = [];
    private static CaptionsConfig? cachedConfig;
    private static List<(CaptionTrack Track, List<Line> Lines)> cachedLines = [];

    public readonly record struct Word(string Text, double StartMs, double EndMs);

    public sealed class Line
    {
        public required string BlockId { get; init; }
        public required double StartMs { get; init; }
        public required double EndMs { get; init; }
        public required IReadOnlyList<Word> Words { get; init; }
        public required CaptionStyle Style { get; init; }
    }

    /// <summary>A rectangle in stage units with a top-left origin.</summary>
    public readonly record struct StageRect(double X, double Y, double Width, double Height);

    /// <param name="IsDimmedAtRest">A dimmed Fade in word is at rest, so it must not pick up the fade-out blur.</param>
    public readonly record struct DrawnWord(string Text, StageRect Rect, double Opacity, bool IsSpokenNow, bool IsDimmedAtRest);

    /// <param name="BoxRect">The line's box including its padding.</param>
    public sealed record TrackFrame(string BlockId, CaptionStyle Style, double FontSize, StageRect BoxRect, double BoxOpacity, IReadOnlyList<DrawnWord> Words);

    /// <summary>Splits a transcript into lines at sentence ends, long pauses and every 6 words.</summary>
    public static List<List<CaptionSegment>> GroupWordsIntoLines(IReadOnlyList<CaptionSegment> segments)
    {
        var lines = new List<List<CaptionSegment>>();
        var bucket = new List<CaptionSegment>();
        foreach (var word in segments.OrderBy(word => word.SourceStartMs))
        {
            if (bucket.Count > 0)
            {
                var previous = bucket[^1];
                var gap = word.SourceStartMs - previous.SourceEndMs;
                var sentence = previous.Text.EndsWith('.') || previous.Text.EndsWith('?') || previous.Text.EndsWith('!');
                if (gap >= 750 || sentence || bucket.Count >= 6)
                {
                    lines.Add(bucket);
                    bucket = [];
                }
            }

            bucket.Add(word);
        }

        if (bucket.Count > 0)
        {
            lines.Add(bucket);
        }

        return lines;
    }

    /// <summary>The caption's text as shown on the timeline and in the inspector.</summary>
    public static string DisplayText(CaptionBlock block, CaptionsConfig config)
    {
        if (block.CustomText is { } custom)
        {
            return custom;
        }

        var parts = new List<string>();
        foreach (var id in block.WordIds)
        {
            if (config.Segments.Find(word => word.Id == id) is { IsHidden: false } word)
            {
                parts.Add(word.Text);
            }
        }

        return string.Join(' ', parts);
    }

    /// <summary>The lines of each track that is not hidden. Rebuilt only for a new config, which the render thread gets as a frozen copy.</summary>
    public static List<(CaptionTrack Track, List<Line> Lines)> LinesByTrack(CaptionsConfig config)
    {
        lock (CacheGate)
        {
            if (ReferenceEquals(cachedConfig, config))
            {
                return cachedLines;
            }

            var words = new Dictionary<string, CaptionSegment>();
            foreach (var segment in config.Segments)
            {
                words.TryAdd(segment.Id, segment);
            }

            var result = new List<(CaptionTrack, List<Line>)>();
            foreach (var track in config.CaptionTracks)
            {
                if (track.IsHidden)
                {
                    continue;
                }

                var lines = new List<Line>();
                foreach (var block in config.CaptionBlocks.Where(item => item.TrackId == track.Id).OrderBy(item => item.SourceStartMs))
                {
                    if (MakeLine(block, block.StyleOverride ?? track.Style, words) is { } line)
                    {
                        lines.Add(line);
                    }
                }

                result.Add((track, lines));
            }

            cachedConfig = config;
            cachedLines = result;
            return result;
        }
    }

    public static List<TrackFrame> Frames(CaptionsConfig config, double timeMs, double stageWidth, double stageHeight, CaptionTextMeasure measure)
    {
        var frames = new List<TrackFrame>();
        foreach (var (_, lines) in LinesByTrack(config))
        {
            if (Frame(lines, timeMs, stageWidth, stageHeight, measure) is { } frame)
            {
                frames.Add(frame);
            }
        }

        return frames;
    }

    private static Line? MakeLine(CaptionBlock block, CaptionStyle style, Dictionary<string, CaptionSegment> wordsById)
    {
        var duration = Math.Max(1, block.SourceEndMs - block.SourceStartMs);
        var words = new List<Word>();
        if (block.CustomText is { } custom)
        {
            // No spoken timing: each word gets time in proportion to its length.
            var parts = custom.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            var total = Math.Max(1, parts.Sum(part => new StringInfo(part).LengthInTextElements + 1));
            var cursor = block.SourceStartMs;
            foreach (var part in parts)
            {
                var span = duration * (new StringInfo(part).LengthInTextElements + 1) / total;
                words.Add(new Word(part, cursor, cursor + span));
                cursor += span;
            }
        }
        else
        {
            var spoken = new List<CaptionSegment>();
            foreach (var id in block.WordIds)
            {
                if (wordsById.TryGetValue(id, out var segment))
                {
                    spoken.Add(segment);
                }
            }

            if (spoken.Count == 0)
            {
                return null;
            }

            var spokenStart = spoken[0].SourceStartMs;
            var scale = duration / Math.Max(1, spoken[^1].SourceEndMs - spokenStart);
            foreach (var word in spoken)
            {
                if (!word.IsHidden)
                {
                    words.Add(new Word(
                        word.Text,
                        block.SourceStartMs + (word.SourceStartMs - spokenStart) * scale,
                        block.SourceStartMs + (word.SourceEndMs - spokenStart) * scale));
                }
            }
        }

        return words.Count == 0
            ? null
            : new Line { BlockId = block.Id, StartMs = words[0].StartMs, EndMs = words[^1].EndMs, Words = words, Style = style };
    }

    private static (double Width, double Height) Measure(string text, CaptionFontStyle style, double size, CaptionTextMeasure measure)
    {
        lock (CacheGate)
        {
            if (CachedMetrics.TryGetValue((text, style, size), out var hit))
            {
                return hit;
            }

            if (CachedMetrics.Count > MaximumCachedMetrics)
            {
                CachedMetrics.Clear();
            }

            var measured = measure(text, style, size);
            CachedMetrics[(text, style, size)] = measured;
            return measured;
        }
    }

    private sealed class Geometry
    {
        public readonly Line Line;
        public readonly double FontSize;
        public readonly (double Width, double Height)[] Sizes;
        public readonly double[] Offsets;
        public readonly double TotalWidth;
        public readonly double Height;
        private readonly StageRect available;

        public Geometry(Line line, double stageWidth, double stageHeight, CaptionTextMeasure measure)
        {
            Line = line;
            var shortest = Math.Min(stageWidth, stageHeight);
            var margin = shortest * StageMarginRatio;
            available = new StageRect(margin, margin, stageWidth - margin * 2, stageHeight - margin * 2);

            var size = Math.Max(8, shortest * line.Style.FontSizeRatio);
            var laidOut = LayOut(line, size, measure);
            // A line wider than the canvas shrinks to fit.
            var usable = available.Width - size * BoxPaddingXRatio * 2;
            if (laidOut.Total > usable && laidOut.Total > 0)
            {
                size = Math.Max(8, size * usable / laidOut.Total);
                laidOut = LayOut(line, size, measure);
            }

            FontSize = size;
            Sizes = laidOut.Sizes;
            Offsets = laidOut.Offsets;
            TotalWidth = laidOut.Total;
            Height = Sizes.Length > 0 ? Sizes.Max(item => item.Height) : size;
        }

        public StageRect Fitted(double width, double height)
        {
            var anchor = Line.Style.Position01;
            return new StageRect(
                available.X + (available.Width - width) * Math.Clamp(anchor.X, 0, 1),
                available.Y + (available.Height - height) * Math.Clamp(anchor.Y, 0, 1),
                width,
                height);
        }

        public double WidthOfFirstWords(int count)
        {
            if (count <= 0 || Sizes.Length == 0)
            {
                return 1;
            }

            var last = Math.Min(count, Sizes.Length) - 1;
            return Offsets[last] + Sizes[last].Width;
        }

        private static ((double Width, double Height)[] Sizes, double[] Offsets, double Total) LayOut(Line line, double fontSize, CaptionTextMeasure measure)
        {
            var space = CaptionLineLayout.Measure(" ", line.Style.FontStyle, fontSize, measure).Width;
            var sizes = new (double, double)[line.Words.Count];
            var offsets = new double[line.Words.Count];
            var cursor = 0.0;
            for (var index = 0; index < sizes.Length; index++)
            {
                var size = CaptionLineLayout.Measure(line.Words[index].Text, line.Style.FontStyle, fontSize, measure);
                sizes[index] = size;
                offsets[index] = cursor;
                cursor += size.Width + space;
            }

            return (sizes, offsets, Math.Max(1, cursor - space));
        }
    }

    private static int PresentWordCount(Line line, double timeMs)
    {
        var count = 0;
        foreach (var word in line.Words)
        {
            count += word.StartMs <= timeMs ? 1 : 0;
        }

        return count;
    }

    /// <summary>Where the line's words sit at this time, without its padding.</summary>
    private static StageRect TargetContentRect(Geometry geometry, double timeMs)
    {
        var style = geometry.Line.Style;
        var count = PresentWordCount(geometry.Line, timeMs);
        if (style.WordsReveal == CaptionWordsReveal.WordByWord)
        {
            var current = geometry.Sizes[Math.Max(0, count - 1)];
            return geometry.Fitted(current.Width, current.Height);
        }

        var full = geometry.Fitted(geometry.TotalWidth, geometry.Height);
        // Dimmed upcoming words need the whole box from the start.
        var growth = style.WordAnimation == CaptionWordAnimation.FadeIn ? CaptionLineGrowth.FullLine : style.LineGrowth;
        return growth switch
        {
            CaptionLineGrowth.FullLine => full,
            CaptionLineGrowth.Expanding => full with { Width = geometry.WidthOfFirstWords(count) },
            _ => geometry.Fitted(geometry.WidthOfFirstWords(count), geometry.Height)
        };
    }

    /// <summary>A word's place relative to its line's content origin.</summary>
    private static double TargetWordOffset(Geometry geometry, int index, double timeMs)
    {
        var style = geometry.Line.Style;
        if (style.WordsReveal == CaptionWordsReveal.WordByWord)
        {
            // The current word stays until the next one pushes it out, also through a short gap between words.
            var current = PresentWordCount(geometry.Line, timeMs) - 1;
            if (timeMs > geometry.Line.EndMs || index < current)
            {
                return -geometry.Sizes[index].Width;
            }

            return index == current ? 0 : geometry.Sizes[Math.Max(0, current)].Width;
        }

        var offset = geometry.Offsets[index];
        return style.WordAnimation == CaptionWordAnimation.SlideIn && timeMs < geometry.Line.Words[index].StartMs
            ? offset + geometry.FontSize * SlideInDistanceRatio
            : offset;
    }

    private static double TargetWordOpacity(Geometry geometry, int index, double timeMs)
    {
        if (timeMs < geometry.Line.StartMs || timeMs > geometry.Line.EndMs)
        {
            return 0;
        }

        if (geometry.Line.Style.WordsReveal == CaptionWordsReveal.WordByWord)
        {
            return index == PresentWordCount(geometry.Line, timeMs) - 1 ? 1 : 0;
        }

        if (timeMs < geometry.Line.Words[index].StartMs)
        {
            return geometry.Line.Style.WordAnimation == CaptionWordAnimation.FadeIn ? DimmedWordOpacity : 0;
        }

        return 1;
    }

    /// <summary>The line closest to this time: the box stays on it through the pause that follows.</summary>
    private static int NearestLineIndex(List<Line> lines, double timeMs)
    {
        var lo = 0;
        var hi = lines.Count;
        while (lo < hi)
        {
            var mid = (lo + hi) / 2;
            if (lines[mid].StartMs <= timeMs)
            {
                lo = mid + 1;
            }
            else
            {
                hi = mid;
            }
        }

        if (lo == 0)
        {
            return 0;
        }

        var previous = lines[lo - 1];
        if (previous.EndMs >= timeMs || lo >= lines.Count)
        {
            return lo - 1;
        }

        return timeMs - previous.EndMs < lines[lo].StartMs - timeMs ? lo - 1 : lo;
    }

    /// <summary>Stops at the target instead of overshooting, so words and boxes land cleanly.</summary>
    private static void Step(double[] values, double[] velocities, double[] targets)
    {
        for (var index = 0; index < values.Length; index++)
        {
            var before = values[index] - targets[index];
            if (Math.Abs(before) <= 0.0001 && Math.Abs(velocities[index]) <= 0.0001)
            {
                values[index] = targets[index];
                velocities[index] = 0;
                continue;
            }

            var force = -SpringStiffness * before - SpringDamping * velocities[index];
            velocities[index] += force / SpringMass * StepSeconds;
            values[index] += velocities[index] * StepSeconds;
            if (before * (values[index] - targets[index]) < 0)
            {
                values[index] = targets[index];
                velocities[index] = 0;
            }
        }
    }

    private static TrackFrame? Frame(List<Line> lines, double timeMs, double stageWidth, double stageHeight, CaptionTextMeasure measure)
    {
        var wordKeys = new List<(int Line, int Word)>();
        for (var index = 0; index < lines.Count; index++)
        {
            if (lines[index].StartMs - DrawnLineWindowMs <= timeMs && lines[index].EndMs + DrawnLineWindowMs >= timeMs)
            {
                for (var word = 0; word < lines[index].Words.Count; word++)
                {
                    wordKeys.Add((index, word));
                }
            }
        }

        if (wordKeys.Count == 0)
        {
            return null;
        }

        var geometries = new Geometry?[lines.Count];
        Geometry GeometryOf(int index) => geometries[index] ??= new Geometry(lines[index], stageWidth, stageHeight, measure);

        void BoxTargets(double t, double[] into)
        {
            var geometry = GeometryOf(NearestLineIndex(lines, t));
            var content = TargetContentRect(geometry, t);
            into[0] = content.X;
            into[1] = content.Y;
            into[2] = content.Width;
            into[3] = content.Height;
            into[4] = t >= geometry.Line.StartMs && t <= geometry.Line.EndMs ? 1 : 0;
        }

        void WordTargets(double t, double[] into)
        {
            var origin = TargetContentRect(GeometryOf(NearestLineIndex(lines, t)), t);
            for (var index = 0; index < wordKeys.Count; index++)
            {
                var (line, word) = wordKeys[index];
                var geometry = GeometryOf(line);
                into[index * 3] = origin.X + TargetWordOffset(geometry, word, t);
                into[index * 3 + 1] = origin.Y;
                into[index * 3 + 2] = TargetWordOpacity(geometry, word, t);
            }
        }

        // Aligned to an absolute grid so a frame does not depend on how playback reached it.
        var stepMs = StepSeconds * 1000;
        var startStep = Math.Floor((timeMs - SettleWindowMs) / stepMs);
        var steps = Math.Max(0, (int)(Math.Ceiling(timeMs / stepMs) - startStep));
        var startMs = startStep * stepMs;

        var box = new double[5];
        var boxVelocity = new double[5];
        var boxTarget = new double[5];
        var words = new double[wordKeys.Count * 3];
        var wordVelocity = new double[words.Length];
        var wordTarget = new double[words.Length];
        BoxTargets(startMs, box);
        WordTargets(startMs, words);
        for (var step = 0; step < steps; step++)
        {
            var t = startMs + (step + 1) * stepMs;
            BoxTargets(t, boxTarget);
            Step(box, boxVelocity, boxTarget);
            WordTargets(t, wordTarget);
            Step(words, wordVelocity, wordTarget);
        }

        var active = GeometryOf(NearestLineIndex(lines, timeMs));
        var fontSize = active.FontSize;
        var padX = fontSize * BoxPaddingXRatio;
        var padY = fontSize * BoxPaddingYRatio;
        var drawn = new List<DrawnWord>();
        for (var index = 0; index < wordKeys.Count; index++)
        {
            var opacity = words[index * 3 + 2];
            if (opacity <= 0.002)
            {
                continue;
            }

            var (lineIndex, wordIndex) = wordKeys[index];
            var geometry = GeometryOf(lineIndex);
            var word = lines[lineIndex].Words[wordIndex];
            var size = geometry.Sizes[wordIndex];
            drawn.Add(new DrawnWord(
                word.Text,
                new StageRect(words[index * 3], words[index * 3 + 1] + (geometry.Height - size.Height) * 0.5, size.Width, size.Height),
                Math.Min(1, opacity),
                timeMs >= word.StartMs && timeMs <= word.EndMs + 120,
                geometry.Line.Style.WordAnimation == CaptionWordAnimation.FadeIn
                    && geometry.Line.Style.WordsReveal == CaptionWordsReveal.LineByLine
                    && timeMs < word.StartMs));
        }

        var boxOpacity = Math.Clamp(box[4], 0, 1);
        if (boxOpacity <= 0.002 && drawn.Count == 0)
        {
            return null;
        }

        return new TrackFrame(
            active.Line.BlockId,
            active.Line.Style,
            fontSize,
            new StageRect(box[0] - padX, box[1] - padY, box[2] + padX * 2, box[3] + padY * 2),
            boxOpacity,
            drawn);
    }
}
