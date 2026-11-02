using System.Diagnostics;
using NativeScreen.Core;
using NativeScreen.Export;
using NativeScreen.Media;

namespace NativeScreen.Rendering.Tests;

/// <summary>Spec/08 numbers, written to %TEMP%\ns-perf-report.txt. Only with NS_TEST_PERF=1: it loads the machine for a while.</summary>
public sealed class PerformanceMeasurements : IDisposable
{
    private readonly string directory = Directory.CreateTempSubdirectory("ns-perf-").FullName;

    public void Dispose() => Directory.Delete(directory, recursive: true);

    private static bool Enabled => Environment.GetEnvironmentVariable("NS_TEST_PERF") == "1";

    private static void Report(string line) => File.AppendAllText(Path.Combine(Path.GetTempPath(), "ns-perf-report.txt"), line + "\n");

    private string Clip(int width, int height, int seconds)
    {
        var path = Path.Combine(directory, $"clip{width}.mp4");
        var nv12 = new byte[width * height * 3 / 2];
        var random = new Random(3);
        random.NextBytes(nv12);
        Array.Fill(nv12, (byte)128, width * height, width * height / 2);
        using var writer = new VideoFileWriter(path, width, height, 30, 12_000_000, false, false, new AudioFormat(48000, 2, 192_000));
        var silence = new byte[1600 * 4];
        for (var index = 0; index < seconds * 30; index++)
        {
            // A moving band, so the decoder has real work on each frame.
            nv12.AsSpan(index % height * width, width).Fill((byte)(index % 200 + 30));
            writer.WriteFrame(nv12, index * 1000.0 / 30, 1000.0 / 30);
            writer.WriteAudio(silence, index * 1000.0 / 30, 1000.0 / 30);
        }

        writer.Finish();
        return path;
    }

    private static ProjectDocument Styled(double durationMs)
    {
        var document = new ProjectDocument();
        document.Timeline.Slices = [new ClipSlice { Id = "s", SourceStartMs = 0, SourceEndMs = durationMs }];
        document.Timeline.Zooms = [new ZoomBlock { Id = "z", SourceStartMs = 500, SourceEndMs = durationMs - 500, Scale = 1.8 }];
        document.Timeline.MaskTracks = [new MaskTrack { Id = "m", Items = [new MaskItem { Id = "i", SourceStartMs = 0, SourceEndMs = durationMs, Keyframes = [new MaskKeyframe { SourceMs = 0 }] }] }];
        return document;
    }

    [Theory]
    [InlineData(1920, 1080)]
    [InlineData(3840, 2160)]
    public void ComposeTime(int width, int height)
    {
        if (!Enabled)
        {
            return;
        }

        var document = Styled(5000);
        using var compositor = new FrameCompositor();
        var trajectory = new SpringTrajectorySolver(5000, [], [], document);
        var times = new List<double>();
        for (var index = 0; index < 120; index++)
        {
            var started = Stopwatch.GetTimestamp();
            var layer = compositor.Compose(
                new ComposeRequest { Document = document, Trajectory = trajectory, SourceMs = index * 40.0, ScreenWidth = 1920, ScreenHeight = 1080, Shortcuts = [] },
                width,
                height);
            // Reading one texel waits for the GPU, so this is the whole frame and not just its submission.
            compositor.WaitForGpu(layer);
            times.Add(Stopwatch.GetElapsedTime(started).TotalMilliseconds);
        }

        times.Sort();
        Report($"compose {width}x{height}: median {times[times.Count / 2]:F1} ms, p95 {times[times.Count * 95 / 100]:F1} ms");
    }

    [Fact]
    public void PlaybackLateFramesAndFirstFrame()
    {
        if (!Enabled)
        {
            return;
        }

        var path = Clip(1920, 1080, 12);
        var document = Styled(12000);
        using var compositor = new FrameCompositor();
        var trajectory = new SpringTrajectorySolver(12000, [], [], document);
        using var source = new VideoPlaybackSource(path);
        var open = Stopwatch.StartNew();
        while (source.FrameAt(0) is null && open.ElapsedMilliseconds < 3000)
        {
            Thread.Sleep(1);
        }

        var firstFrameMs = open.Elapsed.TotalMilliseconds;
        var counter = new LateFrameCounter();
        var clock = Stopwatch.StartNew();
        var allocated = GC.GetAllocatedBytesForCurrentThread();
        var next = 0.0;
        while (clock.Elapsed.TotalMilliseconds < 10000)
        {
            var now = clock.Elapsed.TotalMilliseconds;
            var layer = compositor.Compose(
                new ComposeRequest { Document = document, Trajectory = trajectory, SourceMs = now, ScreenSource = source, ScreenWidth = 1920, ScreenHeight = 1080, Shortcuts = [] },
                1920,
                1080);
            compositor.WaitForGpu(layer);
            if (source.FrameAt(now) is { } frame)
            {
                counter.Present(frame.PresentationMs, now, 1000.0 / 30);
            }

            next += 1000.0 / 60;
            var wait = next - clock.Elapsed.TotalMilliseconds;
            if (wait > 1)
            {
                Thread.Sleep((int)wait);
            }
        }

        Report($"playback 1080p30 at 60 Hz: {counter.Presented} draws, late {counter.LateRatio:P2}, first frame {firstFrameMs:F0} ms, allocated {(GC.GetAllocatedBytesForCurrentThread() - allocated) / 1024 / 1024} MB on the render thread");
    }

    [Theory]
    [InlineData(1080)]
    [InlineData(2160)]
    public async Task ExportSpeed(int outputHeight)
    {
        if (!Enabled)
        {
            return;
        }

        var package = Path.Combine(directory, $"export{outputHeight}.nativescreen");
        Directory.CreateDirectory(Path.Combine(package, "recording"));
        File.Copy(Clip(1920, 1080, 6), Path.Combine(package, "recording", "display.mp4"), overwrite: true);
        var document = Styled(6000);
        var source = new ExportSource(document, package, new RecordingTracksMetadata { SystemAudio = "display.mp4" }, 6000, 1920, 1080, false, [], [], []);
        var settings = new ExportSettings { Fps = 30, ResolutionHeight = outputHeight };
        var process = Process.GetCurrentProcess();
        var memoryBefore = process.WorkingSet64;
        var clock = Stopwatch.StartNew();
        await new ProjectExporter(source).RunAsync(Path.Combine(directory, $"out{outputHeight}.mp4"), settings, null, CancellationToken.None);
        process.Refresh();
        Report($"export {outputHeight}p30: 6 s of video in {clock.Elapsed.TotalSeconds:F1} s = {6 / clock.Elapsed.TotalSeconds:F2}x, working set {memoryBefore / 1024 / 1024} to {process.WorkingSet64 / 1024 / 1024} MB, peak {process.PeakWorkingSet64 / 1024 / 1024} MB");
    }
}
