using System.Runtime.InteropServices;

namespace NativeScreen.App;

/// <summary>The notification area icon, Windows' place for the macOS menu bar extra. The app keeps running with no window open.</summary>
internal sealed class TrayIcon : IDisposable
{
    private const uint WmUser = 0x0400;
    private const uint CallbackMessage = WmUser + 1;
    private const uint WmLButtonUp = 0x0202;
    private const uint WmRButtonUp = 0x0205;
    private const uint NimAdd = 0;
    private const uint NimDelete = 2;
    private const uint NifMessage = 1;
    private const uint NifIcon = 2;
    private const uint NifTip = 4;
    private const uint ImageIcon = 1;
    private const uint LrLoadFromFile = 0x10;
    private const uint TpmReturnCommand = 0x0100;
    private const uint MfSeparator = 0x800;

    private static readonly WndProc ClassProc = StaticProc;
    private static readonly Dictionary<nint, TrayIcon> Instances = [];

    private readonly nint hwnd;
    private readonly Action primary;
    private readonly Func<IReadOnlyList<(string? Title, Action? Click)>> buildMenu;
    private NotifyIconData data;

    public TrayIcon(string iconPath, string tooltip, Action primary, Func<IReadOnlyList<(string? Title, Action? Click)>> buildMenu)
    {
        this.primary = primary;
        this.buildMenu = buildMenu;
        var name = Marshal.StringToHGlobalUni("NativeScreenTray");
        var cls = new WndClass { Size = (uint)Marshal.SizeOf<WndClass>(), Proc = Marshal.GetFunctionPointerForDelegate(ClassProc), Instance = GetModuleHandleW(null), ClassName = name };
        var atom = RegisterClassExW(ref cls);
        hwnd = CreateWindowExW(0, atom, null, 0, 0, 0, 0, 0, 0, 0, GetModuleHandleW(null), 0);
        Instances[hwnd] = this;
        data = new NotifyIconData
        {
            Size = (uint)Marshal.SizeOf<NotifyIconData>(),
            Window = hwnd,
            Id = 1,
            Flags = NifMessage | NifIcon | NifTip,
            CallbackMessage = CallbackMessage,
            Icon = LoadImageW(0, iconPath, ImageIcon, 32, 32, LrLoadFromFile),
            Tip = tooltip
        };
        Shell_NotifyIconW(NimAdd, ref data);
    }

    public void Dispose()
    {
        Shell_NotifyIconW(NimDelete, ref data);
        Instances.Remove(hwnd);
        DestroyWindow(hwnd);
    }

    private static nint StaticProc(nint window, uint message, nint wParam, nint lParam)
    {
        if (message == CallbackMessage && Instances.TryGetValue(window, out var tray))
        {
            var mouse = (uint)(lParam & 0xFFFF);
            if (mouse == WmLButtonUp)
            {
                tray.primary();
            }
            else if (mouse == WmRButtonUp)
            {
                tray.ShowMenu();
            }

            return 0;
        }

        return DefWindowProcW(window, message, wParam, lParam);
    }

    private void ShowMenu()
    {
        var items = buildMenu();
        var menu = CreatePopupMenu();
        for (var index = 0; index < items.Count; index++)
        {
            if (items[index].Title is { } title)
            {
                // A title without an action is information, shown greyed out.
                AppendMenuW(menu, items[index].Click is null ? MfGrayed : 0, (nuint)(index + 1), title);
            }
            else
            {
                AppendMenuW(menu, MfSeparator, 0, null);
            }
        }

        GetCursorPos(out var cursor);
        // Without this, the menu stays open after clicking elsewhere.
        SetForegroundWindow(hwnd);
        var chosen = TrackPopupMenu(menu, TpmReturnCommand, cursor.X, cursor.Y, 0, hwnd, 0);
        DestroyMenu(menu);
        if (chosen > 0)
        {
            items[chosen - 1].Click?.Invoke();
        }
    }

    private delegate nint WndProc(nint window, uint message, nint wParam, nint lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct WndClass
    {
        public uint Size;
        public uint Style;
        public nint Proc;
        public int ClassExtra;
        public int WindowExtra;
        public nint Instance;
        public nint Icon;
        public nint Cursor;
        public nint Background;
        public nint MenuName;
        public nint ClassName;
        public nint IconSmall;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point32
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint Size;
        public nint Window;
        public uint Id;
        public uint Flags;
        public uint CallbackMessage;
        public nint Icon;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string Tip;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern nint GetModuleHandleW(string? name);

    [DllImport("user32.dll")]
    private static extern nint RegisterClassExW(ref WndClass cls);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern nint CreateWindowExW(uint exStyle, nint className, string? title, uint style, int x, int y, int width, int height, nint parent, nint menu, nint instance, nint param);

    [DllImport("user32.dll")]
    private static extern nint DefWindowProcW(nint window, uint message, nint wParam, nint lParam);

    [DllImport("user32.dll")]
    private static extern bool DestroyWindow(nint window);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern nint LoadImageW(nint instance, string name, uint type, int width, int height, uint flags);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern bool Shell_NotifyIconW(uint message, ref NotifyIconData data);

    [DllImport("user32.dll")]
    private static extern nint CreatePopupMenu();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool AppendMenuW(nint menu, uint flags, nuint id, string? text);

    private const uint MfGrayed = 0x1;

    [DllImport("user32.dll")]
    private static extern int TrackPopupMenu(nint menu, uint flags, int x, int y, int reserved, nint window, nint rect);

    [DllImport("user32.dll")]
    private static extern bool DestroyMenu(nint menu);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out Point32 point);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(nint window);
}
