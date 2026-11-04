namespace NativeScreen.Core;

/// <summary>
/// A max-reduction mip pyramid over the levels, read through a Catmull-Rom spline. Halving keeps every peak at any zoom, and
/// blending two pyramid levels keeps the shape from jumping as the zoom changes (spec/06 ADR-10).
/// </summary>
public sealed class WaveformEnvelope
{
    /// <summary>How many points on screen one spline control bin spans.</summary>
    private const double PointsPerBin = 11;

    private readonly List<float[]> levels = [];

    public WaveformEnvelope(float[] samples)
    {
        if (samples.Length == 0)
        {
            return;
        }

        levels.Add(samples);
        while (levels[^1].Length > 2)
        {
            var last = levels[^1];
            var next = new float[(last.Length + 1) / 2];
            for (var index = 0; index < next.Length; index++)
            {
                next[index] = Math.Max(last[index * 2], last[Math.Min(last.Length - 1, index * 2 + 1)]);
            }

            levels.Add(next);
        }
    }

    public int SampleCount => levels.Count == 0 ? 0 : levels[0].Length;

    /// <summary>The level at a sample position, smoothed for how many samples one control bin covers.</summary>
    public double Read(double samplePosition, double samplesPerBin)
    {
        if (levels.Count == 0)
        {
            return 0;
        }

        var level = Math.Min(levels.Count - 1, Math.Max(0, Math.Log2(Math.Max(1, samplesPerBin))));
        var lower = (int)Math.Floor(level);
        var upper = Math.Min(levels.Count - 1, lower + 1);
        var fraction = level - lower;
        var low = ReadLevel(lower, samplePosition);
        return lower == upper || fraction <= 0.0001 ? low : low + (ReadLevel(upper, samplePosition) - low) * fraction;
    }

    /// <summary>Samples per control bin for a part of the recording drawn across the given width.</summary>
    public double SamplesPerBin(double startFraction, double endFraction, double width) =>
        Math.Max(1, Math.Max(1, (endFraction - startFraction) * SampleCount) / Math.Max(1, width) * PointsPerBin);

    private double ReadLevel(int index, double samplePosition)
    {
        var level = levels[index];
        var position = samplePosition / Math.Pow(2, index) - 0.5;
        var leftPosition = Math.Floor(position);
        var t = position - leftPosition;
        var left = (int)leftPosition;
        double Bin(int bin) => bin < 0 || bin >= level.Length ? 0 : level[bin];
        var before = Bin(left - 1);
        var current = Bin(left);
        var right = Bin(left + 1);
        var after = Bin(left + 2);
        var curve = current + 0.5 * t * (right - before + t * (2 * before - 5 * current + 4 * right - after + t * (3 * (current - right) + after - before)));
        return Math.Min(1, Math.Max(0, curve));
    }
}
