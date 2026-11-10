using System.Diagnostics;
using System.Runtime.InteropServices;

namespace NativeScreen.App;

/// <summary>
/// What changes when the app runs from its MSIX package (the Store build, spec/06 ADR-81). The package folder is named
/// after the version, so nothing outside the process may keep its path: clients start the execution alias, and a new copy
/// is started through the shell by the app's user model ID. Win32 calls only, because the MCP bridge asks before WinRT is set up.
/// </summary>
internal static partial class AppPackage
{
    private const int InsufficientBuffer = 122;

    /// <summary>The <c>Application Id</c> in Package.appxmanifest.</summary>
    private const string ApplicationId = "App";

    /// <summary>The package family name (stable across versions), or null when not packaged.</summary>
    public static string? FamilyName { get; } = ReadFamilyName();

    public static bool IsPackaged => FamilyName is not null;

    /// <summary>
    /// The execution alias declared in Package.appxmanifest. Windows keeps this file pointing at the installed version, and
    /// its folder is on the user's PATH by default; the full path also works for clients started without that PATH.
    /// </summary>
    public static string ExecutionAlias { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps", "nativescreen.exe");

    /// <summary>The command MCP clients should run: the alias when packaged, otherwise this executable.</summary>
    public static string ClientCommand => IsPackaged ? ExecutionAlias : Environment.ProcessPath ?? "NativeScreen.App.exe";

    /// <summary>"1.2.0" from the package version, or null when not packaged. Needs WinRT, so the UI process only.</summary>
    public static string? Version
    {
        get
        {
            if (!IsPackaged)
            {
                return null;
            }

            var version = Windows.ApplicationModel.Package.Current.Id.Version;
            return $"{version.Major}.{version.Minor}.{version.Build}";
        }
    }

    /// <summary>
    /// Activates the installed package through the shell, as Start does. Used instead of starting the exe by path, which
    /// points into a versioned folder. Through the shell, so the new process inherits neither handles nor stdout.
    /// </summary>
    public static void LaunchNewCopy()
    {
        Process.Start(new ProcessStartInfo($@"shell:AppsFolder\{FamilyName}!{ApplicationId}") { UseShellExecute = true })?.Dispose();
    }

    private static unsafe string? ReadFamilyName()
    {
        // Fails with "no package" when unpackaged; any other failure is treated the same way.
        var length = 0u;
        if (GetCurrentPackageFamilyName(ref length, null) != InsufficientBuffer || length == 0)
        {
            return null;
        }

        var buffer = new char[length];
        fixed (char* name = buffer)
        {
            return GetCurrentPackageFamilyName(ref length, name) == 0 ? new string(name, 0, (int)length - 1) : null;
        }
    }

    [LibraryImport("kernel32.dll")]
    private static unsafe partial int GetCurrentPackageFamilyName(ref uint length, char* name);
}
