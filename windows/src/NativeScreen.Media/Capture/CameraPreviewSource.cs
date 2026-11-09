using Vortice.MediaFoundation;

namespace NativeScreen.Media;

/// <summary>The camera for the floating preview before a recording starts. Open and dispose it off the UI thread.</summary>
public sealed class CameraPreviewSource : IDisposable
{
    private const int PreviewMaxHeight = 720;
    private const int JoinTimeoutMs = 2000;

    private readonly IMFMediaSource source;
    private readonly IMFSourceReader reader;
    private readonly Action<byte[], int, int> frame;
    private readonly Thread thread;
    private readonly byte[] nv12;
    private readonly int width;
    private readonly int height;
    private volatile bool stopping;

    private CameraPreviewSource(IMFMediaSource source, IMFSourceReader reader, int width, int height, Action<byte[], int, int> frame)
    {
        this.source = source;
        this.reader = reader;
        this.width = width;
        this.height = height;
        this.frame = frame;
        nv12 = new byte[width * height * 3 / 2];
        thread = new Thread(Run) { IsBackground = true, Name = "NativeScreen camera preview" };
        thread.Start();
    }

    /// <summary>Null when the camera cannot be opened. Frames arrive on a background thread, and the buffer is reused after the call.</summary>
    public static CameraPreviewSource? TryStart(string deviceId, Action<byte[], int, int> frame)
    {
        try
        {
            return WebcamRecorder.OpenCamera(deviceId, PreviewMaxHeight) is { } opened
                ? new CameraPreviewSource(opened.Source, opened.Reader, opened.Width, opened.Height, frame)
                : null;
        }
        catch (Exception exception) when (exception is SharpGen.Runtime.SharpGenException or InvalidOperationException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    public void Dispose()
    {
        stopping = true;
        try
        {
            // Stopping ends a read that is waiting for a frame.
            source.Stop();
        }
        catch (SharpGen.Runtime.SharpGenException)
        {
            // Already gone with the device.
        }

        if (thread.Join(JoinTimeoutMs))
        {
            reader.Dispose();
        }

        WebcamRecorder.Release(source);
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
                    Deliver(sample);
                }
            }
            catch (SharpGen.Runtime.SharpGenException)
            {
                // Unplugged or taken by another app. The window keeps its last frame.
                return;
            }
        }
    }

    private unsafe void Deliver(IMFSample sample)
    {
        using var buffer = sample.ConvertToContiguousBuffer();
        buffer.Lock(out var pointer, out _, out var length);
        try
        {
            WebcamRecorder.CopyNv12(new ReadOnlySpan<byte>((void*)pointer, length), nv12, width, height);
        }
        finally
        {
            buffer.Unlock();
        }

        frame(nv12, width, height);
    }
}
