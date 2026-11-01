namespace NativeScreen.Core;

/// <summary>Opaque BGRA to NV12 with the BT.709 limited-range matrix (spec/07 §1.1), for encoding exports.</summary>
public static class Nv12Converter
{
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
