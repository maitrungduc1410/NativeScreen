using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class EditorSessionTests
{
    [Fact]
    public void EditorScrubUndoAndCommandSearchStayOnTheSession()
    {
        var time = 0.0;
        var session = new EditorSession(clock: new PlaybackClock(() => time), durationMs: 1000);
        session.Scrub(250);
        Assert.Equal(250, session.PlayheadTimelineMs);
        session.TogglePlayback();
        time = 100;
        session.SamplePlayhead();
        Assert.Equal(350, session.PlayheadTimelineMs, 6);
        session.TogglePlayback();
        Assert.False(session.IsPlaying);
        Assert.True(PreviewScheduler.BlocksIdle(session.IsPlaying, false));

        session.Rename("Cut");
        session.History.Undo();
        Assert.Equal("Untitled Recording", session.Document.Name);
        session.SelectTab(InspectorTab.Zoom);
        Assert.Equal("Animations", InspectorCatalog.Title(session.SelectedTab));
        Assert.Equal("Ctrl+9", InspectorCatalog.Accelerator(InspectorTab.Zoom));
        session.OpenCommandMenu();
        session.SetCommandQuery("und");
        Assert.Equal("undo", EditorCommands.Search(session.CommandQuery)[0].Id);
    }
}
