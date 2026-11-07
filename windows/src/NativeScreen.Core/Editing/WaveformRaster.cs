namespace NativeScreen.Core;

/// <summary>One recorded source drawn on a clip: its levels, the volume it plays at, and its color.</summary>
public sealed record WaveformRasterLayer(WaveformEnvelope Envelope, double Volume, double Red, double Green, double Blue, double Opacity);

/// <summary>A premultiplied BGRA bitmap, rows top to bottom.</summary>
public sealed record WaveformBitmap(byte[] Pixels, int Width, int Height);

/// <summary>
/// The clip waveforms rasterized per device pixel (spec/06 ADR-42). Each layer draws its volume-scaled wave over a 0.10 opacity
/// copy of its full wave, shown only below 0.999 volume. Inside a column, opacity goes from half at the bottom to full at that
/// column's crest, which one gradient across the row cannot do.
/// </summary>
public static class WaveformRaster
{
    private const long MaximumPixels = 40_000_000;

    /// <summary>The height of a full-level wave.</summary>
    public static double MaximumHeight(double rowHeight) => Math.Min(rowHeight * 0.68, 32);

    /// <summary>
    /// Layers are drawn bottom-up in order. <paramref name="width"/> and <paramref name="height"/> are in points;
    /// <paramref name="cornerRadius"/> rounds the bitmap's corners, as the block around it does. Null when nothing fits.
    /// </summary>
    public static WaveformBitmap? Rasterize(
        IReadOnlyList<WaveformRasterLayer> layers,
        double startFraction,
        double endFraction,
        double width,
        double height,
        double scale,
        bool smooth,
        double cornerRadius = 0)
    {
        if (layers.Count == 0 || width < 1 || height < 1 || scale <= 0)
        {
            return null;
        }

        var widthPx = (int)Math.Ceiling(width * scale);
        var heightPx = (int)Math.Ceiling(height * scale);
        if (widthPx <= 0 || heightPx <= 0 || (long)widthPx * heightPx > MaximumPixels)
        {
            return null;
        }

        var maximum = MaximumHeight(height);
        var span = endFraction - startFraction;
        var radius = Math.Max(0, Math.Min(cornerRadius, Math.Min(width, height) / 2));
        var pixels = new byte[widthPx * heightPx * 4];
        var shapeHeights = new double[layers.Count];
        var fullHeights = new double[layers.Count];
        var samplesPerBin = new double[layers.Count];
        for (var index = 0; index < layers.Count; index++)
        {
            samplesPerBin[index] = layers[index].Envelope.SamplesPerBin(startFraction, endFraction, width);
        }

        for (var x = 0; x < widthPx; x++)
        {
            var xPoints = (x + 0.5) / scale;
            double localFraction;
            if (smooth)
            {
                localFraction = xPoints / width;
            }
            else
            {
                // Smooth waveform off: 2 point bars on a 3 point pitch, each sampled at its center.
                var column = Math.Floor(xPoints / 3);
                if (xPoints - column * 3 >= 2)
                {
                    continue;
                }

                localFraction = (column * 3 + 1) / width;
            }

            var top = 0.0;
            for (var index = 0; index < layers.Count; index++)
            {
                var layer = layers[index];
                var level = layer.Envelope.Read((startFraction + localFraction * span) * layer.Envelope.SampleCount, samplesPerBin[index]);
                fullHeights[index] = Math.Min(height, level * maximum);
                shapeHeights[index] = Math.Min(height, level * maximum * Math.Max(0, layer.Volume));
                top = Math.Max(top, Math.Max(fullHeights[index], shapeHeights[index]));
            }

            if (top <= 0)
            {
                continue;
            }

            var cornerDistance = xPoints < radius ? radius - xPoints : xPoints > width - radius ? xPoints - (width - radius) : 0;
            var rows = Math.Min(heightPx, (int)Math.Ceiling(top * scale) + 1);
            for (var row = 0; row < rows; row++)
            {
                var fromBottom = (row + 0.5) / scale;
                double r = 0, g = 0, b = 0, a = 0;
                for (var index = 0; index < layers.Count; index++)
                {
                    var layer = layers[index];
                    var shape = shapeHeights[index];
                    var shapeAlpha = shape > 0 ? layer.Opacity * Coverage(shape, fromBottom, scale) * Fade(shape, fromBottom) : 0;
                    var full = fullHeights[index];
                    var fullAlpha = layer.Volume < 0.999 && full > 0 ? 0.1 * Coverage(full, fromBottom, scale) * Fade(full, fromBottom) : 0;
                    var layerAlpha = shapeAlpha + fullAlpha * (1 - shapeAlpha);
                    if (layerAlpha <= 0)
                    {
                        continue;
                    }

                    var keep = 1 - layerAlpha;
                    r = layer.Red * layerAlpha + r * keep;
                    g = layer.Green * layerAlpha + g * keep;
                    b = layer.Blue * layerAlpha + b * keep;
                    a = layerAlpha + a * keep;
                }

                if (a <= 0)
                {
                    continue;
                }

                // The bottom corners of the block cut the wave as they cut the block.
                if (cornerDistance > 0 && fromBottom < radius)
                {
                    var dy = radius - fromBottom;
                    var mask = Math.Clamp((radius - Math.Sqrt(cornerDistance * cornerDistance + dy * dy)) * scale + 0.5, 0, 1);
                    r *= mask;
                    g *= mask;
                    b *= mask;
                    a *= mask;
                    if (a <= 0)
                    {
                        continue;
                    }
                }

                var offset = ((heightPx - 1 - row) * widthPx + x) * 4;
                pixels[offset] = ToByte(b);
                pixels[offset + 1] = ToByte(g);
                pixels[offset + 2] = ToByte(r);
                pixels[offset + 3] = ToByte(a);
            }
        }

        return new WaveformBitmap(pixels, widthPx, heightPx);
    }

    private static double Coverage(double waveHeight, double fromBottom, double scale) => Math.Clamp((waveHeight - fromBottom) * scale + 0.5, 0, 1);

    private static double Fade(double waveHeight, double fromBottom) => 0.5 + 0.5 * Math.Clamp(fromBottom / Math.Max(waveHeight, 1), 0, 1);

    private static byte ToByte(double value) => (byte)Math.Min(255, value * 255 + 0.5);
}
