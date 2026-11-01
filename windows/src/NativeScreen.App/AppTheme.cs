using System.Text.Json;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.UI;

namespace NativeScreen.App;

/// <summary>Settings stored in %LOCALAPPDATA%\NativeScreen\settings.json.</summary>
public sealed class AppSettings
{
    public string Appearance { get; set; } = "dark";
    public List<string> RecentProjects { get; set; } = [];

    private static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NativeScreen", "settings.json");

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

    public static void Register(Window window)
    {
        Windows.Add(new WeakReference<Window>(window));
        window.Closed += (_, _) => Windows.RemoveAll(item => !item.TryGetTarget(out var target) || target == window);
        Apply(window);
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
