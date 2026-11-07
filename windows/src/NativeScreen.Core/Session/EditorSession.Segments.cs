namespace NativeScreen.Core;

/// <summary>Segment actions shared by context menus, the command menu and shortcuts. Same names and messages as ProjectSession on macOS.</summary>
public sealed partial class EditorSession
{
    private const string TooShortToCut = "Can't cut item shorter than 0.2s";
    private ZoomBlock? copiedZoom;
    private MaskItem? copiedMask;

    public event Action<string>? ToastRequested;

    /// <summary>A mask is about to be drawn on the preview, by dragging out its area.</summary>
    public MaskType? PendingAddMaskType { get; private set; }

    /// <summary>The time the timeline is hovered at while paused; the preview shows it, the playhead stays.</summary>
    public double? HoverSkimTimelineMs { get; private set; }

    public double DisplaySourceMs => HoverSkimTimelineMs is { } skim ? Mapper.SourceTime(skim).SourceMs : SourceAtPlayhead;

    /// <summary>Returns whether the time changed.</summary>
    public bool SetHoverSkim(double? timelineMs)
    {
        var next = timelineMs is { } time ? Math.Clamp(time, 0, DurationMs) : (double?)null;
        if (next == HoverSkimTimelineMs)
        {
            return false;
        }

        HoverSkimTimelineMs = next;
        return true;
    }

    /// <summary>Asking again for the same type leaves the mode.</summary>
    public void BeginInteractiveMaskSelection(MaskType type)
    {
        HoverSkimTimelineMs = null;
        IsSplitModeActive = false;
        PendingAddMaskType = PendingAddMaskType == type ? null : type;
        if (PendingAddMaskType is not null)
        {
            ClearSelection();
        }

        SelectionChanged?.Invoke();
    }

    public void CancelInteractiveMaskSelection()
    {
        PendingAddMaskType = null;
        SelectionChanged?.Invoke();
    }

    public void CompleteInteractiveMaskSelection(Rect01 rect)
    {
        var type = PendingAddMaskType ?? MaskType.Blur;
        PendingAddMaskType = null;
        var at = SourceAtPlayhead;
        var end = Math.Min(SourceDurationMs, at + 4500);
        var start = Math.Max(0, Math.Min(at, end - 1200));
        var item = new MaskItem
        {
            Id = NewId(),
            SourceStartMs = start,
            SourceEndMs = end,
            Type = type,
            Style = type == MaskType.Spotlight ? MaskStyle.Dim : MaskStyle.Gaussian,
            Intensity = type == MaskType.Spotlight ? 50 : 36,
            CornerRadius = 12,
            Keyframes = [new MaskKeyframe { SourceMs = start, Rect01 = rect.Clamped() }]
        };
        Mutate(document =>
        {
            var tracks = document.Timeline.MaskTracks;
            var free = tracks.Find(track => !track.Items.Exists(other => !(end <= other.SourceStartMs + 30 || start >= other.SourceEndMs - 30)));
            if (free is null)
            {
                free = new MaskTrack { Id = NewId(), Name = tracks.Count == 0 ? "Masks" : $"Masks {tracks.Count + 1}" };
                tracks.Add(free);
            }

            free.IsHidden = false;
            free.Items.Add(item);
            free.Items.Sort((a, b) => a.SourceStartMs.CompareTo(b.SourceStartMs));
        });
        SelectMask(item.Id);
    }

    public ClipSlice? ActiveSlice => Mapper.SourceTime(PlayheadTimelineMs).Slice;

    private MaskItem? FindMask(ProjectDocument document, string id) =>
        document.Timeline.MaskTracks.SelectMany(track => track.Items).FirstOrDefault(item => item.Id == id);

    public void MergeSliceWithNext(string id) => Mutate(document => SegmentEdits.MergeSliceWithNext(document, id));

    public void RemoveSliceStartTrim(string id) => Mutate(document =>
    {
        var slices = document.Timeline.Slices;
        var index = slices.FindIndex(item => item.Id == id);
        if (index >= 0)
        {
            slices[index].SourceStartMs = Math.Min(slices[index].SourceStartMs, index > 0 ? slices[index - 1].SourceEndMs : 0);
        }
    });

    public void RemoveSliceEndTrim(string id) => Mutate(document =>
    {
        var slices = document.Timeline.Slices;
        var index = slices.FindIndex(item => item.Id == id);
        if (index >= 0)
        {
            slices[index].SourceEndMs = Math.Max(slices[index].SourceEndMs, index + 1 < slices.Count ? slices[index + 1].SourceStartMs : SourceDurationMs);
        }
    });

    public void ToggleShortcutTrackHidden(string trackId) => Mutate(document =>
    {
        var tracks = document.Captions.ShortcutTracks;
        var index = tracks.FindIndex(track => track.Id == trackId);
        if (index >= 0)
        {
            tracks[index].IsHidden = !tracks[index].IsHidden;
            if (index == 0)
            {
                document.Timeline.IsShortcutsTrackHidden = tracks[0].IsHidden;
            }
        }
    });

    public void AddCameraLayoutAt(CameraTimelineLayoutType type, double sourceMs)
    {
        string? id = null;
        Mutate(document => id = TimelineEdits.AddCameraLayout(document, sourceMs, SourceDurationMs, type));
        if (id is not null)
        {
            SelectLayout(id);
        }
    }

    public void ApplyVoiceoverVolumeToOthers(string id)
    {
        Mutate(document =>
        {
            var volume = document.Timeline.Voiceovers.First(item => item.Id == id).Volume;
            foreach (var other in document.Timeline.Voiceovers)
            {
                other.Volume = volume;
            }
        });
        ToastRequested?.Invoke("Volume applied to all voiceovers");
    }

    public void ResetSliceTrim(string id) => Mutate(document => SegmentEdits.ResetSliceTrim(document, id, SourceDurationMs));

    public void ResetAllSlices() => Mutate(document => SegmentEdits.ResetAllSlices(document, SourceDurationMs));

    public void SetSliceSpeed(string id, double speed) => Mutate(document => document.Timeline.Slices.First(slice => slice.Id == id).Speed = Math.Clamp(speed, 0.25, 8));

    public void SetSliceSystemAudioVolume(string id, double volume) =>
        Mutate(document => SegmentEdits.SetSliceSystemAudioVolume(document.Timeline.Slices.First(slice => slice.Id == id), volume), "slice-volume:" + id, structural: false);

    public void SetSliceMicrophoneVolume(string id, double volume) =>
        Mutate(document => SegmentEdits.SetSliceMicrophoneVolume(document.Timeline.Slices.First(slice => slice.Id == id), volume), "slice-microphone-volume:" + id, structural: false);

    public void ToggleSliceHideCursor(string id) => Mutate(document =>
    {
        var slice = document.Timeline.Slices.First(item => item.Id == id);
        slice.HideCursor = !slice.HideCursor;
    });

    public void ToggleSliceDisableSmoothCursor(string id) => Mutate(document =>
    {
        var slice = document.Timeline.Slices.First(item => item.Id == id);
        slice.DisableSmoothCursor = !slice.DisableSmoothCursor;
    });

    /// <summary>C: splits whatever is selected, or the clip under the playhead.</summary>
    public void SplitAtCurrentTime()
    {
        var at = SourceAtPlayhead;
        if (SelectedCaptionId is { } caption)
        {
            SplitCaption(caption, at);
        }
        else if (SelectedLayoutId is { } layout)
        {
            SplitLayout(layout, at);
        }
        else if (SelectedMaskId is { } mask)
        {
            SplitMask(mask, at);
        }
        else if (SelectedZoomId is { } zoom)
        {
            SplitZoom(zoom, at);
        }
        else if (!SplitSlice(PlayheadTimelineMs))
        {
            ToastRequested?.Invoke("The part you want to cut is too short");
        }
    }

    public void SplitZoom(string id, double sourceMs)
    {
        string? second = null;
        Mutate(document => second = SegmentEdits.SplitZoom(document, id, sourceMs));
        if (second is null)
        {
            ToastRequested?.Invoke(TooShortToCut);
        }
        else
        {
            SelectZoom(second);
        }
    }

    public void SplitMask(string id, double sourceMs)
    {
        string? second = null;
        Mutate(document => second = SegmentEdits.SplitMask(document, id, sourceMs));
        if (second is null)
        {
            ToastRequested?.Invoke(TooShortToCut);
        }
        else
        {
            SelectMask(second);
        }
    }

    public void SplitLayout(string id, double sourceMs)
    {
        string? second = null;
        Mutate(document => second = SegmentEdits.SplitLayout(document, id, sourceMs));
        if (second is null)
        {
            ToastRequested?.Invoke(TooShortToCut);
        }
        else
        {
            SelectLayout(second);
        }
    }

    public void DuplicateZoom(string id)
    {
        string? copy = null;
        Mutate(document => copy = SegmentEdits.DuplicateZoom(document, id, SourceDurationMs));
        if (copy is not null)
        {
            SelectZoom(copy);
        }
    }

    public void DuplicateLayout(string id)
    {
        string? copy = null;
        Mutate(document => copy = SegmentEdits.DuplicateLayout(document, id, SourceDurationMs));
        if (copy is not null)
        {
            SelectLayout(copy);
        }
    }

    public void DuplicateShortcut(ShortcutCluster cluster)
    {
        string? copy = null;
        var clusters = Shortcuts();
        Mutate(document => copy = SegmentEdits.DuplicateShortcut(document, cluster, clusters, SourceDurationMs));
        if (copy is not null)
        {
            SelectShortcut(copy);
        }
    }

    public void SetZoomPresentation(string id, ZoomPresentation presentation) =>
        Mutate(document => document.Timeline.Zooms.First(zoom => zoom.Id == id).Presentation = presentation);

    public void SetZoomMode(string id, ZoomMode mode) =>
        Mutate(document => document.Timeline.Zooms.First(zoom => zoom.Id == id).Mode = mode);

    public void SetZoomScale(string id, double scale) =>
        Mutate(document => document.Timeline.Zooms.First(zoom => zoom.Id == id).Scale = Math.Clamp(Math.Round(scale * 10) / 10, 1, 4), "zoom-scale:" + id, structural: false);

    public void ToggleZoomDisabled(string id) => Mutate(document =>
    {
        var zoom = document.Timeline.Zooms.First(item => item.Id == id);
        zoom.Disabled = !zoom.Disabled;
    });

    public void ApplyZoomLevelToAll(string id)
    {
        Mutate(document =>
        {
            var level = document.Timeline.Zooms.First(zoom => zoom.Id == id).Scale;
            foreach (var zoom in document.Timeline.Zooms)
            {
                zoom.Scale = level;
            }
        });
        ToastRequested?.Invoke("Zoom level applied to all zooms");
    }

    public void CopyZoom(string id)
    {
        copiedZoom = ProjectJson.Clone(Document.Timeline.Zooms.First(zoom => zoom.Id == id));
        copiedMask = null;
        ToastRequested?.Invoke("Zoom range copied");
    }

    public void CutZoom(string id)
    {
        CopyZoom(id);
        Mutate(document => document.Timeline.Zooms.RemoveAll(zoom => zoom.Id == id));
        SelectZoom(null);
    }

    public void RegenerateAutoZooms()
    {
        var generated = AutoZoomClusterGenerator.GenerateZooms(ClickEvents, KeyEvents, SourceDurationMs, 1.8);
        foreach (var zoom in generated)
        {
            zoom.Id = NewId();
        }

        Mutate(document =>
        {
            document.Timeline.IsZoomTrackHidden = false;
            document.Timeline.Zooms = generated;
        });
    }

    public void SetMaskType(string id, MaskType type) => Mutate(document =>
    {
        if (FindMask(document, id) is { } mask)
        {
            SegmentEdits.SetMaskType(mask, type);
        }
    });

    public void SetMaskIntensity(string id, double value) => Mutate(document =>
    {
        if (FindMask(document, id) is { } mask)
        {
            mask.Intensity = value;
        }
    }, "mask-intensity:" + id, structural: false);

    public void SetMaskCornerRadius(string id, double value) => Mutate(document =>
    {
        if (FindMask(document, id) is { } mask)
        {
            mask.CornerRadius = value;
        }
    }, "mask-radius:" + id, structural: false);

    public void ToggleMaskDisabled(string id) => Mutate(document =>
    {
        if (FindMask(document, id) is { } mask)
        {
            mask.Disabled = !mask.Disabled;
        }
    });

    public void CopyMask(string id)
    {
        if (FindMask(Document, id) is { } mask)
        {
            copiedMask = ProjectJson.Clone(mask);
            copiedZoom = null;
            ToastRequested?.Invoke("Mask copied");
        }
    }

    public void CutMask(string id)
    {
        CopyMask(id);
        DeleteMask(id);
    }

    public void DeleteMask(string id)
    {
        Mutate(document =>
        {
            foreach (var track in document.Timeline.MaskTracks)
            {
                track.Items.RemoveAll(item => item.Id == id);
            }
        });
        if (SelectedMaskId == id)
        {
            SelectMask(null);
        }
    }

    public void MoveMaskToTrack(string id, int targetTrack) => Mutate(document => SegmentEdits.MoveMaskToTrack(document, id, targetTrack));

    /// <summary>Ctrl+V: a copied zoom's settings go to the selected zoom, otherwise a copy lands at the playhead.</summary>
    public void PasteFromClipboard()
    {
        var at = SourceAtPlayhead;
        if (copiedZoom is { } zoom)
        {
            if (SelectedZoomId is { } selected)
            {
                Mutate(document =>
                {
                    var target = document.Timeline.Zooms.First(item => item.Id == selected);
                    target.Mode = zoom.Mode;
                    target.Scale = zoom.Scale;
                    target.Presentation = zoom.Presentation;
                    target.Loupe = ProjectJson.Clone(zoom.Loupe);
                    target.ManualCenter01 = zoom.ManualCenter01;
                    target.InstantAnimation = zoom.InstantAnimation;
                });
            }
            else
            {
                var pasted = ProjectJson.Clone(zoom);
                var length = Math.Max(300, zoom.SourceEndMs - zoom.SourceStartMs);
                pasted.Id = NewId();
                pasted.SourceStartMs = Math.Min(Math.Max(0, at), Math.Max(0, SourceDurationMs - 300));
                pasted.SourceEndMs = Math.Min(SourceDurationMs, pasted.SourceStartMs + length);
                Mutate(document =>
                {
                    document.Timeline.Zooms.Add(pasted);
                    document.Timeline.Zooms.Sort((a, b) => a.SourceStartMs.CompareTo(b.SourceStartMs));
                });
                SelectZoom(pasted.Id);
            }

            ToastRequested?.Invoke("Zoom range settings pasted");
        }
        else if (copiedMask is { } mask)
        {
            var pasted = ProjectJson.Clone(mask);
            var length = Math.Max(300, mask.SourceEndMs - mask.SourceStartMs);
            pasted.Id = NewId();
            pasted.SourceStartMs = Math.Min(Math.Max(0, at), Math.Max(0, SourceDurationMs - 300));
            pasted.SourceEndMs = Math.Min(SourceDurationMs, pasted.SourceStartMs + length);
            Mutate(document =>
            {
                if (document.Timeline.MaskTracks.Count == 0)
                {
                    document.Timeline.MaskTracks.Add(new MaskTrack { Id = NewId(), Name = "Masks" });
                }

                document.Timeline.MaskTracks[0].Items.Add(pasted);
            });
            SelectMask(pasted.Id);
            ToastRequested?.Invoke("Mask settings pasted");
        }
    }

    /// <summary>D: disables whatever is selected.</summary>
    public void ToggleDisableSelected()
    {
        if (SelectedLayoutId is { } layout)
        {
            ToggleLayoutDisabled(layout);
        }
        else if (SelectedMaskId is { } mask)
        {
            ToggleMaskDisabled(mask);
        }
        else if (SelectedZoomId is { } zoom)
        {
            ToggleZoomDisabled(zoom);
        }
    }

    public void SetLayoutType(string id, CameraTimelineLayoutType type) =>
        Mutate(document => document.Timeline.CameraLayouts.First(layout => layout.Id == id).LayoutType = type);

    public void ToggleLayoutDisabled(string id) => Mutate(document =>
    {
        var layout = document.Timeline.CameraLayouts.First(item => item.Id == id);
        layout.Disabled = !layout.Disabled;
    });

    public void DeleteLayout(string id)
    {
        Mutate(document => document.Timeline.CameraLayouts.RemoveAll(layout => layout.Id == id));
        if (SelectedLayoutId == id)
        {
            SelectLayout(null);
        }
    }

    public void ToggleShortcutHidden(ShortcutCluster cluster) => Mutate(document =>
    {
        document.Captions.ShowKeystrokes = true;
        SegmentEdits.SetShortcutHidden(document, cluster, !SegmentEdits.IsShortcutHidden(document, cluster));
    });

    public void SetEveryShortcutWithLabelHidden(ShortcutCluster cluster, bool hidden)
    {
        var matching = Shortcuts().Where(item => item.Label == cluster.Label).ToList();
        Mutate(document =>
        {
            foreach (var item in matching)
            {
                SegmentEdits.SetShortcutHidden(document, item, hidden);
            }
        });
    }

    public void SetAllShortcutsHidden(bool hidden)
    {
        var all = Shortcuts();
        Mutate(document =>
        {
            foreach (var item in all)
            {
                SegmentEdits.SetShortcutHidden(document, item, hidden);
            }
        });
    }

    public void DeleteShortcut(ShortcutCluster cluster)
    {
        var clusters = Shortcuts();
        Mutate(document => TimelineEdits.DeleteShortcut(document, cluster, clusters));
        if (SelectedShortcutId == cluster.Id)
        {
            SelectShortcut(null);
        }
    }

    public void SetVoiceoverVolume(string id, double volume) =>
        Mutate(document => document.Timeline.Voiceovers.First(item => item.Id == id).Volume = Math.Clamp(volume, 0, 1), "voiceover-volume:" + id, structural: false);

    public void ToggleVoiceoverTrackHidden(int track) => Mutate(document =>
        VoiceoverTrackLayout.SetTrackHidden(document.Timeline, track, !VoiceoverTrackLayout.IsTrackHidden(document.Timeline, track)));

    public void MoveVoiceoverToTrack(string id, int targetTrack) => Mutate(document => VoiceoverTrackLayout.MoveToTrack(document.Timeline, id, targetTrack));

    public void DeleteVoiceover(string id) => Mutate(document =>
    {
        document.Timeline.Voiceovers.RemoveAll(item => item.Id == id);
        VoiceoverTrackLayout.Normalize(document.Timeline);
    });

    public void ToggleVoiceoverDisabled(string id) => Mutate(document =>
    {
        var voiceover = document.Timeline.Voiceovers.First(item => item.Id == id);
        voiceover.Disabled = !voiceover.Disabled;
    });
}
