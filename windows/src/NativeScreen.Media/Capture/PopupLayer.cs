using System.Diagnostics;
using System.Runtime.InteropServices;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using RawRect = Vortice.RawRect;

namespace NativeScreen.Media;

/// <summary>
/// The popups a window capture leaves out, put back from the screen (spec/06 ADR-106). Windows.Graphics.Capture of one window
/// drops every tool window, owned or not: Win32 menus and ComboBox lists, tooltips, all WPF popups, a Chromium &lt;select&gt;
/// (windows/tools/PopupCaptureSpike). None of them can be captured on its own, but a capture of the monitor shows them where
/// they are. While a visible tool window of the recorded window's process overlaps it, the monitor is captured too and the
/// popup's rectangle is copied over the window's picture; nothing runs otherwise. A monitor capture, not Desktop Duplication:
/// where Windows draws the pointer in software, Desktop Duplication has it in the picture, and the real pointer showed next
/// to the drawn cursor over a popup. The monitor capture leaves the pointer out and this app's windows excluded from capture
/// too. Used on the capture thread only.
/// </summary>
internal sealed class PopupLayer : IDisposable
{
    private const int ScanIntervalMs = 50;
    private const int IdleReleaseMs = 2000;
    // The yellow capture border Windows 10 draws on the window's edge is on the screen, so the copy stays off the edge.
    private const int EdgeInset = 3;
    private const uint ToolWindow = 0x80;
    private const uint ExcludeFromCapture = 0x11;

    private readonly ID3D11Device device;
    private readonly ID3D11DeviceContext context;
    private readonly IDirect3DDevice captureDevice;
    private readonly nint window;
    private readonly uint processId;
    private readonly List<nint> popups = [];
    private readonly List<RawRect> rects = [];
    private Direct3D11CaptureFramePool? pool;
    private GraphicsCaptureSession? session;
    private ID3D11Texture2D? desktop;
    private RawRect outputBounds;
    private long lastScan;
    private long lastSeen;
    private bool disabled;
    private bool hasDesktop;

    public PopupLayer(ID3D11Device device, ID3D11DeviceContext context, IDirect3DDevice captureDevice, nint window)
    {
        this.device = device;
        this.context = context;
        this.captureDevice = captureDevice;
        this.window = window;
        GetWindowThreadProcessId(window, out processId);
    }

    /// <summary>A popup is over the window and its pixels can be read: frames should come at the screen's rate.</summary>
    public bool Active => !disabled && popups.Count > 0 && hasDesktop;

    /// <summary>
    /// Looks for popups (at most every 50 ms) and reads a new screen image when there is one. Returns true when the popups'
    /// pixels changed since the last call, so a frame is worth writing even if the window itself sent none.
    /// </summary>
    public bool Update()
    {
        if (disabled)
        {
            return false;
        }

        var now = Stopwatch.GetTimestamp();
        if ((now - lastScan) * 1000 / Stopwatch.Frequency >= ScanIntervalMs)
        {
            lastScan = now;
            Scan();
        }

        if (popups.Count == 0)
        {
            if (session is not null && (now - lastSeen) * 1000 / Stopwatch.Frequency >= IdleReleaseMs)
            {
                Release();
            }

            return false;
        }

        lastSeen = now;
        var changed = Refresh();
        return ReadScreen() || changed;
    }

    /// <summary>Copies each popup's rectangle from the screen image over <paramref name="target"/>, the window's picture.</summary>
    public void Overlay(ID3D11Texture2D target, int targetWidth, int targetHeight)
    {
        if (!Active || desktop is null || DwmGetWindowAttribute(window, 9, out RawRect origin, Marshal.SizeOf<RawRect>()) != 0)
        {
            return;
        }

        var inner = new RawRect(origin.Left + EdgeInset, origin.Top + EdgeInset, Math.Min(origin.Right, origin.Left + targetWidth) - EdgeInset, Math.Min(origin.Bottom, origin.Top + targetHeight) - EdgeInset);
        foreach (var rect in rects)
        {
            var left = Math.Max(Math.Max(rect.Left, inner.Left), outputBounds.Left);
            var top = Math.Max(Math.Max(rect.Top, inner.Top), outputBounds.Top);
            var right = Math.Min(Math.Min(rect.Right, inner.Right), outputBounds.Right);
            var bottom = Math.Min(Math.Min(rect.Bottom, inner.Bottom), outputBounds.Bottom);
            if (right <= left || bottom <= top)
            {
                continue;
            }

            var source = new Box(left - outputBounds.Left, top - outputBounds.Top, 0, right - outputBounds.Left, bottom - outputBounds.Top, 1);
            context.CopySubresourceRegion(target, 0, (uint)(left - origin.Left), (uint)(top - origin.Top), 0, desktop, 0, source);
        }
    }

    public void Dispose() => Release();

    /// <summary>The visible tool windows of the recorded window's process that overlap it.</summary>
    private void Scan()
    {
        popups.Clear();
        if (DwmGetWindowAttribute(window, 9, out RawRect bounds, Marshal.SizeOf<RawRect>()) != 0)
        {
            return;
        }

        EnumWindows((handle, _) =>
        {
            if (handle == window || !IsWindowVisible(handle) || IsIconic(handle))
            {
                return true;
            }

            GetWindowThreadProcessId(handle, out var owner);
            if (owner != processId || ((uint)GetWindowLongPtrW(handle, -20) & ToolWindow) == 0)
            {
                return true;
            }

            if (DwmGetWindowAttribute(handle, 14, out int cloaked, 4) == 0 && cloaked != 0)
            {
                return true;
            }

            if (GetWindowDisplayAffinity(handle, out var affinity) && affinity == ExcludeFromCapture)
            {
                return true;
            }

            if (GetWindowRect(handle, out var rect) && rect.Left < bounds.Right && rect.Right > bounds.Left && rect.Top < bounds.Bottom && rect.Bottom > bounds.Top)
            {
                popups.Add(handle);
            }

            return true;
        }, 0);
        // EnumWindows lists from the top; drawn from the bottom so the top popup ends up on top.
        popups.Reverse();
    }

    /// <summary>The popups' rectangles now; true when one moved, appeared or went.</summary>
    private bool Refresh()
    {
        var changed = rects.Count != popups.Count;
        for (var index = 0; index < popups.Count; index++)
        {
            GetWindowRect(popups[index], out var rect);
            if (index < rects.Count)
            {
                changed |= !rects[index].Equals(rect);
                rects[index] = rect;
            }
            else
            {
                rects.Add(rect);
            }
        }

        if (rects.Count > popups.Count)
        {
            rects.RemoveRange(popups.Count, rects.Count - popups.Count);
        }

        return changed;
    }

    /// <summary>Takes the newest screen image, if the screen changed. True when there is a new one.</summary>
    private bool ReadScreen()
    {
        try
        {
            if (session is null && !CaptureMonitor())
            {
                return false;
            }

            var changed = false;
            while (pool!.TryGetNextFrame() is { } frame)
            {
                using (frame)
                using (var texture = ScreenRecorder.TextureOf(frame))
                {
                    var size = frame.ContentSize;
                    var box = new Box(0, 0, 0, Math.Min(size.Width, outputBounds.Right - outputBounds.Left), Math.Min(size.Height, outputBounds.Bottom - outputBounds.Top), 1);
                    context.CopySubresourceRegion(desktop!, 0, 0, 0, 0, texture, 0, box);
                    hasDesktop = true;
                    changed = true;
                }
            }

            return changed;
        }
        catch (Exception exception) when (exception is SharpGen.Runtime.SharpGenException or COMException or ArgumentException)
        {
            Release();
            disabled = true;
            return false;
        }
    }

    /// <summary>Captures the monitor the window is on, without the pointer.</summary>
    private bool CaptureMonitor()
    {
        var monitor = MonitorFromWindow(window, 2);
        var info = new MonitorInfo { Size = (uint)Marshal.SizeOf<MonitorInfo>() };
        if (monitor == 0 || !GetMonitorInfoW(monitor, ref info))
        {
            disabled = true;
            return false;
        }

        outputBounds = info.Monitor;
        var item = CaptureItemInterop.ForMonitor(monitor);
        desktop = device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)(outputBounds.Right - outputBounds.Left),
            Height = (uint)(outputBounds.Bottom - outputBounds.Top),
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default
        });
        pool = Direct3D11CaptureFramePool.CreateFreeThreaded(captureDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, item.Size);
        session = pool.CreateCaptureSession(item);
        session.IsCursorCaptureEnabled = false;
        ScreenRecorder.TrySetBorderless(session);
        session.StartCapture();
        hasDesktop = false;
        return true;
    }

    private void Release()
    {
        session?.Dispose();
        session = null;
        pool?.Dispose();
        pool = null;
        desktop?.Dispose();
        desktop = null;
        hasDesktop = false;
    }

    private delegate bool EnumProc(nint handle, nint parameter);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumWindows(EnumProc proc, nint parameter);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(nint handle, out uint process);

    [DllImport("user32.dll")]
    private static extern nint GetWindowLongPtrW(nint handle, int index);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(nint handle);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsIconic(nint handle);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(nint handle, out RawRect rect);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowDisplayAffinity(nint handle, out uint affinity);

    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo
    {
        public uint Size;
        public RawRect Monitor;
        public RawRect Work;
        public uint Flags;
    }

    [DllImport("user32.dll")]
    private static extern nint MonitorFromWindow(nint window, uint flags);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetMonitorInfoW(nint monitor, ref MonitorInfo info);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(nint handle, int attribute, out RawRect value, int size);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(nint handle, int attribute, out int value, int size);
}
