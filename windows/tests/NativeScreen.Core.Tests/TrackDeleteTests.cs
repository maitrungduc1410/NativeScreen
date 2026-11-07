using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class TrackDeleteTests
{
    private static EditorSession Session(ProjectDocument document, IReadOnlyList<KeyStrokeEvent>? keys = null)
    {
        document.Timeline.Slices = [new ClipSlice { Id = "s", SourceStartMs = 0, SourceEndMs = 20000 }];
        return new EditorSession(document, 20000) { KeyEvents = keys ?? [] };
    }

    [Fact]
    public void DeletingAMaskTrackRemovesItsItemsAndRenamesTheRest()
    {
        var document = new ProjectDocument();
        document.Timeline.MaskTracks =
        [
            new MaskTrack { Id = "a", Name = "Masks", Items = [new MaskItem { Id = "m1", SourceStartMs = 0, SourceEndMs = 1000 }] },
            new MaskTrack { Id = "b", Name = "Masks 2", Items = [new MaskItem { Id = "m2", SourceStartMs = 0, SourceEndMs = 1000 }] }
        ];
        var session = Session(document);
        Assert.True(session.DeleteTimelineTrack(new DeletableTimelineTrack(DeletableTrackKind.Mask, "a")));
        var left = Assert.Single(session.Document.Timeline.MaskTracks);
        Assert.Equal("b", left.Id);
        Assert.Equal("Masks", left.Name);

        session.Undo();
        Assert.Equal(2, session.Document.Timeline.MaskTracks.Count);
    }

    [Fact]
    public void DeletingLayoutsClearsEverySegment()
    {
        var document = new ProjectDocument();
        document.Timeline.CameraLayouts = [new CameraLayoutSegment { Id = "l1", SourceStartMs = 0, SourceEndMs = 1000 }];
        document.Timeline.IsCameraLayoutsTrackHidden = true;
        var session = Session(document);
        session.DeleteTimelineTrack(new DeletableTimelineTrack(DeletableTrackKind.CameraLayouts));
        Assert.Empty(session.Document.Timeline.CameraLayouts);
        Assert.False(session.Document.Timeline.IsCameraLayoutsTrackHidden);
    }

    [Fact]
    public void DeletingAVoiceoverTrackRenumbersTheOnesAfterItAndKeepsTheirHiddenState()
    {
        var document = new ProjectDocument();
        document.Timeline.Voiceovers =
        [
            new VoiceoverSegment { Id = "v0", SourceStartMs = 0, DurationMs = 1000, TrackIndex = 0 },
            new VoiceoverSegment { Id = "v1", SourceStartMs = 0, DurationMs = 1000, TrackIndex = 1 },
            new VoiceoverSegment { Id = "v2", SourceStartMs = 0, DurationMs = 1000, TrackIndex = 2 }
        ];
        document.Timeline.HiddenVoiceoverTracks = [2];
        var session = Session(document);
        session.DeleteTimelineTrack(new DeletableTimelineTrack(DeletableTrackKind.Voiceover, Index: 1));
        var voiceovers = session.Document.Timeline.Voiceovers;
        Assert.Equal(["v0", "v2"], voiceovers.Select(item => item.Id));
        Assert.Equal(1, voiceovers.Single(item => item.Id == "v2").TrackIndex);
        Assert.Equal([1], session.Document.Timeline.HiddenVoiceoverTracks);
    }

    [Fact]
    public void DeletingTheFirstShortcutTrackHidesItsRecordedKeystrokes()
    {
        var document = new ProjectDocument();
        document.Captions.ShortcutTracks =
        [
            new ShortcutTrackConfig { Id = "default-shortcuts-track", Name = "Shortcuts" },
            new ShortcutTrackConfig { Id = "second", Name = "Shortcuts 2" }
        ];
        document.Captions.CustomShortcuts = [new CustomShortcutSegment { Id = "c1", TrackId = "default-shortcuts-track", SourceStartMs = 5000, SourceEndMs = 6000 }];
        KeyStrokeEvent[] keys = [new KeyStrokeEvent { T = 1000, Kind = "down", Key = "K", Modifiers = ["Control"] }];
        var session = Session(document, keys);
        var recorded = session.Shortcuts().Where(item => item.Id.StartsWith("telemetry_", StringComparison.Ordinal)).ToList();
        Assert.NotEmpty(recorded);

        session.DeleteTimelineTrack(new DeletableTimelineTrack(DeletableTrackKind.Shortcut, "default-shortcuts-track"));
        var captions = session.Document.Captions;
        var left = Assert.Single(captions.ShortcutTracks);
        Assert.Equal("second", left.Id);
        Assert.Equal("Shortcuts", left.Name);
        Assert.Empty(captions.CustomShortcuts);
        Assert.All(recorded, cluster => Assert.Contains(cluster.FirstKeyDownMsInt, captions.HiddenShortcutStartMs));
    }

    [Fact]
    public void DeletingAnotherShortcutTrackLeavesRecordedKeystrokesAlone()
    {
        var document = new ProjectDocument();
        document.Captions.ShortcutTracks =
        [
            new ShortcutTrackConfig { Id = "default-shortcuts-track", Name = "Shortcuts" },
            new ShortcutTrackConfig { Id = "second", Name = "Shortcuts 2" }
        ];
        KeyStrokeEvent[] keys = [new KeyStrokeEvent { T = 1000, Kind = "down", Key = "K", Modifiers = ["Control"] }];
        var session = Session(document, keys);
        session.DeleteTimelineTrack(new DeletableTimelineTrack(DeletableTrackKind.Shortcut, "second"));
        Assert.Empty(session.Document.Captions.HiddenShortcutStartMs);
        Assert.Single(session.Document.Captions.ShortcutTracks);
    }

    [Fact]
    public void DeletingACaptionTrackTakesItsCaptions()
    {
        var document = new ProjectDocument();
        document.Captions.CaptionTracks = [new CaptionTrack { Id = "t1" }, new CaptionTrack { Id = "t2", Name = "Captions 2" }];
        document.Captions.CaptionBlocks =
        [
            new CaptionBlock { Id = "b1", TrackId = "t1", SourceStartMs = 0, SourceEndMs = 1000 },
            new CaptionBlock { Id = "b2", TrackId = "t2", SourceStartMs = 0, SourceEndMs = 1000 }
        ];
        var session = Session(document);
        session.DeleteTimelineTrack(new DeletableTimelineTrack(DeletableTrackKind.Caption, "t1"));
        Assert.Equal(["b2"], session.Document.Captions.CaptionBlocks.Select(item => item.Id));
        Assert.Equal("t2", Assert.Single(session.Document.Captions.CaptionTracks).Id);
    }

    [Fact]
    public void FavoritesKeepAddOrderAndSkipWhatIsMissing()
    {
        var favorites = new List<string>();
        BackgroundFavorites.Toggle(favorites, BackgroundFavorites.WallpaperId("b"));
        BackgroundFavorites.Toggle(favorites, BackgroundFavorites.WallpaperId("gone"));
        BackgroundFavorites.Toggle(favorites, BackgroundFavorites.WallpaperId("a"));
        BackgroundFavorites.Toggle(favorites, BackgroundFavorites.MeshId(MeshPreset.BuiltIn[1].Id));
        WallpaperItem[] available = [new("a", "a.jpg", "a.jpg", true), new("b", "b.jpg", "b.jpg", true)];
        Assert.Equal(["b", "a"], BackgroundFavorites.Wallpapers(favorites, available).Select(item => item.Id));
        Assert.Equal(MeshPreset.BuiltIn[1].Id, Assert.Single(BackgroundFavorites.Meshes(favorites, MeshPreset.BuiltIn)).Id);

        BackgroundFavorites.Toggle(favorites, BackgroundFavorites.WallpaperId("b"));
        Assert.DoesNotContain("wallpaper:b", favorites);
        Assert.Equal("wallpaper:gone", favorites[0]);
    }
}
