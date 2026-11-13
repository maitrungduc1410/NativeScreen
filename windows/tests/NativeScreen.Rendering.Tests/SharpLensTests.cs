using NativeScreen.Core;

namespace NativeScreen.Rendering.Tests;

/// <summary>
/// The GPU part of the macOS `MotionRegressionChecks` (spec/06 ADR-86): the lens draws source pixels at lens scale, masks still
/// apply inside it, and a reused source range draws its own cursor. `NS_DUMP_FRAMES` writes the frames to look at.
/// </summary>
public sealed class SharpLensTests
{
    private sealed class OneFrame(VideoFrame frame) : IVideoFrameSource
    {
        public VideoFrame? FrameAt(double sourceMs) => frame;
    }

    private const int Width = 1280;
    private const int Height = 720;

    // One-pixel black and white columns at 3840 x 2160: only a lens that samples the source keeps them apart.
    private static VideoFrame Stripes()
    {
        const int width = 3840;
        const int height = 2160;
        var pixels = new byte[width * height * 3 / 2];
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                pixels[y * width + x] = (byte)(x % 2 == 0 ? 16 : 235);
            }
        }

        pixels.AsSpan(width * height).Fill(128);
        return new VideoFrame(pixels, width, height, 0);
    }

    private static VideoFrame White()
    {
        var pixels = new byte[1920 * 1080 * 3 / 2];
        pixels.AsSpan(0, 1920 * 1080).Fill(235);
        pixels.AsSpan(1920 * 1080).Fill(128);
        return new VideoFrame(pixels, 1920, 1080, 0);
    }

    private static ProjectDocument Plain()
    {
        var document = new ProjectDocument();
        document.Timeline.Slices = [new ClipSlice { Id = "s", SourceStartMs = 0, SourceEndMs = 4000 }];
        document.Camera.Enabled = false;
        document.Canvas.PaddingRatio = 0;
        document.FrameStyle.BorderRadius = 0;
        document.FrameStyle.Inset.Enabled = false;
        document.FrameStyle.Shadow.Enabled = false;
        document.Background.Type = BackgroundType.Solid;
        document.Background.SolidColor = "#000000";
        document.Motion.MotionBlurIntensity = 0;
        return document;
    }

    private static byte[] Compose(FrameCompositor compositor, ProjectDocument document, VideoFrame frame, IReadOnlyList<CursorSampleEvent> cursor, double timelineMs, string dump)
    {
        var trajectory = new PlaybackTrajectorySolver(4000, cursor, [], document);
        var layer = compositor.Compose(
            new ComposeRequest
            {
                Document = document,
                Trajectory = trajectory,
                SourceMs = trajectory.Mapper.SourceTime(timelineMs).SourceMs,
                TimelineMs = timelineMs,
                ScreenSource = new OneFrame(frame),
                ScreenWidth = frame.Width,
                ScreenHeight = frame.Height,
                ExportQuality = true
            },
            Width,
            Height);
        var pixels = ImageTexture.ReadBack(compositor.Device, compositor.Context, layer.Texture, Width, Height);
        if (Environment.GetEnvironmentVariable("NS_DUMP_FRAMES") is { Length: > 0 } folder)
        {
            Directory.CreateDirectory(folder);
            ImageTexture.Save(pixels, Width, Height, Path.Combine(folder, dump + ".png"), false);
        }

        return pixels;
    }

    private static int Red(byte[] pixels, int x, int y) => pixels[(y * Width + x) * 4 + 2];

    [Fact]
    public void TheLensDrawsSourcePixelsAndKeepsMasks()
    {
        using var compositor = new FrameCompositor();
        var document = Plain();
        document.Cursor.Hidden = true;
        document.Timeline.Zooms = [new ZoomBlock { Id = "l", SourceStartMs = 0, SourceEndMs = 4000, Scale = 3, Mode = ZoomMode.Manual, Presentation = ZoomPresentation.Loupe, InstantAnimation = true }];
        List<CursorSampleEvent> still = [new() { T = 0, X = 0.7, Y = 0.4 }, new() { T = 4000, X = 0.7, Y = 0.4 }];
        var pixels = Compose(compositor, document, Stripes(), still, 1000, "lens-stripes");
        var row = Enumerable.Range(610, 60).Select(x => Red(pixels, x, 360)).ToList();
        // A lens over the canvas would see the columns already averaged to grey (about 25/255 apart).
        Assert.True(row.Max() - row.Min() > 180, $"loupe retains source-pixel stripe contrast ({row.Max() - row.Min()}/255)");

        document.Timeline.MaskTracks = [new MaskTrack { Id = "m", Name = "Privacy", Items = [new MaskItem { Id = "mask", SourceStartMs = 0, SourceEndMs = 4000, Type = MaskType.Blur, Style = MaskStyle.Solid, Intensity = 1, Keyframes = [new MaskKeyframe { SourceMs = 0, Rect01 = new Rect01(0, 0, 1, 1) }] }] }];
        var masked = Compose(compositor, document, White(), still, 1000, "lens-masked");
        Assert.True(Red(masked, 640, 360) < 40, "sharp loupe cannot bypass privacy masks");
    }

    [Fact]
    public void AReusedSourceRangeDrawsItsOwnCursor()
    {
        using var compositor = new FrameCompositor();
        var document = Plain();
        document.Cursor.SmoothMovementEnabled = false;
        document.Timeline.Slices = [new ClipSlice { Id = "a", SourceStartMs = 0, SourceEndMs = 2000 }, new ClipSlice { Id = "b", SourceStartMs = 0, SourceEndMs = 2000, HideCursor = true }];
        List<CursorSampleEvent> still = [new() { T = 0, X = 0.7, Y = 0.4 }, new() { T = 4000, X = 0.7, Y = 0.4 }];

        int DarkAroundCursor(byte[] pixels)
        {
            var count = 0;
            for (var y = 288; y < 330; y++)
            {
                for (var x = 896; x < 930; x++)
                {
                    count += Red(pixels, x, y) < 60 ? 1 : 0;
                }
            }

            return count;
        }

        var visible = Compose(compositor, document, White(), still, 500, "reused-visible");
        var hidden = Compose(compositor, document, White(), still, 2500, "reused-hidden");
        Assert.True(DarkAroundCursor(visible) > 20, "cursor shows in the first source occurrence");
        Assert.Equal(0, DarkAroundCursor(hidden));
    }
}
