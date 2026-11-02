using System.Runtime.InteropServices;
using SharpGen.Runtime.Win32;
using Vortice.WIC;

namespace NativeScreen.Media;

/// <summary>Animated GIF through WIC, streamed frame by frame so the animation is never held in memory.</summary>
public sealed class GifFileWriter : IDisposable
{
    private readonly IWICImagingFactory factory = new();
    private readonly IWICStream stream;
    private readonly IWICBitmapEncoder encoder;
    private readonly string path;
    private readonly bool loop;
    private readonly int width;
    private readonly int height;
    private bool closed;
    private bool disposed;

    public GifFileWriter(string path, int width, int height, bool loop = true)
    {
        this.path = path;
        this.loop = loop;
        this.width = width;
        this.height = height;
        stream = factory.CreateStream();
        stream.Initialize(path, System.IO.FileAccess.Write);
        encoder = factory.CreateEncoder(ContainerFormat.Gif, stream);
    }

    /// <summary>Top-down BGRA. Each frame gets its own optimal 256-color palette.</summary>
    public unsafe void WriteFrame(byte[] bgra, double durationMs)
    {
        fixed (byte* pixels = bgra)
        {
            WriteFrame(pixels, bgra.Length, durationMs);
        }
    }

    private unsafe void WriteFrame(byte* pixels, int length, double durationMs)
    {
        using var source = factory.CreateBitmapFromMemory((uint)width, (uint)height, PixelFormat.Format32bppBGRA, (uint)(width * 4), (uint)length, pixels);
        using var palette = factory.CreatePalette();
        palette.InitializeFromBitmap(source, 256, false);
        using var converter = factory.CreateFormatConverter();
        converter.Initialize(source, PixelFormat.Format8bppIndexed, BitmapDitherType.ErrorDiffusion, palette, 0.5, BitmapPaletteType.Custom);
        IPropertyBag2? options;
        using var frame = encoder.CreateNewFrame(out options);
        using (options)
        {
            frame.Initialize(options!);
            frame.SetSize((uint)width, (uint)height);
            frame.SetPalette(palette);
            frame.WriteSource(converter);
            using (var metadata = frame.MetadataQueryWriter)
            {
                // GIF delays are hundredths of a second.
                metadata.SetMetadataByName("/grctlext/Delay", new Variant { ElementType = VariantElementType.UShort, Value = (ushort)Math.Max(2, Math.Round(durationMs / 10)) });
                metadata.SetMetadataByName("/grctlext/Disposal", new Variant { ElementType = VariantElementType.UByte, Value = (byte)2 });
            }

            frame.Commit();
        }
    }

    public void Finish()
    {
        if (!closed)
        {
            closed = true;
            encoder.Commit();
            encoder.Dispose();
            stream.Dispose();
            if (loop)
            {
                AddLoopExtension();
            }
        }
    }

    // WIC writes one-shot animations. The NETSCAPE block that makes a GIF loop goes right after the header and global
    // palette, and WIC's metadata API rejects the byte vectors it needs, so it is added to the finished file.
    private void AddLoopExtension()
    {
        var temporary = path + ".tmp";
        using (var input = File.OpenRead(path))
        using (var output = File.Create(temporary))
        {
            var header = new byte[13];
            input.ReadExactly(header);
            var paletteBytes = (header[10] & 0x80) != 0 ? 3 << ((header[10] & 7) + 1) : 0;
            output.Write(header);
            var palette = new byte[paletteBytes];
            input.ReadExactly(palette);
            output.Write(palette);
            output.Write([0x21, 0xFF, 0x0B]);
            output.Write("NETSCAPE2.0"u8);
            output.Write([0x03, 0x01, 0x00, 0x00, 0x00]);
            input.CopyTo(output);
        }

        File.Move(temporary, path, overwrite: true);
    }

    public void Cancel()
    {
        closed = true;
        Dispose();
        if (File.Exists(path))
        {
            File.Delete(path);
        }
    }

    public void Dispose()
    {
        if (!disposed)
        {
            disposed = true;
            encoder.Dispose();
            stream.Dispose();
            factory.Dispose();
        }
    }
}
