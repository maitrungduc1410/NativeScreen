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
}
