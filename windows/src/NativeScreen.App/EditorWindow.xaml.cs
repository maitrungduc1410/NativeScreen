using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using NativeScreen.Core;
using NativeScreen.Rendering;

namespace NativeScreen.App;

public sealed partial class EditorWindow : Window
{
    private readonly EditorSession session;
    private readonly DispatcherTimer clockTimer;
    private FrameCompositor? compositor;
    private CompositionSwapChain? swapChain;
    private bool scrubInternal;

    public EditorWindow(LoadedProject? project = null)
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        AppTheme.Apply(this);
        session = new EditorSession(project?.Document, project?.Metadata.DurationMs ?? 6000);
        Title = session.Document.Name;
        foreach (var tab in InspectorCatalog.Tabs)
        {
            Tabs.Items.Add(new ListViewItem { Content = InspectorCatalog.Title(tab), Tag = tab });
        }

        Tabs.SelectedIndex = 0;
        Playhead.Maximum = session.DurationMs;
        ShowInspector();
        ShowTimeline();
        FillCommands();
        Preview.Loaded += AttachPreview;
        clockTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(16) };
        clockTimer.Tick += (_, _) => Sample();
    }

    private void AttachPreview(object sender, RoutedEventArgs e)
    {
        var width = Math.Max(2, (int)Preview.ActualWidth);
        var height = Math.Max(2, (int)Preview.ActualHeight);
        compositor = new FrameCompositor();
        swapChain = compositor.CreateSwapChain(width, height);
        // VERIFY: render thread waits on the latency object, composites, then Present(1, 0). This attach is UI-thread only.
        SwapChainPanelInterop.SetSwapChain(Preview, swapChain.SwapChain.NativePointer);
    }

    private void TogglePlay(object sender, RoutedEventArgs e)
    {
        session.TogglePlayback();
        PlayButton.Label = session.IsPlaying ? "Pause" : "Play";
        if (session.IsPlaying)
        {
            clockTimer.Start();
        }
        else if (PreviewScheduler.BlocksIdle(session.IsPlaying, false))
        {
            clockTimer.Stop();
        }
    }

    private void Sample()
    {
        session.SamplePlayhead();
        scrubInternal = true;
        Playhead.Value = session.PlayheadTimelineMs;
        scrubInternal = false;
        TimeLabel.Text = $"{session.PlayheadTimelineMs:0} ms";
        if (!session.IsPlaying)
        {
            clockTimer.Stop();
            PlayButton.Label = "Play";
        }
    }

    private void Scrub(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        if (scrubInternal)
        {
            return;
        }

        session.Scrub(e.NewValue);
        TimeLabel.Text = $"{session.PlayheadTimelineMs:0} ms";
        PlayButton.Label = "Play";
    }

    private void TabChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Tabs.SelectedItem is ListViewItem { Tag: InspectorTab tab })
        {
            session.SelectTab(tab);
            ShowInspector();
        }
    }

    private void ShowInspector()
    {
        var title = InspectorCatalog.Title(session.SelectedTab);
        var accelerator = InspectorCatalog.Accelerator(session.SelectedTab);
        InspectorBody.Text = accelerator is null ? title : $"{title}  {accelerator}";
    }

    private void ShowTimeline()
    {
        var zooms = session.Document.Timeline.Zooms.Count;
        var slices = session.Document.Timeline.Slices.Count;
        TimelineSummary.Text = $"{slices} slices, {zooms} zooms, {session.DurationMs:0} ms";
    }

    private void Undo(object sender, RoutedEventArgs e)
    {
        session.History.Undo();
        Title = session.Document.Name;
        ShowTimeline();
    }

    private void Redo(object sender, RoutedEventArgs e)
    {
        session.History.Redo();
        Title = session.Document.Name;
        ShowTimeline();
    }

    private void ToggleCommands(object sender, RoutedEventArgs e)
    {
        var open = CommandMenu.Visibility != Visibility.Visible;
        CommandMenu.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
        if (open)
        {
            session.OpenCommandMenu();
            CommandQuery.Focus(FocusState.Programmatic);
        }
        else
        {
            session.CloseCommandMenu();
        }
    }

    private void QueryChanged(object sender, TextChangedEventArgs e)
    {
        session.SetCommandQuery(CommandQuery.Text);
        FillCommands();
    }

    private void FillCommands()
    {
        CommandList.Items.Clear();
        foreach (var command in EditorCommands.Search(session.CommandQuery))
        {
            CommandList.Items.Add($"{command.Title}    {command.Accelerator}");
        }
    }

    private void Export(object sender, RoutedEventArgs e)
    {
        var settings = new ExportSettings();
        settings.Normalize();
        if (!ExportPlan.IsAvailableOnWindows(settings.Format))
        {
            return;
        }

        var frames = ExportPlan.FrameCount(session.DurationMs, settings.Fps);
        var job = new ExportJob(frames, Path.Combine(Path.GetTempPath(), "NativeScreen-export.mp4"));
        TimeLabel.Text = $"Export {job.TotalFrames} frames, quality {ExportPlan.Quality(settings.Compression)}";
        // VERIFY: the export worker decodes, composites offscreen, and encodes with FragmentedMp4Writer. Cancel deletes the partial file.
    }

    private void OpenSettings(object sender, RoutedEventArgs e)
    {
        var settings = new SettingsWindow();
        settings.Activate();
    }
}
