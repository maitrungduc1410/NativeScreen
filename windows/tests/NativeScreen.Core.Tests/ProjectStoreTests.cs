using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class ProjectStoreTests : IDisposable
{
    private readonly string directory = Directory.CreateTempSubdirectory("ns-store-").FullName;

    public void Dispose() => Directory.Delete(directory, recursive: true);

    [Fact]
    public void ASavedShowcaseLoadsBackWithItsEdits()
    {
        var package = ShowcaseProject.WritePackage(directory);
        var loaded = new LoadedProject(package);
        Assert.Equal(3, loaded.Document.Timeline.Zooms.Count);
        Assert.Equal("windows", loaded.Metadata.Platform);
        Assert.NotEmpty(loaded.CursorEvents);

        var session = new EditorSession(loaded.Document, loaded.Metadata.DurationMs);
        session.Mutate(document => document.Canvas.PaddingRatio = 0.2);
        var recordingBefore = File.ReadAllBytes(Path.Combine(package, "recording", "metadata.json"));
        ProjectStore.WriteProjectJson(package, ProjectStore.Serialize(session.Document, DateTimeOffset.UtcNow));

        var reloaded = new LoadedProject(package);
        Assert.Equal(0.2, reloaded.Document.Canvas.PaddingRatio);
        Assert.NotEmpty(reloaded.Document.UpdatedAt);
        Assert.Equal(recordingBefore, File.ReadAllBytes(Path.Combine(package, "recording", "metadata.json")));
        Assert.False(File.Exists(Path.Combine(package, "project.json.tmp")));
    }

    [Fact]
    public void PackageNamesNeverCollide()
    {
        var first = ProjectStore.UniquePackagePath(directory, "Demo");
        Directory.CreateDirectory(first);
        Assert.EndsWith("Demo 2.nativescreen", ProjectStore.UniquePackagePath(directory, "Demo"));
    }

    [Theory]
    [InlineData("Launch demo", "Launch demo")]
    [InlineData("  Q3: plan / review?  ", "Q3- plan - review-")]
    [InlineData("Release.nativescreen", "Release")]
    [InlineData("Ends with dots...", "Ends with dots")]
    [InlineData("con", "con-")]
    [InlineData("COM1.notes", "COM1.notes-")]
    [InlineData("Tiếng Việt 日本語", "Tiếng Việt 日本語")]
    [InlineData("   ", null)]
    [InlineData("...", null)]
    public void ProjectNamesBecomeFolderNamesEverySystemAccepts(string name, string? expected) =>
        Assert.Equal(expected, ProjectStore.PackageName(name));

    [Fact]
    public void RenamingMovesNextToTheOldFolderAndNeverOntoAnother()
    {
        var current = Path.Combine(directory, "Recording 2026-11-21 06.31.20.nativescreen");
        Directory.CreateDirectory(current);
        Assert.Equal(Path.Combine(directory, "Launch demo.nativescreen"), ProjectStore.RenamedPackagePath(current, "Launch demo"));
        Assert.Equal(current, ProjectStore.RenamedPackagePath(current, "Recording 2026-11-21 06.31.20"));
        Assert.Equal(Path.Combine(directory, "recording 2026-11-21 06.31.20.nativescreen"), ProjectStore.RenamedPackagePath(current, "recording 2026-11-21 06.31.20"));

        Directory.CreateDirectory(Path.Combine(directory, "Taken.nativescreen"));
        Assert.Equal(Path.Combine(directory, "Taken 2.nativescreen"), ProjectStore.RenamedPackagePath(current + Path.DirectorySeparatorChar, "Taken"));
        Assert.Null(ProjectStore.RenamedPackagePath(current, " .. "));

        var second = Path.Combine(directory, "Taken 2.nativescreen");
        Directory.CreateDirectory(second);
        Assert.Equal(second, ProjectStore.RenamedPackagePath(second, "Taken"));
    }
}
