namespace NativeScreen.Core;

/// <summary>Edits of timeline segments, with the same limits as ProjectSession on macOS.</summary>
public static class TimelineEdits
{
    private const double MinimumSliceMs = 200;
    private const double MinimumLayoutGapMs = 400;
    private const double DefaultLayoutMs = 3500;
    private const double MinimumShortcutGapMs = 300;
    private const double DefaultShortcutMs = 1600;
    private const double ShortcutAfterMs = 1500;
    private const double KeyframeMergeMs = 120;
    private const string DefaultShortcutTrack = "default-shortcuts-track";

    private static readonly ShortcutDockPosition[] TrackPositions = [ShortcutDockPosition.Bottom, ShortcutDockPosition.Top, ShortcutDockPosition.Left, ShortcutDockPosition.Right];

    public static void SetSliceRange(ProjectDocument document, string id, double startMs, double endMs, double maxDurationMs)
    {
        var start = Math.Max(0, Math.Min(maxDurationMs - MinimumSliceMs, startMs));
        var end = Math.Max(start + MinimumSliceMs, Math.Min(maxDurationMs, endMs));
        if (document.Timeline.Slices.Find(slice => slice.Id == id) is { } slice)
        {
            slice.SourceStartMs = start;
            slice.SourceEndMs = end;
        }
    }

    /// <summary>How far a slice's edges may go without running into its neighbours in the source.</summary>
    public static (double Low, double High) SliceBounds(ProjectDocument document, string id, double maxDurationMs)
    {
        var slices = document.Timeline.Slices;
        var current = slices.First(slice => slice.Id == id);
        var low = slices.Where(slice => slice.Id != id && slice.SourceEndMs <= current.SourceStartMs + 0.5).Select(slice => slice.SourceEndMs).DefaultIfEmpty(0).Max();
        var high = slices.Where(slice => slice.Id != id && slice.SourceStartMs >= current.SourceEndMs - 0.5).Select(slice => slice.SourceStartMs).DefaultIfEmpty(maxDurationMs).Min();
        return (low, high);
    }

    /// <summary>One keyframe moves the whole mask. With several, the one near this time changes or a new one is added.</summary>
    public static void SetMaskRect(MaskItem mask, Rect01 rect, double sourceMs)
    {
        var clamped = rect.Clamped();
        if (mask.Keyframes.Count == 0)
        {
            mask.Keyframes = [new MaskKeyframe { SourceMs = mask.SourceStartMs, Rect01 = clamped }];
        }
        else if (mask.Keyframes.Count == 1)
        {
            mask.Keyframes[0].Rect01 = clamped;
        }
        else if (mask.Keyframes.Find(frame => Math.Abs(frame.SourceMs - sourceMs) < KeyframeMergeMs) is { } near)
        {
            near.Rect01 = clamped;
        }
        else
        {
            mask.Keyframes.Add(new MaskKeyframe { SourceMs = sourceMs, Rect01 = clamped });
            mask.Keyframes.Sort((a, b) => a.SourceMs.CompareTo(b.SourceMs));
        }
    }

    /// <summary>Changes the layout under this time, or adds one in the free space. Returns its id, or null when there is no room.</summary>
    /// <summary>Adds a layout over exactly a range the timeline already checked is free.</summary>
    public static string AddCameraLayoutInRange(ProjectDocument document, double startMs, double endMs, CameraTimelineLayoutType type)
    {
        var segment = new CameraLayoutSegment
        {
            Id = EditorSession.NewId(),
            SourceStartMs = startMs,
            SourceEndMs = endMs,
            LayoutType = type,
            OverlayPosition01 = document.Camera.Position01,
            CutoutPositionX01 = document.Camera.CutoutPositionX01
        };
        document.Timeline.IsCameraLayoutsTrackHidden = false;
        document.Timeline.CameraLayouts.Add(segment);
        document.Timeline.CameraLayouts.Sort((a, b) => a.SourceStartMs.CompareTo(b.SourceStartMs));
        return segment.Id;
    }

    public static string? AddCameraLayout(ProjectDocument document, double sourceMs, double maxDurationMs, CameraTimelineLayoutType type)
    {
        var layouts = document.Timeline.CameraLayouts;
        if (layouts.Find(item => sourceMs >= item.SourceStartMs && sourceMs <= item.SourceEndMs) is { } containing)
        {
            containing.LayoutType = type;
            return containing.Id;
        }

        var low = layouts.Where(item => item.SourceEndMs <= sourceMs).Select(item => item.SourceEndMs).DefaultIfEmpty(0).Max();
        var high = layouts.Where(item => item.SourceStartMs >= sourceMs).Select(item => item.SourceStartMs).DefaultIfEmpty(maxDurationMs).Min();
        if (high - low < MinimumLayoutGapMs)
        {
            return null;
        }

        var length = Math.Min(DefaultLayoutMs, high - low);
        var start = Math.Max(low, Math.Min(high - length, sourceMs));
        var segment = new CameraLayoutSegment
        {
            Id = EditorSession.NewId(),
            SourceStartMs = start,
            SourceEndMs = Math.Min(high, start + length),
            LayoutType = type,
            OverlayPosition01 = document.Camera.Position01,
            CutoutPositionX01 = document.Camera.CutoutPositionX01
        };
        document.Timeline.IsCameraLayoutsTrackHidden = false;
        layouts.Add(segment);
        layouts.Sort((a, b) => a.SourceStartMs.CompareTo(b.SourceStartMs));
        return segment.Id;
    }

    /// <summary>The style a track draws with. A document without tracks only has its default.</summary>
    public static ShortcutStyleConfig ShortcutTrackStyle(ProjectDocument document, string? trackId)
    {
        var tracks = document.Captions.ShortcutTracks;
        return (tracks.Find(track => track.Id == trackId) ?? tracks.FirstOrDefault())?.Style ?? document.Captions.DefaultShortcutStyle;
    }

    /// <summary>The style a shortcut draws with, in the compositor's order. Editing it edits only what wins.</summary>
    public static ShortcutStyleConfig EffectiveShortcutStyle(ProjectDocument document, ShortcutCluster cluster)
    {
        var captions = document.Captions;
        return captions.ShortcutStyleOverrides.GetValueOrDefault(cluster.Id)
            ?? captions.CustomShortcuts.Find(item => item.Id == cluster.Id)?.CustomStyle
            ?? ShortcutTrackStyle(document, cluster.TrackId);
    }

    /// <summary>The first track's style is also the document default, so an edit of it has to reach both.</summary>
    public static ShortcutStyleConfig LinkDefaultShortcutStyle(ProjectDocument document, ShortcutStyleConfig style)
    {
        if (ReferenceEquals(document.Captions.ShortcutTracks.FirstOrDefault()?.Style, style))
        {
            document.Captions.DefaultShortcutStyle = style;
        }

        return style;
    }

    public static string AddShortcutTrack(ProjectDocument document)
    {
        var index = document.Captions.ShortcutTracks.Count + 1;
        var track = new ShortcutTrackConfig
        {
            Id = EditorSession.NewId(),
            Name = index == 1 ? "Shortcuts" : $"Shortcuts {index}",
            Style = new ShortcutStyleConfig { DockPosition = TrackPositions[(index - 1) % TrackPositions.Length] }
        };
        document.Captions.ShowKeystrokes = true;
        document.Captions.ShortcutTracks.Add(track);
        return track.Id;
    }

    /// <summary>Adds a shortcut in the free space around a time. Returns its id, or null when the track is full there.</summary>
    public static string? AddCustomShortcut(ProjectDocument document, IReadOnlyList<ShortcutCluster> clusters, string? trackId, double anchorMs, double maxDurationMs, double? endMs = null)
    {
        var track = trackId ?? document.Captions.ShortcutTracks.FirstOrDefault()?.Id ?? DefaultShortcutTrack;
        var existing = clusters.Where(item => item.TrackId == track).OrderBy(item => item.DisplayStartMs).ToList();
        var earliest = document.Timeline.Slices.Select(slice => slice.SourceStartMs).DefaultIfEmpty(0).Min();
        var latest = document.Timeline.Slices.Select(slice => slice.SourceEndMs).DefaultIfEmpty(maxDurationMs).Max();
        var previous = existing.LastOrDefault(item => item.DisplayEndMs <= anchorMs + 1)?.DisplayEndMs ?? earliest;
        var next = existing.FirstOrDefault(item => item.DisplayStartMs >= anchorMs - 1 && item.DisplayEndMs > anchorMs + 1)?.DisplayStartMs ?? latest;
        double start;
        double end;
        if (next - previous >= MinimumShortcutGapMs)
        {
            var length = Math.Min(endMs is { } wanted ? Math.Max(MinimumShortcutGapMs, wanted - anchorMs) : DefaultShortcutMs, next - previous);
            start = Math.Max(previous, Math.Min(next - length, anchorMs));
            end = Math.Min(next, start + length);
        }
        else
        {
            var index = existing.FindIndex(item => anchorMs >= item.DisplayStartMs && anchorMs <= item.DisplayEndMs);
            if (index < 0)
            {
                return null;
            }

            start = existing[index].DisplayEndMs;
            var gapEnd = index + 1 < existing.Count ? existing[index + 1].DisplayStartMs : latest;
            if (gapEnd - start < MinimumShortcutGapMs)
            {
                return null;
            }

            end = Math.Min(gapEnd, start + ShortcutAfterMs);
        }

        var segment = new CustomShortcutSegment { Id = EditorSession.NewId(), TrackId = track, SourceStartMs = start, SourceEndMs = end };
        if (document.Captions.ShortcutTracks.Count == 0)
        {
            document.Captions.ShortcutTracks.Add(new ShortcutTrackConfig { Id = track, Name = "Shortcuts", Style = document.Captions.DefaultShortcutStyle });
        }

        document.Captions.ShowKeystrokes = true;
        document.Captions.CustomShortcuts.Add(segment);
        return segment.Id;
    }

    public static void SetShortcutRange(ProjectDocument document, ShortcutCluster cluster, double startMs, double endMs)
    {
        if (document.Captions.CustomShortcuts.Find(item => item.Id == cluster.Id) is { } custom)
        {
            custom.SourceStartMs = startMs;
            custom.SourceEndMs = endMs;
        }
        else
        {
            document.Captions.ShortcutTimingOverrides[cluster.FirstKeyDownMsInt] = new Point01(startMs, endMs);
        }
    }

    public static void SetShortcutKeys(ProjectDocument document, ShortcutCluster cluster, List<string> modifiers, string key)
    {
        if (document.Captions.CustomShortcuts.Find(item => item.Id == cluster.Id) is { } custom)
        {
            custom.Modifiers = modifiers;
            custom.PrimaryKey = key;
        }
        else
        {
            document.Captions.ShortcutKeyOverrides[cluster.FirstKeyDownMsInt] = new CustomShortcutSegment
            {
                Id = cluster.Id,
                TrackId = cluster.TrackId,
                SourceStartMs = cluster.DisplayStartMs,
                SourceEndMs = cluster.DisplayEndMs,
                Modifiers = modifiers,
                PrimaryKey = key
            };
        }
    }

    /// <summary>A recorded shortcut is remembered as deleted, since telemetry never changes. An empty track goes with its last shortcut.</summary>
    public static void DeleteShortcut(ProjectDocument document, ShortcutCluster cluster, IReadOnlyList<ShortcutCluster> clusters)
    {
        var captions = document.Captions;
        var isLast = !clusters.Any(item => item.TrackId == cluster.TrackId && item.Id != cluster.Id);
        if (captions.CustomShortcuts.RemoveAll(item => item.Id == cluster.Id) == 0)
        {
            if (!captions.DeletedShortcutStartMs.Contains(cluster.FirstKeyDownMsInt))
            {
                captions.DeletedShortcutStartMs.Add(cluster.FirstKeyDownMsInt);
            }

            captions.HiddenShortcutStartMs.Remove(cluster.FirstKeyDownMsInt);
            captions.ShortcutTimingOverrides.Remove(cluster.FirstKeyDownMsInt);
            captions.ShortcutKeyOverrides.Remove(cluster.FirstKeyDownMsInt);
        }

        captions.ShortcutStyleOverrides.Remove(cluster.Id);
        if (isLast)
        {
            var isPrimary = cluster.TrackId == captions.ShortcutTracks.FirstOrDefault()?.Id || cluster.TrackId == DefaultShortcutTrack;
            if (isPrimary && captions.ShortcutTracks.Count > 0)
            {
                captions.ShortcutTracks.RemoveAt(0);
            }
            else
            {
                captions.ShortcutTracks.RemoveAll(track => track.Id == cluster.TrackId);
            }

            for (var index = 0; index < captions.ShortcutTracks.Count; index++)
            {
                captions.ShortcutTracks[index].Name = index == 0 ? "Shortcuts" : $"Shortcuts {index + 1}";
            }
        }
    }
}

/// <summary>Maps between the source frame and the preview canvas under the virtual camera. Port of CanvasCoordinateTransform.swift, with the stage's own screen rect.</summary>
public sealed class CanvasCoordinateTransform(double canvasWidth, double canvasHeight, PixelRect screen, Point01 cameraCenter01, double cameraScale)
{
    private readonly double scale = Math.Max(1, cameraScale);

    private double FocusX => screen.X + cameraCenter01.X * screen.Width;

    private double FocusY => screen.Y + cameraCenter01.Y * screen.Height;

    public (double X, double Y) ToCanvas(double x01, double y01)
    {
        var x = screen.X + x01 * screen.Width;
        var y = screen.Y + y01 * screen.Height;
        return scale <= 1.001
            ? (x, y)
            : (canvasWidth * 0.5 + (x - FocusX) * scale, canvasHeight * 0.5 + (y - FocusY) * scale);
    }

    public (double X, double Y, double Width, double Height) ToCanvas(Rect01 rect)
    {
        var (left, top) = ToCanvas(rect.X, rect.Y);
        var (right, bottom) = ToCanvas(rect.X + rect.Width, rect.Y + rect.Height);
        return (left, top, right - left, bottom - top);
    }

    public (double X, double Y) ToSource(double canvasX, double canvasY)
    {
        var x = scale > 1.001 ? FocusX + (canvasX - canvasWidth * 0.5) / scale : canvasX;
        var y = scale > 1.001 ? FocusY + (canvasY - canvasHeight * 0.5) / scale : canvasY;
        return ((x - screen.X) / Math.Max(1, screen.Width), (y - screen.Y) / Math.Max(1, screen.Height));
    }

    public (double X, double Y) DeltaToSource(double deltaX, double deltaY) =>
        (deltaX / Math.Max(1, screen.Width * scale), deltaY / Math.Max(1, screen.Height * scale));
}
