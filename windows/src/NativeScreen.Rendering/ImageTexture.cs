using System.Runtime.InteropServices;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.WIC;

namespace NativeScreen.Rendering;

/// <summary>A decoded still image: premultiplied BGRA pixels, plus an immutable GPU texture on demand.</summary>
public sealed class ImageTexture
{
    public required byte[] Pixels { get; init; }
    public required int Width { get; init; }
    public required int Height { get; init; }

    public static ImageTexture Load(string path, int? maxPixelSize = null)
    {
        using var factory = new IWICImagingFactory();
        using var decoder = factory.CreateDecoderFromFileName(path);
        using var frame = decoder.GetFrame(0);
        using var converter = factory.CreateFormatConverter();
        converter.Initialize(frame, PixelFormat.Format32bppPBGRA);
        if (maxPixelSize is { } limit && Math.Max(converter.Size.Width, converter.Size.Height) > limit)
        {
            var shrink = (double)limit / Math.Max(converter.Size.Width, converter.Size.Height);
            using var scaler = factory.CreateBitmapScaler();
            scaler.Initialize(converter, (uint)(converter.Size.Width * shrink), (uint)(converter.Size.Height * shrink), BitmapInterpolationMode.Fant);
            var scaled = new byte[scaler.Size.Width * scaler.Size.Height * 4];
            scaler.CopyPixels((uint)(scaler.Size.Width * 4), scaled);
            return new ImageTexture { Pixels = scaled, Width = (int)scaler.Size.Width, Height = (int)scaler.Size.Height };
        }

        var size = converter.Size;
        var pixels = new byte[size.Width * size.Height * 4];
        converter.CopyPixels((uint)(size.Width * 4), pixels);
        return new ImageTexture { Pixels = pixels, Width = (int)size.Width, Height = (int)size.Height };
    }

    public ID3D11ShaderResourceView CreateView(ID3D11Device device)
    {
        var handle = GCHandle.Alloc(Pixels, GCHandleType.Pinned);
        try
        {
            using var texture = device.CreateTexture2D(
                new Texture2DDescription
                {
                    Width = (uint)Width,
                    Height = (uint)Height,
                    MipLevels = 1,
                    ArraySize = 1,
                    Format = Format.B8G8R8A8_UNorm,
                    SampleDescription = new SampleDescription(1, 0),
                    Usage = ResourceUsage.Immutable,
                    BindFlags = BindFlags.ShaderResource
                },
                new SubresourceData(handle.AddrOfPinnedObject(), (uint)(Width * 4)));
            return device.CreateShaderResourceView(texture);
        }
        finally
        {
            handle.Free();
        }
    }

    public static byte[] ReadBack(ID3D11Device device, ID3D11DeviceContext context, ID3D11Texture2D source, int width, int height)
    {
        using var staging = device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)width,
            Height = (uint)height,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Staging,
            CPUAccessFlags = CpuAccessFlags.Read
        });
        context.CopyResource(staging, source);
        var mapped = context.Map(staging, 0, MapMode.Read);
        try
        {
            var pixels = new byte[width * height * 4];
            for (var y = 0; y < height; y++)
            {
                Marshal.Copy(mapped.DataPointer + (nint)(y * mapped.RowPitch), pixels, y * width * 4, width * 4);
            }

            return pixels;
        }
        finally
        {
            context.Unmap(staging, 0);
        }
    }
}
