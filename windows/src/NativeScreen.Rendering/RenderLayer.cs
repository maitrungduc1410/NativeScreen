using Vortice.Direct3D11;
using Vortice.DXGI;

namespace NativeScreen.Rendering;

/// <summary>A premultiplied BGRA surface the compositor can draw into and sample from.</summary>
public sealed class RenderLayer : IDisposable
{
    public ID3D11Texture2D Texture { get; }
    public ID3D11ShaderResourceView View { get; }
    public ID3D11RenderTargetView Target { get; }
    public ID3D11UnorderedAccessView Unordered { get; }
    public int Width { get; }
    public int Height { get; }

    public RenderLayer(ID3D11Device device, int width, int height)
    {
        Width = width;
        Height = height;
        Texture = device.CreateTexture2D(new Texture2DDescription
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
        View = device.CreateShaderResourceView(Texture);
        Target = device.CreateRenderTargetView(Texture);
        Unordered = device.CreateUnorderedAccessView(Texture);
    }

    public void Dispose()
    {
        Unordered.Dispose();
        Target.Dispose();
        View.Dispose();
        Texture.Dispose();
    }
}
