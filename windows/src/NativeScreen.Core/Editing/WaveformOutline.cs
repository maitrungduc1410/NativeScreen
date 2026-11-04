namespace NativeScreen.Core;

/// <summary>
/// The polygon of a waveform inside a rounded block. It follows the block's corners itself, so nothing depends on how the
/// block clips its children.
/// </summary>
public static class WaveformOutline
{
    private const int CornerSteps = 5;

    /// <summary>The height at full level.</summary>
    public static double MaximumHeight(double blockHeight) => Math.Min(blockHeight * 0.68, 32);

    /// <summary>The height a louder than 100% volume may reach.</summary>
    public static double Ceiling(double blockHeight) => blockHeight * 0.82;

    /// <summary>
    /// <paramref name="waveHeight"/> gives the height at 0...1 across the block. Smooth traces the envelope every 1.5 points;
    /// otherwise one bar per 3 points. Empty when no bar is tall enough to see.
    /// </summary>
    public static List<(double X, double Y)> Points(double width, double height, double radius, bool smooth, Func<double, double> waveHeight)
    {
        radius = Math.Min(radius, Math.Min(width, height) / 2);
        return smooth ? Smooth(width, height, radius, waveHeight) : Bars(width, height, radius, waveHeight);
    }

    /// <summary>How far the rounded corner pushes the top and bottom edges in at x.</summary>
    private static double CornerInset(double x, double width, double radius)
    {
        var distance = x < radius ? radius - x : x > width - radius ? x - (width - radius) : 0;
        return distance <= 0 ? 0 : radius - Math.Sqrt(Math.Max(0, radius * radius - distance * distance));
    }

    private static List<(double X, double Y)> Smooth(double width, double height, double radius, Func<double, double> waveHeight)
    {
        var count = Math.Max(4, (int)Math.Ceiling(width / 1.5));
        var points = new List<(double X, double Y)>(count + 2 * CornerSteps + 4);
        for (var index = 0; index <= count; index++)
        {
            var fraction = (double)index / count;
            var x = fraction * width;
            var inset = CornerInset(x, width, radius);
            points.Add((x, Math.Clamp(height - waveHeight(fraction), inset, height - inset)));
        }

        // Back along the bottom edge, around both corners.
        for (var step = 1; step <= CornerSteps; step++)
        {
            var x = width - radius * step / CornerSteps;
            points.Add((x, height - CornerInset(x, width, radius)));
        }

        for (var step = 0; step < CornerSteps; step++)
        {
            var x = radius - radius * step / CornerSteps;
            points.Add((x, height - CornerInset(x, width, radius)));
        }

        return points;
    }

    private static List<(double X, double Y)> Bars(double width, double height, double radius, Func<double, double> waveHeight)
    {
        const double pitch = 3;
        const double barWidth = 2;
        const double chamfer = 0.6;
        var columns = Math.Max(1, (int)(width / pitch));
        var teeth = new List<(double X, double Y)>(columns * 6);
        var baseline = new List<(double X, double Y)>(columns * 2);
        for (var column = 0; column < columns; column++)
        {
            var x = column * pitch;
            var wave = waveHeight((x + barWidth / 2) / Math.Max(1, width));
            if (wave <= 0.5)
            {
                continue;
            }

            var inset = Math.Max(CornerInset(x, width, radius), CornerInset(x + barWidth, width, radius));
            var bottom = height - inset;
            var top = Math.Min(bottom, Math.Max(inset, height - wave));
            teeth.Add((x, bottom));
            teeth.Add((x, Math.Min(bottom, top + chamfer)));
            teeth.Add((x + chamfer, top));
            teeth.Add((x + barWidth - chamfer, top));
            teeth.Add((x + barWidth, Math.Min(bottom, top + chamfer)));
            teeth.Add((x + barWidth, bottom));
            baseline.Add((x + barWidth, bottom));
            baseline.Add((x, bottom));
        }

        // The way back runs over the bottoms of the bars, so nothing fills between them.
        baseline.Reverse();
        var ordered = new List<(double X, double Y)>(teeth.Count + baseline.Count);
        ordered.AddRange(teeth);
        for (var index = 0; index < baseline.Count; index += 2)
        {
            ordered.Add(baseline[index + 1]);
            ordered.Add(baseline[index]);
        }

        return ordered;
    }
}
