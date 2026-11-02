using System.Diagnostics;
using System.Runtime.InteropServices;
using NativeScreen.Core;
using Vortice.MediaFoundation;

namespace NativeScreen.Media;

/// <summary>
/// The camera through a synchronous source reader on its own thread. The source reader converts whatever the camera offers
/// (YUY2, MJPEG) to NV12. Times come from the host clock at delivery; project.camera.delay exists for what remains.
/// </summary>
public sealed class WebcamRecorder : IDisposable
{
    private const int MinimumFps = 15;
    private const int MaximumFps = 60;

    private readonly IMFMediaSource source;
    private readonly IMFSourceReader reader;
    private readonly VideoFileWriter writer;
    private readonly Func<double, double?> elapsed;
    private readonly Thread thread;
    private readonly byte[] nv12;
    private readonly int width;
    private readonly int height;
    private readonly double frameMs;
    private volatile bool stopping;
    private bool wroteFirst;
    private double lastPts;

    /// <summary>The newest frame in NV12 for the floating preview, swapped atomically. Null before the first frame.</summary>
    public event Action<byte[], int, int>? PreviewFrame;

    private WebcamRecorder(IMFMediaSource source, IMFSourceReader reader, string path, int width, int height, int fps, Func<double, double?> elapsed)
    {
        this.source = source;
        this.reader = reader;
        this.elapsed = elapsed;
        this.width = width;
        this.height = height;
        frameMs = 1000.0 / fps;
        nv12 = new byte[width * height * 3 / 2];
        writer = new VideoFileWriter(path, width, height, fps, RecordingRates.WebcamBitrate(width, height), hevc: false, fragmented: true);
        thread = new Thread(Run) { IsBackground = true, Name = "NativeScreen webcam" };
        thread.Start();
    }

    public static IReadOnlyList<CaptureDeviceInfo> Cameras()
    {
        MediaFoundationRuntime.EnsureStarted();
        var results = new List<CaptureDeviceInfo>();
        ForEachCamera((activate, id, name) =>
        {
            results.Add(new CaptureDeviceInfo(id, name, results.Count == 0));
            return false;
        });
        return results;
    }

    public static WebcamRecorder? TryStart(string deviceId, string path, int maxHeight, Func<double, double?> elapsed)
    {
        MediaFoundationRuntime.EnsureStarted();
        IMFMediaSource? source = null;
        ForEachCamera((activate, id, _) =>
        {
            if (id != deviceId)
            {
                return false;
            }

            source = activate.ActivateObject<IMFMediaSource>();
            return true;
        });
        if (source is null)
        {
            return null;
        }

        try
        {
            using var attributes = MediaFactory.MFCreateAttributes(1);
            attributes.Set(SourceReaderAttributeKeys.EnableAdvancedVideoProcessing, true);
            var reader = MediaFactory.MFCreateSourceReaderFromMediaSource(source, attributes);
            reader.SetStreamSelection(SourceReaderIndex.AllStreams, false);
            reader.SetStreamSelection(SourceReaderIndex.FirstVideoStream, true);
            var (nativeWidth, nativeHeight, fps) = ChooseFormat(reader, maxHeight);
            using var requested = MediaFactory.MFCreateMediaType();
            requested.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
            requested.Set(MediaTypeAttributeKeys.Subtype, VideoFormats.Nv12);
            reader.SetCurrentMediaType(SourceReaderIndex.FirstVideoStream, requested);
            return new WebcamRecorder(source, reader, path, RecordingRates.Even(nativeWidth), RecordingRates.Even(nativeHeight), fps, elapsed);
        }
        catch (SharpGen.Runtime.SharpGenException)
        {
            source.Dispose();
            return null;
        }
    }

    public void Stop(double durationMs)
    {
        stopping = true;
        thread.Join();
        if (wroteFirst && durationMs > lastPts + 1)
        {
            writer.WriteFrame(nv12, durationMs, frameMs);
        }

        writer.Dispose();
        source.Stop();
    }

    public void Dispose()
    {
        reader.Dispose();
        source.Shutdown();
        source.Dispose();
    }

    private void Run()
    {
        while (!stopping)
        {
            try
            {
                using var sample = reader.ReadSample(SourceReaderIndex.FirstVideoStream, SourceReaderControlFlag.None, out _, out var flags, out _);
                if (flags.HasFlag(SourceReaderFlag.EndOfStream))
                {
                    return;
                }

                if (sample is not null)
                {
                    HandleSample(sample);
                }
            }
            catch (SharpGen.Runtime.SharpGenException)
            {
                // The camera was unplugged or taken. The track ends here; the recording goes on.
                return;
            }
        }
    }

    private unsafe void HandleSample(IMFSample sample)
    {
        var host = Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency;
        if (elapsed(host) is not { } pts)
        {
            return;
        }

        using var buffer = sample.ConvertToContiguousBuffer();
        buffer.Lock(out var pointer, out _, out var length);
        try
        {
            CopyNv12(new ReadOnlySpan<byte>((void*)pointer, length));
        }
        finally
        {
            buffer.Unlock();
        }

        if (!wroteFirst)
        {
            // A camera starts late. Readers measure from a track's first frame, so the track must start at zero.
            wroteFirst = true;
            writer.WriteFrame(nv12, 0, frameMs);
        }

        if (pts > lastPts)
        {
            writer.WriteFrame(nv12, pts, frameMs);
            lastPts = pts;
            PreviewFrame?.Invoke(nv12, width, height);
        }
    }

    private void CopyNv12(ReadOnlySpan<byte> frame)
    {
        // Decoders may pad rows to the macroblock height; chroma begins two thirds in (spec/06 ADR-21).
        var stride = (frame.Length * 2 / 3) / Math.Max(1, height);
        stride = stride >= width ? stride : width;
        var chromaOffset = frame.Length / 3 * 2;
        for (var y = 0; y < height; y++)
        {
            frame.Slice(y * stride, width).CopyTo(nv12.AsSpan(y * width, width));
        }

        for (var y = 0; y < height / 2; y++)
        {
            frame.Slice(chromaOffset + y * stride, width).CopyTo(nv12.AsSpan(width * height + y * width, width));
        }
    }

    /// <summary>The largest format within the height limit at the highest frame rate, like the macOS format picker.</summary>
    private static (int Width, int Height, int Fps) ChooseFormat(IMFSourceReader reader, int maxHeight)
    {
        var best = (Width: 0, Height: 0, Fps: 0);
        IMFMediaType? bestType = null;
        for (var index = 0; ; index++)
        {
            IMFMediaType type;
            try
            {
                type = reader.GetNativeMediaType(SourceReaderIndex.FirstVideoStream, index);
            }
            catch (SharpGen.Runtime.SharpGenException)
            {
                break;
            }

            var size = type.GetUInt64(MediaTypeAttributeKeys.FrameSize);
            var rate = type.GetUInt64(MediaTypeAttributeKeys.FrameRate);
            var w = (int)(size >> 32);
            var h = (int)(size & 0xFFFFFFFF);
            var denominator = (int)(rate & 0xFFFFFFFF);
            var fps = denominator == 0 ? 30 : (int)Math.Round((rate >> 32) / (double)denominator);
            var better = h <= maxHeight && fps >= MinimumFps && fps <= MaximumFps && (h > best.Height || (h == best.Height && fps > best.Fps));
            if (better)
            {
                bestType?.Dispose();
                bestType = type;
                best = (w, h, fps);
            }
            else
            {
                type.Dispose();
            }
        }

        if (bestType is null)
        {
            throw new InvalidOperationException("The camera offers no usable format.");
        }

        reader.SetCurrentMediaType(SourceReaderIndex.FirstVideoStream, bestType);
        bestType.Dispose();
        return best;
    }

    /// <summary>Calls back for each camera until the callback returns true.</summary>
    private static unsafe void ForEachCamera(Func<IMFActivate, string, string, bool> visit)
    {
        using var attributes = MediaFactory.MFCreateAttributes(1);
        attributes.Set(CaptureDeviceAttributeKeys.SourceType, CaptureDeviceAttributeKeys.SourceTypeVidcap);
        Marshal.ThrowExceptionForHR(MFEnumDeviceSources(attributes.NativePointer, out var array, out var count));
        var stop = false;
        for (var index = 0; index < count; index++)
        {
            using var activate = new IMFActivate(((nint*)array)[index]);
            if (!stop)
            {
                var id = activate.GetString(CaptureDeviceAttributeKeys.SourceTypeVidcapSymbolicLink);
                var name = activate.GetString(CaptureDeviceAttributeKeys.FriendlyName);
                stop = visit(activate, id, name);
            }
        }

        Marshal.FreeCoTaskMem(array);
    }

    [DllImport("mf.dll", ExactSpelling = true)]
    private static extern int MFEnumDeviceSources(nint attributes, out nint activates, out uint count);
}
