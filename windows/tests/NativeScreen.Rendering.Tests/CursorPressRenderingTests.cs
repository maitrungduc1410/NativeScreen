using NativeScreen.Core;

namespace NativeScreen.Rendering.Tests;

/// <summary>
/// A click presses the cursor in, and a theme hand folds its index finger onto the click (spec/06 ADR-95): the fingertip stays
/// where it was and the hand gets shorter. <c>NS_DUMP_FRAMES</c> writes the frames to look at.
/// </summary>
public sealed class CursorPressRenderingTests
{
    private sealed class OneFrame(VideoFrame frame) : IVideoFrameSource
    {
        public VideoFrame? FrameAt(double sourceMs) => frame;
    }

    private const int Width = 1280;
    private const int Height = 720;

    private static ProjectDocument Plain(bool alwaysPointer)
    {
        var document = new ProjectDocument();
        document.Timeline.Slices = [new ClipSlice { Id = "s", SourceStartMs = 0, SourceEndMs = 4000 }];
        document.Camera.Enabled = false;
        document.Canvas.PaddingRatio = 0;
        document.FrameStyle.BorderRadius = 0;
        document.FrameStyle.Inset.Enabled = false;
        document.FrameStyle.Shadow.Enabled = false;
        document.Background.Type = BackgroundType.Solid;
        document.Background.SolidColor = "#808080";
        document.Motion.MotionBlurIntensity = 0;
        document.Cursor.Scale = 6;
        document.Cursor.VelocityRotationEnabled = false;
        document.Cursor.AlwaysUsePointer = alwaysPointer;
        return document;
    }

    /// <summary>The cursor's box: rows and columns that differ from the gray screen.</summary>
    private static (int Top, int Bottom, int Left, int Right) Bounds(FrameCompositor compositor, ProjectDocument document, double timelineMs, string dump)
    {
        var pixels = new byte[1920 * 1080 * 3 / 2];
        pixels.AsSpan(0, 1920 * 1080).Fill(126);
        pixels.AsSpan(1920 * 1080).Fill(128);
        var frame = new VideoFrame(pixels, 1920, 1080, 0);
        IReadOnlyList<CursorSampleEvent> cursor = [new() { T = 0, X = 0.5, Y = 0.5, C = "pointinghand" }, new() { T = 4000, X = 0.5, Y = 0.5, C = "pointinghand" }];
        IReadOnlyList<ClickEvent> clicks = [new() { T = 1000, Type = "down", Button = "left", X = 0.5, Y = 0.5 }, new() { T = 1300, Type = "up", Button = "left", X = 0.5, Y = 0.5 }];
        var trajectory = new PlaybackTrajectorySolver(4000, cursor, clicks, document);
        var layer = compositor.Compose(
            new ComposeRequest
            {
                Document = document,
                Trajectory = trajectory,
                SourceMs = timelineMs,
                TimelineMs = timelineMs,
                ScreenSource = new OneFrame(frame),
                ScreenWidth = 1920,
                ScreenHeight = 1080,
                ExportQuality = true
            },
            Width,
            Height);
        var image = ImageTexture.ReadBack(compositor.Device, compositor.Context, layer.Texture, Width, Height);
        if (Environment.GetEnvironmentVariable("NS_DUMP_FRAMES") is { Length: > 0 } folder)
        {
            Directory.CreateDirectory(folder);
            ImageTexture.Save(image, Width, Height, Path.Combine(folder, dump + ".png"), false);
        }

        var (top, bottom, left, right) = (Height, -1, Width, -1);
        var gray = image[(10 * Width + 10) * 4];
        for (var y = 0; y < Height; y++)
        {
            for (var x = 0; x < Width; x++)
            {
                // Strong differences only, so the soft drop shadow does not count.
                if (Math.Abs(image[(y * Width + x) * 4] - gray) > 60)
                {
                    (top, bottom, left, right) = (Math.Min(top, y), Math.Max(bottom, y), Math.Min(left, x), Math.Max(right, x));
                }
            }
        }

        Assert.True(bottom > top, "no cursor drawn");
        return (top, bottom, left, right);
    }

    [Fact]
    public void AHandFoldsItsFingerOntoTheClick()
    {
        using var compositor = new FrameCompositor();
        var document = Plain(alwaysPointer: false);
        var up = Bounds(compositor, document, 500, "press-hand-up");
        var down = Bounds(compositor, document, 1150, "press-hand-down");
        var back = Bounds(compositor, document, 2500, "press-hand-back");

        // The fingertip stays on the click, and the palm comes up toward it: the hand is clearly shorter.
        Assert.InRange(down.Top - up.Top, -3, 3);
        Assert.True(down.Bottom - down.Top < (up.Bottom - up.Top) * 0.85, $"up {up}, down {down}");
        Assert.Equal(up, back);
    }

    [Fact]
    public void APointerOnlyPressesIn()
    {
        using var compositor = new FrameCompositor();
        var document = Plain(alwaysPointer: true);
        var up = Bounds(compositor, document, 500, "press-pointer-up");
        var down = Bounds(compositor, document, 1150, "press-pointer-down");

        // 92 % around the hotspot (the arrow tip, top left): the same tip, a slightly smaller arrow.
        var ratio = (down.Bottom - down.Top) / (double)(up.Bottom - up.Top);
        Assert.InRange(ratio, 0.88, 0.96);
        Assert.InRange(down.Top - up.Top, -2, 2);
        Assert.InRange(down.Left - up.Left, -2, 2);
    }
}
