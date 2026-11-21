using System.Globalization;

namespace NativeScreen.Core;

public static class AppVersionText
{
    /// <summary>
    /// "Version 1.2.0 (GitHub)", or "Version 1.2.0 (57, GitHub)" with the run number, the fourth part of the file version. The
    /// channel says where the app came from ("Microsoft Store", "GitHub", "App Store" on macOS), so a report names the build.
    /// </summary>
    public static string Format(string word, string version, string? fileVersion, string channel)
    {
        var parts = fileVersion?.Split('.');
        return parts is { Length: >= 4 } && int.TryParse(parts[3], NumberStyles.None, CultureInfo.InvariantCulture, out var run) && run > 0
            ? $"{word} {version} ({run}, {channel})"
            : $"{word} {version} ({channel})";
    }
}
