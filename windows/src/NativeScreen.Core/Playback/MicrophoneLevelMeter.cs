namespace NativeScreen.Core;

/// <summary>The recording bar's two meter bars: a fast one, and a slower peak that holds briefly and falls behind it.</summary>
public sealed class MicrophoneLevelMeter
{
    private const double PeakHoldMs = 90;

    private double trailing;
    private double lastPeakMs;

    public double Level { get; private set; }

    public double PeakHold => Math.Max(Level, trailing);

    public void Add(double peak01, double nowMs)
    {
        var raw = Perceptual(peak01);
        Level = raw >= Level ? Level * 0.32 + raw * 0.68 : Math.Max(0, Level * 0.62 + raw * 0.38);
        if (Level >= trailing)
        {
            trailing = Level;
            lastPeakMs = nowMs;
        }
        else if (nowMs - lastPeakMs > PeakHoldMs)
        {
            trailing = Math.Max(Level, trailing * 0.86 - 0.008);
        }
    }

    /// <summary>-48 dB to 0 dB as 0 to 1. The endpoint meter reports a peak only, so the RMS term has no input here.</summary>
    public static double Perceptual(double peak01)
    {
        var combined = peak01 * 0.85;
        if (combined < 0.002)
        {
            return 0;
        }

        var db = 20 * Math.Log10(Math.Max(0.0001, Math.Min(1, combined)));
        return Math.Clamp(Math.Pow(Math.Max(0, (db + 48) / 48), 1.15), 0, 1);
    }
}
