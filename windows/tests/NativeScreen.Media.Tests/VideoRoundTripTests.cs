using NativeScreen.Core;

namespace NativeScreen.Media.Tests;

/// <summary>Round trips generated clips through the real encoder and decoder on this machine.</summary>
public sealed class VideoRoundTripTests : IDisposable
{
    private const int Width = 640;
    private const int Height = 360;
    private const int Fps = 30;
    private readonly string directory = Directory.CreateTempSubdirectory("ns-media-").FullName;

    public void Dispose() => Directory.Delete(directory, recursive: true);

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void EncodedFramesDecodeInOrderWithTheirPixels(bool fragmented)
    {
        var path = WriteClip(fragmented, 60);
        using var reader = new VideoFileReader(path);
        Assert.Equal(Width, reader.Width);
        Assert.Equal(Height, reader.Height);

        var count = 0;
        var last = -1.0;
        while (reader.ReadNext() is { } frame)
        {
            Assert.True(frame.PresentationMs > last, $"pts {frame.PresentationMs} after {last}");
            Assert.True(
                Math.Abs(frame.PresentationMs - count * 1000.0 / Fps) <= 1,
                $"frame {count} at {frame.PresentationMs}, expected {count * 1000.0 / Fps}");
            last = frame.PresentationMs;
            // Luma ramps with the frame index, so a wrong order or a stuck frame shows up here.
            Assert.InRange(frame.Nv12[Width * 10 + 10], ExpectedLuma(count) - 12, ExpectedLuma(count) + 12);
            Assert.InRange(frame.Nv12[Width * Height + Width * 5 + 10], 128 - 12, 128 + 12);
            count++;
        }

        Assert.Equal(60, count);
        Assert.True(fragmented || Math.Abs(last - 59 * 1000.0 / Fps) <= 1, $"last frame at {last}");
    }

    [Fact]
    public void SeekLandsAtOrBeforeTheTarget()
    {
        var path = WriteClip(false, 120);
        using var reader = new VideoFileReader(path);
        reader.Seek(3000);
        var frame = reader.ReadNext();
        Assert.NotNull(frame);
        Assert.True(frame.PresentationMs <= 3000, $"landed at {frame.PresentationMs}");
    }

    [Fact]
    public void PlaybackSourceServesTheFrameAtTheClock()
    {
        var path = WriteClip(false, 120);
        using var source = new VideoPlaybackSource(path);
        Assert.True(WaitFor(() => source.FrameAt(2000) is { } frame && Math.Abs(frame.PresentationMs - 2000) <= 1000.0 / Fps + 1));
        var early = WaitFor(() => source.FrameAt(100) is { } frame && frame.PresentationMs <= 100.5);
        Assert.True(early, "seeking back did not reach the target");
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void SeekingKeepsTheShownFrameAndSettles(bool fragmented)
    {
        var path = WriteClip(fragmented, 240);
        using var source = new VideoPlaybackSource(path);
        var seeks = 0;
        source.FrameDecoded += () => Interlocked.Increment(ref seeks);
        Assert.True(WaitFor(() => source.FrameAt(0) is not null));

        // Like a pointer moving over the ruler: every request lands while the last seek is still running.
        for (var i = 0; i < 200; i++)
        {
            var target = i * 7919.0 % 7900;
            Assert.NotNull(source.FrameAt(target));
            Thread.Sleep(2);
        }

        // Between frames, as a time on a 30 fps clip almost always is. The frame just before it must be the answer.
        const double between = 4010;
        Assert.True(WaitFor(() => source.FrameAt(between) is { } frame && Math.Abs(frame.PresentationMs - 4000) <= 1000.0 / Fps));
        Thread.Sleep(100);
        var settled = Volatile.Read(ref seeks);
        for (var i = 0; i < 50; i++)
        {
            var frame = source.FrameAt(between);
            Assert.NotNull(frame);
            Assert.True(frame.PresentationMs <= between + 0.5, $"showed {frame.PresentationMs}");
            Thread.Sleep(5);
        }

        Assert.Equal(settled, Volatile.Read(ref seeks));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void PlayingFromASeekDoesNotChaseTheClock(bool fragmented)
    {
        var path = WriteClip(fragmented, 240);
        using var source = new VideoPlaybackSource(path);
        Assert.True(WaitFor(() => source.FrameAt(3000) is { } frame && frame.PresentationMs >= 2900));
        var clock = System.Diagnostics.Stopwatch.StartNew();
        var newest = 0.0;
        while (clock.ElapsedMilliseconds < 2000)
        {
            var time = 3000 + clock.ElapsedMilliseconds;
            var frame = source.FrameAt(time);
            Assert.NotNull(frame);
            newest = frame.PresentationMs;
            Thread.Sleep(8);
        }

        Assert.True(newest >= 4800, $"clock at 5000, newest frame {newest}");
    }

    [Fact]
    public void AppAudioTrackIsContinuousEvenWithNothingToCapture()
    {
        // Only output-side capture of this test's own silent process, or none on Windows without process loopback.
        var written = 0.0;
        var last = 0.0;
        var contiguous = true;
        var origin = System.Diagnostics.Stopwatch.GetTimestamp() * 1000.0 / System.Diagnostics.Stopwatch.Frequency;
        var track = new AppAudioTrackRecorder([Environment.ProcessId], (_, length, at, duration) =>
        {
            contiguous &= Math.Abs(at - last) < 0.01;
            Assert.Equal(duration * 192, length, 1);
            last = at + duration;
            written += duration;
        }, host => host - origin);
        Thread.Sleep(500);
        track.Stop(1000);
        track.Dispose();
        Assert.True(contiguous);
        Assert.Equal(1000, written, 1);
    }

    [Fact]
    public void AudioAppsAreListedWithoutThisProcess()
    {
        var apps = AudioApps.List();
        Assert.DoesNotContain(apps, app => app.Id == System.Diagnostics.Process.GetCurrentProcess().ProcessName);
        Assert.Contains(Environment.ProcessId, AudioApps.RootProcessIds([System.Diagnostics.Process.GetCurrentProcess().ProcessName]));
    }

    [Fact]
    public void CancelRemovesThePartialFile()
    {
        var path = Path.Combine(directory, "cancel.mp4");
        var writer = new VideoFileWriter(path, Width, Height, Fps, 2_000_000, false, false);
        writer.WriteFrame(Frame(0), 0, 1000.0 / Fps);
        writer.Cancel();
        Assert.False(File.Exists(path));
    }

    private static bool WaitFor(Func<bool> condition)
    {
        for (var i = 0; i < 400; i++)
        {
            if (condition())
            {
                return true;
            }

            Thread.Sleep(10);
        }

        return false;
    }

    private string WriteClip(bool fragmented, int frames)
    {
        var path = Path.Combine(directory, $"clip-{fragmented}-{frames}.mp4");
        using var writer = new VideoFileWriter(path, Width, Height, Fps, 4_000_000, false, fragmented);
        for (var i = 0; i < frames; i++)
        {
            writer.WriteFrame(Frame(i), i * 1000.0 / Fps, 1000.0 / Fps);
        }

        writer.Finish();
        return path;
    }

    private static int ExpectedLuma(int index) => 40 + index % 60 * 3;

    private static byte[] Frame(int index)
    {
        var data = new byte[Width * Height * 3 / 2];
        Array.Fill(data, (byte)ExpectedLuma(index), 0, Width * Height);
        Array.Fill(data, (byte)128, Width * Height, Width * Height / 2);
        return data;
    }
}
