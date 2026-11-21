using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using NativeScreen.Core;
using NativeScreen.Media;

namespace NativeScreen.App;

/// <summary>
/// The large preview of the Camera capture mode (spec/04, spec/06 ADR-77): the mirrored camera with thirds to frame yourself,
/// the camera's name, a warning when no microphone is chosen, and the record button. It stays up from picking the mode through
/// the countdown and the recording, and can be dragged anywhere like on macOS. Nothing on screen is recorded in this mode, so
/// it is left in screenshots.
/// </summary>
internal sealed class CameraStageWindow : Window
{
    private const double MaxWidthDip = 720;
    // Like macOS: half the screen's width at most, a little above the middle.
    private const double ScreenWidthShare = 0.5;
    private const double RaiseShare = 0.06;
    private const int PixelsWide = 960;
    private const int PixelsHigh = 540;
    private const long MinimumFrameMs = 30;
    private const string VideoGlyph = "\uE714";
    private const string MicOffGlyph = "\uEC54";
    private const string RecordGlyph = "\uE7C8";
    private static readonly Brush White = Ui.Rgb(1, 1, 1, 1);
    private static readonly Brush Purple = Ui.Rgb(0.36, 0.22, 0.98, 1);

    private readonly Image image = new() { Stretch = Stretch.UniformToFill };
    private readonly WriteableBitmap bitmap = new(PixelsWide, PixelsHigh);
    private readonly byte[] bgra = new byte[PixelsWide * PixelsHigh * 4];
    private readonly Microsoft.UI.Dispatching.DispatcherQueue dispatcher;
    private readonly Grid root = new() { Background = Ui.Rgb(0.08, 0.08, 0.1) };
    private readonly StackPanel footer = new() { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 32) };
    private readonly Border noMicrophone;
    private readonly Border cameraName;
    private readonly Grid thirds = Thirds();
    private long lastFrameMs;
    private int pending;

    /// <param name="escape">Esc pressed in this window; the bar decides what it closes (nothing while recording).</param>
    public CameraStageWindow(string cameraName, bool hasMicrophone, Action start, Action escape)
    {
        dispatcher = DispatcherQueue;
        Title = Loc.T("Camera");
        image.Source = bitmap;
        root.Children.Add(image);
        root.Children.Add(thirds);
        this.cameraName = Pill(VideoGlyph, cameraName, 0.45);
        this.cameraName.Margin = new Thickness(26, 26, 0, 0);
        this.cameraName.HorizontalAlignment = HorizontalAlignment.Left;
        this.cameraName.VerticalAlignment = VerticalAlignment.Top;
        root.Children.Add(this.cameraName);
        noMicrophone = Pill(MicOffGlyph, Loc.T("No microphone selected. The recording will have no sound."), 0.55);
        noMicrophone.HorizontalAlignment = HorizontalAlignment.Center;
        footer.Children.Add(noMicrophone);
        SetHasMicrophone(hasMicrophone);

        var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        label.Children.Add(Ui.Icon(RecordGlyph, 15, White));
        label.Children.Add(new TextBlock { Text = Loc.T("Start recording"), FontSize = 14, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = White });
        var record = new Button
        {
            Content = label,
            Background = Purple,
            Foreground = White,
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(18, 10, 18, 10),
            HorizontalAlignment = HorizontalAlignment.Center
        };
        // Keep it purple under the pointer and when pressed instead of the theme's grey.
        record.Resources["ButtonBackgroundPointerOver"] = Ui.Rgb(0.42, 0.29, 1, 1);
        record.Resources["ButtonBackgroundPressed"] = Ui.Rgb(0.31, 0.18, 0.86, 1);
        record.Resources["ButtonForegroundPointerOver"] = White;
        record.Resources["ButtonForegroundPressed"] = White;
        record.Click += (_, _) => start();
        footer.Children.Add(record);
        root.Children.Add(footer);
        // The picture and the labels move the window; the button takes its own clicks.
        SystemDrag.Attach(this, root);
        // A click on the picture lands in the drag region, which gives nothing in the window the keyboard focus, so Esc went
        // nowhere. A focusable host takes the focus whenever the window is activated and hands Esc to the bar.
        var host = new ContentControl
        {
            Content = root,
            IsTabStop = true,
            UseSystemFocusVisuals = false,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch
        };
        host.KeyDown += (_, args) =>
        {
            if (args.Key == Windows.System.VirtualKey.Escape)
            {
                args.Handled = true;
                escape();
            }
        };
        Activated += (_, args) =>
        {
            if (args.WindowActivationState != WindowActivationState.Deactivated)
            {
                host.Focus(FocusState.Programmatic);
            }
        };
        Content = host;
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.SetBorderAndTitleBar(false, false);
            presenter.IsAlwaysOnTop = true;
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
        }

        var handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        RecordingHudWindow.RemoveWindowFrame(handle);
        AppWindow.IsShownInSwitchers = false;
        var scale = GetDpiForWindow(handle) / 96.0;
        var area = DisplayArea.Primary.WorkArea;
        var width = (int)Math.Min(MaxWidthDip * scale, area.Width * ScreenWidthShare);
        var height = width * PixelsHigh / PixelsWide;
        var top = area.Y + (area.Height - height) / 2 - (int)(area.Height * RaiseShare);
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(area.X + (area.Width - width) / 2, Math.Max(area.Y, top), width, height));
    }

    /// <summary>Shows the warning while no microphone is chosen; the bar calls it whenever the choice changes.</summary>
    public void SetHasMicrophone(bool hasMicrophone) => noMicrophone.Visibility = hasMicrophone ? Visibility.Collapsed : Visibility.Visible;

    /// <summary>Hides the record button, the name and the thirds once recording starts; the preview stays.</summary>
    public void SetRecording(bool recording)
    {
        var idle = recording ? Visibility.Collapsed : Visibility.Visible;
        footer.Visibility = idle;
        cameraName.Visibility = idle;
        thirds.Visibility = idle;
    }

    /// <summary>On a camera thread. A frame is dropped while the last one is still on its way to the screen.</summary>
    public void ShowFrame(byte[] nv12, int width, int height)
    {
        var now = Environment.TickCount64;
        if (now - lastFrameMs < MinimumFrameMs || Interlocked.CompareExchange(ref pending, 1, 0) != 0)
        {
            return;
        }

        lastFrameMs = now;
        CameraPreviewPixels.ToMirroredFill(nv12, width, height, bgra, PixelsWide, PixelsHigh);
        if (!dispatcher.TryEnqueue(Present))
        {
            Volatile.Write(ref pending, 0);
        }
    }

    private void Present()
    {
        using (var stream = bitmap.PixelBuffer.AsStream())
        {
            stream.Write(bgra, 0, bgra.Length);
        }

        bitmap.Invalidate();
        Volatile.Write(ref pending, 0);
    }

    /// <summary>A label with an icon on a dark capsule, readable over any picture.</summary>
    private static Border Pill(string glyph, string text, double darkness)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        row.Children.Add(Ui.Icon(glyph, 12, White));
        row.Children.Add(new TextBlock { Text = text, FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.Medium, Foreground = White, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1 });
        return new Border { Child = row, Background = Ui.Rgb(0, 0, 0, darkness), CornerRadius = new CornerRadius(12), Padding = new Thickness(10, 5, 10, 5) };
    }

    /// <summary>Lines at a third and two thirds, to frame yourself with.</summary>
    private static Grid Thirds()
    {
        var grid = new Grid { IsHitTestVisible = false };
        for (var i = 0; i < 3; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition());
            grid.RowDefinitions.Add(new RowDefinition());
        }

        var line = Ui.Rgb(1, 1, 1, 0.22);
        for (var i = 0; i < 2; i++)
        {
            var vertical = new Border { BorderBrush = line, BorderThickness = new Thickness(0, 0, 1, 0) };
            Grid.SetColumn(vertical, i);
            Grid.SetRowSpan(vertical, 3);
            grid.Children.Add(vertical);
            var horizontal = new Border { BorderBrush = line, BorderThickness = new Thickness(0, 0, 0, 1) };
            Grid.SetRow(horizontal, i);
            Grid.SetColumnSpan(horizontal, 3);
            grid.Children.Add(horizontal);
        }

        return grid;
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint hwnd);
}
