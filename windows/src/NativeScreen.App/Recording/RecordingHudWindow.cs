using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using NativeScreen.Core;
using NativeScreen.Media;

namespace NativeScreen.App;

/// <summary>
/// The floating recording bar, with the three states of RecordingHUDBarView on macOS: idle, countdown and a compact bar while
/// recording. Choosing a mode opens the picker, which carries the Start button. Microphone and camera start off (spec/06 ADR-23).
/// </summary>
public sealed class RecordingHudWindow : Window
{
    private const double BarHeight = 64;
    private const double ButtonHeight = 44;
    private const double BottomMargin = 56;
    private const double CornerRadiusDip = 18;
    private const uint SwpNoMove = 0x0002;
    private const uint SwpNoSize = 0x0001;

    private static readonly nint HwndTopmost = -1;
    private static readonly Brush StopRed = Ui.Rgb(1, 0.27, 0.21);
    private static readonly Brush Coral = Ui.Rgb(0.96, 0.46, 0.43);
    private static readonly Brush Orange = Ui.Rgb(1, 0.6, 0.1);
    private static readonly Brush SelectedFill = Ui.Rgb(1, 1, 1, 0.14);

    private static RecordingHudWindow? shared;

    private readonly StackPanel bar = new() { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly Grid root = new();
    private readonly DispatcherTimer tick = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private readonly DispatcherTimer countdownTimer = new() { Interval = TimeSpan.FromMilliseconds(33) };
    private readonly TextBlock elapsed = new() { FontSize = 15, VerticalAlignment = VerticalAlignment.Center, MinWidth = 38 };
    private readonly ProgressRing countdownRing = new() { IsIndeterminate = false, Width = 22, Height = 22, Maximum = 1, Minimum = 0, Foreground = Coral };
    private readonly TextBlock countdownNumber = new() { FontSize = 11.5, FontWeight = Microsoft.UI.Text.FontWeights.Bold, Foreground = Coral, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private CaptureTargetMode? pickingMode;
    private TargetOverlay? overlay;
    private bool systemAudio = true;
    private CaptureDeviceInfo? microphone;
    private CaptureDeviceInfo? camera;
    private CaptureTarget? pending;
    private DateTime countdownStarted;
    private double countdownTotal;
    private bool busy;
    private bool isPaused;
    private ScreenRecorder? recorder;
    private CaptureTarget? target;
    private string? package;
    private DateTime startedAt;
    private TimeSpan pausedTotal;
    private DateTime? pausedAt;
    private (int X, int Y)? dragPointer;
    private Windows.Graphics.PointInt32 dragWindow;
    private (double DurationMs, bool HasWebcam, bool HasMicrophone, bool HasSystemAudio) lastDuration;
    private bool isShown;

    private RecordingHudWindow()
    {
        Title = "Native Screen Recording";
        root.RequestedTheme = ElementTheme.Dark;
        // The window itself is opaque, so its shape comes from a window region. This also removes the white frame of a borderless window.
        root.Background = Ui.Rgb(0.09, 0.09, 0.11);
        root.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(CornerRadiusDip),
            BorderThickness = new Thickness(1),
            BorderBrush = Ui.Rgb(1, 1, 1, 0.22),
            IsHitTestVisible = false
        });
        root.Children.Add(bar);
        root.PointerPressed += DragStarted;
        root.PointerMoved += DragMoved;
        root.PointerReleased += DragEnded;
        root.KeyDown += (_, args) =>
        {
            if (args.Key == Windows.System.VirtualKey.Escape)
            {
                EscapePressed();
            }
        };
        Content = root;
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.SetBorderAndTitleBar(false, false);
            presenter.IsAlwaysOnTop = true;
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
        }

        AppWindow.IsShownInSwitchers = false;
        tick.Tick += (_, _) => elapsed.Text = FormatElapsed(Elapsed());
        countdownTimer.Tick += (_, _) => CountdownTick();
        CaptureTargets.SetExcludedFromCapture(Handle, true);
        ShowIdle();
    }

    public static bool IsRecording => shared?.recorder is not null || shared?.pending is not null;

    private nint Handle => WinRT.Interop.WindowNative.GetWindowHandle(this);

    private double Scale => GetDpiForWindow(Handle) / 96.0;

    /// <summary>Opens the bar, optionally with the picker of a mode already showing.</summary>
    public static void Show(CaptureTargetMode? mode = null)
    {
        shared ??= new RecordingHudWindow();
        shared.Reveal();
        if (mode is { } picked && shared.recorder is null)
        {
            shared.SelectMode(picked);
        }
    }

    /// <summary>An editor opened, so the bar steps aside. A running recording keeps it.</summary>
    public static void HideIfIdle()
    {
        if (shared is { recorder: null, pending: null } hud)
        {
            hud.Conceal();
        }
    }

    public static void Shutdown()
    {
        shared?.overlay?.Dispose();
        shared?.recorder?.Dispose();
    }

    private void Reveal()
    {
        isShown = true;
        Activate();
        AppWindow.Show();
        FitToContent();
    }

    private void Conceal()
    {
        isShown = false;
        CancelPicking();
        AppWindow.Hide();
    }

    private static string FormatElapsed(TimeSpan time)
    {
        var total = (int)time.TotalSeconds;
        return $"{total / 60}:{total % 60:00}";
    }

    // MARK: Placement and dragging

    /// <summary>Sizes the window to the bar, keeps its spot, and reshapes it. The bar's width changes with its state, like on macOS.</summary>
    private void FitToContent()
    {
        bar.Measure(new Windows.Foundation.Size(double.PositiveInfinity, BarHeight));
        var scale = Scale;
        var width = (int)((bar.DesiredSize.Width + 32) * scale);
        var height = (int)(BarHeight * scale);
        var (x, y) = PlaceFor(width, height, scale);
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(x, y, width, height));
        var corner = (int)(CornerRadiusDip * 2 * scale);
        // One pixel in from the frame on every side: that outermost line is what showed as a white border.
        SetWindowRgn(Handle, CreateRoundRectRgn(1, 1, width, height, corner, corner), true);
    }

    private (int X, int Y) PlaceFor(int width, int height, double scale)
    {
        var settings = AppSettings.Shared;
        if (settings.HudX is { } savedX && settings.HudY is { } savedY)
        {
            // The center stays where it was left, so a wider or narrower state grows from the middle.
            var display = DisplayArea.GetFromPoint(new Windows.Graphics.PointInt32(savedX, savedY), DisplayAreaFallback.Nearest).WorkArea;
            return (
                Math.Clamp(savedX - width / 2, display.X, display.X + display.Width - width),
                Math.Clamp(savedY - height / 2, display.Y, display.Y + display.Height - height));
        }

        var area = DisplayArea.Primary.WorkArea;
        return (area.X + (area.Width - width) / 2, area.Y + area.Height - height - (int)(BottomMargin * scale));
    }

    private void DragStarted(object sender, PointerRoutedEventArgs args)
    {
        GetCursorPos(out var cursor);
        dragPointer = (cursor.X, cursor.Y);
        dragWindow = AppWindow.Position;
        root.CapturePointer(args.Pointer);
    }

    private void DragMoved(object sender, PointerRoutedEventArgs args)
    {
        if (dragPointer is { } start)
        {
            GetCursorPos(out var cursor);
            AppWindow.Move(new Windows.Graphics.PointInt32(dragWindow.X + cursor.X - start.X, dragWindow.Y + cursor.Y - start.Y));
        }
    }

    private void DragEnded(object sender, PointerRoutedEventArgs args)
    {
        if (dragPointer is null)
        {
            return;
        }

        dragPointer = null;
        root.ReleasePointerCaptures();
        var position = AppWindow.Position;
        var size = AppWindow.Size;
        AppSettings.Shared.HudX = position.X + size.Width / 2;
        AppSettings.Shared.HudY = position.Y + size.Height / 2;
        AppSettings.Shared.Save();
    }

    // MARK: Building blocks

    private static Border Separator() =>
        new() { Width = 1, Height = 28, Background = Ui.Rgb(1, 1, 1, 0.18), Margin = new Thickness(2, 0, 2, 0) };

    private static Button Item(UIElement content, string? tooltip, Action click, double? width = null, double height = ButtonHeight, bool selected = false)
    {
        var button = new Button
        {
            Style = Ui.StyleOf("NsIconButton"),
            Content = content,
            Height = height,
            Width = width ?? double.NaN,
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(0),
            Background = selected ? SelectedFill : Ui.Rgb(1, 1, 1, 0)
        };
        if (tooltip is not null)
        {
            ToolTipService.SetToolTip(button, tooltip);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, tooltip);
        }

        button.Click += (_, _) => click();
        return button;
    }

    private static TextBlock Label(string text, double size, double opacity, bool medium = false) => new()
    {
        Text = text,
        FontSize = size,
        Foreground = Ui.Rgb(1, 1, 1, opacity),
        FontWeight = medium ? Microsoft.UI.Text.FontWeights.Medium : Microsoft.UI.Text.FontWeights.Normal,
        VerticalAlignment = VerticalAlignment.Center,
        TextTrimming = TextTrimming.CharacterEllipsis,
        MaxLines = 1
    };

    private static StackPanel IconAndText(string glyph, string text, double maxWidth, bool active)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Padding = new Thickness(12, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(Ui.Icon(glyph, 14.5, Ui.Rgb(1, 1, 1, active ? 0.96 : 0.65)));
        var label = Label(text, 13, active ? 0.96 : 0.65, active);
        label.MaxWidth = maxWidth;
        row.Children.Add(label);
        return row;
    }

    private static MenuFlyoutItem MenuItem(string title, Action click)
    {
        var item = new MenuFlyoutItem { Text = title };
        item.Click += (_, _) => click();
        return item;
    }

    // MARK: Idle bar

    private void ShowIdle()
    {
        tick.Stop();
        countdownTimer.Stop();
        bar.Spacing = 8;
        bar.Children.Clear();
        bar.Children.Add(Item(Ui.Icon("", 20, Ui.Rgb(1, 1, 1, 0.94)), "Close", Conceal, 42));
        bar.Children.Add(Separator());
        var modes = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        modes.Children.Add(ModeButton("", "Display", CaptureTargetMode.Display));
        modes.Children.Add(ModeButton("", "Window", CaptureTargetMode.Window));
        modes.Children.Add(ModeButton("", "Area", CaptureTargetMode.Area));
        bar.Children.Add(modes);
        bar.Children.Add(Separator());
        var devices = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        devices.Children.Add(DeviceButton("", "", camera, "No camera", 72, 96, WebcamRecorder.Cameras, device => camera = device));
        devices.Children.Add(DeviceButton("", "", microphone, "No microphone", 96, 112, AudioTrackRecorder.Microphones, device => microphone = device));
        devices.Children.Add(SystemAudioButton());
        bar.Children.Add(devices);
        bar.Children.Add(Separator());
        var tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        tools.Children.Add(ProjectsButton());
        tools.Children.Add(OptionsButton());
        bar.Children.Add(tools);
        if (isShown)
        {
            FitToContent();
        }
    }

    private Button ModeButton(string glyph, string title, CaptureTargetMode mode)
    {
        var selected = pickingMode == mode;
        var stack = new StackPanel { Spacing = 4, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var icon = Ui.Icon(glyph, 16.5, Ui.Rgb(1, 1, 1, selected ? 1 : 0.92));
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(icon);
        var label = Label(title, 11, selected ? 0.98 : 0.72);
        label.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(label);
        var button = Item(stack, null, () => SelectMode(mode), 58, ButtonHeight, selected);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, title);
        return button;
    }

    private void SelectMode(CaptureTargetMode mode)
    {
        if (pickingMode == mode)
        {
            CancelPicking();
            ShowIdle();
            return;
        }

        CancelPicking();
        pickingMode = mode;
        var position = AppWindow.Position;
        var size = AppWindow.Size;
        var display = CaptureTargets.DisplayAt(position.X + size.Width / 2, position.Y + size.Height / 2);
        overlay = new TargetOverlay(mode, display, chosen =>
        {
            overlay = null;
            pickingMode = null;
            BeginCountdown(chosen);
        }, () =>
        {
            overlay = null;
            pickingMode = null;
            ShowIdle();
        });
        ShowIdle();
        // The bar sits above the picker and stays usable, like the HUD panel over the overlay on macOS.
        SetWindowPos(Handle, HwndTopmost, 0, 0, 0, 0, SwpNoMove | SwpNoSize);
    }

    private void CancelPicking()
    {
        overlay?.Cancel();
        overlay = null;
        pickingMode = null;
    }

    private void EscapePressed()
    {
        if (pending is not null)
        {
            CancelCountdown();
        }
        else if (pickingMode is not null)
        {
            CancelPicking();
            ShowIdle();
        }
        else if (recorder is null)
        {
            Conceal();
        }
    }

    private Button DeviceButton(string glyph, string offGlyph, CaptureDeviceInfo? selected, string offTitle, double onWidth, double offWidth, Func<IReadOnlyList<CaptureDeviceInfo>> list, Action<CaptureDeviceInfo?> choose)
    {
        var active = selected is not null;
        var button = Item(IconAndText(active ? glyph : offGlyph, selected?.Name ?? offTitle, active ? onWidth : offWidth, active), null, () => { });
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, offTitle);
        button.Click += (_, _) =>
        {
            var menu = new MenuFlyout { ShouldConstrainToRootBounds = false };
            var none = new ToggleMenuFlyoutItem { Text = offTitle, IsChecked = selected is null };
            none.Click += (_, _) =>
            {
                choose(null);
                ShowIdle();
            };
            menu.Items.Add(none);
            foreach (var device in list())
            {
                var captured = device;
                var item = new ToggleMenuFlyoutItem { Text = device.Name, IsChecked = device.Id == selected?.Id };
                item.Click += (_, _) =>
                {
                    choose(captured);
                    ShowIdle();
                };
                menu.Items.Add(item);
            }

            menu.ShowAt(button);
        };
        return button;
    }

    private Button SystemAudioButton()
    {
        var button = Item(IconAndText("", systemAudio ? "System audio" : "No system audio", 120, systemAudio), null, () => { });
        button.Click += (_, _) =>
        {
            var menu = new MenuFlyout { ShouldConstrainToRootBounds = false };
            foreach (var (title, value) in new[] { ("System audio", true), ("No system audio", false) })
            {
                var chosen = value;
                var item = new ToggleMenuFlyoutItem { Text = title, IsChecked = systemAudio == value };
                item.Click += (_, _) =>
                {
                    systemAudio = chosen;
                    ShowIdle();
                };
                menu.Items.Add(item);
            }

            menu.ShowAt(button);
        };
        return button;
    }

    private Button ProjectsButton()
    {
        var button = Item(Ui.Icon("", 15.5, Ui.Rgb(1, 1, 1, 0.88)), "Projects", () => { }, 44);
        button.Click += (_, _) =>
        {
            var menu = new MenuFlyout { ShouldConstrainToRootBounds = false };
            menu.Items.Add(MenuItem("Open .nativescreen Project", () => _ = Projects.PromptOpen(this, root.XamlRoot)));
            menu.Items.Add(MenuItem("Create Project from Video", () => _ = Projects.PromptImport(this, root.XamlRoot)));
            menu.Items.Add(MenuItem("Create Interactive Showcase Project", () => _ = Projects.Open(ShowcaseProject.WritePackage(AppSettings.Shared.ProjectsDirectory), root.XamlRoot)));
            if (AppSettings.Shared.RecentProjects.Count > 0)
            {
                menu.Items.Add(new MenuFlyoutSeparator());
                foreach (var path in AppSettings.Shared.RecentProjects.Take(8))
                {
                    var recent = path;
                    menu.Items.Add(MenuItem(Path.GetFileNameWithoutExtension(path), () => _ = Projects.Open(recent, root.XamlRoot)));
                }
            }

            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(MenuItem("Show Projects Folder in File Explorer", () => Projects.ShowFolder(AppSettings.Shared.ProjectsDirectory)));
            menu.Items.Add(MenuItem("Settings", () => new SettingsWindow().Activate()));
            menu.Items.Add(MenuItem("Quit Native Screen", App.Quit));
            menu.ShowAt(button);
        };
        return button;
    }

    private Button OptionsButton()
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, HorizontalAlignment = HorizontalAlignment.Center };
        content.Children.Add(Ui.Icon("", 15.5, Ui.Rgb(1, 1, 1, 0.88)));
        content.Children.Add(Ui.Icon("", 10, Ui.Rgb(1, 1, 1, 0.88)));
        var button = Item(content, "Recording options", () => { }, 56);
        button.Click += (_, _) =>
        {
            var menu = new MenuFlyout { ShouldConstrainToRootBounds = false };
            var settings = AppSettings.Shared;
            var header = new MenuFlyoutSubItem { Text = "Countdown" };
            foreach (var (title, seconds) in new[] { ("Off", 0), ("3s", 3), ("5s", 5), ("10s", 10) })
            {
                var value = seconds;
                var item = new ToggleMenuFlyoutItem { Text = title, IsChecked = settings.CountdownSeconds == value };
                item.Click += (_, _) =>
                {
                    settings.CountdownSeconds = value;
                    settings.Save();
                };
                header.Items.Add(item);
            }

            menu.Items.Add(header);
            var zooms = new ToggleMenuFlyoutItem { Text = "Automatically create zooms", IsChecked = settings.AutoCreateZooms };
            zooms.Click += (_, _) =>
            {
                settings.AutoCreateZooms = zooms.IsChecked;
                settings.Save();
            };
            menu.Items.Add(zooms);
            var highlight = new ToggleMenuFlyoutItem { Text = "Highlight recorded area", IsChecked = settings.HighlightRecordedArea };
            highlight.Click += (_, _) =>
            {
                settings.HighlightRecordedArea = highlight.IsChecked;
                settings.Save();
            };
            menu.Items.Add(highlight);
            var after = new MenuFlyoutSubItem { Text = "After recording" };
            foreach (var (title, action) in new[] { ("Create project", "project"), ("Export to clipboard", "clipboard"), ("Export to file", "file") })
            {
                var value = action;
                var item = new ToggleMenuFlyoutItem { Text = title, IsChecked = settings.AfterRecording == value };
                item.Click += (_, _) =>
                {
                    settings.AfterRecording = value;
                    settings.Save();
                };
                after.Items.Add(item);
            }

            menu.Items.Add(after);
            menu.ShowAt(button);
        };
        return button;
    }

    // MARK: Countdown

    private void BeginCountdown(CaptureTarget chosen)
    {
        pending = chosen;
        countdownTotal = AppSettings.Shared.CountdownSeconds;
        if (countdownTotal <= 0)
        {
            _ = StartRecording();
            return;
        }

        countdownStarted = DateTime.UtcNow;
        bar.Children.Clear();
        bar.Spacing = 14;
        bar.Children.Add(Item(Ui.Icon("", 20, Ui.Rgb(1, 1, 1, 0.92)), "Cancel countdown (Esc)", CancelCountdown, 36, 36));
        bar.Children.Add(Separator());
        bar.Children.Add(Label("Get ready. Recording will start soon.", 14, 0.62, true));
        bar.Children.Add(Separator());
        var ring = new Grid { Width = 22, Height = 22 };
        ring.Children.Add(countdownRing);
        ring.Children.Add(countdownNumber);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 9, Padding = new Thickness(10, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
        var label = Label("Continue", 14, 1, true);
        label.Foreground = Coral;
        row.Children.Add(label);
        row.Children.Add(ring);
        var skip = Item(row, null, () =>
        {
            countdownTimer.Stop();
            _ = StartRecording();
        }, null, 42);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(skip, "Continue");
        bar.Children.Add(skip);
        FitToContent();
        CountdownTick();
        countdownTimer.Start();
    }

    private void CountdownTick()
    {
        var remaining = Math.Max(0, countdownTotal - (DateTime.UtcNow - countdownStarted).TotalSeconds);
        countdownRing.Value = remaining / Math.Max(1, countdownTotal);
        countdownNumber.Text = Math.Max(1, (int)Math.Ceiling(remaining)).ToString(System.Globalization.CultureInfo.InvariantCulture);
        if (remaining <= 0.01 && countdownTimer.IsEnabled)
        {
            countdownTimer.Stop();
            _ = StartRecording();
        }
    }

    private void CancelCountdown()
    {
        countdownTimer.Stop();
        pending = null;
        ShowIdle();
    }

    // MARK: Recording

    private async Task StartRecording()
    {
        if (pending is not { } chosen || busy)
        {
            return;
        }

        busy = true;
        AppExclusion(true);
        try
        {
            var directory = RecordingPackage.Create(AppSettings.Shared.ProjectsDirectory, DateTime.Now);
            var options = new RecordingOptions(chosen, directory, systemAudio, microphone?.Id, camera?.Id);
            var (created, started) = await Task.Run(() =>
            {
                var next = new ScreenRecorder(options);
                return (next, next.WaitForFirstFrame());
            });
            pending = null;
            target = chosen;
            package = directory;
            recorder = created;
            busy = false;
            if (!started)
            {
                await AbortRecording();
                return;
            }

            startedAt = DateTime.UtcNow;
            pausedTotal = TimeSpan.Zero;
            pausedAt = null;
            isPaused = false;
            if (AppSettings.Shared.HighlightRecordedArea)
            {
                recordedArea = new RecordedAreaHighlight(chosen.Rect, chosen.Display.Scale);
            }

            ShowRecording();
        }
        catch (Exception exception) when (exception is SharpGen.Runtime.SharpGenException or COMException or IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            busy = false;
            pending = null;
            AppExclusion(false);
            ShowIdle();
            await new ContentDialog { XamlRoot = root.XamlRoot, RequestedTheme = ElementTheme.Dark, Title = "Could not start recording", Content = exception.Message, CloseButtonText = "OK" }.ShowAsync();
        }
    }

    private TimeSpan Elapsed()
    {
        var paused = pausedTotal + (pausedAt is { } at ? DateTime.UtcNow - at : TimeSpan.Zero);
        return DateTime.UtcNow - startedAt - paused;
    }

    private void ShowRecording()
    {
        bar.Children.Clear();
        bar.Spacing = 10;
        var stopIcon = new Grid { Width = 20, Height = 20 };
        stopIcon.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse { Stroke = StopRed, StrokeThickness = 2.2 });
        stopIcon.Children.Add(new Border { Width = 8, Height = 8, CornerRadius = new CornerRadius(2.2), Background = StopRed, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
        elapsed.Text = FormatElapsed(Elapsed());
        elapsed.Foreground = isPaused ? Orange : StopRed;
        var stopRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 9, Padding = new Thickness(10, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
        stopRow.Children.Add(stopIcon);
        stopRow.Children.Add(elapsed);
        bar.Children.Add(Item(stopRow, "Finish recording", () => _ = StopAndOpen(), null, 42));
        bar.Children.Add(new Border { Width = 1, Height = 26, Background = Ui.Rgb(1, 1, 1, 0.20) });
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        actions.Children.Add(Item(Ui.Icon(isPaused ? "" : "", 17, Ui.Rgb(1, 1, 1, 0.9)), isPaused ? "Resume recording" : "Pause recording", TogglePause, 38, 38, isPaused));
        actions.Children.Add(Item(Ui.Icon("", 16.5, Ui.Rgb(1, 1, 1, 0.9)), "Restart recording", () => _ = Restart(), 38, 38));
        actions.Children.Add(Item(Ui.Icon("", 16, Ui.Rgb(1, 1, 1, 0.9)), "Cancel & delete recording", () => _ = ConfirmDelete(), 38, 38));
        bar.Children.Add(actions);
        FitToContent();
        tick.Start();
    }

    private void TogglePause()
    {
        if (recorder is null)
        {
            return;
        }

        isPaused = !isPaused;
        recorder.SetPaused(isPaused);
        if (isPaused)
        {
            pausedAt = DateTime.UtcNow;
        }
        else if (pausedAt is { } at)
        {
            pausedTotal += DateTime.UtcNow - at;
            pausedAt = null;
        }

        ShowRecording();
    }

    private RecordedAreaHighlight? recordedArea;

    private async Task StopRecorder()
    {
        tick.Stop();
        recordedArea?.Dispose();
        recordedArea = null;
        var running = recorder;
        recorder = null;
        if (running is not null)
        {
            lastDuration = await Task.Run(() =>
            {
                running.Stop();
                var result = (running.DurationMs, running.HasWebcam, running.HasMicrophone, running.HasSystemAudio);
                running.Dispose();
                return result;
            });
        }
    }

    private async Task StopAndOpen()
    {
        if (busy || package is null || target is null)
        {
            return;
        }

        busy = true;
        await StopRecorder();
        AppExclusion(false);
        var (directory, chosen, stats) = (package, target, lastDuration);
        package = null;
        target = null;
        await Task.Run(() => RecordingPackage.Finish(directory, chosen.Metadata(), stats.DurationMs, stats.HasWebcam, stats.HasMicrophone, stats.HasSystemAudio, autoCreateZooms: AppSettings.Shared.AutoCreateZooms, DateTimeOffset.UtcNow));
        busy = false;
        ShowIdle();
        await Projects.Open(directory, root.XamlRoot, AppSettings.Shared.AfterRecording);
    }

    private async Task Restart()
    {
        if (busy || target is not { } same)
        {
            return;
        }

        busy = true;
        await DiscardCurrent();
        busy = false;
        pending = same;
        await StartRecording();
    }

    private async Task ConfirmDelete()
    {
        var answer = await new ContentDialog
        {
            XamlRoot = root.XamlRoot,
            RequestedTheme = ElementTheme.Dark,
            Title = "Delete this recording?",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Keep recording"
        }.ShowAsync();
        if (answer == ContentDialogResult.Primary)
        {
            await AbortRecording();
        }
    }

    private async Task AbortRecording()
    {
        await DiscardCurrent();
        AppExclusion(false);
        ShowIdle();
    }

    private async Task DiscardCurrent()
    {
        await StopRecorder();
        var directory = package;
        package = null;
        target = null;
        if (directory is not null)
        {
            await Task.Run(() =>
            {
                if (Directory.Exists(directory))
                {
                    Directory.Delete(directory, recursive: true);
                }
            });
        }
    }

    /// <summary>The app's own windows never appear in its recordings.</summary>
    private static void AppExclusion(bool excluded)
    {
        foreach (var window in AppTheme.OpenWindows())
        {
            CaptureTargets.SetExcludedFromCapture(WinRT.Interop.WindowNative.GetWindowHandle(window), excluded);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point32
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint hwnd);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out Point32 point);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);

    [DllImport("user32.dll")]
    private static extern int SetWindowRgn(nint window, nint region, bool redraw);

    [DllImport("gdi32.dll")]
    private static extern nint CreateRoundRectRgn(int left, int top, int right, int bottom, int cornerWidth, int cornerHeight);
}
