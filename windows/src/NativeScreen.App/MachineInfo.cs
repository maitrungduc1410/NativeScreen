using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

namespace NativeScreen.App;

/// <summary>Windows, GPU, driver and memory for crash files (spec/06 ADR-98). Read once at launch, off the UI thread.</summary>
internal static class MachineInfo
{
    public static string Describe()
    {
        var text = new StringBuilder();
        text.AppendLine(Windows());
        try
        {
            using var factory = Vortice.DXGI.DXGI.CreateDXGIFactory1<Vortice.DXGI.IDXGIFactory1>();
            for (var index = 0u; factory.EnumAdapters1(index, out var adapter).Success; index++)
            {
                using (adapter)
                {
                    var description = adapter.Description1;
                    if ((description.Flags & Vortice.DXGI.AdapterFlags.Software) != 0)
                    {
                        continue;
                    }

                    text.AppendLine($"GPU {index}: {description.Description}, {description.DedicatedVideoMemory / (1024 * 1024)} MB, driver {DriverVersion(adapter)}");
                }
            }
        }
        catch (Exception exception) when (exception is SharpGen.Runtime.SharpGenException or COMException or DllNotFoundException)
        {
            text.AppendLine($"GPU: unknown (0x{exception.HResult:X8})");
        }

        var memory = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
        if (GlobalMemoryStatusEx(ref memory))
        {
            text.Append($"RAM: {memory.TotalPhysical / (1024 * 1024 * 1024.0):F1} GB, {memory.AvailablePhysical / (1024 * 1024 * 1024.0):F1} GB free at launch");
        }

        return text.ToString().TrimEnd();
    }

    /// <summary>"Windows 10.0.19045.6456, x64". Cheap, so a crash before <see cref="Describe"/> finished still has it.</summary>
    public static string Windows()
    {
        var version = Environment.OSVersion.Version;
        var revision = Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "UBR", null) is int ubr ? ubr : 0;
        return $"Windows {version.Major}.{version.Minor}.{version.Build}.{revision}, {RuntimeInformation.OSArchitecture.ToString().ToLowerInvariant()}";
    }

    private static string DriverVersion(Vortice.DXGI.IDXGIAdapter1 adapter)
    {
        // The user-mode driver version, as Device Manager shows it (a.b.c.d in four 16-bit parts).
        if (adapter.CheckInterfaceSupport(typeof(Vortice.DXGI.IDXGIDevice), out var umd))
        {
            return $"{(umd >> 48) & 0xFFFF}.{(umd >> 32) & 0xFFFF}.{(umd >> 16) & 0xFFFF}.{umd & 0xFFFF}";
        }

        return "unknown";
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryStatus
    {
        public uint Length;
        public uint MemoryLoad;
        public ulong TotalPhysical;
        public ulong AvailablePhysical;
        public ulong TotalPageFile;
        public ulong AvailablePageFile;
        public ulong TotalVirtual;
        public ulong AvailableVirtual;
        public ulong AvailableExtendedVirtual;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
}
