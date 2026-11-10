#if !NS_STORE
using Velopack;
using Velopack.Sources;

namespace NativeScreen.App;

/// <summary>
/// App updates through Velopack, from the GitHub releases (spec/06 ADR-53). Only an installed copy has an updater: a build
/// run from the source tree never replaces itself. An update is downloaded in the background and installed when the user
/// asks for it. The Store build compiles <c>AppUpdater.Store.cs</c> instead (spec/06 ADR-81).
/// </summary>
internal sealed class AppUpdater
{
    private const string Repository = "https://github.com/maitrungduc1410/NativeScreen";
    private static readonly TimeSpan CheckInterval = TimeSpan.FromDays(1);
    private static readonly TimeSpan StartupDelay = TimeSpan.FromSeconds(30);

    private readonly UpdateManager? manager = Create();
    private UpdateInfo? ready;

    public static AppUpdater Shared { get; } = new();

    public event Action? Changed;

    public bool IsAvailable => manager is not null;

    public bool IsChecking { get; private set; }

    /// <summary>The outcome of the last check the user can see, untranslated, or null.</summary>
    public string? Status { get; private set; }

    public string? ReadyVersion => ready?.TargetFullRelease.Version.ToString();

    /// <summary>The installed version with its pre-release suffix. Null in a build run from the source tree.</summary>
    public string? InstalledVersion => manager?.CurrentVersion?.ToString();

    private static UpdateManager? Create()
    {
        try
        {
            var created = new UpdateManager(new GithubSource(Repository, null, false));
            return created.IsInstalled ? created : null;
        }
        catch (Exception)
        {
            // Not installed, or the install is damaged. The app works without updates either way.
            return null;
        }
    }

    /// <summary>Checks once a day while the setting is on. The wait is a timer, so it costs nothing at rest.</summary>
    public async Task StartBackgroundChecks()
    {
        if (manager is null)
        {
            return;
        }

        await Task.Delay(StartupDelay);
        while (true)
        {
            var settings = AppSettings.Shared;
            var due = (settings.LastUpdateCheckUtc ?? DateTimeOffset.MinValue) + CheckInterval - DateTimeOffset.UtcNow;
            if (due > TimeSpan.Zero)
            {
                await Task.Delay(due);
            }

            if (settings.CheckForUpdatesAutomatically && ready is null)
            {
                await Check();
            }
            else
            {
                await Task.Delay(CheckInterval);
            }
        }
    }

    public async Task Check()
    {
        if (manager is not { } updates || IsChecking || ready is not null)
        {
            return;
        }

        IsChecking = true;
        Status = "Checking for updates...";
        Changed?.Invoke();
        try
        {
            var found = await Task.Run(() => updates.CheckForUpdatesAsync());
            if (found is null)
            {
                Status = "You have the latest version.";
            }
            else
            {
                await Task.Run(() => updates.DownloadUpdatesAsync(found));
                ready = found;
                Status = null;
            }

            AppSettings.Shared.LastUpdateCheckUtc = DateTimeOffset.UtcNow;
            AppSettings.Shared.Save();
        }
        catch (Exception)
        {
            // Offline, rate limited, or a bad download. A failed check must never get in the way of the app.
            Status = "Could not check for updates.";
        }

        IsChecking = false;
        Changed?.Invoke();
    }

    /// <summary>Applies the downloaded update once this process has exited, then starts the new version.</summary>
    public void InstallAndRestart()
    {
        if (manager is { } updates && ready is { } update)
        {
            updates.WaitExitThenApplyUpdates(update.TargetFullRelease, silent: false, restart: true);
            App.Quit();
        }
    }
}
#endif
