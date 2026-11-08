namespace NativeScreen.Core.Tests;

public sealed class AutoZoomMergeTests
{
    private static ClickEvent Click(double t) => new() { T = t, Type = "down", X = 0.5, Y = 0.5 };

    [Fact]
    public void ZoomsLessThanOneAndAHalfSecondsApartBecomeOne()
    {
        var zooms = AutoZoomClusterGenerator.GenerateZooms([Click(0), Click(3000), Click(6000)], [], 12000);
        var zoom = Assert.Single(zooms);
        Assert.Equal(0, zoom.SourceStartMs);
        Assert.Equal(8500, zoom.SourceEndMs);
    }

    [Fact]
    public void ZoomsFartherApartStaySeparate()
    {
        Assert.Equal(2, AutoZoomClusterGenerator.GenerateZooms([Click(0), Click(9000)], [], 15000).Count);
    }
}
