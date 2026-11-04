using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class TimelineAddPreviewTests
{
    private static (double Start, double End)? Span(double hover, params (double, double)[] blocks) =>
        TimelineAddPreview.Span(hover, blocks, 20000, 50, 500, 2800);

    [Fact]
    public void CentersOnThePointerInsideTheGap()
    {
        Assert.Equal((3600, 6400), Span(5000));
        Assert.Equal((0, 2800), Span(100));
        Assert.Equal((17200, 20000), Span(19900));
        Assert.Equal((10000, 12800), Span(10100, (0, 10000)));
    }

    [Fact]
    public void ShrinksToAGapShorterThanTheDefault()
    {
        Assert.Equal((1000, 2000), Span(1500, (0, 1000), (2000, 3000)));
    }

    [Fact]
    public void NothingOnOrBesideABlockOrInATinyGap()
    {
        Assert.Null(Span(1500, (1000, 2000)));
        Assert.Null(Span(2040, (1000, 2000)));
        Assert.Null(Span(2200, (1000, 2000), (2400, 3000)));
    }

    [Fact]
    public void AddingFromAGhostUsesExactlyItsRange()
    {
        var document = new ProjectDocument();
        document.Timeline.Slices = [new ClipSlice { Id = "a", SourceStartMs = 0, SourceEndMs = 10000 }];
        document.Timeline.MaskTracks = [new MaskTrack { Id = "t", Items = [new MaskItem { Id = "m", SourceStartMs = 0, SourceEndMs = 500, Type = MaskType.Spotlight, Style = MaskStyle.Dim, Intensity = 50 }] }];
        var session = new EditorSession(document, 10000);

        session.AddZoomInRange(1000, 3800);
        var zoom = session.Document.Timeline.Zooms[0];
        Assert.Equal((1000, 3800), (zoom.SourceStartMs, zoom.SourceEndMs));

        session.AddMaskInRange("t", 2000, 4800);
        var mask = session.Document.Timeline.MaskTracks[0].Items[1];
        Assert.Equal((2000, 4800), (mask.SourceStartMs, mask.SourceEndMs));
        Assert.Equal(MaskType.Spotlight, mask.Type);

        session.AddCustomShortcut(null, 5000, 6800);
        var shortcut = session.Document.Captions.CustomShortcuts[0];
        Assert.Equal((5000, 6800), (shortcut.SourceStartMs, shortcut.SourceEndMs));

        session.AddZoomInRange(1000, 1100);
        session.AddMaskInRange("t", 7000, 7100);
        Assert.Single(session.Document.Timeline.Zooms);
        Assert.Equal(2, session.Document.Timeline.MaskTracks[0].Items.Count);
    }
}
