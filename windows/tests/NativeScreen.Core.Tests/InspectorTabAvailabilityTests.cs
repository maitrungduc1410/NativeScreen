using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class InspectorTabAvailabilityTests
{
    private static ProjectDocument Document() => new();

    [Fact]
    public void AnEmptyRecordingDisablesWhatItDoesNotHave()
    {
        var session = new EditorSession(Document(), 1000);
        Assert.Equal((false, "There is no mouse cursor recorded"), session.TabAvailability(InspectorTab.Cursor));
        Assert.Equal((false, "No camera recorded"), session.TabAvailability(InspectorTab.CameraLayout));
        Assert.Equal((false, "No camera recorded"), session.TabAvailability(InspectorTab.CameraStyle));
        Assert.Equal((true, null), session.TabAvailability(InspectorTab.Captions));
        Assert.Equal((false, "No microphone recorded"), session.TabAvailability(InspectorTab.Transcript));
        Assert.Equal((false, "No keyboard shortcuts during recording"), session.TabAvailability(InspectorTab.Shortcuts));
    }

    [Theory]
    [InlineData(InspectorTab.Background)]
    [InlineData(InspectorTab.Audio)]
    [InlineData(InspectorTab.Zoom)]
    [InlineData(InspectorTab.DeviceFrame)]
    [InlineData(InspectorTab.Masks)]
    public void SomeTabsAreAlwaysOpen(InspectorTab tab) =>
        Assert.True(new EditorSession(Document(), 1000).TabAvailability(tab).CanApply);

    [Fact]
    public void HidingTheCameraDisablesOnlyCameraStyle()
    {
        var session = new EditorSession(Document(), 1000) { HasRecordedCamera = true };
        Assert.True(session.TabAvailability(InspectorTab.CameraStyle).CanApply);
        session.Mutate(document => document.Camera.Enabled = false);
        Assert.Equal((false, "Camera is hidden (see Camera Layout)"), session.TabAvailability(InspectorTab.CameraStyle));
        Assert.True(session.TabAvailability(InspectorTab.CameraLayout).CanApply);
    }

    [Fact]
    public void ACaptionOrCustomShortcutIsEnoughWithoutARecordedTrack()
    {
        var document = Document();
        document.Captions.Segments.Add(new CaptionSegment());
        document.Captions.CustomShortcuts.Add(new CustomShortcutSegment());
        var session = new EditorSession(document, 1000);
        Assert.True(session.TabAvailability(InspectorTab.Transcript).CanApply);
        Assert.True(session.TabAvailability(InspectorTab.Shortcuts).CanApply);
    }
}
