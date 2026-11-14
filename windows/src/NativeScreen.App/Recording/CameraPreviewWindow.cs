using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using NativeScreen.Core;
using NativeScreen.Media;

namespace NativeScreen.App;

/// <summary>The floating camera preview: a draggable square left out of recordings, mirrored like on macOS.</summary>
internal sealed class CameraPreviewWindow : Window
{
    private const double SizeDip = 196;
    private const double LeftMargin = 50;
    private const double BottomMargin = 134;
    private const int Pixels = 392;
    private const long MinimumFrameMs = 30;

    private readonly Image image = new() { Stretch = Stretch.Fill };
    private readonly Grid root = new() { Background = Ui.Rgb(0.12, 0.13, 0.16) };
    private readonly WriteableBitmap bitmap = new(Pixels, Pixels);
    private readonly byte[] bgra = new byte[Pixels * Pixels * 4];
    private readonly Microsoft.UI.Dispatching.DispatcherQueue dispatcher;
    private long lastFrameMs;
    private int pending;

    public CameraPreviewWindow()
    {
        // A frame can still arrive while the window closes, when its own queue is no longer reachable.
        dispatcher = DispatcherQueue;
        Title = Loc.T("Native Screen Camera Preview");
        image.Source = bitmap;
        root.Children.Add(image);
        root.Children.Add(new Border { BorderThickness = new Thickness(1), BorderBrush = Ui.Rgb(1, 1, 1, 0.18), IsHitTestVisible = false });
        SystemDrag.Attach(this, root);
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
        CaptureTargets.SetExcludedFromCapture(handle, true);
        var scale = GetDpiForWindow(handle) / 96.0;
        var area = DisplayArea.Primary.WorkArea;
        var side = (int)(SizeDip * scale);
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(
            area.X + (int)(LeftMargin * scale),
            area.Y + area.Height - side - (int)(BottomMargin * scale),
            side,
            side));
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
        CameraPreviewPixels.ToMirroredSquare(nv12, width, height, bgra, Pixels);
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


    [StructLayout(LayoutKind.Sequential)]
    private struct Point32
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint hwnd);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out Point32 point);
}
