using System.Runtime.InteropServices;
using Vortice.MediaFoundation;

namespace NativeScreen.Media;

/// <summary>
/// H.264 or HEVC in MP4 through IMFSinkWriter, hardware transforms enabled, BT.709 limited tags.
/// Fragmented output (recordings) survives a crash; plain output (exports) is written on Finish.
/// </summary>
public sealed class VideoFileWriter : IDisposable
{
    private const uint Bt709Primaries = 2;
    private const uint Bt709Transfer = 5;
    private const uint Bt709Matrix = 1;
    private const uint NominalRange16To235 = 2;
    private const double GopSeconds = 2;

    private readonly IMFSinkWriter writer;
    private readonly int videoStream;
    private readonly int audioStream = -1;
    private readonly string path;
    private readonly int frameBytes;
    private bool finished;

    public VideoFileWriter(string path, int width, int height, int fps, int bitrate, bool hevc, bool fragmented, AudioFormat? audio = null)
    {
        if (width % 2 != 0 || height % 2 != 0)
        {
            throw new ArgumentException("NV12 needs even dimensions.");
        }

        this.path = path;
        frameBytes = width * height * 3 / 2;
        MediaFoundationRuntime.EnsureStarted();
        using var attributes = MediaFactory.MFCreateAttributes(2);
        attributes.Set(SinkWriterAttributeKeys.ReadwriteEnableHardwareTransforms, true);
        if (fragmented)
        {
            attributes.Set(TranscodeAttributeKeys.TranscodeContainertype, TranscodeContainerTypeGuids.Fmpeg4);
        }

        writer = MediaFactory.MFCreateSinkWriterFromURL(path, null, attributes);

        using var output = MediaFactory.MFCreateMediaType();
        output.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
        output.Set(MediaTypeAttributeKeys.Subtype, hevc ? VideoFormats.Hevc : VideoFormats.H264);
        output.Set(MediaTypeAttributeKeys.AvgBitrate, (uint)bitrate);
        output.Set(MediaTypeAttributeKeys.FrameSize, Pack(width, height));
        output.Set(MediaTypeAttributeKeys.FrameRate, Pack(fps, 1));
        output.Set(MediaTypeAttributeKeys.PixelAspectRatio, Pack(1, 1));
        output.Set(MediaTypeAttributeKeys.InterlaceMode, (uint)VideoInterlaceMode.Progressive);
        output.Set(MediaTypeAttributeKeys.MaxKeyframeSpacing, (uint)(fps * GopSeconds));
        SetBt709(output);
        videoStream = writer.AddStream(output);

        using var input = MediaFactory.MFCreateMediaType();
        input.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
        input.Set(MediaTypeAttributeKeys.Subtype, VideoFormats.Nv12);
        input.Set(MediaTypeAttributeKeys.FrameSize, Pack(width, height));
        input.Set(MediaTypeAttributeKeys.FrameRate, Pack(fps, 1));
        input.Set(MediaTypeAttributeKeys.PixelAspectRatio, Pack(1, 1));
        input.Set(MediaTypeAttributeKeys.InterlaceMode, (uint)VideoInterlaceMode.Progressive);
        input.Set(MediaTypeAttributeKeys.DefaultStride, (uint)width);
        SetBt709(input);
        writer.SetInputMediaType(videoStream, input, null);

        if (audio is { } format)
        {
            using var aac = MediaFactory.MFCreateMediaType();
            aac.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Audio);
            aac.Set(MediaTypeAttributeKeys.Subtype, AudioFormats.Aac);
            aac.Set(MediaTypeAttributeKeys.AudioSamplesPerSecond, (uint)format.SampleRate);
            aac.Set(MediaTypeAttributeKeys.AudioNumChannels, (uint)format.Channels);
            aac.Set(MediaTypeAttributeKeys.AudioBitsPerSample, 16u);
            aac.Set(MediaTypeAttributeKeys.AudioAvgBytesPerSecond, (uint)(format.BitsPerSecond / 8));
            audioStream = writer.AddStream(aac);
            using var pcm = format.CreatePcmType();
            writer.SetInputMediaType(audioStream, pcm, null);
        }

        writer.BeginWriting();
    }

    /// <summary>Tightly packed NV12: width × height luma, then interleaved chroma.</summary>
    public void WriteFrame(ReadOnlySpan<byte> nv12, double presentationMs, double durationMs)
    {
        if (nv12.Length < frameBytes)
        {
            throw new ArgumentException("Frame is smaller than the configured size.");
        }

        Write(videoStream, nv12[..frameBytes], presentationMs, durationMs);
    }

    /// <summary>Interleaved 16-bit PCM in the format given at construction.</summary>
    public void WriteAudio(ReadOnlySpan<byte> pcm, double presentationMs, double durationMs)
    {
        if (audioStream >= 0 && pcm.Length > 0)
        {
            Write(audioStream, pcm, presentationMs, durationMs);
        }
    }

    public void Finish()
    {
        lock (writer)
        {
            if (!finished)
            {
                finished = true;
                writer.Finalize();
            }
        }
    }

    /// <summary>Stops immediately and removes the partial file.</summary>
    public void Cancel()
    {
        finished = true;
        writer.Dispose();
        if (File.Exists(path))
        {
            File.Delete(path);
        }
    }

    public void Dispose()
    {
        if (!finished)
        {
            Finish();
        }

        writer.Dispose();
    }

    private void Write(int stream, ReadOnlySpan<byte> data, double presentationMs, double durationMs)
    {
        // Screen and system audio arrive on different threads; a sample must not be written after Finish.
        lock (writer)
        {
            if (!finished)
            {
                SinkWriterSamples.Write(writer, stream, data, presentationMs, durationMs);
            }
        }
    }

    private static void SetBt709(IMFMediaType type)
    {
        type.Set(MediaTypeAttributeKeys.VideoPrimaries, Bt709Primaries);
        type.Set(MediaTypeAttributeKeys.TransferFunction, Bt709Transfer);
        type.Set(MediaTypeAttributeKeys.YuvMatrix, Bt709Matrix);
        type.Set(MediaTypeAttributeKeys.VideoNominalRange, NominalRange16To235);
    }

    private static ulong Pack(int high, int low) => ((ulong)high << 32) | (uint)low;
}

internal static class SinkWriterSamples
{
    public static unsafe void Write(IMFSinkWriter writer, int stream, ReadOnlySpan<byte> data, double presentationMs, double durationMs)
    {
        using var buffer = MediaFactory.MFCreateMemoryBuffer(data.Length);
        buffer.Lock(out var pointer, out _, out _);
        data.CopyTo(new Span<byte>((void*)pointer, data.Length));
        buffer.Unlock();
        buffer.CurrentLength = data.Length;
        using var sample = MediaFactory.MFCreateSample();
        sample.AddBuffer(buffer);
        sample.SampleTime = (long)(presentationMs * 10_000);
        sample.SampleDuration = (long)(durationMs * 10_000);
        writer.WriteSample(stream, sample);
    }
}

internal static class MediaFoundationRuntime
{
    private static int started;

    /// <summary>Started once per process and never shut down: sessions can outlive any single window.</summary>
    public static void EnsureStarted()
    {
        if (Interlocked.Exchange(ref started, 1) == 0)
        {
            MediaFactory.MFStartup();
        }
    }
}

public readonly record struct AudioFormat(int SampleRate, int Channels, int BitsPerSecond)
{
    internal IMFMediaType CreatePcmType()
    {
        var pcm = MediaFactory.MFCreateMediaType();
        pcm.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Audio);
        pcm.Set(MediaTypeAttributeKeys.Subtype, AudioFormats.Pcm);
        pcm.Set(MediaTypeAttributeKeys.AudioSamplesPerSecond, (uint)SampleRate);
        pcm.Set(MediaTypeAttributeKeys.AudioNumChannels, (uint)Channels);
        pcm.Set(MediaTypeAttributeKeys.AudioBitsPerSample, 16u);
        pcm.Set(MediaTypeAttributeKeys.AudioBlockAlignment, (uint)(Channels * 2));
        pcm.Set(MediaTypeAttributeKeys.AudioAvgBytesPerSecond, (uint)(SampleRate * Channels * 2));
        return pcm;
    }
}
