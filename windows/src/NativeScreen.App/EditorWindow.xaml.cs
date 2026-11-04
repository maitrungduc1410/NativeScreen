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
    private readonly Dictionary<InspectorTab, MenuFlyoutItem> viewMenuItems = [];
    private int railAvailability;
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
    private readonly EditorTools tools;
    private readonly TimelineView timeline;
    private readonly PreviewOverlay overlay;
    private readonly ExportSettings exportSettings = new();
    private readonly ClickSounds clickSounds = new();
    private FrameCompositor? compositor;
    private CompositionSwapChain? swapChain;
    private PreviewRenderer? renderer;
    private VideoPlaybackSource? screenPlayback;
    private VideoPlaybackSource? webcamPlayback;
    private CancellationTokenSource? exportCancel;
    private PreviewAudioPlayer? audio;
    private ProjectDocument? audioDocument;
    private int playRequest;
    private bool closed;

    public EditorWindow(EditorSource? editorSource = null)
    {
        source = editorSource ?? EditorSource.Empty;
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppTheme.Register(this);
        Ui.SizeWindow(this, 1600, 1000, 1180, 720);

        session = new EditorSession(source.Document, source.DurationMs) { HasRecordedCamera = source.HasCamera, HasMicrophoneTrack = source.Project?.Metadata.Tracks.MicrophoneAudio is not null, CursorEvents = source.Project?.CursorEvents ?? [], ClickEvents = source.Project?.ClickEvents ?? [], KeyEvents = source.Project?.KeyEvents ?? [], KeycapStyle = source.Project is { } opened ? WindowsKeycaps.StyleFor(opened.Metadata.Platform) : KeycapStyle.Windows };
        tools = new EditorTools(this, session, source, ShowToast);
        tools.StartPlayback = () => session.IsPlaying ? Task.CompletedTask : TogglePlaybackAsync();
        tools.PausePlayback = () =>
        {
            if (session.IsPlaying)
            {
                TogglePlayback();
            }
        };
        inspector = new InspectorPanel(session, InspectorScroller, InspectorBody, source.HasCamera, tools);
        tools.Changed += inspector.Rebuild;
        inspector.SeekRequested = SeekTo;
        inspector.CameraCropRequested = OpenCameraCrop;
        timeline = new TimelineView(session, TimelineHost) { Tools = tools };
        session.ToastRequested += ShowToast;
        timeline.Skimmed += DrawPreview;
        timeline.ZoomNudged += ZoomTimeline;
        overlay = new PreviewOverlay(session, PreviewCanvas, () => (source.SourceWidth, source.SourceHeight, source.HasCamera));
        PreviewCanvas.SizeChanged += (_, _) => overlay.Refresh();

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
        RemoveButton.IsEnabled = source.PackagePath is not null;
        Root.Loaded += (_, _) => tools.XamlRoot = Root.XamlRoot;
        _ = LoadWaveform();

        BuildAppMenu();
        BuildAspectMenu();
        BuildQuickDock();
        RefreshTabRail();
        RefreshChrome();
        inspector.Rebuild();

        session.DocumentChanged += DocumentChanged;
        Closed += (_, _) =>
        {
            tools.FinishVoiceoverRecordingForClose();
            tools.CancelTranscript();
            clickSounds.Dispose();
        };
        session.SelectionChanged += SelectionChanged;
        // Alt+Tab takes the key's release to another window.
        Activated += (_, args) =>
        {
            if (args.WindowActivationState == WindowActivationState.Deactivated)
            {
                EndHeldSplit();
            }
        };
        AppTheme.Changed += ThemeChanged;
        Root.PreviewKeyDown += RootKeyDown;
        Root.PreviewKeyUp += RootKeyUp;
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
        timeline.PlayheadScrubbed += () =>
        {
            playRequest++;
            clockTimer.Stop();
            StopAudio();
            RefreshTransport();
            DrawPreview();
        };
        Closed += ReleasePreview;
        Closed += (_, _) => App.EditorClosed();
        App.EditorOpened();
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
        file.Items.Add(Menu("Open project", () => _ = OpenProjectCommand()));
        file.Items.Add(RecentMenu());
        file.Items.Add(Menu("Create project from video", () => _ = ImportVideoCommand()));
        file.Items.Add(Menu("Create interactive showcase project", () => _ = Projects.Open(ShowcaseProject.WritePackage(AppSettings.Shared.ProjectsDirectory), Root.XamlRoot)));
        file.Items.Add(Menu("Import preset", () => _ = ImportPreset()));
        file.Items.Add(new MenuFlyoutSeparator());
        file.Items.Add(Menu("Save", source.PackagePath is null ? null : SaveCommand, "Ctrl+S"));
        file.Items.Add(Menu("Save as", source.PackagePath is null ? null : SaveAsCommand));
        file.Items.Add(new MenuFlyoutSeparator());
        file.Items.Add(Menu("Settings", OpenSettings, "Ctrl+,"));
        var edit = new MenuFlyoutSubItem { Text = "Edit" };
        edit.Items.Add(Menu("Undo", session.Undo, "Ctrl+Z"));
        edit.Items.Add(Menu("Redo", session.Redo, "Ctrl+Shift+Z"));
        edit.Items.Add(Menu("Delete", session.DeleteSelected, "Delete"));
        edit.Items.Add(new MenuFlyoutSeparator());
        edit.Items.Add(Menu("Cut", () => HandleSelectionControlKey(VirtualKey.X), "Ctrl+X"));
        edit.Items.Add(Menu("Copy", () => HandleSelectionControlKey(VirtualKey.C), "Ctrl+C"));
        edit.Items.Add(Menu("Paste", session.PasteFromClipboard, "Ctrl+V"));
        var record = new MenuFlyoutSubItem { Text = "Record" };
        record.Items.Add(Menu("New recording", () => RecordingHudWindow.Show()));
        record.Items.Add(Menu("Record display", () => RecordingHudWindow.Show(CaptureTargetMode.Display)));
        record.Items.Add(Menu("Record window", () => RecordingHudWindow.Show(CaptureTargetMode.Window)));
        record.Items.Add(Menu("Record area", () => RecordingHudWindow.Show(CaptureTargetMode.Area)));
        record.Items.Add(Menu("Record this project window", () => RecordingHudWindow.RecordWindow(WinRT.Interop.WindowNative.GetWindowHandle(this))));
        var export = new MenuFlyoutSubItem { Text = "Export" };
        export.Items.Add(Menu("Export", ShowExportOverlay, "Ctrl+E"));
        export.Items.Add(Menu("Quick export to clipboard", () => _ = QuickExportToClipboard()));
        export.Items.Add(Menu("Export current frame as image", ShowFrameExportOverlay));
        export.Items.Add(Menu("Extract raw recording files", source.PackagePath is null ? null : () => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", $"\"{Path.Combine(source.PackagePath, "recording")}\"") { UseShellExecute = true })));
        var view = new MenuFlyoutSubItem { Text = "View" };
        foreach (var (tab, _) in TabIcons)
        {
            var target = tab;
            var item = Menu(InspectorCatalog.Title(tab), () => session.SelectTab(target), InspectorCatalog.Accelerator(tab));
            item.IsEnabled = session.TabAvailability(tab).CanApply;
            viewMenuItems[tab] = item;
            view.Items.Add(item);
        }

        view.Items.Add(new MenuFlyoutSeparator());
        var showWaveform = new ToggleMenuFlyoutItem { Text = "Show audio waveform", IsChecked = AppSettings.Shared.ShowAudioWaveform };
        var smoothWaveform = new ToggleMenuFlyoutItem { Text = "Smooth waveform", IsChecked = AppSettings.Shared.SmoothWaveform, IsEnabled = AppSettings.Shared.ShowAudioWaveform };
        showWaveform.Click += (_, _) =>
        {
            AppSettings.Shared.ShowAudioWaveform = showWaveform.IsChecked;
            AppSettings.Shared.Save();
            smoothWaveform.IsEnabled = showWaveform.IsChecked;
            timeline.Rebuild();
        };
        smoothWaveform.Click += (_, _) =>
        {
            AppSettings.Shared.SmoothWaveform = smoothWaveform.IsChecked;
            AppSettings.Shared.Save();
            timeline.Rebuild();
        };
        view.Items.Add(showWaveform);
        view.Items.Add(smoothWaveform);
        view.Items.Add(new MenuFlyoutSeparator());
        view.Items.Add(Menu("Show safe zones for short videos", () =>
        {
            overlay.ShowSafeZones = !overlay.ShowSafeZones;
            overlay.Refresh();
        }));
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

    private void BeginMaskDraw(MaskType type)
    {
        if (session.IsPlaying)
        {
            TogglePlayback();
        }

        session.BeginInteractiveMaskSelection(type);
    }

    private const double DockActiveFillOpacity = 0.24;
    private readonly List<(MaskType Type, Button Button, FontIcon Icon)> maskDockButtons = [];
    private Button? voiceoverDockButton;
    private FontIcon? voiceoverDockIcon;

    private Button MaskDockButton(string glyph, string tooltip, MaskType type)
    {
        var icon = Ui.Icon(glyph, 16);
        var button = Ui.IconButton(icon, tooltip, () => BeginMaskDraw(type));
        maskDockButtons.Add((type, button, icon));
        return button;
    }

    /// <summary>While a mask is waiting to be drawn its button stays lit, so it is clear why the preview is taking the pointer.</summary>
    private void RefreshVoiceoverDock()
    {
        if (voiceoverDockButton is null || voiceoverDockIcon is null)
        {
            return;
        }

        var recording = session.IsRecordingVoiceover;
        HoverMagnet.SetIsActive(voiceoverDockButton, recording);
        voiceoverDockIcon.Glyph = recording ? "\uE71A" : "\uE720";
        var tooltip = recording ? "Stop voiceover recording" : "Record voiceover";
        ToolTipService.SetToolTip(voiceoverDockButton, tooltip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(voiceoverDockButton, tooltip);
        if (recording)
        {
            voiceoverDockButton.Background = Ui.Rgb(0.45, 0.36, 0.96, DockActiveFillOpacity);
            voiceoverDockIcon.Foreground = Ui.Rgb(0.72, 0.64, 1);
        }
        else
        {
            voiceoverDockButton.ClearValue(Control.BackgroundProperty);
            voiceoverDockIcon.Foreground = Ui.Pal("Ink88");
        }
    }

    private void RefreshMaskDock()
    {
        foreach (var (type, button, icon) in maskDockButtons)
        {
            HoverMagnet.SetIsActive(button, session.PendingAddMaskType == type);
            if (session.PendingAddMaskType == type)
            {
                button.Background = Ui.Rgb(0.45, 0.36, 0.96, DockActiveFillOpacity);
                icon.Foreground = Ui.Rgb(0.72, 0.64, 1);
            }
            else
            {
                button.ClearValue(Control.BackgroundProperty);
                icon.Foreground = Ui.Pal("Ink88");
            }
        }
    }

    private void BuildQuickDock()
    {
        QuickDock.Children.Add(DockGroup(
            Ui.IconButton(Ui.Icon("", 16), "Classic zoom", () => session.AddZoomAtPlayhead(ZoomPresentation.Screen)),
            Ui.IconButton(Ui.Icon("", 16), "Loupe zoom", () => session.AddZoomAtPlayhead(ZoomPresentation.Loupe))));
        if (source.HasCamera)
        {
            QuickDock.Children.Add(DockGroup(
                Ui.IconButton(Ui.Icon("", 16), "Camera overlay layout", () => session.AddCameraLayoutAtPlayhead(CameraTimelineLayoutType.CameraOverlay)),
                Ui.IconButton(Ui.Icon("", 16), "Split screen layout", () => session.AddCameraLayoutAtPlayhead(CameraTimelineLayoutType.SplitScreen)),
                Ui.IconButton(Ui.Icon("", 16), "Camera cutout layout", () => session.AddCameraLayoutAtPlayhead(CameraTimelineLayoutType.CutoutCamera)),
                Ui.IconButton(Ui.Icon("", 16), "Fullscreen camera layout", () => session.AddCameraLayoutAtPlayhead(CameraTimelineLayoutType.FullscreenCamera)),
                Ui.IconButton(Ui.Icon("", 16), "Only screen layout", () => session.AddCameraLayoutAtPlayhead(CameraTimelineLayoutType.ScreenOnly))));
        }

        QuickDock.Children.Add(DockGroup(
            MaskDockButton("", "Sensitive data mask", MaskType.Blur),
            MaskDockButton("", "Highlight mask", MaskType.Spotlight)));
        QuickDock.Children.Add(DockGroup(
            Ui.IconButton(Ui.Icon("", 16), "Add shortcut", () => session.AddCustomShortcut(null, session.SourceAtPlayhead)),
            Ui.IconButton(Ui.Icon("\uE8BD", 16), "Add caption track", () => session.AddCaptionTrack()),
            VoiceoverDockButton()));
    }

    private Button VoiceoverDockButton()
    {
        voiceoverDockIcon = Ui.Icon("\uE720", 16);
        voiceoverDockButton = Ui.IconButton(voiceoverDockIcon, "Record voiceover", tools.ToggleVoiceoverRecording);
        return voiceoverDockButton;
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
        railAvailability = 0;
        foreach (var (tab, glyph) in TabIcons)
        {
            var target = tab;
            var (canApply, disabledTooltip) = session.TabAvailability(tab);
            var selected = session.SelectedTab == tab && canApply;
            var accelerator = InspectorCatalog.Accelerator(tab);
            var tooltip = !canApply
                ? disabledTooltip ?? InspectorCatalog.Title(tab)
                : accelerator is null ? InspectorCatalog.Title(tab) : $"{InspectorCatalog.Title(tab)} ({accelerator})";
            var tint = selected ? Ui.Rgb(0.65, 0.58, 0.99) : Ui.Pal("Ink88");
            UIElement icon = glyph.Length == 0 ? Ui.Shape(CursorArrowPath, 16, tint) : Ui.Icon(glyph, 16, tint);
            // Stays enabled, because a disabled button shows no tooltip and the tooltip says why the tab is off.
            icon.Opacity = canApply ? 1 : 0.28;
            var button = Ui.IconButton(icon, tooltip, () =>
            {
                if (session.TabAvailability(target).CanApply)
                {
                    session.SelectTab(target);
                }
            }, 38);
            button.IsTabStop = canApply;
            if (selected)
            {
                button.Background = Ui.Pal("Ink07");
            }

            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, InspectorCatalog.Title(tab));
            TabRail.Children.Add(button);
            railAvailability = railAvailability * 2 + (canApply ? 1 : 0);
            if (viewMenuItems.TryGetValue(tab, out var item))
            {
                item.IsEnabled = canApply;
            }
        }
    }

    private int CurrentTabAvailability() =>
        TabIcons.Aggregate(0, (bits, entry) => bits * 2 + (session.TabAvailability(entry.Item1).CanApply ? 1 : 0));

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
        HoverMagnet.SetIsActive(SplitButton, session.IsSplitModeActive);
        if (session.IsSplitModeActive)
        {
            SplitButton.Background = Ui.Rgb(0.45, 0.36, 0.96, DockActiveFillOpacity);
        }
        else
        {
            SplitButton.ClearValue(Control.BackgroundProperty);
        }

        timeline.RefreshSplitMode();
        RefreshMaskDock();
        RefreshVoiceoverDock();
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
        if (CurrentTabAvailability() != railAvailability)
        {
            RefreshTabRail();
        }

        RefreshChrome();
        FitPreview();
        if (structural)
        {
            inspector.Rebuild();
            timeline.Rebuild();
            _ = LoadVoiceoverWaveforms();
        }
        else
        {
            timeline.RefreshWaveformVolumes();
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
        overlay.ShortcutHits = () => compositor.ShortcutHitRects01;
        overlay.CaptionHits = () => compositor.CaptionHitRects01;
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
        if (!session.IsPlaying)
        {
            overlay.Refresh();
        }

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
            SourceMs = session.DisplaySourceMs,
            ScreenSource = screenPlayback,
            WebcamSource = webcamPlayback,
            Shortcuts = session.Shortcuts(),
            ScreenWidth = (int)source.SourceWidth,
            ScreenHeight = (int)source.SourceHeight,
            HasCamera = source.HasCamera,
            PackageDirectory = source.PackagePath
        };
        renderer.Submit(request, width, height, Preview.CompositionScaleX, session.LiveSourceClock());
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
        if (audio is { } player)
        {
            audio = null;
            _ = Task.Run(player.Dispose);
        }

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

    private async void TogglePlayback() => await TogglePlaybackAsync();

    private async Task TogglePlaybackAsync()
    {
        var request = ++playRequest;
        if (session.IsPlaying)
        {
            session.TogglePlayback();
            clockTimer.Stop();
            StopAudio();
            RefreshTransport();
            DrawPreview();
            return;
        }

        // Priming opens and decodes files, so it runs off the UI thread and the clock starts only when sound is ready.
        var (document, _) = session.RenderSnapshot();
        var start = session.PlayheadTimelineMs >= session.DurationMs ? 0 : session.PlayheadTimelineMs;
        var player = audio;
        var stale = audioDocument;
        audioDocument = document;
        audio = null;
        var ready = await Task.Run(() =>
        {
            var next = player;
            if (next is null || !ReferenceEquals(stale, document))
            {
                next?.Dispose();
                next = PreviewAudioPlayer.TryCreate(document, source.PackagePath, source.Project?.Metadata.Tracks ?? new RecordingTracksMetadata());
            }

            next?.Prime(start);
            return next;
        });
        audio = ready;
        if (closed)
        {
            audio = null;
            ready?.Dispose();
            return;
        }

        if (request != playRequest)
        {
            return;
        }

        audio?.Start();
        session.TogglePlayback();
        clockTimer.Start();
        overlay.Refresh();
        DrawPreview();
        RefreshTransport();
    }

    private void StopAudio()
    {
        if (audio is { } player)
        {
            _ = Task.Run(player.Pause);
        }
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
        if (audio?.HeardTimelineMs is { } heard)
        {
            session.SyncToAudio(heard);
        }

        session.SamplePlayhead();
        clickSounds.Advance(session);
        CurrentTime.Text = Ui.Timecode(session.PlayheadTimelineMs);
        timeline.UpdatePlayhead();
        if (!session.IsPlaying)
        {
            clickSounds.Rewind();
            clockTimer.Stop();
            StopAudio();
            RefreshTransport();
            DrawPreview();
        }
    }

    private void JumpStart(object sender, RoutedEventArgs e) => SeekTo(0);

    private void JumpEnd(object sender, RoutedEventArgs e) => SeekTo(session.DurationMs);

    private void SeekTo(double timelineMs)
    {
        playRequest++;
        session.Scrub(timelineMs);
        clockTimer.Stop();
        StopAudio();
        RefreshTransport();
        DrawPreview();
    }

    private void ToggleSplit(object sender, RoutedEventArgs e)
    {
        altHeldForSplit = false;
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

    private bool altHeldForSplit;

    private void RootKeyUp(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key is VirtualKey.Menu or VirtualKey.LeftMenu or VirtualKey.RightMenu && altHeldForSplit)
        {
            EndHeldSplit();
        }
    }

    private void EndHeldSplit()
    {
        if (altHeldForSplit)
        {
            altHeldForSplit = false;
            session.IsSplitModeActive = false;
            RefreshChrome();
        }
    }

    private void RootKeyDown(object sender, KeyRoutedEventArgs e)
    {
        // Holding Alt alone is the temporary split tool; any other key makes it a shortcut instead.
        if (e.Key is VirtualKey.Menu or VirtualKey.LeftMenu or VirtualKey.RightMenu)
        {
            if (!session.IsSplitModeActive && Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(Root.XamlRoot) is not TextBox)
            {
                altHeldForSplit = true;
                session.IsSplitModeActive = true;
                RefreshChrome();
            }
        }
        else
        {
            EndHeldSplit();
        }

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
                session.SplitAtCurrentTime();
                RefreshTransport();
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
                    if (exportCancel is null && !stillBusy)
                    {
                        ExportOverlay.Visibility = Visibility.Collapsed;
                    }

                    e.Handled = true;
                }
                else if (CommandOverlay.Visibility == Visibility.Visible)
                {
                    ToggleCommandMenu();
                    e.Handled = true;
                }
                else if (session.PendingAddMaskType is not null)
                {
                    session.CancelInteractiveMaskSelection();
                    e.Handled = true;
                }
                else
                {
                    altHeldForSplit = false;
                    session.IsSplitModeActive = false;
                    session.ClearSelection();
                    RefreshChrome();
                    e.Handled = true;
                }

                break;
            case VirtualKey.H:
                session.Mutate(document => document.Camera.Enabled = !document.Camera.Enabled);
                e.Handled = true;
                break;
            default:
                if (ExportOverlay.Visibility != Visibility.Visible && CommandOverlay.Visibility != Visibility.Visible)
                {
                    e.Handled = HandleEditorKey(e.Key);
                }

                break;
        }
    }

    private bool HandleControlKey(VirtualKey key, bool shift, bool typing)
    {
        if (key is >= VirtualKey.Number0 and <= VirtualKey.Number9)
        {
            var digit = (int)key - (int)VirtualKey.Number0;
            var tab = digit == 0 ? InspectorTab.DeviceFrame : InspectorCatalog.Tabs[digit - 1];
            if (session.TabAvailability(tab).CanApply)
            {
                session.SelectTab(tab);
            }

            return true;
        }

        switch (key)
        {
            case VirtualKey.K:
                ToggleCommandMenu();
                return true;
            case VirtualKey.S:
                SaveCommand();
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
            case VirtualKey.O when shift && source.PackagePath is not null:
                ShowInExplorer(this, new RoutedEventArgs());
                return true;
            default:
                return !typing && HandleSelectionControlKey(key);
        }
    }

    private void Undo(object sender, RoutedEventArgs e) => session.Undo();

    private void Redo(object sender, RoutedEventArgs e) => session.Redo();

    private MenuFlyoutSubItem RecentMenu()
    {
        var menu = new MenuFlyoutSubItem { Text = "Open recent" };
        foreach (var path in AppSettings.Shared.RecentProjects)
        {
            var target = path;
            menu.Items.Add(Menu(Path.GetFileNameWithoutExtension(path), () => _ = Projects.Open(target, Root.XamlRoot)));
        }

        menu.IsEnabled = menu.Items.Count > 0;
        return menu;
    }

    private async Task OpenProjectCommand()
    {
        var picker = new Windows.Storage.Pickers.FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (await picker.PickSingleFolderAsync() is { } folder)
        {
            await Projects.Open(folder.Path, Root.XamlRoot);
        }
    }

    private async Task ImportVideoCommand()
    {
        if (await tools.PickFile(".mp4", ".mov", ".m4v", ".mkv", ".wmv") is { } file)
        {
            await Projects.ImportVideo(file, Root.XamlRoot);
        }
    }

    private void OpenSettings()
    {
        var settings = new SettingsWindow();
        settings.Activate();
    }
}
