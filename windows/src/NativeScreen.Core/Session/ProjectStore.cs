using System.Globalization;
using System.Text.Json;

namespace NativeScreen.Core;

/// <summary>Reads and writes the mutable part of a .nativescreen package. recording/ is never rewritten after capture.</summary>
public static class ProjectStore
{
    public const string PackageExtension = ".nativescreen";

    public static string Serialize(ProjectDocument document, DateTimeOffset now)
    {
        var copy = ProjectJson.Clone(document);
        copy.UpdatedAt = now.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
        return ProjectJson.Serialize(copy);
    }

    /// <summary>Replaces project.json in one step, so a crash leaves the old or the new file, never half of one.</summary>
    public static void WriteProjectJson(string packageDirectory, string json)
    {
        Directory.CreateDirectory(Path.Combine(packageDirectory, "assets"));
        var target = Path.Combine(packageDirectory, "project.json");
        var temporary = target + ".tmp";
        File.WriteAllText(temporary, json);
        File.Move(temporary, target, overwrite: true);
    }

    /// <summary>Runs a write after the one before it. That one's failure was reported to its own caller and must not stop this write.</summary>
    public static Task WriteAfter(Task previous, Action write) => Task.Run(async () =>
    {
        try
        {
            await previous;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // A locked file a moment ago says nothing about now.
        }

        write();
    });

    /// <summary>A name free in the directory: "Name", then "Name 2", "Name 3".</summary>
    public static string UniquePackagePath(string directory, string name)
    {
        var path = Path.Combine(directory, name + PackageExtension);
        for (var index = 2; Directory.Exists(path); index++)
        {
            path = Path.Combine(directory, $"{name} {index}{PackageExtension}");
        }

        return path;
    }

    private const int MaximumNameLength = 120;
    private const string ForbiddenCharacters = "<>:\"/\\|?*";
    private static readonly HashSet<string> ReservedNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
    };

    /// <summary>
    /// A project name as a folder name that works on Windows and macOS: characters a file name cannot hold become "-", a
    /// trailing ".nativescreen" and trailing dots and spaces go. Null when nothing is left.
    /// </summary>
    public static string? PackageName(string name)
    {
        var text = name.Trim();
        if (text.EndsWith(PackageExtension, StringComparison.OrdinalIgnoreCase))
        {
            text = text[..^PackageExtension.Length];
        }

        var characters = text.Select(character => character < 32 || ForbiddenCharacters.Contains(character) ? '-' : character).ToArray();
        text = new string(characters).TrimEnd('.', ' ').Trim();
        if (text.Length > MaximumNameLength)
        {
            text = text[..MaximumNameLength].TrimEnd('.', ' ');
        }

        if (ReservedNames.Contains(text.Split('.')[0]))
        {
            text += "-";
        }

        return text.Length == 0 ? null : text;
    }

    /// <summary>
    /// Where a package moves when its project is renamed (spec/06 ADR-99): the same folder for the same name, the new name
    /// next to it, or "Name 2" when another package already has the name. Null when the name gives no folder name.
    /// </summary>
    public static string? RenamedPackagePath(string packagePath, string name)
    {
        if (PackageName(name) is not { } folder)
        {
            return null;
        }

        var trimmed = packagePath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var directory = Path.GetDirectoryName(trimmed) ?? "";
        var current = Path.GetFileName(trimmed);
        var wanted = folder + PackageExtension;
        if (string.Equals(current, wanted, StringComparison.Ordinal))
        {
            return trimmed;
        }

        // Only the case changes: the same folder on Windows, so it is not "taken".
        if (string.Equals(current, wanted, StringComparison.OrdinalIgnoreCase))
        {
            return Path.Combine(directory, wanted);
        }

        // "Name 2" when another package has the name; the package's own folder counts as free, so it never moves to "Name 3".
        var path = Path.Combine(directory, wanted);
        for (var index = 2; Directory.Exists(path) && !string.Equals(path, trimmed, StringComparison.OrdinalIgnoreCase); index++)
        {
            path = Path.Combine(directory, $"{folder} {index}{PackageExtension}");
        }

        return path;
    }

    public static void WriteLines<T>(string path, IEnumerable<T> items)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllLines(path, items.Select(item => JsonSerializer.Serialize(item, ProjectJson.Compact)));
    }
}
