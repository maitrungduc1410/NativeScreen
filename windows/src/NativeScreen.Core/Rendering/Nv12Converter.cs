namespace NativeScreen.Core;

/// <summary>Opaque BGRA to NV12 with the BT.709 limited-range matrix (spec/07 §1.1), for encoding exports.</summary>
public static class Nv12Converter
{
    // A few cores are enough for 60 fps; using all of them adds heat and takes them from the encoder and the captured app.
    private static readonly ParallelOptions ConversionThreads = new() { MaxDegreeOfParallelism = 4 };

    /// <summary>Same matrix for a mapped texture with row padding, over a few cores: a recording cannot fall behind the screen.</summary>
    public static unsafe void FromBgraParallel(byte* bgra, int rowPitch, byte[] nv12, int width, int height)
    {
        var source = (nint)bgra;
        Parallel.For(0, height / 2, ConversionThreads, row =>
        {
            var top = new ReadOnlySpan<byte>((byte*)source + row * 2 * rowPitch, width * 4);
            var bottom = new ReadOnlySpan<byte>((byte*)source + (row * 2 + 1) * rowPitch, width * 4);
            var lumaTop = nv12.AsSpan(row * 2 * width, width);
            var lumaBottom = nv12.AsSpan((row * 2 + 1) * width, width);
            var chroma = nv12.AsSpan(width * height + row * width, width);
            for (var x = 0; x < width / 2; x++)
            {
                var o = x * 8;
                int b0 = top[o], g0 = top[o + 1], r0 = top[o + 2];
                int b1 = top[o + 4], g1 = top[o + 5], r1 = top[o + 6];
                int b2 = bottom[o], g2 = bottom[o + 1], r2 = bottom[o + 2];
                int b3 = bottom[o + 4], g3 = bottom[o + 5], r3 = bottom[o + 6];
                lumaTop[x * 2] = (byte)(((47 * r0 + 157 * g0 + 16 * b0 + 128) >> 8) + 16);
                lumaTop[x * 2 + 1] = (byte)(((47 * r1 + 157 * g1 + 16 * b1 + 128) >> 8) + 16);
                lumaBottom[x * 2] = (byte)(((47 * r2 + 157 * g2 + 16 * b2 + 128) >> 8) + 16);
                lumaBottom[x * 2 + 1] = (byte)(((47 * r3 + 157 * g3 + 16 * b3 + 128) >> 8) + 16);
                var b = (b0 + b1 + b2 + b3) / 4;
                var g = (g0 + g1 + g2 + g3) / 4;
                var r = (r0 + r1 + r2 + r3) / 4;
                chroma[x * 2] = (byte)Math.Clamp(((-26 * r - 86 * g + 112 * b + 128) >> 8) + 128, 16, 240);
                chroma[x * 2 + 1] = (byte)Math.Clamp(((112 * r - 102 * g - 10 * b + 128) >> 8) + 128, 16, 240);
            }
        });
    }

    public static void FromBgra(ReadOnlySpan<byte> bgra, Span<byte> nv12, int width, int height)
    {
        // Fixed point, 8 fractional bits, so rounding is the same on every machine.
        for (var y = 0; y < height; y++)
        {
            var row = bgra.Slice(y * width * 4, width * 4);
            var luma = nv12.Slice(y * width, width);
            for (var x = 0; x < width; x++)
            {
                int b = row[x * 4];
                int g = row[x * 4 + 1];
                int r = row[x * 4 + 2];
                luma[x] = (byte)(((47 * r + 157 * g + 16 * b + 128) >> 8) + 16);
            }
        }

        var chromaOffset = width * height;
        for (var y = 0; y < height / 2; y++)
        {
            var top = bgra.Slice(y * 2 * width * 4, width * 4);
            var bottom = bgra.Slice((y * 2 + 1) * width * 4, width * 4);
            var chroma = nv12.Slice(chromaOffset + y * width, width);
            for (var x = 0; x < width / 2; x++)
            {
                // Average of the 2×2 block, which is where the chroma sample sits.
                var o = x * 8;
                var b = (top[o] + top[o + 4] + bottom[o] + bottom[o + 4]) / 4;
                var g = (top[o + 1] + top[o + 5] + bottom[o + 1] + bottom[o + 5]) / 4;
                var r = (top[o + 2] + top[o + 6] + bottom[o + 2] + bottom[o + 6]) / 4;
                chroma[x * 2] = (byte)Math.Clamp(((-26 * r - 86 * g + 112 * b + 128) >> 8) + 128, 16, 240);
                chroma[x * 2 + 1] = (byte)Math.Clamp(((112 * r - 102 * g - 10 * b + 128) >> 8) + 128, 16, 240);
            }
        }
    }
}
