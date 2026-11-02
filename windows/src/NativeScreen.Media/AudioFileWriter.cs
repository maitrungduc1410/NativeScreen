using Vortice.MediaFoundation;

namespace NativeScreen.Media;

/// <summary>An audio-only AAC file. Fragmented like the video tracks, so a crash leaves a playable file.</summary>
public sealed class AudioFileWriter : IDisposable
{
    private readonly IMFSinkWriter writer;
    private readonly int stream;
    private bool finished;

    public AudioFileWriter(string path, AudioFormat format)
    {
        MediaFoundationRuntime.EnsureStarted();
        using var attributes = MediaFactory.MFCreateAttributes(1);
        attributes.Set(TranscodeAttributeKeys.TranscodeContainertype, TranscodeContainerTypeGuids.Fmpeg4);
        writer = MediaFactory.MFCreateSinkWriterFromURL(path, null, attributes);
        using var aac = MediaFactory.MFCreateMediaType();
        aac.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Audio);
        aac.Set(MediaTypeAttributeKeys.Subtype, AudioFormats.Aac);
        aac.Set(MediaTypeAttributeKeys.AudioSamplesPerSecond, (uint)format.SampleRate);
        aac.Set(MediaTypeAttributeKeys.AudioNumChannels, (uint)format.Channels);
        aac.Set(MediaTypeAttributeKeys.AudioBitsPerSample, 16u);
        aac.Set(MediaTypeAttributeKeys.AudioAvgBytesPerSecond, (uint)(format.BitsPerSecond / 8));
        stream = writer.AddStream(aac);
        using var pcm = format.CreatePcmType();
        writer.SetInputMediaType(stream, pcm, null);
        writer.BeginWriting();
    }

    public void Write(ReadOnlySpan<byte> pcm, double presentationMs, double durationMs) =>
        SinkWriterSamples.Write(writer, stream, pcm, presentationMs, durationMs);

    public void Dispose()
    {
        if (!finished)
        {
            finished = true;
            writer.Finalize();
        }

        writer.Dispose();
    }
}
