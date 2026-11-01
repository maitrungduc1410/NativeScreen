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

    public static void WriteLines<T>(string path, IEnumerable<T> items)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllLines(path, items.Select(item => JsonSerializer.Serialize(item, ProjectJson.Compact)));
    }
}
