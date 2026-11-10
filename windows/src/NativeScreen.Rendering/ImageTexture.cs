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

    /// <summary>Writes top-down opaque BGRA as PNG or JPEG.</summary>
    public static unsafe void Save(byte[] bgra, int width, int height, string path, bool jpeg, float? jpegQuality = null)
    {
        using var factory = new IWICImagingFactory();
        using var stream = factory.CreateStream();
        stream.Initialize(path, FileAccess.Write);
        using var encoder = factory.CreateEncoder(jpeg ? ContainerFormat.Jpeg : ContainerFormat.Png, stream);
        fixed (byte* pixels = bgra)
        {
            using var source = factory.CreateBitmapFromMemory((uint)width, (uint)height, PixelFormat.Format32bppBGRA, (uint)(width * 4), (uint)bgra.Length, pixels);
            using var frame = encoder.CreateNewFrame(out var options);
            using (options)
            {
                if (jpegQuality is { } quality)
                {
                    options!.Set("ImageQuality", quality);
                }

                frame.Initialize(options!);
                frame.SetSize((uint)width, (uint)height);
                frame.WriteSource(source);
                frame.Commit();
            }
        }

        encoder.Commit();
    }

    public static ImageTexture Load(string path, int? maxPixelSize = null, bool orient = false)    {
        using var factory = new IWICImagingFactory();
        using var decoder = factory.CreateDecoderFromFileName(path);
        using var frame = decoder.GetFrame(0);
        using var converter = factory.CreateFormatConverter();
        using var rotator = orient ? Oriented(factory, frame) : null;
        converter.Initialize(rotator is null ? frame : rotator, PixelFormat.Format32bppPBGRA);
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

    /// <summary>
    /// The picture's size, EXIF orientation applied, from its header: nothing is decoded, so it is cheap enough for the UI
    /// thread. Throws like <see cref="Load"/> when the file cannot be read.
    /// </summary>
    public static (int Width, int Height) ReadSize(string path)
    {
        using var factory = new IWICImagingFactory();
        using var decoder = factory.CreateDecoderFromFileName(path);
        using var frame = decoder.GetFrame(0);
        var size = frame.Size;
        // 5 to 8 turn the picture a quarter.
        return Orientation(frame) is >= 5 and <= 8 ? ((int)size.Height, (int)size.Width) : ((int)size.Width, (int)size.Height);
    }

    /// <summary>The frame turned upright by its EXIF orientation, or null when it has none (or it reads as upright).</summary>
    private static IWICBitmapFlipRotator? Oriented(IWICImagingFactory factory, IWICBitmapFrameDecode frame)
    {
        var options = Orientation(frame) switch
        {
            2 => BitmapTransformOptions.FlipHorizontal,
            3 => BitmapTransformOptions.Rotate180,
            4 => BitmapTransformOptions.FlipVertical,
            5 => BitmapTransformOptions.Rotate90 | BitmapTransformOptions.FlipHorizontal,
            6 => BitmapTransformOptions.Rotate90,
            7 => BitmapTransformOptions.Rotate270 | BitmapTransformOptions.FlipHorizontal,
            8 => BitmapTransformOptions.Rotate270,
            _ => BitmapTransformOptions.Rotate0
        };
        if (options == BitmapTransformOptions.Rotate0)
        {
            return null;
        }

        var rotator = factory.CreateBitmapFlipRotator();
        rotator.Initialize(frame, options);
        return rotator;
    }

    /// <summary>The EXIF orientation (1 to 8), 1 when the file has none.</summary>
    private static int Orientation(IWICBitmapFrameDecode frame)
    {
        var orientation = 1;
        try
        {
            using var metadata = frame.MetadataQueryReader;
            // JPEG keeps it in the EXIF block, TIFF-like files at the top level. A missing name throws.
            foreach (var name in (ReadOnlySpan<string>)["/app1/ifd/{ushort=274}", "/ifd/{ushort=274}"])
            {
                try
                {
                    if (metadata.GetMetadataByName(name) is { } value)
                    {
                        orientation = Convert.ToInt32(value, System.Globalization.CultureInfo.InvariantCulture);
                        break;
                    }
                }
                catch (SharpGen.Runtime.SharpGenException)
                {
                }
            }
        }
        catch (Exception exception) when (exception is SharpGen.Runtime.SharpGenException or InvalidCastException or FormatException or OverflowException)
        {
            return 1;
        }

        return orientation;
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
