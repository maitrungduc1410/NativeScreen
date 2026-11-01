namespace NativeScreen.Core;

/// <summary>The in-memory demo project behind Create Interactive Showcase Project.</summary>
public static class ShowcaseProject
{
    public const double DurationMs = 18000;
    public const double SourceWidth = 2560;
    public const double SourceHeight = 1600;

    /// <summary>Writes a demo package with the same synthetic telemetry as the macOS sample and returns its path.</summary>
    public static string WritePackage(string projectsDirectory)
    {
        var document = Create();
        var package = ProjectStore.UniquePackagePath(projectsDirectory, document.Name);
        var telemetry = Path.Combine(package, "recording", "telemetry");
        Directory.CreateDirectory(telemetry);
        var cursor = new List<CursorSampleEvent>();
        for (var i = 0; i <= (int)(DurationMs / 16.67); i++)
        {
            var t = i * 16.67;
            var phase = t / DurationMs * (Math.PI * 4);
            cursor.Add(new CursorSampleEvent { T = t, X = 0.5 + 0.30 * Math.Sin(phase), Y = 0.5 + 0.24 * Math.Sin(phase * 2) });
        }

        ProjectStore.WriteLines(Path.Combine(telemetry, "cursor.jsonl"), cursor);
        ProjectStore.WriteLines(Path.Combine(telemetry, "clicks.jsonl"), Clicks());
        var keys = new List<KeyStrokeEvent>
        {
            new() { T = 4800, Kind = "shortcut", Modifiers = ["Alt", "Ctrl"], Key = "Space", Label = "Alt Ctrl Space" },
            new() { T = 6400, Kind = "typing", Key = "D", Label = "D" },
            new() { T = 7800, Kind = "shortcut", Modifiers = ["Ctrl"], Key = "A", Label = "Ctrl A" },
            new() { T = 9100, Kind = "shortcut", Key = "Delete", Label = "Delete" }
        };
        var typed = "ADDSFDASFSDFGIT";
        for (var i = 0; i < typed.Length; i++)
        {
            keys.Add(new KeyStrokeEvent { T = 9900 + i * 165.0, Kind = "typing", Key = typed[i].ToString(), Label = typed[i].ToString() });
        }

        keys.Add(new KeyStrokeEvent { T = 14400, Kind = "shortcut", Modifiers = ["Ctrl"], Key = "ArrowRight", Label = "Ctrl Right" });
        ProjectStore.WriteLines(Path.Combine(telemetry, "keys.jsonl"), keys);

        var metadata = new RecordingMetadata
        {
            Platform = "windows",
            CreatedAt = DateTimeOffset.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture),
            DurationMs = DurationMs,
            CaptureTarget = new CaptureTargetMetadata
            {
                Mode = CaptureTargetMode.Window,
                DisplayId = 1,
                AppName = "Interactive Demo",
                WindowTitle = "Native Screen 120Hz Engine Preview",
                LogicalBounds = new LogicalBounds { X = 100, Y = 80, Width = 1280, Height = 800 },
                PixelSize = new PixelDimensions { Width = (int)SourceWidth, Height = (int)SourceHeight }
            },
            Tracks = new RecordingTracksMetadata { WebcamVideo = "webcam.mp4", MicrophoneAudio = "microphone.m4a", SystemAudio = "display.mp4" }
        };
        File.WriteAllText(Path.Combine(package, "recording", "metadata.json"), ProjectJson.Serialize(metadata));
        ProjectStore.WriteProjectJson(package, ProjectStore.Serialize(document, DateTimeOffset.UtcNow));
        return package;
    }

    private static List<ClickEvent> Clicks()
    {
        (double T, double X, double Y)[] samples = [(2200, 0.72, 0.34), (8400, 0.28, 0.66), (13800, 0.64, 0.42)];
        var clicks = new List<ClickEvent>();
        foreach (var (t, x, y) in samples)
        {
            clicks.Add(new ClickEvent { T = t, Type = "down", Button = "left", X = x, Y = y, Count = 1 });
            clicks.Add(new ClickEvent { T = t + 90, Type = "up", Button = "left", X = x, Y = y, Count = 1 });
        }

        return clicks;
    }

    public static ProjectDocument Create()
    {
        var clicks = Clicks();
        var document = new ProjectDocument { Id = EditorSession.NewId(), Name = $"Demo Showcase {DateTime.Now:HH-mm-ss}" };
        document.Timeline.Slices.Add(new ClipSlice { Id = EditorSession.NewId(), SourceStartMs = 0, SourceEndMs = DurationMs });
        document.Timeline.Zooms = AutoZoomClusterGenerator.GenerateZooms(clicks, [], DurationMs);
        document.Timeline.MaskTracks =
        [
            new MaskTrack { Id = "mask-track-1", Name = "Mask Track 1", Items = [Mask(1500, 11000, MaskStyle.Gaussian, 36, new Rect01(0.08, 0.16, 0.36, 0.14))] },
            new MaskTrack { Id = "mask-track-2", Name = "Mask Track 2", Items = [Mask(4000, 15000, MaskStyle.Pixelate, 28, new Rect01(0.54, 0.62, 0.34, 0.16))] }
        ];
        return document;
    }

    private static MaskItem Mask(double start, double end, MaskStyle style, double intensity, Rect01 rect) => new()
    {
        Id = EditorSession.NewId(),
        SourceStartMs = start,
        SourceEndMs = end,
        Style = style,
        Intensity = intensity,
        Keyframes = [new MaskKeyframe { SourceMs = start, Rect01 = rect }]
    };
}
