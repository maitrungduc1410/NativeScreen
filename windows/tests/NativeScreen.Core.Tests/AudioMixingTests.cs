using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class AudioMixingTests
{
    [Fact]
    public void SourcesAddAtTheirPositionsAndGapsAreSilent()
    {
        var mixer = new AudioFrameMixer(1, 100, 2);
        mixer.Add(0, [100, 100], 1);
        mixer.Add(1, [10, 10], 2);
        var output = new short[10];
        Assert.Equal(5, mixer.Drain(5, output));
        Assert.Equal(new short[] { 0, 100, 110, 10, 0 }, output[..5]);
        Assert.Equal(0, mixer.Drain(5, output));
    }

    [Fact]
    public void LoudSourcesClipInsteadOfWrapping()
    {
        var mixer = new AudioFrameMixer(1, 10, 2);
        mixer.Add(0, [30000, -30000], 0);
        mixer.Add(1, [30000, -30000], 0);
        var output = new short[2];
        mixer.Drain(2, output);
        Assert.Equal(new short[] { short.MaxValue, short.MinValue }, output);
    }

    [Fact]
    public void ClockJitterKeepsASourceContiguousButAJumpMovesIt()
    {
        var mixer = new AudioFrameMixer(1, 10000, 1);
        mixer.Add(0, [1, 1], 0);
        // 100 frames off is jitter: this lands right after the last sample.
        mixer.Add(0, [2], 100);
        mixer.Add(0, [3], 5000);
        var output = new short[6000];
        mixer.Drain(6000, output);
        Assert.Equal(2, output[2]);
        Assert.Equal(0, output[100]);
        Assert.Equal(3, output[5000]);
    }

    [Fact]
    public void WrapsAroundTheRingAndDropsWhatIsTooLateOrTooEarly()
    {
        var mixer = new AudioFrameMixer(2, 4, 3);
        var output = new short[8];
        Assert.Equal(3, mixer.Drain(3, output));
        mixer.Add(0, [1, 2, 3, 4], 3);
        mixer.Add(1, [9, 9], 1);
        mixer.Add(2, [7, 7], 50);
        Assert.Equal(2, mixer.Drain(5, output));
        Assert.Equal(new short[] { 1, 2, 3, 4 }, output[..4]);
    }

    [Fact]
    public void OnlyTheTopOfAnAppsProcessTreeIsCaptured()
    {
        var processes = new List<(int Id, int ParentId, string Name)>
        {
            (10, 1, "chrome"),
            (11, 10, "chrome"),
            (12, 11, "Chrome"),
            (20, 1, "chrome"),
            (30, 10, "helper"),
            (40, 1, "spotify"),
            (50, 50, "code")
        };
        Assert.Equal(new[] { 10, 20 }, AudioAppRoots.Select(processes, ["chrome"], 8));
        Assert.Equal(new[] { 10 }, AudioAppRoots.Select(processes, ["chrome"], 1));
        Assert.Equal(new[] { 40, 50 }, AudioAppRoots.Select(processes, ["SPOTIFY", "code"], 8));
        Assert.Empty(AudioAppRoots.Select(processes, ["missing"], 8));
    }
}
