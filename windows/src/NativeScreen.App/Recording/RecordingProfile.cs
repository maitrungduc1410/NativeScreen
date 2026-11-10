namespace NativeScreen.App;

/// <summary>
/// A saved recording setup (spec/06 ADR-76): capture mode, camera, microphone, system audio and recording options. Per user,
/// in settings.json, never in projects. A device that is not connected is skipped when applying and ignored when checking
/// which profile matches.
/// </summary>
public sealed class RecordingProfile
{
    public string Id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    public string Name { get; set; } = "";
    /// <summary>`display`, `window`, `area` or `camera`.</summary>
    public string Mode { get; set; } = "display";
    public string? CameraId { get; set; }
    public string? CameraName { get; set; }
    public bool ShowCameraPreview { get; set; } = true;
    public int CameraMaxHeight { get; set; } = 1080;
    public bool CaptureMicrophone { get; set; }
    public string? MicrophoneId { get; set; }
    public string? MicrophoneName { get; set; }
    public bool CaptureSystemAudio { get; set; }
    public bool SystemAudioFromAllApps { get; set; } = true;
    public List<string> SystemAudioApps { get; set; } = [];
    public int CountdownSeconds { get; set; } = 3;
    public bool HighlightRecordedArea { get; set; } = true;
    public bool ShowSpeakerNotes { get; set; }
}
