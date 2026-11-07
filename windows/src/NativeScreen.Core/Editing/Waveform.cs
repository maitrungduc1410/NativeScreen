namespace NativeScreen.Core;

/// <summary>Turns decoded audio into the levels the timeline draws, with the same curve as macOS.</summary>
public static class Waveform
{
    /// <summary>One raw peak per this many interleaved samples.</summary>
    public const int PeakChunkSamples = 128;

    public static int BinCount(double durationMs) => Math.Clamp((int)(durationMs / 1000 * 240), 256, 16384);

    public static int VoiceoverBinCount(double durationMs) => Math.Clamp((int)(durationMs / 1000 * 240), 128, 4096);

    /// <summary>
    /// Levels from raw peaks. The 95th percentile is the reference so one loud click cannot flatten the rest, and the power
    /// curve lifts quiet speech. Null for silence, so no fake flat bar is drawn.
    /// </summary>
    private const int HistogramBins = 1024;

    public static float[]? BinsFromPeaks(IReadOnlyList<float> rawPeaks, int targetBinCount)
    {
        if (rawPeaks.Count < 8)
        {
            return null;
        }

        // A 1024-bin histogram gives the 95th percentile without a sorted copy of every peak (spec/06 ADR-49).
        Span<int> histogram = stackalloc int[HistogramBins];
        histogram.Clear();
        var loudestPeak = 0f;
        for (var index = 0; index < rawPeaks.Count; index++)
        {
            var peak = Math.Min(1f, rawPeaks[index]);
            histogram[Math.Min(HistogramBins - 1, (int)(peak * HistogramBins))]++;
            loudestPeak = Math.Max(loudestPeak, peak);
        }

        if (loudestPeak < 0.002f)
        {
            return null;
        }

        var target = (int)(rawPeaks.Count * 0.95);
        var cumulative = 0;
        var p95Bin = HistogramBins - 1;
        for (var bin = 0; bin < HistogramBins; bin++)
        {
            cumulative += histogram[bin];
            if (cumulative > target)
            {
                p95Bin = bin;
                break;
            }
        }

        var reference = Math.Max(0.025f, (p95Bin + 1) / (float)HistogramBins);

        var bins = new float[Math.Min(targetBinCount, rawPeaks.Count)];
        for (var bin = 0; bin < bins.Length; bin++)
        {
            var start = (int)((long)bin * rawPeaks.Count / bins.Length);
            var end = Math.Max(start + 1, (int)((long)(bin + 1) * rawPeaks.Count / bins.Length));
            var loudest = 0f;
            for (var index = start; index < Math.Min(rawPeaks.Count, end); index++)
            {
                loudest = Math.Max(loudest, rawPeaks[index]);
            }

            var normalized = Math.Min(1f, loudest / reference);
            bins[bin] = loudest < 0.0015f ? 0.015f : Math.Min(0.98f, Math.Max(0.02f, MathF.Pow(normalized, 0.62f)));
        }

        return bins;
    }

    /// <summary>What a voiceover shows when its file cannot be read.</summary>
    public static float[] Procedural(double durationMs, int bucketCount)
    {
        var samples = new float[bucketCount];
        for (var index = 0; index < bucketCount; index++)
        {
            var t = (double)index / Math.Max(1, bucketCount) * (durationMs / 1000);
            var syllabic = Math.Abs(Math.Sin(t * 4.7)) * 0.52 + Math.Abs(Math.Sin(t * 11.3 + 1.2)) * 0.30 + Math.Abs(Math.Cos(t * 2.1)) * 0.18;
            var pause = Math.Sin(t * 1.35) > -0.55 ? 1.0 : 0.14;
            samples[index] = (float)Math.Min(0.95, Math.Max(0.08, syllabic * pause));
        }

        return samples;
    }
}
