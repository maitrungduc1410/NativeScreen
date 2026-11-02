using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Channels;
using NativeScreen.Core;

namespace NativeScreen.Media;

/// <summary>
/// Cursor, clicks and keys as append-only .jsonl. Hooks live on their own thread with a message loop and only enqueue, so
/// Windows never removes them for being slow; file writes happen on a separate thread. t = 0 is the first video frame.
/// </summary>
public sealed class TelemetryRecorder : IDisposable
{
    private const int WhKeyboardLl = 13;
    private const int WhMouseLl = 14;
    private const int WmKeyDown = 0x0100;
    private const int WmKeyUp = 0x0101;
    private const int WmSysKeyDown = 0x0104;
    private const int WmSysKeyUp = 0x0105;
    private const int WmMouseMove = 0x0200;
    private const int WmLButtonDown = 0x0201;
    private const int WmLButtonUp = 0x0202;
    private const int WmRButtonDown = 0x0204;
    private const int WmRButtonUp = 0x0205;
    private const int WmMButtonDown = 0x0207;
    private const int WmMButtonUp = 0x0208;
    private const int WmMouseWheel = 0x020A;
    private const int WmMouseHWheel = 0x020E;
    private const int WmQuit = 0x0012;
    private const int CursorShowing = 1;
    private const uint CreateWaitableTimerHighResolution = 2;
    private const uint TimerAllAccess = 0x1F0003;
    private const double SampleIntervalMs = 8;
    private const double FlushIntervalMs = 500;
    private const double WheelNotchPoints = 10;

    private static readonly (nint Handle, string Kind)[] SystemCursors =
    [
        (LoadCursorW(0, 32649), "pointer"),
        (LoadCursorW(0, 32513), "ibeam"),
        (LoadCursorW(0, 32515), "crosshair"),
        (LoadCursorW(0, 32646), "openhand")
    ];

    private readonly StreamWriter cursorFile;
    private readonly StreamWriter clicksFile;
    private readonly StreamWriter keysFile;
    private readonly PixelRect bounds;
    private readonly Channel<HookEvent> events = Channel.CreateUnbounded<HookEvent>(new UnboundedChannelOptions { SingleReader = true });
    private readonly PauseTimeline pause = new();
    private readonly object pauseGate = new();
    private readonly HashSet<int> downKeys = [];
    private readonly LowLevelProc mouseProc;
    private readonly LowLevelProc keyboardProc;
    private readonly Thread hookThread;
    private readonly Thread writerThread;
    private readonly double doubleClickMs = GetDoubleClickTime();
    private readonly int doubleClickWidth = GetSystemMetrics(36);
    private readonly int doubleClickHeight = GetSystemMetrics(37);
    private uint hookThreadId;
    private double originMs = double.NaN;
    private volatile bool stopping;
    private double lastDownMs = double.NegativeInfinity;
    private int lastDownButton;
    private int lastDownX;
    private int lastDownY;
    private int clickCount;
    private bool shiftDown;
    private bool controlDown;
    private bool altDown;
    private bool metaDown;

    public TelemetryRecorder(string telemetryDirectory, PixelRect bounds)
    {
        Directory.CreateDirectory(telemetryDirectory);
        this.bounds = bounds;
        cursorFile = Open(Path.Combine(telemetryDirectory, "cursor.jsonl"));
        clicksFile = Open(Path.Combine(telemetryDirectory, "clicks.jsonl"));
        keysFile = Open(Path.Combine(telemetryDirectory, "keys.jsonl"));
        mouseProc = MouseHook;
        keyboardProc = KeyboardHook;
        hookThread = new Thread(RunHooks) { IsBackground = true, Name = "NativeScreen input hooks", Priority = ThreadPriority.AboveNormal };
        writerThread = new Thread(RunWriter) { IsBackground = true, Name = "NativeScreen telemetry" };
        hookThread.Start();
        writerThread.Start();
    }

    /// <summary>Called once with the QPC time of the first video frame.</summary>
    public void MarkFirstVideoFrame(double hostMs) => Volatile.Write(ref originMs, hostMs);

    public void SetPaused(bool paused, double hostMs)
    {
        lock (pauseGate)
        {
            pause.SetPaused(paused, hostMs);
        }
    }

    public void Dispose()
    {
        stopping = true;
        if (hookThreadId != 0)
        {
            PostThreadMessageW(hookThreadId, WmQuit, 0, 0);
        }

        hookThread.Join();
        events.Writer.Complete();
        writerThread.Join();
        cursorFile.Dispose();
        clicksFile.Dispose();
        keysFile.Dispose();
    }

    private static StreamWriter Open(string path) => new(path, append: true, new System.Text.UTF8Encoding(false));

    private static double NowMs() => Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency;

    private void RunHooks()
    {
        hookThreadId = GetCurrentThreadId();
        // A message queue must exist before Dispose posts WM_QUIT.
        PeekMessageW(out _, 0, 0, 0, 0);
        var module = GetModuleHandleW(null);
        var mouse = SetWindowsHookExW(WhMouseLl, mouseProc, module, 0);
        var keyboard = SetWindowsHookExW(WhKeyboardLl, keyboardProc, module, 0);
        while (!stopping && GetMessageW(out var message, 0, 0, 0) > 0)
        {
            DispatchMessageW(ref message);
        }

        UnhookWindowsHookEx(mouse);
        UnhookWindowsHookEx(keyboard);
    }

    private nint MouseHook(int code, nint message, nint data)
    {
        if (code >= 0)
        {
            var info = Marshal.PtrToStructure<MouseHookStruct>(data);
            var kind = (int)message;
            if (kind != WmMouseMove)
            {
                events.Writer.TryWrite(new HookEvent(NowMs(), kind, info.X, info.Y, (short)(info.MouseData >> 16), false));
            }
        }

        return CallNextHookEx(0, code, message, data);
    }

    private nint KeyboardHook(int code, nint message, nint data)
    {
        if (code >= 0)
        {
            var info = Marshal.PtrToStructure<KeyboardHookStruct>(data);
            events.Writer.TryWrite(new HookEvent(NowMs(), (int)message, info.VirtualKey, 0, 0, true));
        }

        return CallNextHookEx(0, code, message, data);
    }

    private void RunWriter()
    {
        var timer = CreateWaitableTimerExW(0, null, CreateWaitableTimerHighResolution, TimerAllAccess);
        var lastFlush = NowMs();
        var wroteFirst = false;
        var reader = events.Reader;
        while (!stopping || reader.TryPeek(out _))
        {
            Wait(timer);
            while (reader.TryRead(out var item))
            {
                Handle(item);
            }

            var now = NowMs();
            var origin = Volatile.Read(ref originMs);
            if (!double.IsNaN(origin))
            {
                if (!wroteFirst)
                {
                    wroteFirst = true;
                    WriteCursor(0);
                }
                else if (Elapsed(now) is { } t)
                {
                    WriteCursor(t);
                }
            }

            if (now - lastFlush >= FlushIntervalMs)
            {
                lastFlush = now;
                cursorFile.Flush();
                clicksFile.Flush();
                keysFile.Flush();
            }
        }

        if (timer != 0)
        {
            CloseHandle(timer);
        }
    }

    private static void Wait(nint timer)
    {
        if (timer == 0)
        {
            Thread.Sleep(1);
            return;
        }

        var due = (long)(-SampleIntervalMs * 10_000);
        SetWaitableTimer(timer, ref due, 0, 0, 0, false);
        WaitForSingleObject(timer, 100);
    }

    private double? Elapsed(double hostMs)
    {
        var origin = Volatile.Read(ref originMs);
        if (double.IsNaN(origin))
        {
            return null;
        }

        lock (pauseGate)
        {
            return pause.OffsetMs(hostMs) is { } offset ? Math.Max(0, hostMs - origin - offset) : null;
        }
    }

    private void WriteCursor(double t)
    {
        var info = new CursorInfo { Size = Marshal.SizeOf<CursorInfo>() };
        if (!GetCursorInfo(ref info))
        {
            return;
        }

        var point = CaptureCoordinates.Normalize(info.X, info.Y, bounds.X, bounds.Y, bounds.Width, bounds.Height);
        var kind = "arrow";
        if ((info.Flags & CursorShowing) != 0)
        {
            foreach (var (handle, name) in SystemCursors)
            {
                if (handle == info.Cursor)
                {
                    kind = name;
                    break;
                }
            }
        }

        cursorFile.WriteLine(JsonSerializer.Serialize(new CursorSampleEvent { T = t, X = point.X, Y = point.Y, C = kind }, ProjectJson.Compact));
    }

    private void Handle(HookEvent item)
    {
        if (item.IsKeyboard)
        {
            HandleKey(item);
            return;
        }

        if (Elapsed(item.HostMs) is not { } t)
        {
            return;
        }

        var point = CaptureCoordinates.Normalize(item.A, item.B, bounds.X, bounds.Y, bounds.Width, bounds.Height);
        ClickEvent? click = item.Message switch
        {
            WmLButtonDown => Down(item, t, "left", point),
            WmRButtonDown => Down(item, t, "right", point),
            WmMButtonDown => Down(item, t, "other", point),
            WmLButtonUp => new ClickEvent { T = t, Type = "up", Button = "left", X = point.X, Y = point.Y, Count = clickCount },
            WmRButtonUp => new ClickEvent { T = t, Type = "up", Button = "right", X = point.X, Y = point.Y, Count = clickCount },
            WmMButtonUp => new ClickEvent { T = t, Type = "up", Button = "other", X = point.X, Y = point.Y, Count = clickCount },
            WmMouseWheel => new ClickEvent { T = t, Type = "scroll", X = point.X, Y = point.Y, Dx = 0, Dy = item.Delta / 120.0 * WheelNotchPoints },
            WmMouseHWheel => new ClickEvent { T = t, Type = "scroll", X = point.X, Y = point.Y, Dx = item.Delta / 120.0 * WheelNotchPoints, Dy = 0 },
            _ => null
        };
        if (click is not null)
        {
            clicksFile.WriteLine(JsonSerializer.Serialize(click, ProjectJson.Compact));
        }
    }

    private ClickEvent Down(HookEvent item, double t, string button, Point01 point)
    {
        var same = item.Message == lastDownButton
            && item.HostMs - lastDownMs <= doubleClickMs
            && Math.Abs(item.A - lastDownX) <= doubleClickWidth / 2
            && Math.Abs(item.B - lastDownY) <= doubleClickHeight / 2;
        clickCount = same ? clickCount + 1 : 1;
        lastDownMs = item.HostMs;
        lastDownButton = item.Message;
        lastDownX = item.A;
        lastDownY = item.B;
        return new ClickEvent { T = t, Type = "down", Button = button, X = point.X, Y = point.Y, Count = clickCount };
    }

    private void HandleKey(HookEvent item)
    {
        var vk = item.A;
        var isDown = item.Message is WmKeyDown or WmSysKeyDown;
        if (!isDown && item.Message is not (WmKeyUp or WmSysKeyUp))
        {
            return;
        }

        switch (vk)
        {
            case 0x10 or 0xA0 or 0xA1:
                shiftDown = isDown;
                break;
            case 0x11 or 0xA2 or 0xA3:
                controlDown = isDown;
                break;
            case 0x12 or 0xA4 or 0xA5:
                altDown = isDown;
                break;
            case 0x5B or 0x5C:
                metaDown = isDown;
                break;
        }

        if (!isDown)
        {
            downKeys.Remove(vk);
            return;
        }

        // A held key repeats its down event; the macOS recorder ignores repeats too.
        if (!downKeys.Add(vk) || KeyTelemetry.IsModifier(vk) || Elapsed(item.HostMs) is not { } t)
        {
            return;
        }

        var mapped = (char)(MapVirtualKeyW((uint)vk, 2) & 0x7FFF);
        var key = KeyTelemetry.KeyName(vk, mapped);
        var capsLock = (GetKeyState(0x14) & 1) != 0;
        var stroke = KeyTelemetry.Stroke(t, capsLock, metaDown, shiftDown, altDown, controlDown, key);
        keysFile.WriteLine(JsonSerializer.Serialize(stroke, ProjectJson.Compact));
    }

    private readonly record struct HookEvent(double HostMs, int Message, int A, int B, int Delta, bool IsKeyboard);

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseHookStruct
    {
        public int X;
        public int Y;
        public int MouseData;
        public int Flags;
        public int Time;
        public nint ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardHookStruct
    {
        public int VirtualKey;
        public int ScanCode;
        public int Flags;
        public int Time;
        public nint ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CursorInfo
    {
        public int Size;
        public int Flags;
        public nint Cursor;
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Message
    {
        public nint Window;
        public uint Id;
        public nint WParam;
        public nint LParam;
        public uint Time;
        public int X;
        public int Y;
    }

    private delegate nint LowLevelProc(int code, nint message, nint data);

    [DllImport("user32.dll")]
    private static extern nint SetWindowsHookExW(int id, LowLevelProc proc, nint module, uint threadId);

    [DllImport("user32.dll")]
    private static extern bool UnhookWindowsHookEx(nint hook);

    [DllImport("user32.dll")]
    private static extern nint CallNextHookEx(nint hook, int code, nint message, nint data);

    [DllImport("user32.dll")]
    private static extern int GetMessageW(out Message message, nint hwnd, uint min, uint max);

    [DllImport("user32.dll")]
    private static extern bool PeekMessageW(out Message message, nint hwnd, uint min, uint max, uint remove);

    [DllImport("user32.dll")]
    private static extern nint DispatchMessageW(ref Message message);

    [DllImport("user32.dll")]
    private static extern bool PostThreadMessageW(uint thread, int message, nint wparam, nint lparam);

    [DllImport("user32.dll")]
    private static extern bool GetCursorInfo(ref CursorInfo info);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern nint LoadCursorW(nint instance, nint name);

    [DllImport("user32.dll")]
    private static extern uint GetDoubleClickTime();

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll")]
    private static extern uint MapVirtualKeyW(uint code, uint type);

    [DllImport("user32.dll")]
    private static extern short GetKeyState(int key);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern nint GetModuleHandleW(string? name);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern nint CreateWaitableTimerExW(nint attributes, string? name, uint flags, uint access);

    [DllImport("kernel32.dll")]
    private static extern bool SetWaitableTimer(nint timer, ref long due, int period, nint routine, nint argument, bool resume);

    [DllImport("kernel32.dll")]
    private static extern uint WaitForSingleObject(nint handle, uint milliseconds);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(nint handle);
}
