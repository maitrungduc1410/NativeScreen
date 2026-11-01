using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class EditorEditingTests
{
    [Fact]
    public void AnInteractiveEditIsOneUndoStep()
    {
        var session = new EditorSession(durationMs: 10000);
        session.AddZoomAtPlayhead(ZoomPresentation.Screen);
        var id = session.Document.Timeline.Zooms[0].Id;
        var original = session.Document.Timeline.Zooms[0].SourceStartMs;

        session.BeginInteractiveEdit();
        session.Mutate(document => document.Timeline.Zooms[0].SourceStartMs = 500);
        session.Mutate(document => document.Timeline.Zooms[0].SourceStartMs = 900);
        session.EndInteractiveEdit();
        Assert.Equal(900, session.Document.Timeline.Zooms.First(zoom => zoom.Id == id).SourceStartMs);

        session.Undo();
        Assert.Equal(original, session.Document.Timeline.Zooms[0].SourceStartMs);
        session.Undo();
        Assert.Empty(session.Document.Timeline.Zooms);
    }

    [Fact]
    public void SplitKeepsTheTimelineDurationAndRespectsSpeed()
    {
        var document = new ProjectDocument();
        document.Timeline.Slices.Add(new ClipSlice { Id = "a", SourceStartMs = 0, SourceEndMs = 4000, Speed = 2 });
        var session = new EditorSession(document, 4000);
        Assert.Equal(2000, session.DurationMs);

        Assert.True(session.SplitSlice(500));
        Assert.Equal(2, session.Document.Timeline.Slices.Count);
        Assert.Equal(1000, session.Document.Timeline.Slices[0].SourceEndMs);
        Assert.Equal(1000, session.Document.Timeline.Slices[1].SourceStartMs);
        Assert.Equal(2000, session.DurationMs);

        Assert.False(session.SplitSlice(50));
        session.Undo();
        Assert.Single(session.Document.Timeline.Slices);
    }

    [Fact]
    public void AddingAZoomInsideOneOnlySelectsIt()
    {
        var session = new EditorSession(durationMs: 10000);
        session.AddZoomAtPlayhead(ZoomPresentation.Screen);
        session.ClearSelection();
        session.AddZoomAtPlayhead(ZoomPresentation.Loupe);
        var zoom = Assert.Single(session.Document.Timeline.Zooms);
        Assert.Equal(ZoomPresentation.Loupe, zoom.Presentation);
        Assert.Equal(zoom.Id, session.SelectedZoomId);
    }

    [Fact]
    public void RemovingTheLastMaskDropsItsTrackAndRenamesTheRest()
    {
        var session = new EditorSession(durationMs: 10000);
        session.AddMaskAtPlayhead(MaskType.Blur);
        session.AddMaskAtPlayhead(MaskType.Spotlight);
        Assert.Equal(["Masks", "Masks 2"], session.Document.Timeline.MaskTracks.Select(track => track.Name));

        session.DeleteSelected();
        Assert.Equal("Masks", Assert.Single(session.Document.Timeline.MaskTracks).Name);
    }

    [Fact]
    public void ShowcaseMatchesTheMacDemoShape()
    {
        var document = ShowcaseProject.Create();
        Assert.Single(document.Timeline.Slices);
        Assert.Equal(3, document.Timeline.Zooms.Count);
        Assert.Equal(2, document.Timeline.MaskTracks.Count);
    }

    [Fact]
    public void GeneratedZoomsGetDistinctIdsSoOnlyOneIsSelected()
    {
        var session = new EditorSession(ShowcaseProject.Create(), ShowcaseProject.DurationMs);
        var ids = session.Document.Timeline.Zooms.Select(zoom => zoom.Id).ToList();
        Assert.All(ids, id => Assert.NotEmpty(id));
        Assert.Equal(ids.Count, ids.Distinct().Count());
    }
}
