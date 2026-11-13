using Microsoft.Win32.SafeHandles;

namespace NativeScreen.Rendering;

/// <summary>The one render thread of an editor window. It blocks while nothing changes, so idle costs no CPU.</summary>
public sealed class PreviewRenderer : IDisposable
{
    private readonly FrameCompositor compositor;
    private readonly CompositionSwapChain swapChain;
    private readonly AutoResetEvent wake = new(false);
    private readonly ManualResetEvent latency;
    private readonly Thread thread;
    private readonly object gate = new();
    private ComposeRequest? request;
    private Func<double>? liveClock;
    private int pixelWidth;
    private int pixelHeight;
    private float scale = 1;
    private bool resize;
    private volatile bool stopping;

    private readonly FrameStats? stats = Environment.GetEnvironmentVariable("NS_PREVIEW_STATS") is { Length: > 0 } statsPath ? new FrameStats(statsPath) : null;

    public PreviewRenderer(FrameCompositor compositor, CompositionSwapChain swapChain, int pixelWidth, int pixelHeight)
    {
        this.compositor = compositor;
        this.swapChain = swapChain;
        this.pixelWidth = pixelWidth;
        this.pixelHeight = pixelHeight;
        latency = new ManualResetEvent(false) { SafeWaitHandle = new SafeWaitHandle(swapChain.LatencyWaitable, false) };
        thread = new Thread(Run) { IsBackground = true, Name = "NativeScreen preview" };
        thread.Start();
    }

    /// <summary>The GPU was lost or something could not be read, on the render thread. Nothing more is drawn.</summary>
    public event Action? Failed;

    /// <summary>The newest request wins; the document inside must be a snapshot the UI thread no longer mutates.</summary>
    /// <summary>With a clock, the render thread keeps drawing at the display rate, reading the time itself for each frame.</summary>
    public void Submit(ComposeRequest next, int width, int height, float rasterScale, Func<double>? clock = null)
    {
        lock (gate)
        {
            request = next;
            liveClock = clock;
            if (width != pixelWidth || height != pixelHeight || rasterScale != scale)
            {
                pixelWidth = width;
                pixelHeight = height;
                scale = rasterScale;
                resize = true;
            }
        }

        wake.Set();
    }

    public void Dispose()
    {
        stopping = true;
        wake.Set();
        thread.Join();
        stats?.Write();
        wake.Dispose();
        latency.Dispose();
    }

    /// <summary>NS_PREVIEW_STATS=path writes present intervals on close, to measure spec/08 phase 3 on a real window.</summary>
    private void NoteFrame(long startTicks)
    {
        stats?.Note(startTicks);
    }

    private sealed class FrameStats(string path)
    {
        private readonly List<double> intervals = [];
        private readonly List<double> work = [];
        private long last;

        public void Note(long startTicks)
        {
            var now = System.Diagnostics.Stopwatch.GetTimestamp();
            work.Add((now - startTicks) * 1000.0 / System.Diagnostics.Stopwatch.Frequency);
            if (last != 0)
            {
                intervals.Add((now - last) * 1000.0 / System.Diagnostics.Stopwatch.Frequency);
            }

            last = now;
        }

        public void Write()
        {
            // Only intervals inside a burst of drawing count; a pause between redraws is not a late frame.
            var active = intervals.Where(item => item < 250).OrderBy(item => item).ToList();
            if (active.Count == 0)
            {
                return;
            }

            var median = active[active.Count / 2];
            var late = active.Count(item => item > median * 1.5);
            work.Sort();
            File.WriteAllText(path, FormattableString.Invariant($"frames {active.Count}, median interval {median:F2} ms, over 1.5x median {late} ({100.0 * late / active.Count:F2}%), worst {active[^1]:F1} ms, compose+present median {work[work.Count / 2]:F2} ms p95 {work[work.Count * 95 / 100]:F2} ms"));
        }
    }

    // An exception left on this thread would end the process, with every open editor and any recording in it.
    private void Run()
    {
        try
        {
            RenderLoop();
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            Failed?.Invoke();
        }
    }

    private void RenderLoop()
    {
        while (true)
        {
            wake.WaitOne();
            if (stopping)
            {
                return;
            }

            ComposeRequest? current;
            int width;
            int height;
            float rasterScale;
            bool needsResize;
            Func<double>? clock;
            lock (gate)
            {
                current = request;
                clock = liveClock;
                width = pixelWidth;
                height = pixelHeight;
                rasterScale = scale;
                needsResize = resize;
                resize = false;
            }

            if (current is null)
            {
                continue;
            }

            if (needsResize)
            {
                compositor.ResizeSwapChain(swapChain, width, height, rasterScale);
            }

            latency.WaitOne(100);
            if (clock is not null)
            {
                current = current.AtTimeline(clock());
            }

            var composeStart = System.Diagnostics.Stopwatch.GetTimestamp();
            compositor.Present(swapChain, current, width, height);
            swapChain.Present();
            NoteFrame(composeStart);            if (compositor.IsAnimating || clock is not null)
            {
                wake.Set();
            }
        }
    }
}
