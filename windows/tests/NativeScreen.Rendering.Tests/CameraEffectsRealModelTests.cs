using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using NativeScreen.Core;
using NativeScreen.Intelligence;
using NativeScreen.Media;

namespace NativeScreen.Rendering.Tests;

/// <summary>NS_TEST_CAMERA=&lt;folder&gt; runs the real models on the website's camera clip and writes frames and timings there. It reads a file; no camera is opened.</summary>
public sealed class CameraEffectsRealModelTests
{
    private const int Width = 1280;
    private const int Height = 720;

    private static string Clip()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            var candidate = Path.Combine(directory.FullName, "site", "assets", "demos", "camera-original.mp4");
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        throw new FileNotFoundException("camera-original.mp4");
    }

    [Fact]
    public async Task ScansStickersBackgroundsAndCutout()
    {
        if (Environment.GetEnvironmentVariable("NS_TEST_CAMERA") is not { Length: > 0 } output)
        {
            return;
        }

        Directory.CreateDirectory(output);
        var log = new StringBuilder();
        if (!PersonSegmentationModel.IsInstalled)
        {
            var download = Stopwatch.StartNew();
            await PersonSegmentationModel.DownloadAsync(null, CancellationToken.None);
            log.AppendLine(CultureInfo.InvariantCulture, $"download {download.Elapsed.TotalSeconds:F1} s");
        }

        var clip = Clip();
        using (var probe = new VideoFileReader(clip))
        {
            log.AppendLine(CultureInfo.InvariantCulture, $"clip {probe.Width}x{probe.Height}, {probe.DurationMs:F0} ms");
        }

        var scan = Stopwatch.StartNew();
        var stored = FaceTrackScanner.Scan(clip, null, CancellationToken.None)!;
        log.AppendLine(CultureInfo.InvariantCulture, $"scan {scan.Elapsed.TotalSeconds:F2} s, {stored.Samples.Count} samples");
        File.WriteAllText(Path.Combine(output, "face-track.json"), JsonSerializer.Serialize(stored));
        Assert.True(stored.Samples.Count > 10);
        var track = new FaceTrack(stored);

        var masks = ExportPersonMasks.TryCreate();
        Assert.NotNull(masks);
        using (masks)
        {
            void Render(string name, double ms, Action<CameraConfig> style)
            {
                var document = new ProjectDocument();
                document.Timeline.Slices = [new ClipSlice { Id = "s", SourceStartMs = 0, SourceEndMs = stored.WebcamDurationMs }];
                document.Camera.LayoutMode = CameraLayoutMode.SplitScreen;
                style(document.Camera);
                using var compositor = new FrameCompositor();
                using var webcam = new SequentialVideoSource(clip);
                var layer = compositor.Compose(
                    new ComposeRequest
                    {
                        Document = document,
                        Trajectory = new PlaybackTrajectorySolver(stored.WebcamDurationMs, [], [], document),
                        SourceMs = ms,
                        WebcamSource = webcam,
                        ScreenWidth = 1920,
                        ScreenHeight = 1080,
                        HasCamera = true,
                        ExportQuality = true,
                        PackageDirectory = output,
                        FaceTrack = track,
                        PersonMasks = masks
                    },
                    Width,
                    Height);
                ImageTexture.Save(ImageTexture.ReadBack(compositor.Device, compositor.Context, layer.Texture, Width, Height), Width, Height, Path.Combine(output, name + ".jpg"), jpeg: true);
            }

            var assets = Path.Combine(output, "assets");
            Directory.CreateDirectory(assets);
            File.Copy(CameraBackgroundCatalog.Items[0].FullImagePath, Path.Combine(assets, "bg.jpg"), overwrite: true);
            Render("original", 4000, _ => { });
            Render("crown", 4000, c => c.StickerId = "crown");
            Render("sunglasses", 4000, c => c.StickerId = "sunglasses");
            Render("cat-mirror", 4000, c => { c.StickerId = "cat"; c.Mirror = true; });
            Render("lips", 4000, c => c.StickerId = "lips");
            Render("blur", 4000, c => { c.BackgroundMode = CameraBackgroundMode.Blur; c.BackgroundBlur = 0.5; });
            Render("image", 4000, c => { c.BackgroundMode = CameraBackgroundMode.Image; c.BackgroundImagePath = "assets/bg.jpg"; });
            Render("cutout", 4000, c => { c.LayoutMode = CameraLayoutMode.Cutout; c.StickerId = "top-hat"; });
            Render("tracking", 4000, c => { c.EnableFaceTracking = true; c.FaceTrackingZoom = 1.7; });
            foreach (var sticker in CameraStickerCatalog.All)
            {
                Render("s-" + sticker.Id, 4000, c => c.StickerId = sticker.Id);
            }
        }

        foreach (var cpu in new[] { false, true })
        {
            Environment.SetEnvironmentVariable("NS_MODEL_CPU", cpu ? "1" : null);
            using var segmenter = new PersonSegmenter();
            using var reader = new VideoFileReader(clip);
            var frame = reader.ReadNext()!;
            foreach (var side in new[] { 320, 672 })
            {
                var input = PersonSegmenter.Prepare(frame, Rect01.Full, false, side);
                segmenter.Run(input);
                var clock = Stopwatch.StartNew();
                const int runs = 20;
                for (var run = 0; run < runs; run++)
                {
                    segmenter.Run(input);
                }

                log.AppendLine(CultureInfo.InvariantCulture, $"{(segmenter.OnGpu ? "gpu" : "cpu")} long side {side}: {clock.Elapsed.TotalMilliseconds / runs:F1} ms");
            }
        }

        Environment.SetEnvironmentVariable("NS_MODEL_CPU", null);
        File.WriteAllText(Path.Combine(output, "timings.txt"), log.ToString());
    }
}
