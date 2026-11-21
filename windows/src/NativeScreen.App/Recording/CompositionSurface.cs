using System.Runtime.InteropServices;
using Vortice.Direct2D1;
using Vortice.Direct3D11;
using Vortice.DXGI;
using AlphaMode = Vortice.DCommon.AlphaMode;
using D2DPixelFormat = Vortice.DCommon.PixelFormat;

namespace NativeScreen.App;

/// <summary>A full-screen overlay window's pixels: drawn with Direct2D, then shown on the window.</summary>
internal interface IOverlaySurface : IDisposable
{
    ID2D1RenderTarget Target { get; }

    void Begin();

    /// <summary>Ends drawing and shows the frame on the window, which covers the screen from <c>(x, y)</c>.</summary>
    void Show(nint window, int x, int y);
}

/// <summary>
/// The overlay drawn on the GPU and shown through DirectComposition: a premultiplied-alpha swap chain as the content of the
/// window's visual, so a frame never comes back to the CPU. A 4K picker frame takes about 1 ms instead of 18 to 50 ms through
/// UpdateLayeredWindow, so its highlight can move at the display's rate (spec/06 ADR-101). The window must be made with
/// WS_EX_NOREDIRECTIONBITMAP and without WS_EX_LAYERED; it takes the mouse over its whole area, which is what the picker wants.
/// The few DirectComposition calls are made through the COM vtable: no wrapper package is referenced.
/// </summary>
internal sealed unsafe class CompositionSurface : IOverlaySurface
{
    private static readonly Guid DeviceId = new("C37EA93A-E7AA-450D-B16F-9746CB0407F3");

    private readonly ID3D11Device device;
    private readonly IDXGISwapChain1 swapChain;
    private readonly ID2D1Factory1 factory;
    private readonly ID2D1Device d2dDevice;
    private readonly ID2D1DeviceContext context;
    private readonly ID2D1Bitmap1 targetBitmap;
    private nint compositionDevice;
    private nint compositionTarget;
    private nint visual;

    private CompositionSurface(int width, int height)
    {
        Vortice.Direct3D.FeatureLevel[] levels = [Vortice.Direct3D.FeatureLevel.Level_11_1, Vortice.Direct3D.FeatureLevel.Level_11_0, Vortice.Direct3D.FeatureLevel.Level_10_1, Vortice.Direct3D.FeatureLevel.Level_10_0];
        D3D11.D3D11CreateDevice(null, Vortice.Direct3D.DriverType.Hardware, DeviceCreationFlags.BgraSupport, levels, out ID3D11Device? created).CheckError();
        device = created ?? throw new COMException("No Direct3D device");
        using var dxgiDevice = device.QueryInterface<IDXGIDevice>();
        using var adapter = dxgiDevice.GetAdapter();
        using var dxgiFactory = adapter.GetParent<IDXGIFactory2>();
        swapChain = dxgiFactory.CreateSwapChainForComposition(device, new SwapChainDescription1
        {
            Width = (uint)width,
            Height = (uint)height,
            Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            BufferUsage = Usage.RenderTargetOutput,
            BufferCount = 2,
            SwapEffect = SwapEffect.FlipSequential,
            AlphaMode = Vortice.DXGI.AlphaMode.Premultiplied
        });
        factory = D2D1.D2D1CreateFactory<ID2D1Factory1>();
        d2dDevice = factory.CreateDevice(dxgiDevice);
        context = d2dDevice.CreateDeviceContext(DeviceContextOptions.None);
        using var backBuffer = swapChain.GetBuffer<IDXGISurface>(0);
        targetBitmap = context.CreateBitmapFromDxgiSurface(backBuffer, new BitmapProperties1(
            new D2DPixelFormat(Format.B8G8R8A8_UNorm, AlphaMode.Premultiplied), 96, 96, BitmapOptions.Target | BitmapOptions.CannotDraw));
        context.Target = targetBitmap;
        var id = DeviceId;
        Check(DCompositionCreateDevice(dxgiDevice.NativePointer, &id, out compositionDevice));
    }

    public ID2D1RenderTarget Target => context;

    /// <summary>The window style a composition overlay needs: no redirection bitmap, so only the visual is shown.</summary>
    public const uint WindowExStyle = 0x00200000;

    /// <summary>The device, swap chain and composition device; null when this machine cannot. Made before the window.</summary>
    public static CompositionSurface? TryCreate(int width, int height)
    {
        try
        {
            return new CompositionSurface(width, height);
        }
        catch (Exception exception) when (exception is SharpGen.Runtime.SharpGenException or COMException or DllNotFoundException or EntryPointNotFoundException)
        {
            return null;
        }
    }

    /// <summary>Puts the swap chain on the window. False when DirectComposition refuses it; the caller then uses a layered window.</summary>
    public bool Attach(nint window)
    {
        try
        {
            nint created;
            // IDCompositionDevice::CreateTargetForHwnd (6), ::CreateVisual (7), IDCompositionVisual::SetContent (15),
            // IDCompositionTarget::SetRoot (3), IDCompositionDevice::Commit (3).
            Check(((delegate* unmanaged[Stdcall]<nint, nint, int, nint*, int>)Method(compositionDevice, 6))(compositionDevice, window, 1, &created));
            compositionTarget = created;
            Check(((delegate* unmanaged[Stdcall]<nint, nint*, int>)Method(compositionDevice, 7))(compositionDevice, &created));
            visual = created;
            Check(((delegate* unmanaged[Stdcall]<nint, nint, int>)Method(visual, 15))(visual, swapChain.NativePointer));
            Check(((delegate* unmanaged[Stdcall]<nint, nint, int>)Method(compositionTarget, 3))(compositionTarget, visual));
            Check(((delegate* unmanaged[Stdcall]<nint, int>)Method(compositionDevice, 3))(compositionDevice));
            return true;
        }
        catch (COMException)
        {
            return false;
        }
    }

    public void Begin() => context.BeginDraw();

    public void Show(nint window, int x, int y)
    {
        context.EndDraw();
        // Synced to the display; while the picker animates, this paces it at the display's rate.
        swapChain.Present(1, PresentFlags.None);
    }

    public void Dispose()
    {
        foreach (var pointer in (ReadOnlySpan<nint>)[visual, compositionTarget, compositionDevice])
        {
            if (pointer != 0)
            {
                Marshal.Release(pointer);
            }
        }

        (visual, compositionTarget, compositionDevice) = (0, 0, 0);
        targetBitmap.Dispose();
        context.Dispose();
        d2dDevice.Dispose();
        factory.Dispose();
        swapChain.Dispose();
        device.Dispose();
    }

    private static nint Method(nint instance, int slot) => (*(nint**)instance)[slot];

    private static void Check(int result)
    {
        if (result < 0)
        {
            throw new COMException("DirectComposition", result);
        }
    }

    [DllImport("dcomp.dll")]
    private static extern int DCompositionCreateDevice(nint dxgiDevice, Guid* iid, out nint device);
}
