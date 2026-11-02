using System.Runtime.InteropServices;
using NativeScreen.Media;
using Vortice.Direct2D1;
using Vortice.DXGI;
using AlphaMode = Vortice.DCommon.AlphaMode;
using D2DPixelFormat = Vortice.DCommon.PixelFormat;
using PixelRect = NativeScreen.Media.PixelRect;

namespace NativeScreen.App;

/// <summary>
/// The dashed frame around the recorded area while recording. It takes no input and is kept out of the capture, so it only
/// tells the person what is being recorded. Drawn once: nothing changes until recording stops.
/// </summary>
internal sealed class RecordedAreaHighlight : IDisposable
{
    private const uint WsPopup = 0x80000000;
    private const uint WsExFrame = 0x00080000 | 0x00000008 | 0x00000080 | 0x00000020 | 0x08000000; // layered, topmost, tool, transparent, no activate
    private const int ShowNoActivate = 4;
    private const uint UlwAlpha = 2;
    private const double OutsetDips = 3;
    private const double CornerDips = 12;
    private const double LineDips = 2;

    private nint hwnd;

    public RecordedAreaHighlight(PixelRect rect, double scale)
    {
        var outset = (int)Math.Round(OutsetDips * scale);
        var width = rect.Width + outset * 2;
        var height = rect.Height + outset * 2;
        hwnd = CreateWindowExW(WsExFrame, "STATIC", null, WsPopup, rect.X - outset, rect.Y - outset, width, height, 0, 0, 0, 0);
        CaptureTargets.SetExcludedFromCapture(hwnd, true);

        var header = new BitmapInfoHeader { Size = 40, Width = width, Height = -height, Planes = 1, BitCount = 32 };
        var screenDc = GetDC(0);
        var memoryDc = CreateCompatibleDC(screenDc);
        var bitmap = CreateDIBSection(screenDc, ref header, 0, out _, 0, 0);
        var previous = SelectObject(memoryDc, bitmap);
        using (var factory = D2D1.D2D1CreateFactory<ID2D1Factory>())
        using (var target = factory.CreateDCRenderTarget(new RenderTargetProperties(new D2DPixelFormat(Format.B8G8R8A8_UNorm, AlphaMode.Premultiplied))))
        {
            target.BindDC(memoryDc, new Vortice.RawRect(0, 0, width, height));
            target.BeginDraw();
            using var brush = target.CreateSolidColorBrush(new Vortice.Mathematics.Color4(0.345f, 0.337f, 0.839f, 0.65f));
            using var dashes = factory.CreateStrokeStyle(new StrokeStyleProperties { DashStyle = DashStyle.Custom, DashCap = CapStyle.Flat }, [3f, 2f]);
            var line = (float)(LineDips * scale);
            var corner = (float)(CornerDips * scale);
            target.DrawRoundedRectangle(
                new RoundedRectangle(new System.Drawing.RectangleF(line / 2, line / 2, width - line, height - line), corner, corner),
                brush,
                line,
                dashes);
            target.EndDraw();
        }

        var position = new Point32 { X = rect.X - outset, Y = rect.Y - outset };
        var size = new Size32 { Width = width, Height = height };
        var source = new Point32();
        var blend = new BlendFunction { AlphaFormat = 1, SourceConstantAlpha = 255 };
        UpdateLayeredWindow(hwnd, 0, ref position, ref size, memoryDc, ref source, 0, ref blend, UlwAlpha);
        ShowWindow(hwnd, ShowNoActivate);
        SelectObject(memoryDc, previous);
        DeleteObject(bitmap);
        DeleteDC(memoryDc);
        ReleaseDC(0, screenDc);
    }

    public void Dispose()
    {
        if (hwnd != 0)
        {
            DestroyWindow(hwnd);
            hwnd = 0;
        }
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
        public int Width;
        public int Height;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BlendFunction
    {
        public byte BlendOp;
        public byte BlendFlags;
        public byte SourceConstantAlpha;
        public byte AlphaFormat;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint CreateWindowExW(uint exStyle, string className, string? title, uint style, int x, int y, int width, int height, nint parent, nint menu, nint instance, nint param);

    [DllImport("user32.dll")]
    private static extern bool DestroyWindow(nint window);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(nint window, int command);

    [DllImport("user32.dll")]
    private static extern nint GetDC(nint window);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(nint window, nint dc);

    [DllImport("user32.dll", SetLastError = true)]
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
}
