namespace NativeScreen.Core;

public enum InspectorTab
{
    Background,
    Cursor,
    CameraLayout,
    CameraStyle,
    Captions,
    Transcript,
    Audio,
    Shortcuts,
    Zoom,
    DeviceFrame,
    Masks
}

public static class InspectorCatalog
{
    public static IReadOnlyList<InspectorTab> Tabs { get; } = Enum.GetValues<InspectorTab>();

    public static string Title(InspectorTab tab) => tab switch
    {
        InspectorTab.Background => "General",
        InspectorTab.Cursor => "Cursor",
        InspectorTab.CameraLayout => "Camera Layout",
        InspectorTab.CameraStyle => "Camera Style",
        InspectorTab.Captions => "Captions",
        InspectorTab.Transcript => "Edit by transcript",
        InspectorTab.Audio => "Audio",
        InspectorTab.Shortcuts => "Keyboard Shortcuts",
        InspectorTab.Zoom => "Animations",
        InspectorTab.DeviceFrame => "Device Frame",
        InspectorTab.Masks => "Masks",
        _ => tab.ToString()
    };

    public static string? Accelerator(InspectorTab tab) => tab switch
    {
        InspectorTab.Background => "Ctrl+1",
        InspectorTab.Cursor => "Ctrl+2",
        InspectorTab.CameraLayout => "Ctrl+3",
        InspectorTab.CameraStyle => "Ctrl+4",
        InspectorTab.Captions => "Ctrl+5",
        InspectorTab.Transcript => "Ctrl+6",
        InspectorTab.Audio => "Ctrl+7",
        InspectorTab.Shortcuts => "Ctrl+8",
        InspectorTab.Zoom => "Ctrl+9",
        InspectorTab.DeviceFrame => "Ctrl+0",
        _ => null
    };
}

public sealed class EditorCommand
{
    public required string Id { get; init; }
    public required string Title { get; init; }
    public string Accelerator { get; init; } = "";
}

public static class EditorCommands
{
    public static IReadOnlyList<EditorCommand> All { get; } =
    [
        new() { Id = "play", Title = "Play or pause", Accelerator = "Space" },
        new() { Id = "split", Title = "Split clip at playhead", Accelerator = "C" },
        new() { Id = "zoom", Title = "Add classic zoom", Accelerator = "" },
        new() { Id = "loupe", Title = "Add loupe zoom", Accelerator = "" },
        new() { Id = "mask", Title = "Add sensitive data mask", Accelerator = "" },
        new() { Id = "highlight", Title = "Add highlight mask", Accelerator = "" },
        new() { Id = "delete", Title = "Delete selection", Accelerator = "Delete" },
        new() { Id = "undo", Title = "Undo", Accelerator = "Ctrl+Z" },
        new() { Id = "redo", Title = "Redo", Accelerator = "Ctrl+Shift+Z" },
        new() { Id = "export", Title = "Export", Accelerator = "Ctrl+E" },
        new() { Id = "settings", Title = "Settings", Accelerator = "Ctrl+," },
        new() { Id = "command-menu", Title = "Command menu", Accelerator = "Ctrl+K" }
    ];

    public static IReadOnlyList<EditorCommand> Search(string? query)
    {
        if (string.IsNullOrWhiteSpace(query))
        {
            return All;
        }

        return All.Where(command => command.Title.Contains(query, StringComparison.OrdinalIgnoreCase)).ToList();
    }
}

public sealed class EditorSession
{
    private const double CoalesceWindowMs = 700;
    private readonly PlaybackClock clock;
    private string? coalesceKey;
    private long coalesceAt;
    private bool interactiveEditActive;
    private bool interactiveEditCommitted;
    private ProjectDocument? renderDocument;
    private SpringTrajectorySolver? trajectory;
    private string? trajectoryKey;
    private ProjectDocument? shortcutsDocument;
    private IReadOnlyList<ShortcutCluster> shortcuts = [];

    public EditorSession(ProjectDocument? document = null, double durationMs = 6000, PlaybackClock? clock = null)
    {
        var initial = document ?? new ProjectDocument();
        if (initial.Timeline.Slices.Count == 0)
        {
            initial.Timeline.Slices.Add(new ClipSlice { Id = NewId(), SourceStartMs = 0, SourceEndMs = durationMs });
        }

        // Selection and drags find blocks by id; generated zooms arrive without one.
        foreach (var zoom in initial.Timeline.Zooms.Where(zoom => zoom.Id.Length == 0))
        {
            zoom.Id = NewId();
        }

        History = new UndoStack(initial);
        SourceDurationMs = durationMs;
        Mapper = new NLETimeMapper(History.Current.Timeline.Slices);
        this.clock = clock ?? new PlaybackClock();
    }

    /// <summary>The document changed. True when the set of controls or timeline blocks may differ.</summary>
    public event Action<bool>? DocumentChanged;

    public event Action? SelectionChanged;

    public UndoStack History { get; }
    public ProjectDocument Document => History.Current;
    public NLETimeMapper Mapper { get; private set; }
    public double SourceDurationMs { get; }
    public double DurationMs => Mapper.TotalTimelineDurationMs;
    public double PlayheadTimelineMs { get; private set; }
    public bool IsPlaying => clock.IsRunning;
    public InspectorTab SelectedTab { get; private set; } = InspectorTab.Background;
    public string CommandQuery { get; private set; } = "";
    public bool IsCommandMenuOpen { get; private set; }
    public string? SelectedSliceId { get; private set; }
    public string? SelectedZoomId { get; private set; }
    public string? SelectedMaskId { get; private set; }
    public bool IsSplitModeActive { get; set; }

    public ZoomBlock? SelectedZoom => Document.Timeline.Zooms.Find(zoom => zoom.Id == SelectedZoomId);

    public MaskItem? SelectedMask
    {
        get
        {
            foreach (var track in Document.Timeline.MaskTracks)
            {
                var hit = track.Items.Find(item => item.Id == SelectedMaskId);
                if (hit is not null)
                {
                    return hit;
                }
            }

            return null;
        }
    }

    public double SourceAtPlayhead => Mapper.SourceTime(PlayheadTimelineMs).SourceMs;

    /// <summary>Telemetry the trajectory is solved from. Empty for a project with no recording.</summary>
    public IReadOnlyList<CursorSampleEvent> CursorEvents { get; init; } = [];

    public IReadOnlyList<ClickEvent> ClickEvents { get; init; } = [];

    public IReadOnlyList<KeyStrokeEvent> KeyEvents { get; init; } = [];

    /// <summary>Shortcut clusters of the current document, rebuilt only after an edit.</summary>
    public IReadOnlyList<ShortcutCluster> Shortcuts()
    {
        var (document, _) = RenderSnapshot();
        if (!ReferenceEquals(shortcutsDocument, document))
        {
            shortcutsDocument = document;
            shortcuts = ShortcutEngine.Detect(document, KeyEvents);
        }

        return shortcuts;
    }

    /// <summary>A frozen copy for the render thread, rebuilt only after an edit.</summary>
    public (ProjectDocument Document, SpringTrajectorySolver Trajectory) RenderSnapshot()
    {
        renderDocument ??= ProjectJson.Clone(Document);
        var key = ProjectJson.Serialize(new object[] { renderDocument.Cursor, renderDocument.Motion, renderDocument.Timeline.Zooms, renderDocument.Timeline.Slices });
        if (trajectory is null || key != trajectoryKey)
        {
            trajectoryKey = key;
            trajectory = new SpringTrajectorySolver(SourceDurationMs, CursorEvents, ClickEvents, renderDocument);
        }

        return (renderDocument, trajectory);
    }

    public void TogglePlayback()
    {
        if (clock.IsRunning)
        {
            PlayheadTimelineMs = Math.Clamp(clock.PositionMs, 0, DurationMs);
            clock.Pause();
            return;
        }

        if (PlayheadTimelineMs >= DurationMs)
        {
            PlayheadTimelineMs = 0;
        }

        clock.PrimeAndStart(PlayheadTimelineMs);
    }

    public void SyncToAudio(double audioTimelineMs) => clock.SyncToAudio(audioTimelineMs);

    public void SamplePlayhead()
    {
        if (!clock.IsRunning)
        {
            return;
        }

        PlayheadTimelineMs = Math.Clamp(clock.PositionMs, 0, DurationMs);
        if (PlayheadTimelineMs >= DurationMs)
        {
            clock.Pause();
        }
    }

    public void Scrub(double timelineMs)
    {
        if (clock.IsRunning)
        {
            clock.Pause();
        }

        PlayheadTimelineMs = Math.Clamp(timelineMs, 0, DurationMs);
    }

    public void SelectTab(InspectorTab tab)
    {
        ClearSelectionState();
        SelectedTab = tab;
        SelectionChanged?.Invoke();
    }

    public void OpenCommandMenu() => IsCommandMenuOpen = true;

    public void SetCommandQuery(string query) => CommandQuery = query;

    public void CloseCommandMenu()
    {
        IsCommandMenuOpen = false;
        CommandQuery = "";
    }

    public void Rename(string name) => Mutate(document => document.Name = name);

    /// <summary>Applies one edit as an undo step. Repeated edits with the same key (a slider drag) share one step.</summary>
    public void Mutate(Action<ProjectDocument> change, string? interactiveKey = null, bool structural = true)
    {
        var now = Environment.TickCount64;
        var coalesced = interactiveKey is not null && interactiveKey == coalesceKey && now - coalesceAt < CoalesceWindowMs;
        if (coalesced || interactiveEditCommitted)
        {
            change(History.Current);
        }
        else
        {
            interactiveEditCommitted = interactiveEditActive;
            var next = ProjectJson.Clone(History.Current);
            change(next);
            History.Commit(next);
        }

        coalesceKey = interactiveKey;
        coalesceAt = now;
        renderDocument = null;
        NormalizeMaskTracks();
        Mapper = new NLETimeMapper(History.Current.Timeline.Slices);
        PlayheadTimelineMs = Math.Clamp(PlayheadTimelineMs, 0, DurationMs);
        DocumentChanged?.Invoke(structural);
    }

    /// <summary>Every edit until EndInteractiveEdit (a timeline drag) becomes a single undo step.</summary>
    public void BeginInteractiveEdit()
    {
        interactiveEditActive = true;
        interactiveEditCommitted = false;
    }

    public void EndInteractiveEdit()
    {
        interactiveEditActive = false;
        interactiveEditCommitted = false;
    }

    public void Undo()
    {
        History.Undo();
        AfterHistoryMove();
    }

    public void Redo()
    {
        History.Redo();
        AfterHistoryMove();
    }

    public void SelectSlice(string? id)
    {
        ClearSelectionState();
        SelectedSliceId = id;
        SelectionChanged?.Invoke();
    }

    public void SelectZoom(string? id)
    {
        ClearSelectionState();
        SelectedZoomId = id;
        SelectionChanged?.Invoke();
    }

    public void SelectMask(string? id)
    {
        ClearSelectionState();
        SelectedMaskId = id;
        SelectedTab = id is null ? SelectedTab : InspectorTab.Masks;
        SelectionChanged?.Invoke();
    }

    public void ClearSelection()
    {
        ClearSelectionState();
        SelectionChanged?.Invoke();
    }

    public void AddZoomAtPlayhead(ZoomPresentation presentation)
    {
        var source = SourceAtPlayhead;
        var sorted = Document.Timeline.Zooms.OrderBy(zoom => zoom.SourceStartMs).ToList();
        var containing = sorted.Find(zoom => source >= zoom.SourceStartMs && source <= zoom.SourceEndMs);
        if (containing is not null)
        {
            if (containing.Presentation != presentation)
            {
                var id = containing.Id;
                Mutate(document => document.Timeline.Zooms.First(zoom => zoom.Id == id).Presentation = presentation);
            }

            SelectZoom(containing.Id);
            return;
        }

        var availableStart = sorted.LastOrDefault(zoom => zoom.SourceEndMs <= source)?.SourceEndMs ?? 0;
        var availableEnd = sorted.FirstOrDefault(zoom => zoom.SourceStartMs >= source)?.SourceStartMs ?? SourceDurationMs;
        if (availableEnd - availableStart < 400)
        {
            return;
        }

        var duration = Math.Min(3200, availableEnd - availableStart);
        var start = Math.Max(availableStart, Math.Min(availableEnd - duration, source));
        var created = new ZoomBlock
        {
            Id = NewId(),
            SourceStartMs = start,
            SourceEndMs = Math.Min(availableEnd, start + duration),
            Scale = presentation == ZoomPresentation.Loupe ? 2.0 : 1.8,
            Mode = ZoomMode.Manual,
            Presentation = presentation,
            Loupe = new LoupeConfig { Radius01 = 0.35, BevelRatio = 0.25, ChromaticAberration = 0.65 }
        };
        Mutate(document =>
        {
            document.Timeline.IsZoomTrackHidden = false;
            document.Timeline.Zooms.Add(created);
            document.Timeline.Zooms.Sort((a, b) => a.SourceStartMs.CompareTo(b.SourceStartMs));
        });
        SelectZoom(created.Id);
    }

    public void AddMaskAtPlayhead(MaskType type)
    {
        var start = SourceAtPlayhead;
        var end = Math.Min(SourceDurationMs, start + 3000);
        if (end - start < 200)
        {
            return;
        }

        var created = new MaskItem
        {
            Id = NewId(),
            SourceStartMs = start,
            SourceEndMs = end,
            Type = type,
            Style = type == MaskType.Spotlight ? MaskStyle.Dim : MaskStyle.Gaussian,
            Intensity = type == MaskType.Spotlight ? 50 : 36,
            Keyframes = [new MaskKeyframe { SourceMs = start }]
        };
        Mutate(document =>
        {
            var track = document.Timeline.MaskTracks.Find(item => !item.Items.Exists(other => other.SourceStartMs < end && other.SourceEndMs > start));
            if (track is null)
            {
                track = new MaskTrack { Id = NewId() };
                document.Timeline.MaskTracks.Add(track);
            }

            track.Items.Add(created);
        });
        SelectMask(created.Id);
    }

    /// <summary>Returns false when the time is within 100 ms of a slice edge.</summary>
    public bool SplitSlice(double timelineMs)
    {
        for (var index = 0; index < Mapper.MappedSlices.Count; index++)
        {
            var mapped = Mapper.MappedSlices[index];
            if (timelineMs <= mapped.TimelineStartMs + 100 || timelineMs >= mapped.TimelineEndMs - 100)
            {
                continue;
            }

            var splitSource = mapped.Slice.SourceStartMs + (timelineMs - mapped.TimelineStartMs) * mapped.Slice.Speed;
            var position = index;
            var secondId = NewId();
            Mutate(document =>
            {
                var original = document.Timeline.Slices[position];
                var second = ProjectJson.Clone(original);
                second.Id = secondId;
                second.SourceStartMs = splitSource;
                original.SourceEndMs = splitSource;
                original.Id = NewId();
                document.Timeline.Slices.Insert(position + 1, second);
            });
            Scrub(timelineMs);
            SelectSlice(secondId);
            return true;
        }

        return false;
    }

    public void DeleteSelected()
    {
        if (SelectedZoomId is { } zoomId)
        {
            Mutate(document => document.Timeline.Zooms.RemoveAll(zoom => zoom.Id == zoomId));
        }
        else if (SelectedMaskId is { } maskId)
        {
            Mutate(document =>
            {
                foreach (var track in document.Timeline.MaskTracks)
                {
                    track.Items.RemoveAll(item => item.Id == maskId);
                }
            });
        }
        else if (SelectedSliceId is { } sliceId && Document.Timeline.Slices.Count > 1)
        {
            Mutate(document => document.Timeline.Slices.RemoveAll(slice => slice.Id == sliceId));
        }
        else
        {
            return;
        }

        ClearSelection();
    }

    public static string NewId() => Guid.NewGuid().ToString().ToUpperInvariant();

    private void AfterHistoryMove()
    {
        coalesceKey = null;
        renderDocument = null;
        Mapper = new NLETimeMapper(History.Current.Timeline.Slices);
        PlayheadTimelineMs = Math.Clamp(PlayheadTimelineMs, 0, DurationMs);
        if (SelectedZoom is null)
        {
            SelectedZoomId = null;
        }

        if (SelectedMask is null)
        {
            SelectedMaskId = null;
        }

        DocumentChanged?.Invoke(true);
    }

    private void NormalizeMaskTracks()
    {
        var tracks = History.Current.Timeline.MaskTracks;
        tracks.RemoveAll(track => track.Items.Count == 0);
        for (var index = 0; index < tracks.Count; index++)
        {
            tracks[index].Name = index == 0 ? "Masks" : $"Masks {index + 1}";
        }
    }

    private void ClearSelectionState()
    {
        SelectedSliceId = null;
        SelectedZoomId = null;
        SelectedMaskId = null;
    }
}
