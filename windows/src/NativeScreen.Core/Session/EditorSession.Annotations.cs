namespace NativeScreen.Core;

public enum AnnotationLayerMove
{
    Front,
    Forward,
    Backward,
    Back
}

/// <summary>Annotation editing, ported from `ProjectSession+Annotations.swift` (spec/02, spec/06 ADR-75). Same names and rules.</summary>
public sealed partial class EditorSession
{
    private AnnotationItem? copiedAnnotation;
    private bool annotationsTouched;

    /// <summary>Size of the recorded picture, for placing new items in what is visible.</summary>
    public double SourceWidth { get; init; } = 1920;

    public double SourceHeight { get; init; } = 1080;

    public string? SelectedAnnotationId { get; private set; }

    /// <summary>A text item being typed into on the canvas: the preview leaves it out while the field shows it.</summary>
    public string? EditingAnnotationTextId { get; set; }

    public AnnotationItem? SelectedAnnotation => SelectedAnnotationId is { } id ? Annotation(id) : null;

    public AnnotationItem? Annotation(string id) => FindAnnotation(Document, id);

    public bool HasCopiedAnnotation => copiedAnnotation is not null;

    public static AnnotationItem? FindAnnotation(ProjectDocument document, string id)
    {
        foreach (var track in document.Timeline.AnnotationTracks)
        {
            if (track.Items.Find(item => item.Id == id) is { } hit)
            {
                return hit;
            }
        }

        return null;
    }

    public int AnnotationTrackIndex(string id) => Document.Timeline.AnnotationTracks.FindIndex(track => track.Items.Exists(item => item.Id == id));

    public void SelectAnnotation(string? id)
    {
        ClearSelectionState();
        SelectedAnnotationId = id;
        SelectionChanged?.Invoke();
    }

    /// <summary>
    /// The canvas mapping the compositor uses at `sourceMs` for a canvas of the given size (top-down), camera-only framing and
    /// face-centered zoom included. The camera is read at edited time: the occurrence under the playhead when the source range
    /// is reused, else the first one (ADR-86).
    /// </summary>
    public CanvasCoordinateTransform CanvasTransform(double sourceMs, double canvasWidth, double canvasHeight)
    {
        var (document, trajectory) = RenderSnapshot();
        var face = IsCameraOnly ? CameraOnlyLayout.FaceCenter01(document, FaceTrack, sourceMs) : null;
        var timelineMs = trajectory.Mapper.TimelineTime(sourceMs, PlayheadTimelineMs) ?? trajectory.Mapper.TimelineTime(sourceMs) ?? 0;
        var camera = CameraOnlyLayout.FaceCentered(trajectory.EvaluateAtTimeline(timelineMs).Camera, face);
        var crop = document.Canvas.CropRect01;
        // The same source size the compositor and the preview handles use, so a new or re-pinned item lands where it is drawn.
        var stage = new StageLayoutEngine().Resolve(
            document,
            sourceMs,
            canvasWidth,
            canvasHeight,
            Math.Max(16, SourceWidth * crop.Width),
            Math.Max(16, SourceHeight * crop.Height),
            camera.Scale,
            HasRecordedCamera,
            cameraOnly: IsCameraOnly,
            faceTrack: FaceTrack);
        return new CanvasCoordinateTransform(canvasWidth, canvasHeight, stage.ScreenRect, crop, camera.Center01, camera.Scale);
    }

    public double OutputCanvasAspect => Document.Canvas.EffectiveAspectRatio(SourceWidth, SourceHeight);

    private (double Start, double End) AnnotationSourceBounds =>
        Document.Timeline.Slices.Count == 0
            ? (0, Math.Max(500, SourceDurationMs))
            : (Document.Timeline.Slices.Min(slice => slice.SourceStartMs), Document.Timeline.Slices.Max(slice => slice.SourceEndMs));

    /// <summary>Where the pointer went down from `start` to `end`, in recording coordinates.</summary>
    public List<Point01> RecordedClicks(double start, double end) =>
        ClickEvents.Where(click => click.Type == "down" && click.T >= start && click.T <= end).Select(click => new Point01(click.X, click.Y)).ToList();

    // MARK: Adding

    /// <summary>A new item placed in the middle of what is visible at its start, pointing at the first click near it.</summary>
    public AnnotationItem NewAnnotation(AnnotationKind kind, double sourceStartMs, double sourceEndMs)
    {
        const double width = 1000;
        var height = width / Math.Max(0.1, OutputCanvasAspect);
        var transform = CanvasTransform(sourceStartMs, width, height);
        // What is visible of the screen: the canvas, clipped to where the screen lands.
        var (sx, sy) = transform.ToCanvas(Document.Canvas.CropRect01.X, Document.Canvas.CropRect01.Y);
        var (ex, ey) = transform.ToCanvas(Document.Canvas.CropRect01.X + Document.Canvas.CropRect01.Width, Document.Canvas.CropRect01.Y + Document.Canvas.CropRect01.Height);
        var vx = Math.Max(0, sx);
        var vy = Math.Max(0, sy);
        var vw = Math.Max(1, Math.Min(width, ex) - vx);
        var vh = Math.Max(1, Math.Min(height, ey) - vy);
        Point01 Source(double fx, double fy)
        {
            var (x, y) = transform.ToSource(vx + vw * fx, vy + vh * fy);
            return new Point01(Math.Clamp(x, 0, 1), Math.Clamp(y, 0, 1));
        }

        var click = RecordedClicks(sourceStartMs - 300, Math.Min(sourceEndMs, sourceStartMs + 2500)).FirstOrDefault();
        (double X, double Y)? clickCanvas = click is null ? null : transform.ToCanvas(click.X, click.Y);
        Point01? Near(double dx, double dy)
        {
            if (clickCanvas is not { } c)
            {
                return null;
            }

            var (x, y) = transform.ToSource(c.X + dx * vw, c.Y + dy * vh);
            return new Point01(Math.Clamp(x, 0, 1), Math.Clamp(y, 0, 1));
        }

        (double X, double Y) ClickFraction() => clickCanvas is { } c ? ((c.X - vx) / vw, (c.Y - vy) / vh) : (0.5, 0.5);
        var item = new AnnotationItem { SourceStartMs = sourceStartMs, SourceEndMs = sourceEndMs, Kind = kind };
        switch (kind)
        {
            case AnnotationKind.Text:
                item.Text = "Add your text";
                item.Position01 = Near(0, -0.12) ?? Source(0.5, 0.3);
                break;
            case AnnotationKind.Arrow:
                item.From01 = Near(-0.14, 0.14) ?? Source(0.36, 0.64);
                item.To01 = click ?? Source(0.5, 0.5);
                break;
            case AnnotationKind.Image:
                item.Position01 = Source(0.5, 0.5);
                item.MaxWidthRatio = 0.25;
                item.CornerRatio = 0.01;
                break;
            case AnnotationKind.Pen:
            {
                var (cx, cy) = ClickFraction();
                var a = Source(cx - 0.1, cy + 0.04);
                var b = Source(cx + 0.1, cy + 0.08);
                item.Position01 = new Point01((a.X + b.X) * 0.5, (a.Y + b.Y) * 0.5);
                item.StrokeRatio = 0.005;
                item.Size01 = new Size01(AnnotationItem.ClampedSize(Math.Abs(b.X - a.X)), AnnotationItem.ClampedSize(Math.Abs(b.Y - a.Y)));
                item.Points01 = Enumerable.Range(0, 17).Select(i => new Point01(i / 16.0, 0.5 + 0.4 * Math.Sin(i / 16.0 * Math.PI * 4))).ToList();
                item.PointTimesMs = Enumerable.Range(0, 17).Select(i => i * 25.0).ToList();
                item.Enter = AnnotationAnimation.Draw;
                item.AnimationMs = 300;
                break;
            }

            case AnnotationKind.Rectangle:
            case AnnotationKind.Ellipse:
            {
                var (cx, cy) = ClickFraction();
                var a = Source(cx - 0.12, cy - 0.08);
                var b = Source(cx + 0.12, cy + 0.08);
                item.Position01 = new Point01((a.X + b.X) * 0.5, (a.Y + b.Y) * 0.5);
                item.Size01 = new Size01(AnnotationItem.ClampedSize(Math.Abs(b.X - a.X)), AnnotationItem.ClampedSize(Math.Abs(b.Y - a.Y)));
                item.Enter = AnnotationAnimation.Draw;
                item.AnimationMs = 400;
                break;
            }

            case AnnotationKind.Step:
                item.Position01 = Near(-0.045, -0.06) ?? Source(0.5, 0.5);
                item.FontSizeRatio = 0.036;
                item.Enter = AnnotationAnimation.Pop;
                break;
        }

        return item;
    }

    private static bool Overlaps(AnnotationItem a, AnnotationItem b) =>
        !(a.SourceEndMs <= b.SourceStartMs + AnnotationTrack.OverlapToleranceMs || a.SourceStartMs >= b.SourceEndMs - AnnotationTrack.OverlapToleranceMs);

    /// <summary>On the preferred track when free, else the first free track, else a new track at the bottom.</summary>
    public void InsertAnnotation(AnnotationItem item, string? preferredTrackId = null)
    {
        MutateAnnotations(document =>
        {
            var tracks = document.Timeline.AnnotationTracks;
            bool IsFree(AnnotationTrack track) => !track.Items.Exists(other => Overlaps(item, other));
            var index = preferredTrackId is not null ? tracks.FindIndex(track => track.Id == preferredTrackId && IsFree(track)) : -1;
            if (index < 0)
            {
                index = tracks.FindIndex(IsFree);
            }

            if (index >= 0)
            {
                tracks[index].IsHidden = false;
                tracks[index].Items.Add(item);
                tracks[index].Items.Sort((a, b) => a.SourceStartMs.CompareTo(b.SourceStartMs));
            }
            else
            {
                tracks.Add(new AnnotationTrack { Name = AnnotationTrack.DefaultName(tracks.Count), Items = [item] });
            }
        });
        SelectAnnotation(item.Id);
    }

    public void AddAnnotationAtPlayhead(AnnotationKind kind)
    {
        if (PlayheadRange() is { } range)
        {
            InsertAnnotation(NewAnnotation(kind, range.Start, range.End));
        }
    }

    /// <summary>Three seconds from the playhead, at least one, inside the recording.</summary>
    private (double Start, double End)? PlayheadRange()
    {
        var bounds = AnnotationSourceBounds;
        var at = SourceAtPlayhead;
        var end = Math.Min(bounds.End, at + 3000);
        var start = Math.Max(bounds.Start, Math.Min(at, end - 1000));
        return end - start >= AnnotationItem.MinDurationMs ? (start, end) : null;
    }

    public void AddAnnotationInTimeRange(AnnotationKind kind, double start, double end) => InsertAnnotation(NewAnnotation(kind, start, end));

    /// <summary>The `+` on an empty span of a track: copies the kind and look of the item before it.</summary>
    public void AddAnnotationInRange(string trackId, double start, double end)
    {
        if (end - start < AnnotationItem.MinDurationMs)
        {
            return;
        }

        var track = Document.Timeline.AnnotationTracks.Find(item => item.Id == trackId);
        var reference = track?.Items.LastOrDefault(item => item.SourceEndMs <= start + 1) ?? track?.Items.FirstOrDefault();
        var item = NewAnnotation(reference?.Kind ?? AnnotationKind.Text, start, end);
        if (reference is not null)
        {
            var fresh = item;
            item = reference.Copy();
            item.Id = fresh.Id;
            item.SourceStartMs = start;
            item.SourceEndMs = end;
            item.Disabled = false;
            if (reference.Anchor == AnnotationAnchor.Screen)
            {
                item.Position01 = fresh.Position01;
                item.From01 = fresh.From01;
                item.To01 = fresh.To01;
            }
        }

        InsertAnnotation(item, trackId);
    }

    /// <summary>A picture already copied into the package (`assets/annotations/...`), as a new image item at the playhead.</summary>
    public void AddImageAnnotation(string relativePath)
    {
        if (PlayheadRange() is { } range)
        {
            var item = NewAnnotation(AnnotationKind.Image, range.Start, range.End);
            item.ImagePath = relativePath;
            InsertAnnotation(item);
        }
    }

    // MARK: Editing

    private void MutateAnnotations(Action<ProjectDocument> change, string? interactiveKey = null, bool structural = true)
    {
        annotationsTouched = true;
        Mutate(change, interactiveKey, structural);
    }

    public void UpdateAnnotation(string id, Action<AnnotationItem> change, string? interactiveKey = null) =>
        MutateAnnotations(document =>
        {
            if (FindAnnotation(document, id) is { } item)
            {
                change(item);
            }
        }, interactiveKey, structural: interactiveKey is null);

    /// <summary>Changes what the item is pinned to and keeps it where it is on screen at the playhead.</summary>
    public void SetAnnotationAnchor(string id, AnnotationAnchor anchor)
    {
        if (Annotation(id) is not { } item || item.Anchor == anchor)
        {
            return;
        }

        const double width = 1000;
        var height = width / Math.Max(0.1, OutputCanvasAspect);
        var at = Math.Clamp(SourceAtPlayhead, item.SourceStartMs, item.SourceEndMs);
        var transform = CanvasTransform(at, width, height);
        Point01 Convert(Point01 p)
        {
            if (anchor == AnnotationAnchor.Canvas)
            {
                var (x, y) = transform.ToCanvas(p.X, p.Y);
                return new Point01(Math.Clamp(x / width, 0, 1), Math.Clamp(y / height, 0, 1));
            }

            var (sx, sy) = transform.ToSource(p.X * width, p.Y * height);
            return new Point01(Math.Clamp(sx, 0, 1), Math.Clamp(sy, 0, 1));
        }

        AnnotationKeyframe ConvertGeometry(AnnotationKeyframe k)
        {
            // A shape keeps its size on screen: convert two corners, not only the center.
            var a0 = Convert(new Point01(k.Position01.X - k.Size01.Width * 0.5, k.Position01.Y - k.Size01.Height * 0.5));
            var a1 = Convert(new Point01(k.Position01.X + k.Size01.Width * 0.5, k.Position01.Y + k.Size01.Height * 0.5));
            return new AnnotationKeyframe
            {
                SourceMs = k.SourceMs,
                Size01 = new Size01(AnnotationItem.ClampedSize(Math.Abs(a1.X - a0.X)), AnnotationItem.ClampedSize(Math.Abs(a1.Y - a0.Y))),
                Position01 = Convert(k.Position01),
                From01 = Convert(k.From01),
                To01 = Convert(k.To01),
                RotationDegrees = k.RotationDegrees
            };
        }

        UpdateAnnotation(id, a =>
        {
            a.ApplyGeometry(ConvertGeometry(a.KeyframeAt(0)));
            a.Keyframes = a.Keyframes.Select(ConvertGeometry).ToList();
            a.Anchor = anchor;
        });
    }

    private (double Lower, double Upper)? NeighborBounds(ProjectDocument document, string id)
    {
        var bounds = AnnotationSourceBounds;
        var track = document.Timeline.AnnotationTracks.Find(t => t.Items.Exists(item => item.Id == id));
        if (track is null)
        {
            return null;
        }

        var items = track.Items.OrderBy(item => item.SourceStartMs).ToList();
        var index = items.FindIndex(item => item.Id == id);
        var lower = index > 0 ? Math.Max(bounds.Start, items[index - 1].SourceEndMs) : bounds.Start;
        var upper = index + 1 < items.Count ? Math.Min(bounds.End, items[index + 1].SourceStartMs) : bounds.End;
        return (lower, upper);
    }

    /// <summary>Moves an item in time between its neighbors; keyframes move with it.</summary>
    public void MoveAnnotation(string id, double desiredStartMs, double durationMs, string? interactiveKey = null)
    {
        if (NeighborBounds(Document, id) is not { } bounds)
        {
            return;
        }

        var span = Math.Max(AnnotationItem.MinDurationMs, durationMs);
        if (bounds.Upper - bounds.Lower < span)
        {
            return;
        }

        var start = Math.Max(bounds.Lower, Math.Min(bounds.Upper - span, desiredStartMs));
        UpdateAnnotation(id, a =>
        {
            a.ShiftTime(start - a.SourceStartMs);
            a.SourceEndMs = start + span;
        }, interactiveKey);
    }

    /// <summary>Moves one edge; neighbors on the track stop it, edge to edge.</summary>
    public void ResizeAnnotation(string id, double newStartMs, double newEndMs, string? interactiveKey = null)
    {
        if (NeighborBounds(Document, id) is not { } bounds || Annotation(id) is not { } current)
        {
            return;
        }

        var isLeft = Math.Abs(newEndMs - current.SourceEndMs) < 0.5;
        UpdateAnnotation(id, a =>
        {
            if (isLeft)
            {
                a.SourceStartMs = Math.Max(bounds.Lower, Math.Min(a.SourceEndMs - AnnotationItem.MinDurationMs, newStartMs));
            }
            else
            {
                a.SourceEndMs = Math.Max(a.SourceStartMs + AnnotationItem.MinDurationMs, Math.Min(bounds.Upper, newEndMs));
            }
        }, interactiveKey);
    }

    /// <summary>To another track, or a new one above (-1) or below (count) all of them. Stays put when the target is busy.</summary>
    public void MoveAnnotationToTrack(string id, int targetTrackIndex) => MutateAnnotations(document =>
    {
        var tracks = document.Timeline.AnnotationTracks;
        var from = tracks.FindIndex(track => track.Items.Exists(item => item.Id == id));
        if (from < 0 || from == targetTrackIndex)
        {
            return;
        }

        var item = tracks[from].Items.Find(other => other.Id == id)!;
        if (targetTrackIndex < 0 || targetTrackIndex >= tracks.Count)
        {
            tracks[from].Items.Remove(item);
            var track = new AnnotationTrack { Name = "", Items = [item] };
            if (targetTrackIndex < 0)
            {
                tracks.Insert(0, track);
            }
            else
            {
                tracks.Add(track);
            }

            return;
        }

        if (tracks[targetTrackIndex].Items.Exists(other => Overlaps(item, other)))
        {
            return;
        }

        tracks[from].Items.Remove(item);
        tracks[targetTrackIndex].Items.Add(item);
        tracks[targetTrackIndex].Items.Sort((a, b) => a.SourceStartMs.CompareTo(b.SourceStartMs));
    });

    public void SplitAnnotation(string id, double sourceMs)
    {
        if (Annotation(id) is not { } original)
        {
            return;
        }

        if (sourceMs <= original.SourceStartMs + 180 || sourceMs >= original.SourceEndMs - 180)
        {
            ToastRequested?.Invoke(TooShortToCut);
            return;
        }

        var secondId = NewId();
        MutateAnnotations(document =>
        {
            foreach (var track in document.Timeline.AnnotationTracks)
            {
                var index = track.Items.FindIndex(item => item.Id == id);
                if (index < 0)
                {
                    continue;
                }

                var first = original.Copy();
                first.Id = NewId();
                first.SourceEndMs = sourceMs;
                var second = original.Copy();
                second.Id = secondId;
                second.SourceStartMs = sourceMs;
                if (original.Keyframes.Count > 0)
                {
                    // Each half keeps its own keyframes plus one at the cut, so neither jumps.
                    var atCut = original.Resolved(sourceMs).KeyframeAt(sourceMs);
                    first.Keyframes = [.. original.Copy().Keyframes.Where(k => k.SourceMs < sourceMs - 1), atCut];
                    second.Keyframes = [ProjectJson.Clone(atCut), .. original.Copy().Keyframes.Where(k => k.SourceMs > sourceMs + 1)];
                }

                track.Items.RemoveAt(index);
                track.Items.InsertRange(index, [first, second]);
                return;
            }
        });
        SelectAnnotation(secondId);
    }

    public void DeleteAnnotation(string id)
    {
        MutateAnnotations(document =>
        {
            foreach (var track in document.Timeline.AnnotationTracks)
            {
                track.Items.RemoveAll(item => item.Id == id);
            }
        });
        if (SelectedAnnotationId == id)
        {
            SelectAnnotation(null);
        }
    }

    public void ToggleAnnotationDisabled(string id) => UpdateAnnotation(id, a => a.Disabled = !a.Disabled);

    // MARK: Geometry edits and keyframes

    /// <summary>
    /// Changes an item as it is shown at `sourceMs`. Without keyframes that is the item itself; with keyframes the new geometry
    /// goes into the keyframe at that moment (within 120 ms), or a new one.
    /// </summary>
    public void EditAnnotationGeometry(string id, double sourceMs, Action<AnnotationItem> change, string? interactiveKey = null) =>
        UpdateAnnotation(id, item =>
        {
            if (item.Keyframes.Count == 0)
            {
                change(item);
                return;
            }

            var shown = item.Resolved(sourceMs).Copy();
            change(shown);
            var edited = shown.KeyframeAt(sourceMs);
            var keyframes = item.Keyframes;
            var index = keyframes.FindIndex(k => Math.Abs(k.SourceMs - sourceMs) < 120);
            if (index >= 0)
            {
                edited.SourceMs = keyframes[index].SourceMs;
                keyframes[index] = edited;
            }
            else
            {
                keyframes.Add(edited);
                keyframes.Sort((a, b) => a.SourceMs.CompareTo(b.SourceMs));
            }

            var ownGeometry = item.KeyframeAt(0);
            var keep = item.Keyframes;
            CopyFields(shown, item);
            item.ApplyGeometry(ownGeometry);
            item.Keyframes = keep;
        }, interactiveKey);

    // Every field but the identity, so a resolved, edited copy can be written back.
    private static void CopyFields(AnnotationItem from, AnnotationItem to)
    {
        var copy = from.Copy();
        to.Kind = copy.Kind;
        to.Anchor = copy.Anchor;
        to.Text = copy.Text;
        to.FontSizeRatio = copy.FontSizeRatio;
        to.MaxWidthRatio = copy.MaxWidthRatio;
        to.Bold = copy.Bold;
        to.TextBackground = copy.TextBackground;
        to.BackgroundColor = copy.BackgroundColor;
        to.Bend = copy.Bend;
        to.StrokeRatio = copy.StrokeRatio;
        to.FillOpacity = copy.FillOpacity;
        to.CornerRatio = copy.CornerRatio;
        to.ImagePath = copy.ImagePath;
        to.Points01 = copy.Points01;
        to.PointTimesMs = copy.PointTimesMs;
        to.Highlighter = copy.Highlighter;
        to.StrokeStarts = copy.StrokeStarts;
        to.Color = copy.Color;
        to.Enter = copy.Enter;
        to.Exit = copy.Exit;
        to.AnimationMs = copy.AnimationMs;
        to.Disabled = copy.Disabled;
    }

    /// <summary>A keyframe at the playhead holding where the item is now; the first one also pins the start.</summary>
    public void AddAnnotationKeyframe(string id)
    {
        if (Annotation(id) is not { } item)
        {
            return;
        }

        var t = Math.Clamp(SourceAtPlayhead, item.SourceStartMs, item.SourceEndMs);
        UpdateAnnotation(id, a =>
        {
            var here = a.Resolved(t).KeyframeAt(t);
            if (a.Keyframes.Count == 0 && t - a.SourceStartMs > 120)
            {
                a.Keyframes.Add(a.KeyframeAt(a.SourceStartMs));
            }

            a.Keyframes.RemoveAll(k => Math.Abs(k.SourceMs - t) < 120);
            a.Keyframes.Add(here);
            a.Keyframes.Sort((x, y) => x.SourceMs.CompareTo(y.SourceMs));
        });
    }

    public void RemoveAnnotationKeyframe(string id, int index) => UpdateAnnotation(id, a =>
    {
        if (index < 0 || index >= a.Keyframes.Count)
        {
            return;
        }

        // The last keyframe left becomes the item's own geometry.
        if (a.Keyframes.Count == 1)
        {
            a.ApplyGeometry(a.Keyframes[0]);
        }

        a.Keyframes.RemoveAt(index);
    });

    /// <summary>Stops the motion, keeping the item where it is at the playhead.</summary>
    public void ClearAnnotationKeyframes(string id)
    {
        if (Annotation(id) is not { } item)
        {
            return;
        }

        var t = Math.Clamp(SourceAtPlayhead, item.SourceStartMs, item.SourceEndMs);
        UpdateAnnotation(id, a =>
        {
            a.ApplyGeometry(a.Resolved(t).KeyframeAt(t));
            a.Keyframes = [];
        });
    }

    // MARK: Styles

    public void ApplyAnnotationStyle(AnnotationStyle style, string id) => UpdateAnnotation(id, style.ApplyTo);

    public void ApplyAnnotationStyleToAll(AnnotationStyle style) => MutateAnnotations(document =>
    {
        foreach (var item in document.Timeline.AnnotationTracks.SelectMany(track => track.Items))
        {
            style.ApplyTo(item);
        }
    });

    // MARK: Layers

    /// <summary>
    /// Layers are tracks: the first track draws on top. An item moves to the next track up or down when it is free at that
    /// time, and otherwise a new track is made right past it.
    /// </summary>
    public void MoveAnnotationLayer(string id, AnnotationLayerMove move)
    {
        MutateAnnotations(document =>
        {
            var tracks = document.Timeline.AnnotationTracks;
            var from = tracks.FindIndex(track => track.Items.Exists(item => item.Id == id));
            if (from < 0)
            {
                return;
            }

            var item = tracks[from].Items.Find(other => other.Id == id)!;
            var count = tracks.Count;
            bool IsFree(int t) => !tracks[t].Items.Exists(other => other.Id != id && Overlaps(item, other));
            int? target = null;
            var insertAt = 0;
            switch (move)
            {
                case AnnotationLayerMove.Forward:
                    if (from == 0)
                    {
                        return;
                    }

                    if (IsFree(from - 1)) { target = from - 1; } else { insertAt = from - 1; }
                    break;
                case AnnotationLayerMove.Front:
                    if (from == 0)
                    {
                        return;
                    }

                    if (IsFree(0)) { target = 0; } else { insertAt = 0; }
                    break;
                case AnnotationLayerMove.Backward:
                    if (from >= count - 1)
                    {
                        return;
                    }

                    if (IsFree(from + 1)) { target = from + 1; } else { insertAt = from + 2; }
                    break;
                default:
                    if (from >= count - 1)
                    {
                        return;
                    }

                    if (IsFree(count - 1)) { target = count - 1; } else { insertAt = count; }
                    break;
            }

            if (target is { } joined)
            {
                tracks[joined].Items.Add(item);
                tracks[joined].Items.Sort((a, b) => a.SourceStartMs.CompareTo(b.SourceStartMs));
                tracks[joined].IsHidden = false;
                tracks[from].Items.Remove(item);
            }
            else
            {
                tracks[from].Items.Remove(item);
                tracks.Insert(insertAt, new AnnotationTrack { Name = "", Items = [item] });
            }
        });
        SelectedAnnotationId = id;
        SelectionChanged?.Invoke();
    }

    // MARK: Copy, paste and duplicate

    public void CopyAnnotation(string id)
    {
        if (Annotation(id) is { } item)
        {
            copiedAnnotation = item.Copy();
            copiedZoom = null;
            copiedMask = null;
            ToastRequested?.Invoke("Annotation copied");
        }
    }

    public void CutAnnotation(string id)
    {
        CopyAnnotation(id);
        DeleteAnnotation(id);
    }

    /// <summary>The copied item at the playhead, on the first track free then.</summary>
    public void PasteAnnotation()
    {
        if (copiedAnnotation is null)
        {
            return;
        }

        var item = copiedAnnotation.Copy();
        var bounds = AnnotationSourceBounds;
        var duration = Math.Max(AnnotationItem.MinDurationMs, item.SourceEndMs - item.SourceStartMs);
        var start = Math.Max(bounds.Start, Math.Min(SourceAtPlayhead, bounds.End - duration));
        item.Id = NewId();
        item.ShiftTime(start - item.SourceStartMs);
        item.SourceEndMs = Math.Min(bounds.End, start + duration);
        if (item.SourceEndMs - item.SourceStartMs >= AnnotationItem.MinDurationMs)
        {
            InsertAnnotation(item);
        }
    }

    /// <summary>A copy right after the item on its own track when it fits, otherwise at the same time on another track.</summary>
    public void DuplicateAnnotation(string id)
    {
        var t = AnnotationTrackIndex(id);
        if (Annotation(id) is not { } original || t < 0)
        {
            return;
        }

        var duration = original.SourceEndMs - original.SourceStartMs;
        var copy = original.Copy();
        copy.Id = NewId();
        var after = original.SourceEndMs;
        var track = Document.Timeline.AnnotationTracks[t];
        var fitsAfter = after + duration <= AnnotationSourceBounds.End + 0.5
            && !track.Items.Exists(other => other.Id != id && !(after + duration <= other.SourceStartMs + AnnotationTrack.OverlapToleranceMs || after >= other.SourceEndMs - AnnotationTrack.OverlapToleranceMs));
        if (fitsAfter)
        {
            copy.ShiftTime(after - original.SourceStartMs);
            InsertAnnotation(copy, track.Id);
        }
        else
        {
            InsertAnnotation(copy);
        }
    }

    public void ToggleAnnotationTrackVisibility(string trackId) => MutateAnnotations(document =>
    {
        if (document.Timeline.AnnotationTracks.Find(track => track.Id == trackId) is { } track)
        {
            track.IsHidden = !track.IsHidden;
        }
    });

    /// <summary>After an annotation edit: empty tracks go and the rest get their default names, as on macOS.</summary>
    private void NormalizeAnnotationTracks()
    {
        if (!annotationsTouched)
        {
            return;
        }

        annotationsTouched = false;
        var tracks = History.Current.Timeline.AnnotationTracks;
        tracks.RemoveAll(track => track.Items.Count == 0);
        for (var index = 0; index < tracks.Count; index++)
        {
            tracks[index].Name = AnnotationTrack.DefaultName(index);
        }
    }
}
