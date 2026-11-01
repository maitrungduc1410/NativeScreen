using System.Numerics;
using System.Runtime.InteropServices;
using NativeScreen.Core;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace NativeScreen.Rendering;

public sealed partial class FrameCompositor
{
    private readonly Dictionary<string, Nv12Upload> nv12Uploads = [];

    /// <summary>Uploads a frame once and converts it to BGRA with the BT.709 limited-range shader.</summary>
    private ID3D11ShaderResourceView Nv12View(string name, VideoFrame frame)
    {
        if (!nv12Uploads.TryGetValue(name, out var upload) || upload.Width != frame.Width || upload.Height != frame.Height)
        {
            upload?.Dispose();
            upload = new Nv12Upload(_graphics.Device, frame.Width, frame.Height);
            nv12Uploads[name] = upload;
        }

        var layer = Layer(name, frame.Width, frame.Height);
        if (ReferenceEquals(upload.Current, frame))
        {
            return layer.View;
        }

        upload.Current = frame;
        var context = _graphics.Context;
        CopyNv12(context, upload.Texture, frame);
        BindTarget(layer);
        context.OMSetBlendState(null);
        context.PSSetShader(_nv12);
        context.PSSetShaderResources(0, [upload.Luma, upload.Chroma]);
        context.UpdateSubresource(new Vector4(1f / frame.Width, 1f / frame.Height, 0, 0), upload.Constants);
        context.PSSetConstantBuffer(0, upload.Constants);
        context.Draw(3, 0);
        context.PSSetShaderResources(0, [null!, null!]);
        context.UnsetRenderTargets();
        return layer.View;
    }

    private static void CopyNv12(ID3D11DeviceContext context, ID3D11Texture2D texture, VideoFrame frame)
    {
        var mapped = context.Map(texture, 0, MapMode.WriteDiscard);
        try
        {
            var pitch = (nint)mapped.RowPitch;
            for (var y = 0; y < frame.Height; y++)
            {
                Marshal.Copy(frame.Nv12, y * frame.Width, mapped.DataPointer + y * pitch, frame.Width);
            }

            // NV12 keeps the chroma rows straight after the luma rows in the mapped subresource.
            var chroma = mapped.DataPointer + frame.Height * pitch;
            var offset = frame.Width * frame.Height;
            for (var y = 0; y < frame.Height / 2; y++)
            {
                Marshal.Copy(frame.Nv12, offset + y * frame.Width, chroma + y * pitch, frame.Width);
            }
        }
        finally
        {
            context.Unmap(texture, 0);
        }
    }

    private sealed class Nv12Upload : IDisposable
    {
        public ID3D11Texture2D Texture { get; }
        public ID3D11ShaderResourceView Luma { get; }
        public ID3D11ShaderResourceView Chroma { get; }
        public ID3D11Buffer Constants { get; }
        public int Width { get; }
        public int Height { get; }
        public VideoFrame? Current { get; set; }

        public Nv12Upload(ID3D11Device device, int width, int height)
        {
            Width = width;
            Height = height;
            Texture = device.CreateTexture2D(new Texture2DDescription
            {
                Width = (uint)width,
                Height = (uint)height,
                MipLevels = 1,
                ArraySize = 1,
                Format = Format.NV12,
                SampleDescription = new SampleDescription(1, 0),
                Usage = ResourceUsage.Dynamic,
                BindFlags = BindFlags.ShaderResource,
                CPUAccessFlags = CpuAccessFlags.Write
            });
            Luma = device.CreateShaderResourceView(Texture, new ShaderResourceViewDescription(Texture, ShaderResourceViewDimension.Texture2D, Format.R8_UNorm));
            Chroma = device.CreateShaderResourceView(Texture, new ShaderResourceViewDescription(Texture, ShaderResourceViewDimension.Texture2D, Format.R8G8_UNorm));
            Constants = device.CreateBuffer(new BufferDescription(16, BindFlags.ConstantBuffer));
        }

        public void Dispose()
        {
            Constants.Dispose();
            Chroma.Dispose();
            Luma.Dispose();
            Texture.Dispose();
        }
    }
}
