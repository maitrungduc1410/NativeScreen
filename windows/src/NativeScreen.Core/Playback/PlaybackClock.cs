using System.Diagnostics;

namespace NativeScreen.Core;

public readonly record struct AudioClockSample(double PositionMs, double DeviceLatencyMs, double QpcAtSampleMs);

public static class AudioMasterClock
{
    public static double TimelineMs(AudioClockSample sample, double qpcNowMs) =>
        sample.PositionMs - sample.DeviceLatencyMs + (qpcNowMs - sample.QpcAtSampleMs);
}

public sealed class PlaybackClock
{
    private const double AudioSyncToleranceMs = 15;
    private readonly Func<double> nowMs;
    private double originTimelineMs;
    private double startQpcMs;
    private double pausedTimelineMs;
    private bool running;

    public PlaybackClock(Func<double>? nowMs = null)
    {
        this.nowMs = nowMs ?? DefaultNowMs;
    }

    public bool IsRunning => running;
    public AudioClockSample? Audio { get; set; }

    public void PrimeAndStart(double timelineMs)
    {
        originTimelineMs = timelineMs;
        startQpcMs = nowMs();
        pausedTimelineMs = timelineMs;
        running = true;
    }

    public double PositionMs
    {
        get
        {
            if (Audio is AudioClockSample sample)
            {
                return AudioMasterClock.TimelineMs(sample, nowMs());
            }

            return running ? originTimelineMs + (nowMs() - startQpcMs) : pausedTimelineMs;
        }
    }

    /// <summary>The audio device is the master. Small differences are its position's granularity and would only make video jitter.</summary>
    public void SyncToAudio(double audioTimelineMs)
    {
        if (running && Math.Abs(audioTimelineMs - PositionMs) > AudioSyncToleranceMs)
        {
            PrimeAndStart(audioTimelineMs);
        }
    }

    public void Pause()
    {
        if (!running)
        {
            return;
        }

        pausedTimelineMs = PositionMs;
        running = false;
        Audio = null;
    }

    private static double DefaultNowMs() =>
        Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency;
}

public sealed class FrameRing
{
    public const int Capacity = 4;
    private readonly double[] pts = new double[Capacity];
    private int count;
    private int next;

    public int Count => count;

    public void Push(double presentationMs)
    {
        pts[next] = presentationMs;
        next = (next + 1) % Capacity;
        if (count < Capacity)
        {
            count++;
        }
    }

    public double? NewestAtOrBefore(double clockMs)
    {
        double? best = null;
        var start = count == Capacity ? next : 0;
        for (var i = 0; i < count; i++)
        {
            var value = pts[(start + i) % Capacity];
            if (value <= clockMs && (best is null || value > best))
            {
                best = value;
            }
        }

        return best;
    }
}

public sealed class LateFrameCounter
{
    public int Presented { get; private set; }
    public int Late { get; private set; }
    public double LateRatio => Presented == 0 ? 0 : (double)Late / Presented;

    public void Present(double framePtsMs, double clockMs, double frameDurationMs)
    {
        Presented++;
        if (clockMs - framePtsMs > frameDurationMs)
        {
            Late++;
        }
    }
}

public sealed class ScrubCoalescer
{
    private long latest;

    public long Submit() => Interlocked.Increment(ref latest);

    public bool IsLatest(long token) => token == Volatile.Read(ref latest);
}

public static class PreviewScheduler
{
    public static bool BlocksIdle(bool isPlaying, bool animating) => !isPlaying && !animating;
}
