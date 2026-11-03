using System.Globalization;

namespace NativeScreen.Core;

public sealed class CubeLut
{
    public int Size { get; }
    public float[] Rgb { get; }

    public CubeLut(int size, float[] rgb)
    {
        if (size < 2 || rgb.Length != size * size * size * 3)
        {
            throw new InvalidDataException($"LUT size {size} does not match {rgb.Length} samples.");
        }

        Size = size;
        Rgb = rgb;
    }

    public const int MaximumSize = 128;

    /// <summary>Null when the text is not a complete 3D table, for files a person picked.</summary>
    public static CubeLut? TryParse(string text)
    {
        try
        {
            return text.Contains("LUT_1D_SIZE", StringComparison.Ordinal) ? null : Parse(text);
        }
        catch (Exception exception) when (exception is FormatException or InvalidDataException or IndexOutOfRangeException or OverflowException)
        {
            return null;
        }
    }

    public static CubeLut Parse(string text)
    {
        var size = 0;
        var values = new List<float>();
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#') || line.StartsWith("TITLE", StringComparison.Ordinal) || line.StartsWith("DOMAIN_", StringComparison.Ordinal))
            {
                continue;
            }

            if (line.StartsWith("LUT_3D_SIZE", StringComparison.Ordinal))
            {
                size = int.Parse(line.Split(' ', StringSplitOptions.RemoveEmptyEntries)[1], CultureInfo.InvariantCulture);
                continue;
            }

            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 3)
            {
                continue;
            }

            values.Add(float.Parse(parts[0], CultureInfo.InvariantCulture));
            values.Add(float.Parse(parts[1], CultureInfo.InvariantCulture));
            values.Add(float.Parse(parts[2], CultureInfo.InvariantCulture));
        }

        if (size > MaximumSize)
        {
            throw new InvalidDataException($"LUT size {size} is above {MaximumSize}.");
        }

        return new CubeLut(size, values.ToArray());
    }

    public Rgba Sample(int red, int green, int blue)
    {
        var index = ((blue * Size + green) * Size + red) * 3;
        return Rgba.Opaque(Rgb[index], Rgb[index + 1], Rgb[index + 2]);
    }
}
