using NativeScreen.Core;

namespace NativeScreen.Media;

/// <summary>
/// One decode thread and a small ring of frames ahead of the requested time. The render thread never waits on it: it takes
/// the newest frame at or before its clock, and keeps the frame it already has while a seek runs, so seeking never shows an
/// empty screen. A running seek follows the newest request forward instead of starting over (spec/06 ADR-34).
/// </summary>
public sealed class VideoPlaybackSource : IVideoFrameSource, IDisposable
{
    private const int RingCapacity = 6;
    private const double SeekThresholdMs = 500;
    private const long SeekProgressIntervalMs = 100;

    private readonly VideoFileReader reader;
    private readonly VideoFramePool pool = new();
    private readonly List<VideoFrame> ring = [];
    private readonly object gate = new();
    private readonly AutoResetEvent wake = new(false);
    private readonly Thread thread;
    private VideoFrame? handed;
    private bool handedRetired;
    private double requestedMs;
    private double coveredFromMs;
    private bool seekPending = true;
    private bool seeking;
    private bool endOfStream;
    private volatile bool stopping;

    public VideoPlaybackSource(string path)
    {
        reader = new VideoFileReader(path);
        thread = new Thread(Run) { IsBackground = true, Name = "NativeScreen video decode" };
        thread.Start();
    }

    public int Width => reader.Width;
    public int Height => reader.Height;

    /// <summary>Raised on the decode thread when a seek has covered the newest request.</summary>
    public event Action? FrameDecoded;

    public VideoFrame? FrameAt(double sourceMs)
    {
        lock (gate)
        {
            // A camera delay can ask for a time before the recording; that is its first frame, not a seek.
            requestedMs = Math.Max(0, sourceMs);
            VideoFrame? best = null;
            foreach (var frame in ring)
            {
                if (frame.PresentationMs <= sourceMs + 0.5)
                {
                    best = frame;
                }
            }

            var needsEarlier = requestedMs < coveredFromMs - 1;
            if (needsEarlier && !seeking)
            {
                seekPending = true;
            }

            wake.Set();
            var first = ring.Count > 0 ? ring[0] : null;
            var chosen = best ?? (needsEarlier ? handed ?? first : first ?? handed);
            if (!ReferenceEquals(chosen, handed))
            {
                // The render thread is done with the last frame it was given, now that it asks again.
                if (handedRetired && handed is not null)
                {
                    pool.Return(handed.Nv12);
                }

                handed = chosen;
                handedRetired = false;
            }

            return chosen;
        }
    }

    /// <summary>Buffers are 9 MB at 3072x1920; dropping them to the GC caused pauses long enough to miss frames. Call under the gate.</summary>
    private void Retire(VideoFrame frame)
    {
        if (ReferenceEquals(frame, handed))
        {
            handedRetired = true;
        }
        else
        {
            pool.Return(frame.Nv12);
        }
    }

    private void RetireAll()
    {
        foreach (var frame in ring)
        {
            Retire(frame);
        }

        ring.Clear();
    }

    public void Dispose()
    {
        stopping = true;
        wake.Set();
        thread.Join();
        wake.Dispose();
        reader.Dispose();
    }

    private void Run()
    {
        while (!stopping)
        {
            bool seek;
            bool hasRoom;
            lock (gate)
            {
                seek = seekPending;
                seekPending = false;
                while (!seek && ring.Count > 1 && ring[1].PresentationMs <= requestedMs)
                {
                    // Keeps the frame at the clock and drops everything older.
                    Retire(ring[0]);
                    ring.RemoveAt(0);
                    coveredFromMs = ring[0].PresentationMs;
                }

                // Falling behind jumps only to a later keyframe; going back to the same one would throw away the work done.
                seek = seek || (ring.Count > 0 && !endOfStream && requestedMs > ring[^1].PresentationMs + SeekThresholdMs && reader.CanSkipAhead(ring[^1].PresentationMs, requestedMs));
                seeking = seek;
                hasRoom = seek || (ring.Count < RingCapacity && !endOfStream);
            }

            if (seek)
            {
                SeekToRequest();
                continue;
            }

            if (!hasRoom)
            {
                wake.WaitOne(50);
                continue;
            }

            var frame = reader.ReadNext(pool);
            lock (gate)
            {
                if (frame is null)
                {
                    endOfStream = true;
                }
                else
                {
                    ring.Add(frame);
                }
            }
        }
    }

    /// <summary>
    /// A seek lands on a keyframe before the target, so it decodes forward until the newest request is covered. A short seek
    /// publishes only its result; a long one shows a frame now and then, so a pointer outrunning the decoder still moves the
    /// picture. The frame just before the target stays with it: a recording of a still screen can have seconds between
    /// frames, and that older frame is the right one to show.
    /// </summary>
    private void SeekToRequest()
    {
        double target;
        lock (gate)
        {
            target = requestedMs;
            RetireAll();
            endOfStream = false;
        }

        reader.Seek(target);
        VideoFrame? before = null;
        var reached = target;
        var lastShown = Environment.TickCount64;
        while (!stopping)
        {
            var frame = reader.ReadNext(pool);
            var restart = false;
            var covered = false;
            lock (gate)
            {
                var wanted = requestedMs;
                if (wanted < reached - 1)
                {
                    // The request moved back past what this decode can still reach.
                    restart = true;
                }
                else if (frame is null || frame.PresentationMs >= wanted - 0.5)
                {
                    covered = true;
                    Publish(before, frame, target);
                }
                else if (reader.CanSkipAhead(frame.PresentationMs, wanted))
                {
                    restart = true;
                }
                else if (Environment.TickCount64 - lastShown >= SeekProgressIntervalMs)
                {
                    lastShown = Environment.TickCount64;
                    RetireAll();
                    ring.Add(frame);
                    reached = frame.PresentationMs;
                    ReturnToPool(before);
                    before = null;
                    frame = null;
                }

                if (restart)
                {
                    target = wanted;
                    reached = wanted;
                    RetireAll();
                }
            }

            if (covered)
            {
                FrameDecoded?.Invoke();
                return;
            }

            if (frame is not null)
            {
                ReturnToPool(before);
                before = frame;
                reached = frame.PresentationMs;
            }

            if (restart)
            {
                ReturnToPool(before);
                before = null;
                reader.Seek(target);
            }
        }

        ReturnToPool(before);
    }

    /// <summary>Call under the gate. A frame shown during the seek counts as the one before the target when nothing newer does.</summary>
    private void Publish(VideoFrame? before, VideoFrame? frame, double target)
    {
        if (before is not null)
        {
            RetireAll();
            ring.Add(before);
        }

        // A keyframe can land just after the target, and asking again would land on it again.
        coveredFromMs = ring.Count > 0 ? ring[0].PresentationMs : Math.Min(target, frame?.PresentationMs ?? target);
        if (frame is null)
        {
            endOfStream = true;
        }
        else
        {
            ring.Add(frame);
        }

        seeking = false;
    }

    private void ReturnToPool(VideoFrame? frame)
    {
        if (frame is not null)
        {
            pool.Return(frame.Nv12);
        }
    }
}
