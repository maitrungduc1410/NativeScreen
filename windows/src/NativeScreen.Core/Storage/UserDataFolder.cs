namespace NativeScreen.Core;

/// <summary>
/// Where the app keeps what it creates for the user: settings, presets, downloaded models and the music cache (spec/06 ADR-90).
/// It is not <c>%LOCALAPPDATA%\NativeScreen</c>: that folder is the installer's own (Velopack installs there and deletes it on
/// uninstall), so anything kept in it was lost when the GitHub build was removed, for example to switch to the Store build.
/// The first time the folder is asked for, what an older version left in the install folder is moved over.
/// </summary>
public static class UserDataFolder
{
    public const string FolderName = "NativeScreen Data";

    /// <summary>The install folder of the GitHub build, where versions before 2026-11-14 also kept their data.</summary>
    public const string LegacyFolderName = "NativeScreen";

    /// <summary>What the app itself made in the old folder; nothing else there is touched (the installer's files stay).</summary>
    public static readonly string[] Items = ["settings.json", "Presets", "Models", "WhisperModels", "BackgroundAudio"];

    // Small and not downloadable again: copied when they cannot be moved. Models and the music cache are made again on demand.
    private static readonly HashSet<string> CopyWhenMoveFails = ["settings.json", "Presets"];

    private static readonly object Gate = new();
    private static string? root;

    /// <summary>The folder, created and migrated on first use. Safe to call from any thread.</summary>
    public static string Root
    {
        get
        {
            lock (Gate)
            {
                if (root is null)
                {
                    // NS_LOCAL_APP_DATA stands in for %LOCALAPPDATA%, so tests and trial runs never move a real user's data.
                    var local = Environment.GetEnvironmentVariable("NS_LOCAL_APP_DATA") is { Length: > 0 } sandbox
                        ? sandbox
                        : Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                    var target = Path.Combine(local, FolderName);
                    Migrate(Path.Combine(local, LegacyFolderName), target);
                    Directory.CreateDirectory(target);
                    root = target;
                }

                return root;
            }
        }
    }

    /// <summary>A path inside the folder, for example <c>PathOf("Models", "modnet.onnx")</c>.</summary>
    public static string PathOf(params string[] parts) => Path.Combine([Root, .. parts]);

    /// <summary>
    /// Moves each known item from <paramref name="legacy"/> to <paramref name="target"/> when the target does not have it yet. A
    /// move is a rename on the same volume, so even large models move at once. An item that cannot be moved (in use, or a
    /// packaged app that may not change the real folder) is copied when it is small, otherwise left for the app to make again.
    /// Never throws: a failed migration must not stop the app from starting. Returns what was moved or copied.
    /// </summary>
    public static IReadOnlyList<string> Migrate(string legacy, string target)
    {
        var done = new List<string>();
        try
        {
            if (!Directory.Exists(legacy) || string.Equals(Path.GetFullPath(legacy), Path.GetFullPath(target), StringComparison.OrdinalIgnoreCase))
            {
                return done;
            }

            Directory.CreateDirectory(target);
            foreach (var item in Items)
            {
                var from = Path.Combine(legacy, item);
                var to = Path.Combine(target, item);
                var isFile = File.Exists(from);
                if ((!isFile && !Directory.Exists(from)) || File.Exists(to) || Directory.Exists(to))
                {
                    continue;
                }

                try
                {
                    if (isFile)
                    {
                        File.Move(from, to);
                    }
                    else
                    {
                        Directory.Move(from, to);
                    }

                    done.Add(item);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    if (CopyWhenMoveFails.Contains(item) && TryCopy(from, to, isFile))
                    {
                        done.Add(item);
                    }
                }
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
        }

        return done;
    }

    private static bool TryCopy(string from, string to, bool isFile)
    {
        try
        {
            if (isFile)
            {
                File.Copy(from, to);
                return true;
            }

            foreach (var directory in Directory.EnumerateDirectories(from, "*", SearchOption.AllDirectories))
            {
                Directory.CreateDirectory(Path.Combine(to, Path.GetRelativePath(from, directory)));
            }

            Directory.CreateDirectory(to);
            foreach (var file in Directory.EnumerateFiles(from, "*", SearchOption.AllDirectories))
            {
                File.Copy(file, Path.Combine(to, Path.GetRelativePath(from, file)));
            }

            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }
}
