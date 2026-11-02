using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class EditorSessionSegmentsTests
{
    private static EditorSession Session()
    {
        var document = new ProjectDocument();
        document.Timeline.Slices = [new ClipSlice { Id = "a", SourceStartMs = 0, SourceEndMs = 10000 }];
        document.Timeline.Zooms = [new ZoomBlock { Id = "z", SourceStartMs = 1000, SourceEndMs = 3000, Scale = 2 }];
        document.Timeline.MaskTracks = [new MaskTrack { Id = "t", Items = [new MaskItem { Id = "m", SourceStartMs = 4000, SourceEndMs = 6000 }] }];
        return new EditorSession(document, 10000);
    }

    [Fact]
    public void SplitAtCurrentTimeSplitsTheSelectionThenTheClip()
    {
        var session = Session();
        session.Scrub(2000);
        session.SelectZoom("z");
        session.SplitAtCurrentTime();
        Assert.Equal(2, session.Document.Timeline.Zooms.Count);
        Assert.Single(session.Document.Timeline.Slices);

        session.ClearSelection();
        session.SplitAtCurrentTime();
        Assert.Equal(2, session.Document.Timeline.Slices.Count);
    }

    [Fact]
    public void SplittingTooCloseToAnEdgeWarnsInsteadOfCutting()
    {
        var session = Session();
        var messages = new List<string>();
        session.ToastRequested += messages.Add;
        session.Scrub(1100);
        session.SelectZoom("z");
        session.SplitAtCurrentTime();
        Assert.Single(session.Document.Timeline.Zooms);
        Assert.Equal(["Can't cut item shorter than 0.2s"], messages);
    }

    [Fact]
    public void PastedZoomLandsAtThePlayheadOrStylesTheSelection()
    {
        var session = Session();
        session.CopyZoom("z");
        session.ClearSelection();
        session.Scrub(7000);
        session.PasteFromClipboard();
        var zooms = session.Document.Timeline.Zooms;
        Assert.Equal(2, zooms.Count);
        Assert.Equal(7000, zooms[1].SourceStartMs);
        Assert.Equal(9000, zooms[1].SourceEndMs);
        Assert.Equal(zooms[1].Id, session.SelectedZoomId);

        session.SetZoomScale("z", 3);
        session.CopyZoom("z");
        session.PasteFromClipboard();
        Assert.Equal(2, session.Document.Timeline.Zooms.Count);
        Assert.Equal(3, session.Document.Timeline.Zooms[1].Scale);
    }

    [Fact]
    public void CutMaskPastesIntoTheFirstTrack()
    {
        var session = Session();
        session.CutMask("m");
        Assert.DoesNotContain(session.Document.Timeline.MaskTracks.SelectMany(track => track.Items), item => item.Id == "m");
        session.Scrub(1000);
        session.PasteFromClipboard();
        var pasted = Assert.Single(session.Document.Timeline.MaskTracks[0].Items);
        Assert.Equal(1000, pasted.SourceStartMs);
        Assert.Equal(pasted.Id, session.SelectedMaskId);
    }

    [Fact]
    public void DisableKeyActsOnTheSelection()
    {
        var session = Session();
        session.SelectZoom("z");
        session.ToggleDisableSelected();
        Assert.True(session.Document.Timeline.Zooms[0].Disabled);
        session.SelectMask("m");
        session.ToggleDisableSelected();
        Assert.True(session.Document.Timeline.MaskTracks[0].Items[0].Disabled);
    }
}
