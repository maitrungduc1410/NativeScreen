using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class BuiltInBackgroundMusicTests
{
    [Fact]
    public void TracksAreSixteenSecondsOfAudibleStereo()
    {
        var pcm = BuiltInBackgroundMusic.Synthesize("Sunny Lo-Fi");
        Assert.Equal(44_100 * 16 * 2, pcm.Length);
        Assert.True(pcm.Max(sample => Math.Abs((int)sample)) > 8000);
        Assert.All(pcm, sample => Assert.InRange((int)sample, -32000, 32000));
    }

    [Fact]
    public void TracksDifferAndRepeat()
    {
        Assert.NotEqual(BuiltInBackgroundMusic.Synthesize("Sunny Lo-Fi"), BuiltInBackgroundMusic.Synthesize("Lean Groove"));
        Assert.Equal(BuiltInBackgroundMusic.Synthesize("Soft Rain"), BuiltInBackgroundMusic.Synthesize("Soft Rain"));
    }

    [Fact]
    public void UnknownNamesDoNotResolve()
    {
        Assert.Null(BuiltInBackgroundMusic.ResolvePath(null, "not a track"));
        Assert.Null(BuiltInBackgroundMusic.ResolvePath(null, null));
    }

    [Fact]
    public void PackageFilesWinOverBuiltIns()
    {
        var directory = Directory.CreateTempSubdirectory("ns-music-").FullName;
        try
        {
            Directory.CreateDirectory(Path.Combine(directory, "assets"));
            var file = Path.Combine(directory, "assets", "song.wav");
            File.WriteAllBytes(file, [1]);
            Assert.Equal(file, BuiltInBackgroundMusic.ResolvePath(directory, "assets/song.wav")?.Replace('/', '\\'));
            Assert.Equal(file, BuiltInBackgroundMusic.ResolvePath(directory, "song.wav"));
        }
        finally
        {
            Directory.Delete(directory, true);
        }
    }
}
