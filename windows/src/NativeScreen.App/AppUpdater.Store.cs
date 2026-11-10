#if NS_STORE
namespace NativeScreen.App;

/// <summary>
/// The Store build's updater: none. The Store installs and updates the package, and two updaters must never act on one
/// install, so this build has no Velopack at all (spec/06 ADR-81). Same members as the Velopack updater in
/// <c>AppUpdater.cs</c>, so Settings and the tray menu need no build switches: they hide their update items when
/// <see cref="IsAvailable"/> is false.
/// </summary>
internal sealed class AppUpdater
{
    public static AppUpdater Shared { get; } = new();

    public event Action? Changed
    {
        add { }
        remove { }
    }

    public bool IsAvailable => false;

    public bool IsChecking => false;

    public string? Status => null;

    public string? ReadyVersion => null;

    /// <summary>The package version, since the Store build is always installed from its package.</summary>
    public string? InstalledVersion => AppPackage.Version;

    public Task StartBackgroundChecks() => Task.CompletedTask;

    public Task Check() => Task.CompletedTask;

    public void InstallAndRestart()
    {
    }
}
#endif
