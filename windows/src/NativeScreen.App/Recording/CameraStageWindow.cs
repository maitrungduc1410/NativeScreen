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
/// the countdown and the recording. Nothing on screen is recorded in this mode, so it is left in screenshots.
/// </summary>
internal sealed class CameraStageWindow : Window
{
    private const double WidthDip = 640;
    private const double HeightDip = 360;
    private const double TopMargin = 24;
    private const int PixelsWide = 960;
    private const int PixelsHigh = 540;
    private const long MinimumFrameMs = 30;

    private readonly Image image = new() { Stretch = Stretch.UniformToFill };
    private readonly WriteableBitmap bitmap = new(PixelsWide, PixelsHigh);
    private readonly byte[] bgra = new byte[PixelsWide * PixelsHigh * 4];
    private readonly Microsoft.UI.Dispatching.DispatcherQueue dispatcher;
    private readonly Grid root = new() { Background = Ui.Rgb(0.08, 0.08, 0.1) };
    private readonly StackPanel footer = new() { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 16) };
    private long lastFrameMs;
    private int pending;

    public CameraStageWindow(string cameraName, bool hasMicrophone, Action start)
    {
        dispatcher = DispatcherQueue;
        Title = Loc.T("Camera");
        image.Source = bitmap;
        root.Children.Add(image);
        root.Children.Add(Thirds());
        var name = Ui.Text(cameraName, 12.5);
        name.Foreground = Ui.Rgb(1, 1, 1, 0.85);
        name.Margin = new Thickness(14, 12, 0, 0);
        name.HorizontalAlignment = HorizontalAlignment.Left;
        name.VerticalAlignment = VerticalAlignment.Top;
        root.Children.Add(name);
        if (!hasMicrophone)
        {
            var warning = Ui.Text("No microphone selected. The recording will have no sound.", 12.5);
            warning.Foreground = Ui.Rgb(1, 0.62, 0.25, 1);
            warning.VerticalAlignment = VerticalAlignment.Center;
            footer.Children.Add(warning);
        }

        var record = new Button
        {
            Content = Loc.T("Start recording"),
            Background = Ui.Rgb(0.93, 0.27, 0.23, 1),
            Foreground = Ui.Rgb(1, 1, 1, 1),
            CornerRadius = new CornerRadius(16),
            Padding = new Thickness(16, 6, 16, 6)
        };
        record.Click += (_, _) => start();
        footer.Children.Add(record);
        root.Children.Add(footer);
        Content = root;
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
        var width = (int)(WidthDip * scale);
        var height = (int)(HeightDip * scale);
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(area.X + (area.Width - width) / 2, area.Y + (int)(TopMargin * scale), width, height));
    }

    /// <summary>Hides the record button once recording starts; the preview stays.</summary>
    public void SetRecording(bool recording) => footer.Visibility = recording ? Visibility.Collapsed : Visibility.Visible;

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
