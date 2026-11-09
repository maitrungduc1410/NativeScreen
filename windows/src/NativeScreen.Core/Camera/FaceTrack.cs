using System.Text.Json.Serialization;

namespace NativeScreen.Core;

public readonly record struct FacePoint(double X, double Y);

/// <summary>Both eyes, the nose and the mouth of a face. The eyes can come in either order.</summary>
public readonly record struct FacePoints(FacePoint EyeA, FacePoint EyeB, FacePoint Nose, FacePoint Mouth);

/// <summary>The contents of <c>assets/face-track.json</c>, shared with macOS.</summary>
public sealed class StoredFaceTrack
{
    [JsonPropertyName("version")]
    public int Version { get; set; } = 1;

    [JsonPropertyName("webcamDurationMs")]
    public double WebcamDurationMs { get; set; }

    /// <summary>[timeMs, faceX, faceY, faceW, faceH, eyeAx, eyeAy, eyeBx, eyeBy, noseX, noseY, mouthX, mouthY], normalized to the webcam frame, top-left origin.</summary>
    [JsonPropertyName("samples")]
    public List<double[]> Samples { get; set; } = [];
}

/// <summary>
/// Where the largest face is at each moment of the webcam video, scanned once. Having the whole recording lets stickers and
/// framing be smoothed with no lag, the same in preview and export (spec/06 ADR-58).
/// </summary>
public sealed class FaceTrack
{
    public const int FieldCount = 13;
    private const double BridgeGapMs = 500;
    private const double FadeMs = 150;
    private const double FramingStepMs = 100;
    private const double FramingDeadZone = 0.05;
    private const int FramingSigmaSteps = 7;

    private readonly double[] times;
    private readonly double[][] values;
    private readonly FacePoint[] framing;

    public FaceTrack(StoredFaceTrack stored)
    {
        var usable = stored.Samples.Where(sample => sample.Length == FieldCount).ToArray();
        times = usable.Select(sample => sample[0]).ToArray();
        values = Smoothed(usable);
        framing = FramingPath(usable, stored.WebcamDurationMs);
    }

    public bool HasFaces => times.Length > 0;

    /// <summary>The face at a webcam time, normalized, and how visible a sticker on it should be.</summary>
    public (FacePoints Points, double Opacity)? PointsAt(double ms)
    {
        if (!HasFaces)
        {
            return null;
        }

        var next = FirstIndexAtLeast(ms);
        if (next < times.Length && next > 0 && times[next] - times[next - 1] <= BridgeGapMs)
        {
            var t = (ms - times[next - 1]) / Math.Max(1, times[next] - times[next - 1]);
            return (Interpolated(values[next - 1], values[next], t), 1);
        }

        if (next < times.Length && times[next] == ms)
        {
            return (Interpolated(values[next], values[next], 0), 1);
        }

        if (next > 0 && ms - times[next - 1] < FadeMs)
        {
            return (Interpolated(values[next - 1], values[next - 1], 0), 1 - (ms - times[next - 1]) / FadeMs);
        }

        if (next < times.Length && times[next] - ms < FadeMs)
        {
            return (Interpolated(values[next], values[next], 0), 1 - (times[next] - ms) / FadeMs);
        }

        return null;
    }

    /// <summary>The slow, steady point a tracking camera should center on, normalized to the webcam frame.</summary>
    public FacePoint? FramingCenterAt(double ms)
    {
        if (framing.Length == 0)
        {
            return null;
        }

        var last = framing.Length - 1;
        var position = Math.Max(0, Math.Min(last, ms / FramingStepMs));
        var lower = (int)position;
        var upper = Math.Min(last, lower + 1);
        var t = position - lower;
        return new FacePoint(
            framing[lower].X + (framing[upper].X - framing[lower].X) * t,
            framing[lower].Y + (framing[upper].Y - framing[lower].Y) * t);
    }

    private int FirstIndexAtLeast(double value)
    {
        int low = 0, high = times.Length;
        while (low < high)
        {
            var mid = (low + high) / 2;
            if (times[mid] < value)
            {
                low = mid + 1;
            }
            else
            {
                high = mid;
            }
        }

        return low;
    }

    private static FacePoints Interpolated(double[] a, double[] b, double t)
    {
        FacePoint At(int field) => new(a[field] + (b[field] - a[field]) * t, a[field + 1] + (b[field + 1] - a[field + 1]) * t);
        return new FacePoints(At(5), At(7), At(9), At(11));
    }

    // Centered binomial filter over each unbroken run: removes landmark jitter without adding lag.
    private static double[][] Smoothed(double[][] samples)
    {
        double[] weights = [1, 4, 6, 4, 1];
        var result = samples.Select(sample => (double[])sample.Clone()).ToArray();
        var runStart = 0;
        for (var index = 0; index < samples.Length; index++)
        {
            if (index > 0 && samples[index][0] - samples[index - 1][0] > BridgeGapMs)
            {
                runStart = index;
            }

            var runEnd = index;
            while (runEnd + 1 < samples.Length && runEnd - index < 2 && samples[runEnd + 1][0] - samples[runEnd][0] <= BridgeGapMs)
            {
                runEnd++;
            }

            for (var field = 1; field < FieldCount; field++)
            {
                double sum = 0, total = 0;
                for (var offset = -2; offset <= 2; offset++)
                {
                    if (index + offset >= runStart && index + offset <= runEnd)
                    {
                        sum += samples[index + offset][field] * weights[offset + 2];
                        total += weights[offset + 2];
                    }
                }

                result[index][field] = sum / total;
            }
        }

        return result;
    }

    private static FacePoint[] FramingPath(double[][] samples, double durationMs)
    {
        if (samples.Length == 0)
        {
            return [];
        }

        static FacePoint Center(double[] s) => new(s[1] + s[3] * 0.5, s[2] + s[4] * 0.5);
        var first = samples[0];
        var count = (int)(durationMs / FramingStepMs) + 1;
        var raw = new FacePoint[count];
        var cursor = 0;
        for (var step = 0; step < count; step++)
        {
            var ms = step * FramingStepMs;
            while (cursor + 1 < samples.Length && samples[cursor + 1][0] <= ms)
            {
                cursor++;
            }

            if (ms <= first[0])
            {
                raw[step] = Center(first);
            }
            else if (cursor + 1 < samples.Length)
            {
                var a = samples[cursor];
                var b = samples[cursor + 1];
                var t = (ms - a[0]) / Math.Max(1, b[0] - a[0]);
                var ca = Center(a);
                var cb = Center(b);
                raw[step] = new FacePoint(ca.X + (cb.X - ca.X) * t, ca.Y + (cb.Y - ca.Y) * t);
            }
            else
            {
                raw[step] = Center(samples[cursor]);
            }
        }

        var held = raw[0];
        var settled = new FacePoint[count];
        for (var index = 0; index < count; index++)
        {
            var dx = raw[index].X - held.X;
            var dy = raw[index].Y - held.Y;
            var distance = Math.Sqrt(dx * dx + dy * dy);
            if (distance > FramingDeadZone)
            {
                var move = (distance - FramingDeadZone) / distance;
                held = new FacePoint(held.X + dx * move, held.Y + dy * move);
            }

            settled[index] = held;
        }

        const int radius = FramingSigmaSteps * 3;
        var kernel = new double[radius * 2 + 1];
        for (var d = -radius; d <= radius; d++)
        {
            kernel[d + radius] = Math.Exp(-(double)(d * d) / (2 * FramingSigmaSteps * FramingSigmaSteps));
        }

        var path = new FacePoint[count];
        for (var index = 0; index < count; index++)
        {
            double x = 0, y = 0, total = 0;
            for (var offset = -radius; offset <= radius; offset++)
            {
                var at = index + offset;
                if (at >= 0 && at < count)
                {
                    var weight = kernel[offset + radius];
                    x += settled[at].X * weight;
                    y += settled[at].Y * weight;
                    total += weight;
                }
            }

            path[index] = new FacePoint(x / total, y / total);
        }

        return path;
    }
}
