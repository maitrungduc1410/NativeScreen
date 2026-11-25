using System.Collections.Concurrent;
using NativeScreen.Core;
using NativeScreen.Media;

namespace NativeScreen.Intelligence;

/// <summary>
/// Reads the screen video once for hover highlights (spec/06 ADR-108): one Media Foundation pass as NV12, frames handed to
/// <see cref="HoverChangeDetector"/>. Frame times are counted from the first frame, like the telemetry. Decoding runs on its
/// own thread a few frames ahead of the resampling and comparing, so the two overlap.
/// </summary>
public static class HoverChangeScanner
{
    /// <summary>Decoded frames waiting for the detector: a 4K frame is 12 MB, so only a few.</summary>
    private const int QueuedFrames = 4;

    /// <summary>Throws when cancelled or when the video cannot be read.</summary>
    public static HoverChangeDetector.Stored Scan(
        string videoPath,
        IReadOnlyList<CursorSampleEvent> cursor,
        IReadOnlyList<ClickEvent> clicks,
        MotionPointSize pointSize,
        IProgress<double>? progress,
        CancellationToken cancel)
    {
        var pool = new VideoFramePool();
        using var staged = StagedVideoReader.TryOpen(videoPath);
        using var plain = staged is null ? new VideoFileReader(videoPath) : null;
        var durationMs = staged?.DurationMs ?? plain!.DurationMs;
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        Task? producer = null;
        try
        {
            return HoverChangeDetector.Scan(
                    wanted =>
                    {
                        var queue = new BlockingCollection<VideoFrame>(QueuedFrames);
                        producer = Task.Run(() => Produce(staged is not null ? staged.Read(pool, wanted) : Read(plain!, pool, wanted), queue, stop.Token));
                        return Consume(queue, cancel);
                    },
                    Return,
                    durationMs,
                    cursor,
                    clicks,
                    pointSize,
                    fraction =>
                    {
                        progress?.Report(fraction);
                        return !cancel.IsCancellationRequested;
                    })
                ?? throw new OperationCanceledException(cancel);
        }
        finally
        {
            // The detector stops reading after the last mouse movement; the decoding thread stops with it, before the
            // readers are disposed.
            stop.Cancel();
            try
            {
                producer?.GetAwaiter().GetResult();
            }
            catch (OperationCanceledException)
            {
            }
        }

        void Return(byte[] buffer)
        {
            if (buffer.Length > 0)
            {
                pool.Return(buffer);
            }
        }
    }

    // Stopping is normal (the detector is done after the last mouse movement), so it is a flag checked here, not an exception
    // thrown out of the task: a debugger stops on that as if the app had crashed.
    private static void Produce(IEnumerable<VideoFrame> frames, BlockingCollection<VideoFrame> queue, CancellationToken stop)
    {
        try
        {
            foreach (var frame in frames)
            {
                while (!queue.TryAdd(frame, 50))
                {
                    if (stop.IsCancellationRequested)
                    {
                        return;
                    }
                }

                if (stop.IsCancellationRequested)
                {
                    return;
                }
            }
        }
        finally
        {
            queue.CompleteAdding();
        }
    }

    private static IEnumerable<HoverChangeDetector.Nv12Frame> Consume(BlockingCollection<VideoFrame> queue, CancellationToken cancel)
    {
        foreach (var frame in queue.GetConsumingEnumerable(cancel))
        {
            yield return new HoverChangeDetector.Nv12Frame(frame.Nv12, frame.Width, frame.Height, frame.PresentationMs);
        }
    }

    private static IEnumerable<VideoFrame> Read(VideoFileReader reader, VideoFramePool pool, Func<double, bool> wanted)
    {
        while (reader.ReadNext(pool, wanted) is { } frame)
        {
            yield return frame;
        }
    }
}
