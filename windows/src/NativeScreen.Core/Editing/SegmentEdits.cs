namespace NativeScreen.Core;

/// <summary>What the timeline's context menus do to a segment. Same limits and messages as ProjectSession on macOS.</summary>
public static class SegmentEdits
{
    private const double MinimumSplitSideMs = 200;
    private const double MinimumMaskSplitSideMs = 180;
    private const double MinimumDuplicateGapMs = 300;
    public const double MinimumVoiceoverMs = 250;
    private const double MinimumHalvableMs = 500;
    private const double TrackOverlapToleranceMs = 20;

    public static void MergeSliceWithNext(ProjectDocument document, string id)
    {
        var slices = document.Timeline.Slices;
        var index = slices.FindIndex(slice => slice.Id == id);
        if (index >= 0 && index + 1 < slices.Count)
        {
            slices[index].SourceEndMs = Math.Max(slices[index].SourceEndMs, slices[index + 1].SourceEndMs);
            slices.RemoveAt(index + 1);
        }
    }

    public static void ResetSliceTrim(ProjectDocument document, string id, double maxDurationMs)
    {
        var slices = document.Timeline.Slices;
        var index = slices.FindIndex(slice => slice.Id == id);
        if (index < 0)
        {
            return;
        }

        var previousEnd = index > 0 ? slices[index - 1].SourceEndMs : 0;
        var nextStart = index + 1 < slices.Count ? slices[index + 1].SourceStartMs : maxDurationMs;
        if (nextStart > previousEnd + 100)
        {
            slices[index].SourceStartMs = previousEnd;
            slices[index].SourceEndMs = nextStart;
        }
    }

    public static void ResetAllSlices(ProjectDocument document, double maxDurationMs) =>
        document.Timeline.Slices = [new ClipSlice { Id = EditorSession.NewId(), SourceStartMs = 0, SourceEndMs = maxDurationMs, Speed = 1 }];

    /// <summary>
    /// Volume sliders never set Muted: it silences every source of the slice, so the system audio slider at 0 used to mute the
    /// microphone too. Moving a slider clears a mute left that way (spec/06 ADR-47).
    /// </summary>
    public static void SetSliceSystemAudioVolume(ClipSlice slice, double volume)
    {
        slice.SystemAudioVolume = Math.Clamp(volume, 0, 1);
        slice.Muted = false;
    }

    public static void SetSliceMicrophoneVolume(ClipSlice slice, double volume)
    {
        slice.MicrophoneVolume = Math.Clamp(volume, 0, 1);
        slice.Muted = false;
    }

    /// <summary>Returns the second half's id, or null when a side would be too short.</summary>
    public static string? SplitZoom(ProjectDocument document, string id, double sourceMs)
    {
        var zooms = document.Timeline.Zooms;
        var index = zooms.FindIndex(zoom => zoom.Id == id);
        if (index < 0 || sourceMs <= zooms[index].SourceStartMs + MinimumSplitSideMs || sourceMs >= zooms[index].SourceEndMs - MinimumSplitSideMs)
        {
            return null;
        }

        var second = ProjectJson.Clone(zooms[index]);
        second.Id = EditorSession.NewId();
        second.SourceStartMs = sourceMs;
        zooms[index].SourceEndMs = sourceMs;
        zooms.Insert(index + 1, second);
        return second.Id;
    }

    public static bool CanSplitVoiceover(VoiceoverSegment voiceover, double sourceMs) =>
        sourceMs > voiceover.SourceStartMs + MinimumSplitSideMs && sourceMs < voiceover.SourceEndMs - MinimumSplitSideMs;

    /// <summary>Both halves share the original's audio file (spec/06 ADR-59).</summary>
    public static void SplitVoiceover(ProjectDocument document, string id, double sourceMs, string firstId, string secondId)
    {
        var voiceovers = document.Timeline.Voiceovers;
        var index = voiceovers.FindIndex(item => item.Id == id);
        if (index < 0 || !CanSplitVoiceover(voiceovers[index], sourceMs))
        {
            return;
        }

        var original = voiceovers[index];
        var first = ProjectJson.Clone(original);
        first.Id = firstId;
        first.DurationMs = sourceMs - original.SourceStartMs;
        var second = ProjectJson.Clone(original);
        second.Id = secondId;
        // Exactly at the first half's end: a rounding gap the other way would count as an overlap and move it to a new track.
        second.SourceStartMs = first.SourceEndMs;
        second.DurationMs = original.SourceEndMs - second.SourceStartMs;
        second.FileOffsetMs = original.FileOffsetMs + first.DurationMs;
        voiceovers[index] = first;
        voiceovers.Insert(index + 1, second);
    }

    /// <summary>Trims by either edge. The audio stays where it is on the timeline, so the left edge moves the start point in the file and stops where the file begins.</summary>
    public static void ResizeVoiceover(ProjectDocument document, string id, double newStartMs, double newEndMs, double sourceDurationMs)
    {
        var voiceovers = document.Timeline.Voiceovers;
        if (voiceovers.Find(item => item.Id == id) is not { } current)
        {
            return;
        }

        var slices = document.Timeline.Slices;
        var earliest = slices.Count == 0 ? 0 : slices.Min(slice => slice.SourceStartMs);
        var latest = slices.Count == 0 ? sourceDurationMs : slices.Max(slice => slice.SourceEndMs);
        var others = voiceovers.Where(item => item.TrackIndex == current.TrackIndex && item.Id != id).ToList();
        var previousEnd = others.Where(item => item.SourceStartMs < current.SourceStartMs).Select(item => item.SourceEndMs).DefaultIfEmpty(earliest).Max();
        var nextStart = others.Where(item => item.SourceStartMs > current.SourceStartMs).Select(item => item.SourceStartMs).DefaultIfEmpty(latest).Min();
        var start = Math.Max(Math.Max(earliest, previousEnd), Math.Max(current.SourceStartMs - current.FileOffsetMs, newStartMs));
        var end = Math.Min(Math.Min(latest, nextStart), newEndMs);
        if (end - start < MinimumVoiceoverMs)
        {
            return;
        }

        current.FileOffsetMs = current.FileOffsetMs + start - current.SourceStartMs;
        current.SourceStartMs = start;
        current.DurationMs = end - start;
    }

    public static string? SplitMask(ProjectDocument document, string id, double sourceMs)
    {
        foreach (var track in document.Timeline.MaskTracks)
        {
            var index = track.Items.FindIndex(item => item.Id == id);
            if (index < 0)
            {
                continue;
            }

            var original = track.Items[index];
            if (sourceMs <= original.SourceStartMs + MinimumMaskSplitSideMs || sourceMs >= original.SourceEndMs - MinimumMaskSplitSideMs)
            {
                return null;
            }

            var rect = original.InterpolatedRect(sourceMs);
            var second = ProjectJson.Clone(original);
            second.Id = EditorSession.NewId();
            second.SourceStartMs = sourceMs;
            second.Keyframes = [new MaskKeyframe { SourceMs = sourceMs, Rect01 = new Rect01(rect.X, rect.Y, rect.Width, rect.Height) }];
            original.SourceEndMs = sourceMs;
            track.Items.Insert(index + 1, second);
            return second.Id;
        }

        return null;
    }

    public static string? SplitLayout(ProjectDocument document, string id, double sourceMs)
    {
        var layouts = document.Timeline.CameraLayouts;
        var index = layouts.FindIndex(layout => layout.Id == id);
        if (index < 0 || sourceMs <= layouts[index].SourceStartMs + MinimumSplitSideMs || sourceMs >= layouts[index].SourceEndMs - MinimumSplitSideMs)
        {
            return null;
        }

        var second = ProjectJson.Clone(layouts[index]);
        second.Id = EditorSession.NewId();
        second.SourceStartMs = sourceMs;
        layouts[index].SourceEndMs = sourceMs;
        layouts.Insert(index + 1, second);
        return second.Id;
    }

    public static string? DuplicateZoom(ProjectDocument document, string id, double maxDurationMs)
    {
        var zooms = document.Timeline.Zooms;
        var sorted = zooms.OrderBy(zoom => zoom.SourceStartMs).ToList();
        var at = sorted.FindIndex(zoom => zoom.Id == id);
        if (at < 0)
        {
            return null;
        }

        var original = sorted[at];
        var nextStart = at + 1 < sorted.Count ? sorted[at + 1].SourceStartMs : maxDurationMs;
        var copy = ProjectJson.Clone(original);
        copy.Id = EditorSession.NewId();
        if (nextStart - original.SourceEndMs >= MinimumDuplicateGapMs)
        {
            copy.SourceStartMs = original.SourceEndMs;
            copy.SourceEndMs = Math.Min(nextStart, original.SourceEndMs + (original.SourceEndMs - original.SourceStartMs));
        }
        else if (original.SourceEndMs - original.SourceStartMs >= MinimumHalvableMs)
        {
            var middle = (original.SourceStartMs + original.SourceEndMs) * 0.5;
            copy.SourceStartMs = middle;
            original.SourceEndMs = middle;
        }
        else
        {
            return null;
        }

        zooms.Add(copy);
        zooms.Sort((a, b) => a.SourceStartMs.CompareTo(b.SourceStartMs));
        return copy.Id;
    }

    public static string? DuplicateLayout(ProjectDocument document, string id, double maxDurationMs)
    {
        var layouts = document.Timeline.CameraLayouts;
        var sorted = layouts.OrderBy(layout => layout.SourceStartMs).ToList();
        var at = sorted.FindIndex(layout => layout.Id == id);
        if (at < 0)
        {
            return null;
        }

        var original = sorted[at];
        var nextStart = at + 1 < sorted.Count ? sorted[at + 1].SourceStartMs : maxDurationMs;
        var copy = ProjectJson.Clone(original);
        copy.Id = EditorSession.NewId();
        if (nextStart - original.SourceEndMs >= MinimumDuplicateGapMs)
        {
            copy.SourceStartMs = original.SourceEndMs;
            copy.SourceEndMs = Math.Min(nextStart, original.SourceEndMs + (original.SourceEndMs - original.SourceStartMs));
        }
        else if (original.SourceEndMs - original.SourceStartMs >= MinimumHalvableMs)
        {
            var middle = (original.SourceStartMs + original.SourceEndMs) * 0.5;
            copy.SourceStartMs = middle;
            original.SourceEndMs = middle;
        }
        else
        {
            return null;
        }

        layouts.Add(copy);
        layouts.Sort((a, b) => a.SourceStartMs.CompareTo(b.SourceStartMs));
        return copy.Id;
    }

    public static string? DuplicateShortcut(ProjectDocument document, ShortcutCluster cluster, IReadOnlyList<ShortcutCluster> clusters, double maxDurationMs)
    {
        var latest = document.Timeline.Slices.Select(slice => slice.SourceEndMs).DefaultIfEmpty(maxDurationMs).Max();
        var sorted = clusters.Where(item => item.TrackId == cluster.TrackId).OrderBy(item => item.DisplayStartMs).ToList();
        var at = sorted.FindIndex(item => item.Id == cluster.Id);
        if (at < 0)
        {
            return null;
        }

        var nextStart = at + 1 < sorted.Count ? sorted[at + 1].DisplayStartMs : latest;
        var length = Math.Max(MinimumDuplicateGapMs, cluster.DisplayEndMs - cluster.DisplayStartMs);
        double start;
        double end;
        if (nextStart - cluster.DisplayEndMs >= MinimumDuplicateGapMs)
        {
            start = cluster.DisplayEndMs;
            end = Math.Min(nextStart, start + length);
        }
        else if (length >= MinimumHalvableMs)
        {
            start = (cluster.DisplayStartMs + cluster.DisplayEndMs) * 0.5;
            end = cluster.DisplayEndMs;
            TimelineEdits.SetShortcutRange(document, cluster, cluster.DisplayStartMs, start);
        }
        else
        {
            return null;
        }

        var style = document.Captions.ShortcutStyleOverrides.GetValueOrDefault(cluster.Id)
            ?? document.Captions.CustomShortcuts.Find(item => item.Id == cluster.Id)?.CustomStyle;
        var copy = new CustomShortcutSegment
        {
            Id = EditorSession.NewId(),
            TrackId = cluster.TrackId,
            SourceStartMs = start,
            SourceEndMs = end,
            Modifiers = cluster.Modifiers.ToList(),
            PrimaryKey = cluster.PrimaryKey,
            CustomStyle = style
        };
        document.Captions.CustomShortcuts.Add(copy);
        return copy.Id;
    }

    public static bool IsShortcutHidden(ProjectDocument document, ShortcutCluster cluster) =>
        document.Captions.CustomShortcuts.Find(item => item.Id == cluster.Id) is { } custom
            ? custom.IsHidden
            : document.Captions.HiddenShortcutStartMs.Contains(cluster.FirstKeyDownMsInt);

    public static void SetShortcutHidden(ProjectDocument document, ShortcutCluster cluster, bool hidden)
    {
        var captions = document.Captions;
        if (captions.CustomShortcuts.Find(item => item.Id == cluster.Id) is { } custom)
        {
            custom.IsHidden = hidden;
        }
        else if (hidden)
        {
            if (!captions.HiddenShortcutStartMs.Contains(cluster.FirstKeyDownMsInt))
            {
                captions.HiddenShortcutStartMs.Add(cluster.FirstKeyDownMsInt);
            }
        }
        else
        {
            captions.HiddenShortcutStartMs.RemoveAll(ms => ms == cluster.FirstKeyDownMsInt);
        }
    }

    /// <summary>
    /// Moves a mask to another row. A row past either end becomes a new track. A row that is busy at that time leaves the mask
    /// where it was. Tracks left empty are removed by the session.
    /// </summary>
    public static void MoveMaskToTrack(ProjectDocument document, string maskId, int targetTrack)
    {
        var tracks = document.Timeline.MaskTracks;
        var sourceIndex = tracks.FindIndex(track => track.Items.Exists(item => item.Id == maskId));
        if (sourceIndex < 0 || targetTrack == sourceIndex)
        {
            return;
        }

        var mask = tracks[sourceIndex].Items.First(item => item.Id == maskId);
        tracks[sourceIndex].Items.Remove(mask);
        if (targetTrack < 0)
        {
            tracks.Insert(0, new MaskTrack { Id = EditorSession.NewId(), Name = "Masks", Items = [mask] });
        }
        else if (targetTrack >= tracks.Count)
        {
            tracks.Add(new MaskTrack { Id = EditorSession.NewId(), Name = $"Masks {tracks.Count + 1}", Items = [mask] });
        }
        else if (tracks[targetTrack].Items.Exists(other => !(mask.SourceEndMs <= other.SourceStartMs + TrackOverlapToleranceMs || mask.SourceStartMs >= other.SourceEndMs - TrackOverlapToleranceMs)))
        {
            tracks[sourceIndex].Items.Add(mask);
            tracks[sourceIndex].Items.Sort((a, b) => a.SourceStartMs.CompareTo(b.SourceStartMs));
        }
        else
        {
            tracks[targetTrack].Items.Add(mask);
            tracks[targetTrack].Items.Sort((a, b) => a.SourceStartMs.CompareTo(b.SourceStartMs));
        }
    }

    public static void SetMaskType(MaskItem mask, MaskType type)
    {
        mask.Type = type;
        if (type == MaskType.Spotlight)
        {
            mask.Style = MaskStyle.Dim;
        }
        else if (mask.Style == MaskStyle.Dim)
        {
            mask.Style = MaskStyle.Gaussian;
        }
    }
}
