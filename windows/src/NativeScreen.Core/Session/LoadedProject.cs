namespace NativeScreen.Core;

public sealed class LoadedProject
{
    public ProjectDocument Document { get; }
    public RecordingMetadata Metadata { get; }
    public IReadOnlyList<CursorSampleEvent> CursorEvents { get; }
    public IReadOnlyList<ClickEvent> ClickEvents { get; }
    public IReadOnlyList<KeyStrokeEvent> KeyEvents { get; }
    public NLETimeMapper TimeMapper { get; }
    public PlaybackTrajectorySolver Trajectory { get; }

    /// <summary>The capture size in points, for cursor tolerances and shake (ADR-87).</summary>
    public MotionPointSize PointSize => MotionPointSize.Of(Metadata.CaptureTarget);
    public bool HasRecordedCamera { get; }

    /// <summary>Recorded in the Camera mode: the main picture is the camera, with no screen, cursor or system audio.</summary>
    public bool IsCameraOnly => Metadata.CaptureTarget.Mode == CaptureTargetMode.Camera;

    public LoadedProject(string packageDirectory)
    {
        var projectPath = Path.Combine(packageDirectory, "project.json");
        var recording = Path.Combine(packageDirectory, "recording");
        Document = ProjectJson.Deserialize<ProjectDocument>(File.ReadAllText(projectPath));
        var metadataPath = Path.Combine(recording, "metadata.json");
        Metadata = File.Exists(metadataPath)
            ? ProjectJson.Deserialize<RecordingMetadata>(File.ReadAllText(metadataPath))
            : new RecordingMetadata { DurationMs = Document.Timeline.Slices.Count == 0 ? 10000 : Document.Timeline.Slices.Max(slice => slice.SourceEndMs) };

        Document.Timeline.Zooms = AutoZoomClusterGenerator.NormalizeNonOverlappingZooms(Document.Timeline.Zooms, Metadata.DurationMs);
        Document.Timeline.MaskTracks.RemoveAll(track => track.Items.Count == 0);
        // Items on an annotation track must not overlap, or dragging one pushes it away. Older live drawings could.
        AnnotationTrack.RepackOverlapping(Document.Timeline.AnnotationTracks);
        // Files stay as recorded; older recordings are moved onto the video clock in memory only (ADR-88).
        var rawCursor = JsonLines.Load<CursorSampleEvent>(Path.Combine(recording, Metadata.Tracks.CursorTelemetry));
        var rawClicks = JsonLines.Load<ClickEvent>(Path.Combine(recording, Metadata.Tracks.ClicksTelemetry));
        var rawKeys = JsonLines.Load<KeyStrokeEvent>(Path.Combine(recording, Metadata.Tracks.KeysTelemetry));
        var legacyOffsetMs = LegacyTelemetryEpoch.OffsetMs(rawCursor, rawClicks, rawKeys, Metadata.DurationMs);
        (CursorEvents, ClickEvents, KeyEvents) = LegacyTelemetryEpoch.Corrected(rawCursor, rawClicks, rawKeys, legacyOffsetMs);
        TimeMapper = new NLETimeMapper(Document.Timeline.Slices);
        Trajectory = new PlaybackTrajectorySolver(Metadata.DurationMs, CursorEvents, ClickEvents, Document, PointSize);
        var webcam = Metadata.Tracks.WebcamVideo;
        // A camera-only recording names its camera movie as the screen and has no camera layer (spec/06 ADR-77).
        HasRecordedCamera = !IsCameraOnly && (webcam is not null || File.Exists(Path.Combine(recording, "webcam.mp4")));

        Document.Captions.MigrateTranscriptToCaptionTracksIfNeeded();
        Document.Captions.RemoveEmptyCaptionTracks();
        var clusters = ShortcutEngine.Detect(Document, KeyEvents);
        if (clusters.Count > 0 && Document.Captions.ShortcutTracks.Count == 0)
        {
            Document.Captions.ShortcutTracks.Add(new ShortcutTrackConfig
            {
                Id = "default-shortcuts-track",
                Name = "Shortcuts",
                Style = Document.Captions.DefaultShortcutStyle
            });
        }
        else if (clusters.Count == 0 && Document.Captions.CustomShortcuts.Count == 0)
        {
            Document.Captions.ShortcutTracks.Clear();
        }
    }

    public StageFrame StageAt(double sourceMs, double canvasWidth, double canvasHeight)
    {
        var crop = Document.Canvas.CropRect01;
        var sourceW = Math.Max(16, Metadata.CaptureTarget.PixelSize.Width * crop.Width);
        var sourceH = Math.Max(16, Metadata.CaptureTarget.PixelSize.Height * crop.Height);
        var zoom = Trajectory.EvaluateAtSource(sourceMs).Camera.Scale;
        return new StageLayoutEngine().Resolve(
            Document,
            sourceMs,
            canvasWidth,
            canvasHeight,
            sourceW,
            sourceH,
            zoom,
            HasRecordedCamera,
            cameraOnly: IsCameraOnly);
    }
}
