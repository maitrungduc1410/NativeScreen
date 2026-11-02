using NativeScreen.Core;
using NativeScreen.Export;
using NativeScreen.Intelligence;
using NativeScreen.Media;

namespace NativeScreen.Rendering.Tests;

/// <summary>Real OS engines on generated clips: text comes from the caption renderer, so the test knows where it is.</summary>
public sealed class IntelligenceAndAssetsTests : IDisposable
{
    private const int Width = 1280;
    private const int Height = 720;
    private readonly string directory = Directory.CreateTempSubdirectory("ns-assets-").FullName;

    public void Dispose() => Directory.Delete(directory, recursive: true);

    private string ClipWithCaption(string text, bool audio = false)
    {
        var document = new ProjectDocument();
        document.Background.Type = BackgroundType.Solid;
        document.Background.SolidColor = "#000000";
        document.Canvas.PaddingRatio = 0;
        document.Captions.Enabled = true;
        document.Captions.FontSizeRatio = 0.06;
        document.Captions.WordsReveal = CaptionWordsReveal.LineByLine;
        document.Captions.Segments = [new CaptionSegment { Id = "a", SourceStartMs = 0, SourceEndMs = 60000, Text = text }];
        document.Timeline.Slices = [new ClipSlice { Id = "s", SourceStartMs = 0, SourceEndMs = 60000 }];
        using var compositor = new FrameCompositor();
        var layer = compositor.Compose(
            new ComposeRequest
            {
                Document = document,
                Trajectory = new SpringTrajectorySolver(60000, [], [], document),
                SourceMs = 500,
                ScreenWidth = Width,
                ScreenHeight = Height,
                ExportQuality = true,
                Shortcuts = []
            },
            Width,
            Height);
        var pixels = ImageTexture.ReadBack(compositor.Device, compositor.Context, layer.Texture, Width, Height);
        var nv12 = new byte[Width * Height * 3 / 2];
        Nv12Converter.FromBgra(pixels, nv12, Width, Height);
        var path = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".mp4");
        using var writer = new VideoFileWriter(path, Width, Height, 30, 6_000_000, false, false, audio ? new AudioFormat(48000, 2, 192_000) : null);
        var silence = new byte[1600 * 4];
        for (var index = 0; index < 90; index++)
        {
            writer.WriteFrame(nv12, index * 1000.0 / 30, 1000.0 / 30);
            if (audio)
            {
                writer.WriteAudio(silence, index * 1000.0 / 30, 1000.0 / 30);
            }
        }

        writer.Finish();
        return path;
    }

    [Fact]
    public async Task OcrFindsAnEmailWhereItIsDrawn()
    {
        var path = ClipWithCaption("write to someone@example.com today");
        var masks = await OnDeviceMaskScanner.DetectSensitiveAsync(path, 3000, [], null, CancellationToken.None);
        if (masks is null)
        {
            return; // This Windows has no OCR language.
        }

        var mask = Assert.Single(masks);
        var rect = mask.Keyframes[0].Rect01;
        Assert.True(mask.IsAutoSensitiveMask);
        Assert.InRange(rect.Center.Y, 0.7, 0.98);
        Assert.InRange(rect.Width, 0.1, 0.6);
    }

    [Fact]
    public async Task CustomPhrasesAreFoundAndCleanTextIsNot()
    {
        var path = ClipWithCaption("project falcon launch");
        var phrase = await OnDeviceMaskScanner.DetectSensitiveAsync(path, 3000, ["falcon"], null, CancellationToken.None);
        if (phrase is null)
        {
            return;
        }

        Assert.NotEmpty(phrase);
        Assert.Empty((await OnDeviceMaskScanner.DetectSensitiveAsync(path, 3000, [], null, CancellationToken.None))!);
    }

    [Fact]
    public async Task FaceDetectorRunsAndFindsNothingInText()
    {
        var path = ClipWithCaption("no faces in here");
        Assert.Empty(await OnDeviceMaskScanner.DetectFacesAsync(path, 3000, null, CancellationToken.None));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task StillFramesAreWrittenAtTheAskedSize(bool jpeg)
    {
        var document = new ProjectDocument();
        document.Timeline.Slices = [new ClipSlice { Id = "s", SourceStartMs = 0, SourceEndMs = 3000 }];
        document.Canvas.AspectRatioMode = AspectRatioMode.Preset;
        document.Canvas.AspectRatioPreset = AspectRatioPreset.Widescreen16x9;
        var source = new ExportSource(document, null, new RecordingTracksMetadata(), 3000, 1920, 1080, false, [], [], []);
        var path = Path.Combine(directory, jpeg ? "frame.jpg" : "frame.png");
        await new ProjectExporter(source).ExportStillAsync(path, 1000, 720, jpeg);
        var image = ImageTexture.Load(path);
        Assert.Equal(1280, image.Width);
        Assert.Equal(720, image.Height);
    }

    [Fact]
    public void ImportedVideoBecomesAProjectThatLoads()
    {
        var clip = ClipWithCaption("hello", audio: true);
        var package = VideoProjectImporter.BuildPackage(clip, directory, DateTimeOffset.UtcNow);
        var project = new LoadedProject(package);
        Assert.Equal(Width, project.Metadata.CaptureTarget.PixelSize.Width);
        Assert.Equal("display.mp4", project.Metadata.Tracks.DisplayVideo);
        Assert.Equal("display.mp4", project.Metadata.Tracks.SystemAudio);
        Assert.InRange(project.Metadata.DurationMs, 2900, 3100);
        Assert.True(File.Exists(Path.Combine(package, "recording", "display.mp4")));
    }

    [Fact]
    public void WaveformReflectsWhereTheSoundIs()
    {
        var path = Path.Combine(directory, "tone.mp4");
        using (var writer = new VideoFileWriter(path, 320, 180, 30, 1_000_000, false, false, new AudioFormat(48000, 2, 192_000)))
        {
            var nv12 = new byte[320 * 180 * 3 / 2];
            for (var index = 0; index < 120; index++)
            {
                var pcm = new byte[1600 * 4];
                if (index >= 60)
                {
                    for (var i = 0; i < 1600; i++)
                    {
                        var value = (short)(Math.Sin((index * 1600 + i) * 2 * Math.PI * 440 / 48000) * 16000);
                        BitConverter.TryWriteBytes(pcm.AsSpan(i * 4), value);
                        BitConverter.TryWriteBytes(pcm.AsSpan(i * 4 + 2), value);
                    }
                }

                writer.WriteFrame(nv12, index * 1000.0 / 30, 1000.0 / 30);
                writer.WriteAudio(pcm, index * 1000.0 / 30, 1000.0 / 30);
            }

            writer.Finish();
        }

        var peaks = MediaAssets.ReadWaveform(path, 4000, CancellationToken.None);
        Assert.NotNull(peaks);
        var quarter = peaks.Length / 4;
        Assert.True(peaks.Take(quarter).Max() < 0.2f, "the silent half has sound");
        Assert.True(peaks.Skip(3 * quarter).Max() > 0.8f, "the loud half is silent");
    }

    [Fact]
    public void PreviewAudioIsAMasterClockWithoutDrift()
    {
        var path = Path.Combine(directory, "quiet.mp4");
        using (var writer = new VideoFileWriter(path, 320, 180, 30, 1_000_000, false, false, new AudioFormat(48000, 2, 192_000)))
        {
            var nv12 = new byte[320 * 180 * 3 / 2];
            var pcm = new byte[1600 * 4];
            for (var i = 0; i < 1600; i++)
            {
                // Quiet on purpose: this test plays through the machine's speakers.
                BitConverter.TryWriteBytes(pcm.AsSpan(i * 4), (short)(i % 2 == 0 ? 1 : -1));
                BitConverter.TryWriteBytes(pcm.AsSpan(i * 4 + 2), (short)(i % 2 == 0 ? 1 : -1));
            }

            for (var index = 0; index < 150; index++)
            {
                writer.WriteFrame(nv12, index * 1000.0 / 30, 1000.0 / 30);
                writer.WriteAudio(pcm, index * 1000.0 / 30, 1000.0 / 30);
            }

            writer.Finish();
        }

        var package = Path.Combine(directory, "audio.nativescreen");
        Directory.CreateDirectory(Path.Combine(package, "recording"));
        File.Copy(path, Path.Combine(package, "recording", "display.mp4"));
        var document = new ProjectDocument();
        document.Timeline.Slices = [new ClipSlice { Id = "s", SourceStartMs = 0, SourceEndMs = 5000 }];
        document.Audio.MasterVolume = 0.02;
        using var player = PreviewAudioPlayer.TryCreate(document, package, new RecordingTracksMetadata { SystemAudio = "display.mp4" });
        if (player is null)
        {
            return; // No output device.
        }

        player.Prime(1000);
        var clock = System.Diagnostics.Stopwatch.StartNew();
        player.Start();
        Thread.Sleep(2000);
        var heard = player.HeardTimelineMs;
        var elapsed = clock.Elapsed.TotalMilliseconds;
        player.Pause();
        Assert.NotNull(heard);
        File.WriteAllText(Path.Combine(Path.GetTempPath(), "ns-audio-clock.txt"), $"after {elapsed:F0} ms heard {heard - 1000:F0} ms");
        Assert.InRange(heard!.Value - 1000, elapsed - 150, elapsed + 30);
    }
}
