using System.Runtime.InteropServices;
using Vortice.Direct2D1;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using AlphaMode = Vortice.DCommon.AlphaMode;
using D2DPixelFormat = Vortice.DCommon.PixelFormat;

namespace NativeScreen.App;

/// <summary>
/// Where a full-screen per-pixel-alpha window (the target picker, the live drawing overlay) is drawn with Direct2D before
/// UpdateLayeredWindow shows it. On the GPU when it can: a GDI-compatible D3D11 texture whose DC goes to the window. Software
/// Direct2D on a DIB took 33 to 50 ms per 4K frame, too slow to animate the picker's highlight (spec/06 ADR-101). Falls back
/// to that software path when no hardware device can be made.
/// </summary>
internal sealed class LayeredSurface : IOverlaySurface
{
    private const uint UlwAlpha = 2;

    private readonly int width;
    private readonly int height;
    private readonly ID2D1Factory1 factory;
    private readonly ID3D11Device? device;
    private readonly ID2D1Device? d2dDevice;
    private readonly ID2D1DeviceContext? context;
    private readonly ID3D11Texture2D? texture;
    private readonly IDXGISurface1? surface;
    private readonly ID2D1Bitmap1? targetBitmap;
    private readonly ID2D1DCRenderTarget? software;
    private readonly nint memoryDc;
    private readonly nint bitmap;

    public LayeredSurface(int width, int height)
    {
        this.width = width;
        this.height = height;
        factory = D2D1.D2D1CreateFactory<ID2D1Factory1>();
        try
        {
            Vortice.Direct3D.FeatureLevel[] levels = [Vortice.Direct3D.FeatureLevel.Level_11_1, Vortice.Direct3D.FeatureLevel.Level_11_0, Vortice.Direct3D.FeatureLevel.Level_10_1, Vortice.Direct3D.FeatureLevel.Level_10_0];
            D3D11.D3D11CreateDevice(null, DriverType.Hardware, DeviceCreationFlags.BgraSupport, levels, out device).CheckError();
            texture = device!.CreateTexture2D(new Texture2DDescription
            {
                Width = (uint)width,
                Height = (uint)height,
                MipLevels = 1,
                ArraySize = 1,
                Format = Format.B8G8R8A8_UNorm,
                SampleDescription = new SampleDescription(1, 0),
                Usage = ResourceUsage.Default,
                BindFlags = BindFlags.RenderTarget | BindFlags.ShaderResource,
                MiscFlags = ResourceOptionFlags.GdiCompatible
            });
            surface = texture.QueryInterface<IDXGISurface1>();
            using var dxgiDevice = device.QueryInterface<IDXGIDevice>();
            d2dDevice = factory.CreateDevice(dxgiDevice);
            context = d2dDevice.CreateDeviceContext(DeviceContextOptions.None);
            targetBitmap = context.CreateBitmapFromDxgiSurface(surface, new BitmapProperties1(
                new D2DPixelFormat(Format.B8G8R8A8_UNorm, AlphaMode.Premultiplied), 96, 96, BitmapOptions.Target | BitmapOptions.GdiCompatible));
            context.Target = targetBitmap;
            Target = context;
            IsHardware = true;
        }
        catch (Exception exception) when (exception is SharpGen.Runtime.SharpGenException or COMException or NullReferenceException)
        {
            targetBitmap?.Dispose();
            context?.Dispose();
            d2dDevice?.Dispose();
            surface?.Dispose();
            texture?.Dispose();
            device?.Dispose();
            (targetBitmap, context, d2dDevice, surface, texture, device) = (null, null, null, null, null, null);
            var header = new BitmapInfoHeader { Size = 40, Width = width, Height = -height, Planes = 1, BitCount = 32 };
            var screenDc = GetDC(0);
            memoryDc = CreateCompatibleDC(screenDc);
            bitmap = CreateDIBSection(screenDc, ref header, 0, out _, 0, 0);
            ReleaseDC(0, screenDc);
            SelectObject(memoryDc, bitmap);
            software = factory.CreateDCRenderTarget(new RenderTargetProperties(new D2DPixelFormat(Format.B8G8R8A8_UNorm, AlphaMode.Premultiplied)));
            Target = software;
        }
    }

    /// <summary>What to draw on, between <see cref="Begin"/> and <see cref="Show"/>.</summary>
    public ID2D1RenderTarget Target { get; }

    public bool IsHardware { get; }

    public void Begin()
    {
        software?.BindDC(memoryDc, new Vortice.RawRect(0, 0, width, height));
        Target.BeginDraw();
    }

    /// <summary>Ends drawing and puts the pixels on the window, which covers <c>(x, y, width, height)</c> on the screen.</summary>
    public void Show(nint window, int x, int y)
    {
        Target.EndDraw();
        var position = new Point32 { X = x, Y = y };
        var size = new Size32 { Cx = width, Cy = height };
        var source = default(Point32);
        var blend = new BlendFunction { SourceConstantAlpha = 255, AlphaFormat = 1 };
        if (surface is null)
        {
            UpdateLayeredWindow(window, 0, ref position, ref size, memoryDc, ref source, 0, ref blend, UlwAlpha);
            return;
        }

        var dc = surface.GetDC(false);
        try
        {
            UpdateLayeredWindow(window, 0, ref position, ref size, dc, ref source, 0, ref blend, UlwAlpha);
        }
        finally
        {
            surface.ReleaseDC(null);
        }
    }

    public void Dispose()
    {
        targetBitmap?.Dispose();
        context?.Dispose();
        d2dDevice?.Dispose();
        surface?.Dispose();
        texture?.Dispose();
        device?.Dispose();
        software?.Dispose();
        if (bitmap != 0)
        {
            DeleteObject(bitmap);
            DeleteDC(memoryDc);
        }

        factory.Dispose();
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

    [DllImport("user32.dll")]
    private static extern bool UpdateLayeredWindow(nint window, nint destinationDc, ref Point32 position, ref Size32 size, nint sourceDc, ref Point32 source, uint key, ref BlendFunction blend, uint flags);

    [DllImport("user32.dll")]
    private static extern nint GetDC(nint window);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(nint window, nint dc);

    [DllImport("gdi32.dll")]
    private static extern nint CreateCompatibleDC(nint dc);

    [DllImport("gdi32.dll")]
    private static extern nint CreateDIBSection(nint dc, ref BitmapInfoHeader header, uint usage, out nint bits, nint section, uint offset);

    [DllImport("gdi32.dll")]
    private static extern nint SelectObject(nint dc, nint item);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(nint item);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteDC(nint dc);
}
