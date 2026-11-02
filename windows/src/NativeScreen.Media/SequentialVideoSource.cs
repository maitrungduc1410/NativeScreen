using NativeScreen.Core;

namespace NativeScreen.Media;

/// <summary>Exact frames for export: blocks until the requested time is decoded, and only seeks across a cut.</summary>
public sealed class SequentialVideoSource(string path) : IVideoFrameSource, IDisposable
{
    private const double SeekAheadMs = 2000;
    private readonly VideoFileReader reader = new(path);
    private readonly VideoFramePool pool = new();
    private VideoFrame? current;
    private VideoFrame? next;

    public VideoFrame? FrameAt(double sourceMs)
    {
        if (current is null || sourceMs < current.PresentationMs - 0.5 || sourceMs > current.PresentationMs + SeekAheadMs)
        {
            reader.Seek(Math.Max(0, sourceMs));
            Recycle(current);
            Recycle(next);
            current = reader.ReadNext(pool);
            next = reader.ReadNext(pool);
        }

        while (next is not null && next.PresentationMs <= sourceMs + 0.5)
        {
            // The caller finished with the old frame when it asked for this one.
            Recycle(current);
            current = next;
            next = reader.ReadNext(pool);
        }

        return current;
    }

    public void Dispose() => reader.Dispose();

    private void Recycle(VideoFrame? frame)
    {
        if (frame is not null)
        {
            pool.Return(frame.Nv12);
        }
    }
}
