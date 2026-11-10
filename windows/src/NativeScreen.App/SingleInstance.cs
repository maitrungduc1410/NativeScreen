using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.UI.Dispatching;

namespace NativeScreen.App;

/// <summary>
/// One process per copy of the app, so a project opened from Explorer does not bring a second tray icon and recording bar.
/// The name includes the executable's path, so two builds of the app can run side by side (spec/06 ADR-41). A packaged copy
/// uses its package family name instead, because its path changes with every version (spec/06 ADR-81).
/// </summary>
internal static partial class SingleInstance
{
    private const int ForwardTimeoutMs = 3000;
    private const int AllowAnyProcess = -1;

    private static readonly string Name = "NativeScreen-" + Convert.ToHexString(
        SHA256.HashData(Encoding.UTF8.GetBytes((AppPackage.FamilyName ?? Environment.ProcessPath ?? "").ToUpperInvariant())))[..16];

    private static Mutex? owned;

    /// <summary>True when no other process of this copy is running. Held until the process ends.</summary>
    public static bool TryClaim()
    {
        var mutex = new Mutex(true, @"Local\" + Name, out var created);
        if (!created)
        {
            try
            {
                if (!mutex.WaitOne(0))
                {
                    mutex.Dispose();
                    return false;
                }
            }
            catch (AbandonedMutexException)
            {
                // The last owner crashed, so the claim is ours.
            }
        }

        owned = mutex;
        return true;
    }

    /// <summary>Gives up the claim, so a copy started now becomes the running one.</summary>
    public static void Release()
    {
        try
        {
            owned?.ReleaseMutex();
        }
        catch (ApplicationException)
        {
        }

        owned?.Dispose();
        owned = null;
    }

    /// <summary>Hands the request to the running process. An empty path asks it to show the recording bar.</summary>
    public static bool Forward(string? path)
    {
        try
        {
            // The running process is in the background, and only this one may bring a window to the front right now.
            AllowSetForegroundWindow(AllowAnyProcess);
            using var pipe = new NamedPipeClientStream(".", Name, PipeDirection.Out, PipeOptions.CurrentUserOnly);
            pipe.Connect(ForwardTimeoutMs);
            using var writer = new StreamWriter(pipe, Encoding.UTF8);
            writer.WriteLine(path ?? "");
            return true;
        }
        catch (Exception exception) when (exception is IOException or TimeoutException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>Runs <paramref name="open"/> on the UI thread for each request from a later launch.</summary>
    public static void Listen(DispatcherQueue dispatcher, Action<string?> open) => _ = Task.Run(async () =>
    {
        while (true)
        {
            try
            {
                using var pipe = new NamedPipeServerStream(Name, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync();
                using var reader = new StreamReader(pipe, Encoding.UTF8);
                var line = await reader.ReadLineAsync();
                dispatcher.TryEnqueue(() => open(string.IsNullOrEmpty(line) ? null : line));
            }
            catch (IOException)
            {
                // A sender gave up halfway; wait for the next one.
            }
        }
    });

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AllowSetForegroundWindow(int processId);
}
