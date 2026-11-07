using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class SegmentEditsTests
{
    private static ProjectDocument Document()
    {
        var document = new ProjectDocument();
        document.Timeline.Slices = [new ClipSlice { Id = "a", SourceStartMs = 500, SourceEndMs = 4000 }, new ClipSlice { Id = "b", SourceStartMs = 6000, SourceEndMs = 9000 }];
        document.Timeline.Zooms = [new ZoomBlock { Id = "z", SourceStartMs = 1000, SourceEndMs = 3000, Scale = 2 }];
        document.Timeline.MaskTracks =
        [
            new MaskTrack { Id = "t1", Items = [new MaskItem { Id = "m1", SourceStartMs = 0, SourceEndMs = 2000, Keyframes = [new MaskKeyframe { SourceMs = 0 }] }] },
            new MaskTrack { Id = "t2", Items = [new MaskItem { Id = "m2", SourceStartMs = 1000, SourceEndMs = 3000 }] }
        ];
        return document;
    }

    [Fact]
    public void SliceMenuActionsFollowTheMacRules()
    {
        var document = Document();
        SegmentEdits.ResetSliceTrim(document, "a", 10000);
        Assert.Equal(0, document.Timeline.Slices[0].SourceStartMs);
        Assert.Equal(6000, document.Timeline.Slices[0].SourceEndMs);

        document = Document();
        SegmentEdits.MergeSliceWithNext(document, "a");
        Assert.Equal(9000, Assert.Single(document.Timeline.Slices).SourceEndMs);

        SegmentEdits.ResetAllSlices(document, 12000);
        Assert.Equal(12000, Assert.Single(document.Timeline.Slices).SourceEndMs);

        var slice = document.Timeline.Slices[0];
        SegmentEdits.SetSliceSystemAudioVolume(slice, 0);
        Assert.Equal(0, slice.SystemAudioVolume);
        Assert.False(slice.Muted);
        SegmentEdits.SetSliceSystemAudioVolume(slice, 3);
        Assert.Equal(1, slice.SystemAudioVolume);
    }

    [Fact]
    public void SliceVolumesNeverMuteAndClearAnOldMute()
    {
        var slice = new ClipSlice { Id = "a", SourceEndMs = 1000, Muted = true };
        SegmentEdits.SetSliceMicrophoneVolume(slice, 0.2);
        Assert.Equal(0.2, slice.MicrophoneVolume);
        Assert.False(slice.Muted);
        SegmentEdits.SetSliceMicrophoneVolume(slice, -1);
        Assert.Equal(0, slice.MicrophoneVolume);
        SegmentEdits.SetSliceMicrophoneVolume(slice, 5);
        Assert.Equal(1, slice.MicrophoneVolume);

        // System audio at 0 leaves the microphone playing.
        SegmentEdits.SetSliceSystemAudioVolume(slice, 0);
        var audio = new AudioConfig();
        Assert.Equal(0, AudioMix.SystemGain(audio, slice, 1));
        Assert.Equal(1, AudioMix.MicrophoneGain(audio, slice, 1, hiddenByVoiceover: false));
        SegmentEdits.SetSliceMicrophoneVolume(slice, 0.25);
        Assert.Equal(0.25, AudioMix.MicrophoneGain(audio, slice, 1, hiddenByVoiceover: false));
    }

    [Fact]
    public void ASliceWithoutAMicrophoneVolumeReadsAsFull()
    {
        var slice = ProjectJson.Deserialize<ClipSlice>("{\"id\":\"a\",\"sourceEndMs\":1000}");
        Assert.Equal(1, slice.MicrophoneVolume);
        var loud = ProjectJson.Deserialize<ClipSlice>("{\"id\":\"a\",\"microphoneVolume\":7}");
        Assert.Equal(2, loud.MicrophoneVolume);
        Assert.Contains("\"microphoneVolume\"", ProjectJson.Serialize(slice));
    }

    [Fact]
    public void SplittingKeepsBothSidesLongEnough()
    {
        var document = Document();
        Assert.Null(SegmentEdits.SplitZoom(document, "z", 1100));
        var second = SegmentEdits.SplitZoom(document, "z", 2000);
        Assert.NotNull(second);
        Assert.Equal(2, document.Timeline.Zooms.Count);
        Assert.Equal(2000, document.Timeline.Zooms[0].SourceEndMs);
        Assert.Equal(2000, document.Timeline.Zooms[1].SourceStartMs);

        Assert.Null(SegmentEdits.SplitMask(document, "m1", 100));
        Assert.NotNull(SegmentEdits.SplitMask(document, "m1", 1000));
        var halves = document.Timeline.MaskTracks[0].Items;
        Assert.Equal(2, halves.Count);
        Assert.Equal(1000, Assert.Single(halves[1].Keyframes).SourceMs);
    }

    [Fact]
    public void DuplicatingUsesFreeSpaceOrHalvesTheBlock()
    {
        var document = Document();
        Assert.NotNull(SegmentEdits.DuplicateZoom(document, "z", 10000));
        Assert.Equal(3000, document.Timeline.Zooms[1].SourceStartMs);
        Assert.Equal(5000, document.Timeline.Zooms[1].SourceEndMs);

        var tight = Document();
        tight.Timeline.Zooms.Add(new ZoomBlock { Id = "y", SourceStartMs = 3100, SourceEndMs = 4000 });
        Assert.NotNull(SegmentEdits.DuplicateZoom(tight, "z", 10000));
        Assert.Equal(2000, tight.Timeline.Zooms[0].SourceEndMs);
        Assert.Equal(2000, tight.Timeline.Zooms[1].SourceStartMs);
    }

    [Fact]
    public void AMaskMovesToAFreeRowStaysOnABusyOneAndMakesNewRowsAtTheEnds()
    {
        var document = Document();
        SegmentEdits.MoveMaskToTrack(document, "m1", 1);
        Assert.Contains(document.Timeline.MaskTracks[0].Items, item => item.Id == "m1");

        SegmentEdits.MoveMaskToTrack(document, "m1", 5);
        Assert.Equal(3, document.Timeline.MaskTracks.Count);
        Assert.Equal("m1", Assert.Single(document.Timeline.MaskTracks[2].Items).Id);
        Assert.Empty(document.Timeline.MaskTracks[0].Items);

        SegmentEdits.MoveMaskToTrack(document, "m2", -1);
        Assert.Equal("m2", Assert.Single(document.Timeline.MaskTracks[0].Items).Id);
    }

    [Fact]
    public void HidingAShortcutWorksForRecordedAndCustomOnes()
    {
        var document = Document();
        var recorded = new ShortcutCluster { Id = "r", TrackId = "t", FirstKeyDownMsInt = 1000, Modifiers = [], PrimaryKey = "K", Label = "K", KeyCaps = [] };
        SegmentEdits.SetShortcutHidden(document, recorded, true);
        Assert.True(SegmentEdits.IsShortcutHidden(document, recorded));
        SegmentEdits.SetShortcutHidden(document, recorded, false);
        Assert.False(SegmentEdits.IsShortcutHidden(document, recorded));

        document.Captions.CustomShortcuts.Add(new CustomShortcutSegment { Id = "c" });
        var custom = new ShortcutCluster { Id = "c", TrackId = "t", Modifiers = [], PrimaryKey = "K", Label = "K", KeyCaps = [] };
        SegmentEdits.SetShortcutHidden(document, custom, true);
        Assert.True(document.Captions.CustomShortcuts[0].IsHidden);
    }

    [Fact]
    public void MaskTypeChangeKeepsAValidStyle()
    {
        var mask = new MaskItem { Style = MaskStyle.Pixelate };
        SegmentEdits.SetMaskType(mask, MaskType.Spotlight);
        Assert.Equal(MaskStyle.Dim, mask.Style);
        SegmentEdits.SetMaskType(mask, MaskType.Blur);
        Assert.Equal(MaskStyle.Gaussian, mask.Style);
    }
}
