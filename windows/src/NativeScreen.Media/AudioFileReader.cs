using Vortice.MediaFoundation;

namespace NativeScreen.Media;

/// <summary>Random access to the first audio stream of a file as 16-bit PCM, at the file's own rate and channel count.</summary>
public sealed class AudioFileReader : IDisposable
{
    private readonly IMFSourceReader reader;

    public int SampleRate { get; }
    public int Channels { get; }

    public AudioFileReader(string path)
    {
        MediaFoundationRuntime.EnsureStarted();
        reader = MediaFactory.MFCreateSourceReaderFromURL(path, null);
        try
        {
            reader.SetStreamSelection(SourceReaderIndex.AllStreams, false);
            reader.SetStreamSelection(SourceReaderIndex.FirstAudioStream, true);
            using var requested = MediaFactory.MFCreateMediaType();
            requested.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Audio);
            requested.Set(MediaTypeAttributeKeys.Subtype, AudioFormats.Pcm);
            requested.Set(MediaTypeAttributeKeys.AudioBitsPerSample, 16u);
            reader.SetCurrentMediaType(SourceReaderIndex.FirstAudioStream, requested);
            using var actual = reader.GetCurrentMediaType(SourceReaderIndex.FirstAudioStream);
            SampleRate = (int)actual.GetUInt32(MediaTypeAttributeKeys.AudioSamplesPerSecond);
            Channels = (int)actual.GetUInt32(MediaTypeAttributeKeys.AudioNumChannels);
        }
        catch
        {
            // A file with no audio stream (a recording without system audio) throws here; the open reader would keep the
            // file locked until a collection, so a project could not be deleted or moved right after it was opened.
            reader.Dispose();
            throw;
        }
    }

    /// <summary>The file has no audio stream, or none this machine can decode.</summary>
    public static AudioFileReader? TryOpen(string path)
    {
        if (!File.Exists(path))
        {
            return null;
        }

        try
        {
            return new AudioFileReader(path);
        }
        catch (SharpGen.Runtime.SharpGenException)
        {
            return null;
        }
    }

    public double DurationMs => Convert.ToInt64(reader.GetPresentationAttribute(SourceReaderIndex.MediaSource, PresentationDescriptionAttributeKeys.Duration).Value) / 10_000.0;

    public void Seek(double positionMs)
    {
        reader.Flush(SourceReaderIndex.FirstAudioStream);
        reader.SetCurrentPosition((long)(Math.Max(0, positionMs) * 10_000));
    }

    /// <summary>The next block of interleaved samples and its start time, or null at the end of the stream.</summary>
    public unsafe (short[] Samples, double StartMs)? ReadBlock()
    {
        while (true)
        {
            using var sample = reader.ReadSample(SourceReaderIndex.FirstAudioStream, SourceReaderControlFlag.None, out _, out var flags, out _);
            if (flags.HasFlag(SourceReaderFlag.EndOfStream))
            {
                return null;
            }

            if (sample is null)
            {
                continue;
            }

            using var buffer = sample.ConvertToContiguousBuffer();
            buffer.Lock(out var pointer, out _, out var length);
            try
            {
                var samples = new short[length / 2];
                new ReadOnlySpan<short>((void*)pointer, samples.Length).CopyTo(samples);
                return (samples, sample.SampleTime / 10_000.0);
            }
            finally
            {
                buffer.Unlock();
            }
        }
    }

    public void Dispose() => reader.Dispose();
}
