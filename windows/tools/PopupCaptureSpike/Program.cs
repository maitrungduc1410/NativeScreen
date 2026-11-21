// Spike: which popup windows a window capture leaves out. For each case a popup is opened over an app's window; every
// window of that app's process that became visible is listed, then:
//   A. the main window is captured with Windows.Graphics.Capture (what the recorder does today), and the popup's rectangle
//      in it is compared with the same rectangle in a Desktop Duplication frame of the screen: the same pixels mean the
//      popup is in the window capture;
//   B. the popup window is captured on its own with Windows.Graphics.Capture.
// Cases: WinForms and Win32 popups and WPF popups in this process, WinUI 3 flyouts in Native Screen's recording bar (a
// sandboxed copy), and a Chromium <select>. Writes report.md and PNGs to the folder given as the first argument; the
// second argument is the Native Screen executable for the WinUI cases (optional).
using System.Diagnostics;
using System.IO;
using Path = System.IO.Path;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using WinRT;

namespace PopupCaptureSpike;

internal static unsafe class Program
{
    private static string output = "";
    private static readonly StringBuilder Report = new();
    private static ID3D11Device device = null!;

    [MTAThread]
    private static void Main(string[] args)
    {
        output = args.Length > 0 ? args[0] : Path.Combine(Path.GetTempPath(), "popup-capture-spike");
        var nativeScreen = args.Length > 1 ? args[1] : null;
        Directory.CreateDirectory(output);
        SetProcessDpiAwarenessContext(-4);
        D3D11.D3D11CreateDevice(null, DriverType.Hardware, DeviceCreationFlags.BgraSupport, [FeatureLevel.Level_11_0], out ID3D11Device? created).CheckError();
        device = created!;

        Report.AppendLine("# Popup capture spike");
        Report.AppendLine();
        Report.AppendLine($"Windows {Environment.OSVersion.Version}. A = is the popup in a capture of its main window (its rectangle compared with a Desktop Duplication frame; mean difference per channel). B = capture of the popup window alone.");
        Report.AppendLine();
        Report.AppendLine("| Toolkit | Popup | Window class | Styles | Owner | A: in window capture | B: popup alone |");
        Report.AppendLine("| :-- | :-- | :-- | :-- | :-- | :-- | :-- |");

        RunWinForms();
        RunWpf();
        if (nativeScreen is not null)
        {
            RunWinUi(nativeScreen);
        }

        RunChromium();

        File.WriteAllText(Path.Combine(output, "report.md"), Report.ToString());
        device.Dispose();
    }

    // MARK: Cases

    private static void RunWinForms()
    {
        TestForm? form = null;
        var ready = new ManualResetEventSlim();
        var ui = new Thread(() =>
        {
            Application.EnableVisualStyles();
            form = new TestForm();
            form.Shown += (_, _) => ready.Set();
            Application.Run(form);
        });
        ui.SetApartmentState(ApartmentState.STA);
        ui.Start();
        ready.Wait();
        Thread.Sleep(800);
        foreach (var scenario in form!.Scenarios)
        {
            Measure("WinForms / Win32", scenario.Name, form.Handle, (uint)Environment.ProcessId, () => form.Invoke(scenario.Open), () => scenario.Close(form));
        }

        form.Invoke(form.Close);
        ui.Join(3000);
    }

    private static void RunWpf()
    {
        WpfWindow? window = null;
        var ready = new ManualResetEventSlim();
        var ui = new Thread(() =>
        {
            window = new WpfWindow();
            window.ContentRendered += (_, _) => ready.Set();
            window.Show();
            System.Windows.Threading.Dispatcher.Run();
        });
        ui.SetApartmentState(ApartmentState.STA);
        ui.Start();
        ready.Wait();
        Thread.Sleep(800);
        var handle = window!.Dispatcher.Invoke(() => new System.Windows.Interop.WindowInteropHelper(window).Handle);
        foreach (var (name, open, close) in window.Scenarios)
        {
            Measure("WPF", name, handle, (uint)Environment.ProcessId, () => window.Dispatcher.Invoke(open), () => window.Dispatcher.Invoke(close));
        }

        window.Dispatcher.Invoke(() =>
        {
            window.Close();
            System.Windows.Threading.Dispatcher.CurrentDispatcher.InvokeShutdown();
        });
        ui.Join(3000);
    }

    /// <summary>
    /// Native Screen in a sandbox: an editor window (the recording bar is a tool window, which a window capture refuses)
    /// and its WinUI 3 menus.
    /// </summary>
    private static void RunWinUi(string executable)
    {
        var sandbox = Path.Combine(output, "nativescreen-sandbox");
        Directory.CreateDirectory(sandbox);
        var project = ShowcaseCopy(sandbox);
        var start = new ProcessStartInfo(executable, $"\"{project}\"") { UseShellExecute = false };
        start.Environment["NS_LOCAL_APP_DATA"] = sandbox;
        using var app = Process.Start(start)!;
        Thread.Sleep(10000);
        var editor = Windows((uint)app.Id).Where(window => window.Visible && window.Title.Length > 0 && window.Title != "Native Screen Recording")
            .OrderByDescending(window => Area(window.Handle)).FirstOrDefault();
        if (editor is null)
        {
            Report.AppendLine("| WinUI 3 | (editor not found) | | | | | |");
            app.Kill();
            return;
        }

        foreach (var button in new[] { "Menu", "Presets" })
        {
            Measure("WinUI 3", $"Editor {button} flyout", editor.Handle, (uint)app.Id, () => Ui.Invoke(app.Id, button), () => Ui.PressEscape(editor.Handle));
        }

        app.Kill();
    }

    /// <summary>A copy of the project given in NS_SPIKE_PROJECT, so the editor opens on something.</summary>
    private static string ShowcaseCopy(string sandbox)
    {
        var source = Environment.GetEnvironmentVariable("NS_SPIKE_PROJECT") ?? throw new InvalidOperationException("Set NS_SPIKE_PROJECT to a .nativescreen folder.");
        var target = Path.Combine(sandbox, Path.GetFileName(source.TrimEnd(Path.DirectorySeparatorChar)));
        if (!Directory.Exists(target))
        {
            foreach (var file in Directory.GetFiles(source, "*", SearchOption.AllDirectories))
            {
                var copy = Path.Combine(target, Path.GetRelativePath(source, file));
                Directory.CreateDirectory(Path.GetDirectoryName(copy)!);
                File.Copy(file, copy);
            }
        }

        return target;
    }

    private static long Area(nint window)
    {
        var rect = VisibleBounds(window);
        return (long)(rect.Right - rect.Left) * (rect.Bottom - rect.Top);
    }

    /// <summary>A &lt;select&gt; in Chrome, opened with its own throwaway profile so the person's browser is not touched.</summary>
    private static void RunChromium()
    {
        var chrome = new[] { @"C:\Program Files\Google\Chrome\Application\chrome.exe", @"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" }.FirstOrDefault(File.Exists);
        if (chrome is null)
        {
            Report.AppendLine("| Chromium | (no Chrome or Edge) | | | | | |");
            return;
        }

        var page = Path.Combine(output, "select.html");
        File.WriteAllText(page, """
            <!doctype html><title>Popup spike select</title>
            <body style="background:#00c800;margin:0">
            <select id="s" autofocus style="margin:40px;font-size:20px;width:320px">
            """ + string.Concat(Enumerable.Range(1, 20).Select(i => $"<option>Option {i}</option>")) + """
            </select></body>
            """);
        var profile = Path.Combine(output, "chrome-profile");
        using var browser = Process.Start(new ProcessStartInfo(chrome, $"--user-data-dir=\"{profile}\" --no-first-run --no-default-browser-check --window-position=200,150 --window-size=1000,760 --app=\"{new Uri(page)}\"") { UseShellExecute = false })!;
        Thread.Sleep(6000);
        var window = AllWindows().FirstOrDefault(info => info.Visible && info.Title.StartsWith("Popup spike select", StringComparison.Ordinal));
        if (window is null)
        {
            Report.AppendLine($"| Chromium | (window not found, {Path.GetFileName(chrome)}) | | | | | |");
            KillTree(browser, profile);
            return;
        }

        GetWindowThreadProcessId(window.Handle, out var pid);
        Measure($"Chromium ({Path.GetFileNameWithoutExtension(chrome)})", "<select> dropdown", window.Handle, pid, () => Ui.KeyTo(window.Handle, alt: true, 0x28), () => Ui.PressEscape(window.Handle));
        KillTree(browser, profile);
    }

    /// <summary>A separate profile starts a browser process of its own, so its tree is only this test.</summary>
    private static void KillTree(Process browser, string profile)
    {
        try
        {
            browser.Kill(entireProcessTree: true);
        }
        catch (Exception)
        {
            // Already gone.
        }
    }

    // MARK: Measuring

    private static void Measure(string toolkit, string name, nint main, uint pid, Action open, Action close)
    {
        var before = Windows(pid).Where(window => window.Visible).Select(window => window.Handle).ToHashSet();
        open();
        Thread.Sleep(900);
        var popups = Windows(pid).Where(window => window.Visible && !before.Contains(window.Handle) && window.Handle != main && window.Class != "SysShadow").ToList();
        var slug = Slug(toolkit + "-" + name);
        if (popups.Count == 0)
        {
            Report.AppendLine($"| {toolkit} | {name} | (no new window: drawn inside the main window) | | | | |");
        }
        else
        {
            var mainBounds = VisibleBounds(main);
            using var captured = CaptureWindow(main, out var mainError);
            Save(captured, $"{slug}-A.png");
            foreach (var popup in popups)
            {
                var rect = VisibleBounds(popup.Handle);
                using var screen = Duplicate(rect, out var duplicateError);
                Save(screen, $"{slug}-screen-{Hex(popup.Handle)}.png");
                string inCapture;
                if (captured is null || screen is null)
                {
                    inCapture = $"failed: {mainError ?? duplicateError}";
                }
                else
                {
                    inCapture = Compare(captured, mainBounds, screen, rect);
                }

                using var alone = CaptureWindow(popup.Handle, out var aloneError);
                var aloneText = alone is null ? $"refused ({aloneError})" : $"{alone.Width}x{alone.Height}";
                var owner = popup.Owner == main ? "main window" : popup.Owner == 0 ? "none" : $"{Hex(popup.Owner)} ({ClassOf(popup.Owner)})";
                Report.AppendLine($"| {toolkit} | {name} | `{popup.Class}` | {popup.Styles} | {owner} | {inCapture} | {aloneText} |");
            }
        }

        close();
        Thread.Sleep(600);
    }

    /// <summary>The popup's rectangle in the window capture against the same rectangle on the screen.</summary>
    private static string Compare(Bitmap captured, RECT capturedBounds, Bitmap screen, RECT rect)
    {
        long total = 0, difference = 0;
        for (var y = 0; y < screen.Height; y += 2)
        {
            for (var x = 0; x < screen.Width; x += 2)
            {
                var cx = rect.Left + x - capturedBounds.Left;
                var cy = rect.Top + y - capturedBounds.Top;
                if (cx < 0 || cy < 0 || cx >= captured.Width || cy >= captured.Height)
                {
                    continue;
                }

                var a = captured.GetPixel(cx, cy);
                var b = screen.GetPixel(x, y);
                difference += Math.Abs(a.R - b.R) + Math.Abs(a.G - b.G) + Math.Abs(a.B - b.B);
                total += 3;
            }
        }

        if (total == 0)
        {
            return "outside the window";
        }

        var mean = difference / (double)total;
        return mean < 10 ? $"**yes** ({mean:F1})" : $"**no** ({mean:F1})";
    }

    private static string Slug(string name) => new(name.Select(c => char.IsLetterOrDigit(c) ? char.ToLowerInvariant(c) : '-').ToArray());

    private static string Hex(nint handle) => "0x" + handle.ToString("X");

    private static void Save(Bitmap? bitmap, string name) => bitmap?.Save(Path.Combine(output, name), ImageFormat.Png);

    // MARK: Windows.Graphics.Capture

    private static Bitmap? CaptureWindow(nint window, out string? error)
    {
        error = null;
        try
        {
            using var dxgi = device.QueryInterface<IDXGIDevice>();
            Marshal.ThrowExceptionForHR(CreateDirect3D11DeviceFromDXGIDevice(dxgi.NativePointer, out var inspectable));
            var direct3D = MarshalInterface<IDirect3DDevice>.FromAbi(inspectable);
            Marshal.Release(inspectable);
            var item = ItemForWindow(window);
            using var pool = Direct3D11CaptureFramePool.CreateFreeThreaded(direct3D, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, item.Size);
            using var session = pool.CreateCaptureSession(item);
            session.IsCursorCaptureEnabled = false;
            session.StartCapture();
            for (var waited = 0; waited < 3000; waited += 20)
            {
                using var frame = pool.TryGetNextFrame();
                if (frame is not null)
                {
                    using var texture = TextureOf(frame);
                    return Read(texture, 0, 0, frame.ContentSize.Width, frame.ContentSize.Height);
                }

                Thread.Sleep(20);
            }

            error = "no frame in 3 s";
            return null;
        }
        catch (Exception exception)
        {
            error = $"{exception.GetType().Name} 0x{exception.HResult:X8}";
            return null;
        }
    }

    private static GraphicsCaptureItem ItemForWindow(nint window)
    {
        using var factory = ActivationFactory.Get("Windows.Graphics.Capture.GraphicsCaptureItem");
        var interopIid = new Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356");
        Marshal.ThrowExceptionForHR(Marshal.QueryInterface(factory.ThisPtr, in interopIid, out var interop));
        try
        {
            var method = (delegate* unmanaged[Stdcall]<nint, nint, Guid*, nint*, int>)(*(nint**)interop)[3];
            var itemIid = new Guid("79C3F95B-31F7-4EC2-A464-632EF5D30760");
            nint raw;
            Marshal.ThrowExceptionForHR(method(interop, window, &itemIid, &raw));
            try
            {
                return GraphicsCaptureItem.FromAbi(raw);
            }
            finally
            {
                Marshal.Release(raw);
            }
        }
        finally
        {
            Marshal.Release(interop);
        }
    }

    private static ID3D11Texture2D TextureOf(Direct3D11CaptureFrame frame)
    {
        var access = ((IWinRTObject)frame.Surface).NativeObject.As(new Guid("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1"));
        var iid = typeof(ID3D11Texture2D).GUID;
        var method = (delegate* unmanaged[Stdcall]<nint, Guid*, nint*, int>)(*(nint**)access.ThisPtr)[3];
        nint texture;
        Marshal.ThrowExceptionForHR(method(access.ThisPtr, &iid, &texture));
        access.Dispose();
        return new ID3D11Texture2D(texture);
    }

    // MARK: Desktop Duplication

    private static Bitmap? Duplicate(RECT rect, out string? error)
    {
        error = null;
        try
        {
            using var dxgi = device.QueryInterface<IDXGIDevice>();
            using var adapter = dxgi.GetAdapter();
            for (uint index = 0; adapter.EnumOutputs(index, out var output).Success; index++)
            {
                using (output)
                {
                    var bounds = output.Description.DesktopCoordinates;
                    if (rect.Left < bounds.Left || rect.Top < bounds.Top || rect.Left >= bounds.Right || rect.Top >= bounds.Bottom)
                    {
                        continue;
                    }

                    using var output1 = output.QueryInterface<IDXGIOutput1>();
                    using var duplication = output1.DuplicateOutput(device);
                    for (var tries = 0; tries < 20; tries++)
                    {
                        if (duplication.AcquireNextFrame(200, out var info, out var resource).Failure)
                        {
                            continue;
                        }

                        try
                        {
                            if (info.LastPresentTime == 0 && tries < 19)
                            {
                                continue;
                            }

                            using var texture = resource.QueryInterface<ID3D11Texture2D>();
                            var width = Math.Min(rect.Right, bounds.Right) - rect.Left;
                            var height = Math.Min(rect.Bottom, bounds.Bottom) - rect.Top;
                            return Read(texture, rect.Left - bounds.Left, rect.Top - bounds.Top, width, height);
                        }
                        finally
                        {
                            resource.Dispose();
                            duplication.ReleaseFrame();
                        }
                    }

                    error = "no frame";
                    return null;
                }
            }

            error = "popup on another adapter's output";
            return null;
        }
        catch (Exception exception)
        {
            error = $"{exception.GetType().Name} 0x{exception.HResult:X8}";
            return null;
        }
    }

    private static Bitmap Read(ID3D11Texture2D texture, int x, int y, int width, int height)
    {
        var description = texture.Description;
        description.Width = (uint)width;
        description.Height = (uint)height;
        description.Usage = ResourceUsage.Staging;
        description.BindFlags = BindFlags.None;
        description.CPUAccessFlags = CpuAccessFlags.Read;
        description.MiscFlags = ResourceOptionFlags.None;
        description.MipLevels = 1;
        description.ArraySize = 1;
        using var staging = device.CreateTexture2D(description);
        device.ImmediateContext.CopySubresourceRegion(staging, 0, 0, 0, 0, texture, 0, new Vortice.Mathematics.Box(x, y, 0, x + width, y + height, 1));
        var mapped = device.ImmediateContext.Map(staging, 0, MapMode.Read);
        var bitmap = new Bitmap(width, height, PixelFormat.Format32bppRgb);
        var data = bitmap.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.WriteOnly, PixelFormat.Format32bppRgb);
        for (var row = 0; row < height; row++)
        {
            Buffer.MemoryCopy((byte*)mapped.DataPointer + row * mapped.RowPitch, (byte*)data.Scan0 + row * data.Stride, data.Stride, width * 4);
        }

        bitmap.UnlockBits(data);
        device.ImmediateContext.Unmap(staging, 0);
        return bitmap;
    }

    // MARK: Windows

    internal sealed record WindowInfo(nint Handle, string Class, string Title, string Styles, nint Owner, bool Visible);

    private static List<WindowInfo> Windows(uint pid) => AllWindows().Where(window =>
    {
        GetWindowThreadProcessId(window.Handle, out var owner);
        return owner == pid;
    }).ToList();

    private static List<WindowInfo> AllWindows()
    {
        var list = new List<WindowInfo>();
        EnumWindows((handle, _) =>
        {
            var title = new StringBuilder(256);
            GetWindowTextW(handle, title, title.Capacity);
            var style = (long)GetWindowLongPtrW(handle, -16);
            var exStyle = (long)GetWindowLongPtrW(handle, -20);
            var flags = new List<string>();
            if ((style & 0x80000000L) != 0) flags.Add("POPUP");
            if ((exStyle & 0x80) != 0) flags.Add("TOOLWINDOW");
            if ((exStyle & 0x80000) != 0) flags.Add("LAYERED");
            if ((exStyle & 0x8) != 0) flags.Add("TOPMOST");
            if ((exStyle & 0x8000000) != 0) flags.Add("NOACTIVATE");
            if ((exStyle & 0x20) != 0) flags.Add("TRANSPARENT");
            if ((exStyle & 0x200000) != 0) flags.Add("NOREDIRECTIONBITMAP");
            list.Add(new WindowInfo(handle, ClassOf(handle), title.ToString(), string.Join(" ", flags), GetWindow(handle, 4), IsWindowVisible(handle) && !Cloaked(handle)));
            return true;
        }, 0);
        return list;
    }

    private static string ClassOf(nint handle)
    {
        var name = new StringBuilder(128);
        GetClassNameW(handle, name, name.Capacity);
        return name.ToString();
    }

    private static bool Cloaked(nint handle) => DwmGetWindowAttribute(handle, 14, out int cloaked, 4) == 0 && cloaked != 0;

    private static RECT VisibleBounds(nint window)
    {
        if (DwmGetWindowAttribute(window, 9, out RECT rect, Marshal.SizeOf<RECT>()) != 0)
        {
            GetWindowRect(window, out rect);
        }

        return rect;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct RECT
    {
        public int Left, Top, Right, Bottom;
    }

    private delegate bool EnumProc(nint handle, nint parameter);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc proc, nint parameter);
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint handle, out uint process);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(nint handle, StringBuilder name, int length);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(nint handle, StringBuilder text, int length);
    [DllImport("user32.dll")] private static extern nint GetWindowLongPtrW(nint handle, int index);
    [DllImport("user32.dll")] private static extern nint GetWindow(nint handle, uint command);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint handle);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(nint handle, out RECT rect);
    [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(nint context);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(nint handle, int attribute, out RECT value, int size);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(nint handle, int attribute, out int value, int size);
    [DllImport("d3d11.dll")] private static extern int CreateDirect3D11DeviceFromDXGIDevice(nint dxgiDevice, out nint graphicsDevice);
}
