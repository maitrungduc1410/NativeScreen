namespace NativeScreen.Core;

public readonly record struct Rgba(double R, double G, double B, double A)
{
    public static Rgba Opaque(double r, double g, double b) => new(r, g, b, 1);

    public static Rgba ParseHex(string? hex)
    {
        if (string.IsNullOrWhiteSpace(hex))
        {
            return Fallback;
        }

        var text = hex.Trim();
        if (text.StartsWith('#'))
        {
            text = text[1..];
        }

        if (text.Length is not (6 or 8) || !IsHex(text))
        {
            return Fallback;
        }

        var r = Convert.ToInt32(text[..2], 16) / 255.0;
        var g = Convert.ToInt32(text[2..4], 16) / 255.0;
        var b = Convert.ToInt32(text[4..6], 16) / 255.0;
        var a = text.Length == 8 ? Convert.ToInt32(text[6..8], 16) / 255.0 : 1;
        return new Rgba(r, g, b, a);
    }

    public static Rgba Bt709LimitedToRgb(double y, double cb, double cr)
    {
        var yp = (y - 16.0 / 255.0) * (255.0 / 219.0);
        var cbp = (cb - 128.0 / 255.0) * (255.0 / 224.0);
        var crp = (cr - 128.0 / 255.0) * (255.0 / 224.0);
        return new Rgba(
            Clamp(yp + 1.5748 * crp),
            Clamp(yp - 0.1873 * cbp - 0.4681 * crp),
            Clamp(yp + 1.8556 * cbp),
            1);
    }

    public (double Y, double Cb, double Cr) ToBt709Limited()
    {
        const double cbScale = 0.1873 / 1.8556;
        const double crScale = 0.4681 / 1.5748;
        var denom = 1 + cbScale + crScale;
        var yLinear = (G + crScale * R + cbScale * B) / denom;
        var cb = ((B - yLinear) / 1.8556) * (224.0 / 255.0) + 128.0 / 255.0;
        var cr = ((R - yLinear) / 1.5748) * (224.0 / 255.0) + 128.0 / 255.0;
        var y = yLinear * (219.0 / 255.0) + 16.0 / 255.0;
        return (Clamp(y), Clamp(cb), Clamp(cr));
    }

    public Rgba SourceOver(Rgba destination)
    {
        var a = A + destination.A * (1 - A);
        if (a <= 0)
        {
            return new Rgba(0, 0, 0, 0);
        }

        return new Rgba(
            (R * A + destination.R * destination.A * (1 - A)) / a,
            (G * A + destination.G * destination.A * (1 - A)) / a,
            (B * A + destination.B * destination.A * (1 - A)) / a,
            a);
    }

    public Rgba ColorControls(double saturation, double brightness, double contrast)
    {
        var luma = 0.2125 * R + 0.7154 * G + 0.0721 * B;
        var saturated = new Rgba(
            luma + (R - luma) * saturation,
            luma + (G - luma) * saturation,
            luma + (B - luma) * saturation,
            A);
        var bright = new Rgba(saturated.R + brightness, saturated.G + brightness, saturated.B + brightness, A);
        return new Rgba(
            Clamp((bright.R - 0.5) * contrast + 0.5),
            Clamp((bright.G - 0.5) * contrast + 0.5),
            Clamp((bright.B - 0.5) * contrast + 0.5),
            A);
    }

    public Rgba Vibrance(double amount)
    {
        var sat = Math.Max(R, Math.Max(G, B)) - Math.Min(R, Math.Min(G, B));
        var k = amount * (1 - sat);
        var luma = 0.2125 * R + 0.7154 * G + 0.0721 * B;
        return new Rgba(
            Clamp(luma + (R - luma) * (1 + k)),
            Clamp(luma + (G - luma) * (1 + k)),
            Clamp(luma + (B - luma) * (1 + k)),
            A);
    }

    public Rgba Warmth(double warmth)
    {
        return new Rgba(
            Clamp(R * (1 + 0.10 * warmth)),
            Clamp(G * (1 + 0.01 * warmth)),
            Clamp(B * (1 - 0.12 * warmth)),
            A);
    }

    public Rgba ApplyCustomPreset(CustomCameraColorPreset preset)
    {
        var color = Math.Abs(preset.Warmth) > 0.005 ? Warmth(preset.Warmth) : this;
        var contrast = Math.Clamp(1 + preset.Contrast * 0.32 + preset.BackgroundPop * 0.08, 0.75, 1.45);
        var saturation = Math.Clamp(1 + preset.ColorIntensity * 0.35, 0.55, 1.45);
        color = color.ColorControls(saturation, preset.BackgroundPop * 0.018, contrast);
        if (Math.Abs(preset.ColorIntensity) > 0.01 || preset.BackgroundPop > 0.01)
        {
            color = color.Vibrance(preset.ColorIntensity * 0.32 + preset.BackgroundPop * 0.14);
        }

        return color;
    }

    public Rgba BlendLook(Rgba graded, double intensity)
    {
        var t = Math.Clamp(intensity, 0, 1);
        return new Rgba(R + (graded.R - R) * t, G + (graded.G - G) * t, B + (graded.B - B) * t, A);
    }

    private static Rgba Fallback { get; } = new(0.28, 0.46, 0.90, 1);

    private static bool IsHex(string text)
    {
        foreach (var ch in text)
        {
            if (!Uri.IsHexDigit(ch))
            {
                return false;
            }
        }

        return true;
    }

    private static double Clamp(double value) => Math.Clamp(value, 0, 1);
}

public static class ColorMath
{
    public static double Smoothstep(double edge0, double edge1, double x)
    {
        var t = Math.Clamp((x - edge0) / Math.Max(1e-9, edge1 - edge0), 0, 1);
        return t * t * (3 - 2 * t);
    }
}
