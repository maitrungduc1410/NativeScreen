using System.Runtime.InteropServices;
using System.Security;
using Microsoft.Win32;

namespace NativeScreen.App;

/// <summary>
/// "Open in Native Screen" on project folders. A package is a folder, and Windows applies file type associations only to files,
/// so a double-click cannot reach the app (spec/06 ADR-41). Written at each launch, so it follows the app when it moves.
/// </summary>
internal static partial class ExplorerContextMenu
{
    private const string KeyPath = @"Software\Classes\Directory\shell\NativeScreen.Open";
    private const string CommandName = "command";
    private const int NoPackage = 15700;

    public static void Register()
    {
        // A packaged app's registry writes stay inside its own private view, where Explorer never looks.
        if (Environment.ProcessPath is not { } exe || IsPackaged())
        {
            return;
        }

        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(KeyPath);
            key.SetValue(null, "Open in Native Screen");
            key.SetValue("Icon", $"\"{exe}\",0");
            key.SetValue("AppliesTo", "System.FileName:\"*.nativescreen\"");
            using var command = key.CreateSubKey(CommandName);
            command.SetValue(null, $"\"{exe}\" \"%1\"");
        }
        catch (Exception exception) when (exception is UnauthorizedAccessException or SecurityException or IOException)
        {
            // Only a convenience: projects still open from inside the app.
        }
    }

    public static void Unregister()
    {
        try
        {
            Registry.CurrentUser.DeleteSubKeyTree(KeyPath, throwOnMissingSubKey: false);
        }
        catch (Exception exception) when (exception is UnauthorizedAccessException or SecurityException or IOException)
        {
            // Uninstalling must not stop on this.
        }
    }

    private static bool IsPackaged()
    {
        var length = 0u;
        return GetCurrentPackageFullName(ref length, IntPtr.Zero) != NoPackage;
    }

    [LibraryImport("kernel32.dll")]
    private static partial int GetCurrentPackageFullName(ref uint length, IntPtr name);
}
