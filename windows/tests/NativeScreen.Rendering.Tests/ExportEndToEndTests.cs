using NativeScreen.Core;
using NativeScreen.Export;
using NativeScreen.Media;

namespace NativeScreen.Rendering.Tests;

/// <summary>Builds a package with real media, exports it, and checks the file that comes out.</summary>
public sealed class ExportEndToEndTests : IDisposable
{
    private const int ClipFps = 30;
    private readonly string directory = Directory.CreateTempSubdirectory("ns-export-").FullName;

    public void Dispose() => Directory.Delete(directory, recursive: true);

    [Fact]
    public async Task Mp4HasEveryFrameTheComposedPixelsAndAudio()
    {
        var (source, input) = BuildPackage(withAudio: true);
        var output = Path.Combine(directory, "out.mp4");
        var settings = new ExportSettings { Fps = 30, ResolutionHeight = 720, Compression = ExportCompression.Studio };
        var reports = 0;
        await new ProjectExporter(source).RunAsync(output, settings, new InlineProgress(() => reports++), CancellationToken.None);
        Assert.Equal(90, reports);

        using var reader = new VideoFileReader(output);
        Assert.Equal(1280, reader.Width);
        Assert.Equal(720, reader.Height);
        var frames = new List<VideoFrame>();
        while (reader.ReadNext() is { } frame)
        {
            frames.Add(frame);
        }

        Assert.Equal(90, frames.Count);
        Assert.InRange(frames[^1].PresentationMs, 89 * 1000.0 / 30 - 1, 89 * 1000.0 / 30 + 1);

        // The decoded file must look like the frame the compositor drew.
        using var compositor = new FrameCompositor();
        using var screen = new SequentialVideoSource(Path.Combine(source.PackageDirectory!, "recording", "display.mp4"));
        var layer = compositor.Compose(
            new ComposeRequest
            {
                Document = source.Document,
                Trajectory = new PlaybackTrajectorySolver(source.SourceDurationMs, source.CursorEvents, source.ClickEvents, source.Document),
                SourceMs = 2000,
                ScreenSource = screen,
                ExportQuality = true,
                PackageDirectory = source.PackageDirectory,
                Shortcuts = source.Shortcuts
            },
            1280,
            720);
        var expected = ImageTexture.ReadBack(compositor.Device, compositor.Context, layer.Texture, 1280, 720);
        var decoded = frames[60];
        var nv12 = new byte[1280 * 720 * 3 / 2];
        Nv12Converter.FromBgra(expected, nv12, 1280, 720);
        Assert.True(LumaSsim(nv12, decoded.Nv12, 1280, 720) > 0.95, "exported frame does not match the composed frame");
        Assert.True(input.Width > 0);

        using var audio = new AudioFileReader(output);
        Assert.Equal(48000, audio.SampleRate);
        var peak = 0;
        var samples = 0L;
        while (audio.ReadBlock() is { } block)
        {
            samples += block.Samples.Length / audio.Channels;
            peak = Math.Max(peak, block.Samples.Max(value => Math.Abs((int)value)));
        }

        Assert.True(peak > 2000, $"audio is silent, peak {peak}");
        Assert.InRange(samples / 48000.0, 2.8, 3.2);
    }

    [Fact]
    public async Task GifIsWrittenAndHasAnimationFrames()
    {
        var (source, _) = BuildPackage(withAudio: false);
        var output = Path.Combine(directory, "out.gif");
        var settings = new ExportSettings { Format = ExportFormat.Gif, Fps = 10, ResolutionHeight = 360 };
        settings.Normalize();
        await new ProjectExporter(source).RunAsync(output, settings, null, CancellationToken.None);
        using var factory = new Vortice.WIC.IWICImagingFactory();
        using var decoder = factory.CreateDecoderFromFileName(output);
        Assert.Equal(settings.Fps * 3, (int)decoder.FrameCount);
    }

    [Fact]
    public async Task CancelLeavesNoPartialFile()
    {
        var (source, _) = BuildPackage(withAudio: false);
        var output = Path.Combine(directory, "cancelled.mp4");
        using var cancel = new CancellationTokenSource();
        var settings = new ExportSettings { Fps = 30, ResolutionHeight = 720 };
        var run = new ProjectExporter(source).RunAsync(output, settings, new InlineProgress(cancel.Cancel), cancel.Token);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => run);
        Assert.False(File.Exists(output));
    }

    private (ExportSource Source, ImageTexture Input) BuildPackage(bool withAudio)
    {
        var fixture = Path.Combine(CasesRoot(), "basic");
        var package = Path.Combine(directory, $"Clip{Guid.NewGuid():N}.nativescreen");
        CopyDirectory(Path.Combine(fixture, "project.nativescreen"), package);
        var input = ImageTexture.Load(Path.Combine(fixture, "inputs", "screen.png"));
        var width = input.Width & ~1;
        var height = input.Height & ~1;
        var format = withAudio ? new AudioFormat(48000, 2, 192_000) : (AudioFormat?)null;
        using (var writer = new VideoFileWriter(Path.Combine(package, "recording", "display.mp4"), width, height, ClipFps, 8_000_000, false, true, format))
        {
            var nv12 = new byte[width * height * 3 / 2];
            Nv12Converter.FromBgra(input.Pixels, nv12, width, height);
            for (var i = 0; i < ClipFps * 6; i++)
            {
                writer.WriteFrame(nv12, i * 1000.0 / ClipFps, 1000.0 / ClipFps);
                if (withAudio)
                {
                    writer.WriteAudio(Tone(i), i * 1000.0 / ClipFps, 1000.0 / ClipFps);
                }
            }

            writer.Finish();
        }

        var project = new LoadedProject(package);
        project.Document.Timeline.Slices = [new ClipSlice { Id = "a", SourceStartMs = 0, SourceEndMs = 3000 }];
        var tracks = new RecordingTracksMetadata { DisplayVideo = "display.mp4", SystemAudio = withAudio ? "display.mp4" : null };
        return (new ExportSource(
            project.Document,
            package,
            tracks,
            project.Metadata.DurationMs,
            width,
            height,
            false,
            project.CursorEvents,
            project.ClickEvents,
            ShortcutEngine.Detect(project.Document, project.KeyEvents)), input);
    }

    private static byte[] Tone(int frameIndex)
    {
        const int perFrame = 48000 / ClipFps;
        var bytes = new byte[perFrame * 4];
        for (var i = 0; i < perFrame; i++)
        {
            var t = (frameIndex * perFrame + i) / 48000.0;
            var value = (short)(Math.Sin(t * 2 * Math.PI * 440) * 12000);
            bytes[i * 4] = bytes[i * 4 + 2] = (byte)value;
            bytes[i * 4 + 1] = bytes[i * 4 + 3] = (byte)(value >> 8);
        }

        return bytes;
    }

    private static double LumaSsim(byte[] a, byte[] b, int width, int height)
    {
        double sumA = 0, sumB = 0, sumAA = 0, sumBB = 0, sumAB = 0;
        var n = width * height;
        for (var i = 0; i < n; i++)
        {
            sumA += a[i];
            sumB += b[i];
            sumAA += a[i] * a[i];
            sumBB += b[i] * b[i];
            sumAB += a[i] * b[i];
        }

        var meanA = sumA / n;
        var meanB = sumB / n;
        var varA = sumAA / n - meanA * meanA;
        var varB = sumBB / n - meanB * meanB;
        var cov = sumAB / n - meanA * meanB;
        return (2 * meanA * meanB + 6.5025) * (2 * cov + 58.5225) / ((meanA * meanA + meanB * meanB + 6.5025) * (varA + varB + 58.5225));
    }

    private static void CopyDirectory(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var file in Directory.GetFiles(from))
        {
            File.Copy(file, Path.Combine(to, Path.GetFileName(file)));
        }

        foreach (var child in Directory.GetDirectories(from))
        {
            CopyDirectory(child, Path.Combine(to, Path.GetFileName(child)));
        }
    }

    private static string CasesRoot([System.Runtime.CompilerServices.CallerFilePath] string file = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(file)!, "..", "..", "..", "conformance", "cases"));

    private sealed class InlineProgress(Action report) : IProgress<ExportProgress>
    {
        public void Report(ExportProgress value) => report();
    }
}
