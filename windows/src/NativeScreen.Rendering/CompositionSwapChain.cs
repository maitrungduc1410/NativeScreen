using Vortice.Direct3D11;
using Vortice.DXGI;

namespace NativeScreen.Rendering;

public sealed class CompositionSwapChain : IDisposable
{
    public IDXGISwapChain1 SwapChain { get; }
    public nint LatencyWaitable { get; }

    public CompositionSwapChain(ID3D11Device device, int width, int height)
    {
        using var dxgiDevice = device.QueryInterface<IDXGIDevice>();
        using var adapter = dxgiDevice.GetAdapter();
        using var factory = adapter.GetParent<IDXGIFactory2>();
        var description = new SwapChainDescription1
        {
            Width = (uint)width,
            Height = (uint)height,
            Format = Format.B8G8R8A8_UNorm,
            Stereo = false,
            SampleDescription = new SampleDescription(1, 0),
            BufferUsage = Usage.RenderTargetOutput,
            BufferCount = 2,
            Scaling = Scaling.Stretch,
            SwapEffect = SwapEffect.FlipDiscard,
            AlphaMode = AlphaMode.Premultiplied,
            Flags = SwapChainFlags.FrameLatencyWaitableObject
        };
        SwapChain = factory.CreateSwapChainForComposition(device, description);
        using var swapChain2 = SwapChain.QueryInterface<IDXGISwapChain2>();
        swapChain2.MaximumFrameLatency = 1;
        LatencyWaitable = swapChain2.FrameLatencyWaitableObject;
        // VERIFY: the WinUI preview calls ISwapChainPanelNative.SetSwapChain on the UI thread.
        // Present(0) stays on the render thread. Do not call ResizeBuffers on the UI thread.
    }

    public void Present() => SwapChain.Present(1, PresentFlags.None).CheckError();

    // Buffers hold physical pixels; the inverse transform stops the panel scaling them a second time.
    public void Resize(int width, int height, float rasterScale)
    {
        SwapChain.ResizeBuffers(2, (uint)width, (uint)height, Format.B8G8R8A8_UNorm, SwapChainFlags.FrameLatencyWaitableObject).CheckError();
        using var swapChain2 = SwapChain.QueryInterface<IDXGISwapChain2>();
        swapChain2.MatrixTransform = System.Numerics.Matrix3x2.CreateScale(1 / rasterScale);
    }

    public void Dispose() => SwapChain.Dispose();
}
