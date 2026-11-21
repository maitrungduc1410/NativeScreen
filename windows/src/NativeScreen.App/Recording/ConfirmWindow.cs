using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using NativeScreen.Media;

namespace NativeScreen.App;

/// <summary>
/// A yes or no question asked from the recording bar, in a small window of its own. A ContentDialog hosted by the bar was
/// cut to the bar's height: its buttons were off screen while its overlay still took every click, so the bar froze during
/// a recording (spec/06 ADR-98). Kept out of the capture and on top, like the bar.
/// </summary>
internal sealed class ConfirmWindow : Window
{
    private const double Edge = 24;

    private readonly TaskCompletionSource<bool> answer = new();

    private ConfirmWindow(string title, string confirm, string cancel)
    {
        Title = "Native Screen";
        var body = new StackPanel { Spacing = 18, Padding = new Thickness(Edge) };
        var heading = Ui.Text(title, 15, "Ink95", true);
        heading.TextWrapping = TextWrapping.Wrap;
        body.Children.Add(heading);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        var keep = Ui.Option(cancel, false, () => Finish(false));
        buttons.Children.Add(keep);
        buttons.Children.Add(Ui.Option(confirm, true, () => Finish(true)));
        body.Children.Add(buttons);
        var content = new Grid { Background = Ui.Pal("SurfaceModal"), Children = { body } };
        content.KeyDown += (_, args) =>
        {
            if (args.Key == Windows.System.VirtualKey.Escape)
            {
                Finish(false);
            }
        };
        Content = content;
        Closed += (_, _) => answer.TrySetResult(false);
        AppTheme.Register(this);
        Ui.SizeWindow(this, 420, 130, 360, 120);
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter)
        {
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
            presenter.IsResizable = false;
            presenter.IsAlwaysOnTop = true;
        }

        CaptureTargets.SetExcludedFromCapture(WinRT.Interop.WindowNative.GetWindowHandle(this), true);
        // The safe answer has the focus, so Enter or Space does not delete by accident.
        content.Loaded += (_, _) =>
        {
            FitHeight(body);
            keep.Focus(FocusState.Programmatic);
        };
    }

    /// <summary>
    /// Sizes the client area to the text and buttons, so the buttons sit <see cref="Edge"/> from the bottom as from the right.
    /// A fixed window height counted the title bar, which left the buttons on the bottom edge.
    /// </summary>
    private void FitHeight(FrameworkElement body)
    {
        if (body.XamlRoot is not { } root)
        {
            return;
        }

        var scale = root.RasterizationScale;
        var width = AppWindow.ClientSize.Width;
        body.Measure(new Windows.Foundation.Size(width / scale, double.PositiveInfinity));
        AppWindow.ResizeClient(new Windows.Graphics.SizeInt32(width, (int)Math.Ceiling(body.DesiredSize.Height * scale)));
    }

    /// <summary>True when the user picked <paramref name="confirm"/>; closing the window or Esc is the other answer.</summary>
    public static Task<bool> Ask(string title, string confirm, string cancel)
    {
        var window = new ConfirmWindow(title, confirm, cancel);
        window.Activate();
        return window.answer.Task;
    }

    private void Finish(bool confirmed)
    {
        answer.TrySetResult(confirmed);
        Close();
    }
}
