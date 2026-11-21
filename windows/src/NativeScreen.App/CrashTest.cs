namespace NativeScreen.App;

/// <summary>
/// Debug builds only: NS_CRASH_TEST=ui|background|task|preview makes one failure on purpose, to check the crash files
/// (spec/06 ADR-98). Release builds ignore the variable.
/// </summary>
internal static class CrashTest
{
#if DEBUG
    public static string? Mode { get; } = Environment.GetEnvironmentVariable("NS_CRASH_TEST");
#else
    public static string? Mode => null;
#endif

    public static void Schedule()
    {
        switch (Mode)
        {
            case "ui":
                Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread().TryEnqueue(ThrowOnUiThread);
                break;
            case "uisync":
                // Thrown inside a callback the dispatcher runs: a fail-fast with no .NET handler. Windows Error Reporting calls
                // the recovery callback only after a minute of running, hence the wait.
                After(TimeSpan.FromSeconds(65), () => throw new NullReferenceException("NS_CRASH_TEST uisync"));
                break;
            case "quit":
                // Quit from the tray icon after a few seconds; a clean exit leaves no crash file.
                After(TimeSpan.FromSeconds(4), App.Quit);
                break;
            case "xaml":
                // Thrown inside a XAML event handler: XAML raises UnhandledException, then ends the app.
                After(TimeSpan.FromSeconds(3), () =>
                {
                    var grid = new Microsoft.UI.Xaml.Controls.Grid();
                    grid.Loaded += (_, _) => throw new NullReferenceException("NS_CRASH_TEST xaml");
                    new Microsoft.UI.Xaml.Window { Content = grid }.Activate();
                });
                break;
            case "background":
                new Thread(() =>
                {
                    Thread.Sleep(3000);
                    throw new InvalidOperationException("NS_CRASH_TEST background");
                }) { IsBackground = true }.Start();
                break;
            case "task":
                _ = Task.Run(async () =>
                {
                    await Task.Delay(2000);
                    _ = Task.Run(() => throw new InvalidOperationException("NS_CRASH_TEST task"));
                    await Task.Delay(500);
                    GC.Collect();
                    GC.WaitForPendingFinalizers();
                    GC.Collect();
                });
                break;
        }
    }

    /// <summary>Throws inside the editor preview's setup when NS_CRASH_TEST=preview.</summary>
    public static void PreviewStep()
    {
        if (Mode == "preview")
        {
            throw new InvalidOperationException("NS_CRASH_TEST preview");
        }
    }

    private static void After(TimeSpan delay, Action action)
    {
        var timer = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread().CreateTimer();
        timer.Interval = delay;
        timer.IsRepeating = false;
        timer.Tick += (_, _) => action();
        timer.Start();
    }

    private static async void ThrowOnUiThread()
    {
        await Task.Delay(3000);
        CrashLog.Note("NS_CRASH_TEST ui");
        throw new NullReferenceException("NS_CRASH_TEST ui");
    }
}
