using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using NativeScreen.Core;

namespace NativeScreen.Media;

public sealed record AudioAppInfo(string Id, string Name, string? ExecutablePath);

/// <summary>The apps whose sound can be recorded on its own. An app is known by its process name, across its windows and restarts.</summary>
public static class AudioApps
{
    private const int FirstSupportedBuild = 19041;
    private const int MaximumStreams = 16;
    private const uint SnapshotProcess = 0x2;
    private static readonly HashSet<string> NotApps = new(StringComparer.OrdinalIgnoreCase) { "ApplicationFrameHost", "TextInputHost", "SystemSettings" };

    /// <summary>Process loopback does not exist on older Windows. Its documentation says build 20348; it was measured working on 19044.</summary>
    public static bool IsPerAppSupported => Environment.OSVersion.Version.Build >= FirstSupportedBuild;

    /// <summary>Apps with a window, by name. Reads every process, so call it off the UI thread.</summary>
    public static IReadOnlyList<AudioAppInfo> List()
    {
        var seen = new Dictionary<string, AudioAppInfo>(StringComparer.OrdinalIgnoreCase);
        foreach (var process in Process.GetProcesses())
        {
            using (process)
            {
                try
                {
                    if (process.Id != Environment.ProcessId && process.MainWindowHandle != 0 && process.MainWindowTitle.Length > 0
                        && !NotApps.Contains(process.ProcessName) && !seen.ContainsKey(process.ProcessName))
                    {
                        seen[process.ProcessName] = Describe(process);
                    }
                }
                catch (Exception exception) when (exception is InvalidOperationException or Win32Exception)
                {
                    // It exited while being read, or belongs to a higher privilege.
                }
            }
        }

        return seen.Values.OrderBy(app => app.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    /// <summary>The processes to capture for the chosen apps right now.</summary>
    public static List<int> RootProcessIds(IReadOnlyCollection<string> chosen) => AudioAppRoots.Select(Snapshot(), chosen, MaximumStreams);

    private static AudioAppInfo Describe(Process process)
    {
        try
        {
            var module = process.MainModule;
            var description = module?.FileVersionInfo.FileDescription;
            return new AudioAppInfo(process.ProcessName, string.IsNullOrWhiteSpace(description) ? process.ProcessName : description, module?.FileName);
        }
        catch (Exception exception) when (exception is Win32Exception or InvalidOperationException)
        {
            return new AudioAppInfo(process.ProcessName, process.ProcessName, null);
        }
    }

    private static List<(int Id, int ParentId, string Name)> Snapshot()
    {
        var results = new List<(int, int, string)>();
        var snapshot = CreateToolhelp32Snapshot(SnapshotProcess, 0);
        if (snapshot == -1)
        {
            return results;
        }

        try
        {
            var entry = new ProcessEntry { Size = (uint)Marshal.SizeOf<ProcessEntry>() };
            var more = Process32FirstW(snapshot, ref entry);
            while (more)
            {
                results.Add(((int)entry.ProcessId, (int)entry.ParentProcessId, Path.GetFileNameWithoutExtension(entry.ExeFile)));
                more = Process32NextW(snapshot, ref entry);
            }
        }
        finally
        {
            CloseHandle(snapshot);
        }

        return results;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry
    {
        public uint Size;
        public uint Usage;
        public uint ProcessId;
        public nuint DefaultHeapId;
        public uint ModuleId;
        public uint Threads;
        public uint ParentProcessId;
        public int BasePriority;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string ExeFile;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern nint CreateToolhelp32Snapshot(uint flags, uint processId);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern bool Process32FirstW(nint snapshot, ref ProcessEntry entry);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern bool Process32NextW(nint snapshot, ref ProcessEntry entry);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(nint handle);
}
