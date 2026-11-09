using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class EditorPerformanceTests
{
    private static EditorSession Session(double durationMs = 20000)
    {
        var document = new ProjectDocument();
        document.Timeline.Slices = [new ClipSlice { Id = "s", SourceStartMs = 0, SourceEndMs = durationMs }];
        document.Timeline.Zooms = [new ZoomBlock { Id = "z", SourceStartMs = 1000, SourceEndMs = 9000, Scale = 2, Mode = ZoomMode.Manual, Presentation = ZoomPresentation.Screen }];
        return new EditorSession(document, durationMs);
    }

    [Fact]
    public async Task AFailedSaveDoesNotStopTheNextOne()
    {
        var failed = ProjectStore.WriteAfter(Task.CompletedTask, () => throw new IOException("locked"));
        await Assert.ThrowsAsync<IOException>(() => failed);
        var written = false;
        await ProjectStore.WriteAfter(failed, () => written = true);
        Assert.True(written);
    }

    [Fact]
    public void HidingTheZoomTrackReachesThePreview()
    {
        var session = Session();
        Assert.True(session.RenderSnapshot().Trajectory.Evaluate(8000).Camera.Scale > 1.5);
        session.Mutate(document => document.Timeline.IsZoomTrackHidden = true);
        Assert.Equal(1, session.RenderSnapshot().Trajectory.Evaluate(8000).Camera.Scale, 3);
    }

    [Fact]
    public void ACutDoesNotSolveTheMotionAgain()
    {
        var session = Session();
        var before = session.RenderSnapshot().Trajectory;
        session.Mutate(document => document.Timeline.Slices[0].SourceEndMs = 15000);
        Assert.Same(before, session.RenderSnapshot().Trajectory);
        session.Mutate(document => document.Timeline.Zooms[0].Scale = 3);
        Assert.NotSame(before, session.RenderSnapshot().Trajectory);
    }

    [Fact]
    public async Task ALongRecordingSolvesOffTheCallerAndKeepsTheNewestEdit()
    {
        var session = Session(120_000);
        var first = session.RenderSnapshot().Trajectory;
        var solved = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        session.TrajectorySolved += () => solved.TrySetResult();
        session.Mutate(document => document.Timeline.Zooms[0].Scale = 3);
        session.RenderSnapshot();
        session.Mutate(document => document.Timeline.Zooms[0].Scale = 2.5);
        session.RenderSnapshot();
        await solved.Task.WaitAsync(TimeSpan.FromSeconds(20));
        var latest = session.RenderSnapshot().Trajectory;
        Assert.NotSame(first, latest);
        Assert.Equal(2.5, latest.Evaluate(8000).Camera.Scale, 1);
    }

    [Theory]
    [InlineData(60)]
    [InlineData(75)]
    [InlineData(100)]
    [InlineData(120)]
    [InlineData(144)]
    [InlineData(165)]
    [InlineData(240)]
    public void TheCapHoldsAtAnyRefreshRate(int hertz)
    {
        var pacer = new FramePacer(1000.0 / 60, 2);
        var kept = 0;
        for (var frame = 0; frame < hertz * 10; frame++)
        {
            kept += pacer.Accept(frame * 1000.0 / hertz) ? 1 : 0;
        }

        Assert.InRange(kept / 10.0, 59, 61);
    }

    [Fact]
    public void AGapRestartsTheSchedule()
    {
        var pacer = new FramePacer(1000.0 / 60, 2);
        Assert.True(pacer.Accept(0));
        Assert.True(pacer.Accept(5000));
        Assert.False(pacer.Accept(5008));
        Assert.True(pacer.Accept(5017));
    }

    [Fact]
    public void CaptionTextIsTheSameFromTheLookup()
    {
        var config = new CaptionsConfig
        {
            Segments =
            [
                new CaptionSegment { Id = "a", Text = "one" },
                new CaptionSegment { Id = "b", Text = "gone", IsHidden = true },
                new CaptionSegment { Id = "c", Text = "two" },
                new CaptionSegment { Id = "a", Text = "repeat" }
            ]
        };
        var block = new CaptionBlock { WordIds = ["a", "b", "c", "missing"] };
        Assert.Equal("one two", CaptionLineLayout.DisplayText(block, config));
        Assert.Equal("one two", CaptionLineLayout.DisplayText(block, CaptionLineLayout.WordsById(config)));
    }
}
