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
    private StageScene? scene;
    private int pixelWidth;
    private int pixelHeight;
    private float scale = 1;
    private bool resize;
    private volatile bool stopping;

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

    public void Submit(StageScene next, int width, int height, float rasterScale)
    {
        lock (gate)
        {
            scene = next;
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
        wake.Dispose();
        latency.Dispose();
    }

    private void Run()
    {
        while (true)
        {
            wake.WaitOne();
            if (stopping)
            {
                return;
            }

            StageScene? current;
            int width;
            int height;
            float rasterScale;
            bool needsResize;
            lock (gate)
            {
                current = scene;
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
            compositor.DrawStage(swapChain, current, width, height);
            swapChain.Present();
        }
    }
}
