using System.Globalization;

namespace NativeScreen.Core;

public static class AppVersionText
{
    /// <summary>"Version 1.2.0 (57)". The run number is the fourth part of the file version, and a build without one shows no brackets.</summary>
    public static string Format(string word, string version, string? fileVersion)
    {
        var parts = fileVersion?.Split('.');
        return parts is { Length: >= 4 } && int.TryParse(parts[3], NumberStyles.None, CultureInfo.InvariantCulture, out var run) && run > 0
            ? $"{word} {version} ({run})"
            : $"{word} {version}";
    }
}
