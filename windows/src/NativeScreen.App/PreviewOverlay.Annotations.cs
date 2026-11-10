using System.Numerics;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using NativeScreen.Core;
using NativeScreen.Rendering;

namespace NativeScreen.App;

/// <summary>
/// Canvas handles for annotations (spec/06 ADR-75): a click selects, a drag moves, corners resize or scale, a knob rotates
/// (snapping to 45°), arrow ends and bend move, and a double-click types into a text in place. Geometry comes from the same
/// numbers the compositor uses, and edits go through the keyframe at the playhead when there are keyframes.
/// </summary>
internal sealed partial class PreviewOverlay
{
    private const double SnapPoints = 12;
    private const double KnobOffset = 26;
    private AnnotationDrag? annotationDrag;
    private TextBox? textEditor;

    /// <summary>The package, for image sizes.</summary>
    public string? PackageDirectory { get; set; }

    /// <summary>Asks the window to compose again (the typed text leaves the preview while its field shows it).</summary>
    public Action? RedrawRequested { get; set; }

    private enum DragPart
    {
        Body,
        Corner,
        Rotate,
        Tail,
        Head,
        Bend
    }

    private sealed record AnnotationDrag(string Id, DragPart Part, AnnotationItem Start, double AtMs, Vector2 Press, Vector2 Center, Vector2 CornerSign, CanvasCoordinateTransform Map, double Width, double Height);

    private Vector2 ToCanvas(AnnotationItem item, Point01 p, CanvasCoordinateTransform map, double width, double height)
    {
        if (item.Anchor == AnnotationAnchor.Canvas)
        {
            return new Vector2((float)(p.X * width), (float)(p.Y * height));
        }

        var (x, y) = map.ToCanvas(p.X, p.Y);
        return new Vector2((float)x, (float)y);
    }

    private static Point01 ToPoint(AnnotationItem item, Vector2 c, CanvasCoordinateTransform map, double width, double height)
    {
        if (item.Anchor == AnnotationAnchor.Canvas)
        {
            return new Point01(Math.Clamp(c.X / width, 0, 1), Math.Clamp(c.Y / height, 0, 1));
        }

        var (x, y) = map.ToSource(c.X, c.Y);
        return new Point01(Math.Clamp(x, 0, 1), Math.Clamp(y, 0, 1));
    }

    private void DrawAnnotations(CanvasCoordinateTransform map, double at, double width, double height)
    {
        if (session.Document.Timeline.AnnotationTracks.Count == 0)
        {
            return;
        }

        // Bottom first, so the top layer takes the click.
        foreach (var item in AnnotationMath.Active(session.Document, at))
        {
            DrawAnnotation(item, map, at, width, height);
        }

        if (textEditor is not null)
        {
            canvas.Children.Add(textEditor);
        }
    }

    private void DrawAnnotation(AnnotationItem item, CanvasCoordinateTransform map, double at, double width, double height)
    {
        var selected = item.Id == session.SelectedAnnotationId;
        switch (item.Kind)
        {
            case AnnotationKind.Arrow:
            {
                var tail = ToCanvas(item, item.From01, map, width, height);
                var head = ToCanvas(item, item.To01, map, width, height);
                var stroke = AnnotationMath.StrokeWidth(item, width, height);
                var g = AnnotationMath.ArrowGeometry(tail, head, item.Bend, stroke);
                // A thick, see-through line along the shaft takes the clicks.
                var path = new Microsoft.UI.Xaml.Shapes.Path
                {
                    Data = Quadratic(g.Tail, g.Control, g.Head),
                    Stroke = new SolidColorBrush(Windows.UI.Color.FromArgb(1, 0, 0, 0)),
                    StrokeThickness = Math.Max(14, stroke * 2)
                };
                canvas.Children.Add(path);
                Press(path, item, DragPart.Body, at, (tail + head) * 0.5f, Vector2.Zero, map, width, height);
                if (selected)
                {
                    Knob(item, g.Tail, DragPart.Tail, at, map, width, height);
                    Knob(item, g.Head, DragPart.Head, at, map, width, height);
                    // The bend handle sits on the curve's middle.
                    var middle = 0.25f * g.Tail + 0.5f * g.Control + 0.25f * g.Head;
                    Knob(item, middle, DragPart.Bend, at, map, width, height, small: true);
                }

                break;
            }

            case AnnotationKind.Rectangle:
            case AnnotationKind.Ellipse:
            case AnnotationKind.Pen:
            {
                var center = ToCanvas(item, item.Position01, map, width, height);
                var half = AnnotationMath.ShapeHalfSize(item, p => ToCanvas(item, p, map, width, height));
                Box(item, center, (float)half.Width * 2, (float)half.Height * 2, at, map, width, height, selected, corners: true);
                break;
            }

            default:
            {
                var center = ToCanvas(item, item.Position01, map, width, height);
                var (w, h) = AnnotationMeasure.Box(item, width, height, PackageDirectory);
                Action? type = item.Kind == AnnotationKind.Text ? () => BeginTyping(item, center, (float)w, (float)h, width, height) : null;
                Box(item, center, (float)w, (float)h, at, map, width, height, selected, corners: true, type);
                break;
            }
        }
    }

    /// <summary>The item's turned box: a see-through body, its outline when selected, corner handles and the rotation knob.</summary>
    private Border Box(AnnotationItem item, Vector2 center, float w, float h, double at, CanvasCoordinateTransform map, double width, double height, bool selected, bool corners, Action? doubleClick = null)
    {
        var body = new Border
        {
            Width = Math.Max(8, w),
            Height = Math.Max(8, h),
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(1, 0, 0, 0)),
            BorderBrush = selected ? Accent : null,
            BorderThickness = new Thickness(selected ? 1.5 : 0),
            RenderTransform = new RotateTransform { Angle = item.RotationDegrees, CenterX = Math.Max(8, w) / 2, CenterY = Math.Max(8, h) / 2 }
        };
        Canvas.SetLeft(body, center.X - Math.Max(8, w) / 2);
        Canvas.SetTop(body, center.Y - Math.Max(8, h) / 2);
        canvas.Children.Add(body);
        Press(body, item, DragPart.Body, at, center, Vector2.Zero, map, width, height, doubleClick);
        if (!selected)
        {
            return body;
        }

        var turn = Matrix3x2.CreateRotation((float)(item.RotationDegrees * Math.PI / 180));
        if (corners)
        {
            foreach (var sign in (ReadOnlySpan<Vector2>)[new(-1, -1), new(1, -1), new(-1, 1), new(1, 1)])
            {
                var corner = center + Vector2.Transform(new Vector2(sign.X * w / 2, sign.Y * h / 2), turn);
                var handle = Knob(item, corner, DragPart.Corner, at, map, width, height);
                annotationCornerSigns[handle] = sign;
            }
        }

        if (item.Kind.CanRotate())
        {
            Knob(item, center + Vector2.Transform(new Vector2(0, -h / 2 - (float)KnobOffset), turn), DragPart.Rotate, at, map, width, height, small: true);
        }

        return body;
    }

    private readonly Dictionary<FrameworkElement, Vector2> annotationCornerSigns = [];
    private (string Id, long Ticks, double X, double Y)? lastAnnotationPress;

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint GetDoubleClickTime();

    private FrameworkElement Knob(AnnotationItem item, Vector2 at, DragPart part, double atMs, CanvasCoordinateTransform map, double width, double height, bool small = false)
    {
        var size = small ? HandleSize - 4 : HandleSize;
        var handle = new Border { Width = size, Height = size, CornerRadius = new CornerRadius(size / 2), Background = new SolidColorBrush(Colors.White), BorderBrush = Accent, BorderThickness = new Thickness(2) };
        Canvas.SetLeft(handle, at.X - size / 2);
        Canvas.SetTop(handle, at.Y - size / 2);
        canvas.Children.Add(handle);
        var center = ToCanvas(item, item.Position01, map, width, height);
        handle.PointerPressed += (_, args) =>
        {
            var sign = annotationCornerSigns.GetValueOrDefault(handle);
            StartDrag(args, item, part, atMs, center, sign, map, width, height);
        };
        return handle;
    }

    /// <summary>
    /// A press selects and starts a drag; a second press on the same item within the double-click time runs
    /// <paramref name="doubleClick"/>. Counted here and not with DoubleTapped: every click rebuilds the handles, so the
    /// second click lands on a new element and the gesture never forms.
    /// </summary>
    private void Press(FrameworkElement element, AnnotationItem item, DragPart part, double at, Vector2 center, Vector2 sign, CanvasCoordinateTransform map, double width, double height, Action? doubleClick = null) =>
        element.PointerPressed += (_, args) =>
        {
            var position = args.GetCurrentPoint(canvas).Position;
            var now = Environment.TickCount64;
            var second = lastAnnotationPress is { } last
                && last.Id == item.Id
                && now - last.Ticks <= GetDoubleClickTime()
                && Math.Abs(position.X - last.X) <= 6
                && Math.Abs(position.Y - last.Y) <= 6;
            lastAnnotationPress = second ? null : (item.Id, now, position.X, position.Y);
            if (second && doubleClick is not null)
            {
                args.Handled = true;
                doubleClick();
                return;
            }

            if (session.SelectedAnnotationId != item.Id)
            {
                session.SelectAnnotation(item.Id);
            }

            StartDrag(args, item, part, at, center, sign, map, width, height);
        };

    private void StartDrag(PointerRoutedEventArgs args, AnnotationItem item, DragPart part, double at, Vector2 center, Vector2 sign, CanvasCoordinateTransform map, double width, double height)
    {
        var point = args.GetCurrentPoint(canvas).Position;
        annotationDrag = new AnnotationDrag(item.Id, part, item.Copy(), at, new Vector2((float)point.X, (float)point.Y), center, sign, map, width, height);
        session.BeginInteractiveEdit();
        canvas.CapturePointer(args.Pointer);
        args.Handled = true;
    }

    /// <summary>Recorded clicks near the item's time, to snap screen-pinned points onto.</summary>
    private Vector2 Snapped(AnnotationDrag drag, Vector2 point)
    {
        if (drag.Start.Anchor != AnnotationAnchor.Screen)
        {
            return point;
        }

        var best = point;
        var bestDistance = SnapPoints;
        foreach (var click in session.RecordedClicks(drag.Start.SourceStartMs - 1000, drag.Start.SourceEndMs + 1000))
        {
            var c = ToCanvas(drag.Start, click, drag.Map, drag.Width, drag.Height);
            var distance = Vector2.Distance(c, point);
            if (distance < bestDistance)
            {
                bestDistance = distance;
                best = c;
            }
        }

        return best;
    }

    private bool MovedAnnotation(PointerRoutedEventArgs args)
    {
        if (annotationDrag is not { } drag)
        {
            return false;
        }

        var p = args.GetCurrentPoint(canvas).Position;
        var point = new Vector2((float)p.X, (float)p.Y);
        var delta = point - drag.Press;
        var start = drag.Start;
        Vector2 C(Point01 q) => ToCanvas(start, q, drag.Map, drag.Width, drag.Height);
        Point01 P(Vector2 c) => ToPoint(start, c, drag.Map, drag.Width, drag.Height);
        session.EditAnnotationGeometry(drag.Id, drag.AtMs, item =>
        {
            switch (drag.Part)
            {
                case DragPart.Body when start.Kind == AnnotationKind.Arrow:
                    item.From01 = P(C(start.From01) + delta);
                    item.To01 = P(C(start.To01) + delta);
                    break;
                case DragPart.Body:
                {
                    var moved = C(start.Position01) + delta;
                    item.Position01 = P(start.Kind is AnnotationKind.Step or AnnotationKind.Rectangle or AnnotationKind.Ellipse ? Snapped(drag, moved) : moved);
                    break;
                }

                case DragPart.Tail:
                    item.From01 = P(Snapped(drag, C(start.From01) + delta));
                    break;
                case DragPart.Head:
                    item.To01 = P(Snapped(drag, C(start.To01) + delta));
                    break;
                case DragPart.Bend:
                {
                    var tail = C(start.From01);
                    var head = C(start.To01);
                    var length = Math.Max(1, Vector2.Distance(tail, head));
                    var normal = new Vector2((head.Y - tail.Y) / length, -(head.X - tail.X) / length);
                    // The handle is at half the control offset along the normal.
                    var offset = Vector2.Dot(point - (tail + head) * 0.5f, normal) * 2;
                    item.Bend = AnnotationItem.ClampedBend(offset / length);
                    break;
                }

                case DragPart.Rotate:
                {
                    var center = C(start.Position01);
                    var angle = Math.Atan2(point.X - center.X, -(point.Y - center.Y)) * 180 / Math.PI;
                    var snapped = Math.Round(angle / 45) * 45;
                    item.RotationDegrees = AnnotationItem.NormalizedRotation(Math.Abs(angle - snapped) < 4 ? snapped : angle);
                    break;
                }

                case DragPart.Corner:
                    Resize(item, start, drag, delta, C, P);
                    break;
            }
        }, "annotation-canvas");
        Refresh(rebuildDuringDrag: true);
        return true;
    }

    /// <summary>Shapes resize in their turned frame with the opposite corner fixed; text, steps and images scale.</summary>
    private static void Resize(AnnotationItem item, AnnotationItem start, AnnotationDrag drag, Vector2 delta, Func<Point01, Vector2> c, Func<Vector2, Point01> p)
    {
        var center = c(start.Position01);
        if (!start.Kind.IsShape())
        {
            var startCorner = drag.Press - center;
            var ratio = Math.Max(0.1, (startCorner + delta).Length() / Math.Max(1, startCorner.Length()));
            switch (start.Kind)
            {
                case AnnotationKind.Image:
                    item.MaxWidthRatio = AnnotationItem.ClampedMaxWidth(start.MaxWidthRatio * ratio);
                    break;
                default:
                    item.FontSizeRatio = AnnotationItem.ClampedFontSize(start.FontSizeRatio * ratio);
                    break;
            }

            return;
        }

        var angle = (float)(start.RotationDegrees * Math.PI / 180);
        var local = Vector2.Transform(delta, Matrix3x2.CreateRotation(-angle));
        var right = c(new Point01(start.Position01.X + start.Size01.Width * 0.5, start.Position01.Y));
        var down = c(new Point01(start.Position01.X, start.Position01.Y + start.Size01.Height * 0.5));
        var halfW = Vector2.Distance(right, center);
        var halfH = Vector2.Distance(down, center);
        var newHalfW = Math.Max(4, halfW + local.X * drag.CornerSign.X / 2);
        var newHalfH = Math.Max(4, halfH + local.Y * drag.CornerSign.Y / 2);
        var shift = Vector2.Transform(new Vector2((newHalfW - halfW) * drag.CornerSign.X, (newHalfH - halfH) * drag.CornerSign.Y), Matrix3x2.CreateRotation(angle));
        item.Position01 = p(center + shift);
        // Sizes are in the item's own units: scale them by how much the pixel half sizes grew.
        item.Size01 = new Size01(
            AnnotationItem.ClampedSize(start.Size01.Width * newHalfW / Math.Max(0.5f, halfW)),
            AnnotationItem.ClampedSize(start.Size01.Height * newHalfH / Math.Max(0.5f, halfH)));
    }

    private bool FinishAnnotation()
    {
        if (annotationDrag is not { } drag)
        {
            return false;
        }

        annotationDrag = null;
        session.EndInteractiveEdit();
        session.SelectAnnotation(drag.Id);
        Refresh();
        return true;
    }

    /// <summary>A field in the text's font, size and plate over it; the preview leaves the item out meanwhile.</summary>
    private void BeginTyping(AnnotationItem item, Vector2 center, float w, float h, double width, double height)
    {
        var fontSize = AnnotationMath.FontSize(item, width, height);
        var (r, g, b) = AnnotationMath.HexColor(item.Color);
        var (br, bg, bb) = AnnotationMath.HexColor(item.BackgroundColor);
        var plate = item.TextBackground == AnnotationTextBackground.Solid;
        var id = item.Id;
        var editor = new TextBox
        {
            Text = item.Text,
            FontSize = fontSize,
            FontWeight = item.Bold ? Microsoft.UI.Text.FontWeights.Bold : Microsoft.UI.Text.FontWeights.Medium,
            TextAlignment = TextAlignment.Center,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinWidth = Math.Max(40, w),
            MaxWidth = Math.Max(w, item.MaxWidthRatio * width),
            Foreground = new SolidColorBrush(Windows.UI.Color.FromArgb(255, (byte)(r * 255), (byte)(g * 255), (byte)(b * 255))),
            Background = plate ? new SolidColorBrush(Windows.UI.Color.FromArgb(255, (byte)(br * 255), (byte)(bg * 255), (byte)(bb * 255))) : new SolidColorBrush(Windows.UI.Color.FromArgb(120, 0, 0, 0)),
            BorderBrush = Accent,
            CornerRadius = new CornerRadius(AnnotationMath.TextCornerRadius(item, fontSize))
        };
        Canvas.SetLeft(editor, center.X - Math.Max(40, w) / 2);
        Canvas.SetTop(editor, center.Y - h / 2);
        void Commit()
        {
            if (textEditor != editor)
            {
                return;
            }

            textEditor = null;
            session.EditingAnnotationTextId = null;
            if (session.Annotation(id) is { } current && current.Text != editor.Text)
            {
                session.UpdateAnnotation(id, a => a.Text = editor.Text);
            }

            Refresh();
            RedrawRequested?.Invoke();
        }

        editor.LostFocus += (_, _) => Commit();
        editor.KeyDown += (_, args) =>
        {
            if (args.Key == Windows.System.VirtualKey.Escape)
            {
                editor.Text = item.Text;
                args.Handled = true;
                Commit();
            }
        };
        textEditor = editor;
        session.EditingAnnotationTextId = id;
        canvas.Children.Add(editor);
        editor.Focus(FocusState.Programmatic);
        editor.SelectAll();
        RedrawRequested?.Invoke();
    }

    private static Geometry Quadratic(Vector2 a, Vector2 control, Vector2 b)
    {
        var figure = new PathFigure { StartPoint = new Windows.Foundation.Point(a.X, a.Y) };
        figure.Segments.Add(new QuadraticBezierSegment { Point1 = new Windows.Foundation.Point(control.X, control.Y), Point2 = new Windows.Foundation.Point(b.X, b.Y) });
        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        return geometry;
    }
}
