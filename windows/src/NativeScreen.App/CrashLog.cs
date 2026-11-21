using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace NativeScreen.App;

/// <summary>
/// One text file per crash or caught error in the user data folder's Logs, with the machine, the full exception and the last
/// steps the app took (spec/06 ADR-98). A user's crash used to leave only an event log entry with no stack.
/// </summary>
internal static class CrashLog
{
    public const string CrashPrefix = "crash-";
    public const string ErrorPrefix = "error-";
    private const int KeepPerKind = 10;
    private const int BreadcrumbCount = 100;

    private static readonly Stopwatch Clock = Stopwatch.StartNew();
    private static readonly string[] Breadcrumbs = new string[BreadcrumbCount];
    private static readonly object Gate = new();
    private static int nextBreadcrumb;
    private static int writing;
    private static string machine = "";

    public static string Folder => NativeScreen.Core.UserDataFolder.PathOf("Logs");

    /// <summary>Hooks the process-wide handlers and reads the machine once, off the UI thread. Called first thing in Main.</summary>
    public static void Start()
    {
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.IsTerminating)
            {
                crashWritten = true;
            }

            Write(args.ExceptionObject as Exception, "background thread", args.IsTerminating);
        };
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            Write(args.Exception, "unobserved task", ending: false);
            args.SetObserved();
        };
        // An exception thrown in a dispatcher callback ends the process with a fail-fast that runs no .NET handler. Windows
        // Error Reporting still calls a recovery callback, and the last exception thrown is almost always the cause.
        AppDomain.CurrentDomain.FirstChanceException += (_, args) => lastThrown = args.Exception;
        _ = RegisterApplicationRecoveryCallback(Recovery, 0, RecoveryPingMs, 0);
        _ = Task.Run(() => machine = MachineInfo.Describe());
    }

    private const uint RecoveryPingMs = 5000;
    private static readonly RecoveryCallback Recovery = Recover;
    private static volatile Exception? lastThrown;
    private static volatile bool crashWritten;

    private static uint Recover(nint parameter)
    {
        _ = ApplicationRecoveryInProgress(out _);
        if (!crashWritten)
        {
            Note("the app was ended by a fail-fast; the exception below is the last one thrown");
            Write(lastThrown, "fail-fast", ending: true);
        }

        ApplicationRecoveryFinished(true);
        return 0;
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate uint RecoveryCallback(nint parameter);

    [DllImport("kernel32.dll")]
    private static extern int RegisterApplicationRecoveryCallback(RecoveryCallback callback, nint parameter, uint pingInterval, uint flags);

    [DllImport("kernel32.dll")]
    private static extern int ApplicationRecoveryInProgress([MarshalAs(UnmanagedType.Bool)] out bool canceled);

    [DllImport("kernel32.dll")]
    private static extern void ApplicationRecoveryFinished([MarshalAs(UnmanagedType.Bool)] bool success);

    /// <summary>
    /// For XAML's UnhandledException. Most of those end the process (a stowed exception), but one thrown after an await on
    /// the dispatcher is reported and the app keeps running. Written as a crash first, because the process may be gone in a
    /// moment; if it is still alive 3 s later, the file becomes an error file, so the next launch does not report a crash.
    /// </summary>
    public static void WriteUiException(Exception? exception)
    {
        crashWritten = true;
        if (Write(exception, "UI thread", ending: true) is not { } path)
        {
            return;
        }

        new Thread(() =>
        {
            Thread.Sleep(3000);
            // Still alive: a later fail-fast is a new crash, and recovery may write it.
            crashWritten = false;
            try
            {
                var text = File.ReadAllText(path).Replace("Native Screen crash: UI thread, the app closed", "Native Screen error: UI thread, the app kept running");
                File.WriteAllText(Path.Combine(Path.GetDirectoryName(path) ?? "", ErrorPrefix + Path.GetFileName(path)[CrashPrefix.Length..]), text, new UTF8Encoding(false));
                File.Delete(path);
            }
            catch (Exception)
            {
                // The crash file stays; better a crash reported once too often than none.
            }
        }) { IsBackground = true, Name = "NativeScreen crash log" }.Start();
    }

    /// <summary>A step worth knowing after a crash. Kept in memory only; written with the next crash or error.</summary>
    public static void Note(string step)
    {
        var line = $"{Clock.Elapsed.TotalMilliseconds,10:F0} ms  {step}";
        lock (Gate)
        {
            Breadcrumbs[nextBreadcrumb % BreadcrumbCount] = line;
            nextBreadcrumb++;
        }
    }

    /// <summary>Writes a crash (<paramref name="ending"/>) or an error file. Never throws.</summary>
    public static string? Write(Exception? exception, string kind, bool ending)
    {
        // A failure while logging must not log again, or recurse into the same handler.
        if (Interlocked.Exchange(ref writing, 1) != 0)
        {
            return null;
        }

        try
        {
            var now = DateTime.Now;
            var folder = Folder;
            Directory.CreateDirectory(folder);
            var prefix = ending ? CrashPrefix : ErrorPrefix;
            var path = Path.Combine(folder, $"{prefix}{now:yyyy-MM-dd_HH-mm-ss}.txt");
            for (var suffix = 2; File.Exists(path); suffix++)
            {
                path = Path.Combine(folder, $"{prefix}{now:yyyy-MM-dd_HH-mm-ss}-{suffix}.txt");
            }

            File.WriteAllText(path, Report(exception, kind, ending, now), new UTF8Encoding(false));
            Prune(folder, prefix);
            return path;
        }
        catch (Exception)
        {
            return null;
        }
        finally
        {
            Volatile.Write(ref writing, 0);
        }
    }

    /// <summary>The newest crash file, or null.</summary>
    public static FileInfo? NewestCrash()
    {
        try
        {
            var folder = new DirectoryInfo(Folder);
            return folder.Exists ? folder.GetFiles(CrashPrefix + "*.txt").OrderByDescending(file => file.Name, StringComparer.Ordinal).FirstOrDefault() : null;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>The local time a crash file names, read from its name.</summary>
    public static DateTime TimeOf(FileInfo file) =>
        DateTime.TryParseExact(file.Name.AsSpan(CrashPrefix.Length, 19), "yyyy-MM-dd_HH-mm-ss", null, System.Globalization.DateTimeStyles.None, out var time)
            ? time
            : file.LastWriteTime;

    private static string Report(Exception? exception, string kind, bool ending, DateTime now)
    {
        var text = new StringBuilder();
        text.AppendLine($"Native Screen {(ending ? "crash" : "error")}: {kind}{(ending ? ", the app closed" : ", the app kept running")}");
        text.AppendLine($"Time: {now:yyyy-MM-dd HH:mm:ss} local, {now.ToUniversalTime():yyyy-MM-dd HH:mm:ss} UTC");
        text.AppendLine($"App: {McpServer.AppVersion} ({(AppPackage.IsPackaged ? "Microsoft Store" : "GitHub")} build), uptime {Clock.Elapsed:hh\\:mm\\:ss}");
        text.AppendLine(machine.Length > 0 ? machine : MachineInfo.Windows());
        text.AppendLine();
        text.AppendLine(exception is null ? "No exception object." : Describe(exception));
        text.AppendLine();
        text.AppendLine("Last steps (oldest first):");
        lock (Gate)
        {
            var first = Math.Max(0, nextBreadcrumb - BreadcrumbCount);
            for (var index = first; index < nextBreadcrumb; index++)
            {
                text.AppendLine(Breadcrumbs[index % BreadcrumbCount]);
            }
        }

        return text.ToString();
    }

    private static string Describe(Exception exception)
    {
        var text = new StringBuilder();
        text.AppendLine($"HRESULT 0x{exception.HResult:X8}");
        text.AppendLine(exception.ToString());
        if (exception is AggregateException aggregate)
        {
            foreach (var inner in aggregate.Flatten().InnerExceptions)
            {
                text.AppendLine();
                text.AppendLine($"Inner, HRESULT 0x{inner.HResult:X8}:");
                text.AppendLine(inner.ToString());
            }
        }

        return text.ToString();
    }

    private static void Prune(string folder, string prefix)
    {
        foreach (var old in new DirectoryInfo(folder).GetFiles(prefix + "*.txt").OrderByDescending(file => file.Name, StringComparer.Ordinal).Skip(KeepPerKind))
        {
            old.Delete();
        }
    }

    /// <summary>
    /// The path Explorer can open. A packaged app's new files under %LOCALAPPDATA% really live in the package's LocalCache,
    /// and only the app sees them at the original path; Explorer runs outside the package. A folder that existed before the
    /// app was installed (a GitHub build made it) is not redirected, so the copy in LocalCache is used only when it exists.
    /// </summary>
    public static string ForExplorer(string path)
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (!AppPackage.IsPackaged || !path.StartsWith(local + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
        {
            return path;
        }

        try
        {
            var mapped = Path.Combine(Windows.Storage.ApplicationData.Current.LocalCacheFolder.Path, "Local", path[(local.Length + 1)..]);
            return File.Exists(mapped) || Directory.Exists(mapped) ? mapped : path;
        }
        catch (Exception exception) when (exception is InvalidOperationException or COMException)
        {
            return path;
        }
    }
}
