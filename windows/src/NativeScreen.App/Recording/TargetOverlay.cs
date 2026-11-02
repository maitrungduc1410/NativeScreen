using System.Runtime.InteropServices;
using NativeScreen.Media;

namespace NativeScreen.App;

/// <summary>
/// The full-desktop dim layer for picking a window or dragging an area. A plain per-pixel-alpha Win32 window: WinUI has no
/// transparent windows. It runs on the UI thread, whose loop already pumps Win32 messages.
/// </summary>
internal sealed unsafe class TargetOverlay : IDisposable
{
    private const uint WsPopup = 0x80000000;
    private const uint WsExLayered = 0x00080000;
    private const uint WsExTopmost = 0x00000008;
    private const uint WsExToolWindow = 0x00000080;
    private const uint WmDestroy = 0x0002;
    private const uint WmKeyDown = 0x0100;
    private const uint WmMouseMove = 0x0200;
    private const uint WmLButtonDown = 0x0201;
    private const uint WmLButtonUp = 0x0202;
    private const uint WmRButtonDown = 0x0204;
    private const int VkEscape = 0x1B;
    private const int SwShowNoActivate = 4;
    private const int IdcCross = 32515;
    private const uint UlwAlpha = 2;
    private const int MinimumArea = 32;
    private const byte DimAlpha = 110;
    private const int BorderThickness = 3;
    private const uint BorderColor = 0xFF7C5CFC;
    private const uint LabelColor = 0xFF1C1B22;
    private const int LabelHeight = 34;
    private const int LabelPadding = 14;

    private static readonly nint ClassAtom;
    private static readonly WndProc ClassProc = StaticProc;
    private static readonly Dictionary<nint, TargetOverlay> Instances = [];

    private readonly bool pickWindow;
    private readonly PixelRect screen;
    private readonly IReadOnlyList<CaptureWindow> windows;
    private readonly Action<CaptureWindow> windowPicked;
    private readonly Action<PixelRect> areaPicked;
    private readonly Action cancelled;
    private readonly nint hwnd;
    private readonly nint memoryDc;
    private readonly nint bitmap;
    private readonly nint font;
    private readonly uint* pixels;
    private CaptureWindow? hovered;
    private (int X, int Y)? dragStart;
    private PixelRect? selection;
    private bool disposed;

    static TargetOverlay()
    {
        var name = Marshal.StringToHGlobalUni("NativeScreenTargetOverlay");
        var cls = new WndClass
        {
            Size = (uint)Marshal.SizeOf<WndClass>(),
            Proc = Marshal.GetFunctionPointerForDelegate(ClassProc),
            Instance = GetModuleHandleW(null),
            Cursor = LoadCursorW(0, IdcCross),
            ClassName = name
        };
        ClassAtom = RegisterClassExW(ref cls);
    }

    public TargetOverlay(bool pickWindow, Action<CaptureWindow> windowPicked, Action<PixelRect> areaPicked, Action cancelled)
    {
        this.pickWindow = pickWindow;
        this.windowPicked = windowPicked;
        this.areaPicked = areaPicked;
        this.cancelled = cancelled;
        screen = CaptureTargets.VirtualScreen();
        windows = pickWindow ? CaptureTargets.WindowsFrontToBack() : [];
        hwnd = CreateWindowExW(WsExLayered | WsExTopmost | WsExToolWindow, ClassAtom, null, WsPopup, screen.X, screen.Y, screen.Width, screen.Height, 0, 0, GetModuleHandleW(null), 0);
        Instances[hwnd] = this;
        CaptureTargets.SetExcludedFromCapture(hwnd, true);

        var header = new BitmapInfoHeader { Size = 40, Width = screen.Width, Height = -screen.Height, Planes = 1, BitCount = 32 };
        var screenDc = GetDC(0);
        memoryDc = CreateCompatibleDC(screenDc);
        bitmap = CreateDIBSection(screenDc, ref header, 0, out var bits, 0, 0);
        pixels = (uint*)bits;
        ReleaseDC(0, screenDc);
        SelectObject(memoryDc, bitmap);
        font = CreateFontW(-18, 0, 0, 0, 500, 0, 0, 0, 1, 0, 0, 5, 0, "Segoe UI");
        SelectObject(memoryDc, font);
        SetBkMode(memoryDc, 1);
        SetTextColor(memoryDc, 0x00FFFFFF);

        Present();
        ShowWindow(hwnd, SwShowNoActivate);
        SetForegroundWindow(hwnd);
        SetFocus(hwnd);
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        Instances.Remove(hwnd);
        DestroyWindow(hwnd);
        DeleteObject(bitmap);
        DeleteObject(font);
        DeleteDC(memoryDc);
    }

    private static nint StaticProc(nint window, uint message, nint wParam, nint lParam)
    {
        if (Instances.TryGetValue(window, out var overlay) && overlay.Handle(message, wParam, lParam))
        {
            return 0;
        }

        return DefWindowProcW(window, message, wParam, lParam);
    }

    private bool Handle(uint message, nint wParam, nint lParam)
    {
        var x = (short)(lParam & 0xFFFF) + screen.X;
        var y = (short)((lParam >> 16) & 0xFFFF) + screen.Y;
        switch (message)
        {
            case WmKeyDown when wParam == VkEscape:
            case WmRButtonDown:
                Finish(cancelled);
                return true;
            case WmMouseMove:
                Moved(x, y);
                return true;
            case WmLButtonDown:
                Pressed(x, y);
                return true;
            case WmLButtonUp:
                Released();
                return true;
            default:
                return false;
        }
    }

    private void Moved(int x, int y)
    {
        if (pickWindow)
        {
            var next = windows.FirstOrDefault(window => window.Bounds.Contains(x, y));
            if (!ReferenceEquals(next, hovered))
            {
                hovered = next;
                Present();
            }
        }
        else if (dragStart is { } start)
        {
            var left = Math.Min(start.X, x);
            var top = Math.Min(start.Y, y);
            selection = new PixelRect(left, top, Math.Abs(x - start.X), Math.Abs(y - start.Y));
            Present();
        }
    }

    private void Pressed(int x, int y)
    {
        if (pickWindow)
        {
            Moved(x, y);
            if (hovered is { } window)
            {
                Finish(() => windowPicked(window));
            }

            return;
        }

        dragStart = (x, y);
        SetCapture(hwnd);
    }

    private void Released()
    {
        if (dragStart is null)
        {
            return;
        }

        dragStart = null;
        ReleaseCapture();
        if (selection is { Width: >= MinimumArea, Height: >= MinimumArea } area)
        {
            Finish(() => areaPicked(area));
        }
    }

    private void Finish(Action result)
    {
        Dispose();
        result();
    }

    private void Present()
    {
        new Span<uint>(pixels, screen.Width * screen.Height).Fill((uint)DimAlpha << 24);
        PixelRect? hole = pickWindow ? hovered?.Bounds : selection;
        if (hole is { } rect)
        {
            // Alpha 1, not 0: a fully transparent pixel would pass clicks to the window underneath.
            FillRect(rect, 1u << 24);
            DrawBorder(rect);
            var text = pickWindow && hovered is { } window
                ? $"{window.AppName}  ·  {rect.Width} × {rect.Height}"
                : $"{rect.Width} × {rect.Height}";
            DrawLabel(rect, text);
        }
        else
        {
            var hint = pickWindow ? "Click a window to record it  ·  Esc to cancel" : "Drag to select an area  ·  Esc to cancel";
            var display = CaptureTargets.DisplayAt(screen.X + screen.Width / 2, screen.Y + screen.Height / 2).Bounds;
            DrawLabel(new PixelRect(display.X, display.Y + display.Height / 2, display.Width, 0), hint);
        }

        var position = new Point32 { X = screen.X, Y = screen.Y };
        var size = new Size32 { Cx = screen.Width, Cy = screen.Height };
        var source = default(Point32);
        var blend = new BlendFunction { SourceConstantAlpha = 255, AlphaFormat = 1 };
        UpdateLayeredWindow(hwnd, 0, ref position, ref size, memoryDc, ref source, 0, ref blend, UlwAlpha);
    }

    private void FillRect(PixelRect rect, uint color)
    {
        var left = Math.Max(0, rect.X - screen.X);
        var top = Math.Max(0, rect.Y - screen.Y);
        var right = Math.Min(screen.Width, rect.X - screen.X + rect.Width);
        var bottom = Math.Min(screen.Height, rect.Y - screen.Y + rect.Height);
        for (var y = top; y < bottom; y++)
        {
            new Span<uint>(pixels + y * screen.Width + left, Math.Max(0, right - left)).Fill(color);
        }
    }

    private void DrawBorder(PixelRect rect)
    {
        FillRect(new PixelRect(rect.X, rect.Y, rect.Width, BorderThickness), BorderColor);
        FillRect(new PixelRect(rect.X, rect.Y + rect.Height - BorderThickness, rect.Width, BorderThickness), BorderColor);
        FillRect(new PixelRect(rect.X, rect.Y, BorderThickness, rect.Height), BorderColor);
        FillRect(new PixelRect(rect.X + rect.Width - BorderThickness, rect.Y, BorderThickness, rect.Height), BorderColor);
    }

    private void DrawLabel(PixelRect around, string text)
    {
        GetTextExtentPoint32W(memoryDc, text, text.Length, out var extent);
        var width = extent.Cx + LabelPadding * 2;
        var x = around.X + (around.Width - width) / 2;
        var y = around.Y + (around.Height - LabelHeight) / 2;
        var label = new PixelRect(x, y, width, LabelHeight);
        FillRect(label, LabelColor);
        TextOutW(memoryDc, x - screen.X + LabelPadding, y - screen.Y + (LabelHeight - extent.Cy) / 2, text, text.Length);
        // GDI clears alpha where it draws text.
        var left = Math.Max(0, x - screen.X);
        var top = Math.Max(0, y - screen.Y);
        for (var row = top; row < Math.Min(screen.Height, top + LabelHeight); row++)
        {
            var line = pixels + row * screen.Width;
            for (var column = left; column < Math.Min(screen.Width, left + width); column++)
            {
                line[column] |= 0xFF000000;
            }
        }
    }

    private delegate nint WndProc(nint window, uint message, nint wParam, nint lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct WndClass
    {
        public uint Size;
        public uint Style;
        public nint Proc;
        public int ClassExtra;
        public int WindowExtra;
        public nint Instance;
        public nint Icon;
        public nint Cursor;
        public nint Background;
        public nint MenuName;
        public nint ClassName;
        public nint IconSmall;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BitmapInfoHeader
    {
        public uint Size;
        public int Width;
        public int Height;
        public ushort Planes;
        public ushort BitCount;
        public uint Compression;
        public uint SizeImage;
        public int XPelsPerMeter;
        public int YPelsPerMeter;
        public uint ClrUsed;
        public uint ClrImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point32
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Size32
    {
        public int Cx;
        public int Cy;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BlendFunction
    {
        public byte BlendOp;
        public byte BlendFlags;
        public byte SourceConstantAlpha;
        public byte AlphaFormat;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern nint GetModuleHandleW(string? name);

    [DllImport("user32.dll")]
    private static extern nint RegisterClassExW(ref WndClass cls);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern nint CreateWindowExW(uint exStyle, nint className, string? title, uint style, int x, int y, int width, int height, nint parent, nint menu, nint instance, nint param);

    [DllImport("user32.dll")]
    private static extern nint DefWindowProcW(nint window, uint message, nint wParam, nint lParam);

    [DllImport("user32.dll")]
    private static extern bool DestroyWindow(nint window);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(nint window, int command);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(nint window);

    [DllImport("user32.dll")]
    private static extern nint SetFocus(nint window);

    [DllImport("user32.dll")]
    private static extern nint SetCapture(nint window);

    [DllImport("user32.dll")]
    private static extern bool ReleaseCapture();

    [DllImport("user32.dll")]
    private static extern nint LoadCursorW(nint instance, nint name);

    [DllImport("user32.dll")]
    private static extern nint GetDC(nint window);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(nint window, nint dc);

    [DllImport("user32.dll")]
    private static extern bool UpdateLayeredWindow(nint window, nint target, ref Point32 position, ref Size32 size, nint source, ref Point32 sourcePosition, uint key, ref BlendFunction blend, uint flags);

    [DllImport("gdi32.dll")]
    private static extern nint CreateCompatibleDC(nint dc);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteDC(nint dc);

    [DllImport("gdi32.dll")]
    private static extern nint CreateDIBSection(nint dc, ref BitmapInfoHeader header, uint usage, out nint bits, nint section, uint offset);

    [DllImport("gdi32.dll")]
    private static extern nint SelectObject(nint dc, nint item);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(nint item);

    [DllImport("gdi32.dll")]
    private static extern int SetBkMode(nint dc, int mode);

    [DllImport("gdi32.dll")]
    private static extern uint SetTextColor(nint dc, uint color);

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    private static extern nint CreateFontW(int height, int width, int escapement, int orientation, int weight, uint italic, uint underline, uint strike, uint charset, uint precision, uint clip, uint quality, uint pitch, string face);

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetTextExtentPoint32W(nint dc, string text, int length, out Size32 size);

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    private static extern bool TextOutW(nint dc, int x, int y, string text, int length);
}
