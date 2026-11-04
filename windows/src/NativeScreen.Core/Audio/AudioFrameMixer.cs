namespace NativeScreen.Core;

/// <summary>
/// Adds several timed PCM sources into one track. Each source writes at its own position on a shared timeline, and whatever
/// no source wrote comes out as silence, so a quiet app leaves no gap and a late one lands in the right place.
/// </summary>
public sealed class AudioFrameMixer
{
    private const long ResyncFrames = 1920;

    private readonly object gate = new();
    private readonly int channels;
    private readonly int capacity;
    private readonly int[] ring;
    private readonly long[] nextFrame;
    private long drained;

    public AudioFrameMixer(int channels, int capacityFrames, int sources)
    {
        this.channels = channels;
        capacity = capacityFrames;
        ring = new int[capacityFrames * channels];
        nextFrame = new long[sources];
        Array.Fill(nextFrame, -1);
    }

    /// <summary>Clock jitter is ignored, so a source's samples stay contiguous; only a real jump moves it to the given position.</summary>
    public void Add(int source, ReadOnlySpan<short> samples, long positionFrame)
    {
        var frames = samples.Length / channels;
        lock (gate)
        {
            var start = nextFrame[source];
            if (start < 0 || Math.Abs(positionFrame - start) > ResyncFrames)
            {
                start = positionFrame;
            }

            for (var index = 0; index < frames; index++)
            {
                var frame = start + index;
                if (frame < drained)
                {
                    continue;
                }

                if (frame >= drained + capacity)
                {
                    break;
                }

                var slot = (int)(frame % capacity) * channels;
                for (var channel = 0; channel < channels; channel++)
                {
                    ring[slot + channel] += samples[index * channels + channel];
                }
            }

            nextFrame[source] = start + frames;
        }
    }

    /// <summary>Fills output with the mix up to a frame and returns how many frames it wrote; call again until it returns 0.</summary>
    public int Drain(long untilFrame, Span<short> output)
    {
        lock (gate)
        {
            var frames = (int)Math.Clamp(untilFrame - drained, 0, Math.Min(capacity, output.Length / channels));
            for (var index = 0; index < frames; index++)
            {
                var slot = (int)((drained + index) % capacity) * channels;
                for (var channel = 0; channel < channels; channel++)
                {
                    output[index * channels + channel] = (short)Math.Clamp(ring[slot + channel], short.MinValue, short.MaxValue);
                    ring[slot + channel] = 0;
                }
            }

            drained += frames;
            return frames;
        }
    }
}
