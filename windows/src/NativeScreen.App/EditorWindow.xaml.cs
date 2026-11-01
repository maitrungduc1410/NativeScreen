using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using NativeScreen.Core;
using NativeScreen.Export;
using NativeScreen.Media;
using NativeScreen.Rendering;
using Windows.Foundation;
using Windows.Graphics;
using Windows.System;
using Windows.UI.Core;

namespace NativeScreen.App;

/// <summary>What an editor window opens: a loaded package, or an in-memory project with no files behind it.</summary>
public sealed record EditorSource(ProjectDocument? Document, double DurationMs, double SourceWidth, double SourceHeight, bool HasCamera, string? PackagePath, LoadedProject? Project = null)
{
    public static EditorSource Empty { get; } = new(null, 6000, ShowcaseProject.SourceWidth, ShowcaseProject.SourceHeight, false, null);

    public static EditorSource Package(string path, LoadedProject project) => new(
        project.Document,
        project.Metadata.DurationMs,
        project.Metadata.CaptureTarget.PixelSize.Width,
        project.Metadata.CaptureTarget.PixelSize.Height,
        project.HasRecordedCamera,
        path,
        project);
}

public sealed partial class EditorWindow : Window
{
    private const double PreviewSideMargin = 72;
    private const double PreviewEndMargin = 8;

    private static readonly (AspectRatioPreset Preset, string Name, string Ratio)[] AspectPresets =
    [
        (AspectRatioPreset.Widescreen16x9, "Wide", "16:9"),
        (AspectRatioPreset.Vertical9x16, "Vertical", "9:16"),
        (AspectRatioPreset.Square1x1, "Square", "1:1"),
        (AspectRatioPreset.Classic4x3, "Classic", "4:3"),
        (AspectRatioPreset.Tall3x4, "Tall", "3:4"),
        (AspectRatioPreset.Portrait4x5, "Portrait", "4:5"),
        (AspectRatioPreset.Mac16x10, "Display", "16:10")
    ];

    private const string CursorArrowPath = "M3,1 L3,17 L7.2,13.2 L10,19.5 L12.6,18.4 L9.8,12.2 L15.5,12 Z";

    private static readonly (InspectorTab Tab, string Glyph)[] TabIcons =
    [
        (InspectorTab.Background, ""),
        (InspectorTab.Cursor, ""),
        (InspectorTab.CameraLayout, ""),
        (InspectorTab.CameraStyle, ""),
        (InspectorTab.Captions, ""),
        (InspectorTab.Transcript, ""),
        (InspectorTab.Audio, ""),
        (InspectorTab.Shortcuts, ""),
        (InspectorTab.Zoom, ""),
        (InspectorTab.DeviceFrame, ""),
        (InspectorTab.Masks, "")
    ];

    private readonly EditorSource source;
    private readonly EditorSession session;
    private readonly DispatcherTimer clockTimer;
    private readonly DispatcherTimer toastTimer;
    private readonly DispatcherTimer saveTimer;
    private Task pendingWrite = Task.CompletedTask;
    private bool hasUnsavedChanges;
    private readonly InspectorPanel inspector;
    private readonly TimelineView timeline;
    private readonly ExportSettings exportSettings = new();
    private FrameCompositor? compositor;
    private CompositionSwapChain? swapChain;
    private PreviewRenderer? renderer;
    private VideoPlaybackSource? screenPlayback;
    private VideoPlaybackSource? webcamPlayback;
    private CancellationTokenSource? exportCancel;
    private bool closed;

    public EditorWindow(EditorSource? editorSource = null)
    {
        source = editorSource ?? EditorSource.Empty;
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppTheme.Register(this);
        Ui.SizeWindow(this, 1600, 1000, 1180, 720);

        session = new EditorSession(source.Document, source.DurationMs) { CursorEvents = source.Project?.CursorEvents ?? [], ClickEvents = source.Project?.ClickEvents ?? [], KeyEvents = source.Project?.KeyEvents ?? [] };
        inspector = new InspectorPanel(session, InspectorScroller, InspectorBody, source.HasCamera);
        timeline = new TimelineView(session, TimelineHost);

        SetTitleBar(TitleBar);
        TitleBar.SizeChanged += (_, _) => UpdateTitleBarRegions();
        TitleBar.Loaded += (_, _) =>
        {
            UpdateTitleBarRegions();
            // Keeps the first button from opening with a focus ring.
            FocusSink.Focus(FocusState.Programmatic);
        };
        TitleName.SizeChanged += (_, _) => UpdateTitleBarRegions();
        FolderButton.IsEnabled = source.PackagePath is not null;

        BuildAppMenu();
        BuildAspectMenu();
        BuildQuickDock();
        RefreshTabRail();
        RefreshChrome();
        inspector.Rebuild();
        FillCommands();

        session.DocumentChanged += DocumentChanged;
        session.SelectionChanged += SelectionChanged;
        AppTheme.Changed += ThemeChanged;
        Root.PreviewKeyDown += RootKeyDown;
        PreviewHost.SizeChanged += (_, _) => FitPreview();
        Preview.CompositionScaleChanged += (_, _) => DrawPreview();
        Preview.Loaded += AttachPreview;
        clockTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(16) };
        clockTimer.Tick += (_, _) => Sample();
        toastTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        toastTimer.Tick += (_, _) =>
        {
            toastTimer.Stop();
            Toast.Visibility = Visibility.Collapsed;
        };
        saveTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(350) };
        saveTimer.Tick += (_, _) => SaveNow();
        Closed += ReleasePreview;
    }

    // MARK: Title bar

    private void UpdateTitleBarRegions()
    {
        if (TitleBar.XamlRoot is null)
        {
            return;
        }

        var scale = TitleBar.XamlRoot.RasterizationScale;
        var rects = new[] { Region(TitleLeft, scale), Region(TitleCenter, scale), Region(TitleRight, scale) };
        InputNonClientPointerSource.GetForWindowId(AppWindow.Id).SetRegionRects(NonClientRegionKind.Passthrough, rects);
    }

    private static RectInt32 Region(FrameworkElement element, double scale)
    {
        var box = element.TransformToVisual(null).TransformBounds(new Rect(0, 0, element.ActualWidth, element.ActualHeight));
        return new RectInt32((int)(box.X * scale), (int)(box.Y * scale), (int)(box.Width * scale), (int)(box.Height * scale));
    }

    private void BeginRename(object sender, RoutedEventArgs e)
    {
        TitleEditor.Text = session.Document.Name;
        TitleButton.Visibility = Visibility.Collapsed;
        TitleEditor.Visibility = Visibility.Visible;
        TitleEditor.Focus(FocusState.Programmatic);
        TitleEditor.SelectAll();
    }

    private void CommitRename(object sender, RoutedEventArgs e)
    {
        if (TitleEditor.Visibility != Visibility.Visible)
        {
            return;
        }

        TitleEditor.Visibility = Visibility.Collapsed;
        TitleButton.Visibility = Visibility.Visible;
        var name = TitleEditor.Text.Trim();
        if (name.Length > 0 && name != session.Document.Name)
        {
            session.Rename(name);
        }
    }

    private void RenameKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            CommitRename(sender, e);
            e.Handled = true;
        }
        else if (e.Key == VirtualKey.Escape)
        {
            TitleEditor.Text = session.Document.Name;
            CommitRename(sender, e);
            e.Handled = true;
        }
    }

    private void ShowInExplorer(object sender, RoutedEventArgs e)
    {
        if (source.PackagePath is { } path)
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
        }
    }

    private void BuildAppMenu()
    {
        var file = new MenuFlyoutSubItem { Text = "File" };
        file.Items.Add(Menu("Settings", OpenSettings, "Ctrl+,"));
        var edit = new MenuFlyoutSubItem { Text = "Edit" };
        edit.Items.Add(Menu("Undo", session.Undo, "Ctrl+Z"));
        edit.Items.Add(Menu("Redo", session.Redo, "Ctrl+Shift+Z"));
        edit.Items.Add(Menu("Delete", session.DeleteSelected, "Delete"));
        var record = new MenuFlyoutSubItem { Text = "Record" };
        record.Items.Add(Menu("New recording…", null));
        var export = new MenuFlyoutSubItem { Text = "Export" };
        export.Items.Add(Menu("Export…", ShowExportOverlay, "Ctrl+E"));
        var view = new MenuFlyoutSubItem { Text = "View" };
        foreach (var (tab, _) in TabIcons)
        {
            var target = tab;
            view.Items.Add(Menu(InspectorCatalog.Title(tab), () => session.SelectTab(target), InspectorCatalog.Accelerator(tab)));
        }

        view.Items.Add(new MenuFlyoutSeparator());
        view.Items.Add(Menu("Command menu", ToggleCommandMenu, "Ctrl+K"));
        AppMenu.Items.Add(file);
        AppMenu.Items.Add(edit);
        AppMenu.Items.Add(record);
        AppMenu.Items.Add(export);
        AppMenu.Items.Add(view);
    }

    private static MenuFlyoutItem Menu(string title, Action? click, string? accelerator = null)
    {
        var item = new MenuFlyoutItem { Text = title, IsEnabled = click is not null };
        if (accelerator is not null)
        {
            item.KeyboardAcceleratorTextOverride = accelerator;
        }

        if (click is not null)
        {
            item.Click += (_, _) => click();
        }

        return item;
    }

    // MARK: Toolbar and dock

    private void BuildAspectMenu()
    {
        AspectMenu.Items.Add(Menu("Auto", () => session.Mutate(document => document.Canvas.AspectRatioMode = AspectRatioMode.Auto)));
        AspectMenu.Items.Add(new MenuFlyoutSeparator());
        foreach (var (preset, name, ratio) in AspectPresets)
        {
            var target = preset;
            AspectMenu.Items.Add(Menu($"{name}  {ratio}", () => session.Mutate(document =>
            {
                document.Canvas.AspectRatioMode = AspectRatioMode.Preset;
                document.Canvas.AspectRatioPreset = target;
            })));
        }
    }

    private void BuildQuickDock()
    {
        QuickDock.Children.Add(DockGroup(
            Ui.IconButton(Ui.Icon("", 16), "Classic zoom", () => session.AddZoomAtPlayhead(ZoomPresentation.Screen)),
            Ui.IconButton(Ui.Icon("", 16), "Loupe zoom", () => session.AddZoomAtPlayhead(ZoomPresentation.Loupe))));
        QuickDock.Children.Add(DockGroup(
            Ui.IconButton(Ui.Icon("", 16), "Sensitive data mask", () => session.AddMaskAtPlayhead(MaskType.Blur)),
            Ui.IconButton(Ui.Icon("", 16), "Highlight mask", () => session.AddMaskAtPlayhead(MaskType.Spotlight))));
        QuickDock.Children.Add(DockGroup(
            Ui.IconButton(Ui.Icon("", 16), "Add shortcut track", () => session.SelectTab(InspectorTab.Shortcuts)),
            Ui.IconButton(Ui.Icon("", 16), "Record voiceover: not available on Windows yet", null)));
    }

    private static StackPanel DockGroup(params UIElement[] buttons)
    {
        var group = new StackPanel();
        foreach (var button in buttons)
        {
            group.Children.Add(button);
        }

        return group;
    }

    private void RefreshTabRail()
    {
        TabRail.Children.Clear();
        foreach (var (tab, glyph) in TabIcons)
        {
            var target = tab;
            var selected = session.SelectedTab == tab;
            var accelerator = InspectorCatalog.Accelerator(tab);
            var tooltip = accelerator is null ? InspectorCatalog.Title(tab) : $"{InspectorCatalog.Title(tab)} ({accelerator})";
            var tint = selected ? Ui.Rgb(0.65, 0.58, 0.99) : Ui.Pal("Ink88");
            UIElement icon = glyph.Length == 0 ? Ui.Shape(CursorArrowPath, 16, tint) : Ui.Icon(glyph, 16, tint);
            var button = Ui.IconButton(icon, tooltip, () => session.SelectTab(target), 38);
            if (selected)
            {
                button.Background = Ui.Pal("Ink07");
            }

            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, InspectorCatalog.Title(tab));
            TabRail.Children.Add(button);
        }
    }

    private void RefreshChrome()
    {
        var document = session.Document;
        if (Title != document.Name)
        {
            Title = document.Name;
            TitleName.Text = document.Name;
        }

        UndoButton.IsEnabled = session.History.CanUndo;
        RedoButton.IsEnabled = session.History.CanRedo;
        TotalTime.Text = Ui.Timecode(session.DurationMs);
        CurrentTime.Text = Ui.Timecode(session.PlayheadTimelineMs);
        SplitIcon.Foreground = session.IsSplitModeActive ? Ui.Rgb(0.65, 0.58, 1) : Ui.Pal("Ink88");
        if (document.Canvas.AspectRatioMode == AspectRatioMode.Auto)
        {
            AspectName.Text = "Auto";
            AspectRatio.Text = "";
        }
        else
        {
            var match = AspectPresets.FirstOrDefault(item => item.Preset == document.Canvas.AspectRatioPreset);
            AspectName.Text = match.Name ?? "Custom";
            AspectRatio.Text = match.Ratio ?? "";
        }
    }

    private void TimelineZoomChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e) =>
        timeline?.SetZoom(e.NewValue);

    // MARK: Session events

    private void ScheduleSave()
    {
        if (source.PackagePath is null)
        {
            return;
        }

        hasUnsavedChanges = true;
        if (AppSettings.Shared.AutosaveEnabled)
        {
            saveTimer.Stop();
            saveTimer.Start();
        }
    }

    /// <summary>Serializes here so the snapshot is consistent; the file write never blocks the UI thread.</summary>
    private void SaveNow(bool waitForDisk = false)
    {
        saveTimer.Stop();
        if (source.PackagePath is not { } path || !hasUnsavedChanges)
        {
            return;
        }

        hasUnsavedChanges = false;
        var json = ProjectStore.Serialize(session.Document, DateTimeOffset.UtcNow);
        var previous = pendingWrite;
        pendingWrite = Task.Run(async () =>
        {
            await previous;
            ProjectStore.WriteProjectJson(path, json);
        });
        if (waitForDisk)
        {
            pendingWrite.Wait();
        }
        else
        {
            _ = ReportSaveFailure(pendingWrite);
        }
    }

    private async Task ReportSaveFailure(Task write)
    {
        try
        {
            await write;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            hasUnsavedChanges = true;
            ShowToast($"Could not save the project: {exception.Message}");
        }
    }

    private void DocumentChanged(bool structural)
    {
        ScheduleSave();
        RefreshChrome();
        FitPreview();
        if (structural)
        {
            inspector.Rebuild();
            timeline.Rebuild();
        }
        else
        {
            DrawPreview();
        }
    }

    private void SelectionChanged()
    {
        RefreshTabRail();
        inspector.Rebuild();
        timeline.Rebuild();
        RefreshChrome();
        DrawPreview();
    }

    private void ThemeChanged()
    {
        RefreshTabRail();
        inspector.Rebuild();
        timeline.Rebuild();
        RefreshChrome();
    }

    // MARK: Preview

    private async void AttachPreview(object sender, RoutedEventArgs e)
    {
        var built = await Task.Run(() => new FrameCompositor());
        if (closed)
        {
            built.Dispose();
            return;
        }

        compositor = built;
        var (width, height) = PreviewPixels();
        swapChain = compositor.CreateSwapChain(width, height);
        SwapChainPanelInterop.SetSwapChain(Preview, swapChain.SwapChain.NativePointer);
        renderer = new PreviewRenderer(compositor, swapChain, width, height);
        screenPlayback = OpenPlayback(source.Project?.Metadata.Tracks.DisplayVideo);
        webcamPlayback = OpenPlayback(source.Project?.Metadata.Tracks.WebcamVideo);
        FitPreview();
        DrawPreview();
    }

    private VideoPlaybackSource? OpenPlayback(string? track)
    {
        if (track is null || source.PackagePath is null)
        {
            return null;
        }

        var path = Path.Combine(source.PackagePath, "recording", track);
        if (!File.Exists(path))
        {
            return null;
        }

        try
        {
            var playback = new VideoPlaybackSource(path);
            // A seek finishes after the render thread already drew; show its frame as soon as it exists.
            playback.FrameDecoded += () => DispatcherQueue.TryEnqueue(DrawPreview);
            return playback;
        }
        catch (SharpGen.Runtime.SharpGenException exception)
        {
            ShowToast($"Could not open {track}: {exception.Message}");
            return null;
        }
    }

    private (int Width, int Height) PreviewPixels()
    {
        var width = Math.Max(2, (int)Math.Round(PreviewFrame.Width * Preview.CompositionScaleX));
        var height = Math.Max(2, (int)Math.Round(PreviewFrame.Height * Preview.CompositionScaleY));
        return double.IsNaN(PreviewFrame.Width) ? (2, 2) : (width, height);
    }

    private void FitPreview()
    {
        var availableWidth = PreviewHost.ActualWidth - PreviewSideMargin * 2;
        var availableHeight = PreviewHost.ActualHeight - PreviewEndMargin * 2;
        if (availableWidth <= 2 || availableHeight <= 2)
        {
            return;
        }

        var aspect = session.Document.Canvas.EffectiveAspectRatio(source.SourceWidth, source.SourceHeight);
        var height = Math.Min(availableHeight, availableWidth / aspect);
        PreviewFrame.Width = Math.Round(height * aspect);
        PreviewFrame.Height = Math.Round(height);
        DrawPreview();
    }

    private void DrawPreview()
    {
        if (renderer is null || double.IsNaN(PreviewFrame.Width))
        {
            return;
        }

        var (width, height) = PreviewPixels();
        var (document, trajectory) = session.RenderSnapshot();
        var request = new ComposeRequest
        {
            Document = document,
            Trajectory = trajectory,
            SourceMs = session.SourceAtPlayhead,
            ScreenSource = screenPlayback,
            WebcamSource = webcamPlayback,
            Shortcuts = session.Shortcuts(),
            ScreenWidth = (int)source.SourceWidth,
            ScreenHeight = (int)source.SourceHeight,
            HasCamera = source.HasCamera,
            PackageDirectory = source.PackagePath
        };
        renderer.Submit(request, width, height, Preview.CompositionScaleX);
    }

    private void ReleasePreview(object sender, WindowEventArgs args)
    {
        closed = true;
        exportCancel?.Cancel();
        SaveNow(waitForDisk: true);
        clockTimer.Stop();
        toastTimer.Stop();
        AppTheme.Changed -= ThemeChanged;
        renderer?.Dispose();
        screenPlayback?.Dispose();
        webcamPlayback?.Dispose();
        if (swapChain is not null)
        {
            SwapChainPanelInterop.SetSwapChain(Preview, 0);
            swapChain.Dispose();
        }

        compositor?.Dispose();
    }

    // MARK: Transport

    private void TogglePlay(object sender, RoutedEventArgs e) => TogglePlayback();

    private void TogglePlayback()
    {
        session.TogglePlayback();
        if (session.IsPlaying)
        {
            clockTimer.Start();
        }
        else
        {
            clockTimer.Stop();
        }

        RefreshTransport();
    }

    private void RefreshTransport()
    {
        PlayIcon.Glyph = session.IsPlaying ? "" : "";
        ToolTipService.SetToolTip(PlayButton, session.IsPlaying ? "Pause (Space)" : "Play (Space)");
        CurrentTime.Text = Ui.Timecode(session.PlayheadTimelineMs);
        timeline.UpdatePlayhead();
    }

    private void Sample()
    {
        session.SamplePlayhead();
        CurrentTime.Text = Ui.Timecode(session.PlayheadTimelineMs);
        timeline.UpdatePlayhead();
        DrawPreview();
        if (!session.IsPlaying)
        {
            clockTimer.Stop();
            RefreshTransport();
        }
    }

    private void JumpStart(object sender, RoutedEventArgs e) => SeekTo(0);

    private void JumpEnd(object sender, RoutedEventArgs e) => SeekTo(session.DurationMs);

    private void SeekTo(double timelineMs)
    {
        session.Scrub(timelineMs);
        clockTimer.Stop();
        RefreshTransport();
        DrawPreview();
    }

    private void ToggleSplit(object sender, RoutedEventArgs e)
    {
        session.IsSplitModeActive = !session.IsSplitModeActive;
        RefreshChrome();
    }

    private void SplitAtPlayhead()
    {
        if (!session.SplitSlice(session.PlayheadTimelineMs))
        {
            ShowToast("The part you want to cut is too short");
        }

        RefreshTransport();
    }

    private void ShowToast(string message)
    {
        ToastText.Text = message;
        Toast.Visibility = Visibility.Visible;
        toastTimer.Stop();
        toastTimer.Start();
    }

    // MARK: Keyboard

    private void RootKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var control = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(CoreVirtualKeyStates.Down);
        var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(CoreVirtualKeyStates.Down);
        var typing = Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(Root.XamlRoot) is TextBox;
        if (control)
        {
            e.Handled = HandleControlKey(e.Key, shift, typing);
            return;
        }

        if (typing)
        {
            return;
        }

        switch (e.Key)
        {
            case VirtualKey.Space:
                TogglePlayback();
                e.Handled = true;
                break;
            case VirtualKey.C:
                SplitAtPlayhead();
                e.Handled = true;
                break;
            case VirtualKey.Delete:
            case VirtualKey.Back:
                session.DeleteSelected();
                e.Handled = true;
                break;
            case VirtualKey.Escape:
                if (ExportOverlay.Visibility == Visibility.Visible)
                {
                    ExportOverlay.Visibility = Visibility.Collapsed;
                    e.Handled = true;
                }
                else if (CommandOverlay.Visibility == Visibility.Visible)
                {
                    ToggleCommandMenu();
                    e.Handled = true;
                }

                break;
        }
    }

    private bool HandleControlKey(VirtualKey key, bool shift, bool typing)
    {
        if (key is >= VirtualKey.Number0 and <= VirtualKey.Number9)
        {
            var digit = (int)key - (int)VirtualKey.Number0;
            session.SelectTab(digit == 0 ? InspectorTab.DeviceFrame : InspectorCatalog.Tabs[digit - 1]);
            return true;
        }

        switch (key)
        {
            case VirtualKey.K:
                ToggleCommandMenu();
                return true;
            case VirtualKey.E:
                ShowExportOverlay();
                return true;
            case (VirtualKey)188:
                OpenSettings();
                return true;
            case VirtualKey.Z when !typing:
                if (shift)
                {
                    session.Redo();
                }
                else
                {
                    session.Undo();
                }

                return true;
            case VirtualKey.Y when !typing:
                session.Redo();
                return true;
            default:
                return false;
        }
    }

    private void Undo(object sender, RoutedEventArgs e) => session.Undo();

    private void Redo(object sender, RoutedEventArgs e) => session.Redo();

    // MARK: Command menu

    private void ToggleCommands(object sender, RoutedEventArgs e) => ToggleCommandMenu();

    private void ToggleCommandMenu()
    {
        var open = CommandOverlay.Visibility != Visibility.Visible;
        CommandOverlay.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
        if (open)
        {
            session.OpenCommandMenu();
            CommandQuery.Text = "";
            FillCommands();
            CommandQuery.Focus(FocusState.Programmatic);
        }
        else
        {
            session.CloseCommandMenu();
        }
    }

    private void CommandOverlayTapped(object sender, TappedRoutedEventArgs e) => ToggleCommandMenu();

    private void SwallowTap(object sender, TappedRoutedEventArgs e) => e.Handled = true;

    private void QueryChanged(object sender, TextChangedEventArgs e)
    {
        session.SetCommandQuery(CommandQuery.Text);
        FillCommands();
    }

    private void CommandQueryKeyDown(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Down:
                CommandList.SelectedIndex = Math.Min(CommandList.Items.Count - 1, CommandList.SelectedIndex + 1);
                e.Handled = true;
                break;
            case VirtualKey.Up:
                CommandList.SelectedIndex = Math.Max(0, CommandList.SelectedIndex - 1);
                e.Handled = true;
                break;
            case VirtualKey.Enter:
                if (CommandList.SelectedItem is ListViewItem { Tag: EditorCommand command })
                {
                    RunCommand(command);
                }

                e.Handled = true;
                break;
            case VirtualKey.Escape:
                ToggleCommandMenu();
                e.Handled = true;
                break;
        }
    }

    private void FillCommands()
    {
        CommandList.Items.Clear();
        foreach (var command in EditorCommands.Search(session.CommandQuery))
        {
            var row = new Grid { HorizontalAlignment = HorizontalAlignment.Stretch };
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(Ui.Text(command.Title, 13, "Ink95"));
            var shortcut = Ui.Text(command.Accelerator, 12, "Ink45");
            Grid.SetColumn(shortcut, 1);
            row.Children.Add(shortcut);
            CommandList.Items.Add(new ListViewItem { Content = row, Tag = command, HorizontalContentAlignment = HorizontalAlignment.Stretch });
        }

        CommandList.SelectedIndex = CommandList.Items.Count > 0 ? 0 : -1;
    }

    private void CommandClicked(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is Grid { Parent: ListViewItem { Tag: EditorCommand command } })
        {
            RunCommand(command);
        }
    }

    private void RunCommand(EditorCommand command)
    {
        ToggleCommandMenu();
        switch (command.Id)
        {
            case "play": TogglePlayback(); break;
            case "split": SplitAtPlayhead(); break;
            case "zoom": session.AddZoomAtPlayhead(ZoomPresentation.Screen); break;
            case "loupe": session.AddZoomAtPlayhead(ZoomPresentation.Loupe); break;
            case "mask": session.AddMaskAtPlayhead(MaskType.Blur); break;
            case "highlight": session.AddMaskAtPlayhead(MaskType.Spotlight); break;
            case "delete": session.DeleteSelected(); break;
            case "undo": session.Undo(); break;
            case "redo": session.Redo(); break;
            case "export": ShowExportOverlay(); break;
            case "settings": OpenSettings(); break;
        }
    }

    // MARK: Export settings

    private void ShowExport(object sender, RoutedEventArgs e) => ShowExportOverlay();

    private void ShowExportOverlay()
    {
        exportSettings.Normalize();
        ExportBody.Children.Clear();
        ExportBody.Children.Add(Ui.Text("Export", 18, "Ink95", true));
        ExportBody.Children.Add(ExportRow("Format", ExportOptions(
            ("MP4", exportSettings.Format == ExportFormat.Mp4, () => exportSettings.Format = ExportFormat.Mp4),
            ("GIF", exportSettings.Format == ExportFormat.Gif, () => exportSettings.Format = ExportFormat.Gif))));
        ExportBody.Children.Add(ExportRow("Frame rate", ExportOptions(ExportSettings.AllowedFps(exportSettings.Format)
            .Select(fps => ($"{fps} FPS", exportSettings.Fps == fps, (Action)(() => exportSettings.Fps = fps))).ToArray())));
        ExportBody.Children.Add(ExportRow("Resolution", ExportOptions(ExportSettings.Heights(exportSettings.Format)
            .Select(height => (height == 2160 ? "4K" : $"{height}p", exportSettings.ResolutionHeight == height, (Action)(() => exportSettings.ResolutionHeight = height))).ToArray())));
        if (exportSettings.Format == ExportFormat.Mp4)
        {
            ExportBody.Children.Add(ExportRow("Compression", ExportOptions(
                ("Studio", exportSettings.Compression == ExportCompression.Studio, () => exportSettings.Compression = ExportCompression.Studio),
                ("Social Media", exportSettings.Compression == ExportCompression.SocialMedia, () => exportSettings.Compression = ExportCompression.SocialMedia),
                ("Web", exportSettings.Compression == ExportCompression.Web, () => exportSettings.Compression = ExportCompression.Web),
                ("Web (Low)", exportSettings.Compression == ExportCompression.WebLow, () => exportSettings.Compression = ExportCompression.WebLow))));
        }

        var aspect = session.Document.Canvas.EffectiveAspectRatio(source.SourceWidth, source.SourceHeight);
        var (outputWidth, outputHeight) = exportSettings.OutputSize(aspect);
        var size = ExportEstimator.SizeString(exportSettings, aspect, session.DurationMs);
        var time = ExportEstimator.DurationString(exportSettings, aspect, session.DurationMs);
        ExportBody.Children.Add(Ui.Text($"{outputWidth} × {outputHeight}  ·  Estimation: export time {time}, output size {size}", 12.5, "Ink60"));

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = Ui.Option("Cancel", false, () => ExportOverlay.Visibility = Visibility.Collapsed);
        var start = new Button { Style = Ui.StyleOf("NsPrimaryButton"), Content = "Export" };
        start.Click += (_, _) => _ = StartExport();
        buttons.Children.Add(cancel);
        buttons.Children.Add(start);
        ExportBody.Children.Add(buttons);
        ExportOverlay.Visibility = Visibility.Visible;
    }

    private async Task StartExport()
    {
        var gif = exportSettings.Format == ExportFormat.Gif;
        var picker = new Windows.Storage.Pickers.FileSavePicker { SuggestedFileName = session.Document.Name };
        picker.FileTypeChoices.Add(gif ? "GIF" : "MP4", new List<string> { gif ? ".gif" : ".mp4" });
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        var file = await picker.PickSaveFileAsync();
        if (file is null)
        {
            return;
        }

        var cancel = new CancellationTokenSource();
        exportCancel = cancel;
        var started = DateTime.UtcNow;
        ExportBody.Children.Clear();
        var title = Ui.Text("Exporting video • 0%", 18, "Ink95", true);
        var bar = new ProgressBar { Minimum = 0, Maximum = 1, Value = 0 };
        var time = Ui.Text("Preparing export...", 12.5, "Ink60");
        var stop = Ui.Option("Stop export", false, cancel.Cancel);
        ExportBody.Children.Add(title);
        ExportBody.Children.Add(bar);
        ExportBody.Children.Add(time);
        ExportBody.Children.Add(stop);
        var progress = new Progress<ExportProgress>(update =>
        {
            var share = update.Encoded / (double)Math.Max(1, update.Total);
            bar.Value = share;
            title.Text = $"Exporting video • {share:P0}";
            var elapsed = DateTime.UtcNow - started;
            var left = share > 0 ? elapsed * (1 / share - 1) : TimeSpan.Zero;
            time.Text = $"{(int)elapsed.TotalMinutes:00}:{elapsed.Seconds:00} • {(int)left.TotalMinutes:00}:{left.Seconds:00} left";
        });
        var (document, _) = session.RenderSnapshot();
        var exporter = new ProjectExporter(new ExportSource(
            document,
            source.PackagePath,
            source.Project?.Metadata.Tracks ?? new RecordingTracksMetadata(),
            source.DurationMs,
            source.SourceWidth,
            source.SourceHeight,
            source.HasCamera,
            session.CursorEvents,
            session.ClickEvents,
            session.Shortcuts()));
        try
        {
            await exporter.RunAsync(file.Path, exportSettings, progress, cancel.Token);
            ShowToast($"Exported {file.Name}");
        }
        catch (OperationCanceledException)
        {
            ShowToast("Export stopped");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or SharpGen.Runtime.SharpGenException)
        {
            ShowToast($"Export failed: {exception.Message}");
        }
        finally
        {
            exportCancel = null;
            cancel.Dispose();
            ExportOverlay.Visibility = Visibility.Collapsed;
        }
    }

    private static Grid ExportRow(string title, UIElement options)
    {
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120) });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.Children.Add(Ui.Text(title, 13, "Ink88"));
        Grid.SetColumn(options as FrameworkElement, 1);
        row.Children.Add(options);
        return row;
    }

    private StackPanel ExportOptions(params (string Title, bool Selected, Action Change)[] options)
    {
        var stack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        foreach (var (title, selected, change) in options)
        {
            var apply = change;
            stack.Children.Add(Ui.Option(title, selected, () =>
            {
                apply();
                ShowExportOverlay();
            }));
        }

        return stack;
    }

    private void OpenSettings()
    {
        var settings = new SettingsWindow();
        settings.Activate();
    }
}
