using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class ExportJobTests
{
    [Fact]
    public void ExportProgressCountsEncodedFramesAndCancelDropsTheFile()
    {
        Assert.Equal(360, ExportPlan.FrameCount(6000, 60));
        Assert.Equal(87, ExportPlan.Quality(ExportCompression.Studio));
        Assert.False(ExportPlan.IsAvailableOnWindows(ExportFormat.ProRes));
        var job = new ExportJob(4, "out.mp4");
        Assert.True(job.TryEncodeFrame());
        Assert.Equal(0.25, job.Progress, 6);
        job.Cancel();
        Assert.False(job.TryEncodeFrame());
        Assert.True(job.ShouldDeletePartial);
    }

    [Fact]
    public void AudioGainsMatchTheMacExporter()
    {
        var audio = new AudioConfig();
        var slice = new ClipSlice();
        Assert.Equal(1, AudioMix.SystemGain(audio, slice, 1), 6);
        Assert.Equal(1, AudioMix.MicrophoneGain(audio, slice, 1, false), 6);
        Assert.Equal(0, AudioMix.MicrophoneGain(audio, slice, 1, true), 6);
        Assert.Equal(0.2, AudioMix.MusicGain(audio, 1), 6);
        var voice = new VoiceoverSegment { Volume = 0.5 };
        Assert.Equal(0.5, AudioMix.VoiceoverGain(voice, 1, false), 6);
    }
}
