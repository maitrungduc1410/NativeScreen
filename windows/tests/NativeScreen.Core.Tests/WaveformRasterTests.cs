using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class WaveformRasterTests
{
    private static readonly WaveformEnvelope Flat = new(Enumerable.Repeat(1f, 64).ToArray());

    private static WaveformBitmap Draw(double volume, bool smooth = true) =>
        WaveformRaster.Rasterize([new WaveformRasterLayer(Flat, volume, 1, 1, 1, 0.5)], 0, 1, 100, 48, 1, smooth)!;

    private static byte Alpha(WaveformBitmap bitmap, int x, int fromBottom) =>
        bitmap.Pixels[((bitmap.Height - 1 - fromBottom) * bitmap.Width + x) * 4 + 3];

    [Fact]
    public void AtFullVolumeOnlyTheWaveIsDrawn()
    {
        var bitmap = Draw(1);
        // 48 * 0.68 = 32.6, capped at 32 points.
        Assert.True(Alpha(bitmap, 50, 30) > 0);
        Assert.Equal(0, Alpha(bitmap, 50, 33));
        // Half at the bottom, full at the crest: 0.5 * 0.5 and 0.5 * ~1.
        Assert.InRange(Alpha(bitmap, 50, 0), 63, 66);
        Assert.InRange(Alpha(bitmap, 50, 30), 120, 128);
    }

    [Fact]
    public void BelowFullVolumeTheFullWaveShowsFaintly()
    {
        var bitmap = Draw(0.5);
        // The scaled wave ends near 16 points; above it only the 0.10 copy is left.
        var faint = Alpha(bitmap, 50, 25);
        Assert.InRange(faint, 15, 26);
        Assert.Equal(0, Alpha(bitmap, 50, 33));
        Assert.True(Alpha(bitmap, 50, 10) > faint);
    }

    [Fact]
    public void AtZeroVolumeOnlyTheCopyIsLeft()
    {
        var bitmap = Draw(0);
        Assert.InRange(Alpha(bitmap, 50, 30), 20, 26);
        Assert.InRange(Alpha(bitmap, 50, 0), 12, 13);
    }

    [Fact]
    public void BarsLeaveAGapEveryThirdPoint()
    {
        var bitmap = Draw(1, smooth: false);
        Assert.True(Alpha(bitmap, 0, 5) > 0);
        Assert.True(Alpha(bitmap, 1, 5) > 0);
        Assert.Equal(0, Alpha(bitmap, 2, 5));
    }

    [Fact]
    public void PixelsArePremultipliedBgra()
    {
        var bitmap = WaveformRaster.Rasterize([new WaveformRasterLayer(Flat, 1, 77 / 255.0, 47 / 255.0, 245 / 255.0, 0.5)], 0, 1, 10, 48, 2, true)!;
        Assert.Equal(20, bitmap.Width);
        Assert.Equal(96, bitmap.Height);
        var offset = ((bitmap.Height - 1 - 40) * bitmap.Width + 5) * 4;
        var alpha = bitmap.Pixels[offset + 3];
        Assert.True(bitmap.Pixels[offset] > bitmap.Pixels[offset + 2]);
        Assert.True(bitmap.Pixels[offset] <= alpha);
    }

    [Fact]
    public void RoundedCornersCutTheBottomCorners()
    {
        var bitmap = WaveformRaster.Rasterize([new WaveformRasterLayer(Flat, 1, 1, 1, 1, 0.5)], 0, 1, 100, 48, 1, true, cornerRadius: 8)!;
        Assert.Equal(0, Alpha(bitmap, 0, 0));
        Assert.True(Alpha(bitmap, 50, 0) > 0);
    }
}
