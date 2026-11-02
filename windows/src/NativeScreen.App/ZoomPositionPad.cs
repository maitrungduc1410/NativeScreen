using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using NativeScreen.Core;
using System.Runtime.InteropServices.WindowsRuntime;

namespace NativeScreen.App;

/// <summary>
/// A thumbnail of the recording with a draggable focus point and the zoomed viewport it produces. Dragging writes
/// ManualCenter01 as one undo step and parks the playhead inside the zoom, so the preview follows, as on macOS.
/// </summary>
internal sealed class ZoomPositionPad
{
    private const double DotSize = 26;

    private readonly EditorSession session;
    private readonly string zoomId;
    private readonly Canvas canvas = new() { Height = 150, Background = Ui.Pal("Ink07") };
    private readonly Image thumbnail = new() { Stretch = Stretch.Fill };
    private readonly Rectangle[] shades = new Rectangle[4];
    private readonly Border viewport = new() { BorderThickness = new Thickness(1), IsHitTestVisible = false };
    private readonly Ellipse dot = new() { Width = DotSize, Height = DotSize, StrokeThickness = 2, IsHitTestVisible = false };
    private readonly TextBlock readout = new() { FontSize = 11.5, IsHitTestVisible = false };
    private bool dragging;

    public ZoomPositionPad(EditorSession session, EditorTools tools, string zoomId)
    {
        this.session = session;
        this.zoomId = zoomId;
        viewport.BorderBrush = Ui.Pal("Ink95");
        dot.Fill = Ui.Rgb(0.16, 0.17, 0.22, 0.92);
        dot.Stroke = Ui.Pal("Ink95");
        readout.Foreground = Ui.Pal("Ink95");
        canvas.Clip = null;
        canvas.Children.Add(thumbnail);
        for (var index = 0; index < shades.Length; index++)
        {
            shades[index] = new Rectangle { Fill = Ui.Rgb(0, 0, 0, 0.45), IsHitTestVisible = false };
            canvas.Children.Add(shades[index]);
        }

        canvas.Children.Add(viewport);
        canvas.Children.Add(dot);
        canvas.Children.Add(readout);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(canvas, "Zoom position");

        canvas.SizeChanged += (_, _) => Layout();
        canvas.PointerPressed += (_, args) =>
        {
            dragging = canvas.CapturePointer(args.Pointer);
            session.BeginInteractiveEdit();
            ParkPlayhead();
            Move(args.GetCurrentPoint(canvas).Position);
            args.Handled = true;
        };
        canvas.PointerMoved += (_, args) =>
        {
            if (dragging)
            {
                Move(args.GetCurrentPoint(canvas).Position);
            }
        };
        canvas.PointerReleased += (_, args) =>
        {
            canvas.ReleasePointerCapture(args.Pointer);
            EndDrag();
        };
        canvas.PointerCaptureLost += (_, _) => EndDrag();
        Element.Children.Add(canvas);
        _ = LoadThumbnail(tools);
    }

    public Grid Element { get; } = new() { CornerRadius = new CornerRadius(8) };

    private ZoomBlock? Zoom => session.Document.Timeline.Zooms.Find(item => item.Id == zoomId);

    private void EndDrag()
    {
        if (dragging)
        {
            dragging = false;
            session.EndInteractiveEdit();
        }
    }

    private void ParkPlayhead()
    {
        if (Zoom is { } zoom && (session.SourceAtPlayhead < zoom.SourceStartMs || session.SourceAtPlayhead > zoom.SourceEndMs))
        {
            if (session.Mapper.TimelineTime((zoom.SourceStartMs + zoom.SourceEndMs) / 2) is { } timeline)
            {
                session.Scrub(timeline);
            }
        }
    }

    private void Move(Windows.Foundation.Point point)
    {
        var center = new Point01(Math.Clamp(point.X / Math.Max(1, canvas.ActualWidth), 0, 1), Math.Clamp(point.Y / Math.Max(1, canvas.ActualHeight), 0, 1));
        session.Mutate(
            document =>
            {
                if (document.Timeline.Zooms.Find(item => item.Id == zoomId) is { } zoom)
                {
                    zoom.ManualCenter01 = center;
                }
            },
            structural: false);
        Layout();
    }

    private void Layout()
    {
        if (Zoom is not { } zoom)
        {
            return;
        }

        var (width, height) = (canvas.ActualWidth, canvas.ActualHeight);
        thumbnail.Width = width;
        thumbnail.Height = height;
        var scale = Math.Max(1, zoom.Scale);
        var (w, h) = (width / scale, height / scale);
        var x = Math.Min(Math.Max(0, zoom.ManualCenter01.X * width - w / 2), width - w);
        var y = Math.Min(Math.Max(0, zoom.ManualCenter01.Y * height - h / 2), height - h);
        Place(shades[0], 0, 0, width, y);
        Place(shades[1], 0, y + h, width, height - y - h);
        Place(shades[2], 0, y, x, h);
        Place(shades[3], x + w, y, width - x - w, h);
        Place(viewport, x, y, w, h);
        Canvas.SetLeft(dot, zoom.ManualCenter01.X * width - DotSize / 2);
        Canvas.SetTop(dot, zoom.ManualCenter01.Y * height - DotSize / 2);
        readout.Text = $"Left {Math.Round(zoom.ManualCenter01.X * 100)}% · Top {Math.Round(zoom.ManualCenter01.Y * 100)}%";
        Canvas.SetLeft(readout, 8);
        Canvas.SetTop(readout, 6);
    }

    private static void Place(FrameworkElement element, double x, double y, double width, double height)
    {
        Canvas.SetLeft(element, x);
        Canvas.SetTop(element, y);
        element.Width = Math.Max(0, width);
        element.Height = Math.Max(0, height);
    }

    private async Task LoadThumbnail(EditorTools tools)
    {
        if (Zoom is not { } zoom || await tools.ReadFrame((zoom.SourceStartMs + zoom.SourceEndMs) / 2) is not { } frame)
        {
            return;
        }

        var bitmap = new WriteableBitmap(frame.Width, frame.Height);
        using (var stream = bitmap.PixelBuffer.AsStream())
        {
            stream.Write(frame.Bgra);
        }

        bitmap.Invalidate();
        thumbnail.Source = bitmap;
        // The pad keeps the recording's shape at whatever width the panel gives it.
        canvas.Height = Math.Max(90, canvas.ActualWidth * frame.Height / Math.Max(1, frame.Width));
    }
}
