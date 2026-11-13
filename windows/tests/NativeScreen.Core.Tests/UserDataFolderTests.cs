using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

/// <summary>User data leaves the installer's folder, so uninstalling the GitHub build no longer deletes it (spec/06 ADR-90).</summary>
public sealed class UserDataFolderTests : IDisposable
{
    private readonly string root = Directory.CreateTempSubdirectory("ns-user-data-").FullName;

    private string Legacy => Path.Combine(root, UserDataFolder.LegacyFolderName);

    private string Target => Path.Combine(root, UserDataFolder.FolderName);

    public void Dispose() => Directory.Delete(root, recursive: true);

    private void Write(string relative, string text = "x")
    {
        var path = Path.Combine(Legacy, relative);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, text);
    }

    // What an older version and the installer leave in %LOCALAPPDATA%\NativeScreen.
    private void OlderInstall()
    {
        Write("settings.json", "{\"Language\":\"vi\"}");
        Write(Path.Combine("Presets", "mine.nspreset"));
        Write(Path.Combine("Models", "modnet.onnx"), new string('m', 1000));
        Write(Path.Combine("WhisperModels", "ggml-base.bin"));
        Write(Path.Combine("BackgroundAudio", "chill-hop.wav"));
        Write(Path.Combine("current", "NativeScreen.App.exe"));
        Write(Path.Combine("packages", "NativeScreen-1.0.6-full.nupkg"));
        Write("Update.exe");
    }

    [Fact]
    public void MovesTheAppsItemsAndLeavesTheInstallersFiles()
    {
        OlderInstall();
        var moved = UserDataFolder.Migrate(Legacy, Target);

        Assert.Equal(UserDataFolder.Items, moved);
        Assert.Equal("{\"Language\":\"vi\"}", File.ReadAllText(Path.Combine(Target, "settings.json")));
        Assert.True(File.Exists(Path.Combine(Target, "Presets", "mine.nspreset")));
        Assert.Equal(1000, new FileInfo(Path.Combine(Target, "Models", "modnet.onnx")).Length);
        Assert.True(File.Exists(Path.Combine(Target, "WhisperModels", "ggml-base.bin")));
        Assert.True(File.Exists(Path.Combine(Target, "BackgroundAudio", "chill-hop.wav")));
        foreach (var item in UserDataFolder.Items)
        {
            Assert.False(Path.Exists(Path.Combine(Legacy, item)), item);
        }

        Assert.True(File.Exists(Path.Combine(Legacy, "current", "NativeScreen.App.exe")));
        Assert.True(File.Exists(Path.Combine(Legacy, "packages", "NativeScreen-1.0.6-full.nupkg")));
        Assert.True(File.Exists(Path.Combine(Legacy, "Update.exe")));
        Assert.False(Path.Exists(Path.Combine(Target, "current")));

        // Uninstalling the GitHub build deletes its folder; the data is no longer in it.
        Directory.Delete(Legacy, recursive: true);
        Assert.True(File.Exists(Path.Combine(Target, "settings.json")));
    }

    [Fact]
    public void RunsOnceAndNeverOverwritesNewerData()
    {
        OlderInstall();
        Directory.CreateDirectory(Target);
        File.WriteAllText(Path.Combine(Target, "settings.json"), "{\"Language\":\"de\"}");

        var moved = UserDataFolder.Migrate(Legacy, Target);
        Assert.DoesNotContain("settings.json", moved);
        Assert.Equal("{\"Language\":\"de\"}", File.ReadAllText(Path.Combine(Target, "settings.json")));
        Assert.True(File.Exists(Path.Combine(Legacy, "settings.json")));
        Assert.Empty(UserDataFolder.Migrate(Legacy, Target));
    }

    [Fact]
    public void CopiesSmallItemsThatCannotMoveAndLeavesModels()
    {
        OlderInstall();
        // Open for reading without delete sharing: the file can be copied but not moved, like a file in use.
        using (new FileStream(Path.Combine(Legacy, "settings.json"), FileMode.Open, FileAccess.Read, FileShare.Read))
        using (new FileStream(Path.Combine(Legacy, "Models", "modnet.onnx"), FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            var moved = UserDataFolder.Migrate(Legacy, Target);
            Assert.Contains("settings.json", moved);
            Assert.DoesNotContain("Models", moved);
        }

        Assert.Equal("{\"Language\":\"vi\"}", File.ReadAllText(Path.Combine(Target, "settings.json")));
        Assert.False(Path.Exists(Path.Combine(Target, "Models")));
        Assert.True(File.Exists(Path.Combine(Legacy, "Models", "modnet.onnx")));
    }

    [Fact]
    public void NothingToMoveIsFine()
    {
        Assert.Empty(UserDataFolder.Migrate(Legacy, Target));
        Assert.Empty(UserDataFolder.Migrate(Target, Target));
    }

    [Fact]
    public void TheFolderIsNotTheInstallersOne() =>
        Assert.NotEqual(UserDataFolder.LegacyFolderName, UserDataFolder.FolderName, StringComparer.OrdinalIgnoreCase);
}
