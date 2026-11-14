using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;

namespace NativeScreen.App;

/// <summary>
/// Makes a borderless window movable the way a title bar is: the whole window is a caption region and its controls are
/// click-through, so Windows runs the move itself and keeps up with the pointer. Moving it from XAML pointer events
/// (AppWindow.Move on every PointerMoved) ran a layout and a present per step on the UI thread, so the window trailed the
/// pointer and caught up after it stopped. Starting the system move from a XAML press instead loses XAML's button-up and
/// eats every second press (spec/06 ADR-96).
/// </summary>
internal static class SystemDrag
{
    /// <summary>Keeps the regions current for <paramref name="root"/>, the window's content. Cheap: only a changed layout is sent.</summary>
    public static void Attach(Window window, FrameworkElement root)
    {
        RectInt32[]? sent = null;
        root.LayoutUpdated += (_, _) =>
        {
            if (root.XamlRoot is not { } xamlRoot)
            {
                return;
            }

            var scale = xamlRoot.RasterizationScale;
            var controls = new List<RectInt32>();
            Collect(root, root, scale, controls);
            var caption = new RectInt32(0, 0, (int)Math.Ceiling(root.ActualWidth * scale), (int)Math.Ceiling(root.ActualHeight * scale));
            var next = controls.Prepend(caption).ToArray();
            if (sent is not null && sent.SequenceEqual(next))
            {
                return;
            }

            sent = next;
            var source = InputNonClientPointerSource.GetForWindowId(window.AppWindow.Id);
            source.SetRegionRects(NonClientRegionKind.Caption, [caption]);
            source.SetRegionRects(NonClientRegionKind.Passthrough, controls.ToArray());
        };
    }

    // Controls take their own clicks; panels, text and meters between them move the window.
    private static void Collect(DependencyObject element, UIElement root, double scale, List<RectInt32> rects)
    {
        var count = VisualTreeHelper.GetChildrenCount(element);
        for (var index = 0; index < count; index++)
        {
            if (VisualTreeHelper.GetChild(element, index) is not FrameworkElement child || child.Visibility != Visibility.Visible)
            {
                continue;
            }

            if (child is Control { IsHitTestVisible: true } control && control.ActualWidth > 0 && control.ActualHeight > 0)
            {
                var box = control.TransformToVisual(root).TransformBounds(new Windows.Foundation.Rect(0, 0, control.ActualWidth, control.ActualHeight));
                rects.Add(new RectInt32((int)Math.Floor(box.X * scale), (int)Math.Floor(box.Y * scale), (int)Math.Ceiling(box.Width * scale), (int)Math.Ceiling(box.Height * scale)));
                continue;
            }

            Collect(child, root, scale, rects);
        }
    }
}
