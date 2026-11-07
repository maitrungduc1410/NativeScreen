using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class TimelineSnappingTests
{
    // 0.1 points per ms: the 8 point threshold is 80 ms.
    private const double PointsPerMs = 0.1;

    [Fact]
    public void AMoveKeepsItsLengthAndSnapsTheCloserEdge()
    {
        var snap = new TimelineSnapController();
        snap.Begin([4610], PointsPerMs);
        Assert.Equal(4610, snap.SnapMove(4650, 1000));
        Assert.Equal(4610, snap.GuideTimelineMs);
        Assert.Equal(3610, snap.SnapMove(3580, 1000));
        Assert.Equal(4610, snap.GuideTimelineMs);
    }

    [Fact]
    public void OutsideTheThresholdNothingMoves()
    {
        var snap = new TimelineSnapController();
        snap.Begin([4610], PointsPerMs);
        Assert.Equal(4700, snap.SnapMove(4700, 500));
        Assert.Null(snap.GuideTimelineMs);
        Assert.Equal(4691, snap.SnapEdge(4691));
        Assert.Equal(4610, snap.SnapEdge(4689));
    }

    [Fact]
    public void BothEdgesNearTargetsPicksTheNearer()
    {
        var snap = new TimelineSnapController();
        snap.Begin([1000, 2050], PointsPerMs);
        Assert.Equal(1040, snap.SnapMove(1030, 1010));
        Assert.Equal(2050, snap.GuideTimelineMs);
    }

    [Fact]
    public void TheThresholdFollowsTheZoom()
    {
        var snap = new TimelineSnapController();
        snap.Begin([1000], 1);
        Assert.Equal(1020, snap.SnapEdge(1020));
        snap.Begin([1000], 0.1);
        Assert.Equal(1000, snap.SnapEdge(1020));
    }

    [Fact]
    public void EndingClearsTheGuideAndTheTargets()
    {
        var snap = new TimelineSnapController();
        snap.Begin([1000], PointsPerMs);
        snap.SnapEdge(1010);
        snap.End();
        Assert.Null(snap.GuideTimelineMs);
        Assert.Equal(1010, snap.SnapEdge(1010));
    }

    [Fact]
    public void TargetsLeaveOutTheDraggedItemButKeepItsNeighbors()
    {
        var document = new ProjectDocument();
        document.Timeline.Slices =
        [
            new ClipSlice { Id = "a", SourceStartMs = 0, SourceEndMs = 4000 },
            new ClipSlice { Id = "b", SourceStartMs = 6000, SourceEndMs = 10000 }
        ];
        document.Timeline.Zooms =
        [
            new ZoomBlock { Id = "z1", SourceStartMs = 1000, SourceEndMs = 2000 },
            new ZoomBlock { Id = "z2", SourceStartMs = 2000, SourceEndMs = 3000 },
            new ZoomBlock { Id = "gone", SourceStartMs = 4500, SourceEndMs = 5500 }
        ];
        var session = new EditorSession(document, 10000);
        session.Scrub(1234);
        var targets = TimelineSnapTargets.Collect(session, "z2");
        Assert.Contains(0, targets);
        Assert.Contains(8000, targets);
        Assert.Contains(4000, targets);
        Assert.Contains(1234, targets);
        Assert.Contains(1000, targets);
        Assert.Contains(2000, targets);
        Assert.DoesNotContain(3000, targets);
        Assert.Equal(2 + 1 + 4 + 2, targets.Count);
    }
}
