using NativeScreen.Core;

namespace NativeScreen.Media;

/// <summary>
/// One decode thread and a small ring of frames ahead of the requested time. The render thread never waits on it: it takes
/// the newest frame at or before its clock, and asking for a time outside the ring makes the decoder seek (latest wins).
/// </summary>
public sealed class VideoPlaybackSource : IVideoFrameSource, IDisposable
{
    private const int RingCapacity = 6;
    private const double SeekThresholdMs = 500;

    private readonly VideoFileReader reader;
    private readonly VideoFramePool pool = new();
    private readonly List<VideoFrame> ring = [];
    private readonly object gate = new();
    private readonly AutoResetEvent wake = new(false);
    private readonly Thread thread;
    private double requestedMs;
    private bool seekPending = true;
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

    /// <summary>Raised on the decode thread when a frame that the UI might be waiting for arrives after a seek.</summary>
    public event Action? FrameDecoded;

    public VideoFrame? FrameAt(double sourceMs)
    {
        lock (gate)
        {
            requestedMs = sourceMs;
            VideoFrame? best = null;
            foreach (var frame in ring)
            {
                if (frame.PresentationMs <= sourceMs + 0.5)
                {
                    best = frame;
                }
            }

            var outside = ring.Count == 0
                || sourceMs < ring[0].PresentationMs - 1
                || sourceMs > ring[^1].PresentationMs + SeekThresholdMs;
            if (outside && !(endOfStream && sourceMs >= (ring.Count > 0 ? ring[^1].PresentationMs : 0)))
            {
                seekPending = true;
            }

            wake.Set();
            return best ?? (ring.Count > 0 ? ring[0] : null);
        }
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
            double target;
            bool hasRoom;
            lock (gate)
            {
                seek = seekPending;
                seekPending = false;
                target = requestedMs;
                while (!seek && ring.Count > 1 && ring[1].PresentationMs <= target)
                {
                    // Keeps the frame at the clock and drops everything older; its buffer may still be on screen, so it goes to the GC.
                    ring.RemoveAt(0);
                }

                hasRoom = seek || (ring.Count < RingCapacity && !endOfStream);
            }

            if (seek)
            {
                reader.Seek(target);
                lock (gate)
                {
                    ring.Clear();
                    endOfStream = false;
                }
            }
            else if (!hasRoom)
            {
                wake.WaitOne(50);
                continue;
            }

            var frame = reader.ReadNext();
            var seeking = seek;
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

            if (seeking)
            {
                // A seek lands on the keyframe before the target, so decode forward until the target is covered.
                while (!stopping && frame is not null && frame.PresentationMs < target - 20)
                {
                    lock (gate)
                    {
                        if (seekPending)
                        {
                            break;
                        }
                    }

                    var next = reader.ReadNext();
                    lock (gate)
                    {
                        if (next is null)
                        {
                            endOfStream = true;
                        }
                        else
                        {
                            ring.Clear();
                            ring.Add(next);
                        }
                    }

                    frame = next;
                }

                FrameDecoded?.Invoke();
            }
        }
    }
}
