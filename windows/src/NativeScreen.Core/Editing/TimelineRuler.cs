namespace NativeScreen.Core;

/// <summary>How far apart the ruler's marks are, so they stay readable at any zoom.</summary>
public static class TimelineRuler
{
    private const double TargetPixels = 200;
    private static readonly double[] CandidateSeconds = [0.5, 1, 2.5, 5, 10, 30, 60, 120, 300, 600];

    /// <summary>Reduces toward a span of 100 to 200 pixels between marks, then takes the closest round interval.</summary>
    public static double StepSeconds(double totalDurationMs, double width)
    {
        var totalMs = Math.Max(1000, totalDurationMs);
        var pixelsPerMs = Math.Max(0.001, width / totalMs);
        var numerator = 1.0;
        var denominator = 1.0;
        var intervalMs = 1000.0;
        for (var round = 0; round < 500; round++)
        {
            intervalMs = 1000.0 / (numerator / denominator);
            var span = intervalMs * pixelsPerMs;
            if (span > TargetPixels)
            {
                numerator++;
                continue;
            }

            if (span < TargetPixels * 0.5)
            {
                denominator++;
                continue;
            }

            break;
        }

        var ideal = intervalMs / 1000;
        var chosen = CandidateSeconds[0];
        foreach (var candidate in CandidateSeconds)
        {
            if (Math.Abs(candidate - ideal) < Math.Abs(chosen - ideal))
            {
                chosen = candidate;
            }
        }

        return chosen;
    }
}
