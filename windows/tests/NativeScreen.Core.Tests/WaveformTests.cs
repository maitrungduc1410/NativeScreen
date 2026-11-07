using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class WaveformTests
{
    [Fact]
    public void SilenceHasNoWaveform()
    {
        Assert.Null(Waveform.BinsFromPeaks(new float[1000], 256));
        Assert.Null(Waveform.BinsFromPeaks(new float[4], 256));
    }

    [Fact]
    public void OneLoudClickDoesNotFlattenTheRest()
    {
        var peaks = Enumerable.Repeat(0.1f, 1000).ToArray();
        peaks[500] = 1;
        var bins = Waveform.BinsFromPeaks(peaks, 1000)!;
        Assert.Equal(0.98f, bins[0], 3);
        Assert.Equal(0.98f, bins[500], 3);
    }

    [Fact]
    public void QuietPartsKeepAVisibleFloorAndLevelsAreLifted()
    {
        var peaks = new float[1000];
        Array.Fill(peaks, 0.5f);
        for (var index = 0; index < 500; index++)
        {
            peaks[index] = 0.001f;
        }

        peaks[600] = 0.1f;
        var bins = Waveform.BinsFromPeaks(peaks, 1000)!;
        Assert.Equal(0.015f, bins[0], 4);
        // The 95th percentile is the upper edge of its histogram bin, as on macOS: 0.5 is in bin 512 of 1024.
        Assert.Equal(MathF.Pow(0.1f / (513f / 1024f), 0.62f), bins[600], 4);
    }

    [Fact]
    public void BinsNeverExceedTheRawPeaksAndKeepThePeak()
    {
        var peaks = new float[1000];
        Array.Fill(peaks, 0.2f);
        var bins = Waveform.BinsFromPeaks(peaks, 16384)!;
        Assert.Equal(1000, bins.Length);
        Assert.Equal(100, Waveform.BinsFromPeaks(peaks, 100)!.Length);
    }

    [Fact]
    public void ZoomingOutKeepsEveryPeak()
    {
        var samples = new float[1024];
        samples[300] = 1;
        var envelope = new WaveformEnvelope(samples);
        // One control bin covers 32 samples, far more than the single loud one.
        Assert.True(envelope.Read(300.5, 32) > 0.9);
        Assert.Equal(0, envelope.Read(800, 32), 6);
    }

    [Fact]
    public void TheSplineStaysInRangeAndPassesThroughItsBins()
    {
        var samples = new float[64];
        for (var index = 0; index < samples.Length; index++)
        {
            samples[index] = index % 2 == 0 ? 1 : 0;
        }

        var envelope = new WaveformEnvelope(samples);
        Assert.Equal(1, envelope.Read(10.5, 1), 6);
        Assert.Equal(0, envelope.Read(11.5, 1), 6);
        for (var position = 0.0; position < 64; position += 0.13)
        {
            Assert.InRange(envelope.Read(position, 1), 0, 1);
        }
    }

    [Fact]
    public void ControlBinsSpanElevenPointsOfTheSlice()
    {
        var envelope = new WaveformEnvelope(new float[1000]);
        Assert.Equal(1, envelope.SamplesPerBin(0, 0.01, 1000));
        Assert.Equal(11, envelope.SamplesPerBin(0, 1, 1000), 6);
    }

    [Fact]
    public void WaveHeightsFollowTheRow()
    {
        Assert.Equal(32, WaveformRaster.MaximumHeight(52));
        Assert.Equal(20.4, WaveformRaster.MaximumHeight(30), 6);
    }

    [Fact]
    public void AVoiceoverWithoutAReadableFileStillShowsAShape()
    {
        var samples = Waveform.Procedural(3000, 96);
        Assert.Equal(96, samples.Length);
        Assert.All(samples, value => Assert.InRange(value, 0.08f, 0.95f));
    }
}
