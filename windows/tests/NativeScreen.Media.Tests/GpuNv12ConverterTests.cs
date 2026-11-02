using NativeScreen.Core;
using NativeScreen.Media;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace NativeScreen.Media.Tests;

public sealed class GpuNv12ConverterTests
{
    [Fact]
    public void GpuMatchesTheCpuConverterWithinRounding()
    {
        const int Width = 64;
        const int Height = 36;
        var bgra = new byte[Width * Height * 4];
        new Random(7).NextBytes(bgra);
        for (var i = 3; i < bgra.Length; i += 4)
        {
            bgra[i] = 255;
        }

        D3D11.D3D11CreateDevice(null, DriverType.Hardware, DeviceCreationFlags.BgraSupport, [FeatureLevel.Level_11_0], out ID3D11Device? device, out _, out ID3D11DeviceContext? context).CheckError();
        using (device)
        using (context)
        {
            using var texture = device!.CreateTexture2D(new Texture2DDescription
            {
                Width = Width,
                Height = Height,
                MipLevels = 1,
                ArraySize = 1,
                Format = Format.B8G8R8A8_UNorm,
                SampleDescription = new SampleDescription(1, 0),
                Usage = ResourceUsage.Default,
                BindFlags = BindFlags.ShaderResource
            });
            context!.UpdateSubresource(bgra, texture, 0, Width * 4, 0);
            using var view = device.CreateShaderResourceView(texture);
            using var converter = new GpuNv12Converter(device, context, Width, Height);
            var gpu = new byte[Width * Height * 3 / 2];
            converter.Convert(view, gpu);
            var cpu = new byte[gpu.Length];
            Nv12Converter.FromBgra(bgra, cpu, Width, Height);
            for (var i = 0; i < gpu.Length; i++)
            {
                Assert.True(Math.Abs(gpu[i] - cpu[i]) <= 2, $"byte {i}: gpu {gpu[i]}, cpu {cpu[i]}");
            }
        }
    }
}
