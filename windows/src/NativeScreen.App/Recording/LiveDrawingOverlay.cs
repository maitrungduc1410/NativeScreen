using System.Diagnostics;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Text;
using NativeScreen.Core;
using NativeScreen.Media;
using Vortice.Direct2D1;
using Vortice.DXGI;
using Vortice.Mathematics;
using AlphaMode = Vortice.DCommon.AlphaMode;
using D2DPixelFormat = Vortice.DCommon.PixelFormat;
using PixelRect = NativeScreen.Media.PixelRect;

namespace NativeScreen.App;

/// <summary>
/// Drawing on the screen while recording (spec/02 §3.5, spec/06 ADR-79). A clear, topmost Win32 window over the recorded
/// display, left out of capture with `WDA_EXCLUDEFROMCAPTURE` (Windows applies it at any time, so it is made when drawing
/// first starts) and drawn with Direct2D, never InkCanvas: the exported strokes come from the compositor, so the screen must
/// show the same simple lines. It lets clicks through except while drawing. Every finished stroke, clear and undo is
/// appended to `telemetry/drawings.jsonl`; the project turns them into `Live drawing` annotations.
/// </summary>
internal sealed class LiveDrawingOverlay : IDisposable
{
    private const uint WsPopup = 0x80000000;
    private const uint WsExLayered = 0x00080000;
    private const uint WsExTopmost = 0x00000008;
    private const uint WsExToolWindow = 0x00000080;
    private const uint WsExTransparent = 0x00000020;
    private const uint WsExNoActivate = 0x08000000;
    private const int GwlExStyle = -20;
    private const uint WmKeyDown = 0x0100;
    private const uint WmMouseMove = 0x0200;
    private const uint WmLButtonDown = 0x0201;
    private const uint WmLButtonUp = 0x0202;
    private const uint WmTimer = 0x0113;
    private const int SwShowNoActivate = 4;
    private const int IdcCross = 32515;
    private const uint UlwAlpha = 2;
    private const double FadeMs = 300;

    private static readonly nint ClassAtom;
    private static readonly WndProc ClassProc = StaticProc;
    private static readonly Dictionary<nint, LiveDrawingOverlay> Instances = [];

    private readonly PixelRect screen;
    private readonly PixelRect recorded;
    private readonly IRecordingEngine engine;
    private readonly StreamWriter log;
    private readonly double? fadeAfterMs;
    private readonly nint hwnd;
    private readonly nint memoryDc;
    private readonly nint bitmap;
    private readonly ID2D1Factory factory;
    private readonly ID2D1DCRenderTarget target;
    private readonly List<Stroke> shown = [];
    private Stroke? current;
    private double lastPenUpMs = double.NegativeInfinity;
    private bool drawing;
    private bool disposed;

    private sealed class Stroke(LiveDrawingTool tool, string color, double startTimelineMs, double startHostMs)
    {
        public LiveDrawingTool Tool { get; } = tool;
        public string Color { get; } = color;
        public double StartTimelineMs { get; } = startTimelineMs;
        public double StartHostMs { get; } = startHostMs;
        public List<(Vector2 Pixel, double Ms)> Points { get; } = [];
    }

    static LiveDrawingOverlay()
    {
        var name = Marshal.StringToHGlobalUni("NativeScreenLiveDrawing");
        var cls = new WndClass
        {
            Size = (uint)Marshal.SizeOf<WndClass>(),
            Proc = Marshal.GetFunctionPointerForDelegate(ClassProc),
            Instance = GetModuleHandleW(null),
            Cursor = LoadCursorW(0, IdcCross),
            ClassName = name
        };
        ClassAtom = RegisterClassExW(ref cls);
    }

    /// <param name="stayUntilCleared">Read when the recording starts, so the screen and the saved strokes never disagree.</param>
    public LiveDrawingOverlay(CaptureDisplay display, PixelRect recorded, string package, IRecordingEngine engine, bool stayUntilCleared)
    {
        screen = display.Bounds;
        this.recorded = recorded;
        this.engine = engine;
        fadeAfterMs = stayUntilCleared ? null : LiveDrawingTools.FadeAfterMs;
        var path = Path.Combine(package, "recording", "telemetry", "drawings.jsonl");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        log = new StreamWriter(path, append: true, new UTF8Encoding(false)) { AutoFlush = true };
        hwnd = CreateWindowExW(WsExLayered | WsExTopmost | WsExToolWindow | WsExTransparent | WsExNoActivate, ClassAtom, null, WsPopup, screen.X, screen.Y, screen.Width, screen.Height, 0, 0, GetModuleHandleW(null), 0);
        Instances[hwnd] = this;
        CaptureTargets.SetExcludedFromCapture(hwnd, true);
        var header = new BitmapInfoHeader { Size = 40, Width = screen.Width, Height = -screen.Height, Planes = 1, BitCount = 32 };
        var screenDc = GetDC(0);
        memoryDc = CreateCompatibleDC(screenDc);
        bitmap = CreateDIBSection(screenDc, ref header, 0, out _, 0, 0);
        ReleaseDC(0, screenDc);
        SelectObject(memoryDc, bitmap);
        factory = D2D1.D2D1CreateFactory<ID2D1Factory>();
        target = factory.CreateDCRenderTarget(new RenderTargetProperties(new D2DPixelFormat(Format.B8G8R8A8_UNorm, AlphaMode.Premultiplied)));
        Present();
        ShowWindow(hwnd, SwShowNoActivate);
        // Redraws while strokes fade.
        SetTimer(hwnd, 1, 33, 0);
    }

    public LiveDrawingTool Tool { get; set; } = LiveDrawingTool.Pen;

    public string Color { get; set; } = LiveDrawingTools.Palette[0];

    public bool IsDrawing => drawing;

    /// <summary>Raised when drawing stops from the overlay (Esc), so the bar can follow.</summary>
    public event Action? DrawingStopped;

    /// <summary>Takes the mouse and keys while on; lets them through to the apps below otherwise.</summary>
    public void SetDrawing(bool on)
    {
        if (disposed || drawing == on)
        {
            return;
        }

        drawing = on;
        TelemetryRecorder.IsDrawing = on;
        var style = (uint)GetWindowLongPtrW(hwnd, GwlExStyle);
        style = on ? style & ~(WsExTransparent | WsExNoActivate) : style | WsExTransparent | WsExNoActivate;
        SetWindowLongPtrW(hwnd, GwlExStyle, (nint)style);
        if (on)
        {
            SetForegroundWindow(hwnd);
            SetFocus(hwnd);
        }
        else
        {
            FinishStroke();
        }
    }

    public void Undo()
    {
        if (shown.Count == 0 || TimelineNow() is not { } t)
        {
            return;
        }

        shown.RemoveAt(shown.Count - 1);
        Write(LiveDrawingEvent.Undo(t));
        Present();
    }

    public void Clear()
    {
        if (TimelineNow() is not { } t)
        {
            return;
        }

        shown.Clear();
        Write(LiveDrawingEvent.Clear(t));
        Present();
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        TelemetryRecorder.IsDrawing = false;
        KillTimer(hwnd, 1);
        Instances.Remove(hwnd);
        DestroyWindow(hwnd);
        target.Dispose();
        factory.Dispose();
        DeleteObject(bitmap);
        DeleteDC(memoryDc);
        log.Dispose();
    }

    private static double HostMs() => Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency;

    private double? TimelineNow() => engine.TimelineMs(HostMs());

    private void Write(LiveDrawingEvent drawingEvent)
    {
        try
        {
            log.WriteLine(System.Text.Json.JsonSerializer.Serialize(drawingEvent, ProjectJson.Compact));
        }
        catch (IOException)
        {
            // A full disk loses this stroke only; the recording goes on.
        }
    }

    private void FinishStroke()
    {
        if (current is not { } stroke)
        {
            return;
        }

        current = null;
        ReleaseCapture();
        if (stroke.Points.Count == 0)
        {
            return;
        }

        // Points are normalized to the recorded area like the cursor, with ms after the stroke began.
        var points = stroke.Points.Select(point => new[]
        {
            Math.Round((point.Pixel.X + screen.X - recorded.X) / Math.Max(1, recorded.Width), 5),
            Math.Round((point.Pixel.Y + screen.Y - recorded.Y) / Math.Max(1, recorded.Height), 5),
            Math.Round(point.Ms, 1)
        }).ToList();
        Write(LiveDrawingEvent.Stroke(stroke.StartTimelineMs, stroke.Tool, stroke.Color, points, fadeAfterMs));
        shown.Add(stroke);
        lastPenUpMs = HostMs();
        Present();
    }

    private nint Handle(uint message, nint wParam, nint lParam)
    {
        switch (message)
        {
            case WmLButtonDown when drawing:
            {
                if (TimelineNow() is not { } t)
                {
                    // Paused: nothing is recorded, so nothing is drawn.
                    return 0;
                }

                SetCapture(hwnd);
                current = new Stroke(Tool, Color, t, HostMs());
                current.Points.Add((PointOf(lParam), 0));
                Present();
                return 0;
            }

            case WmMouseMove when current is { } stroke:
            {
                var point = PointOf(lParam);
                var ms = HostMs() - stroke.StartHostMs;
                if (stroke.Tool is LiveDrawingTool.Arrow or LiveDrawingTool.Rectangle && stroke.Points.Count > 1)
                {
                    // Arrows and rectangles keep their first point and the latest one.
                    stroke.Points[^1] = (point, ms);
                }
                else if (Vector2.Distance(stroke.Points[^1].Pixel, point) >= 1.5f)
                {
                    stroke.Points.Add((point, ms));
                }

                if (stroke.Points.Count == 1)
                {
                    stroke.Points.Add((point, ms));
                }

                Present();
                return 0;
            }

            case WmLButtonUp:
                FinishStroke();
                return 0;
            case WmKeyDown when drawing:
                switch ((int)wParam)
                {
                    case 0x31: Tool = LiveDrawingTool.Pen; break;
                    case 0x32: Tool = LiveDrawingTool.Highlighter; break;
                    case 0x33: Tool = LiveDrawingTool.Arrow; break;
                    case 0x34: Tool = LiveDrawingTool.Rectangle; break;
                    case 0x5A when (GetKeyState(0x11) & 0x8000) != 0: Undo(); break;
                    case 0x43:
                    case 0x2E:
                        Clear();
                        break;
                    case 0x1B:
                        SetDrawing(false);
                        DrawingStopped?.Invoke();
                        break;
                }

                return 0;
            case WmTimer:
                if (shown.Count > 0 && fadeAfterMs is { } fade && HostMs() - lastPenUpMs > fade && current is null)
                {
                    var faded = HostMs() - lastPenUpMs - fade;
                    if (faded >= FadeMs)
                    {
                        // Strokes leave together, as in the project.
                        shown.Clear();
                    }

                    Present();
                }

                return 0;
        }

        return DefWindowProcW(hwnd, message, wParam, lParam);
    }

    private static Vector2 PointOf(nint lParam) => new((short)(lParam.ToInt64() & 0xFFFF), (short)((lParam.ToInt64() >> 16) & 0xFFFF));

    private void Present()
    {
        target.BindDC(memoryDc, new Vortice.RawRect(0, 0, screen.Width, screen.Height));
        target.BeginDraw();
        target.Clear(new Color4(0, 0, 0, 0));
        var opacity = 1f;
        if (fadeAfterMs is { } fade && current is null && shown.Count > 0)
        {
            var faded = HostMs() - lastPenUpMs - fade;
            opacity = faded <= 0 ? 1 : (float)Math.Max(0, 1 - faded / FadeMs);
        }

        foreach (var stroke in shown)
        {
            Draw(stroke, opacity);
        }

        if (current is { } live)
        {
            Draw(live, 1);
        }

        target.EndDraw();
        var position = new Point32 { X = screen.X, Y = screen.Y };
        var size = new Size32 { Cx = screen.Width, Cy = screen.Height };
        var source = default(Point32);
        var blend = new BlendFunction { SourceConstantAlpha = 255, AlphaFormat = 1 };
        UpdateLayeredWindow(hwnd, 0, ref position, ref size, memoryDc, ref source, 0, ref blend, UlwAlpha);
    }

    /// <summary>The same shapes as the pen annotation and the arrow and rectangle passes, at the recorded area's scale.</summary>
    private void Draw(Stroke stroke, float opacity)
    {
        if (stroke.Points.Count == 0)
        {
            return;
        }

        var (r, g, b) = AnnotationMath.HexColor(stroke.Color);
        var highlighter = stroke.Tool == LiveDrawingTool.Highlighter;
        using var brush = target.CreateSolidColorBrush(new Color4(r, g, b, opacity * (highlighter ? 0.42f : 1)));
        var width = (float)(stroke.Tool.StrokeRatio() * Math.Min(recorded.Width, recorded.Height));
        var cap = highlighter ? CapStyle.Flat : CapStyle.Round;
        using var style = factory.CreateStrokeStyle(new StrokeStyleProperties { StartCap = cap, EndCap = cap, LineJoin = LineJoin.Round });
        var first = stroke.Points[0].Pixel;
        var last = stroke.Points[^1].Pixel;
        switch (stroke.Tool)
        {
            case LiveDrawingTool.Rectangle:
                target.DrawRectangle(new Rect(Math.Min(first.X, last.X), Math.Min(first.Y, last.Y), Math.Abs(last.X - first.X), Math.Abs(last.Y - first.Y)), brush, width, style);
                break;
            case LiveDrawingTool.Arrow:
            {
                var arrow = AnnotationMath.ArrowGeometry(first, last, 0, width);
                target.DrawLine(arrow.Tail, arrow.ShaftEnd, brush, width, style);
                using var head = factory.CreatePathGeometry();
                using (var sink = head.Open())
                {
                    sink.BeginFigure(arrow.Head, FigureBegin.Filled);
                    sink.AddLine(arrow.HeadBaseLeft);
                    sink.AddLine(arrow.HeadBaseRight);
                    sink.EndFigure(FigureEnd.Closed);
                    sink.Close();
                }

                target.FillGeometry(head, brush);
                break;
            }

            default:
            {
                using var path = factory.CreatePathGeometry();
                using (var sink = path.Open())
                {
                    sink.BeginFigure(first, FigureBegin.Hollow);
                    if (stroke.Points.Count == 1)
                    {
                        sink.AddLine(first + new Vector2(0.01f, 0));
                    }

                    for (var i = 1; i < stroke.Points.Count - 1; i++)
                    {
                        var point = stroke.Points[i].Pixel;
                        sink.AddQuadraticBezier(new QuadraticBezierSegment { Point1 = point, Point2 = (point + stroke.Points[i + 1].Pixel) * 0.5f });
                    }

                    if (stroke.Points.Count > 1)
                    {
                        sink.AddLine(last);
                    }

                    sink.EndFigure(FigureEnd.Open);
                    sink.Close();
                }

                target.DrawGeometry(path, brush, width, style);
                break;
            }
        }
    }

    private static nint StaticProc(nint window, uint message, nint wParam, nint lParam) =>
        Instances.TryGetValue(window, out var overlay) ? overlay.Handle(message, wParam, lParam) : DefWindowProcW(window, message, wParam, lParam);

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
    private struct BitmapInfoHeader
    {
        public uint Size;
        public int Width;
        public int Height;
        public ushort Planes;
        public ushort BitCount;
        public uint Compression;
        public uint SizeImage;
        public int XPelsPerMeter;
        public int YPelsPerMeter;
        public uint ClrUsed;
        public uint ClrImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point32
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Size32
    {
        public int Cx;
        public int Cy;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BlendFunction
    {
        public byte BlendOp;
        public byte BlendFlags;
        public byte SourceConstantAlpha;
        public byte AlphaFormat;
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

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(nint window, int command);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(nint window);

    [DllImport("user32.dll")]
    private static extern nint SetFocus(nint window);

    [DllImport("user32.dll")]
    private static extern nint SetCapture(nint window);

    [DllImport("user32.dll")]
    private static extern bool ReleaseCapture();

    [DllImport("user32.dll")]
    private static extern short GetKeyState(int key);

    [DllImport("user32.dll")]
    private static extern nint LoadCursorW(nint instance, nint name);

    [DllImport("user32.dll")]
    private static extern nint GetDC(nint window);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(nint window, nint dc);

    [DllImport("user32.dll")]
    private static extern bool UpdateLayeredWindow(nint window, nint target, ref Point32 position, ref Size32 size, nint source, ref Point32 sourcePosition, uint key, ref BlendFunction blend, uint flags);

    [DllImport("user32.dll")]
    private static extern nint GetWindowLongPtrW(nint window, int index);

    [DllImport("user32.dll")]
    private static extern nint SetWindowLongPtrW(nint window, int index, nint value);

    [DllImport("user32.dll")]
    private static extern nuint SetTimer(nint window, nuint id, uint elapse, nint callback);

    [DllImport("user32.dll")]
    private static extern bool KillTimer(nint window, nuint id);

    [DllImport("gdi32.dll")]
    private static extern nint CreateCompatibleDC(nint dc);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteDC(nint dc);

    [DllImport("gdi32.dll")]
    private static extern nint CreateDIBSection(nint dc, ref BitmapInfoHeader header, uint usage, out nint bits, nint section, uint offset);

    [DllImport("gdi32.dll")]
    private static extern nint SelectObject(nint dc, nint item);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(nint item);
}
