using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class VoiceoverCutTests
{
    private static EditorSession Session(params VoiceoverSegment[] voiceovers)
    {
        var document = new ProjectDocument();
        document.Timeline.Slices = [new ClipSlice { Id = "s", SourceStartMs = 0, SourceEndMs = 20000 }];
        document.Timeline.Voiceovers = [.. voiceovers];
        return new EditorSession(document, 20000);
    }

    private static VoiceoverSegment Segment(string id, double start, double duration, double offset = 0, int track = 0) =>
        new() { Id = id, SourceStartMs = start, DurationMs = duration, RelativePath = "assets/vo.wav", FileOffsetMs = offset, TrackIndex = track };

    [Fact]
    public void TheOffsetRoundTripsAndDefaultsToZero()
    {
        Assert.Equal(0, ProjectJson.Clone(new VoiceoverSegment()).FileOffsetMs);
        Assert.Equal(1500, ProjectJson.Clone(Segment("a", 0, 1000, 1500)).FileOffsetMs);
        Assert.Equal(0, new VoiceoverSegment { FileOffsetMs = -5 }.FileOffsetMs);
    }

    [Fact]
    public void ACutGivesTwoHalvesOfOneFileAndSelectsTheSecond()
    {
        var session = Session(Segment("a", 1000, 4000, 500));
        session.SplitVoiceover("a", 2500);
        var list = session.Document.Timeline.Voiceovers;
        Assert.Equal(2, list.Count);
        Assert.DoesNotContain(list, item => item.Id == "a");
        Assert.Equal(1000, list[0].SourceStartMs);
        Assert.Equal(1500, list[0].DurationMs);
        Assert.Equal(500, list[0].FileOffsetMs);
        Assert.Equal(list[0].SourceEndMs, list[1].SourceStartMs);
        Assert.Equal(2500, list[1].DurationMs);
        Assert.Equal(2000, list[1].FileOffsetMs);
        Assert.Equal(list[1].RelativePath, list[0].RelativePath);
        Assert.Equal(list[1].Id, session.SelectedVoiceoverId);
        Assert.Equal(0, list[1].TrackIndex);
    }

    [Fact]
    public void AHalfUnderTwoHundredMillisecondsIsRefused()
    {
        var session = Session(Segment("a", 1000, 4000));
        string? toast = null;
        session.ToastRequested += text => toast = text;
        session.SplitVoiceover("a", 1150);
        Assert.Single(session.Document.Timeline.Voiceovers);
        Assert.Equal("Can't cut item shorter than 0.2s", toast);
    }

    [Fact]
    public void TheCutKeyPrefersASelectedVoiceoverAndUndoRestoresIt()
    {
        var session = Session(Segment("a", 0, 4000));
        session.SelectVoiceover("a");
        session.Scrub(1500);
        session.SplitAtCurrentTime();
        Assert.Equal(2, session.Document.Timeline.Voiceovers.Count);
        Assert.Single(session.Document.Timeline.Slices);
        session.Undo();
        Assert.Equal("a", Assert.Single(session.Document.Timeline.Voiceovers).Id);
    }

    [Fact]
    public void TheEventComesBeforeTheEditWithTheNewIds()
    {
        var session = Session(Segment("a", 0, 4000));
        var seen = new List<string>();
        var countAtEvent = 0;
        session.VoiceoverSplitting += (original, first, second) =>
        {
            seen.AddRange([original, first, second]);
            countAtEvent = session.Document.Timeline.Voiceovers.Count;
        };
        session.SplitVoiceover("a", 2000);
        Assert.Equal(1, countAtEvent);
        Assert.Equal("a", seen[0]);
        Assert.Equal(seen[1], session.Document.Timeline.Voiceovers[0].Id);
        Assert.Equal(seen[2], session.Document.Timeline.Voiceovers[1].Id);
    }

    [Fact]
    public void TrimmingTheLeftEdgeKeepsTheWordsInPlace()
    {
        var session = Session(Segment("a", 1000, 4000, 300));
        session.ResizeVoiceover("a", 1800, 5000);
        var item = session.Document.Timeline.Voiceovers[0];
        Assert.Equal(1800, item.SourceStartMs);
        Assert.Equal(3200, item.DurationMs);
        Assert.Equal(1100, item.FileOffsetMs);
        // What plays at 2 s comes from the same place in the file as before the trim: 300 + (2000 - 1000).
        Assert.Equal(1300, item.FileOffsetMs + 2000 - item.SourceStartMs);
    }

    [Fact]
    public void TheLeftEdgeStopsWhereTheFileBegins()
    {
        var session = Session(Segment("a", 1000, 4000, 300));
        session.ResizeVoiceover("a", 0, 5000);
        var item = session.Document.Timeline.Voiceovers[0];
        Assert.Equal(700, item.SourceStartMs);
        Assert.Equal(0, item.FileOffsetMs);
    }

    [Fact]
    public void EdgesStopAtNeighborsOnTheTrackAndTheShortestIsAQuarterSecond()
    {
        var session = Session(Segment("a", 1000, 2000, 5000), Segment("b", 4000, 1000), Segment("c", 500, 300, 0), Segment("other", 3000, 1000, 0, 1));
        session.ResizeVoiceover("a", 0, 9000);
        var item = session.Document.Timeline.Voiceovers.First(other => other.Id == "a");
        Assert.Equal(800, item.SourceStartMs);
        Assert.Equal(4000, item.SourceStartMs + item.DurationMs);
        session.ResizeVoiceover("a", 1000, 1100);
        Assert.Equal(3200, session.Document.Timeline.Voiceovers.First(other => other.Id == "a").DurationMs);
    }
}
