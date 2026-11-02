using NativeScreen.Media;

namespace NativeScreen.Media.Tests;

/// <summary>A recording has gaps between frames. Whatever Media Foundation reports, a reader must give back the written times.</summary>
public sealed class FragmentedTimingTests : IDisposable
{
    private const int Width = 640;
    private const int Height = 360;
    private readonly string directory = Directory.CreateTempSubdirectory("ns-fragment-").FullName;

    public void Dispose() => Directory.Delete(directory, recursive: true);

    [Fact]
    public void FramesWithGapsReadBackAtTheirWrittenTimes()
    {
        var (path, written) = WriteVariableRateClip();
        using var reader = new VideoFileReader(path);
        var index = 0;
        while (reader.ReadNext() is { } frame)
        {
            Assert.True(Math.Abs(frame.PresentationMs - written[index]) < 2, $"frame {index}: read {frame.PresentationMs}, written {written[index]}");
            index++;
        }

        Assert.Equal(written.Count, index);
    }

    [Theory]
    [InlineData(700)]
    [InlineData(2500)]
    [InlineData(5000)]
    [InlineData(100)]
    public void SeekingLandsOnAFrameAtOrBeforeTheTargetWithItsRealTime(double target)
    {
        var (path, written) = WriteVariableRateClip();
        using var reader = new VideoFileReader(path);
        reader.Seek(target);
        var frame = reader.ReadNext();
        Assert.NotNull(frame);
        Assert.True(frame.PresentationMs <= target + 1, $"landed at {frame.PresentationMs} for {target}");
        Assert.Contains(written, time => Math.Abs(time - frame.PresentationMs) < 2);
        var luma = frame.Nv12[Width * 10 + 10];
        var index = written.FindIndex(time => Math.Abs(time - frame.PresentationMs) < 2);
        Assert.InRange((int)luma, ExpectedLuma(index) - 14, ExpectedLuma(index) + 14);
    }

    private (string Path, List<double> Written) WriteVariableRateClip()
    {
        var path = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".mp4");
        var written = new List<double>();
        var nv12 = new byte[Width * Height * 3 / 2];
        var time = 0.0;
        using (var writer = new VideoFileWriter(path, Width, Height, 60, 4_000_000, hevc: false, fragmented: true))
        {
            for (var index = 0; index < 360; index++)
            {
                Array.Fill(nv12, (byte)ExpectedLuma(index), 0, Width * Height);
                Array.Fill(nv12, (byte)128, Width * Height, Width * Height / 2);
                writer.WriteFrame(nv12, time, 1000.0 / 60);
                written.Add(time);
                // Bursts of motion with still moments between them, like a real screen.
                time += index % 25 == 24 ? 250 : 1000.0 / 60;
            }
        }

        return (path, written);
    }

    private static int ExpectedLuma(int index) => 30 + index % 60 * 3;
}
