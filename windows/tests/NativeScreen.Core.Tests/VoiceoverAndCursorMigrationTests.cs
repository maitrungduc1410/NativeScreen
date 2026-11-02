using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class VoiceoverAndCursorMigrationTests
{
    private static VoiceoverSegment Segment(string id, double start, double duration, int track = 0) =>
        new() { Id = id, SourceStartMs = start, DurationMs = duration, TrackIndex = track };

    [Fact]
    public void OverlapsMoveToFreeTracksAndEmptyTracksClose()
    {
        var timeline = new TimelineConfig { Voiceovers = [Segment("b", 500, 1000), Segment("a", 0, 1000), Segment("c", 3000, 500, 7)] };
        VoiceoverTrackLayout.Normalize(timeline);
        Assert.Equal(["a", "b", "c"], timeline.Voiceovers.Select(item => item.Id));
        Assert.Equal([0, 1, 2], timeline.Voiceovers.Select(item => item.TrackIndex));
    }

    [Fact]
    public void TheOldHideFlagHidesEveryTrackOnce()
    {
        var timeline = new TimelineConfig { Voiceovers = [Segment("a", 0, 1000), Segment("b", 500, 1000)], IsVoiceoversTrackHidden = true };
        VoiceoverTrackLayout.Normalize(timeline);
        Assert.False(timeline.IsVoiceoversTrackHidden);
        Assert.Equal([0, 1], timeline.HiddenVoiceoverTracks);
    }

    [Fact]
    public void HiddenTracksFollowWhenTracksCloseUp()
    {
        var timeline = new TimelineConfig { Voiceovers = [Segment("a", 0, 100, 2), Segment("b", 0, 100, 5)], HiddenVoiceoverTracks = [5, 3] };
        VoiceoverTrackLayout.Normalize(timeline);
        Assert.Equal([1], timeline.HiddenVoiceoverTracks);
    }

    [Fact]
    public void MovingToAFullTrackLeavesTheSegmentAndPastTheEndMakesATrack()
    {
        var timeline = new TimelineConfig { Voiceovers = [Segment("a", 0, 1000), Segment("b", 500, 1000, 1)] };
        VoiceoverTrackLayout.MoveToTrack(timeline, "b", 0);
        Assert.Equal(1, timeline.Voiceovers.Find(item => item.Id == "b")!.TrackIndex);
        VoiceoverTrackLayout.MoveToTrack(timeline, "b", 9);
        Assert.Equal(1, timeline.Voiceovers.Find(item => item.Id == "b")!.TrackIndex);
        timeline.Voiceovers.Add(Segment("c", 5000, 100));
        VoiceoverTrackLayout.MoveToTrack(timeline, "c", 1);
        Assert.Equal(1, timeline.Voiceovers.Find(item => item.Id == "c")!.TrackIndex);
    }

    [Theory]
    [InlineData("""{"themeId":"arrow","variantId":"pointer-2"}""", "classic-light")]
    [InlineData("""{"themeId":"arrow","variantId":"pointer-1"}""", "classic-dark")]
    [InlineData("""{"themeId":"arrow"}""", "classic-dark")]
    [InlineData("{}", "classic-dark")]
    public void ArrowProjectsMigrate(string json, string theme)
    {
        var cursor = ProjectJson.Deserialize<CursorConfig>(json);
        Assert.Equal(theme, cursor.ThemeId);
        Assert.Null(cursor.VariantId);
    }

    [Fact]
    public void OtherThemesKeepTheirVariant()
    {
        var cursor = ProjectJson.Deserialize<CursorConfig>("""{"themeId":"rounded","variantId":"pointer-3"}""");
        Assert.Equal("rounded", cursor.ThemeId);
        Assert.Equal("pointer-3", cursor.VariantId);
    }

    [Theory]
    [InlineData("dart-color", "dart-color")]
    [InlineData("touch-2", "touch")]
    [InlineData("arrow", "classic-dark")]
    [InlineData("nope", "classic-dark")]
    [InlineData(null, "classic-dark")]
    public void ThemeIdsNormalize(string? id, string expected) => Assert.Equal(expected, CursorSpriteName.NormalizeThemeId(id));
}
