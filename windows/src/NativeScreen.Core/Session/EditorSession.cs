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
        new() { Id = "undo", Title = "Undo", Accelerator = "Ctrl+Z" },
        new() { Id = "redo", Title = "Redo", Accelerator = "Ctrl+Y" },
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
    private readonly PlaybackClock clock;

    public EditorSession(ProjectDocument? document = null, double durationMs = 6000, PlaybackClock? clock = null)
    {
        History = new UndoStack(document ?? new ProjectDocument());
        DurationMs = durationMs;
        this.clock = clock ?? new PlaybackClock();
    }

    public UndoStack History { get; }
    public ProjectDocument Document => History.Current;
    public double DurationMs { get; }
    public double PlayheadTimelineMs { get; private set; }
    public bool IsPlaying => clock.IsRunning;
    public InspectorTab SelectedTab { get; private set; } = InspectorTab.Background;
    public string CommandQuery { get; private set; } = "";
    public bool IsCommandMenuOpen { get; private set; }

    public void TogglePlayback()
    {
        if (clock.IsRunning)
        {
            PlayheadTimelineMs = Math.Clamp(clock.PositionMs, 0, DurationMs);
            clock.Pause();
            return;
        }

        clock.PrimeAndStart(PlayheadTimelineMs);
    }

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

    public void SelectTab(InspectorTab tab) => SelectedTab = tab;

    public void OpenCommandMenu() => IsCommandMenuOpen = true;

    public void SetCommandQuery(string query) => CommandQuery = query;

    public void CloseCommandMenu()
    {
        IsCommandMenuOpen = false;
        CommandQuery = "";
    }

    public void Rename(string name)
    {
        var next = ProjectJson.Clone(Document);
        next.Name = name;
        History.Commit(next);
    }
}
