using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using NativeScreen.Core;

namespace NativeScreen.App;

/// <summary>
/// XAML above the preview: handles for the masks under a paused playhead, and the short-video safe zones. It draws only when
/// paused and only after an edit or a seek, so it costs nothing during playback.
/// </summary>
internal sealed partial class PreviewOverlay
{
    private const double HandleSize = 14;
    private const double MinimumSize01 = 0.02;
    private const double SafeTop = 0.12;
    private const double SafeBottom = 0.22;
    private const double SafeRight = 0.14;

    private static readonly Brush Accent = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 124, 92, 252));
    private static readonly Brush Shade = new SolidColorBrush(Windows.UI.Color.FromArgb(90, 255, 80, 80));

    private readonly EditorSession session;
    private readonly Canvas canvas;
    private readonly Func<(double SourceWidth, double SourceHeight, bool HasCamera)> source;
    private Interaction? active;
    private string? hoveredMaskId;

    public PreviewOverlay(EditorSession session, Canvas canvas, Func<(double, double, bool)> source)
    {
        this.session = session;
        this.canvas = canvas;
        this.source = source;
        // A click that lands on a drawn keycap or caption opens its editor; masks sit above and take their own clicks.
        canvas.Background = new SolidColorBrush(Windows.UI.Color.FromArgb(1, 0, 0, 0));
        canvas.PointerPressed += (_, args) =>
        {
            if (active is not null)
            {
                return;
            }

            var point = args.GetCurrentPoint(canvas).Position;
            var (x, y) = (point.X / Math.Max(1, canvas.ActualWidth), point.Y / Math.Max(1, canvas.ActualHeight));
            static string? HitIn(IReadOnlyDictionary<string, System.Numerics.Vector4>? hits, double x, double y)
            {
                foreach (var (id, rect) in hits ?? new Dictionary<string, System.Numerics.Vector4>())
                {
                    if (x >= rect.X && x <= rect.X + rect.Z && y >= rect.Y && y <= rect.Y + rect.W)
                    {
                        return id;
                    }
                }

                return null;
            }

            if (!session.IsPlaying && HitIn(ShortcutHits?.Invoke(), x, y) is { } shortcut)
            {
                session.SelectShortcut(shortcut);
                args.Handled = true;
            }
            else if (HitIn(CaptionHits?.Invoke(), x, y) is { } caption)
            {
                session.SelectCaption(caption);
                args.Handled = true;
            }
        };
        canvas.PointerMoved += Moved;
        canvas.PointerReleased += Released;
        canvas.PointerCaptureLost += (_, _) => Finish();
    }

    public bool ShowSafeZones { get; set; }

    public Func<IReadOnlyDictionary<string, System.Numerics.Vector4>>? ShortcutHits { get; set; }

    public Func<IReadOnlyDictionary<string, System.Numerics.Vector4>>? CaptionHits { get; set; }

    public void Refresh() => Refresh(rebuildDuringDrag: false);

    private void Refresh(bool rebuildDuringDrag)
    {
        // While a text is typed into, its field stays; rebuilding would take the focus away and end the typing.
        if (active is not null || textEditor is not null || annotationDrag is not null && !rebuildDuringDrag)
        {
            return;
        }

        canvas.Children.Clear();
        annotationCornerSigns.Clear();
        var (width, height) = (canvas.ActualWidth, canvas.ActualHeight);
        if (width < 2 || height < 2)
        {
            return;
        }

        if (ShowSafeZones)
        {
            DrawSafeZones(width, height);
        }

        if (session.PendingAddMaskType is { } pending && !session.IsPlaying)
        {
            DrawNewMaskLayer(pending, width, height);
            return;
        }

        if (session.IsPlaying || session.HoverSkimTimelineMs is not null || !session.Document.Timeline.MaskTracks.Exists(track => !track.IsHidden) && !session.Document.Timeline.AnnotationTracks.Exists(track => !track.IsHidden))
        {
            return;
        }

        var map = Transform(width, height);
        var at = session.SourceAtPlayhead;
        foreach (var track in session.Document.Timeline.MaskTracks.Where(track => !track.IsHidden))
        {
            foreach (var mask in track.Items.Where(item => !item.Disabled && at >= item.SourceStartMs && at <= item.SourceEndMs))
            {
                DrawMask(mask, map, at);
            }
        }

        DrawAnnotations(map, at, width, height);
    }

    /// <summary>Drag over the recording to choose the area; a plain click places a default mask around the click.</summary>
    private void DrawNewMaskLayer(MaskType type, double width, double height)
    {
        var (x, y, videoWidth, videoHeight) = Transform(width, height).ToCanvas(session.Document.Canvas.CropRect01);
        var layer = new CrosshairCanvas { Width = videoWidth, Height = videoHeight, Background = new SolidColorBrush(Windows.UI.Color.FromArgb(1, 255, 255, 255)) };
        Canvas.SetLeft(layer, x);
        Canvas.SetTop(layer, y);
        var selection = new Microsoft.UI.Xaml.Shapes.Rectangle
        {
            Fill = new SolidColorBrush(Windows.UI.Color.FromArgb(40, 124, 92, 252)),
            Stroke = Accent,
            StrokeThickness = 1.5,
            StrokeDashArray = [5, 3],
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = false
        };
        layer.Children.Add(selection);
        var hint = new Border
        {
            Padding = new Thickness(14, 7, 14, 7),
            CornerRadius = new CornerRadius(16),
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(184, 0, 0, 0)),
            IsHitTestVisible = false,
            Child = new TextBlock
            {
                Text = Loc.T(type == MaskType.Blur ? "Drag to select the area for the new sensitive data mask" : "Drag to select the area for the new highlight mask"),
                FontSize = 12.5,
                Foreground = new SolidColorBrush(Colors.White)
            }
        };
        hint.Loaded += (_, _) =>
        {
            var (visibleLeft, visibleRight) = (Math.Max(0, x), Math.Min(width, x + videoWidth));
            Canvas.SetLeft(hint, (visibleLeft + visibleRight - hint.ActualWidth) / 2 - x);
            Canvas.SetTop(hint, Math.Min(height, y + videoHeight) - hint.ActualHeight - 16 - y);
        };
        layer.Children.Add(hint);

        Windows.Foundation.Point? press = null;
        layer.PointerPressed += (_, args) =>
        {
            press = args.GetCurrentPoint(layer).Position;
            layer.CapturePointer(args.Pointer);
            hint.Visibility = Visibility.Collapsed;
            args.Handled = true;
        };
        layer.PointerMoved += (_, args) =>
        {
            if (press is not { } from)
            {
                return;
            }

            var to = args.GetCurrentPoint(layer).Position;
            var (left, right) = (Math.Clamp(Math.Min(from.X, to.X), 0, videoWidth), Math.Clamp(Math.Max(from.X, to.X), 0, videoWidth));
            var (top, bottom) = (Math.Clamp(Math.Min(from.Y, to.Y), 0, videoHeight), Math.Clamp(Math.Max(from.Y, to.Y), 0, videoHeight));
            Canvas.SetLeft(selection, left);
            Canvas.SetTop(selection, top);
            selection.Width = Math.Max(2, right - left);
            selection.Height = Math.Max(2, bottom - top);
            selection.Visibility = Visibility.Visible;
        };
        layer.PointerReleased += (_, args) =>
        {
            if (press is not { } from)
            {
                return;
            }

            press = null;
            var to = args.GetCurrentPoint(layer).Position;
            layer.ReleasePointerCaptures();
            var crop = session.Document.Canvas.CropRect01;
            var (x0, x1) = (Math.Clamp(from.X, 0, videoWidth), Math.Clamp(to.X, 0, videoWidth));
            var (y0, y1) = (Math.Clamp(from.Y, 0, videoHeight), Math.Clamp(to.Y, 0, videoHeight));
            var (dragWidth, dragHeight) = (Math.Abs(x1 - x0), Math.Abs(y1 - y0));
            Rect01 rect;
            if (dragWidth >= 6 && dragHeight >= 6)
            {
                rect = new Rect01(
                    crop.X + Math.Min(x0, x1) / Math.Max(1, videoWidth) * crop.Width,
                    crop.Y + Math.Min(y0, y1) / Math.Max(1, videoHeight) * crop.Height,
                    dragWidth / Math.Max(1, videoWidth) * crop.Width,
                    dragHeight / Math.Max(1, videoHeight) * crop.Height);
            }
            else
            {
                var (sourceX, sourceY) = (crop.X + x1 / Math.Max(1, videoWidth) * crop.Width, crop.Y + y1 / Math.Max(1, videoHeight) * crop.Height);
                var (defaultWidth, defaultHeight) = (Math.Min(0.28, crop.Width), Math.Min(0.14, crop.Height));
                rect = new Rect01(
                    Math.Max(crop.X, Math.Min(crop.X + crop.Width - defaultWidth, sourceX - defaultWidth / 2)),
                    Math.Max(crop.Y, Math.Min(crop.Y + crop.Height - defaultHeight, sourceY - defaultHeight / 2)),
                    defaultWidth,
                    defaultHeight);
            }

            session.CompleteInteractiveMaskSelection(rect);
        };
        canvas.Children.Add(layer);
    }

    private CanvasCoordinateTransform Transform(double width, double height)
    {
        var (document, trajectory) = session.RenderSnapshot();
        var (sourceWidth, sourceHeight, hasCamera) = source();
        var crop = document.Canvas.CropRect01;
        var at = session.SourceAtPlayhead;
        var face = session.IsCameraOnly ? CameraOnlyLayout.FaceCenter01(document, session.FaceTrack, at) : null;
        var camera = CameraOnlyLayout.FaceCentered(trajectory.EvaluateAtTimeline(session.PlayheadTimelineMs).Camera, face);
        var stage = new StageLayoutEngine().Resolve(document, at, width, height, Math.Max(16, sourceWidth * crop.Width), Math.Max(16, sourceHeight * crop.Height), camera.Scale, hasCamera, cameraOnly: session.IsCameraOnly, faceTrack: session.FaceTrack);
        // The screen camera keeps its transform while a lens is visible (ADR-86).
        return new CanvasCoordinateTransform(width, height, stage.ScreenRect, crop, camera.Center01, camera.Scale);
    }

    private void DrawSafeZones(double width, double height)
    {
        Zone(0, 0, width, height * SafeTop);
        Zone(0, height * (1 - SafeBottom), width, height * SafeBottom);
        Zone(width * (1 - SafeRight), height * SafeTop, width * SafeRight, height * (1 - SafeTop - SafeBottom));
    }

    private void Zone(double x, double y, double width, double height)
    {
        var zone = new Border { Width = width, Height = height, Background = Shade, IsHitTestVisible = false };
        Canvas.SetLeft(zone, x);
        Canvas.SetTop(zone, y);
        canvas.Children.Add(zone);
    }

    // The drawn frame is the mask's only appearance. This layer sits above the cursor, so it adds nothing but corner handles,
    // and those only while the mask is selected or under the pointer.
    private void DrawMask(MaskItem mask, CanvasCoordinateTransform map, double at)
    {
        var rect = mask.InterpolatedRect(at);
        var (x, y, width, height) = map.ToCanvas(rect);
        var id = mask.Id;
        var body = new Border
        {
            Width = Math.Max(1, width),
            Height = Math.Max(1, height),
            Background = new SolidColorBrush(Colors.Transparent)
        };
        Canvas.SetLeft(body, x);
        Canvas.SetTop(body, y);
        canvas.Children.Add(body);
        Begin(body, mask, map, rect, at, moveX: 1, moveY: 1, sizeX: 0, sizeY: 0);
        Border[] handles =
        [
            Handle(mask, map, rect, at, x, y, 1, 1, -1, -1),
            Handle(mask, map, rect, at, x + width, y, 0, 1, 1, -1),
            Handle(mask, map, rect, at, x, y + height, 1, 0, -1, 1),
            Handle(mask, map, rect, at, x + width, y + height, 0, 0, 1, 1)
        ];
        void ShowHandles()
        {
            var visible = id == session.SelectedMaskId || id == hoveredMaskId;
            foreach (var handle in handles)
            {
                handle.Opacity = visible ? 1 : 0;
            }
        }

        foreach (var element in handles.Append(body))
        {
            element.PointerEntered += (_, _) =>
            {
                hoveredMaskId = id;
                ShowHandles();
            };
            element.PointerExited += (_, _) =>
            {
                hoveredMaskId = hoveredMaskId == id ? null : hoveredMaskId;
                ShowHandles();
            };
        }

        ShowHandles();
    }

    private Border Handle(MaskItem mask, CanvasCoordinateTransform map, Rect01 rect, double at, double x, double y, double moveX, double moveY, double sizeX, double sizeY)
    {
        var handle = new Border { Width = HandleSize, Height = HandleSize, CornerRadius = new CornerRadius(HandleSize / 2), Background = new SolidColorBrush(Colors.White), BorderBrush = Accent, BorderThickness = new Thickness(2) };
        Canvas.SetLeft(handle, x - HandleSize / 2);
        Canvas.SetTop(handle, y - HandleSize / 2);
        canvas.Children.Add(handle);
        Begin(handle, mask, map, rect, at, moveX, moveY, sizeX, sizeY);
        return handle;
    }

    private void Begin(FrameworkElement element, MaskItem mask, CanvasCoordinateTransform map, Rect01 rect, double at, double moveX, double moveY, double sizeX, double sizeY)
    {
        var id = mask.Id;
        var start = new Rect01(rect.X, rect.Y, rect.Width, rect.Height);
        element.PointerPressed += (_, args) =>
        {
            var point = args.GetCurrentPoint(canvas).Position;
            active = new Interaction(id, element, start, map, at, point.X, point.Y, moveX, moveY, sizeX, sizeY, false);
            session.BeginInteractiveEdit();
            canvas.CapturePointer(args.Pointer);
            args.Handled = true;
        };
    }

    private void Moved(object sender, PointerRoutedEventArgs args)
    {
        if (MovedAnnotation(args))
        {
            return;
        }

        if (active is not { } drag)
        {
            return;
        }

        var point = args.GetCurrentPoint(canvas).Position;
        var (dx, dy) = drag.Map.DeltaToSource(point.X - drag.PressX, point.Y - drag.PressY);
        var start = drag.Start;
        var width = Math.Max(MinimumSize01, start.Width + dx * drag.SizeX);
        var height = Math.Max(MinimumSize01, start.Height + dy * drag.SizeY);
        var x = drag.SizeX == 0 ? start.X + dx : drag.MoveX == 1 ? start.X + start.Width - width : start.X;
        var y = drag.SizeY == 0 ? start.Y + dy : drag.MoveY == 1 ? start.Y + start.Height - height : start.Y;
        if (drag.SizeX == 0 && drag.SizeY == 0)
        {
            x = Math.Clamp(x, 0, 1 - start.Width);
            y = Math.Clamp(y, 0, 1 - start.Height);
        }

        var next = new Rect01(x, y, width, height).Clamped();
        active = drag with { Changed = true };
        session.Mutate(
            document =>
            {
                if (document.Timeline.MaskTracks.SelectMany(track => track.Items).FirstOrDefault(item => item.Id == drag.MaskId) is { } mask)
                {
                    TimelineEdits.SetMaskRect(mask, next, drag.AtMs);
                }
            },
            structural: false);
        var (left, top, drawnWidth, drawnHeight) = drag.Map.ToCanvas(next);
        if (drag.SizeX == 0 && drag.SizeY == 0)
        {
            Canvas.SetLeft(drag.Element, left);
            Canvas.SetTop(drag.Element, top);
            drag.Element.Width = Math.Max(1, drawnWidth);
            drag.Element.Height = Math.Max(1, drawnHeight);
        }
    }

    private void Released(object sender, PointerRoutedEventArgs args)
    {
        canvas.ReleasePointerCaptures();
        Finish();
    }

    private void Finish()
    {
        if (FinishAnnotation())
        {
            return;
        }

        if (active is not { } drag)
        {
            return;
        }

        active = null;
        session.EndInteractiveEdit();
        session.SelectMask(drag.MaskId);
        Refresh();
    }

    private sealed partial class CrosshairCanvas : Canvas
    {
        public CrosshairCanvas() => ProtectedCursor = Microsoft.UI.Input.InputSystemCursor.Create(Microsoft.UI.Input.InputSystemCursorShape.Cross);
    }

    private sealed record Interaction(string MaskId, FrameworkElement Element, Rect01 Start, CanvasCoordinateTransform Map, double AtMs, double PressX, double PressY, double MoveX, double MoveY, double SizeX, double SizeY, bool Changed);
}
