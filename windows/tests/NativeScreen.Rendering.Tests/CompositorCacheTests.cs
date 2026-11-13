using NativeScreen.Core;
using NativeScreen.Intelligence;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace NativeScreen.Rendering.Tests;

public sealed class CompositorCacheTests
{
    private sealed class OneFrame : IVideoFrameSource
    {
        public VideoFrame? Current { get; set; }

        public VideoFrame? FrameAt(double sourceMs) => Current;
    }

    private static VideoFrame Flat(byte luma, int width = 1920, int height = 1080)
    {
        var pixels = new byte[width * height * 3 / 2];
        pixels.AsSpan(0, width * height).Fill(luma);
        pixels.AsSpan(width * height).Fill(128);
        return new VideoFrame(pixels, width, height, 0);
    }

    private static byte[] Compose(FrameCompositor compositor, ProjectDocument document, PlaybackTrajectorySolver trajectory, IVideoFrameSource screen, int width, int height, IVideoFrameSource? webcam = null)
    {
        var layer = compositor.Compose(
            new ComposeRequest { Document = document, Trajectory = trajectory, SourceMs = 100, ScreenSource = screen, WebcamSource = webcam, HasCamera = webcam is not null, ScreenWidth = 1920, ScreenHeight = 1080 },
            width,
            height);
        return ImageTexture.ReadBack(compositor.Device, compositor.Context, layer.Texture, width, height);
    }

    [Fact]
    public void ANewVideoFrameIsDrawnEvenWhenTheScaleIsTheSame()
    {
        using var compositor = new FrameCompositor();
        var document = new ProjectDocument();
        var trajectory = new PlaybackTrajectorySolver(1000, [], [], document);
        var source = new OneFrame { Current = Flat(235) };
        var white = Compose(compositor, document, trajectory, source, 1280, 720);
        Assert.Equal(white, Compose(compositor, document, trajectory, source, 1280, 720));
        source.Current = Flat(16);
        var black = Compose(compositor, document, trajectory, source, 1280, 720);
        Assert.NotEqual(white, black);
    }

    [Fact]
    public void ANewCameraFrameIsDrawnAndTheSameOneReused()
    {
        using var compositor = new FrameCompositor();
        var document = new ProjectDocument();
        document.Camera.Enabled = true;
        var trajectory = new PlaybackTrajectorySolver(1000, [], [], document);
        var screen = new OneFrame { Current = Flat(128) };
        var camera = new OneFrame { Current = Flat(235, 640, 360) };
        var first = Compose(compositor, document, trajectory, screen, 1280, 720, camera);
        Assert.Equal(first, Compose(compositor, document, trajectory, screen, 1280, 720, camera));
        camera.Current = Flat(16, 640, 360);
        Assert.NotEqual(first, Compose(compositor, document, trajectory, screen, 1280, 720, camera));
    }

    [Fact]
    public void ResizingKeepsTheScratchTexturesBounded()
    {
        using var compositor = new FrameCompositor();
        var document = new ProjectDocument();
        document.FrameStyle.Shadow.Enabled = true;
        document.FrameStyle.Shadow.Intensity = 0.5;
        var trajectory = new PlaybackTrajectorySolver(1000, [], [], document);
        var source = new OneFrame { Current = Flat(128) };
        for (var step = 0; step < 60; step++)
        {
            compositor.Compose(new ComposeRequest { Document = document, Trajectory = trajectory, SourceMs = 100, ScreenSource = source, ScreenWidth = 1920, ScreenHeight = 1080 }, 800 + step * 2, 450 + step);
            Assert.InRange(compositor.ScratchLayerCount, 0, 12);
        }

        Assert.InRange(compositor.ScratchLayerCount, 1, 9);
    }

    [Fact]
    public void TheMaskInputIsReusedWhenItFits()
    {
        var frame = Flat(128, 640, 360);
        var first = PersonSegmenter.Prepare(frame, Rect01.Full, true, 320);
        Assert.Same(first, PersonSegmenter.Prepare(frame, Rect01.Full, true, 320, first));
        Assert.NotSame(first, PersonSegmenter.Prepare(Flat(128, 640, 640), Rect01.Full, true, 320, first));
        DenseTensor<float>? none = null;
        Assert.NotNull(PersonSegmenter.Prepare(frame, Rect01.Full, true, 320, none));
    }
}
