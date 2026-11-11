namespace NativeScreen.Media.Tests;

public sealed class DiskSpaceTests
{
    [Fact]
    public void ReadsTheVolumeOfTheNearestFolderThatExists()
    {
        // The projects folder may not exist yet: its volume is read from the nearest parent that does.
        var missing = Path.Combine(Path.GetTempPath(), "ns-disk-" + Guid.NewGuid().ToString("N"), "a", "b");
        Assert.False(Directory.Exists(missing));
        var free = DiskSpace.FreeBytes(missing);
        var temp = DiskSpace.FreeBytes(Path.GetTempPath());
        Assert.NotNull(free);
        Assert.NotNull(temp);
        Assert.True(free > 0);
        // Same volume, read a moment apart.
        Assert.InRange(Math.Abs(free.Value - temp.Value), 0, 200_000_000);
    }
}
