namespace NativeScreen.Core;

/// <summary>Turns a camera frame into the floating preview's square: center crop, mirrored like a mirror, BT.709 limited range.</summary>
public static class CameraPreviewPixels
{
    public static void ToMirroredSquare(ReadOnlySpan<byte> nv12, int width, int height, Span<byte> bgra, int size)
    {
        var side = Math.Min(width, height);
        var left = (width - side) / 2;
        var top = (height - side) / 2;
        var chroma = nv12[(width * height)..];
        for (var row = 0; row < size; row++)
        {
            var y = top + row * side / size;
            var chromaRow = (y / 2) * width;
            var target = row * size * 4;
            for (var column = 0; column < size; column++)
            {
                var x = left + (size - 1 - column) * side / size;
                var luma = (nv12[y * width + x] - 16) * 298;
                var chromaIndex = chromaRow + (x & ~1);
                var u = chroma[chromaIndex] - 128;
                var v = chroma[chromaIndex + 1] - 128;
                bgra[target] = Clamp((luma + 541 * u + 128) >> 8);
                bgra[target + 1] = Clamp((luma - 55 * u - 136 * v + 128) >> 8);
                bgra[target + 2] = Clamp((luma + 459 * v + 128) >> 8);
                bgra[target + 3] = 255;
                target += 4;
            }
        }
    }

    private static byte Clamp(int value) => (byte)(value < 0 ? 0 : value > 255 ? 255 : value);
}
