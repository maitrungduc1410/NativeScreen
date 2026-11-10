using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using NativeScreen.Media;

namespace NativeScreen.App;

/// <summary>
/// Speaker notes only the presenter sees (spec/06 ADR-76). It edits as text or scrolls as a prompter. The prompter is a clock,
/// not a scroll view: the offset is the distance scrolled before plus speed × time since scrolling started, so a speed change
/// keeps the position and it costs nothing at rest. Windows can leave a window out of capture at any time, so it is left out
/// while recording (`WDA_EXCLUDEFROMCAPTURE`) and shows in screenshots otherwise; it can be turned on mid-recording.
/// </summary>
internal sealed class SpeakerNotesWindow : Window
{
    private const double MinimumFont = 14;
    private const double MaximumFont = 64;
    private const double MinimumSpeed = 5;
    private const double MaximumSpeed = 120;

    private readonly Grid root = new() { Background = Ui.Rgb(0.10, 0.10, 0.12, 1) };
    private readonly TextBox editor = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, BorderThickness = new Thickness(0) };
    private readonly Canvas prompterView = new() { Background = Ui.Rgb(0, 0, 0, 1) };
    private readonly TextBlock prompterText = new() { TextWrapping = TextWrapping.Wrap, Foreground = Ui.Rgb(1, 1, 1, 0.96), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };
    private readonly StackPanel toolbar = new() { Orientation = Orientation.Horizontal, Spacing = 4, Padding = new Thickness(8, 6, 8, 6) };
    private readonly DispatcherTimer clock = new() { Interval = TimeSpan.FromMilliseconds(16) };
    private bool prompter;
    private double offset;
    private DateTime? scrollingSince;
    private Windows.Graphics.RectInt32? userFrame;

    public SpeakerNotesWindow()
    {
        Title = Loc.T("Speaker Notes");
        var settings = AppSettings.Shared;
        editor.Text = settings.SpeakerNotesText;
        editor.PlaceholderText = Loc.T("Write what you want to say. Only you see this window; it is not recorded.");
        editor.FontSize = settings.SpeakerNotesFontSize;
        editor.TextChanged += (_, _) =>
        {
            settings.SpeakerNotesText = editor.Text;
            settings.Save();
        };
        prompterView.Children.Add(prompterText);
        prompterView.SizeChanged += (_, _) => Layout();
        prompterView.Tapped += (_, _) => ToggleScrolling();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition());
        root.Children.Add(toolbar);
        Grid.SetRow(editor, 1);
        Grid.SetRow(prompterView, 1);
        root.Children.Add(editor);
        root.Children.Add(prompterView);
        root.KeyDown += KeyPressed;
        root.RequestedTheme = ElementTheme.Dark;
        Content = root;
        clock.Tick += (_, _) => Layout();
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsAlwaysOnTop = true;
            presenter.IsMinimizable = false;
            presenter.IsMaximizable = false;
        }

        AppWindow.IsShownInSwitchers = false;
        var scale = GetDpiForWindow(Handle) / 96.0;
        var area = DisplayArea.Primary.WorkArea;
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(area.X + area.Width - (int)(440 * scale) - (int)(40 * scale), area.Y + (int)(80 * scale), (int)(440 * scale), (int)(300 * scale)));
        Closed += (_, _) => clock.Stop();
        Show(prompter: false);
    }

    private nint Handle => WinRT.Interop.WindowNative.GetWindowHandle(this);

    /// <summary>Left out of capture from the start of a recording to its end, when the prompter may also restart.</summary>
    public void RecordingStarted()
    {
        CaptureTargets.SetExcludedFromCapture(Handle, true);
        if (AppSettings.Shared.SpeakerNotesScrollsWhileRecording)
        {
            offset = 0;
            Show(prompter: true);
            StartScrolling();
        }
    }

    public void RecordingPaused(bool paused)
    {
        if (paused)
        {
            StopScrolling();
        }
        else if (prompter && AppSettings.Shared.SpeakerNotesScrollsWhileRecording)
        {
            StartScrolling();
        }
    }

    public void RecordingEnded()
    {
        StopScrolling();
        CaptureTargets.SetExcludedFromCapture(Handle, false);
    }

    /// <summary>In the Camera mode the notes sit at the top center, under the camera; `null` puts them back.</summary>
    public void DockUnderCamera(Windows.Graphics.RectInt32? frame)
    {
        if (frame is { } dock)
        {
            userFrame ??= new Windows.Graphics.RectInt32(AppWindow.Position.X, AppWindow.Position.Y, AppWindow.Size.Width, AppWindow.Size.Height);
            AppWindow.MoveAndResize(dock);
        }
        else if (userFrame is { } own)
        {
            AppWindow.MoveAndResize(own);
            userFrame = null;
        }
    }

    private void Show(bool prompter)
    {
        this.prompter = prompter;
        editor.Visibility = prompter ? Visibility.Collapsed : Visibility.Visible;
        prompterView.Visibility = prompter ? Visibility.Visible : Visibility.Collapsed;
        if (!prompter)
        {
            StopScrolling();
        }

        BuildToolbar();
        Layout();
    }

    private void BuildToolbar()
    {
        toolbar.Children.Clear();
        toolbar.Children.Add(Ui.IconButton(Ui.Icon(prompter ? "" : "", 14), prompter ? "Edit notes" : "Show as prompter", () => Show(!prompter)));
        if (prompter)
        {
            toolbar.Children.Add(Ui.IconButton(Ui.Icon(scrollingSince is null ? "" : "", 14), scrollingSince is null ? "Scroll" : "Pause scrolling", ToggleScrolling));
            toolbar.Children.Add(Ui.IconButton(Ui.Icon("", 14), "Back to the top", () =>
            {
                offset = 0;
                scrollingSince = scrollingSince is null ? null : DateTime.UtcNow;
                Layout();
            }));
            var speed = new Slider { Minimum = MinimumSpeed, Maximum = MaximumSpeed, Value = AppSettings.Shared.SpeakerNotesSpeed, Width = 110, VerticalAlignment = VerticalAlignment.Center };
            ToolTipService.SetToolTip(speed, Loc.T("Scroll speed"));
            speed.ValueChanged += (_, args) =>
            {
                // Keeps the position when the speed changes mid-scroll.
                Fold();
                AppSettings.Shared.SpeakerNotesSpeed = args.NewValue;
                AppSettings.Shared.Save();
            };
            toolbar.Children.Add(speed);
        }

        toolbar.Children.Add(Ui.IconButton(Ui.Icon("", 14), "Smaller text", () => SetFont(AppSettings.Shared.SpeakerNotesFontSize - 2)));
        toolbar.Children.Add(Ui.IconButton(Ui.Icon("", 14), "Larger text", () => SetFont(AppSettings.Shared.SpeakerNotesFontSize + 2)));
        var fromTop = new Microsoft.UI.Xaml.Controls.Primitives.ToggleButton { Content = Ui.Icon("", 14), IsChecked = AppSettings.Shared.SpeakerNotesScrollsWhileRecording };
        ToolTipService.SetToolTip(fromTop, Loc.T("Scroll from the top when recording starts"));
        fromTop.Click += (_, _) =>
        {
            AppSettings.Shared.SpeakerNotesScrollsWhileRecording = fromTop.IsChecked == true;
            AppSettings.Shared.Save();
        };
        toolbar.Children.Add(fromTop);
    }

    private void SetFont(double size)
    {
        var value = Math.Clamp(size, MinimumFont, MaximumFont);
        AppSettings.Shared.SpeakerNotesFontSize = value;
        AppSettings.Shared.Save();
        editor.FontSize = value;
        Layout();
    }

    private void ToggleScrolling()
    {
        if (scrollingSince is null)
        {
            StartScrolling();
        }
        else
        {
            StopScrolling();
        }
    }

    private void StartScrolling()
    {
        if (!prompter || scrollingSince is not null)
        {
            return;
        }

        scrollingSince = DateTime.UtcNow;
        clock.Start();
        BuildToolbar();
    }

    private void StopScrolling()
    {
        if (scrollingSince is null)
        {
            return;
        }

        Fold();
        scrollingSince = null;
        clock.Stop();
        BuildToolbar();
    }

    private void Fold()
    {
        if (scrollingSince is { } since)
        {
            offset += (DateTime.UtcNow - since).TotalSeconds * AppSettings.Shared.SpeakerNotesSpeed;
            scrollingSince = DateTime.UtcNow;
        }
    }

    /// <summary>The notes move up by the offset; the reading line is a third of the way down.</summary>
    private void Layout()
    {
        if (!prompter)
        {
            return;
        }

        var size = AppSettings.Shared.SpeakerNotesFontSize;
        prompterText.Text = editor.Text;
        prompterText.FontSize = size;
        prompterText.LineHeight = size * 1.35;
        prompterText.Width = Math.Max(40, prompterView.ActualWidth - 32);
        var current = offset + (scrollingSince is { } since ? (DateTime.UtcNow - since).TotalSeconds * AppSettings.Shared.SpeakerNotesSpeed : 0);
        Canvas.SetLeft(prompterText, 16);
        Canvas.SetTop(prompterText, prompterView.ActualHeight / 3 - current);
        prompterView.Clip = new RectangleGeometry { Rect = new Windows.Foundation.Rect(0, 0, prompterView.ActualWidth, prompterView.ActualHeight) };
    }

    private void KeyPressed(object sender, KeyRoutedEventArgs args)
    {
        // Space plays and pauses the prompter, except while the notes are being typed in.
        if (args.Key == Windows.System.VirtualKey.Space && prompter)
        {
            ToggleScrolling();
            args.Handled = true;
        }
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint hwnd);
}
