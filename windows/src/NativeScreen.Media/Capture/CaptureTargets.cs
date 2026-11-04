using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using NativeScreen.Core;

namespace NativeScreen.Media;

public readonly record struct PixelRect(int X, int Y, int Width, int Height)
{
    public bool Contains(int x, int y) => x >= X && y >= Y && x < X + Width && y < Y + Height;
}

public sealed record CaptureDisplay(nint Handle, long Id, string Name, PixelRect Bounds, double Scale, double RefreshRate, bool IsPrimary);

public sealed record CaptureWindow(nint Handle, string Title, string AppName, string? ProcessPath, PixelRect Bounds, bool IsMaximized);

/// <summary>What a recording captures, resolved to physical pixels. Rect is the part of the monitor or the window.</summary>
public sealed record CaptureTarget(CaptureTargetMode Mode, CaptureDisplay Display, CaptureWindow? Window, PixelRect Rect)
{
    public int OutputWidth => RecordingRates.Even(Rect.Width);
    public int OutputHeight => RecordingRates.Even(Rect.Height);

    public CaptureTargetMetadata Metadata(string? appName = null) => new()
    {
        Mode = Mode,
        DisplayId = Display.Id,
        WindowId = Window?.Handle,
        AppName = appName ?? Window?.AppName,
        WindowTitle = Window?.Title,
        LogicalBounds = new LogicalBounds { X = Rect.X / Display.Scale, Y = Rect.Y / Display.Scale, Width = Rect.Width / Display.Scale, Height = Rect.Height / Display.Scale },
        PixelSize = new PixelDimensions { Width = OutputWidth, Height = OutputHeight },
        ScaleFactor = Display.Scale,
        RefreshRate = Display.RefreshRate,
        WindowBorderRadius = Mode == CaptureTargetMode.Window ? WindowCornerRadius(Window) : 0
    };

    private static double WindowCornerRadius(CaptureWindow? window) =>
        window is { IsMaximized: false } && Environment.OSVersion.Version.Build >= 22000 ? 8 : 0;
}

public static class CaptureTargets
{
    private const int MonitorInfoPrimary = 1;
    private const int MdtEffectiveDpi = 0;
    private const int EnumCurrentSettings = -1;
    private const int DwmaExtendedFrameBounds = 9;
    private const int DwmaCloaked = 14;
    private const int GwlExStyle = -20;
    private const long WsExToolWindow = 0x80;
    private const long WsExNoActivate = 0x08000000;
    private const uint GaRoot = 2;
    private const uint ProcessQueryLimitedInformation = 0x1000;
    private const int MinimumWindowWidth = 120;
    private const int MinimumWindowHeight = 90;

    public static IReadOnlyList<CaptureDisplay> Displays()
    {
        var results = new List<CaptureDisplay>();
        EnumDisplayMonitors(0, 0, (monitor, _, _, _) =>
        {
            var info = new MonitorInfoEx { Size = Marshal.SizeOf<MonitorInfoEx>() };
            if (!GetMonitorInfoW(monitor, ref info))
            {
                return true;
            }

            var scale = GetDpiForMonitor(monitor, MdtEffectiveDpi, out var dpi, out _) == 0 ? dpi / 96.0 : 1;
            var mode = new DevMode { Size = (short)Marshal.SizeOf<DevMode>() };
            var refresh = EnumDisplaySettingsW(info.Device, EnumCurrentSettings, ref mode) && mode.DisplayFrequency > 1 ? mode.DisplayFrequency : 60;
            var bounds = new PixelRect(info.Monitor.Left, info.Monitor.Top, info.Monitor.Right - info.Monitor.Left, info.Monitor.Bottom - info.Monitor.Top);
            results.Add(new CaptureDisplay(monitor, StableDisplayId(info.Device), info.Device, bounds, scale, refresh, (info.Flags & MonitorInfoPrimary) != 0));
            return true;
        }, 0);
        results.Sort((a, b) => b.IsPrimary.CompareTo(a.IsPrimary));
        return results;
    }

    /// <summary>Normal on-screen windows, front to back, including this app's editors so editing can be demoed. The recording UI stays out.</summary>
    public static IReadOnlyList<CaptureWindow> WindowsFrontToBack()
    {
        var results = new List<CaptureWindow>();
        EnumWindows((hwnd, _) =>
        {
            var excluded = GetWindowDisplayAffinity(hwnd, out var affinity) && affinity != 0;
            if (!excluded && Describe(hwnd, -1) is { } window)
            {
                results.Add(window);
            }

            return true;
        }, 0);
        return results;
    }

    public static CaptureWindow? WindowInfo(nint hwnd) => Describe(hwnd, -1);

    public static bool IsOwnWindow(nint hwnd)
    {
        _ = GetWindowThreadProcessId(hwnd, out var processId);
        return processId == Environment.ProcessId;
    }

    public static CaptureDisplay DisplayAt(int x, int y)
    {
        var displays = Displays();
        return displays.FirstOrDefault(display => display.Bounds.Contains(x, y)) ?? displays[0];
    }

    public static CaptureDisplay DisplayOf(PixelRect rect) =>
        DisplayAt(rect.X + rect.Width / 2, rect.Y + rect.Height / 2);

    public static void BringToFront(nint hwnd) => SetForegroundWindow(hwnd);

    public static PixelRect VirtualScreen() => new(GetSystemMetrics(76), GetSystemMetrics(77), GetSystemMetrics(78), GetSystemMetrics(79));

    /// <summary>Hidden from every capture on this machine, including this app's own recording.</summary>
    public static void SetExcludedFromCapture(nint hwnd, bool excluded) =>
        SetWindowDisplayAffinity(hwnd, excluded ? (uint)CapturePolicy.ExcludeFromCapture : 0);

    private static CaptureWindow? Describe(nint hwnd, int excludedProcess)
    {
        if (!IsWindowVisible(hwnd) || IsIconic(hwnd) || GetAncestor(hwnd, GaRoot) != hwnd)
        {
            return null;
        }

        var style = GetWindowLongPtrW(hwnd, GwlExStyle);
        if ((style & (WsExToolWindow | WsExNoActivate)) != 0)
        {
            return null;
        }

        if (DwmGetWindowAttribute(hwnd, DwmaCloaked, out int cloaked, sizeof(int)) == 0 && cloaked != 0)
        {
            return null;
        }

        _ = GetWindowThreadProcessId(hwnd, out var processId);
        if (processId == excludedProcess || DwmGetWindowAttribute(hwnd, DwmaExtendedFrameBounds, out Rect frame, Marshal.SizeOf<Rect>()) != 0)
        {
            return null;
        }

        var width = frame.Right - frame.Left;
        var height = frame.Bottom - frame.Top;
        var length = GetWindowTextLengthW(hwnd);
        if (width < MinimumWindowWidth || height < MinimumWindowHeight || length == 0)
        {
            return null;
        }

        var title = new StringBuilder(length + 1);
        _ = GetWindowTextW(hwnd, title, title.Capacity);
        var (appName, path) = ProcessIdentity(processId);
        if (appName.Equals("TextInputHost", StringComparison.OrdinalIgnoreCase) || appName.Equals("ShellExperienceHost", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        return new CaptureWindow(hwnd, title.ToString(), appName, path, new PixelRect(frame.Left, frame.Top, width, height), IsZoomed(hwnd));
    }

    private static (string Name, string? Path) ProcessIdentity(int processId)
    {
        var handle = OpenProcess(ProcessQueryLimitedInformation, false, processId);
        if (handle == 0)
        {
            return ("Application", null);
        }

        try
        {
            var buffer = new StringBuilder(1024);
            var size = buffer.Capacity;
            if (!QueryFullProcessImageNameW(handle, 0, buffer, ref size))
            {
                return ("Application", null);
            }

            var path = buffer.ToString();
            string? description = null;
            try
            {
                description = FileVersionInfo.GetVersionInfo(path).FileDescription;
            }
            catch (FileNotFoundException)
            {
            }

            return (string.IsNullOrWhiteSpace(description) ? Path.GetFileNameWithoutExtension(path) : description, path);
        }
        finally
        {
            CloseHandle(handle);
        }
    }

    private static long StableDisplayId(string device)
    {
        var digits = new string(device.Where(char.IsDigit).ToArray());
        return long.TryParse(digits, out var id) ? id : 1;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MonitorInfoEx
    {
        public int Size;
        public Rect Monitor;
        public Rect Work;
        public int Flags;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string Device;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DevMode
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;
        public short SpecVersion;
        public short DriverVersion;
        public short Size;
        public short DriverExtra;
        public int Fields;
        public int PositionX;
        public int PositionY;
        public int DisplayOrientation;
        public int DisplayFixedOutput;
        public short Color;
        public short Duplex;
        public short YResolution;
        public short TTOption;
        public short Collate;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string FormName;
        public short LogPixels;
        public int BitsPerPel;
        public int PelsWidth;
        public int PelsHeight;
        public int DisplayFlags;
        public int DisplayFrequency;
        public int IcmMethod;
        public int IcmIntent;
        public int MediaType;
        public int DitherType;
        public int Reserved1;
        public int Reserved2;
        public int PanningWidth;
        public int PanningHeight;
    }

    private delegate bool MonitorEnumProc(nint monitor, nint hdc, nint rect, nint data);

    private delegate bool WindowEnumProc(nint hwnd, nint data);

    [DllImport("user32.dll")]
    private static extern bool GetWindowDisplayAffinity(nint hwnd, out uint affinity);

    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(nint hdc, nint clip, MonitorEnumProc callback, nint data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfoW(nint monitor, ref MonitorInfoEx info);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool EnumDisplaySettingsW(string device, int mode, ref DevMode devMode);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(nint monitor, int type, out uint dpiX, out uint dpiY);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(WindowEnumProc callback, nint data);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(nint hwnd);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(nint hwnd);

    [DllImport("user32.dll")]
    private static extern bool IsZoomed(nint hwnd);

    [DllImport("user32.dll")]
    private static extern nint GetAncestor(nint hwnd, uint flags);

    [DllImport("user32.dll")]
    private static extern long GetWindowLongPtrW(nint hwnd, int index);

    [DllImport("user32.dll")]
    private static extern int GetWindowThreadProcessId(nint hwnd, out int processId);

    [DllImport("user32.dll")]
    private static extern int GetWindowTextLengthW(nint hwnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextW(nint hwnd, StringBuilder text, int count);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(nint hwnd);

    [DllImport("user32.dll")]
    private static extern bool SetWindowDisplayAffinity(nint hwnd, uint affinity);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(nint hwnd, int attribute, out int value, int size);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(nint hwnd, int attribute, out Rect value, int size);

    [DllImport("kernel32.dll")]
    private static extern nint OpenProcess(uint access, bool inherit, int processId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern bool QueryFullProcessImageNameW(nint process, int flags, StringBuilder name, ref int size);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(nint handle);
}
