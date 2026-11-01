using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class Nv12ConverterTests
{
    [Theory]
    [InlineData(255, 255, 255)]
    [InlineData(0, 0, 0)]
    [InlineData(230, 80, 60)]
    [InlineData(60, 190, 140)]
    [InlineData(80, 140, 240)]
    public void ConvertingBackGivesTheOriginalColor(int red, int green, int blue)
    {
        const int size = 4;
        var bgra = new byte[size * size * 4];
        for (var i = 0; i < size * size; i++)
        {
            bgra[i * 4] = (byte)blue;
            bgra[i * 4 + 1] = (byte)green;
            bgra[i * 4 + 2] = (byte)red;
            bgra[i * 4 + 3] = 255;
        }

        var nv12 = new byte[size * size * 3 / 2];
        Nv12Converter.FromBgra(bgra, nv12, size, size);
        var back = Rgba.Bt709LimitedToRgb(nv12[0] / 255.0, nv12[size * size] / 255.0, nv12[size * size + 1] / 255.0);
        Assert.InRange(back.R * 255, red - 3, red + 3);
        Assert.InRange(back.G * 255, green - 3, green + 3);
        Assert.InRange(back.B * 255, blue - 3, blue + 3);
    }

    [Fact]
    public void WhiteAndBlackUseTheLimitedRange()
    {
        var bgra = new byte[16];
        Array.Fill(bgra, (byte)255);
        var nv12 = new byte[6];
        Nv12Converter.FromBgra(bgra, nv12, 2, 2);
        Assert.Equal(235, nv12[0]);
        Assert.Equal(128, nv12[4]);
        Assert.Equal(128, nv12[5]);
        Nv12Converter.FromBgra(new byte[16], nv12, 2, 2);
        Assert.Equal(16, nv12[0]);
    }
}
