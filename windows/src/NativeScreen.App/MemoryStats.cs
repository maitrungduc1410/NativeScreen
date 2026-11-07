using System.Diagnostics;
using System.Runtime.CompilerServices;

namespace NativeScreen.App;

/// <summary>
/// NS_MEMORY_STATS=&lt;file&gt;: after each editor closes, collects garbage and appends memory and how many editor objects are
/// still alive. Anything above zero after a close is a leak (spec/06 ADR-48). Costs nothing when the variable is not set.
/// </summary>
internal static class MemoryStats
{
    private static readonly string? File = Environment.GetEnvironmentVariable("NS_MEMORY_STATS");
    private static readonly List<(string Kind, WeakReference Target)> Tracked = [];

    // A DispatcherQueueTimer nothing references is collected, and then never fires.
    private static readonly List<Microsoft.UI.Dispatching.DispatcherQueueTimer> Pending = [];


    public static void Track(params object[] items)
    {
        if (File is null)
        {
            return;
        }

        foreach (var item in items)
        {
            Tracked.Add((item.GetType().Name, new WeakReference(item)));
        }
    }

    /// <summary>Writes one line a moment after a close, once the window's own teardown has run.</summary>
    public static void AfterClose(string note)
    {
        if (File is null)
        {
            return;
        }

        var queue = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        foreach (var seconds in new[] { 2, 6, 15 })
        {
            var timer = queue.CreateTimer();
            timer.Interval = TimeSpan.FromSeconds(seconds);
            timer.IsRepeating = false;
            timer.Tick += (sender, _) =>
            {
                sender.Stop();
                Pending.Remove(sender);
                Write($"{note} +{seconds}s");
            };
            Pending.Add(timer);
            timer.Start();
        }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    public static void Write(string note)
    {
        if (File is null)
        {
            return;
        }

        for (var pass = 0; pass < 3; pass++)
        {
            GC.Collect();
            GC.WaitForPendingFinalizers();
        }

        Tracked.RemoveAll(item => !item.Target.IsAlive);
        var alive = string.Join(" ", Tracked.GroupBy(item => item.Kind).Select(group => $"{group.Key}={group.Count()}"));
        using var process = Process.GetCurrentProcess();
        System.IO.File.AppendAllText(File,
            $"{DateTime.Now:HH:mm:ss}\t{note}\tprivate={process.PrivateMemorySize64 / 1048576.0:0.0}MB\tmanaged={GC.GetTotalMemory(false) / 1048576.0:0.0}MB\talive: {(alive.Length == 0 ? "none" : alive)}\n");
    }
}
