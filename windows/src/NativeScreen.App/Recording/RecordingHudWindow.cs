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
public sealed partial class RecordingHudWindow : Window
{
    private const double BarHeight = 64;
    private const double ButtonHeight = 44;
    private const double BottomMargin = 56;
    private const int MaximumAudioAppRows = 12;
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
    private readonly DispatcherTimer meterTimer = new() { Interval = TimeSpan.FromMilliseconds(33) };
    private TextBlock elapsed = NewClock();
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
    private IRecordingEngine? recorder;
    private CameraStageWindow? stage;
    private (int Width, int Height, double FrameMs)? cameraFormat;
    private CaptureTarget? target;
    private string? package;
    private DateTime startedAt;
    private TimeSpan pausedTotal;
    private DateTime? pausedAt;
    private (int X, int Y)? dragPointer;
    private Windows.Graphics.PointInt32 dragWindow;
    private (double DurationMs, bool HasWebcam, bool HasMicrophone, bool HasSystemAudio) lastDuration;
    private bool lastRecordingFailed;
    private bool isShown;
    private bool systemAudioAllApps = true;
    private readonly HashSet<string> systemAudioApps = new(StringComparer.OrdinalIgnoreCase);
    private bool showCameraPreview = true;
    private int cameraMaxHeight = 1080;
    private bool capturing;
    private Flyout? openMenu;
    private LevelBar? barMeter;
    private LevelBar? menuMeter;
    private string? menuMeterDevice;
    private string? monitoredMicrophone;
    private string? previewedCamera;
    private MicrophoneLevelMonitor? monitor;
    private CameraPreviewSource? cameraPreview;
    private CameraPreviewWindow? previewWindow;
    private Task deviceWork = Task.CompletedTask;

    private RecordingHudWindow()
    {
        Title = Loc.T("Native Screen Recording");
        root.RequestedTheme = ElementTheme.Dark;
        root.Background = Ui.Rgb(0.09, 0.09, 0.11);
        root.Children.Add(new Border
        {
            BorderThickness = new Thickness(1),
            BorderBrush = Ui.Rgb(1, 1, 1, 0.22),
            IsHitTestVisible = false
        });
        root.Children.Add(bar);
        // A label that changes in place (a longer microphone name) changes the bar without a rebuild: follow its own size.
        bar.SizeChanged += (_, _) =>
        {
            if (isShown)
            {
                FitToContent();
            }
        };
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

        RemoveWindowFrame(Handle);
        AppWindow.IsShownInSwitchers = false;
        tick.Tick += (_, _) => elapsed.Text = FormatElapsed(Elapsed());
        countdownTimer.Tick += (_, _) => CountdownTick();
        meterTimer.Tick += (_, _) => MeterTick();
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

    /// <summary>Record > Record this project window: starts on an editor window without going through the picker.</summary>
    public static void RecordWindow(nint window)
    {
        shared ??= new RecordingHudWindow();
        if (shared.recorder is not null || shared.pending is not null || shared.busy || CaptureTargets.WindowInfo(window) is not { } info)
        {
            return;
        }

        shared.Reveal();
        shared.CancelPicking();
        shared.BeginCountdown(new CaptureTarget(CaptureTargetMode.Window, CaptureTargets.DisplayOf(info.Bounds), info, info.Bounds));
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
        shared?.monitor?.Dispose();
        shared?.cameraPreview?.Dispose();
    }

    private void Reveal()
    {
        isShown = true;
        Activate();
        AppWindow.Show();
        FitToContent();
        UpdateDevices();
        if (AppSettings.Shared.ShowSpeakerNotes && notes is null)
        {
            SetSpeakerNotes(true);
        }
    }

    private void Conceal()
    {
        isShown = false;
        CancelPicking();
        if (recorder is null && pending is null)
        {
            CloseCameraStage();
        }

        AppWindow.Hide();
        UpdateDevices();
    }

    private static string FormatElapsed(TimeSpan time)
    {
        var total = (int)time.TotalSeconds;
        return $"{total / 60}:{total % 60:00}";
    }

    // MARK: Placement and dragging

    /// <summary>Sizes the window to the bar and keeps its spot. The bar's width changes with its state, like on macOS.</summary>
    private void FitToContent()
    {
        bar.Measure(new Windows.Foundation.Size(double.PositiveInfinity, BarHeight));
        var scale = Scale;
        var width = (int)((bar.DesiredSize.Width + 32) * scale);
        var height = (int)(BarHeight * scale);
        if (AppWindow.Size.Width == width && AppWindow.Size.Height == height && AppWindow.IsVisible)
        {
            return;
        }

        var (x, y) = PlaceFor(width, height, scale);
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(x, y, width, height));
    }

    /// <summary>A window without a title bar still gets a white frame around its content, 3 pixels at 200%. Only the style removes it.</summary>
    internal static void RemoveWindowFrame(nint window)
    {
        var style = GetWindowLongPtr(window, StyleIndex) & ~(CaptionStyle | ThickFrameStyle) | PopupStyle;
        SetWindowLongPtr(window, StyleIndex, style);
        SetWindowPos(window, 0, 0, 0, 0, 0, FrameChangedFlags);
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
            Ui.Tip(button, tooltip);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, tooltip);
        }

        button.Click += (_, _) => click();
        return button;
    }

    private static TextBlock Label(string text, double size, double opacity, bool medium = false) => new()
    {
        Text = Loc.T(text),
        FontSize = size,
        Foreground = Ui.Rgb(1, 1, 1, opacity),
        FontWeight = medium ? Microsoft.UI.Text.FontWeights.Medium : Microsoft.UI.Text.FontWeights.Normal,
        VerticalAlignment = VerticalAlignment.Center,
        TextTrimming = TextTrimming.CharacterEllipsis,
        MaxLines = 1
    };

    private static StackPanel IconAndText(string glyph, string text, double maxWidth, bool active)
    {
        text = Loc.T(text);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Padding = new Thickness(12, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(Ui.Icon(glyph, 14.5, Ui.Rgb(1, 1, 1, active ? 0.96 : 0.65)));
        var label = Label(text, 13, active ? 0.96 : 0.65, active);
        label.MaxWidth = maxWidth;
        row.Children.Add(label);
        return row;
    }

    private static MenuFlyoutItem MenuItem(string title, Action click)
    {
        title = Loc.T(title);
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
        modes.Children.Add(ModeButton("", "Camera", CaptureTargetMode.Camera));
        bar.Children.Add(modes);
        bar.Children.Add(Separator());
        var devices = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        devices.Children.Add(CameraButton());
        devices.Children.Add(MicrophoneButton());
        // System audio comes with the screen stream, which the Camera mode does not start.
        if (stage is null)
        {
            devices.Children.Add(SystemAudioButton());
        }

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
        title = Loc.T(title);
        var selected = pickingMode == mode || mode == CaptureTargetMode.Camera && stage is not null;
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
        if (mode == CaptureTargetMode.Camera)
        {
            ToggleCameraStage();
            return;
        }

        CloseCameraStage();
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

    /// <summary>
    /// The Camera mode: the large preview with its record button, kept up through the countdown and the recording. A second
    /// click on the mode, Esc or hiding the bar closes it (spec/06 ADR-77).
    /// </summary>
    private void ToggleCameraStage()
    {
        if (stage is not null)
        {
            CloseCameraStage();
            ShowIdle();
            UpdateDevices();
            return;
        }

        CancelPicking();
        camera ??= WebcamRecorder.Cameras().FirstOrDefault();
        if (camera is not { } chosen)
        {
            var title = Loc.T("Camera");
            var message = Loc.T("A camera recording needs a camera.");
            _ = Task.Run(() => MessageBoxW(0, message, title, MessageBoxWarningTopmost));
            return;
        }

        stage = new CameraStageWindow(chosen.Name, microphone is not null, () => BeginCountdown(CameraTarget()));
        stage.AppWindow.Show(false);
        DockNotes();
        ShowIdle();
        UpdateDevices();
    }

    private void CloseCameraStage()
    {
        if (stage is null)
        {
            return;
        }

        stage.Close();
        stage = null;
        DockNotes();
    }

    /// <summary>A camera-only recording has no screen target; the display only places the bar.</summary>
    private static CaptureTarget CameraTarget()
    {
        var display = CaptureTargets.Displays().FirstOrDefault(item => item.IsPrimary) ?? CaptureTargets.Displays()[0];
        return new CaptureTarget(CaptureTargetMode.Camera, display, null, new NativeScreen.Media.PixelRect(0, 0, 16, 16));
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
        else if (stage is not null && recorder is null)
        {
            CloseCameraStage();
            ShowIdle();
            UpdateDevices();
        }
        else if (recorder is null)
        {
            Conceal();
        }
    }

    /// <summary>Opens a device menu. The bar is rebuilt only when it closes, because a rebuild would take the menu's anchor away.</summary>
    private void OpenMenu(Button anchor, StackPanel content, Action? closed = null)
    {
        anchor.Background = SelectedFill;
        content.RequestedTheme = ElementTheme.Dark;
        content.Padding = new Thickness(4, 6, 4, 6);
        content.Spacing = 2;
        var presenter = new Style(typeof(FlyoutPresenter));
        presenter.Setters.Add(new Setter(Control.BackgroundProperty, Ui.Rgb(0.13, 0.13, 0.15)));
        presenter.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(0)));
        presenter.Setters.Add(new Setter(FrameworkElement.MaxWidthProperty, 460.0));
        var flyout = new Flyout { Content = content, Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.Top, ShouldConstrainToRootBounds = false, FlyoutPresenterStyle = presenter };
        openMenu = flyout;
        flyout.Closed += (_, _) =>
        {
            openMenu = null;
            closed?.Invoke();
            ShowIdle();
            UpdateDevices();
        };
        flyout.ShowAt(anchor);
    }

    /// <summary>A row with a check mark column, like the menus on macOS.</summary>
    private Button MenuRow(bool selected, double height, UIElement content, Action click)
    {
        var row = new Grid { ColumnSpacing = 8, Padding = new Thickness(8, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        if (selected)
        {
            row.Children.Add(Ui.Icon("\uE73E", 11, Ui.Rgb(1, 1, 1, 0.96)));
        }

        Grid.SetColumn((FrameworkElement)content, 1);
        row.Children.Add(content);
        var button = new Button
        {
            Style = Ui.StyleOf("NsIconButton"),
            Content = row,
            Width = double.NaN,
            Height = height,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(7),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = Ui.Rgb(1, 1, 1, 0)
        };
        button.Click += (_, _) =>
        {
            click();
            openMenu?.Hide();
        };
        return button;
    }

    private static Grid DeviceTitle(CaptureDeviceInfo device)
    {
        var title = new Grid { ColumnSpacing = 14 };
        title.ColumnDefinitions.Add(new ColumnDefinition());
        title.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        title.Children.Add(Label(device.Name, 13.5, 0.96));
        if (device.IsDefault)
        {
            var badge = new Border { Background = Ui.Rgb(1, 1, 1, 0.16), CornerRadius = new CornerRadius(9), Padding = new Thickness(8, 2, 8, 3), Child = Label("Default", 11, 0.88, true) };
            Grid.SetColumn(badge, 1);
            title.Children.Add(badge);
        }

        return title;
    }

    private static (Grid Row, ToggleSwitch Toggle) SwitchRow(string title, bool isOn, Action<bool> changed, UIElement? icon = null)
    {
        title = Loc.T(title);
        var toggle = new ToggleSwitch { IsOn = isOn, OnContent = "", OffContent = "", MinWidth = 0, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 0, -12, 0) };
        toggle.Toggled += (_, _) => changed(toggle.IsOn);
        var row = new Grid { ColumnSpacing = 10, MinHeight = 32, Padding = new Thickness(14, 0, 8, 0) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 150 });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (icon is not null)
        {
            row.Children.Add(icon);
        }

        var label = Label(title, 13.5, 0.96);
        Grid.SetColumn(label, 1);
        row.Children.Add(label);
        Grid.SetColumn(toggle, 2);
        row.Children.Add(toggle);
        return (row, toggle);
    }

    private static async Task<IReadOnlyList<CaptureDeviceInfo>> ListDevices(Func<IReadOnlyList<CaptureDeviceInfo>> list)
    {
        try
        {
            return await Task.Run(list);
        }
        catch (Exception exception) when (exception is COMException or SharpGen.Runtime.SharpGenException)
        {
            return [];
        }
    }

    private Button CameraButton()
    {
        var active = camera is not null;
        var button = Item(IconAndText(active ? "\uE714" : "\uF781", camera?.Name ?? "No camera", active ? 72 : 96, active), null, () => { });
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, "Camera");
        button.Click += async (_, _) =>
        {
            var cameras = await ListDevices(WebcamRecorder.Cameras);
            if (camera is { } chosen && !cameras.Any(item => item.Id == chosen.Id))
            {
                camera = null;
            }

            var menu = new StackPanel();
            foreach (var device in cameras)
            {
                var captured = device;
                menu.Children.Add(MenuRow(device.Id == camera?.Id, 30, DeviceTitle(device), () => camera = captured));
            }

            menu.Children.Add(MenuRow(camera is null, 30, Label("Don't record camera", 13.5, 0.96), () => camera = null));
            menu.Children.Add(new Border { Height = 1, Background = Ui.Rgb(1, 1, 1, 0.12), Margin = new Thickness(10, 5, 10, 5) });
            menu.Children.Add(SwitchRow("Show camera preview", showCameraPreview, value =>
            {
                showCameraPreview = value;
                UpdateDevices();
            }).Row);
            menu.Children.Add(ResolutionRow());
            OpenMenu(button, menu);
        };
        return button;
    }

    private StackPanel ResolutionRow()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16, Height = 36, Padding = new Thickness(14, 0, 8, 0) };
        var label = Label("Max resolution", 13.5, 0.96);
        label.MinWidth = 120;
        row.Children.Add(label);
        var pills = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 0, VerticalAlignment = VerticalAlignment.Center, Background = Ui.Rgb(1, 1, 1, 0.11), CornerRadius = new CornerRadius(7.5), Padding = new Thickness(2) };
        var buttons = new List<(Button Button, int Height)>();
        void Refresh()
        {
            foreach (var (pill, height) in buttons)
            {
                pill.Background = height == cameraMaxHeight ? Ui.Rgb(0.04, 0.52, 1) : Ui.Rgb(1, 1, 1, 0);
            }
        }

        foreach (var (title, height) in new[] { ("720p", 720), ("1080p", 1080), ("4K", 2160) })
        {
            var value = height;
            var pill = new Button { Style = Ui.StyleOf("NsIconButton"), Content = Label(title, 12.5, 1), Width = 52, Height = 24, Padding = new Thickness(0), CornerRadius = new CornerRadius(6) };
            pill.Click += (_, _) =>
            {
                cameraMaxHeight = value;
                Refresh();
            };
            buttons.Add((pill, height));
            pills.Children.Add(pill);
        }

        Refresh();
        row.Children.Add(pills);
        return row;
    }

    private Button MicrophoneButton()
    {
        var active = microphone is not null;
        var content = new Grid { Height = ButtonHeight };
        content.Children.Add(IconAndText(active ? "\uE720" : "\uEC54", microphone?.Name ?? "No microphone", active ? 96 : 112, active));
        barMeter = null;
        if (active)
        {
            barMeter = new LevelBar(3, Ui.Rgb(1, 1, 1, 0.14), Ui.Rgb(1, 1, 1, 0.30), Ui.Rgb(1, 1, 1, 0.68)) { VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(8, 0, 8, 3) };
            content.Children.Add(barMeter);
        }

        var button = Item(content, null, () => { });
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, "Microphone");
        button.Click += async (_, _) =>
        {
            var microphones = await ListDevices(AudioTrackRecorder.Microphones);
            if (microphone is { } chosen && !microphones.Any(item => item.Id == chosen.Id))
            {
                microphone = null;
            }

            // The meter reads one device at a time: the chosen one, or the default while none is chosen.
            menuMeterDevice = microphone?.Id ?? microphones.FirstOrDefault(item => item.IsDefault)?.Id ?? microphones.FirstOrDefault()?.Id;
            menuMeter = null;
            var menu = new StackPanel { Spacing = 4 };
            foreach (var device in microphones)
            {
                var captured = device;
                var lines = new StackPanel { Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
                lines.Children.Add(DeviceTitle(device));
                var blue = Ui.Rgb(0.04, 0.52, 1);
                var meter = new LevelBar(3.5, Ui.Rgb(1, 1, 1, 0.15), Ui.Rgb(0.04, 0.52, 1, 0.42), blue);
                lines.Children.Add(meter);
                if (device.Id == menuMeterDevice)
                {
                    menuMeter = meter;
                }

                menu.Children.Add(MenuRow(device.Id == microphone?.Id, 44, lines, () => microphone = captured));
            }

            menu.Children.Add(MenuRow(microphone is null, 30, Label("Don't record microphone", 13.5, 0.96), () => microphone = null));
            OpenMenu(button, menu, () =>
            {
                menuMeter = null;
                menuMeterDevice = null;
            });
            UpdateDevices();
        };
        return button;
    }

    private Button SystemAudioButton()
    {
        var button = Item(IconAndText("\uE767", SystemAudioTitle, 120, IsSystemAudioActive), null, () => { });
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, "System audio");
        button.Click += async (_, _) =>
        {
            var apps = AudioApps.IsPerAppSupported ? await Task.Run(AudioApps.List) : [];
            OpenMenu(button, SystemAudioMenu(apps));
        };
        return button;
    }

    private bool IsSystemAudioActive => systemAudio && (systemAudioAllApps || systemAudioApps.Count > 0);

    private string SystemAudioTitle => !IsSystemAudioActive
        ? "No system audio"
        : systemAudioAllApps
            ? "System audio"
            : systemAudioApps.Count == 1 ? "Sound from 1 app" : $"Sound from {systemAudioApps.Count} apps";

    /// <summary>Windows without process loopback gets the first switch only, since an app could not be recorded on its own there.</summary>
    private StackPanel SystemAudioMenu(IReadOnlyList<AudioAppInfo> apps)
    {
        var menu = new StackPanel { MinWidth = 284 };
        var appSwitches = new List<(ToggleSwitch Toggle, string Id)>();
        ToggleSwitch? recordSwitch = null;
        ToggleSwitch? allSwitch = null;
        var refreshing = false;
        void Refresh()
        {
            refreshing = true;
            recordSwitch!.IsOn = systemAudio;
            if (allSwitch is not null)
            {
                allSwitch.IsOn = systemAudio && systemAudioAllApps;
            }

            foreach (var (toggle, id) in appSwitches)
            {
                toggle.IsOn = systemAudio && !systemAudioAllApps && systemAudioApps.Contains(id);
            }

            refreshing = false;
        }

        void Change(Action apply)
        {
            if (!refreshing)
            {
                apply();
                Refresh();
            }
        }

        var record = SwitchRow("Record system audio", systemAudio, value => Change(() =>
        {
            systemAudio = value;
            if (value && !systemAudioAllApps && systemAudioApps.Count == 0)
            {
                systemAudioAllApps = true;
            }
        }));
        recordSwitch = record.Toggle;
        menu.Children.Add(record.Row);
        if (!AudioApps.IsPerAppSupported)
        {
            return menu;
        }

        var all = SwitchRow("From all apps", systemAudio && systemAudioAllApps, value => Change(() =>
        {
            systemAudioAllApps = value;
            if (value)
            {
                systemAudio = true;
                systemAudioApps.Clear();
            }
        }));
        allSwitch = all.Toggle;
        menu.Children.Add(all.Row);
        menu.Children.Add(new Border { Height = 1, Background = Ui.Rgb(1, 1, 1, 0.12), Margin = new Thickness(14, 5, 14, 5) });
        var header = Label("Apps", 12, 0.5, true);
        header.Margin = new Thickness(14, 0, 0, 4);
        menu.Children.Add(header);
        foreach (var app in apps.Take(MaximumAudioAppRows))
        {
            var id = app.Id;
            var icon = new Image { Width = 19, Height = 19, VerticalAlignment = VerticalAlignment.Center };
            var row = SwitchRow(app.Name, systemAudio && !systemAudioAllApps && systemAudioApps.Contains(id), value => Change(() =>
            {
                if (value)
                {
                    systemAudio = true;
                    systemAudioAllApps = false;
                    systemAudioApps.Add(id);
                }
                else
                {
                    systemAudioApps.Remove(id);
                }
            }), icon);
            _ = LoadAppIcon(icon, app.ExecutablePath);
            appSwitches.Add((row.Toggle, id));
            menu.Children.Add(row.Row);
        }

        return menu;
    }

    private static async Task LoadAppIcon(Image image, string? path)
    {
        if (path is null)
        {
            return;
        }

        try
        {
            var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(path);
            using var thumbnail = await file.GetThumbnailAsync(Windows.Storage.FileProperties.ThumbnailMode.SingleItem, 38);
            var bitmap = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage();
            await bitmap.SetSourceAsync(thumbnail);
            image.Source = bitmap;
        }
        catch (Exception exception) when (exception is COMException or IOException or UnauthorizedAccessException or ArgumentException)
        {
            // The row stands without an icon.
        }
    }

    // MARK: Device monitoring

    /// <summary>
    /// Opens and closes the meter and the camera preview to match what is on screen. Only one piece of device work runs at a
    /// time and always off the UI thread, and nothing stays open once a recording needs the devices (spec/06 ADR-23).
    /// </summary>
    private void UpdateDevices()
    {
        var idle = isShown && !capturing;
        var wantedMicrophone = idle ? menuMeterDevice ?? microphone?.Id : null;
        if (wantedMicrophone != monitoredMicrophone)
        {
            monitoredMicrophone = wantedMicrophone;
            var old = monitor;
            monitor = null;
            deviceWork = deviceWork.ContinueWith(_ =>
            {
                old?.Dispose();
                if (wantedMicrophone is null)
                {
                    return;
                }

                var opened = MicrophoneLevelMonitor.TryStart(wantedMicrophone);
                if (opened is not null && !DispatcherQueue.TryEnqueue(() => AdoptMonitor(opened, wantedMicrophone)))
                {
                    opened.Dispose();
                }
            }, TaskScheduler.Default);
        }

        // In the Camera mode the large stage window shows the camera instead of the floating bubble.
        var showPreview = isShown && camera is not null && showCameraPreview && stage is null;
        if (showPreview && previewWindow is null)
        {
            previewWindow = new CameraPreviewWindow();
            previewWindow.AppWindow.Show(false);
        }
        else if (!showPreview && previewWindow is not null)
        {
            previewWindow.Close();
            previewWindow = null;
        }

        var wantedCamera = idle && (showPreview || stage is not null) ? camera?.Id : null;
        // The key names the window too, so moving between the bubble and the stage reopens the preview on the right one.
        var wantedKey = wantedCamera is null ? null : wantedCamera + (stage is not null ? "|stage" : "|bubble");
        if (wantedKey != previewedCamera)
        {
            previewedCamera = wantedKey;
            var old = cameraPreview;
            cameraPreview = null;
            Action<byte[], int, int>? show = stage is { } stageWindow ? stageWindow.ShowFrame : previewWindow is { } bubble ? bubble.ShowFrame : null;
            deviceWork = deviceWork.ContinueWith(_ =>
            {
                old?.Dispose();
                if (wantedCamera is null || show is null)
                {
                    return;
                }

                var opened = CameraPreviewSource.TryStart(wantedCamera, show);
                if (opened is not null && !DispatcherQueue.TryEnqueue(() => AdoptPreview(opened, wantedKey ?? "")))
                {
                    opened.Dispose();
                }
            }, TaskScheduler.Default);
        }

        if (wantedMicrophone is null)
        {
            meterTimer.Stop();
            barMeter?.Set(0, 0);
        }
        else
        {
            meterTimer.Start();
        }
    }

    private void AdoptMonitor(MicrophoneLevelMonitor opened, string device)
    {
        if (monitoredMicrophone == device && monitor is null)
        {
            monitor = opened;
        }
        else
        {
            deviceWork = deviceWork.ContinueWith(_ => opened.Dispose(), TaskScheduler.Default);
        }
    }

    private void AdoptPreview(CameraPreviewSource opened, string device)
    {
        if (previewedCamera == device && cameraPreview is null)
        {
            cameraPreview = opened;
        }
        else
        {
            deviceWork = deviceWork.ContinueWith(_ => opened.Dispose(), TaskScheduler.Default);
        }
    }

    private void MeterTick()
    {
        var (level, peak) = monitor is { } active ? (active.Level, active.PeakHold) : (0, 0);
        barMeter?.Set(level, peak);
        menuMeter?.Set(level, peak);
    }

    /// <summary>A capsule track with a dim peak bar and a bright level bar. Widths are set from the meter, never bound.</summary>
    private sealed partial class LevelBar : Grid
    {
        private readonly Border trailing = new() { HorizontalAlignment = HorizontalAlignment.Left, Width = 0 };
        private readonly Border bright = new() { HorizontalAlignment = HorizontalAlignment.Left, Width = 0 };

        public LevelBar(double thickness, Brush track, Brush peak, Brush level)
        {
            Height = thickness;
            var radius = new CornerRadius(thickness / 2);
            Children.Add(new Border { Background = track, CornerRadius = radius });
            trailing.Background = peak;
            trailing.CornerRadius = radius;
            bright.Background = level;
            bright.CornerRadius = radius;
            Children.Add(trailing);
            Children.Add(bright);
        }

        public void Set(double level, double peak)
        {
            var total = Math.Max(10, ActualWidth);
            trailing.Width = peak * total > 0.5 ? Math.Max(Height, Math.Min(1, peak) * total) : 0;
            bright.Width = level * total > 0.5 ? Math.Max(Height, Math.Min(1, level) * total) : 0;
        }
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
            var header = new MenuFlyoutSubItem { Text = Loc.T("Countdown") };
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
            var zooms = new ToggleMenuFlyoutItem { Text = Loc.T("Automatically create zooms"), IsChecked = settings.AutoCreateZooms };
            zooms.Click += (_, _) =>
            {
                settings.AutoCreateZooms = zooms.IsChecked;
                settings.Save();
            };
            menu.Items.Add(zooms);
            var highlight = new ToggleMenuFlyoutItem { Text = Loc.T("Highlight recorded area"), IsChecked = settings.HighlightRecordedArea };
            highlight.Click += (_, _) =>
            {
                settings.HighlightRecordedArea = highlight.IsChecked;
                settings.Save();
            };
            menu.Items.Add(highlight);
            // Read when a recording starts, so the screen and the saved strokes never disagree.
            var stay = new ToggleMenuFlyoutItem { Text = Loc.T("Drawings Stay Until Cleared"), IsChecked = settings.DrawingsStayUntilCleared };
            stay.Click += (_, _) =>
            {
                settings.DrawingsStayUntilCleared = stay.IsChecked;
                settings.Save();
            };
            menu.Items.Add(stay);
            AddNotesAndProfiles(menu);
            var after = new MenuFlyoutSubItem { Text = Loc.T("After recording") };
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

    /// <param name="seconds">A countdown for this recording only, as an agent can ask; otherwise the setting.</param>
    private void BeginCountdown(CaptureTarget chosen, int? seconds = null)
    {
        pending = chosen;
        countdownTotal = seconds ?? AppSettings.Shared.CountdownSeconds;
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
            // The recorder opens the same devices, so the meter and the preview let go of them first.
            capturing = true;
            UpdateDevices();
            // Only that the devices were let go matters here: a failure while closing one must not stop the recording.
            await deviceWork.ContinueWith(_ => { }, TaskScheduler.Default);
            var directory = RecordingPackage.Create(AppSettings.Shared.ProjectsDirectory, DateTime.Now);
            var options = new RecordingOptions(chosen, directory, IsSystemAudioActive, microphone?.Id, camera?.Id, cameraMaxHeight, systemAudioAllApps ? null : systemAudioApps.ToList());
            var cameraOnly = chosen.Mode == CaptureTargetMode.Camera;
            var cameraId = camera?.Id;
            var microphoneId = microphone?.Id;
            var (created, started) = await Task.Run(() =>
            {
                IRecordingEngine next = cameraOnly
                    ? new CameraOnlyRecorder(directory, cameraId ?? throw new InvalidOperationException(Loc.T("A camera recording needs a camera.")), cameraMaxHeight, microphoneId)
                    : new ScreenRecorder(options);
                return (next, next.WaitForFirstFrame());
            });
            cameraFormat = created is CameraOnlyRecorder cameraRecorder ? cameraRecorder.Format : null;
            pending = null;
            target = chosen;
            package = directory;
            recorder = created;
            busy = false;
            created.Failed += failure => DispatcherQueue.TryEnqueue(() => _ = EndAfterFailure(created, failure));
            if (stage is { } cameraStage)
            {
                created.CameraFrame += cameraStage.ShowFrame;
                cameraStage.SetRecording(true);
            }
            else if (previewWindow is { } preview)
            {
                created.CameraFrame += preview.ShowFrame;
            }

            if (!started)
            {
                await AbortRecording();
                return;
            }

            startedAt = DateTime.UtcNow;
            drawingsStay = AppSettings.Shared.DrawingsStayUntilCleared;
            notes?.RecordingStarted();
            pausedTotal = TimeSpan.Zero;
            pausedAt = null;
            isPaused = false;
            if (AppSettings.Shared.HighlightRecordedArea && !cameraOnly)
            {
                recordedArea = new RecordedAreaHighlight(chosen.Rect, chosen.Display.Scale);
            }

            ShowRecording();
        }
        catch (Exception exception) when (exception is SharpGen.Runtime.SharpGenException or COMException or IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            busy = false;
            pending = null;
            capturing = false;
            mcpLastError = exception.Message;
            AppExclusion(false);
            ShowIdle();
            UpdateDevices();
            // A message box and not a dialog: the recording bar is too small to host one.
            var message = exception.Message;
            var title = Loc.T("Could not start recording");
            _ = Task.Run(() => MessageBoxW(0, message, title, MessageBoxWarningTopmost));
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
        // A new clock each rebuild: the previous one stays a child of the previous row, and adding it again threw "No
        // installed components were detected" (0x800F1000), so pausing failed and the bar stopped changing.
        elapsed = NewClock();
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
        AddDrawingControls();
        if (recorder?.IsMissingAppAudio == true)
        {
            var warning = Label("Some app sound is missing", 12.5, 1);
            warning.Foreground = Orange;
            bar.Children.Add(warning);
        }

        FitToContent();
        tick.Start();
    }

    private static TextBlock NewClock() => new() { FontSize = 15, VerticalAlignment = VerticalAlignment.Center, MinWidth = 38 };

    private void TogglePause()
    {
        if (recorder is null)
        {
            return;
        }

        isPaused = !isPaused;
        if (isPaused)
        {
            StopDrawingForPause();
        }

        recorder.SetPaused(isPaused);
        notes?.RecordingPaused(isPaused);
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
        DisposeDrawing();
        notes?.RecordingEnded();
        var running = recorder;
        recorder = null;
        if (running is not null)
        {
            lastDuration = await Task.Run(() =>
            {
                running.Stop();
                var result = (running.DurationMs, running.HasWebcam, running.HasMicrophone, running.HasSystemAudio);
                lastRecordingFailed = running.Failure is not null;
                running.Dispose();
                return result;
            });
        }

        capturing = false;
        UpdateDevices();
    }

    /// <summary>The captured window went away or a writer failed: keep what was written, open it, and say why the recording stopped.</summary>
    private async Task EndAfterFailure(IRecordingEngine engine, CaptureFailure failure)
    {
        if (recorder != engine || busy)
        {
            return;
        }

        var savedMs = await StopAndOpen();
        var reason = Loc.T(failure.Kind switch
        {
            CaptureFailureKind.Stream => "The recorded window or display is no longer available.",
            CaptureFailureKind.ScreenWriter => "The screen video could not be written.",
            CaptureFailureKind.WebcamWriter => "The camera video could not be written.",
            _ => "The microphone audio could not be written."
        });
        mcpLastError = reason;
        var outcome = Loc.T("Nothing could be saved.");
        if (savedMs is { } ms)
        {
            var total = (int)Math.Round(ms / 1000);
            outcome = Loc.F("The first %@ was saved and opened in the editor.", $"{total / 60}:{total % 60:00}");
        }

        // A message box and not a dialog: the recording bar is too small to host one. Off the UI thread, so the app keeps running.
        var text = $"{reason} {outcome}\n\n{failure.Details}";
        var title = Loc.T("Recording stopped");
        _ = Task.Run(() => MessageBoxW(0, text, title, MessageBoxWarningTopmost));
    }

    private const uint MessageBoxWarningTopmost = 0x30 | 0x40000 | 0x10000;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(nint owner, string text, string caption, uint type);

    /// <summary>What a failed writer left that can be played: its complete fragments.</summary>
    private static double PlayableMs(string directory)
    {
        try
        {
            using var reader = new VideoFileReader(Path.Combine(directory, "recording", File.Exists(Path.Combine(directory, "recording", "display.mp4")) ? "display.mp4" : "webcam.mp4"));
            return reader.DurationMs;
        }
        catch (Exception exception) when (exception is SharpGen.Runtime.SharpGenException or COMException or IOException or InvalidOperationException or IndexOutOfRangeException)
        {
            return 0;
        }
    }

    /// <summary>Returns the saved length in milliseconds, or null when nothing was saved.</summary>
    private async Task<double?> StopAndOpen()
    {
        if (busy || package is null || target is null)
        {
            return null;
        }

        busy = true;
        await StopRecorder();
        AppExclusion(false);
        var (directory, chosen, stats) = (package, target, lastDuration);
        package = null;
        target = null;
        if (lastRecordingFailed)
        {
            // A failed writer is never finished, so the project must not be longer than what can be played back.
            var playableMs = await Task.Run(() => PlayableMs(directory));
            if (!double.IsFinite(playableMs) || playableMs < 500)
            {
                await Task.Run(() => Directory.Delete(directory, true));
                busy = false;
                ShowIdle();
                return null;
            }

            stats.DurationMs = Math.Min(stats.DurationMs, playableMs);
        }

        var cameraOnly = chosen.Mode == CaptureTargetMode.Camera;
        var metadata = cameraOnly && cameraFormat is { } format ? CameraOnlyMetadata(format) : chosen.Metadata();
        CloseCameraStage();
        await Task.Run(() => RecordingPackage.Finish(directory, metadata, stats.DurationMs, stats.HasWebcam, stats.HasMicrophone, stats.HasSystemAudio, autoCreateZooms: AppSettings.Shared.AutoCreateZooms && !cameraOnly, DateTimeOffset.UtcNow, cameraOnly));
        await Task.Run(() => ApplyDefaultPreset(directory));
        busy = false;
        ShowIdle();
        await Projects.Open(directory, root.XamlRoot, AppSettings.Shared.AfterRecording);
        return stats.DurationMs;
    }

    /// <summary>A camera-only recording's target: the camera picture's size with scale 1, at the camera's rate (spec/02).</summary>
    private static CaptureTargetMetadata CameraOnlyMetadata((int Width, int Height, double FrameMs) format) => new()
    {
        Mode = CaptureTargetMode.Camera,
        DisplayId = 0,
        LogicalBounds = new LogicalBounds { X = 0, Y = 0, Width = format.Width, Height = format.Height },
        PixelSize = new PixelDimensions { Width = format.Width, Height = format.Height },
        ScaleFactor = 1,
        RefreshRate = Math.Round(1000 / Math.Max(1, format.FrameMs)),
        WindowBorderRadius = 0
    };

    /// <summary>A new project starts in the style of the default preset, when one is set.</summary>
    private static void ApplyDefaultPreset(string directory)
    {
        var store = new ProjectPresetStore(EditorTools.PresetsDirectory);
        if (AppSettings.Shared.DefaultPresetId is { } id && store.Load().Find(item => item.Id == id) is { } preset)
        {
            var path = Path.Combine(directory, "project.json");
            var document = ProjectJson.Deserialize<ProjectDocument>(File.ReadAllText(path));
            preset.Apply(document);
            File.WriteAllText(path, ProjectJson.Serialize(document));
        }
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
            Title = Loc.T("Delete this recording?"),
            PrimaryButtonText = Loc.T("Delete"),
            CloseButtonText = Loc.T("Keep recording")
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

    /// <summary>
    /// Only the recording UI stays off camera: editors are recordable, so editing can be demoed. The bar is excluded only while
    /// recording, so a screenshot of it works the rest of the time.
    /// </summary>
    private void AppExclusion(bool excluded) => CaptureTargets.SetExcludedFromCapture(Handle, excluded);

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

    private const int StyleIndex = -16;
    private const long CaptionStyle = 0x00C00000;
    private const long ThickFrameStyle = 0x00040000;
    private const long PopupStyle = 0x80000000;
    private const uint FrameChangedFlags = 0x0001 | 0x0002 | 0x0004 | 0x0010 | 0x0020;

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern long GetWindowLongPtr(nint window, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static extern long SetWindowLongPtr(nint window, int index, long value);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);

}
