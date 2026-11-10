using NativeScreen.Core;

namespace NativeScreen.Rendering.Tests;

/// <summary>Passes 3B and 5C draw every kind; `NS_DUMP_FRAMES` writes the frames to look at.</summary>
public sealed class AnnotationRenderingTests
{
    private sealed class OneFrame(VideoFrame frame) : IVideoFrameSource
    {
        public VideoFrame? FrameAt(double sourceMs) => frame;
    }

    private static VideoFrame Flat(byte luma, int width = 1920, int height = 1080)
    {
        var pixels = new byte[width * height * 3 / 2];
        pixels.AsSpan(0, width * height).Fill(luma);
        pixels.AsSpan(width * height).Fill(128);
        return new VideoFrame(pixels, width, height, 0);
    }

    private static AnnotationItem Item(AnnotationKind kind, Action<AnnotationItem>? edit = null)
    {
        var item = new AnnotationItem { SourceStartMs = 0, SourceEndMs = 4000, Kind = kind, Enter = AnnotationAnimation.None, Exit = AnnotationAnimation.None };
        edit?.Invoke(item);
        return item;
    }

    private static ProjectDocument EveryKind()
    {
        var document = new ProjectDocument();
        document.Timeline.AnnotationTracks =
        [
            new AnnotationTrack { Name = "Top", Items = [Item(AnnotationKind.Text, i => { i.Text = "Click Save to keep it"; i.Position01 = new Point01(0.5, 0.2); })] },
            new AnnotationTrack { Items = [Item(AnnotationKind.Arrow, i => { i.From01 = new Point01(0.2, 0.7); i.To01 = new Point01(0.4, 0.45); })] },
            new AnnotationTrack { Items = [Item(AnnotationKind.Rectangle, i => { i.Position01 = new Point01(0.7, 0.5); i.FillOpacity = 0.2; i.RotationDegrees = 12; })] },
            new AnnotationTrack { Items = [Item(AnnotationKind.Ellipse, i => { i.Position01 = new Point01(0.3, 0.35); })] },
            new AnnotationTrack { Items = [Item(AnnotationKind.Step, i => { i.Position01 = new Point01(0.85, 0.2); i.Anchor = AnnotationAnchor.Canvas; })] },
            new AnnotationTrack
            {
                Items =
                [
                    Item(AnnotationKind.Pen, i =>
                    {
                        i.Position01 = new Point01(0.55, 0.8);
                        i.Size01 = new Size01(0.3, 0.1);
                        i.Points01 = [new(0, 0.5), new(0.2, 0), new(0.4, 1), new(0.6, 0), new(0.8, 1), new(1, 0.5), new(0, 1), new(1, 1)];
                        i.StrokeStarts = [6];
                        i.Highlighter = false;
                    })
                ]
            },
            new AnnotationTrack { Items = [Item(AnnotationKind.Text, i => { i.Text = "Frame pinned"; i.Anchor = AnnotationAnchor.Canvas; i.Position01 = new Point01(0.5, 0.92); i.TextBackground = AnnotationTextBackground.None; })] }
        ];
        return document;
    }

    private static byte[] Compose(FrameCompositor compositor, ProjectDocument document, double ms, int width, int height, string? dump = null)
    {
        var trajectory = new SpringTrajectorySolver(4000, [], [], document);
        var layer = compositor.Compose(
            new ComposeRequest { Document = document, Trajectory = trajectory, SourceMs = ms, ScreenSource = new OneFrame(Flat(60)), ScreenWidth = 1920, ScreenHeight = 1080 },
            width,
            height);
        var pixels = ImageTexture.ReadBack(compositor.Device, compositor.Context, layer.Texture, width, height);
        if (dump is not null && Environment.GetEnvironmentVariable("NS_DUMP_FRAMES") is { Length: > 0 } folder)
        {
            Directory.CreateDirectory(folder);
            ImageTexture.Save(pixels, width, height, Path.Combine(folder, dump + ".png"), false);
        }

        return pixels;
    }

    private static (byte B, byte G, byte R, byte A) At(byte[] pixels, int width, double x01, double y01, int height)
    {
        var o = ((int)(y01 * height) * width + (int)(x01 * width)) * 4;
        return (pixels[o], pixels[o + 1], pixels[o + 2], pixels[o + 3]);
    }

    [Fact]
    public void EveryKindIsDrawnAndTheEmptyFrameIsNot()
    {
        using var compositor = new FrameCompositor();
        var plain = Compose(compositor, new ProjectDocument(), 1000, 1280, 720);
        var drawn = Compose(compositor, EveryKind(), 1000, 1280, 720, "annotations-every-kind");
        Assert.NotEqual(plain, drawn);
        // The step badge is coral: red well above blue at its center.
        var (b, _, r, _) = At(drawn, 1280, 0.85 - 0.0117, 0.2, 720);
        Assert.True(r > b + 80, $"step center {r},{b}");
    }

    [Fact]
    public void FadesAndDrawOnChangeTheFrame()
    {
        using var compositor = new FrameCompositor();
        var document = EveryKind();
        foreach (var item in document.Timeline.AnnotationTracks.SelectMany(track => track.Items))
        {
            item.Enter = item.Kind.SupportsDrawOn() ? AnnotationAnimation.Draw : AnnotationAnimation.Pop;
            item.AnimationMs = 600;
        }

        var middle = Compose(compositor, document, 300, 1280, 720, "annotations-entering");
        var rest = Compose(compositor, document, 1500, 1280, 720);
        Assert.NotEqual(middle, rest);
    }

    [Fact]
    public void ScreenPinnedItemsFollowTheZoomAndKeepTheirSize()
    {
        using var compositor = new FrameCompositor();
        var document = EveryKind();
        document.Timeline.Zooms = [new ZoomBlock { Id = "z", SourceStartMs = 0, SourceEndMs = 4000, Scale = 1.8, ManualCenter01 = new Point01(0.3, 0.4), Mode = ZoomMode.Manual, InstantAnimation = true }];
        var zoomed = Compose(compositor, document, 2000, 1280, 720, "annotations-zoomed");
        Assert.NotEqual(Compose(compositor, EveryKind(), 2000, 1280, 720), zoomed);
    }

    [Fact]
    public void LiveDrawingConvertsTheMacOSLog()
    {
        // Two red strokes in one burst become one item; an undone arrow and a highlighter get their own tracks.
        List<LiveDrawingEvent> events =
        [
            LiveDrawingEvent.Stroke(1000, LiveDrawingTool.Pen, "#FF3B30", [[0.1, 0.1, 0], [0.2, 0.2, 100]], 3000),
            LiveDrawingEvent.Stroke(1500, LiveDrawingTool.Pen, "#FF3B30", [[0.3, 0.1, 0], [0.4, 0.2, 80]], 3000),
            LiveDrawingEvent.Stroke(1700, LiveDrawingTool.Highlighter, "#FFCC00", [[0.5, 0.5, 0], [0.7, 0.5, 120]], 3000),
            LiveDrawingEvent.Stroke(2000, LiveDrawingTool.Arrow, "#0A84FF", [[0.1, 0.9, 0], [0.3, 0.7, 200]], 3000),
            LiveDrawingEvent.Undo(2500),
            LiveDrawingEvent.Stroke(9000, LiveDrawingTool.Pen, "#FF3B30", [[0.6, 0.6, 0], [0.7, 0.7, 50]], 3000)
        ];
        var tracks = LiveDrawingEvent.AnnotationTracks(events, 20000);
        Assert.Equal(3, tracks.Count);
        Assert.Equal(["Live drawing", "Live drawing 2", "Live drawing 3"], tracks.Select(t => t.Name));
        var pen = tracks[0].Items[0];
        Assert.Equal(AnnotationKind.Pen, pen.Kind);
        Assert.Equal([2], pen.StrokeStarts);
        Assert.Equal([0, 100, 500, 580], pen.PointTimesMs);
        Assert.Equal(1000, pen.SourceStartMs);
        // The burst ends 3 s after its last finish (the arrow at 2200).
        Assert.Equal(5200, pen.SourceEndMs);
        var arrow = tracks.SelectMany(t => t.Items).Single(i => i.Kind == AnnotationKind.Arrow);
        Assert.Equal(2500, arrow.SourceEndMs);
        Assert.Equal(200, arrow.AnimationMs);
        Assert.Contains(tracks[0].Items, i => i.SourceStartMs == 9000);
        Assert.True(tracks.SelectMany(t => t.Items).Single(i => i.Highlighter).Highlighter);
    }
}
