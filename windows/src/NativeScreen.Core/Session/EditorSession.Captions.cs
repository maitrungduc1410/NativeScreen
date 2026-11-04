namespace NativeScreen.Core;

/// <summary>Caption tracks: same rules as ProjectSession on macOS.</summary>
public sealed partial class EditorSession
{
    public const double MinimumCaptionMs = 220;
    private const double NewCaptionMs = 2000;

    public string? SelectedCaptionId { get; private set; }

    public CaptionBlock? SelectedCaption => SelectedCaptionId is { } id ? Document.Captions.CaptionBlocks.Find(item => item.Id == id) : null;

    public void SelectCaption(string? id)
    {
        ClearSelectionState();
        SelectedCaptionId = id;
        SelectedTab = id is null ? SelectedTab : InspectorTab.Captions;
        SelectionChanged?.Invoke();
    }

    /// <summary>The slices' extent: a caption never reaches past what the recording still shows.</summary>
    private (double Start, double End) CaptionSourceBounds()
    {
        var slices = Document.Timeline.Slices;
        return slices.Count == 0
            ? (0, Math.Max(500, SourceDurationMs))
            : (slices.Min(slice => slice.SourceStartMs), slices.Max(slice => slice.SourceEndMs));
    }

    /// <summary>Free space around a caption on its track. Captions on one track never overlap.</summary>
    public (double Low, double High) CaptionNeighborBounds(string blockId, string trackId, double aroundMs)
    {
        var bounds = CaptionSourceBounds();
        var low = bounds.Start;
        var high = bounds.End;
        foreach (var other in Document.Captions.CaptionBlocks)
        {
            if (other.TrackId == trackId && other.Id != blockId)
            {
                if (other.SourceStartMs < aroundMs)
                {
                    low = Math.Max(low, other.SourceEndMs);
                }
                else
                {
                    high = Math.Min(high, other.SourceStartMs);
                }
            }
        }

        return (low, high);
    }

    /// <summary>A second track at the same spot would cover the first.</summary>
    private static CaptionStyle StyleForNewTrack(CaptionStyle from)
    {
        var style = ProjectJson.Clone(from);
        style.Position01 = Math.Abs(from.Position01.Y - 1) < 0.1 ? new Point01(0.5, 0) : CaptionStyle.BottomPosition01;
        return style;
    }

    /// <summary>A track always holds a caption, so a new one starts with one at the playhead, kept whole near the end.</summary>
    public string AddCaptionTrack()
    {
        var tracks = Document.Captions.CaptionTracks;
        var bounds = CaptionSourceBounds();
        var start = Math.Max(bounds.Start, Math.Min(SourceAtPlayhead, bounds.End - NewCaptionMs));
        var end = Math.Min(bounds.End, start + NewCaptionMs);
        var created = new CaptionTrack
        {
            Id = NewId(),
            Name = tracks.Count == 0 ? "Captions" : $"Captions {tracks.Count + 1}",
            Style = tracks.Count == 0 ? new CaptionStyle() : StyleForNewTrack(tracks[^1].Style)
        };
        var block = new CaptionBlock { Id = NewId(), TrackId = created.Id, SourceStartMs = start, SourceEndMs = end, CustomText = "New caption" };
        Mutate(document =>
        {
            document.Captions.Enabled = true;
            document.Captions.CaptionTracks.Add(created);
            document.Captions.CaptionBlocks.Add(block);
        });
        SelectCaption(block.Id);
        return created.Id;
    }

    public void DeleteCaptionTrack(string id)
    {
        if (SelectedCaption?.TrackId == id)
        {
            SelectedCaptionId = null;
        }

        Mutate(document =>
        {
            document.Captions.CaptionTracks.RemoveAll(track => track.Id == id);
            document.Captions.CaptionBlocks.RemoveAll(block => block.TrackId == id);
        });
    }

    public void ToggleCaptionTrackHidden(string id) => Mutate(document =>
    {
        if (document.Captions.CaptionTracks.Find(track => track.Id == id) is { } track)
        {
            track.IsHidden = !track.IsHidden;
        }
    });

    public void AddCaption(string trackId, double startMs, double endMs, string text = "New caption")
    {
        var block = new CaptionBlock { Id = NewId(), TrackId = trackId, SourceStartMs = startMs, SourceEndMs = endMs, CustomText = text };
        Mutate(document =>
        {
            document.Captions.Enabled = true;
            document.Captions.CaptionBlocks.Add(block);
        });
        SelectCaption(block.Id);
    }

    public void DeleteCaption(string id)
    {
        Mutate(document => document.Captions.CaptionBlocks.RemoveAll(block => block.Id == id));
        if (SelectedCaptionId == id)
        {
            SelectCaption(null);
        }
    }

    /// <summary>Moves a caption to another track, or to a new one when dragged past the ends. It stays put if the target is taken.</summary>
    public void MoveCaptionToTrack(string id, int targetTrackIndex) => Mutate(document =>
    {
        var captions = document.Captions;
        if (captions.CaptionBlocks.Find(item => item.Id == id) is not { } block)
        {
            return;
        }

        if (targetTrackIndex < 0 || targetTrackIndex >= captions.CaptionTracks.Count)
        {
            if (captions.CaptionTracks.Find(track => track.Id == block.TrackId) is not { } current)
            {
                return;
            }

            // Its track would go away with it, leaving the same layout with the caption at another spot.
            if (!captions.CaptionBlocks.Exists(other => other.TrackId == block.TrackId && other.Id != id))
            {
                return;
            }

            var created = new CaptionTrack { Id = NewId(), Name = $"Captions {captions.CaptionTracks.Count + 1}", Style = StyleForNewTrack(current.Style) };
            captions.CaptionTracks.Insert(targetTrackIndex < 0 ? 0 : captions.CaptionTracks.Count, created);
            block.TrackId = created.Id;
            return;
        }

        var target = captions.CaptionTracks[targetTrackIndex].Id;
        var taken = captions.CaptionBlocks.Exists(other => other.TrackId == target
            && other.Id != id
            && block.SourceEndMs > other.SourceStartMs + 20
            && block.SourceStartMs < other.SourceEndMs - 20);
        if (!taken)
        {
            block.TrackId = target;
        }
    });

    /// <summary>Splits between words. A caption shows at least one word on each side.</summary>
    public void SplitCaption(string id, double sourceMs)
    {
        var captions = Document.Captions;
        if (captions.CaptionBlocks.Find(item => item.Id == id) is not { } block || sourceMs <= block.SourceStartMs || sourceMs >= block.SourceEndMs)
        {
            return;
        }

        var first = ProjectJson.Clone(block);
        var second = ProjectJson.Clone(block);
        second.Id = NewId();
        if (block.CustomText is { } custom)
        {
            var words = custom.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (words.Length < 2)
            {
                ToastRequested?.Invoke("Can't split a caption with one word");
                return;
            }

            var keep = (int)Math.Round(words.Length * (sourceMs - block.SourceStartMs) / (block.SourceEndMs - block.SourceStartMs), MidpointRounding.AwayFromZero);
            var count = Math.Clamp(keep, 1, words.Length - 1);
            first.CustomText = string.Join(' ', words[..count]);
            second.CustomText = string.Join(' ', words[count..]);
            first.SourceEndMs = sourceMs;
            second.SourceStartMs = sourceMs;
        }
        else
        {
            var spoken = new List<CaptionSegment>();
            foreach (var wordId in block.WordIds)
            {
                if (captions.Segments.Find(item => item.Id == wordId) is { } word)
                {
                    spoken.Add(word);
                }
            }

            if (spoken.Count < 2 || spoken.Count != block.WordIds.Count)
            {
                ToastRequested?.Invoke("Can't split a caption with one word");
                return;
            }

            var scale = (block.SourceEndMs - block.SourceStartMs) / Math.Max(1, spoken[^1].SourceEndMs - spoken[0].SourceStartMs);
            var starts = spoken.Select(word => block.SourceStartMs + (word.SourceStartMs - spoken[0].SourceStartMs) * scale).ToList();
            var count = Math.Clamp(starts.Count(start => start < sourceMs), 1, spoken.Count - 1);
            // Cut where the next word starts, so words keep their timing.
            first.WordIds = block.WordIds.GetRange(0, count);
            second.WordIds = block.WordIds.GetRange(count, block.WordIds.Count - count);
            first.SourceEndMs = starts[count];
            second.SourceStartMs = starts[count];
        }

        Mutate(document =>
        {
            var list = document.Captions.CaptionBlocks;
            var index = list.FindIndex(item => item.Id == id);
            if (index >= 0)
            {
                list[index] = first;
                list.Insert(index + 1, second);
            }
        });
        SelectCaption(second.Id);
    }

    /// <summary>Editing keeps the spoken timing while the word count is unchanged. Otherwise the caption becomes typed text.</summary>
    public void UpdateCaptionText(string id, string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0)
        {
            return;
        }

        Mutate(document =>
        {
            var captions = document.Captions;
            if (captions.CaptionBlocks.Find(item => item.Id == id) is not { } block)
            {
                return;
            }

            var parts = trimmed.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            var visible = block.WordIds.Select(wordId => captions.Segments.Find(item => item.Id == wordId)).OfType<CaptionSegment>().Where(word => !word.IsHidden).ToList();
            if (block.CustomText is null && visible.Count == parts.Length)
            {
                for (var index = 0; index < parts.Length; index++)
                {
                    visible[index].Text = parts[index];
                }
            }
            else
            {
                block.CustomText = trimmed;
                block.WordIds = [];
            }
        });
    }

    public CaptionStyle EffectiveCaptionStyle(string? blockId, string? trackId)
    {
        var captions = Document.Captions;
        var block = captions.CaptionBlocks.Find(item => item.Id == blockId);
        if (block?.StyleOverride is { } own)
        {
            return own;
        }

        var resolved = block?.TrackId ?? trackId;
        return captions.CaptionTracks.Find(track => track.Id == resolved)?.Style
            ?? captions.CaptionTracks.FirstOrDefault()?.Style
            ?? new CaptionStyle();
    }

    /// <summary>With a block, changes only that caption. Otherwise changes the whole track, including captions that override it.</summary>
    public void UpdateCaptionStyle(string? blockId, string? trackId, Action<CaptionStyle> change, string? interactiveKey = null) =>
        Mutate(document => ApplyCaptionStyle(document, blockId, trackId, change), interactiveKey, structural: interactiveKey is null);

    public static void ApplyCaptionStyle(ProjectDocument document, string? blockId, string? trackId, Action<CaptionStyle> change)
    {
        var captions = document.Captions;
        if (captions.CaptionBlocks.Find(item => item.Id == blockId) is { } block)
        {
            block.StyleOverride ??= ProjectJson.Clone(captions.CaptionTracks.Find(track => track.Id == block.TrackId)?.Style ?? new CaptionStyle());
            change(block.StyleOverride);
            return;
        }

        if (captions.CaptionTracks.Find(track => track.Id == trackId) is not { } target)
        {
            return;
        }

        change(target.Style);
        foreach (var other in captions.CaptionBlocks)
        {
            if (other.TrackId == target.Id && other.StyleOverride is { } style)
            {
                change(style);
            }
        }
    }
}
