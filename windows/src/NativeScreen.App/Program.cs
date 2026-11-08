using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Velopack;

namespace NativeScreen.App;

/// <summary>
/// Replaces the XAML-generated entry point so <c>--mcp</c> can run before WinUI starts: MCP clients start the app's own
/// executable as their stdio server, and that process must not open a window or claim the single instance (spec/06 ADR-52).
/// </summary>
public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Contains("--mcp", StringComparer.OrdinalIgnoreCase))
        {
            return McpBridge.Run();
        }

        // The installer starts the app with hook arguments; these exit before any window, COM or single-instance work.
        VelopackApp.Build()
            .OnBeforeUninstallFastCallback(_ => ExplorerContextMenu.Unregister())
            .Run();

        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(callback =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            new App();
        });
        return 0;
    }
}
