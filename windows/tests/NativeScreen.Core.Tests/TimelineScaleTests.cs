using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class TimelineScaleTests
{
    private static EditorSession Session()
    {
        var document = new ProjectDocument();
        document.Timeline.Slices = [new ClipSlice { Id = "a", SourceStartMs = 0, SourceEndMs = 10000 }];
        return new EditorSession(document, 10000);
    }

    private static void Trim(EditorSession session, double end) =>
        session.Mutate(document => document.Timeline.Slices[0].SourceEndMs = end, structural: false);

    [Fact]
    public void TheScaleHoldsDuringADragAndUpdatesOnTheDrop()
    {
        var session = Session();
        session.BeginInteractiveEdit();
        Trim(session, 6000);
        Assert.Equal(6000, session.DurationMs);
        Assert.Equal(10000, session.TimelineScaleDurationMs);
        Trim(session, 4000);
        Assert.Equal(10000, session.TimelineScaleDurationMs);
        session.EndInteractiveEdit();
        Assert.Equal(4000, session.TimelineScaleDurationMs);
    }

    [Fact]
    public void WithoutADragTheScaleFollowsTheDuration()
    {
        var session = Session();
        Trim(session, 6000);
        Assert.Equal(6000, session.TimelineScaleDurationMs);
    }

    [Fact]
    public void AVeryShortProjectKeepsAOneSecondScale()
    {
        var session = Session();
        Trim(session, 300);
        Assert.Equal(1000, session.TimelineScaleDurationMs);
    }

    [Fact]
    public void ASegmentFollowsWhatTheClipsStillKeep()
    {
        var mapper = new NLETimeMapper([new ClipSlice { Id = "a", SourceStartMs = 0, SourceEndMs = 4000 }]);
        Assert.Equal((1000d, 2000d), mapper.TimelineSpan(1000, 2000));
        Assert.Equal((3000d, 4000d), mapper.TimelineSpan(3000, 6000));
        Assert.Null(mapper.TimelineSpan(4000, 6000));
        Assert.Null(mapper.TimelineSpan(5000, 6000));
        var grown = new NLETimeMapper([new ClipSlice { Id = "a", SourceStartMs = 0, SourceEndMs = 5500 }]);
        Assert.Equal((5000d, 5500d), grown.TimelineSpan(5000, 6000));
    }

    [Fact]
    public void ASegmentAcrossACutSpansBothSidesAndSpeedScalesIt()
    {
        var mapper = new NLETimeMapper(
        [
            new ClipSlice { Id = "a", SourceStartMs = 0, SourceEndMs = 2000 },
            new ClipSlice { Id = "b", SourceStartMs = 5000, SourceEndMs = 9000, Speed = 2 }
        ]);
        Assert.Equal((1000d, 3000d), mapper.TimelineSpan(1000, 7000));
        Assert.Null(mapper.TimelineSpan(3000, 4000));
    }

    [Fact]
    public void TrimmingAndGrowingBackKeepsASegmentsTimes()
    {
        var session = Session();
        session.Mutate(document => document.Timeline.Zooms = [new ZoomBlock { Id = "z", SourceStartMs = 7000, SourceEndMs = 8000 }]);
        session.BeginInteractiveEdit();
        Trim(session, 5000);
        Assert.Null(session.Mapper.TimelineSpan(7000, 8000));
        Trim(session, 10000);
        session.EndInteractiveEdit();
        Assert.Equal((7000d, 8000d), session.Mapper.TimelineSpan(7000, 8000));
        Assert.Equal(7000, session.Document.Timeline.Zooms[0].SourceStartMs);
    }

    [Fact]
    public void TheDragStaysOneUndoStep()
    {
        var session = Session();
        session.BeginInteractiveEdit();
        Trim(session, 6000);
        Trim(session, 4000);
        session.EndInteractiveEdit();
        session.Undo();
        Assert.Equal(10000, session.DurationMs);
    }
}
