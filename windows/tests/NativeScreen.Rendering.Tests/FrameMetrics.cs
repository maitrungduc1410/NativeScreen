namespace NativeScreen.Rendering.Tests;

internal static class FrameMetrics
{
    private const int Window = 8;

    /// <summary>Writes top-down BGRA pixels as a PNG, for looking at a failing frame.</summary>
    public static void WritePng(string path, byte[] bgra, int width, int height)
    {
        using var raw = new MemoryStream();
        using (var zlib = new System.IO.Compression.ZLibStream(raw, System.IO.Compression.CompressionLevel.Fastest, leaveOpen: true))
        {
            var row = new byte[width * 4 + 1];
            for (var y = 0; y < height; y++)
            {
                for (var x = 0; x < width; x++)
                {
                    var o = (y * width + x) * 4;
                    row[x * 4 + 1] = bgra[o + 2];
                    row[x * 4 + 2] = bgra[o + 1];
                    row[x * 4 + 3] = bgra[o];
                    row[x * 4 + 4] = bgra[o + 3];
                }

                zlib.Write(row);
            }
        }

        using var file = File.Create(path);
        file.Write([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
        var header = new byte[13];
        System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(header, width);
        System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(4), height);
        header[8] = 8;
        header[9] = 6;
        Chunk(file, "IHDR", header);
        Chunk(file, "IDAT", raw.ToArray());
        Chunk(file, "IEND", []);
    }

    private static void Chunk(Stream stream, string type, byte[] data)
    {
        var name = System.Text.Encoding.ASCII.GetBytes(type);
        Span<byte> number = stackalloc byte[4];
        System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(number, data.Length);
        stream.Write(number);
        stream.Write(name);
        stream.Write(data);
        var crc = 0xFFFFFFFFu;
        foreach (var value in name.Concat(data))
        {
            crc ^= value;
            for (var bit = 0; bit < 8; bit++)
            {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320u : crc >> 1;
            }
        }

        System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(number, ~crc);
        stream.Write(number);
    }

    /// <summary>Mean SSIM over 8×8 luma windows, and the share of pixels within 6/255 on every channel.</summary>
    public static (double Ssim, double Within) Compare(byte[] actual, byte[] expected, int width, int height) =>
        Compare(actual, expected, width, 0, 0, width, height);

    /// <summary>The same measurement limited to a region of the frame.</summary>
    public static (double Ssim, double Within) Compare(byte[] actual, byte[] expected, int stride, int left, int top, int width, int height)
    {
        var close = 0L;
        for (var y = top; y < top + height; y++)
        {
            for (var x = left; x < left + width; x++)
            {
                var o = (y * stride + x) * 4;
                if (Math.Abs(actual[o] - expected[o]) <= 6 && Math.Abs(actual[o + 1] - expected[o + 1]) <= 6 && Math.Abs(actual[o + 2] - expected[o + 2]) <= 6)
                {
                    close++;
                }
            }
        }

        const double c1 = 6.5025;
        const double c2 = 58.5225;
        var total = 0.0;
        var windows = 0;
        for (var y = top; y + Window <= top + height; y += Window)
        {
            for (var x = left; x + Window <= left + width; x += Window)
            {
                double sumA = 0, sumB = 0, sumAA = 0, sumBB = 0, sumAB = 0;
                for (var j = 0; j < Window; j++)
                {
                    for (var k = 0; k < Window; k++)
                    {
                        var o = ((y + j) * stride + x + k) * 4;
                        var a = 0.0722 * actual[o] + 0.7152 * actual[o + 1] + 0.2126 * actual[o + 2];
                        var b = 0.0722 * expected[o] + 0.7152 * expected[o + 1] + 0.2126 * expected[o + 2];
                        sumA += a;
                        sumB += b;
                        sumAA += a * a;
                        sumBB += b * b;
                        sumAB += a * b;
                    }
                }

                const int n = Window * Window;
                var meanA = sumA / n;
                var meanB = sumB / n;
                var varA = sumAA / n - meanA * meanA;
                var varB = sumBB / n - meanB * meanB;
                var cov = sumAB / n - meanA * meanB;
                total += (2 * meanA * meanB + c1) * (2 * cov + c2) / ((meanA * meanA + meanB * meanB + c1) * (varA + varB + c2));
                windows++;
            }
        }

        return (total / windows, close / (double)(width * height));
    }
}
