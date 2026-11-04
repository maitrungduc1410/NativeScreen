namespace NativeScreen.Core;

/// <summary>
/// Voiceover track rules: segments on one track never overlap, and tracks stay numbered 0..count with no empty track.
/// Overlapping voiceovers are allowed, on different tracks, and are mixed on playback and export.
/// </summary>
public static class VoiceoverTrackLayout
{
    public static int TrackCount(IReadOnlyList<VoiceoverSegment> voiceovers)
    {
        var last = -1;
        foreach (var segment in voiceovers)
        {
            last = Math.Max(last, segment.TrackIndex);
        }

        return last + 1;
    }

    public static bool IsRangeFree(IReadOnlyList<VoiceoverSegment> voiceovers, int trackIndex, double startMs, double endMs, string? ignoringId = null)
    {
        foreach (var segment in voiceovers)
        {
            if (segment.Id != ignoringId && segment.TrackIndex == trackIndex && segment.SourceStartMs < endMs && startMs < segment.SourceEndMs)
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>The first track that has room for the range, or a new track after the last one.</summary>
    public static int FirstFreeTrack(IReadOnlyList<VoiceoverSegment> voiceovers, double startMs, double endMs)
    {
        var count = TrackCount(voiceovers);
        for (var track = 0; track < count; track++)
        {
            if (IsRangeFree(voiceovers, track, startMs, endMs))
            {
                return track;
            }
        }

        return count;
    }

    /// <summary>Where a recording goes: its length is not known yet, so the track must have nothing after the start.</summary>
    public static int FirstTrackEmptyAfter(IReadOnlyList<VoiceoverSegment> voiceovers, double startMs)
    {
        var count = TrackCount(voiceovers);
        for (var track = 0; track < count; track++)
        {
            var empty = true;
            foreach (var segment in voiceovers)
            {
                if (segment.TrackIndex == track && segment.SourceEndMs > startMs)
                {
                    empty = false;
                    break;
                }
            }

            if (empty)
            {
                return track;
            }
        }

        return count;
    }

    /// <summary>Applies the rules and closes up empty tracks. A project saved with the single hide flag loads with every track hidden.</summary>
    public static void Normalize(TimelineConfig timeline)
    {
        var placed = new List<VoiceoverSegment>(timeline.Voiceovers.Count);
        foreach (var segment in timeline.Voiceovers.OrderBy(item => item.SourceStartMs))
        {
            // Segments that already fit keep their track, so the result is stable.
            if (!IsRangeFree(placed, segment.TrackIndex, segment.SourceStartMs, segment.SourceEndMs))
            {
                segment.TrackIndex = FirstFreeTrack(placed, segment.SourceStartMs, segment.SourceEndMs);
            }

            placed.Add(segment);
        }

        var used = placed.Select(item => item.TrackIndex).Distinct().Order().ToList();
        if (timeline.IsVoiceoversTrackHidden)
        {
            timeline.HiddenVoiceoverTracks = [.. used];
            timeline.IsVoiceoversTrackHidden = false;
        }

        timeline.HiddenVoiceoverTracks = timeline.HiddenVoiceoverTracks.Select(track => used.IndexOf(track)).Where(index => index >= 0).ToList();
        foreach (var segment in placed)
        {
            segment.TrackIndex = Math.Max(0, used.IndexOf(segment.TrackIndex));
        }

        timeline.Voiceovers = placed;
    }

    public static bool IsTrackHidden(TimelineConfig timeline, int trackIndex) => timeline.HiddenVoiceoverTracks.Contains(trackIndex);

    public static void SetTrackHidden(TimelineConfig timeline, int trackIndex, bool hidden)
    {
        timeline.HiddenVoiceoverTracks.RemoveAll(track => track == trackIndex);
        if (hidden)
        {
            timeline.HiddenVoiceoverTracks.Add(trackIndex);
        }
    }

    /// <summary>Moves a segment to another track, or a new one past the last. It stays put when the target has no room.</summary>
    public static void MoveToTrack(TimelineConfig timeline, string id, int targetTrack)
    {
        if (timeline.Voiceovers.Find(item => item.Id == id) is not { } segment)
        {
            return;
        }

        var target = Math.Clamp(targetTrack, 0, TrackCount(timeline.Voiceovers));
        if (target != segment.TrackIndex && IsRangeFree(timeline.Voiceovers, target, segment.SourceStartMs, segment.SourceEndMs, id))
        {
            segment.TrackIndex = target;
            Normalize(timeline);
        }
    }
}
