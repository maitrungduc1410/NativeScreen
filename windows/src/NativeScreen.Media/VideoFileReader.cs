using System.Runtime.InteropServices;
using NativeScreen.Core;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.MediaFoundation;

namespace NativeScreen.Media;

/// <summary>
/// Sequential NV12 decode through IMFSourceReader with hardware transforms. Frames arrive in system memory, so they are
/// safe to hand between threads without sharing the compositor's device (spec/06 ADR-21).
/// </summary>
public sealed class VideoFileReader : IDisposable
{
    private const double UnknownKeyframeIntervalMs = 5000;

    private readonly IMFSourceReader reader;
    private int stride;
    private bool strideMeasured;
    private readonly double startMs;
    private readonly Mp4FragmentIndex? index;
    private readonly DecodeAccelerator? accelerator;
    private int nextIndex;
    private bool resolveAfterSeek;
    private double lastSeekMs;

    public int Width { get; }
    public int Height { get; }

    /// <summary>Time of the last frame for a fragmented file; otherwise the container's duration.</summary>
    public double DurationMs => index is not null ? index.TimesMs[^1] : (reader.GetPresentationAttribute(SourceReaderIndex.MediaSource, PresentationDescriptionAttributeKeys.Duration) is var ticks ? Convert.ToInt64(ticks.Value) / 10_000.0 : 0);

    public VideoFileReader(string path)
    {
        MediaFoundationRuntime.EnsureStarted();
        index = Mp4FragmentIndex.TryRead(path, "vide");
        using var attributes = MediaFactory.MFCreateAttributes(3);
        attributes.Set(SourceReaderAttributeKeys.EnableAdvancedVideoProcessing, false);
        attributes.Set(SinkWriterAttributeKeys.ReadwriteEnableHardwareTransforms, true);
        accelerator = DecodeAccelerator.TryCreate();
        if (accelerator is not null)
        {
            attributes.Set(SourceReaderAttributeKeys.D3DManager, accelerator.Manager);
        }        reader = MediaFactory.MFCreateSourceReaderFromURL(path, attributes);
        reader.SetStreamSelection(SourceReaderIndex.AllStreams, false);
        reader.SetStreamSelection(SourceReaderIndex.FirstVideoStream, true);

        using var requested = MediaFactory.MFCreateMediaType();
        requested.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
        requested.Set(MediaTypeAttributeKeys.Subtype, VideoFormats.Nv12);
        reader.SetCurrentMediaType(SourceReaderIndex.FirstVideoStream, requested);

        using var actual = reader.GetCurrentMediaType(SourceReaderIndex.FirstVideoStream);
        var size = actual.GetUInt64(MediaTypeAttributeKeys.FrameSize);
        var codedWidth = (int)(size >> 32);
        var codedHeight = (int)(size & 0xFFFFFFFF);
        stride = ReadStride(actual, codedWidth);
        (Width, Height) = DisplaySize(actual, codedWidth, codedHeight);

        // The recorded timeline starts at the first frame, and a file may not start at zero.
        using var first = reader.ReadSample(SourceReaderIndex.FirstVideoStream, SourceReaderControlFlag.None, out _, out _, out _);
        startMs = first is null ? 0 : first.SampleTime / 10_000.0;
        Seek(0);
    }

    /// <summary>The next frame, or null at the end of the stream. The buffer comes from the pool when one is given.</summary>
    public unsafe VideoFrame? ReadNext(VideoFramePool? pool = null)
    {
        while (true)
        {
            using var sample = reader.ReadSample(
                SourceReaderIndex.FirstVideoStream,
                SourceReaderControlFlag.None,
                out _,
                out var flags,
                out _);
            if (flags.HasFlag(SourceReaderFlag.EndOfStream))
            {
                return null;
            }

            if (sample is null)
            {
                continue;
            }

            var needed = Width * Height * 3 / 2;
            var data = pool?.Rent(needed) ?? new byte[needed];
            using var buffer = sample.ConvertToContiguousBuffer();
            buffer.Lock(out var pointer, out _, out var length);
            try
            {
                MeasureStride(length);
                var source = (byte*)pointer;
                // Decoders pad rows to their macroblock height, which the media type does not report. NV12 is always
                // two thirds luma, so the buffer length gives the plane offset whatever the padding is.
                var chroma = source + length / 3 * 2;

                fixed (byte* target = data)
                {
                    for (var y = 0; y < Height; y++)
                    {
                        Buffer.MemoryCopy(source + y * stride, target + y * Width, Width, Width);
                    }

                    for (var y = 0; y < Height / 2; y++)
                    {
                        Buffer.MemoryCopy(chroma + y * stride, target + Width * Height + y * Width, Width, Width);
                    }
                }
            }
            finally
            {
                buffer.Unlock();
            }

            return new VideoFrame(data, Width, Height, PresentationMs(sample.SampleTime / 10_000.0));
        }
    }

    public void Seek(double positionMs)
    {
        lastSeekMs = positionMs;
        reader.Flush(SourceReaderIndex.FirstVideoStream);
        if (index is null)
        {
            reader.SetCurrentPosition((long)((positionMs + startMs) * 10_000));
            return;
        }

        // Keyframe times are the ones Media Foundation has right, because its seek table holds them.
        nextIndex = index.KeyframeAtOrBefore(positionMs);
        resolveAfterSeek = true;
        reader.SetCurrentPosition((long)((index.TimesMs[nextIndex] + startMs) * 10_000));
    }

    /// <summary>
    /// Whether a seek to a later time would start past a position. It also has to be past the last seek's own target: a
    /// seek can land well before the keyframe it asked for, and asking again would land there again, for ever.
    /// </summary>
    public bool CanSkipAhead(double positionMs, double targetMs)
    {
        var reached = Math.Max(positionMs, lastSeekMs);
        if (index is null)
        {
            // Without an index the keyframes are unknown, so only a gap longer than any keyframe interval counts.
            return targetMs - reached > UnknownKeyframeIntervalMs;
        }

        return index.TimesMs[index.KeyframeAtOrBefore(targetMs)] > reached;
    }

    private double PresentationMs(double reportedMs)
    {
        if (index is null)
        {
            return reportedMs - startMs;
        }

        if (resolveAfterSeek)
        {
            // A seek always lands on a keyframe, though not always the one asked for.
            resolveAfterSeek = false;
            nextIndex = index.NearestKeyframe(reportedMs - startMs);
        }

        var last = index.TimesMs.Length - 1;
        return index.TimesMs[Math.Min(nextIndex++, last)];
    }

    public void Dispose()
    {
        reader.Dispose();
        accelerator?.Dispose();
    }

    private static (int Width, int Height) DisplaySize(IMFMediaType type, int codedWidth, int codedHeight)
    {
        try
        {
            // MFVideoArea: offset x and y as two MFOffset values, then width and height.
            var area = new byte[16];
            type.GetBlob(MediaTypeAttributeKeys.MinimumDisplayAperture, area);
            var width = BitConverter.ToInt32(area, 8);
            var height = BitConverter.ToInt32(area, 12);
            if (width > 0 && height > 0)
            {
                return (width & ~1, height & ~1);
            }
        }
        catch (SharpGen.Runtime.SharpGenException)
        {
            // Not every source reports an aperture; the coded size is then the display size.
        }

        return (codedWidth & ~1, codedHeight & ~1);
    }

    /// <summary>
    /// A hardware decoder pads rows to its macroblock width: 1904 for a 1900-wide video. The media type still says 1900,
    /// which shears the picture by 4 pixels per row. The locked buffer is pitch x padded height x 3/2, so the first frame's
    /// length gives the pitch. (IMF2DBuffer reports the pitch of the mapped texture, which is not the layout Lock returns.)
    /// </summary>
    private void MeasureStride(int length)
    {
        if (strideMeasured)
        {
            return;
        }

        strideMeasured = true;
        var luma = length / 3 * 2;
        for (var alignment = 1; alignment <= 128; alignment *= 2)
        {
            var pitch = (Width + alignment - 1) / alignment * alignment;
            if (luma % pitch == 0 && luma / pitch is var rows && rows >= Height && rows < Height + 128)
            {
                stride = pitch;
                return;
            }
        }
    }

    private static int ReadStride(IMFMediaType type, int fallback)
    {
        try
        {
            return Math.Abs((int)type.GetUInt32(MediaTypeAttributeKeys.DefaultStride));
        }
        catch (SharpGen.Runtime.SharpGenException)
        {
            return fallback;
        }
    }
}

/// <summary>
/// Without a device the source reader only finds software decoders, whatever the hardware-transforms flag says: a 3072x1920
/// recording cost over 2 cores to play. Each reader has its own device, so the render thread never shares one with a decoder.
/// </summary>
internal sealed class DecodeAccelerator : IDisposable
{
    private readonly ID3D11Device device;

    private DecodeAccelerator(ID3D11Device device, IMFDXGIDeviceManager manager)
    {
        this.device = device;
        Manager = manager;
    }

    public IMFDXGIDeviceManager Manager { get; }

    public static DecodeAccelerator? TryCreate()
    {
        var result = D3D11.D3D11CreateDevice(null, DriverType.Hardware, DeviceCreationFlags.VideoSupport | DeviceCreationFlags.BgraSupport, [FeatureLevel.Level_11_1, FeatureLevel.Level_11_0], out ID3D11Device? device, out _, out ID3D11DeviceContext? context);
        context?.Dispose();
        if (result.Failure || device is null)
        {
            return null;
        }

        using (var protection = device.QueryInterface<ID3D11Multithread>())
        {
            protection.SetMultithreadProtected(true);
        }

        var manager = MediaFactory.MFCreateDXGIDeviceManager();
        manager.ResetDevice(device);
        return new DecodeAccelerator(device, manager);
    }

    public void Dispose()
    {
        Manager.Dispose();
        device.Dispose();
    }
}
