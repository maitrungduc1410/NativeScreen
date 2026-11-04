namespace NativeScreen.Core;

/// <summary>Voiceover recording state and the segment it produces. The microphone itself belongs to the app layer.</summary>
public sealed partial class EditorSession
{
    private const double MinimumRecordedVoiceoverMs = 1200;
    private const double ShortestVoiceoverRoomMs = 400;

    public bool IsRecordingVoiceover { get; private set; }

    public double VoiceoverRecordingStartSourceMs { get; private set; }

    public int VoiceoverRecordingTrackIndex { get; private set; }

    /// <summary>Starts from the playhead, on the first track with nothing after it.</summary>
    public void BeginVoiceoverRecording()
    {
        IsRecordingVoiceover = true;
        VoiceoverRecordingStartSourceMs = SourceAtPlayhead;
        VoiceoverRecordingTrackIndex = VoiceoverTrackLayout.FirstTrackEmptyAfter(Document.Timeline.Voiceovers, SourceAtPlayhead);
        SelectionChanged?.Invoke();
    }

    /// <summary>The red block goes away at once; the segment comes when its file is finished.</summary>
    public void EndVoiceoverRecording()
    {
        IsRecordingVoiceover = false;
        SelectionChanged?.Invoke();
    }

    public VoiceoverSegment AddRecordedVoiceover(string relativePath, double recordedMs)
    {
        var start = Math.Max(0, Math.Min(SourceDurationMs - ShortestVoiceoverRoomMs, VoiceoverRecordingStartSourceMs));
        var segment = new VoiceoverSegment
        {
            Id = NewId(),
            SourceStartMs = start,
            DurationMs = Math.Min(Math.Max(MinimumRecordedVoiceoverMs, recordedMs), Math.Max(ShortestVoiceoverRoomMs, SourceDurationMs - start)),
            RelativePath = relativePath,
            TrackIndex = VoiceoverRecordingTrackIndex
        };
        Mutate(document =>
        {
            VoiceoverTrackLayout.SetTrackHidden(document.Timeline, segment.TrackIndex, false);
            document.Timeline.Voiceovers.Add(segment);
            VoiceoverTrackLayout.Normalize(document.Timeline);
        });
        SelectTab(InspectorTab.Audio);
        return segment;
    }
}
