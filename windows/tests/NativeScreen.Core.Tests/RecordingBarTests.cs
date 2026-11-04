using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class RecordingBarTests
{
    [Fact]
    public void MeterRisesFastAndThePeakFallsBehindIt()
    {
        var meter = new MicrophoneLevelMeter();
        meter.Add(0.5, 0);
        var rising = meter.Level;
        Assert.InRange(rising, 0.5, 1);
        meter.Add(0, 33);
        Assert.True(meter.Level < rising);
        Assert.Equal(rising, meter.PeakHold);
        for (var time = 66; time < 3000; time += 33)
        {
            meter.Add(0, time);
        }

        Assert.True(meter.Level < 0.001 && meter.PeakHold < 0.001, $"{meter.Level} {meter.PeakHold}");
    }

    [Theory]
    [InlineData(0, 0)]
    [InlineData(0.001, 0)]
    [InlineData(1, 0.95)]
    public void PerceptualCurveMatchesTheDecibelRange(double peak, double atLeast)
    {
        Assert.InRange(MicrophoneLevelMeter.Perceptual(peak), atLeast, atLeast == 0 ? 0 : 1);
    }

    [Fact]
    public void PreviewCropsTheCenterAndMirrors()
    {
        const int width = 8;
        const int height = 4;
        var nv12 = new byte[width * height * 3 / 2];
        Array.Fill(nv12, (byte)128, width * height, width * height / 2);
        // The left half of the cropped square is bright, so the mirrored picture has it on the right.
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                nv12[y * width + x] = (byte)(x is >= 2 and < 4 ? 235 : 16);
            }
        }

        var bgra = new byte[4 * 4 * 4];
        CameraPreviewPixels.ToMirroredSquare(nv12, width, height, bgra, 4);
        Assert.Equal(0, bgra[0]);
        Assert.Equal(255, bgra[2 * 4]);
        Assert.Equal(255, bgra[3 * 4 + 3]);
    }
}
