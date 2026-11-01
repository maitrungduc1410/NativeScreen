using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace NativeScreen.Rendering;

public sealed class D3D11GraphicsDevice : IDisposable
{
    public ID3D11Device Device { get; }
    public ID3D11DeviceContext Context { get; }

    public D3D11GraphicsDevice()
    {
        FeatureLevel[] levels = [FeatureLevel.Level_11_1, FeatureLevel.Level_11_0];
        var result = D3D11.D3D11CreateDevice(
            null,
            DriverType.Hardware,
            DeviceCreationFlags.BgraSupport,
            levels,
            out ID3D11Device? device,
            out _,
            out ID3D11DeviceContext? context);
        if (result.Failure)
        {
            // VERIFY: hardware device creation. WARP is the software fallback when no GPU is available.
            result = D3D11.D3D11CreateDevice(
                null,
                DriverType.Warp,
                DeviceCreationFlags.BgraSupport,
                levels,
                out device,
                out _,
                out context);
        }

        if (result.Failure || device is null || context is null)
        {
            throw new InvalidOperationException($"D3D11CreateDevice failed ({result}).");
        }

        Device = device;
        Context = context;
    }

    public ID3D11Texture2D CreateWorkingTexture(int width, int height)
    {
        return Device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)width,
            Height = (uint)height,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.ShaderResource | BindFlags.RenderTarget | BindFlags.UnorderedAccess
        });
    }

    public void Dispose()
    {
        Context.Dispose();
        Device.Dispose();
    }
}
