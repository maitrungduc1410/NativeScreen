namespace NativeScreen.Core;

/// <summary>The in-memory demo project behind Create Interactive Showcase Project.</summary>
public static class ShowcaseProject
{
    public const double DurationMs = 18000;
    public const double SourceWidth = 2560;
    public const double SourceHeight = 1600;

    public static ProjectDocument Create()
    {
        (double T, double X, double Y)[] samples = [(2200, 0.72, 0.34), (8400, 0.28, 0.66), (13800, 0.64, 0.42)];
        var clicks = new List<ClickEvent>();
        foreach (var (t, x, y) in samples)
        {
            clicks.Add(new ClickEvent { T = t, Type = "down", Button = "left", X = x, Y = y, Count = 1 });
            clicks.Add(new ClickEvent { T = t + 90, Type = "up", Button = "left", X = x, Y = y, Count = 1 });
        }

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
