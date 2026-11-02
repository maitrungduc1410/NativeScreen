using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class TimelineEditsTests
{
    private static ProjectDocument Document()
    {
        var document = new ProjectDocument();
        document.Timeline.Slices = [new ClipSlice { Id = "a", SourceStartMs = 0, SourceEndMs = 4000 }, new ClipSlice { Id = "b", SourceStartMs = 6000, SourceEndMs = 10000 }];
        return document;
    }

    [Fact]
    public void SliceEdgesStopAtNeighboursAndKeepAMinimumLength()
    {
        var document = Document();
        Assert.Equal((4000, 10000), TimelineEdits.SliceBounds(document, "b", 10000));
        Assert.Equal((0, 6000), TimelineEdits.SliceBounds(document, "a", 10000));
        TimelineEdits.SetSliceRange(document, "a", 3990, 4000, 10000);
        Assert.Equal(3990, document.Timeline.Slices[0].SourceStartMs);
        Assert.Equal(4190, document.Timeline.Slices[0].SourceEndMs);
    }

    [Fact]
    public void AMaskWithOneKeyframeMovesWholeAndWithSeveralGainsOne()
    {
        var mask = new MaskItem { SourceStartMs = 0, SourceEndMs = 5000, Keyframes = [new MaskKeyframe { SourceMs = 0 }] };
        TimelineEdits.SetMaskRect(mask, new Rect01(0.1, 0.1, 0.2, 0.2), 3000);
        Assert.Single(mask.Keyframes);
        Assert.Equal(0.1, mask.Keyframes[0].Rect01.X);

        mask.Keyframes.Add(new MaskKeyframe { SourceMs = 4000, Rect01 = new Rect01(0.5, 0.5, 0.2, 0.2) });
        TimelineEdits.SetMaskRect(mask, new Rect01(0.3, 0.3, 0.2, 0.2), 2000);
        Assert.Equal([0.0, 2000.0, 4000.0], mask.Keyframes.Select(frame => frame.SourceMs));
        TimelineEdits.SetMaskRect(mask, new Rect01(0.4, 0.4, 0.2, 0.2), 2050);
        Assert.Equal(3, mask.Keyframes.Count);
        Assert.Equal(0.4, mask.Keyframes[1].Rect01.X);
    }

    [Fact]
    public void LayoutsFillFreeSpaceOrChangeTheOneUnderThePlayhead()
    {
        var document = Document();
        var id = TimelineEdits.AddCameraLayout(document, 1000, 10000, CameraTimelineLayoutType.SplitScreen);
        var layout = Assert.Single(document.Timeline.CameraLayouts);
        Assert.Equal(id, layout.Id);
        Assert.Equal(1000, layout.SourceStartMs);
        Assert.Equal(4500, layout.SourceEndMs);

        TimelineEdits.AddCameraLayout(document, 2000, 10000, CameraTimelineLayoutType.ScreenOnly);
        Assert.Equal(CameraTimelineLayoutType.ScreenOnly, Assert.Single(document.Timeline.CameraLayouts).LayoutType);

        var next = TimelineEdits.AddCameraLayout(document, 4600, 10000, CameraTimelineLayoutType.CameraOverlay);
        Assert.NotNull(next);
        Assert.True(document.Timeline.CameraLayouts[1].SourceStartMs >= 4500);
    }

    [Fact]
    public void ACustomShortcutAppearsAndDeletingTheLastRemovesItsTrack()
    {
        var document = Document();
        var id = TimelineEdits.AddCustomShortcut(document, [], null, 1000, 10000);
        Assert.NotNull(id);
        Assert.Single(document.Captions.ShortcutTracks);
        var clusters = ShortcutEngine.Detect(document, []);
        var cluster = Assert.Single(clusters);
        Assert.Equal(id, cluster.Id);

        TimelineEdits.SetShortcutRange(document, cluster, 2000, 3000);
        TimelineEdits.SetShortcutKeys(document, cluster, ["Ctrl"], "P");
        var changed = Assert.Single(ShortcutEngine.Detect(document, []));
        Assert.Equal("P", changed.PrimaryKey);
        Assert.Equal(2000, changed.DisplayStartMs);

        TimelineEdits.DeleteShortcut(document, changed, [changed]);
        Assert.Empty(document.Captions.ShortcutTracks);
        Assert.Empty(ShortcutEngine.Detect(document, []));
    }

    [Fact]
    public void ARecordedShortcutIsRememberedAsDeleted()
    {
        var document = Document();
        var keys = new List<KeyStrokeEvent> { new() { T = 1000, Kind = "shortcut", Modifiers = ["Ctrl"], Key = "K", Label = "Ctrl K" } };
        document.Captions.ShortcutTracks.Add(new ShortcutTrackConfig { Id = "default-shortcuts-track" });
        var cluster = Assert.Single(ShortcutEngine.Detect(document, keys));
        TimelineEdits.SetShortcutRange(document, cluster, 1200, 2200);
        Assert.Equal(1200, Assert.Single(ShortcutEngine.Detect(document, keys)).DisplayStartMs);
        TimelineEdits.DeleteShortcut(document, cluster, [cluster]);
        Assert.Empty(ShortcutEngine.Detect(document, keys));
        Assert.Contains(cluster.FirstKeyDownMsInt, document.Captions.DeletedShortcutStartMs);
    }

    [Fact]
    public void CanvasMappingInvertsUnderZoom()
    {
        var screen = new PixelRect(100, 50, 800, 450);
        var plain = new CanvasCoordinateTransform(1000, 550, screen, Point01.Center, 1);
        Assert.Equal((100, 50), plain.ToCanvas(0, 0));
        Assert.Equal((0.5, 0.5), plain.ToSource(500, 275));

        var zoomed = new CanvasCoordinateTransform(1000, 550, screen, new Point01(0.25, 0.75), 2);
        var (x, y) = zoomed.ToCanvas(0.25, 0.75);
        Assert.Equal(500, x, 6);
        Assert.Equal(275, y, 6);
        var (backX, backY) = zoomed.ToSource(x + 100, y - 40);
        var (again, againY) = zoomed.ToCanvas(backX, backY);
        Assert.Equal(x + 100, again, 6);
        Assert.Equal(y - 40, againY, 6);
        Assert.Equal((0.0625, 0.0), zoomed.DeltaToSource(100, 0));
    }
}
