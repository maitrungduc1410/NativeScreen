using NativeScreen.Core;

namespace NativeScreen.Rendering.Tests;

/// <summary>Camera-only framing and the green screen key (spec/07 Pass 2 and §7.4). `NS_DUMP_FRAMES` writes the frames.</summary>
public sealed class CameraOnlyRenderingTests
{
    private sealed class OneFrame(VideoFrame frame) : IVideoFrameSource
    {
        public VideoFrame? FrameAt(double sourceMs) => frame;
    }

    // BT.709 limited range, the inverse of Nv12ToRgb.hlsl.
    private static (byte Y, byte U, byte V) Yuv(double r, double g, double b)
    {
        var y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        var cb = (b - y) / 1.8556;
        var cr = (r - y) / 1.5748;
        return ((byte)Math.Round(16 + 219 * y), (byte)Math.Round(128 + 224 * cb), (byte)Math.Round(128 + 224 * cr));
    }

    /// <summary>A green backdrop with a gray "person" in the middle third.</summary>
    private static VideoFrame Backdrop(int width = 640, int height = 360)
    {
        var green = Yuv(0, 0xB1 / 255.0, 0x40 / 255.0);
        var gray = Yuv(0.55, 0.5, 0.45);
        var pixels = new byte[width * height * 3 / 2];
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var person = x > width / 3 && x < width * 2 / 3 && y > height / 4;
                pixels[y * width + x] = person ? gray.Y : green.Y;
                if (y % 2 == 0 && x % 2 == 0)
                {
                    var o = width * height + y / 2 * width + x;
                    pixels[o] = person ? gray.U : green.U;
                    pixels[o + 1] = person ? gray.V : green.V;
                }
            }
        }

        return new VideoFrame(pixels, width, height, 0);
    }

    private static byte[] Compose(ProjectDocument document, string name, bool cameraOnly = true, int width = 1280, int height = 720)
    {
        using var compositor = new FrameCompositor();
        var layer = compositor.Compose(
            new ComposeRequest
            {
                Document = document,
                Trajectory = new PlaybackTrajectorySolver(1000, [], [], document),
                SourceMs = 100,
                ScreenSource = new OneFrame(Backdrop()),
                ScreenWidth = 640,
                ScreenHeight = 360,
                CameraOnly = cameraOnly
            },
            width,
            height);
        var pixels = ImageTexture.ReadBack(compositor.Device, compositor.Context, layer.Texture, width, height);
        if (Environment.GetEnvironmentVariable("NS_DUMP_FRAMES") is { Length: > 0 } folder)
        {
            Directory.CreateDirectory(folder);
            ImageTexture.Save(pixels, width, height, Path.Combine(folder, name + ".png"), false);
        }

        return pixels;
    }

    private static (int B, int G, int R) At(byte[] pixels, int width, int x, int y)
    {
        var o = (y * width + x) * 4;
        return (pixels[o], pixels[o + 1], pixels[o + 2]);
    }

    private static ProjectDocument Document(CameraOnlyFraming framing, bool greenScreen)
    {
        var document = new ProjectDocument();
        document.Background.Type = BackgroundType.Solid;
        document.Background.SolidColor = "#2040FF";
        document.Camera.CameraOnlyFraming = framing;
        document.Camera.BackgroundRemoval = greenScreen ? CameraBackgroundRemoval.GreenScreen : CameraBackgroundRemoval.Ai;
        document.FrameStyle.DeviceMockup.Enabled = true;
        return document;
    }

    [Fact]
    public void FullFrameCoversTheCanvasWithNoFrame()
    {
        var pixels = Compose(Document(CameraOnlyFraming.FullFrame, false), "camera-only-full-frame");
        // The corner shows the picture's green, not the blue background, and no device frame was drawn.
        var (b, g, r) = At(pixels, 1280, 2, 2);
        Assert.True(g > 120 && b < 110 && r < 60, $"corner {r},{g},{b}");
    }

    [Fact]
    public void FramedKeepsThePadding()
    {
        var pixels = Compose(Document(CameraOnlyFraming.Framed, false), "camera-only-framed");
        var (b, _, r) = At(pixels, 1280, 2, 2);
        Assert.True(b > 200 && r < 60, "the background shows in the padding");
    }

    [Fact]
    public void GreenScreenCutoutShowsTheBackgroundAroundThePerson()
    {
        var pixels = Compose(Document(CameraOnlyFraming.Cutout, true), "camera-only-cutout-green");
        var (b, g, r) = At(pixels, 1280, 100, 100);
        Assert.True(b > 200 && g < 120, $"backdrop removed: {r},{g},{b}");
        var (pb, pg, pr) = At(pixels, 1280, 640, 500);
        Assert.True(Math.Abs(pr - pg) < 40 && pr > 90, $"person kept: {pr},{pg},{pb}");
    }
}
