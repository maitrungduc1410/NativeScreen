using System.Text.Json;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.UI;

namespace NativeScreen.App;

/// <summary>Settings stored in settings.json of the user data folder (<see cref="NativeScreen.Core.UserDataFolder"/>).</summary>
public sealed class AppSettings
{
    public string Appearance { get; set; } = "dark";
    public List<string> RecentProjects { get; set; } = [];
    public bool AutosaveEnabled { get; set; } = true;
    public int CountdownSeconds { get; set; } = 3;
    public bool AutoCreateZooms { get; set; } = true;
    public int? HudX { get; set; }
    public int? HudY { get; set; }
    public string? StillExportFolder { get; set; }
    public string? DefaultPresetId { get; set; }
    public string AfterRecording { get; set; } = "project";
    public bool HighlightRecordedArea { get; set; } = true;

    /// <summary>Live drawings stay on screen until cleared instead of fading after 3 s; read when a recording starts.</summary>
    public bool DrawingsStayUntilCleared { get; set; }

    public string LiveDrawingTool { get; set; } = "pen";

    public string LiveDrawingColor { get; set; } = "#FF3B30";

    public bool ShowSpeakerNotes { get; set; }

    public string SpeakerNotesText { get; set; } = "";

    public double SpeakerNotesFontSize { get; set; } = 26;

    public double SpeakerNotesSpeed { get; set; } = 30;

    public bool SpeakerNotesScrollsWhileRecording { get; set; } = true;

    /// <summary>Saved recording setups, per user (spec/06 ADR-76).</summary>
    public List<RecordingProfile> RecordingProfiles { get; set; } = [];
    public bool ShowAudioWaveform { get; set; } = true;
    public bool SmoothWaveform { get; set; } = true;
    public bool SnapToSegments { get; set; } = true;

    /// <summary>Favorite backgrounds in add order: mesh:&lt;id&gt; or wallpaper:&lt;id&gt; (spec/06 ADR-32).</summary>
    public List<string> FavoriteBackgrounds { get; set; } = [];

    /// <summary>Annotation styles the user saved; per user, not in projects (spec/06 ADR-75).</summary>
    public List<NativeScreen.Core.AnnotationStyle> AnnotationStyles { get; set; } = [];

    /// <summary>Settings > AI Agents: lets MCP clients drive the app (spec/06 ADR-52). Off by default; the bridge reads it too.</summary>
    public bool AiAgentsEnabled { get; set; }

    public bool CheckForUpdatesAutomatically { get; set; } = true;

    public DateTimeOffset? LastUpdateCheckUtc { get; set; }

    /// <summary>What Quick export uses, and what agents start from with useQuickExportSettings.</summary>
    public NativeScreen.Core.ExportSettings QuickExport { get; set; } = new();

    /// <summary>A catalog language id, or empty for the system language. Applies on the next launch.</summary>
    public string Language { get; set; } = "";

    public string ProjectsDirectory { get; set; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Native Screen Projects");

    private static string FilePath => NativeScreen.Core.UserDataFolder.PathOf("settings.json");

    public static AppSettings Shared { get; } = Load();

    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        File.WriteAllText(FilePath, JsonSerializer.Serialize(this));
    }

    public void NoteRecent(string path)
    {
        RecentProjects.RemoveAll(item => string.Equals(item, path, StringComparison.OrdinalIgnoreCase));
        RecentProjects.Insert(0, path);
        if (RecentProjects.Count > 12)
        {
            RecentProjects.RemoveRange(12, RecentProjects.Count - 12);
        }

        Save();
    }

    private static AppSettings Load()
    {
        try
        {
            return File.Exists(FilePath)
                ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath)) ?? new AppSettings()
                : new AppSettings();
        }
        catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException)
        {
            return new AppSettings();
        }
    }
}

public static class AppTheme
{
    private static readonly List<WeakReference<Window>> Windows = [];

    public static ElementTheme Current { get; private set; } =
        AppSettings.Shared.Appearance == "light" ? ElementTheme.Light : ElementTheme.Dark;

    public static event Action? Changed;

    public static void Set(ElementTheme theme)
    {
        Current = theme;
        AppSettings.Shared.Appearance = theme == ElementTheme.Light ? "light" : "dark";
        AppSettings.Shared.Save();
        foreach (var reference in Windows)
        {
            if (reference.TryGetTarget(out var window))
            {
                Apply(window);
            }
        }

        Changed?.Invoke();
    }

    public static IReadOnlyList<Window> OpenWindows()
    {
        var open = new List<Window>();
        foreach (var reference in Windows)
        {
            if (reference.TryGetTarget(out var window))
            {
                open.Add(window);
            }
        }

        return open;
    }

    public static void Register(Window window)    {
        Windows.Add(new WeakReference<Window>(window));
        window.AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "app.ico"));
        // Static and removed on close: a handler on a Window that captures it keeps the window alive for good (spec/06 ADR-48).
        window.Closed += Unregister;
        Apply(window);
    }

    private static void Unregister(object sender, WindowEventArgs args)
    {
        var window = (Window)sender;
        window.Closed -= Unregister;
        Windows.RemoveAll(item => !item.TryGetTarget(out var target) || target == window);
    }

    private static void Apply(Window window)
    {
        if (window.Content is FrameworkElement root)
        {
            root.RequestedTheme = Current;
        }

        ApplyCaptionButtons(window.AppWindow.TitleBar);
    }

    // Without explicit colors the caption glyphs follow the OS theme, not the app's, and vanish on a dark bar.
    private static void ApplyCaptionButtons(AppWindowTitleBar bar)
    {
        var dark = Current == ElementTheme.Dark;
        var ink = dark ? Colors.White : Color.FromArgb(255, 18, 18, 23);
        byte tone = dark ? (byte)255 : (byte)0;
        bar.ButtonBackgroundColor = Colors.Transparent;
        bar.ButtonInactiveBackgroundColor = Colors.Transparent;
        bar.ButtonForegroundColor = ink;
        bar.ButtonInactiveForegroundColor = Color.FromArgb(120, ink.R, ink.G, ink.B);
        bar.ButtonHoverBackgroundColor = Color.FromArgb(26, tone, tone, tone);
        bar.ButtonHoverForegroundColor = ink;
        bar.ButtonPressedBackgroundColor = Color.FromArgb(46, tone, tone, tone);
        bar.ButtonPressedForegroundColor = ink;
    }
}
