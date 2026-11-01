using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class PlaybackTests
{
    [Fact]
    public void AudioClockLeadsTheVideoChoice()
    {
        var qpc = 1000.0;
        var clock = new PlaybackClock(() => qpc);
        clock.PrimeAndStart(0);
        clock.Audio = new AudioClockSample(500, 20, 1000);
        qpc = 1030;
        Assert.Equal(510, clock.PositionMs, 6);

        var ring = new FrameRing();
        ring.Push(480);
        ring.Push(500);
        ring.Push(530);
        Assert.Equal(500, ring.NewestAtOrBefore(clock.PositionMs));
    }

    [Fact]
    public void PausedPreviewIdlesAndScrubKeepsTheLatestSeek()
    {
        Assert.True(PreviewScheduler.BlocksIdle(false, false));
        Assert.False(PreviewScheduler.BlocksIdle(true, false));
        var scrub = new ScrubCoalescer();
        var first = scrub.Submit();
        var second = scrub.Submit();
        Assert.False(scrub.IsLatest(first));
        Assert.True(scrub.IsLatest(second));
    }

    [Fact]
    public void LateFramesStayUnderOnePercent()
    {
        var counter = new LateFrameCounter();
        for (var i = 0; i < 100; i++)
        {
            counter.Present(i * 16.7, i * 16.7, 16.7);
        }

        counter.Present(0, 40, 16.7);
        Assert.True(counter.LateRatio < 0.01);
    }
}
