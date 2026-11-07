namespace NativeScreen.Core;

/// <summary>What a track label's Delete Track removes. The clip and zoom tracks cannot be deleted (spec/06 ADR-50).</summary>
public enum DeletableTrackKind
{
    CameraLayouts,
    Mask,
    Voiceover,
    Shortcut,
    Caption
}

/// <summary>A track to delete: masks, shortcuts and captions by id, voiceovers by track index.</summary>
public readonly record struct DeletableTimelineTrack(DeletableTrackKind Kind, string? Id = null, int Index = 0);

public sealed partial class EditorSession
{
    /// <summary>Deletes a track and everything on it as one undo step. False when nothing was deleted.</summary>
    public bool DeleteTimelineTrack(DeletableTimelineTrack track)
    {
        switch (track.Kind)
        {
            case DeletableTrackKind.CameraLayouts:
                SelectLayout(null);
                Mutate(document =>
                {
                    document.Timeline.CameraLayouts.Clear();
                    document.Timeline.IsCameraLayoutsTrackHidden = false;
                });
                return true;
            case DeletableTrackKind.Mask when track.Id is { } maskTrackId:
                if (Document.Timeline.MaskTracks.Find(item => item.Id == maskTrackId) is { } maskTrack && maskTrack.Items.Exists(item => item.Id == SelectedMaskId))
                {
                    SelectMask(null);
                }

                // An empty mask track is removed and the rest renamed by the normalization after every edit.
                Mutate(document => document.Timeline.MaskTracks.RemoveAll(item => item.Id == maskTrackId));
                return true;
            case DeletableTrackKind.Voiceover:
                if (IsRecordingVoiceover)
                {
                    return false;
                }

                var index = track.Index;
                Mutate(document =>
                {
                    document.Timeline.Voiceovers.RemoveAll(item => item.TrackIndex == index);
                    document.Timeline.HiddenVoiceoverTracks.RemoveAll(item => item == index);
                    VoiceoverTrackLayout.Normalize(document.Timeline);
                });
                return true;
            case DeletableTrackKind.Shortcut when track.Id is { } shortcutTrackId:
                // Recorded keystrokes always belong to the first track and come back with it when the project reopens, so
                // deleting that track hides them instead.
                var isPrimary = Document.Captions.ShortcutTracks.Count > 0 && Document.Captions.ShortcutTracks[0].Id == shortcutTrackId;
                var onTrack = Shortcuts().Where(item => item.TrackId == shortcutTrackId).ToList();
                var recordedStarts = isPrimary ? onTrack.Where(item => !IsCustomShortcut(item)).Select(item => item.FirstKeyDownMsInt).ToList() : [];
                if (onTrack.Exists(item => item.Id == SelectedShortcutId))
                {
                    SelectShortcut(null);
                }

                Mutate(document =>
                {
                    var captions = document.Captions;
                    foreach (var start in recordedStarts)
                    {
                        if (!captions.HiddenShortcutStartMs.Contains(start))
                        {
                            captions.HiddenShortcutStartMs.Add(start);
                        }
                    }

                    captions.ShortcutTracks.RemoveAll(item => item.Id == shortcutTrackId);
                    captions.CustomShortcuts.RemoveAll(item => item.TrackId == shortcutTrackId);
                    for (var position = 0; position < captions.ShortcutTracks.Count; position++)
                    {
                        captions.ShortcutTracks[position].Name = position == 0 ? "Shortcuts" : $"Shortcuts {position + 1}";
                    }
                });
                return true;
            case DeletableTrackKind.Caption when track.Id is { } captionTrackId:
                DeleteCaptionTrack(captionTrackId);
                return true;
            default:
                return false;
        }
    }

    /// <summary>Recorded keystroke clusters are made from telemetry; everything else on a shortcut track was added by hand.</summary>
    private static bool IsCustomShortcut(ShortcutCluster cluster) => !cluster.Id.StartsWith("telemetry_", StringComparison.Ordinal);
}
