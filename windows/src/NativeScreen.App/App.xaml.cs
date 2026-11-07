using Microsoft.UI.Xaml;
using NativeScreen.Core;

namespace NativeScreen.App;

/// <summary>Starts with only the recording bar, like the macOS app. The bar steps aside for editors and returns when the last one closes.</summary>
public partial class App : Application
{
    private static int openEditors;
    private static TrayIcon? tray;

    public App()
    {
        InitializeComponent();
    }

    public static void EditorOpened()
    {
        openEditors++;
        RecordingHudWindow.HideIfIdle();
    }

    public static void EditorClosed()
    {
        openEditors--;
        if (openEditors == 0)
        {
            InspectorPanel.PurgeCaches();
            RecordingHudWindow.Show();
        }
    }

    /// <summary>Starts a new copy and ends this one, for a change that applies on launch.</summary>
    public static void Restart()
    {
        SingleInstance.Release();
        if (Environment.ProcessPath is { } executable)
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(executable) { UseShellExecute = false });
        }

        Quit();
    }

    public static void Quit()
    {
        RecordingHudWindow.Shutdown();
        tray?.Dispose();
        Current.Exit();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // Explorer passes a package's folder, or the project.json inside it.
        var argument = Environment.GetCommandLineArgs().Skip(1).FirstOrDefault();
        var folder = argument is null ? null : File.Exists(argument) ? Path.GetDirectoryName(argument) : argument;
        if (!SingleInstance.TryClaim() && SingleInstance.Forward(folder))
        {
            Environment.Exit(0);
        }

        // NS_LANGUAGE overrides the setting for one run, for checking a layout in another language.
        Loc.Start(Environment.GetEnvironmentVariable("NS_LANGUAGE") ?? AppSettings.Shared.Language);

        // Nothing may end the process when a window closes: the recording bar can be hidden with no editor open.
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        tray = new TrayIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "app.ico"), "Native Screen", () => RecordingHudWindow.Show(), TrayMenu);
        SingleInstance.Listen(Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread(), OpenRequested);
        _ = Task.Run(ExplorerContextMenu.Register);
        OpenRequested(folder);
    }

    private static void OpenRequested(string? folder)
    {
        if (folder is not null && File.Exists(Path.Combine(folder, "project.json")))
        {
            _ = Projects.Open(folder, null);
        }
        else
        {
            RecordingHudWindow.Show();
        }
    }

    private static IReadOnlyList<(string? Title, Action? Click)> TrayMenu()
    {
        var items = new List<(string?, Action?)>
        {
            ("Show Recording Bar", () => RecordingHudWindow.Show()),
            ("Create Interactive Showcase Project", () => _ = Projects.Open(ShowcaseProject.WritePackage(AppSettings.Shared.ProjectsDirectory), null))
        };
        if (AppSettings.Shared.RecentProjects.Count > 0)
        {
            items.Add((null, null));
            foreach (var path in AppSettings.Shared.RecentProjects.Take(10))
            {
                var target = path;
                items.Add((Path.GetFileNameWithoutExtension(path), () => _ = Projects.Open(target, null)));
            }
        }

        items.Add((null, null));
        items.Add(("Settings", () => new SettingsWindow().Activate()));
        items.Add(("Quit Native Screen", Quit));
        return items;
    }
}
