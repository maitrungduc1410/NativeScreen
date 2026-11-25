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

    /// <summary>
    /// A still moment just before a keyframe, where one fragment ends and the next begins (spec/06 ADR-110). The fragments
    /// carry no decode time, so the last frame of a fragment must have its real duration, or every later frame moves earlier
    /// and the video runs ahead of the cursor. Checked on the fragmented file and after it is made plain.
    /// </summary>
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void AStillMomentAtAFragmentBoundaryKeepsItsLength(bool plain)
    {
        var path = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".mp4");
        var written = new List<double>();
        var nv12 = new byte[Width * Height * 3 / 2];
        var time = 0.0;
        using (var writer = new VideoFileWriter(path, Width, Height, 60, 4_000_000, hevc: false, fragmented: true))
        {
            for (var index = 0; index < 400; index++)
            {
                Array.Fill(nv12, (byte)ExpectedLuma(index), 0, Width * Height);
                Array.Fill(nv12, (byte)128, Width * Height, Width * Height / 2);
                writer.WriteFrame(nv12, time, 1000.0 / 60);
                written.Add(time);
                // A keyframe every 120 frames (2 s at 60 fps); the frame before each one stays on screen for 250 ms.
                time += index % 120 == 119 ? 250 : 1000.0 / 60;
            }
        }

        if (plain)
        {
            Assert.True(Mp4Defragmenter.TryRewrite(path));
        }

        using var reader = new VideoFileReader(path);
        var count = 0;
        while (reader.ReadNext() is { } frame)
        {
            Assert.True(Math.Abs(frame.PresentationMs - written[count]) < 2, $"frame {count}: read {frame.PresentationMs:F1}, written {written[count]:F1}");
            count++;
        }

        Assert.Equal(written.Count, count);
    }

    /// <summary>
    /// The same written in real time with a sound track, as a recording is: still moments of 300 ms between bursts while the
    /// sound keeps coming. Writing as fast as possible did not show the lost time; a live recording did.
    /// </summary>
    [Fact]
    public void StillMomentsWrittenInRealTimeKeepTheirLength()
    {
        var path = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".mp4");
        var format = new AudioFormat(48_000, 2, 192_000);
        var written = new List<double>();
        var nv12 = new byte[Width * Height * 3 / 2];
        var pcm = new byte[480 * 4];
        var clock = System.Diagnostics.Stopwatch.StartNew();
        using (var writer = new VideoFileWriter(path, Width, Height, 60, 4_000_000, hevc: false, fragmented: true, format))
        {
            var audioMs = 0.0;
            var nextVideo = 0.0;
            var frames = 0;
            while (clock.Elapsed.TotalMilliseconds < 7000)
            {
                var now = clock.Elapsed.TotalMilliseconds;
                while (audioMs + 10 <= now)
                {
                    writer.WriteAudio(pcm, audioMs, 10);
                    audioMs += 10;
                }

                if (now >= nextVideo)
                {
                    Array.Fill(nv12, (byte)ExpectedLuma(frames), 0, Width * Height);
                    Array.Fill(nv12, (byte)128, Width * Height, Width * Height / 2);
                    writer.WriteFrame(nv12, now, 1000.0 / 60);
                    written.Add(now);
                    frames++;
                    // Bursts of about 0.7 s, then the screen stays still for 300 ms.
                    nextVideo = now + (frames % 40 == 0 ? 300 : 1000.0 / 60);
                }

                Thread.Sleep(1);
            }
        }

        using var reader = new VideoFileReader(path);
        var count = 0;
        var start = written[0];
        while (reader.ReadNext() is { } frame)
        {
            Assert.True(Math.Abs(frame.PresentationMs - (written[count] - start)) < 2, $"frame {count}: read {frame.PresentationMs:F1}, written {written[count] - start:F1}");
            count++;
        }

        Assert.Equal(written.Count, count);
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
