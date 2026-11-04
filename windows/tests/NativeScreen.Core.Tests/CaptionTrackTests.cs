using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class CaptionTrackTests
{
    private static CaptionSegment Word(string id, string text, double start, double end) =>
        new() { Id = id, Text = text, SourceStartMs = start, SourceEndMs = end };

    private static EditorSession Session(params CaptionSegment[] words)
    {
        var document = new ProjectDocument();
        document.Captions.Segments = words.ToList();
        document.Timeline.Slices = [new ClipSlice { Id = "a", SourceStartMs = 0, SourceEndMs = 20000 }];
        return new EditorSession(document, 20000);
    }

    private static List<CaptionLineLayout.TrackFrame> Frames(EditorSession session, double time) =>
        CaptionLineLayout.Frames(ProjectJson.Clone(session.Document.Captions), time, 1920, 1080, (text, _, size) => (text.Length * size * 0.5, size * 1.2));

    [Fact]
    public void AnOldTranscriptBecomesAFirstTrackWithItsLook()
    {
        var document = new ProjectDocument();
        document.Captions.Segments = [Word("a", "One.", 0, 400), Word("b", "Two", 500, 900), Word("c", "three", 950, 1300)];
        document.Captions.ColorTheme = CaptionColorTheme.Light;
        var session = new EditorSession(document, 20000);
        var track = Assert.Single(session.Document.Captions.CaptionTracks);
        Assert.Equal(CaptionColorTheme.Light, track.Style.ColorTheme);
        Assert.Equal(2, session.Document.Captions.CaptionBlocks.Count);
        Assert.Equal(new[] { "b", "c" }, session.Document.Captions.CaptionBlocks[1].WordIds);
    }

    [Fact]
    public void ANewTrackAvoidsTheSpotOfTheLast()
    {
        var session = Session();
        session.AddCaptionTrack();
        session.AddCaptionTrack();
        var tracks = session.Document.Captions.CaptionTracks;
        Assert.Equal(new[] { "Captions", "Captions 2" }, tracks.Select(track => track.Name));
        Assert.Equal(1, tracks[0].Style.Position01.Y);
        Assert.Equal(0, tracks[1].Style.Position01.Y);
    }

    [Fact]
    public void SplittingKeepsSpokenTimingAndNeedsTwoWords()
    {
        var session = Session(Word("a", "One", 0, 1000), Word("b", "two", 1000, 2000), Word("c", "three", 2000, 3000));
        var block = session.Document.Captions.CaptionBlocks[0];
        var toast = "";
        session.ToastRequested += message => toast = message;
        session.SplitCaption(block.Id, 1500);
        var blocks = session.Document.Captions.CaptionBlocks;
        Assert.Equal(new[] { "a", "b" }, blocks[0].WordIds);
        Assert.Equal(new[] { "c" }, blocks[1].WordIds);
        Assert.Equal(2000, blocks[0].SourceEndMs);
        Assert.Equal(2000, blocks[1].SourceStartMs);
        session.SplitCaption(blocks[1].Id, 2500);
        Assert.Equal(2, session.Document.Captions.CaptionBlocks.Count);
        Assert.NotEmpty(toast);
    }

    [Fact]
    public void EditingTextKeepsTimingUntilTheWordCountChanges()
    {
        var session = Session(Word("a", "One", 0, 1000), Word("b", "two", 1000, 2000));
        var id = session.Document.Captions.CaptionBlocks[0].Id;
        session.UpdateCaptionText(id, "Uno dos");
        Assert.Equal("dos", session.Document.Captions.Segments[1].Text);
        Assert.Null(session.Document.Captions.CaptionBlocks[0].CustomText);
        session.UpdateCaptionText(id, "Just three words");
        var block = session.Document.Captions.CaptionBlocks[0];
        Assert.Equal("Just three words", block.CustomText);
        Assert.Empty(block.WordIds);
    }

    [Fact]
    public void StyleGoesToOneCaptionOrToTheWholeTrack()
    {
        var session = Session(Word("a", "One.", 0, 500), Word("b", "Two.", 600, 1000));
        var blocks = session.Document.Captions.CaptionBlocks;
        var trackId = session.Document.Captions.CaptionTracks[0].Id;
        session.UpdateCaptionStyle(blocks[0].Id, trackId, style => style.FontSizeRatio = 0.08);
        blocks = session.Document.Captions.CaptionBlocks;
        Assert.Equal(0.08, blocks[0].StyleOverride?.FontSizeRatio);
        Assert.Null(blocks[1].StyleOverride);
        Assert.Equal(0.045, session.Document.Captions.CaptionTracks[0].Style.FontSizeRatio);
        session.UpdateCaptionStyle(null, trackId, style => style.ColorTheme = CaptionColorTheme.Light);
        blocks = session.Document.Captions.CaptionBlocks;
        Assert.Equal(CaptionColorTheme.Light, session.Document.Captions.CaptionTracks[0].Style.ColorTheme);
        Assert.Equal(CaptionColorTheme.Light, blocks[0].StyleOverride?.ColorTheme);
    }

    [Fact]
    public void AnOccupiedTrackRefusesACaptionAndDraggingPastTheEndMakesANewOne()
    {
        var session = Session(Word("a", "One.", 0, 400), Word("b", "Two.", 500, 1000));
        var second = session.AddCaptionTrack();
        var block = session.Document.Captions.CaptionBlocks[0];
        session.MoveCaptionToTrack(block.Id, 1);
        Assert.NotEqual(second, session.Document.Captions.CaptionBlocks[0].TrackId);
        session.MoveCaptionToTrack(block.Id, 2);
        Assert.Equal(3, session.Document.Captions.CaptionTracks.Count);
        Assert.Equal(session.Document.Captions.CaptionTracks[2].Id, session.Document.Captions.CaptionBlocks[0].TrackId);
    }

    [Fact]
    public void ANewTrackStartsWithACaptionAtThePlayheadInOneUndoStep()
    {
        var session = Session();
        session.Scrub(19000);
        var trackId = session.AddCaptionTrack();
        var block = Assert.Single(session.Document.Captions.CaptionBlocks);
        Assert.Equal(trackId, block.TrackId);
        Assert.Equal(18000, block.SourceStartMs);
        Assert.Equal(20000, block.SourceEndMs);
        Assert.Equal(block.Id, session.SelectedCaptionId);
        session.Undo();
        Assert.Empty(session.Document.Captions.CaptionTracks);
        Assert.Empty(session.Document.Captions.CaptionBlocks);
    }

    [Fact]
    public void ATrackLeftWithoutCaptionsGoesAwayAndTheRestAreRenumbered()
    {
        var session = Session();
        session.AddCaptionTrack();
        session.AddCaptionTrack();
        session.AddCaptionTrack();
        var captions = session.Document.Captions;
        var middle = captions.CaptionBlocks.First(block => block.TrackId == captions.CaptionTracks[1].Id);
        var third = captions.CaptionTracks[2].Id;
        session.DeleteCaption(middle.Id);
        captions = session.Document.Captions;
        Assert.Equal(new[] { "Captions", "Captions 2" }, captions.CaptionTracks.Select(track => track.Name));
        Assert.Equal(third, captions.CaptionTracks[1].Id);
    }

    [Fact]
    public void MovingTheOnlyCaptionAwayRemovesItsTrack()
    {
        var session = Session();
        session.AddCaptionTrack();
        session.Scrub(5000);
        var second = session.AddCaptionTrack();
        var first = session.Document.Captions.CaptionBlocks[0];
        session.MoveCaptionToTrack(first.Id, 1);
        var track = Assert.Single(session.Document.Captions.CaptionTracks);
        Assert.Equal(second, track.Id);
        Assert.Equal("Captions", track.Name);
    }

    [Fact]
    public void DraggingTheOnlyCaptionPastTheEndChangesNothing()
    {
        var session = Session(Word("a", "One", 0, 1000));
        var trackId = session.Document.Captions.CaptionTracks[0].Id;
        var position = session.Document.Captions.CaptionTracks[0].Style.Position01.Y;
        session.MoveCaptionToTrack(session.Document.Captions.CaptionBlocks[0].Id, 1);
        session.MoveCaptionToTrack(session.Document.Captions.CaptionBlocks[0].Id, -1);
        var track = Assert.Single(session.Document.Captions.CaptionTracks);
        Assert.Equal(trackId, track.Id);
        Assert.Equal(position, track.Style.Position01.Y);
    }

    [Fact]
    public void DeletingEveryCaptionStaysDeletedAfterReloadAndUndoBringsItBack()
    {
        var session = Session(Word("a", "One", 0, 1000));
        session.DeleteCaption(session.Document.Captions.CaptionBlocks[0].Id);
        Assert.Empty(session.Document.Captions.CaptionTracks);
        var reloaded = new EditorSession(ProjectJson.Clone(session.Document), 20000);
        Assert.Empty(reloaded.Document.Captions.CaptionTracks);
        session.Undo();
        Assert.Single(session.Document.Captions.CaptionTracks);
        Assert.Single(session.Document.Captions.Segments);
    }

    [Fact]
    public void AnEmptyTrackFromAnOlderSaveIsRemovedOnLoad()
    {
        var document = new ProjectDocument();
        document.Captions.CaptionTracks = [new CaptionTrack { Id = "empty", Name = "Captions" }];
        var session = new EditorSession(document, 20000);
        Assert.Empty(session.Document.Captions.CaptionTracks);
    }

    [Fact]
    public void AFrameDependsOnlyOnItsTime()
    {
        var session = Session(Word("a", "One", 0, 400), Word("b", "two", 400, 800), Word("c", "three", 800, 1200));
        Assert.Empty(Frames(session, 5000));
        var first = Frames(session, 600);
        var again = Frames(session, 600);
        Assert.Equal(first[0].BoxRect, again[0].BoxRect);
        Assert.Equal(first[0].Words, again[0].Words);
        Assert.Equal(1, first[0].BoxOpacity, 2);
        // The box stays inside the margins with the default bottom position.
        Assert.True(first[0].BoxRect.Y + first[0].BoxRect.Height <= 1080);
    }

    [Fact]
    public void AHiddenTrackDrawsNothing()
    {
        var session = Session(Word("a", "One", 0, 1000));
        session.ToggleCaptionTrackHidden(session.Document.Captions.CaptionTracks[0].Id);
        Assert.Empty(Frames(session, 500));
    }
}
