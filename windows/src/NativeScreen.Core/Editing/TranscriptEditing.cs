using System.Globalization;
using System.Text;

namespace NativeScreen.Core;

/// <summary>Cutting and restoring source ranges, and what the transcript offers to cut. Same rules as ProjectSession on macOS.</summary>
public static class TranscriptEditing
{
    private const double MinimumSliceMs = 150;
    private const double MinimumPauseMs = 800;
    private const double FillerMarginMs = 25;
    private const double PauseKeepMs = 100;
    private const double MinimumPauseCutMs = 120;
    private const double PresenceToleranceMs = 15;
    private const double RestoreToleranceMs = 120;

    private static readonly HashSet<string> Fillers =
    [
        "um", "uh", "er", "ah", "hmm", "mhmm", "mm", "mmm", "huh", "uh-huh", "erm", "umm", "uhh", "ờ", "à", "ừm"
    ];

    public static bool IsFillerWord(string text)
    {
        var cleaned = text.ToLowerInvariant().Trim();
        cleaned = cleaned.Trim(cleaned.Where(character => char.IsPunctuation(character) || char.IsWhiteSpace(character)).Distinct().ToArray());
        return Fillers.Contains(cleaned);
    }

    public static void CutSourceRange(ProjectDocument document, double cutStartMs, double cutEndMs)
    {
        var updated = new List<ClipSlice>();
        foreach (var slice in document.Timeline.Slices)
        {
            if (cutEndMs <= slice.SourceStartMs || cutStartMs >= slice.SourceEndMs)
            {
                updated.Add(slice);
                continue;
            }

            var left = cutStartMs - slice.SourceStartMs;
            var right = slice.SourceEndMs - cutEndMs;
            if (left >= MinimumSliceMs && right >= MinimumSliceMs)
            {
                var first = ProjectJson.Clone(slice);
                first.Id = EditorSession.NewId();
                first.SourceEndMs = cutStartMs;
                var second = ProjectJson.Clone(slice);
                second.Id = EditorSession.NewId();
                second.SourceStartMs = cutEndMs;
                updated.Add(first);
                updated.Add(second);
            }
            else if (left >= MinimumSliceMs)
            {
                slice.SourceEndMs = cutStartMs;
                updated.Add(slice);
            }
            else if (right >= MinimumSliceMs)
            {
                slice.SourceStartMs = cutEndMs;
                updated.Add(slice);
            }
        }

        // A project never loses all of its video.
        if (updated.Count > 0)
        {
            document.Timeline.Slices = updated;
        }
    }

    public static void RestoreSourceRange(ProjectDocument document, double startMs, double endMs, double maxDurationMs)
    {
        var start = Math.Max(0, startMs);
        var end = Math.Min(maxDurationMs, endMs);
        if (end <= start + 40)
        {
            return;
        }

        var slices = document.Timeline.Slices.OrderBy(slice => slice.SourceStartMs).ToList();
        var previous = slices.FindLastIndex(slice => slice.SourceEndMs <= start + RestoreToleranceMs);
        if (previous >= 0)
        {
            if (previous + 1 < slices.Count && slices[previous + 1].SourceStartMs <= end + RestoreToleranceMs)
            {
                slices[previous].SourceEndMs = slices[previous + 1].SourceEndMs;
                slices.RemoveAt(previous + 1);
            }
            else
            {
                slices[previous].SourceEndMs = Math.Max(slices[previous].SourceEndMs, end);
            }

            document.Timeline.Slices = slices;
            return;
        }

        var next = slices.FindIndex(slice => slice.SourceStartMs >= end - RestoreToleranceMs);
        if (next >= 0)
        {
            slices[next].SourceStartMs = Math.Min(slices[next].SourceStartMs, start);
            document.Timeline.Slices = slices;
        }
    }

    public static bool IsRangePresent(ProjectDocument document, double startMs, double endMs) =>
        document.Timeline.Slices.Exists(slice => Math.Min(endMs, slice.SourceEndMs) > Math.Max(startMs, slice.SourceStartMs) + PresenceToleranceMs);

    public static List<CaptionSegment> PresentFillers(ProjectDocument document) =>
        document.Captions.Segments.Where(segment => IsFillerWord(segment.Text) && IsRangePresent(document, segment.SourceStartMs, segment.SourceEndMs)).ToList();

    public static List<(double StartMs, double EndMs)> TightenablePauses(ProjectDocument document)
    {
        var segments = document.Captions.Segments.OrderBy(segment => segment.SourceStartMs).ToList();
        var pauses = new List<(double, double)>();
        for (var index = 0; index + 1 < segments.Count; index++)
        {
            var start = segments[index].SourceEndMs;
            var end = segments[index + 1].SourceStartMs;
            if (end - start >= MinimumPauseMs && IsRangePresent(document, start + PauseKeepMs, end - PauseKeepMs))
            {
                pauses.Add((start, end));
            }
        }

        return pauses;
    }

    public static void RemoveFillers(ProjectDocument document, double maxDurationMs)
    {
        foreach (var filler in Enumerable.Reverse(PresentFillers(document)))
        {
            CutSourceRange(document, Math.Max(0, filler.SourceStartMs - FillerMarginMs), Math.Min(maxDurationMs, filler.SourceEndMs + FillerMarginMs));
        }
    }

    /// <summary>Shortens each long pause to a 200 ms breath, 100 ms on each side.</summary>
    public static void TightenPauses(ProjectDocument document)
    {
        foreach (var (start, end) in Enumerable.Reverse(TightenablePauses(document)))
        {
            var from = start + PauseKeepMs;
            var to = end - PauseKeepMs;
            if (to > from + MinimumPauseCutMs)
            {
                CutSourceRange(document, from, to);
            }
        }
    }

    /// <summary>SubRip on the edited timeline: lines of up to 7 words, broken at sentence ends and pauses of 800 ms.</summary>
    public static string FormatSrt(IReadOnlyList<CaptionSegment> segments, NLETimeMapper mapper)
    {
        var lines = new List<(double Start, double End, string Text)>();
        var words = new List<CaptionSegment>();

        void Flush()
        {
            if (words.Count > 0 && mapper.TimelineTime(words[0].SourceStartMs) is { } start && mapper.TimelineTime(words[^1].SourceEndMs) is { } end && end > start)
            {
                lines.Add((start, end, string.Join(' ', words.Select(word => word.Text))));
            }

            words.Clear();
        }

        foreach (var segment in segments.Where(item => !item.IsHidden))
        {
            if (words.Count > 0)
            {
                var previous = words[^1];
                var endsSentence = previous.Text.EndsWith('.') || previous.Text.EndsWith('?') || previous.Text.EndsWith('!');
                if (segment.SourceStartMs - previous.SourceEndMs >= MinimumPauseMs || endsSentence || words.Count >= 7)
                {
                    Flush();
                }
            }

            words.Add(segment);
        }

        Flush();
        var output = new StringBuilder();
        for (var index = 0; index < lines.Count; index++)
        {
            if (index > 0)
            {
                output.Append("\n\n");
            }

            output.Append(CultureInfo.InvariantCulture, $"{index + 1}\n{Timestamp(lines[index].Start)} --> {Timestamp(lines[index].End)}\n{lines[index].Text}");
        }

        return output.ToString();
    }

    private static string Timestamp(double ms)
    {
        var total = Math.Max(0, (int)Math.Round(ms));
        return string.Create(CultureInfo.InvariantCulture, $"{total / 3_600_000:00}:{total % 3_600_000 / 60_000:00}:{total % 60_000 / 1000:00},{total % 1000:000}");
    }
}

/// <summary>Applying a suggestion from ShortcutEngine.TypingSuggestions. Same thresholds as macOS.</summary>
public static class TypingSuggestionEdits
{
    public static double ClampSpeed(double speed) => Math.Clamp(Math.Round(speed * 10) / 10, 1.5, 8);

    public static void Apply(ProjectDocument document, TypingSuggestion suggestion, double speed)
    {
        SpeedUp(document, suggestion.SourceStartMs, suggestion.SourceEndMs, ClampSpeed(speed));
        Dismiss(document, suggestion);
    }

    public static void Dismiss(ProjectDocument document, TypingSuggestion suggestion)
    {
        if (!document.Timeline.DismissedTypingSuggestionStarts.Contains(suggestion.StartKeyMs))
        {
            document.Timeline.DismissedTypingSuggestionStarts.Add(suggestion.StartKeyMs);
        }
    }

    private static void SpeedUp(ProjectDocument document, double startMs, double endMs, double speed)
    {
        var slices = document.Timeline.Slices;
        var index = slices.FindIndex(item => startMs >= item.SourceStartMs + 100 && endMs <= item.SourceEndMs - 100);
        if (endMs - startMs < 300 || index < 0)
        {
            return;
        }

        var original = slices[index];
        var before = ProjectJson.Clone(original);
        before.Id = EditorSession.NewId();
        before.SourceEndMs = startMs;
        var typing = ProjectJson.Clone(original);
        typing.Id = EditorSession.NewId();
        typing.SourceStartMs = startMs;
        typing.SourceEndMs = endMs;
        typing.Speed = speed;
        var after = ProjectJson.Clone(original);
        after.Id = EditorSession.NewId();
        after.SourceStartMs = endMs;
        slices.RemoveAt(index);
        slices.InsertRange(index, [before, typing, after]);
    }
}

/// <summary>Turns detections on sampled frames into tracked masks. Pure, so OCR and face results can be tested without a video.</summary>
public static class AutoMaskBuilder
{
    public static readonly string[] SensitivePatterns =
    [
        "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",
        "\\b(?:sk-[a-zA-Z0-9_-]{12,}|pk_live_[a-zA-Z0-9]{12,}|rk_live_[a-zA-Z0-9]{12,}|gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{20,}|AIza[0-9A-Za-z\\-_]{25,}|AKIA[0-9A-Z]{16}|xox[baprs]-[0-9a-zA-Z-]{10,}|eyJ[A-Za-z0-9_-]{16,}\\.[A-Za-z0-9_-]{16,})\\b",
        "\\b(?:\\d[ -]*?){13,19}\\b",
        "(?:\\+?\\d{1,3}[\\s.-]?)?\\(?\\d{3}\\)?[\\s.-]\\d{3}[\\s.-]\\d{4}\\b"
    ];

    public static IReadOnlyList<double> SensitiveSampleTimes(double durationMs) => SampleTimes(durationMs, Math.Max(1000, Math.Min(2500, Math.Max(1000, durationMs) / 8)));

    public static IReadOnlyList<double> FaceSampleTimes(double durationMs) => SampleTimes(durationMs, Math.Max(900, Math.Min(2000, Math.Max(1000, durationMs) / 8)));

    public static double SensitiveStepMs(double durationMs) => Math.Max(1000, Math.Min(2500, Math.Max(1000, durationMs) / 8));

    public static double FaceStepMs(double durationMs) => Math.Max(900, Math.Min(2000, Math.Max(1000, durationMs) / 8));

    /// <summary>Same box growth as macOS, 0.008 and 0.006 of the frame, dropping specks.</summary>
    public static Rect01? PadSensitive(double x, double y, double width, double height)
    {
        var left = Math.Max(0, x - 0.008);
        var top = Math.Max(0, y - 0.006);
        var w = Math.Min(1 - left, width + 0.016);
        var h = Math.Min(1 - top, height + 0.012);
        return w >= 0.015 && h >= 0.010 ? new Rect01(left, top, w, h) : null;
    }

    public static Rect01 PadFace(double x, double y, double width, double height)
    {
        var padX = width * 0.14;
        var padY = height * 0.18;
        var left = Math.Max(0, x - padX);
        var top = Math.Max(0, y - padY);
        return new Rect01(left, top, Math.Min(1 - left, width + padX * 2), Math.Min(1 - top, height + padY * 2));
    }

    public static void AddSensitiveHit(List<MaskItem> masks, double sampleMs, double stepMs, double totalMs, Rect01 rect)
    {
        var start = Math.Max(0, sampleMs - stepMs * 0.55);
        var end = Math.Min(totalMs, sampleMs + stepMs * 0.65);
        var existing = masks.Find(mask =>
        {
            var last = mask.Keyframes[^1].Rect01.Center;
            return Math.Abs(last.X - rect.Center.X) < 0.08 && Math.Abs(last.Y - rect.Center.Y) < 0.05 && start <= mask.SourceEndMs + stepMs * 0.75;
        });
        if (existing is not null)
        {
            existing.SourceEndMs = Math.Max(existing.SourceEndMs, end);
            existing.Keyframes.Add(new MaskKeyframe { SourceMs = (start + end) * 0.5, Rect01 = rect });
            return;
        }

        masks.Add(new MaskItem
        {
            Id = EditorSession.NewId(),
            SourceStartMs = start,
            SourceEndMs = Math.Max(start + 600, end),
            Type = MaskType.Blur,
            Style = MaskStyle.Gaussian,
            Intensity = 44,
            CornerRadius = 8,
            Keyframes = [new MaskKeyframe { SourceMs = start, Rect01 = rect }],
            IsAutoSensitiveMask = true
        });
    }

    public static void AddFaceHit(List<MaskItem> masks, double sampleMs, double stepMs, double totalMs, Rect01 rect)
    {
        var start = Math.Max(0, sampleMs - stepMs * 0.55);
        var end = Math.Min(totalMs, sampleMs + stepMs * 0.65);
        var existing = masks.Find(mask =>
        {
            var last = mask.Keyframes[^1].Rect01.Center;
            var distance = Math.Sqrt(Math.Pow(last.X - rect.Center.X, 2) + Math.Pow(last.Y - rect.Center.Y, 2));
            return distance < 0.10 && start <= mask.SourceEndMs + stepMs * 0.75;
        });
        if (existing is not null)
        {
            existing.SourceEndMs = Math.Max(existing.SourceEndMs, end);
            existing.Keyframes.Add(new MaskKeyframe { SourceMs = sampleMs, Rect01 = rect });
            return;
        }

        masks.Add(new MaskItem
        {
            Id = EditorSession.NewId(),
            SourceStartMs = start,
            SourceEndMs = Math.Max(start + 600, end),
            Type = MaskType.Blur,
            Style = MaskStyle.Gaussian,
            Intensity = 48,
            CornerRadius = 48,
            Keyframes = [new MaskKeyframe { SourceMs = sampleMs, Rect01 = rect }],
            IsAutoFaceMask = true
        });
    }

    /// <summary>Replaces one kind of automatic mask in the document, in a track of its own.</summary>
    public static void Replace(ProjectDocument document, Predicate<MaskItem> kind, List<MaskItem> detected)
    {
        foreach (var track in document.Timeline.MaskTracks)
        {
            track.Items.RemoveAll(kind);
        }

        if (detected.Count > 0)
        {
            var name = document.Timeline.MaskTracks.Count == 0 ? "Masks" : $"Masks {document.Timeline.MaskTracks.Count + 1}";
            document.Timeline.MaskTracks.Add(new MaskTrack { Id = EditorSession.NewId(), Name = name, Items = detected });
        }
    }

    private static List<double> SampleTimes(double durationMs, double stepMs)
    {
        var total = Math.Max(1000, durationMs);
        var times = new List<double>();
        for (var t = 200.0; t < total; t += stepMs)
        {
            times.Add(t);
        }

        return times.Count == 0 ? [0] : times;
    }
}

/// <summary>Word timings from a speech engine, cleaned for the transcript. Same rules as normalizeWordSegments on macOS.</summary>
public static class TranscriptSegments
{
    public static List<CaptionSegment> Normalize(IEnumerable<(string Text, double StartMs, double EndMs)> words, double maxDurationMs)
    {
        var results = new List<CaptionSegment>();
        foreach (var (text, start, end) in words.OrderBy(word => word.StartMs))
        {
            var cleaned = text.Trim();
            if (cleaned.Length == 0)
            {
                continue;
            }

            var from = Math.Clamp(start, 0, maxDurationMs);
            var to = Math.Clamp(Math.Max(end, from + 40), 0, maxDurationMs);
            if (to > from)
            {
                results.Add(new CaptionSegment { Id = EditorSession.NewId(), SourceStartMs = from, SourceEndMs = to, Text = cleaned });
            }
        }

        return results;
    }
}

/// <summary>
/// Where speech is in an audio track. Whisper places words wrongly after long silence, up to the whole length of the silence,
/// so each region is transcribed on its own and its words are shifted by the region's start (spec/06 ADR-25).
/// </summary>
public static class SpeechRegions
{
    private const double WindowMs = 30;
    private const double MergeGapMs = 700;
    private const double PaddingMs = 200;
    private const float RelativeThreshold = 0.05f;
    private const float AbsoluteThreshold = 0.002f;

    public static List<(int Start, int Length)> Find(float[] samples, int sampleRate)
    {
        var window = Math.Max(1, (int)(WindowMs / 1000 * sampleRate));
        var count = samples.Length / window;
        var levels = new float[count];
        var loudest = 0f;
        for (var index = 0; index < count; index++)
        {
            var sum = 0f;
            for (var at = index * window; at < (index + 1) * window; at++)
            {
                sum += samples[at] * samples[at];
            }

            levels[index] = MathF.Sqrt(sum / window);
            loudest = Math.Max(loudest, levels[index]);
        }

        var threshold = Math.Max(AbsoluteThreshold, loudest * RelativeThreshold);
        var mergeGap = (int)(MergeGapMs / WindowMs);
        var padding = (int)(PaddingMs / 1000 * sampleRate);
        var regions = new List<(int Start, int Length)>();
        var first = -1;
        var last = -1;

        void Close()
        {
            var start = Math.Max(0, first * window - padding);
            var end = Math.Min(samples.Length, (last + 1) * window + padding);
            regions.Add((start, end - start));
        }

        for (var index = 0; index < count; index++)
        {
            if (levels[index] < threshold)
            {
                continue;
            }

            if (first >= 0 && index - last > mergeGap)
            {
                Close();
                first = -1;
            }

            first = first < 0 ? index : first;
            last = index;
        }

        if (first >= 0)
        {
            Close();
        }

        return regions;
    }
}

/// <summary>Peak levels per bin for the timeline, normalized to the loudest bin.</summary>
public static class Waveform
{
    public static float[] Normalize(float[] peaks)
    {
        var loudest = 0f;
        foreach (var peak in peaks)
        {
            loudest = Math.Max(loudest, peak);
        }

        if (loudest > 0.0001f)
        {
            for (var index = 0; index < peaks.Length; index++)
            {
                peaks[index] /= loudest;
            }
        }

        return peaks;
    }

    public static int BinCount(double durationMs) => Math.Clamp((int)(durationMs / 1000 * 240), 256, 16384);
}
