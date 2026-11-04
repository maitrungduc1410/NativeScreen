using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Shapes;
using NativeScreen.Core;

namespace NativeScreen.App;

/// <summary>A small picture of the canvas with a dot marking where the caption line sits. Dragging it is one undo step.</summary>
internal sealed class CaptionPositionPad
{
    private const double PadHeight = 170;
    private const double Inset = 16;
    private const double DotSize = 26;

    private readonly EditorSession session;
    private readonly string? blockId;
    private readonly string trackId;
    private readonly Action finished;
    private readonly Canvas canvas = new() { Height = PadHeight };
    private readonly Ellipse dot = new() { Width = DotSize, Height = DotSize, StrokeThickness = 1, IsHitTestVisible = false };
    private Point01 position;
    private bool dragging;

    public CaptionPositionPad(EditorSession session, string? blockId, string trackId, Point01 position, Action finished)
    {
        this.session = session;
        this.blockId = blockId;
        this.trackId = trackId;
        this.position = position;
        this.finished = finished;
        Element = new Border { CornerRadius = new CornerRadius(10), Background = Ui.Pal("Ink07"), Child = canvas };
        dot.Fill = Ui.Rgb(0.13, 0.14, 0.17);
        dot.Stroke = Ui.Rgb(1, 1, 1, 0.95);
        canvas.Background = Ui.Rgb(0, 0, 0, 0);
        canvas.Children.Add(dot);
        canvas.SizeChanged += (_, _) => PlaceDot();
        canvas.PointerPressed += Pressed;
        canvas.PointerMoved += Moved;
        canvas.PointerReleased += Released;
        canvas.PointerCaptureLost += (_, _) => End();
    }

    public Border Element { get; }

    private void PlaceDot()
    {
        Canvas.SetLeft(dot, Inset + Math.Max(1, canvas.ActualWidth - Inset * 2) * position.X - DotSize / 2);
        Canvas.SetTop(dot, Inset + (PadHeight - Inset * 2) * position.Y - DotSize / 2);
    }

    private void Pressed(object sender, PointerRoutedEventArgs args)
    {
        dragging = true;
        session.BeginInteractiveEdit();
        canvas.CapturePointer(args.Pointer);
        Update(args);
        args.Handled = true;
    }

    private void Moved(object sender, PointerRoutedEventArgs args)
    {
        if (dragging)
        {
            Update(args);
        }
    }

    private void Released(object sender, PointerRoutedEventArgs args)
    {
        canvas.ReleasePointerCapture(args.Pointer);
        End();
    }

    private void End()
    {
        if (dragging)
        {
            dragging = false;
            session.EndInteractiveEdit();
            finished();
        }
    }

    private void Update(PointerRoutedEventArgs args)
    {
        var point = args.GetCurrentPoint(canvas).Position;
        var next = new Point01(
            Math.Clamp((point.X - Inset) / Math.Max(1, canvas.ActualWidth - Inset * 2), 0, 1),
            Math.Clamp((point.Y - Inset) / (PadHeight - Inset * 2), 0, 1));
        position = next;
        session.UpdateCaptionStyle(blockId, trackId, style => style.Position01 = new Point01(next.X, next.Y), "caption-position");
        PlaceDot();
    }
}
