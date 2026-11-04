using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class VoiceoverRecordingTests
{
    private static EditorSession Session(params VoiceoverSegment[] voiceovers)
    {
        var document = new ProjectDocument();
        document.Timeline.Slices = [new ClipSlice { Id = "a", SourceStartMs = 0, SourceEndMs = 20000 }];
        document.Timeline.Voiceovers = voiceovers.ToList();
        return new EditorSession(document, 20000);
    }

    private static VoiceoverSegment Segment(string id, double start, double duration, int track) =>
        new() { Id = id, SourceStartMs = start, DurationMs = duration, TrackIndex = track, RelativePath = "assets/" + id + ".m4a" };

    [Fact]
    public void ATrackOnlyCountsAsEmptyWithNothingAfterTheStart()
    {
        var voiceovers = new[] { Segment("a", 1000, 1000, 0), Segment("b", 8000, 1000, 1) };
        Assert.Equal(0, VoiceoverTrackLayout.FirstTrackEmptyAfter(voiceovers, 3000));
        Assert.Equal(2, VoiceoverTrackLayout.FirstTrackEmptyAfter(voiceovers, 1500));
        Assert.Equal(1, VoiceoverTrackLayout.FirstTrackEmptyAfter([Segment("a", 1000, 1000, 0)], 0));
        Assert.Equal(0, VoiceoverTrackLayout.FirstTrackEmptyAfter([], 0));
    }

    [Fact]
    public void ARecordingStartsAtThePlayheadAndAddsItsSegmentAtTheEnd()
    {
        var session = Session();
        session.Scrub(3000);
        session.BeginVoiceoverRecording();
        Assert.True(session.IsRecordingVoiceover);
        Assert.Empty(session.Document.Timeline.Voiceovers);
        session.Scrub(9000);
        session.EndVoiceoverRecording();
        var added = session.AddRecordedVoiceover("assets/take.m4a", 6000);
        var segment = Assert.Single(session.Document.Timeline.Voiceovers);
        Assert.False(session.IsRecordingVoiceover);
        Assert.Equal(added.Id, segment.Id);
        Assert.Equal(3000, segment.SourceStartMs);
        Assert.Equal(6000, segment.DurationMs);
        Assert.Equal(1, segment.Volume);
        Assert.Equal(VoiceoverAttachMode.Synchronized, segment.AttachMode);
        Assert.Equal(InspectorTab.Audio, session.SelectedTab);
    }

    [Fact]
    public void AVeryShortTakeKeepsAUsableLengthAndALongOneStopsAtTheEnd()
    {
        var session = Session();
        session.BeginVoiceoverRecording();
        session.EndVoiceoverRecording();
        Assert.Equal(1200, session.AddRecordedVoiceover("assets/a.m4a", 100).DurationMs);

        session = Session();
        session.Scrub(19000);
        session.BeginVoiceoverRecording();
        session.EndVoiceoverRecording();
        var segment = session.AddRecordedVoiceover("assets/b.m4a", 60000);
        Assert.Equal(19000, segment.SourceStartMs);
        Assert.Equal(1000, segment.DurationMs);
    }

    [Fact]
    public void ANewTakeGoesOnItsOwnTrackWhenTheFirstIsBusyAndUnhidesIt()
    {
        var session = Session(Segment("old", 5000, 3000, 0));
        session.Scrub(1000);
        session.BeginVoiceoverRecording();
        Assert.Equal(1, session.VoiceoverRecordingTrackIndex);
        session.EndVoiceoverRecording();
        var segment = session.AddRecordedVoiceover("assets/c.m4a", 2000);
        Assert.Equal(1, session.Document.Timeline.Voiceovers.First(item => item.Id == segment.Id).TrackIndex);
        Assert.False(VoiceoverTrackLayout.IsTrackHidden(session.Document.Timeline, 1));
    }

    [Fact]
    public void OneUndoRemovesATake()
    {
        var session = Session();
        session.BeginVoiceoverRecording();
        session.EndVoiceoverRecording();
        session.AddRecordedVoiceover("assets/d.m4a", 2000);
        session.Undo();
        Assert.Empty(session.Document.Timeline.Voiceovers);
    }
}
