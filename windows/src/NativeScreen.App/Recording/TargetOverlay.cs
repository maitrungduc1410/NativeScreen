using System.Drawing;
using System.Numerics;
using System.Runtime.InteropServices;
using NativeScreen.Core;
using NativeScreen.Media;
using Vortice.Direct2D1;
using Vortice.DirectWrite;
using Vortice.DXGI;
using Vortice.Mathematics;
using Vortice.WIC;
using AlphaMode = Vortice.DCommon.AlphaMode;
using D2DPixelFormat = Vortice.DCommon.PixelFormat;
using PixelRect = NativeScreen.Media.PixelRect;

namespace NativeScreen.App;

/// <summary>
/// The picker over the whole desktop, like WindowAndAreaPickerOverlayView on macOS: dims everything, follows the window or
/// display under the pointer, and carries the Start button itself. A per-pixel-alpha Win32 window drawn with Direct2D, because
/// WinUI has no transparent windows. Runs on the UI thread, whose loop already pumps Win32 messages.
/// </summary>
internal sealed class TargetOverlay : IDisposable
{
    private const uint WsPopup = 0x80000000;
    private const uint WsExLayered = 0x00080000;
    private const uint WsExTopmost = 0x00000008;
    private const uint WsExToolWindow = 0x00000080;
    private const uint WmKeyDown = 0x0100;
    private const uint WmMouseMove = 0x0200;
    private const uint WmLButtonDown = 0x0201;
    private const uint WmLButtonUp = 0x0202;
    private const int VkEscape = 0x1B;
    private const int SwShowNoActivate = 4;
    private const int IdcArrow = 32512;
    private const uint UlwAlpha = 2;
    private const uint TpmReturnCommand = 0x0100;
    private const uint SwpNoMove = 0x0002;
    private const uint SwpNoZOrder = 0x0004;
    private const int MinimumAreaSize = 64;
    private const int HandleHitSize = 16;

    private static readonly (string Label, int Width, int Height)[] WindowSizes =
    [
        ("16:9 HD (1280 × 720)", 1280, 720),
        ("16:9 HD+ (1600 × 900)", 1600, 900),
        ("16:9 Full HD (1920 × 1080)", 1920, 1080),
        ("16:10 (1440 × 900)", 1440, 900),
        ("1:1 Square (1080 × 1080)", 1080, 1080),
        ("9:16 Vertical (608 × 1080)", 608, 1080)
    ];

    private static readonly Color4 Dim = new(0, 0, 0, 0.22f);
    private static readonly Color4 Accent = new(0.36f, 0.22f, 0.98f, 1);
    private static readonly Color4 AccentBorder = new(0.44f, 0.30f, 1, 0.95f);
    private static readonly Color4 CardFill = new(0.12f, 0.12f, 0.15f, 0.94f);
    private static readonly Color4 CardBorder = new(1, 1, 1, 0.18f);

    private static readonly nint ClassAtom;
    private static readonly WndProc ClassProc = StaticProc;
    private static readonly Dictionary<nint, TargetOverlay> Instances = [];

    private readonly CaptureTargetMode mode;
    private readonly Action<CaptureTarget> start;
    private readonly Action cancelled;
    private readonly PixelRect screen;
    private readonly nint hwnd;
    private readonly nint memoryDc;
    private readonly nint bitmap;
    private readonly ID2D1Factory factory;
    private readonly ID2D1DCRenderTarget target;
    private readonly IDWriteFactory write;
    private readonly IWICImagingFactory imaging = new();
    private readonly List<(RectangleF Rect, Action Click)> buttons = [];
    private IReadOnlyList<CaptureWindow> windows;
    private CaptureWindow? hovered;
    private CaptureDisplay display;
    private PixelRect area;
    private (int X, int Y)? pressed;
    private PixelRect pressedArea;
    private int resizeX;
    private int resizeY;
    private ID2D1Bitmap? icon;
    private string? iconPath;
    private bool disposed;

    static TargetOverlay()
    {
        var name = Marshal.StringToHGlobalUni("NativeScreenTargetOverlay");
        var cls = new WndClass
        {
            Size = (uint)Marshal.SizeOf<WndClass>(),
            Proc = Marshal.GetFunctionPointerForDelegate(ClassProc),
            Instance = GetModuleHandleW(null),
            Cursor = LoadCursorW(0, IdcArrow),
            ClassName = name
        };
        ClassAtom = RegisterClassExW(ref cls);
    }

    public TargetOverlay(CaptureTargetMode mode, CaptureDisplay initialDisplay, Action<CaptureTarget> start, Action cancelled, nint recordingBar = 0)
    {
        this.mode = mode;
        this.start = start;
        this.cancelled = cancelled;
        display = initialDisplay;
        screen = CaptureTargets.VirtualScreen();
        // The recording bar is not a target. It is only left out of capture while recording, so it is removed here; without
        // this, a pick opened from its Window button started on the bar itself, since the pointer was still on it.
        windows = mode == CaptureTargetMode.Window ? CaptureTargets.WindowsFrontToBack().Where(window => window.Handle != recordingBar).ToList() : [];
        var width = Math.Min((int)(1280 * display.Scale), (int)(display.Bounds.Width * 0.7));
        var height = Math.Min((int)(720 * display.Scale), (int)(display.Bounds.Height * 0.7));
        area = new PixelRect(display.Bounds.X + (display.Bounds.Width - width) / 2, display.Bounds.Y + (display.Bounds.Height - height) / 2, width, height);

        hwnd = CreateWindowExW(WsExLayered | WsExTopmost | WsExToolWindow, ClassAtom, null, WsPopup, screen.X, screen.Y, screen.Width, screen.Height, 0, 0, GetModuleHandleW(null), 0);
        Instances[hwnd] = this;
        CaptureTargets.SetExcludedFromCapture(hwnd, true);

        var header = new BitmapInfoHeader { Size = 40, Width = screen.Width, Height = -screen.Height, Planes = 1, BitCount = 32 };
        var screenDc = GetDC(0);
        memoryDc = CreateCompatibleDC(screenDc);
        bitmap = CreateDIBSection(screenDc, ref header, 0, out _, 0, 0);
        ReleaseDC(0, screenDc);
        SelectObject(memoryDc, bitmap);
        factory = D2D1.D2D1CreateFactory<ID2D1Factory>();
        write = DWrite.DWriteCreateFactory<IDWriteFactory>();
        target = factory.CreateDCRenderTarget(new RenderTargetProperties(new D2DPixelFormat(Format.B8G8R8A8_UNorm, AlphaMode.Premultiplied)));
        target.TextAntialiasMode = Vortice.Direct2D1.TextAntialiasMode.Grayscale;

        GetCursorPos(out var cursor);
        UpdateHover(cursor.X, cursor.Y);
        Present();
        ShowWindow(hwnd, SwShowNoActivate);
        SetForegroundWindow(hwnd);
        SetFocus(hwnd);
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        Instances.Remove(hwnd);
        DestroyWindow(hwnd);
        icon?.Dispose();
        target.Dispose();
        factory.Dispose();
        write.Dispose();
        imaging.Dispose();
        DeleteObject(bitmap);
        DeleteDC(memoryDc);
    }

    /// <summary>Clicking the mode again, or anything else that ends picking without a choice.</summary>
    public void Cancel() => Dispose();

    private static nint StaticProc(nint window, uint message, nint wParam, nint lParam)
    {
        if (Instances.TryGetValue(window, out var overlay) && overlay.Handle(message, wParam, lParam))
        {
            return 0;
        }

        return DefWindowProcW(window, message, wParam, lParam);
    }

    private bool Handle(uint message, nint wParam, nint lParam)
    {
        var x = (short)(lParam & 0xFFFF) + screen.X;
        var y = (short)((lParam >> 16) & 0xFFFF) + screen.Y;
        switch (message)
        {
            case WmKeyDown when wParam == VkEscape:
                Dispose();
                cancelled();
                return true;
            case WmMouseMove:
                Moved(x, y);
                return true;
            case WmLButtonDown:
                Pressed(x, y);
                return true;
            case WmLButtonUp:
                pressed = null;
                ReleaseCapture();
                return true;
            default:
                return false;
        }
    }

    private void Moved(int x, int y)
    {
        if (pressed is { } origin)
        {
            var dx = x - origin.X;
            var dy = y - origin.Y;
            var left = pressedArea.X + (resizeX < 0 ? dx : resizeX == 0 ? dx : 0);
            var top = pressedArea.Y + (resizeY < 0 ? dy : resizeY == 0 ? dy : 0);
            var width = pressedArea.Width + (resizeX > 0 ? dx : resizeX < 0 ? -dx : 0);
            var height = pressedArea.Height + (resizeY > 0 ? dy : resizeY < 0 ? -dy : 0);
            if (resizeX == 0 && resizeY == 0)
            {
                left = Math.Clamp(left, display.Bounds.X, display.Bounds.X + display.Bounds.Width - width);
                top = Math.Clamp(top, display.Bounds.Y, display.Bounds.Y + display.Bounds.Height - height);
            }

            area = new PixelRect(left, top, Math.Max(MinimumAreaSize, width), Math.Max(MinimumAreaSize, height));
            Present();
            return;
        }

        if (UpdateHover(x, y))
        {
            Present();
        }
    }

    private bool UpdateHover(int x, int y)
    {
        var changed = false;
        if (mode == CaptureTargetMode.Window)
        {
            var next = windows.FirstOrDefault(window => window.Bounds.Contains(x, y));
            changed = next?.Handle != hovered?.Handle;
            hovered = next;
        }

        if (mode != CaptureTargetMode.Area)
        {
            var next = hovered is { } window ? CaptureTargets.DisplayOf(window.Bounds) : CaptureTargets.DisplayAt(x, y);
            changed |= next.Handle != display.Handle;
            display = next;
        }

        return changed;
    }

    private void Pressed(int x, int y)
    {
        foreach (var (rect, click) in buttons)
        {
            if (rect.Contains(x, y))
            {
                click();
                return;
            }
        }

        if (mode != CaptureTargetMode.Area || !area.Contains(x, y) && !NearCorner(x, y))
        {
            return;
        }

        resizeX = Math.Abs(x - area.X) < HandleHitSize ? -1 : Math.Abs(x - area.X - area.Width) < HandleHitSize ? 1 : 0;
        resizeY = Math.Abs(y - area.Y) < HandleHitSize ? -1 : Math.Abs(y - area.Y - area.Height) < HandleHitSize ? 1 : 0;
        if (resizeX == 0 || resizeY == 0)
        {
            resizeX = 0;
            resizeY = 0;
        }

        pressed = (x, y);
        pressedArea = area;
        SetCapture(hwnd);
    }

    private bool NearCorner(int x, int y) =>
        (Math.Abs(x - area.X) < HandleHitSize || Math.Abs(x - area.X - area.Width) < HandleHitSize)
        && (Math.Abs(y - area.Y) < HandleHitSize || Math.Abs(y - area.Y - area.Height) < HandleHitSize);

    private void Finish(CaptureTarget chosen)
    {
        Dispose();
        start(chosen);
    }

    private void Present()
    {
        buttons.Clear();
        var whole = new Vortice.RawRect(0, 0, screen.Width, screen.Height);
        target.BindDC(memoryDc, whole);
        target.BeginDraw();
        target.Clear(Dim);
        switch (mode)
        {
            case CaptureTargetMode.Window:
                DrawWindowMode();
                break;
            case CaptureTargetMode.Area:
                DrawAreaMode();
                break;
            default:
                DrawDisplayMode();
                break;
        }

        target.EndDraw();
        var position = new Point32 { X = screen.X, Y = screen.Y };
        var size = new Size32 { Cx = screen.Width, Cy = screen.Height };
        var source = default(Point32);
        var blend = new BlendFunction { SourceConstantAlpha = 255, AlphaFormat = 1 };
        UpdateLayeredWindow(hwnd, 0, ref position, ref size, memoryDc, ref source, 0, ref blend, UlwAlpha);
    }

    private float S => (float)display.Scale;

    private RectangleF Local(PixelRect rect) => new(rect.X - screen.X, rect.Y - screen.Y, rect.Width, rect.Height);

    private void DrawWindowMode()
    {
        if (hovered is not { } window)
        {
            DrawHint(Loc.T("Move the pointer over a window"));
            return;
        }

        var radius = (Environment.OSVersion.Version.Build >= 22000 && !window.IsMaximized ? 8 : 0) * S;
        var rect = Local(window.Bounds);
        Fill(rect, radius, new Color4(0.36f, 0.22f, 0.98f, 0.24f));
        Stroke(rect, radius, AccentBorder, 2.5f * S);

        var loaded = IconFor(window);
        using var title = Text(window.AppName, 20, FontWeight.Bold);
        var sizeText = $"{window.Bounds.Width} × {window.Bounds.Height}";
        using var sizeLayout = Text(sizeText, 13, FontWeight.Regular);
        using var resizeLayout = Text(Loc.T("Resize"), 11.5f, FontWeight.Medium);
        using var startLayout = Text(Loc.T("Start recording"), 14, FontWeight.SemiBold);
        var padding = 22 * S;
        var resizeWidth = resizeLayout.Metrics.Width + 20 * S;
        var row = sizeLayout.Metrics.Width + 8 * S + resizeWidth;
        var startWidth = startLayout.Metrics.Width + 36 * S + 22 * S;
        var contentWidth = Math.Max(Math.Max(title.Metrics.Width, row), startWidth);
        var iconSize = loaded is null ? 0 : 64 * S;
        var height = padding * 2 + iconSize + (loaded is null ? 0 : 10 * S) + title.Metrics.Height + 10 * S + 26 * S + 14 * S + 40 * S;
        var card = CenteredCard(rect, contentWidth + padding * 2, height);
        DrawCard(card);
        var y = card.Y + padding;
        var middle = card.X + card.Width / 2;
        if (loaded is not null)
        {
            target.DrawBitmap(loaded, new Rect(middle - iconSize / 2, y, iconSize, iconSize), 1, Vortice.Direct2D1.BitmapInterpolationMode.Linear, new Rect(0, 0, loaded.Size.Width, loaded.Size.Height));
            y += iconSize + 10 * S;
        }

        DrawText(title, middle - title.Metrics.Width / 2, y, new Color4(1, 1, 1, 1));
        y += title.Metrics.Height + 10 * S;
        var rowLeft = middle - row / 2;
        DrawText(sizeLayout, rowLeft, y + (26 * S - sizeLayout.Metrics.Height) / 2, new Color4(1, 1, 1, 0.85f));
        var resize = new RectangleF(rowLeft + sizeLayout.Metrics.Width + 8 * S, y, resizeWidth, 26 * S);
        Fill(resize, 13 * S, new Color4(1, 1, 1, 0.18f));
        DrawText(resizeLayout, resize.X + 10 * S, y + (26 * S - resizeLayout.Metrics.Height) / 2, new Color4(1, 1, 1, 1));
        AddButton(resize, () => ShowResizeMenu(window));
        y += 26 * S + 14 * S;
        var targetWindow = window;
        DrawStartButton(new RectangleF(middle - startWidth / 2, y, startWidth, 40 * S), startLayout, () =>
        {
            CaptureTargets.BringToFront(targetWindow.Handle);
            var fresh = CaptureTargets.WindowInfo(targetWindow.Handle) ?? targetWindow;
            Finish(new CaptureTarget(CaptureTargetMode.Window, display, fresh, fresh.Bounds));
        });
    }

    private void DrawDisplayMode()
    {
        var bounds = Local(display.Bounds);
        var inset = new RectangleF(bounds.X + 8 * S, bounds.Y + 8 * S, bounds.Width - 16 * S, bounds.Height - 16 * S);
        Fill(inset, 14 * S, new Color4(0.36f, 0.22f, 0.98f, 0.10f));
        Stroke(inset, 14 * S, new Color4(0.44f, 0.30f, 1, 1), 4 * S);
        using var title = Text(display.IsPrimary ? Loc.T("Primary display") : Loc.F("Display %lld", display.Id), 20, FontWeight.Bold);
        using var detail = Text(Loc.F("%lld × %lld • Press ESC to cancel", display.Bounds.Width, display.Bounds.Height), 13, FontWeight.Regular);
        using var startLayout = Text(Loc.T("Record This Display"), 14, FontWeight.SemiBold);
        var padding = 24 * S;
        var startWidth = startLayout.Metrics.Width + 58 * S;
        var contentWidth = Math.Max(Math.Max(title.Metrics.Width, detail.Metrics.Width), startWidth);
        var height = padding * 2 + title.Metrics.Height + 12 * S + detail.Metrics.Height + 12 * S + 40 * S;
        var card = CenteredCard(inset, contentWidth + padding * 2, height);
        DrawCard(card);
        var middle = card.X + card.Width / 2;
        var y = card.Y + padding;
        DrawText(title, middle - title.Metrics.Width / 2, y, new Color4(1, 1, 1, 1));
        y += title.Metrics.Height + 12 * S;
        DrawText(detail, middle - detail.Metrics.Width / 2, y, new Color4(1, 1, 1, 0.75f));
        y += detail.Metrics.Height + 12 * S;
        var chosen = display;
        DrawStartButton(new RectangleF(middle - startWidth / 2, y, startWidth, 40 * S), startLayout, () => Finish(new CaptureTarget(CaptureTargetMode.Display, chosen, null, chosen.Bounds)));
    }

    private void DrawAreaMode()
    {
        var rect = Local(area);
        Fill(rect, 10 * S, new Color4(0.36f, 0.22f, 0.98f, 0.12f));
        using var white = target.CreateSolidColorBrush(new Color4(1, 1, 1, 1));
        using var style = factory.CreateStrokeStyle(new StrokeStyleProperties { DashStyle = DashStyle.Custom }, [4f, 2f]);
        target.DrawRoundedRectangle(new RoundedRectangle(rect, 10 * S, 10 * S), white, 2 * S, style);
        foreach (var (x, y) in new[] { (rect.Left, rect.Top), (rect.Right, rect.Top), (rect.Left, rect.Bottom), (rect.Right, rect.Bottom) })
        {
            target.FillEllipse(new Ellipse(new Vector2(x, y), 5 * S, 5 * S), white);
        }

        using var sizeLayout = Text($"{area.Width} × {area.Height}", 13.5f, FontWeight.Medium);
        using var startLayout = Text(Loc.T("Start Area Recording"), 13, FontWeight.SemiBold);
        var padding = 16 * S;
        var presets = WindowSizes.Take(4).ToArray();
        var layouts = presets.Select(preset => Text($"{preset.Width}x{preset.Height}", 11.5f, FontWeight.Medium)).ToList();
        var row = layouts.Sum(layout => layout.Metrics.Width + 16 * S) + 8 * S * (layouts.Count - 1);
        var startWidth = startLayout.Metrics.Width + 32 * S;
        var contentWidth = Math.Max(Math.Max(sizeLayout.Metrics.Width, row), startWidth);
        var height = padding * 2 + sizeLayout.Metrics.Height + 10 * S + 26 * S + 10 * S + 34 * S;
        var card = CenteredCard(rect, contentWidth + padding * 2, height);
        DrawCard(card);
        var middle = card.X + card.Width / 2;
        var top = card.Y + padding;
        DrawText(sizeLayout, middle - sizeLayout.Metrics.Width / 2, top, new Color4(1, 1, 1, 1));
        top += sizeLayout.Metrics.Height + 10 * S;
        var left = middle - row / 2;
        for (var index = 0; index < presets.Length; index++)
        {
            var layout = layouts[index];
            var (_, presetWidth, presetHeight) = presets[index];
            var pill = new RectangleF(left, top, layout.Metrics.Width + 16 * S, 26 * S);
            Fill(pill, 6 * S, Accent);
            DrawText(layout, pill.X + 8 * S, pill.Y + (pill.Height - layout.Metrics.Height) / 2, new Color4(1, 1, 1, 1));
            AddButton(pill, () =>
            {
                var newWidth = Math.Min((int)(presetWidth * display.Scale), display.Bounds.Width);
                var newHeight = Math.Min((int)(presetHeight * display.Scale), display.Bounds.Height);
                area = new PixelRect(
                    Math.Clamp(area.X, display.Bounds.X, display.Bounds.X + display.Bounds.Width - newWidth),
                    Math.Clamp(area.Y, display.Bounds.Y, display.Bounds.Y + display.Bounds.Height - newHeight),
                    newWidth,
                    newHeight);
                Present();
            });
            left += pill.Width + 8 * S;
            layout.Dispose();
        }

        top += 26 * S + 10 * S;
        DrawStartButton(new RectangleF(middle - startWidth / 2, top, startWidth, 34 * S), startLayout, () =>
        {
            var chosen = CaptureTargets.DisplayOf(area);
            Finish(new CaptureTarget(CaptureTargetMode.Area, chosen, null, area));
        });
    }

    private void DrawHint(string text)
    {
        using var layout = Text(text, 14, FontWeight.Medium);
        var bounds = Local(display.Bounds);
        var card = CenteredCard(bounds, layout.Metrics.Width + 40 * S, layout.Metrics.Height + 24 * S);
        DrawCard(card);
        DrawText(layout, card.X + 20 * S, card.Y + 12 * S, new Color4(1, 1, 1, 0.9f));
    }

    private void ShowResizeMenu(CaptureWindow window)
    {
        var menu = CreatePopupMenu();
        for (var index = 0; index < WindowSizes.Length; index++)
        {
            AppendMenuW(menu, 0, (nuint)(index + 1), WindowSizes[index].Label);
        }

        GetCursorPos(out var cursor);
        var chosen = TrackPopupMenu(menu, TpmReturnCommand, cursor.X, cursor.Y, 0, hwnd, 0);
        DestroyMenu(menu);
        if (chosen <= 0)
        {
            return;
        }

        var (_, width, height) = WindowSizes[chosen - 1];
        SetWindowPos(window.Handle, 0, 0, 0, (int)(width * display.Scale), (int)(height * display.Scale), SwpNoMove | SwpNoZOrder);
        windows = CaptureTargets.WindowsFrontToBack();
        hovered = CaptureTargets.WindowInfo(window.Handle) ?? window;
        Present();
    }

    private ID2D1Bitmap? IconFor(CaptureWindow window)
    {
        if (window.ProcessPath == iconPath)
        {
            return icon;
        }

        iconPath = window.ProcessPath;
        icon?.Dispose();
        icon = null;
        if (iconPath is null)
        {
            return null;
        }

        var handles = new nint[1];
        if (PrivateExtractIconsW(iconPath, 0, (int)(64 * S), (int)(64 * S), handles, null, 1, 0) < 1 || handles[0] == 0)
        {
            return null;
        }

        try
        {
            using var source = imaging.CreateBitmapFromHICON(handles[0]);
            using var converter = imaging.CreateFormatConverter();
            converter.Initialize(source, Vortice.WIC.PixelFormat.Format32bppPBGRA, BitmapDitherType.None, null, 0, BitmapPaletteType.Custom);
            icon = target.CreateBitmapFromWicBitmap(converter);
        }
        catch (SharpGen.Runtime.SharpGenException)
        {
            icon = null;
        }
        finally
        {
            DestroyIcon(handles[0]);
        }

        return icon;
    }

    private static RectangleF CenteredCard(RectangleF within, float width, float height) =>
        new(within.X + (within.Width - width) / 2, within.Y + (within.Height - height) / 2, width, height);

    private void DrawCard(RectangleF card)
    {
        Fill(card, 18 * S, CardFill);
        Stroke(card, 18 * S, CardBorder, 1 * S);
    }

    private void DrawStartButton(RectangleF rect, IDWriteTextLayout label, Action click)
    {
        Fill(rect, 10 * S, Accent);
        using var white = target.CreateSolidColorBrush(new Color4(1, 1, 1, 1));
        var dotX = rect.X + (rect.Width - label.Metrics.Width - 22 * S) / 2 + 7 * S;
        target.DrawEllipse(new Ellipse(new Vector2(dotX, rect.Y + rect.Height / 2), 7 * S, 7 * S), white, 1.5f * S);
        target.FillEllipse(new Ellipse(new Vector2(dotX, rect.Y + rect.Height / 2), 3.5f * S, 3.5f * S), white);
        DrawText(label, dotX + 15 * S, rect.Y + (rect.Height - label.Metrics.Height) / 2, new Color4(1, 1, 1, 1));
        AddButton(rect, click);
    }

    private void AddButton(RectangleF local, Action click) =>
        buttons.Add((new RectangleF(local.X + screen.X, local.Y + screen.Y, local.Width, local.Height), click));

    private IDWriteTextLayout Text(string text, float size, FontWeight weight)
    {
        using var format = write.CreateTextFormat("Segoe UI", weight, Vortice.DirectWrite.FontStyle.Normal, FontStretch.Normal, size * S);
        return write.CreateTextLayout(text, format, 4096, 4096);
    }

    private void DrawText(IDWriteTextLayout layout, float x, float y, Color4 color)
    {
        using var brush = target.CreateSolidColorBrush(color);
        target.DrawTextLayout(new Vector2(x, y), layout, brush);
    }

    private void Fill(RectangleF rect, float radius, Color4 color)
    {
        using var brush = target.CreateSolidColorBrush(color);
        target.FillRoundedRectangle(new RoundedRectangle(rect, radius, radius), brush);
    }

    private void Stroke(RectangleF rect, float radius, Color4 color, float width)
    {
        using var brush = target.CreateSolidColorBrush(color);
        target.DrawRoundedRectangle(new RoundedRectangle(rect, radius, radius), brush, width);
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
    private static extern bool GetCursorPos(out Point32 point);

    [DllImport("user32.dll")]
    private static extern nint LoadCursorW(nint instance, nint name);

    [DllImport("user32.dll")]
    private static extern nint GetDC(nint window);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(nint window, nint dc);

    [DllImport("user32.dll")]
    private static extern bool UpdateLayeredWindow(nint window, nint target, ref Point32 position, ref Size32 size, nint source, ref Point32 sourcePosition, uint key, ref BlendFunction blend, uint flags);

    [DllImport("user32.dll")]
    private static extern nint CreatePopupMenu();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool AppendMenuW(nint menu, uint flags, nuint id, string text);

    [DllImport("user32.dll")]
    private static extern int TrackPopupMenu(nint menu, uint flags, int x, int y, int reserved, nint window, nint rect);

    [DllImport("user32.dll")]
    private static extern bool DestroyMenu(nint menu);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern uint PrivateExtractIconsW(string file, int index, int width, int height, nint[] icons, uint[]? ids, uint count, uint flags);

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(nint icon);

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
