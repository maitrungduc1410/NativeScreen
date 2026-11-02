using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using NativeScreen.Core;
using NativeScreen.Media;
using PixelRect = NativeScreen.Media.PixelRect;

namespace NativeScreen.App;

/// <summary>
/// The floating recording bar. One at a time; it picks the target, runs the countdown, and owns the recorder until the
/// editor opens. Microphone and camera start off and are chosen per session (spec/06 ADR-23).
/// </summary>
public sealed class RecordingHudWindow : Window
{
    private const int CountdownSeconds = 3;
    private const double BarHeight = 64;
    private const double BottomMargin = 56;

    private static RecordingHudWindow? shared;

    private readonly StackPanel bar = new() { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly Grid root = new();
    private readonly DispatcherTimer tick = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private readonly TextBlock status;
    private CaptureTargetMode mode = CaptureTargetMode.Display;
    private CaptureDisplay display = CaptureTargets.Displays()[0];
    private CaptureWindow? pickedWindow;
    private PixelRect? pickedArea;
    private TargetOverlay? overlay;
    private bool systemAudio = true;
    private CaptureDeviceInfo? microphone;
    private CaptureDeviceInfo? camera;
    private int countdown;
    private bool busy;
    private bool isPaused;
    private ScreenRecorder? recorder;
    private CaptureTarget? target;
    private string? package;
    private DateTime startedAt;
    private TimeSpan pausedTotal;
    private DateTime? pausedAt;

    private RecordingHudWindow(CaptureTargetMode initialMode)
    {
        mode = initialMode;
        Title = "Native Screen Recording";
        root.Background = Ui.Pal("SurfacePanel");
        root.CornerRadius = new CornerRadius(14);
        root.Children.Add(bar);
        Content = root;
        status = Ui.Text("", 12.5, "Ink60");
        status.TextWrapping = TextWrapping.NoWrap;
        AppTheme.Register(this);
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.SetBorderAndTitleBar(false, false);
            presenter.IsAlwaysOnTop = true;
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
        }

        AppWindow.IsShownInSwitchers = false;
        tick.Tick += (_, _) => Tick();
        Closed += (_, _) =>
        {
            shared = null;
            tick.Stop();
            overlay?.Dispose();
            AppExclusion(false);
        };
        CaptureTargets.SetExcludedFromCapture(Handle, true);
        ShowIdle();
    }

    private nint Handle => WinRT.Interop.WindowNative.GetWindowHandle(this);

    /// <summary>Opens the bar, or brings the open one forward with another mode.</summary>
    public static void Show(CaptureTargetMode mode = CaptureTargetMode.Display)
    {
        if (shared is null)
        {
            shared = new RecordingHudWindow(mode);
        }
        else if (shared.recorder is null)
        {
            shared.mode = mode;
            shared.ShowIdle();
        }

        shared.Activate();
        if (mode != CaptureTargetMode.Display)
        {
            shared.BeginPick();
        }
    }

    private void Place(double width)
    {
        var scale = root.XamlRoot?.RasterizationScale ?? display.Scale;
        var area = DisplayArea.GetFromPoint(new Windows.Graphics.PointInt32(display.Bounds.X + 1, display.Bounds.Y + 1), DisplayAreaFallback.Primary).WorkArea;
        var pixelWidth = (int)(width * scale);
        var pixelHeight = (int)(BarHeight * scale);
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(
            area.X + (area.Width - pixelWidth) / 2,
            area.Y + area.Height - pixelHeight - (int)(BottomMargin * scale),
            pixelWidth,
            pixelHeight));
    }

    // MARK: Idle

    private void ShowIdle()
    {
        bar.Children.Clear();
        bar.Children.Add(Ui.IconButton(Ui.Icon("", 14), "Close", Close, 36));
        bar.Children.Add(ModeButton("Display", CaptureTargetMode.Display));
        bar.Children.Add(ModeButton("Window", CaptureTargetMode.Window));
        bar.Children.Add(ModeButton("Area", CaptureTargetMode.Area));
        bar.Children.Add(Separator());
        bar.Children.Add(DeviceButton("Camera", camera, WebcamRecorder.Cameras, device => camera = device));
        bar.Children.Add(DeviceButton("Microphone", microphone, AudioTrackRecorder.Microphones, device => microphone = device));
        bar.Children.Add(Ui.Option("System audio", systemAudio, () =>
        {
            systemAudio = !systemAudio;
            ShowIdle();
        }));
        bar.Children.Add(Separator());
        status.Text = TargetDescription();
        bar.Children.Add(status);
        var record = new Button { Style = Ui.StyleOf("NsPrimaryButton"), Content = "Record", Height = 38, IsEnabled = TargetIsReady() };
        record.Click += (_, _) => BeginCountdown();
        bar.Children.Add(record);
        Place(980);
    }

    private Button ModeButton(string title, CaptureTargetMode target) => Ui.Option(title, mode == target, () =>
    {
        mode = target;
        ShowIdle();
        BeginPick();
    });

    private Button DeviceButton(string title, CaptureDeviceInfo? selected, Func<IReadOnlyList<CaptureDeviceInfo>> list, Action<CaptureDeviceInfo?> choose)
    {
        var button = Ui.Option(selected is null ? $"{title}: Off" : selected.Name, selected is not null, () => { });
        button.Click += (_, _) =>
        {
            var menu = new MenuFlyout();
            var none = new MenuFlyoutItem { Text = "Off" };
            none.Click += (_, _) =>
            {
                choose(null);
                ShowIdle();
            };
            menu.Items.Add(none);
            foreach (var device in list())
            {
                var item = new MenuFlyoutItem { Text = device.Name };
                var captured = device;
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

    private UIElement Separator() => new Border { Width = 1, Height = 26, Background = Ui.Pal("Ink07"), Margin = new Thickness(2, 0, 2, 0) };

    private string TargetDescription() => mode switch
    {
        CaptureTargetMode.Window => pickedWindow?.AppName ?? "Pick a window",
        CaptureTargetMode.Area => pickedArea is { } area ? $"{area.Width} × {area.Height}" : "Drag an area",
        _ => $"{display.Bounds.Width} × {display.Bounds.Height}"
    };

    private bool TargetIsReady() => mode switch
    {
        CaptureTargetMode.Window => pickedWindow is not null,
        CaptureTargetMode.Area => pickedArea is not null,
        _ => true
    };

    private void BeginPick()
    {
        overlay?.Dispose();
        overlay = null;
        if (mode == CaptureTargetMode.Display)
        {
            return;
        }

        overlay = new TargetOverlay(
            mode == CaptureTargetMode.Window,
            window =>
            {
                overlay = null;
                pickedWindow = window;
                display = CaptureTargets.DisplayOf(window.Bounds);
                ShowIdle();
            },
            area =>
            {
                overlay = null;
                pickedArea = area;
                display = CaptureTargets.DisplayOf(area);
                ShowIdle();
            },
            () =>
            {
                overlay = null;
                mode = CaptureTargetMode.Display;
                ShowIdle();
            });
    }

    // MARK: Start

    private void BeginCountdown()
    {
        countdown = CountdownSeconds;
        bar.Children.Clear();
        status.Text = $"Recording starts in {countdown}";
        bar.Children.Add(status);
        var cancel = Ui.Option("Cancel", false, () =>
        {
            tick.Stop();
            countdown = 0;
            ShowIdle();
        });
        bar.Children.Add(cancel);
        Place(380);
        tick.Interval = TimeSpan.FromSeconds(1);
        tick.Start();
    }

    private void Tick()
    {
        if (countdown > 0)
        {
            countdown--;
            status.Text = $"Recording starts in {countdown}";
            if (countdown == 0)
            {
                tick.Stop();
                _ = StartRecording();
            }

            return;
        }

        status.Text = Ui.Timecode(Elapsed().TotalMilliseconds);
    }

    private TimeSpan Elapsed()
    {
        var paused = pausedTotal + (pausedAt is { } at ? DateTime.UtcNow - at : TimeSpan.Zero);
        return DateTime.UtcNow - startedAt - paused;
    }

    private CaptureTarget BuildTarget() => mode switch
    {
        CaptureTargetMode.Window => new CaptureTarget(mode, display, CaptureTargets.WindowInfo(pickedWindow!.Handle) ?? pickedWindow, CaptureTargets.WindowInfo(pickedWindow.Handle)?.Bounds ?? pickedWindow.Bounds),
        CaptureTargetMode.Area => new CaptureTarget(mode, display, null, pickedArea!.Value),
        _ => new CaptureTarget(CaptureTargetMode.Display, display, null, display.Bounds)
    };

    private async Task StartRecording()
    {
        ShowBusy("Starting…");
        AppExclusion(true);
        try
        {
            var chosen = BuildTarget();
            if (chosen.Window is { } window)
            {
                CaptureTargets.BringToFront(window.Handle);
            }

            var directory = RecordingPackage.Create(AppSettings.Shared.ProjectsDirectory, DateTime.Now);
            var options = new RecordingOptions(chosen, directory, systemAudio, microphone?.Id, camera?.Id);
            var (created, started) = await Task.Run(() =>
            {
                var next = new ScreenRecorder(options);
                return (next, next.WaitForFirstFrame());
            });
            target = chosen;
            package = directory;
            recorder = created;
            if (!started)
            {
                await AbortRecording("This target did not produce any frames.");
                return;
            }

            startedAt = DateTime.UtcNow;
            pausedTotal = TimeSpan.Zero;
            pausedAt = null;
            isPaused = false;
            ShowRecording();
        }
        catch (Exception exception) when (exception is SharpGen.Runtime.SharpGenException or System.Runtime.InteropServices.COMException or IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            AppExclusion(false);
            ShowIdle();
            status.Text = $"Could not start: {exception.Message}";
        }
    }

    // MARK: Recording

    private void ShowRecording()
    {
        bar.Children.Clear();
        var stop = new Button { Style = Ui.StyleOf("NsPrimaryButton"), Content = "Stop", Height = 38 };
        stop.Click += (_, _) => _ = StopAndOpen();
        bar.Children.Add(stop);
        status.Text = Ui.Timecode(Elapsed().TotalMilliseconds);
        bar.Children.Add(status);
        bar.Children.Add(Ui.Option(isPaused ? "Resume" : "Pause", isPaused, TogglePause));
        bar.Children.Add(Ui.Option("Restart", false, () => _ = Restart()));
        bar.Children.Add(Ui.Option("Delete", false, () => _ = ConfirmDelete()));
        Place(480);
        tick.Interval = TimeSpan.FromMilliseconds(250);
        tick.Start();
    }

    private void ShowBusy(string text)
    {
        bar.Children.Clear();
        status.Text = text;
        bar.Children.Add(status);
        Place(300);
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

    private async Task StopRecorder()
    {
        tick.Stop();
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

    private (double DurationMs, bool HasWebcam, bool HasMicrophone, bool HasSystemAudio) lastDuration;

    private async Task StopAndOpen()
    {
        if (busy || package is null || target is null)
        {
            return;
        }

        busy = true;
        ShowBusy("Finishing the recording…");
        await StopRecorder();
        AppExclusion(false);
        var (directory, chosen, stats) = (package, target, lastDuration);
        var project = await Task.Run(() =>
        {
            RecordingPackage.Finish(directory, chosen.Metadata(), stats.DurationMs, stats.HasWebcam, stats.HasMicrophone, stats.HasSystemAudio, autoCreateZooms: true, DateTimeOffset.UtcNow);
            return new LoadedProject(directory);
        });
        new EditorWindow(EditorSource.Package(directory, project)).Activate();
        AppSettings.Shared.NoteRecent(directory);
        Close();
    }

    private async Task Restart()
    {
        if (busy)
        {
            return;
        }

        busy = true;
        ShowBusy("Restarting…");
        await DiscardCurrent();
        busy = false;
        await StartRecording();
    }

    private async Task ConfirmDelete()
    {
        var answer = await new ContentDialog
        {
            XamlRoot = root.XamlRoot,
            RequestedTheme = AppTheme.Current,
            Title = "Delete this recording?",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Keep recording"
        }.ShowAsync();
        if (answer == ContentDialogResult.Primary)
        {
            await AbortRecording(null);
        }
    }

    private async Task AbortRecording(string? message)
    {
        ShowBusy("Stopping…");
        await DiscardCurrent();
        AppExclusion(false);
        ShowIdle();
        if (message is not null)
        {
            status.Text = message;
        }
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
}
