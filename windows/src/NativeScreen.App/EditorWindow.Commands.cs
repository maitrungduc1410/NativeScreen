using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using NativeScreen.Core;
using Windows.System;
using ZoomMode = NativeScreen.Core.ZoomMode;

namespace NativeScreen.App;

/// <summary>The searchable command menu and its keyboard shortcuts, the same groups and rows as CommandMenuOverlay on macOS.</summary>
public sealed partial class EditorWindow
{
    private const double TimelineZoomStep = 1.25;
    private static readonly Brush CommandDestructive = Ui.Rgb(1, 0.35, 0.32);

    private readonly List<(CommandItem Item, Border Row)> commandRows = [];
    private List<CommandItem> commandItems = [];
    private int highlightedCommand;

    private sealed record CommandItem(string Group, string Title, string Glyph, Action Run, string? Badge, bool Destructive);

    private void ToggleCommands(object sender, RoutedEventArgs e) => ToggleCommandMenu();

    private void ToggleCommandMenu()
    {
        var open = CommandOverlay.Visibility != Visibility.Visible;
        CommandOverlay.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
        if (open)
        {
            commandItems = BuildCommands();
            CommandQuery.Text = "";
            FillCommands();
            CommandQuery.Focus(FocusState.Programmatic);
        }
    }

    private void CommandOverlayTapped(object sender, TappedRoutedEventArgs e) => ToggleCommandMenu();

    private void SwallowTap(object sender, TappedRoutedEventArgs e) => e.Handled = true;

    private void QueryChanged(object sender, TextChangedEventArgs e) => FillCommands();

    private void CommandQueryKeyDown(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Down:
                HighlightCommand(highlightedCommand + 1);
                e.Handled = true;
                break;
            case VirtualKey.Up:
                HighlightCommand(highlightedCommand - 1);
                e.Handled = true;
                break;
            case VirtualKey.Enter:
                if (highlightedCommand < commandRows.Count)
                {
                    RunCommand(commandRows[highlightedCommand].Item);
                }

                e.Handled = true;
                break;
            case VirtualKey.Escape:
                ToggleCommandMenu();
                e.Handled = true;
                break;
        }
    }

    private void RunCommand(CommandItem item)
    {
        ToggleCommandMenu();
        item.Run();
        RefreshTransport();
    }

    private void HighlightCommand(int index)
    {
        if (commandRows.Count == 0)
        {
            return;
        }

        highlightedCommand = Math.Clamp(index, 0, commandRows.Count - 1);
        for (var row = 0; row < commandRows.Count; row++)
        {
            commandRows[row].Row.Background = row == highlightedCommand ? Ui.Pal("Ink14") : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        }

        commandRows[highlightedCommand].Row.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false });
    }

    private void FillCommands()
    {
        var query = CommandQuery.Text.Trim();
        CommandRows.Children.Clear();
        commandRows.Clear();
        var shown = commandItems.Where(item => query.Length == 0
            || item.Title.Contains(query, StringComparison.OrdinalIgnoreCase)
            || item.Group.Contains(query, StringComparison.OrdinalIgnoreCase));
        foreach (var group in shown.GroupBy(item => item.Group))
        {
            if (CommandRows.Children.Count > 0)
            {
                CommandRows.Children.Add(new Border { Height = 1, Margin = new Thickness(4, 6, 4, 6), Background = Ui.Pal("Ink10") });
            }

            CommandRows.Children.Add(new TextBlock { Text = group.Key, FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.Medium, Foreground = Ui.Pal("Ink45"), Margin = new Thickness(10, 4, 10, 4) });
            foreach (var item in group)
            {
                var row = CommandRow(item);
                commandRows.Add((item, row));
                CommandRows.Children.Add(row);
            }
        }

        if (commandRows.Count == 0)
        {
            CommandRows.Children.Add(new TextBlock { Text = "No commands found", FontSize = 13.5, Foreground = Ui.Pal("Ink45"), Margin = new Thickness(10, 12, 10, 12) });
        }

        HighlightCommand(0);
    }

    private Border CommandRow(CommandItem item)
    {
        var ink = item.Destructive ? CommandDestructive : Ui.Pal("Ink95");
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(Ui.Icon(item.Glyph, 14, item.Destructive ? CommandDestructive : Ui.Pal("Ink60")));
        var title = new TextBlock { Text = item.Title, FontSize = 13.5, VerticalAlignment = VerticalAlignment.Center, Foreground = ink, TextTrimming = TextTrimming.CharacterEllipsis };
        Grid.SetColumn(title, 1);
        grid.Children.Add(title);
        if (item.Badge is not null)
        {
            var badge = new Border
            {
                Padding = new Thickness(6, 1, 6, 2),
                CornerRadius = new CornerRadius(5),
                Background = Ui.Pal("Ink07"),
                BorderBrush = Ui.Pal("Ink10"),
                BorderThickness = new Thickness(1),
                VerticalAlignment = VerticalAlignment.Center,
                Child = new TextBlock { Text = item.Badge, FontSize = 11.5, FontWeight = Microsoft.UI.Text.FontWeights.Medium, Foreground = Ui.Pal("Ink60") }
            };
            Grid.SetColumn(badge, 2);
            grid.Children.Add(badge);
        }

        var row = new Border { Height = 40, Padding = new Thickness(10, 0, 10, 0), CornerRadius = new CornerRadius(8), Child = grid };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(row, item.Title);
        row.PointerEntered += (_, _) =>
        {
            var index = commandRows.FindIndex(entry => entry.Row == row);
            if (index >= 0)
            {
                highlightedCommand = index;
                for (var other = 0; other < commandRows.Count; other++)
                {
                    commandRows[other].Row.Background = other == index ? Ui.Pal("Ink14") : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
                }
            }
        };
        row.Tapped += (_, args) =>
        {
            args.Handled = true;
            RunCommand(item);
        };
        return row;
    }

    private List<CommandItem> BuildCommands()
    {
        var items = new List<CommandItem>();
        void Add(string group, string title, string glyph, Action run, string? badge = null, bool destructive = false) =>
            items.Add(new CommandItem(group, title, glyph, run, badge, destructive));

        var document = session.Document;
        var timeline = document.Timeline;

        Add("Playback", "Play/Pause", "", TogglePlayback, "Space");
        Add("Playback", "Go to first frame", "", () => SeekTo(0), "Ctrl+Left");
        Add("Playback", "Go to last frame", "", () => SeekTo(session.DurationMs), "Ctrl+Right");
        Add("Playback", "Move backwards", "", () => StepPlayhead(-1000, -1000.0 / 60), "Left");
        Add("Playback", "Move backwards fast", "", () => StepPlayhead(-2000, -2000), "Shift+Left");
        Add("Playback", "Move forwards", "", () => StepPlayhead(500, 1000.0 / 60), "Right");
        Add("Playback", "Move forwards fast", "", () => StepPlayhead(1000, 1000), "Shift+Right");
        Add("Playback", "Zoom in timeline", "", () => ZoomTimeline(TimelineZoomStep), "Ctrl+=");
        Add("Playback", "Zoom out timeline", "", () => ZoomTimeline(1 / TimelineZoomStep), "Ctrl+-");

        if (session.History.CanUndo)
        {
            Add("Editor", "Undo", "", session.Undo, "Ctrl+Z");
        }

        if (session.History.CanRedo)
        {
            Add("Editor", "Redo", "", session.Redo, "Ctrl+Y");
        }

        var dark = AppTheme.Current != ElementTheme.Light;
        Add("Editor", dark ? "Switch to light appearance" : "Switch to dark appearance", "", () => AppTheme.Set(dark ? ElementTheme.Light : ElementTheme.Dark));
        Add("Editor", "Toggle split", "", () => ToggleSplit(this, new RoutedEventArgs()), "Alt");
        Add("Editor", "Split at current time", "", SplitAtPlayhead, "C");
        Add("Editor", "Crop", "", () => OpenCrop(this, new RoutedEventArgs()));

        Add("Zoom", "Add zoom at current time", "", () => session.AddZoomAtPlayhead(ZoomPresentation.Screen));
        if (session.SelectedZoomId is { } zoomId && timeline.Zooms.Find(item => item.Id == zoomId) is { } zoom)
        {
            Add("Zoom", "Duplicate zoom", "", () => session.DuplicateZoom(zoomId), "Ctrl+D");
            Add("Zoom", "Toggle zoom loupe mode", "", () => ToggleZoomLoupe(zoomId), "L");
            Add("Zoom", "Set zoom type to Auto", "", () => session.SetZoomMode(zoomId, ZoomMode.FollowCursor), "A");
            Add("Zoom", "Set zoom type to Manual", "", () => session.SetZoomMode(zoomId, ZoomMode.Manual), "M");
            Add("Zoom", "Apply zoom level to all other zooms", "", () => session.ApplyZoomLevelToAll(zoomId));
            Add("Zoom", zoom.Disabled ? "Enable zoom" : "Disable zoom", "", () => session.ToggleZoomDisabled(zoomId), "D");
            Add("Zoom", "Remove zoom", "", session.DeleteSelected, "Delete", true);
        }

        if (timeline.Zooms.Exists(item => !item.Disabled))
        {
            Add("Zoom", "Disable all zoom ranges", "", () => SetAllZoomsDisabled(true));
        }

        if (timeline.Zooms.Exists(item => item.Disabled))
        {
            Add("Zoom", "Enable all zoom ranges", "", () => SetAllZoomsDisabled(false));
        }

        Add("Zoom", "Restore default zoom ranges", "", session.RegenerateAutoZooms);
        if (timeline.Zooms.Count > 0)
        {
            Add("Zoom", "Remove all zoom ranges", "", () => session.Mutate(edit => edit.Timeline.Zooms.Clear()), null, true);
        }

        Add("Masks", "Add sensitive data mask", "", () => session.AddMaskAtPlayhead(MaskType.Blur));
        Add("Masks", "Add highlight mask", "", () => session.AddMaskAtPlayhead(MaskType.Spotlight));
        if (session.SelectedMaskId is { } maskId)
        {
            Add("Masks", "Change mask type to highlight", "", () => session.SetMaskType(maskId, MaskType.Spotlight));
            Add("Masks", "Change mask type to sensitive data", "", () => session.SetMaskType(maskId, MaskType.Blur));
            Add("Masks", "Toggle disable mask", "", () => session.ToggleMaskDisabled(maskId), "D");
            Add("Masks", "Remove mask", "", () => session.DeleteMask(maskId), "Delete", true);
        }

        if (timeline.MaskTracks.Count > 0)
        {
            Add("Masks", "Disable all masks", "", () => session.Mutate(edit =>
            {
                foreach (var mask in edit.Timeline.MaskTracks.SelectMany(track => track.Items))
                {
                    mask.Disabled = true;
                }
            }));
            Add("Masks", "Remove all masks", "", () => session.Mutate(edit => edit.Timeline.MaskTracks.Clear()), null, true);
        }

        if (session.ActiveSlice is { } slice)
        {
            var sliceId = slice.Id;
            Add("Slice", slice.HideCursor ? "Show mouse cursor for slice" : "Hide mouse cursor for slice", "", () => session.ToggleSliceHideCursor(sliceId));
            Add("Slice", slice.DisableSmoothCursor ? "Enable smooth mouse movement for slice" : "Disable smooth mouse movement for slice", "", () => session.ToggleSliceDisableSmoothCursor(sliceId));
            Add("Slice", "Reset trim", "", () => session.ResetSliceTrim(sliceId));
        }

        if (timeline.Slices.Count > 1)
        {
            Add("Slice", "Reset trims and cuts for all slices", "", session.ResetAllSlices, null, true);
        }

        var typing = ShortcutEngine.TypingSuggestions(document, session.KeyEvents);
        if (typing.Count > 0)
        {
            Add("Slice", "Speed up all typing sections", "", () => session.Mutate(edit =>
            {
                foreach (var suggestion in typing)
                {
                    TypingSuggestionEdits.Apply(edit, suggestion, 3);
                }
            }), "3x");
        }

        var showing = document.Captions.ShowKeystrokes;
        Add("Shortcuts", showing ? "Hide keyboard shortcuts" : "Show keyboard shortcuts", "", () => session.Mutate(edit => edit.Captions.ShowKeystrokes = !showing));
        var singleKeys = document.Captions.ShowSingleKeyShortcuts;
        Add("Shortcuts", singleKeys ? "Disable single key shortcuts" : "Enable single key shortcuts", "", () => session.Mutate(edit => edit.Captions.ShowSingleKeyShortcuts = !singleKeys));

        Add("Camera Layout", "Add camera layout at playhead", "", () => session.AddCameraLayoutAtPlayhead(CameraTimelineLayoutType.CameraOverlay));

        Add("Voiceover", session.IsRecordingVoiceover ? "Stop voiceover recording" : "Record voiceover...", "", tools.ToggleVoiceoverRecording);
        Add("Voiceover", "Upload voiceover audio file...", "", tools.UploadVoiceover);

        var mockup = document.FrameStyle.DeviceMockup.Enabled;
        Add("Device", mockup ? "Disable device mockup" : "Use device mockup", "", () =>
        {
            session.Mutate(edit => edit.FrameStyle.DeviceMockup.Enabled = !mockup);
            session.SelectTab(InspectorTab.DeviceFrame);
        });

        Add("Export", "Export video", "", ShowExportOverlay, "Ctrl+E");
        Add("Export", "Export current frame as image", "", ShowFrameExportOverlay);

        if (source.PackagePath is not null)
        {
            Add("Project", "Save", "", SaveCommand, "Ctrl+S");
            Add("Project", "Show project in File Explorer", "", () => ShowInExplorer(this, new RoutedEventArgs()), "Ctrl+Shift+O");
            Add("Project", "Remove project", "", () => RemoveProject(this, new RoutedEventArgs()), null, true);
        }

        return items;
    }

    private void StepPlayhead(double playingDeltaMs, double pausedDeltaMs)
    {
        var playing = session.IsPlaying;
        SeekTo(Math.Clamp(session.PlayheadTimelineMs + (playing ? playingDeltaMs : pausedDeltaMs), 0, session.DurationMs));
        if (playing)
        {
            TogglePlayback();
        }
    }

    private void ZoomTimeline(double factor) => TimelineZoom.Value = Math.Clamp(TimelineZoom.Value * factor, TimelineZoom.Minimum, TimelineZoom.Maximum);

    private void ToggleZoomLoupe(string id)
    {
        if (session.Document.Timeline.Zooms.Find(item => item.Id == id) is { } zoom)
        {
            session.SetZoomPresentation(id, zoom.Presentation == ZoomPresentation.Loupe ? ZoomPresentation.Screen : ZoomPresentation.Loupe);
        }
    }

    private void SetAllZoomsDisabled(bool disabled) => session.Mutate(edit =>
    {
        foreach (var zoom in edit.Timeline.Zooms)
        {
            zoom.Disabled = disabled;
        }
    });

    // MARK: Keyboard

    /// <summary>Single keys that act on the selection, as on macOS. Returns false when the key means nothing here.</summary>
    private bool HandleEditorKey(VirtualKey key)
    {
        var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        switch (key)
        {
            case VirtualKey.Left:
                StepPlayhead(shift ? -2000 : -1000, shift ? -2000 : -1000.0 / 60);
                return true;
            case VirtualKey.Right:
                StepPlayhead(shift ? 1000 : 500, shift ? 1000 : 1000.0 / 60);
                return true;
            case VirtualKey.D:
                session.ToggleDisableSelected();
                return true;
            case VirtualKey.L when session.SelectedZoomId is { } zoom:
                ToggleZoomLoupe(zoom);
                return true;
            case VirtualKey.A when session.SelectedZoomId is { } zoom:
                session.SetZoomMode(zoom, ZoomMode.FollowCursor);
                return true;
            case VirtualKey.M when session.SelectedZoomId is { } zoom:
                session.SetZoomMode(zoom, ZoomMode.Manual);
                return true;
            default:
                return false;
        }
    }

    /// <summary>Ctrl with a key that edits the selection: duplicate, copy, cut, paste and timeline zoom.</summary>
    private bool HandleSelectionControlKey(VirtualKey key)
    {
        switch (key)
        {
            case VirtualKey.Left:
                SeekTo(0);
                return true;
            case VirtualKey.Right:
                SeekTo(session.DurationMs);
                return true;
            case (VirtualKey)187:
            case VirtualKey.Add:
                ZoomTimeline(TimelineZoomStep);
                return true;
            case (VirtualKey)189:
            case VirtualKey.Subtract:
                ZoomTimeline(1 / TimelineZoomStep);
                return true;
            case VirtualKey.D:
                if (session.SelectedLayoutId is { } layout)
                {
                    session.DuplicateLayout(layout);
                }
                else if (session.SelectedZoomId is { } zoom)
                {
                    session.DuplicateZoom(zoom);
                }
                else if (session.SelectedShortcut is { } shortcut)
                {
                    session.DuplicateShortcut(shortcut);
                }

                return true;
            case VirtualKey.C:
                if (session.SelectedZoomId is { } copiedZoom)
                {
                    session.CopyZoom(copiedZoom);
                }
                else if (session.SelectedMaskId is { } copiedMask)
                {
                    session.CopyMask(copiedMask);
                }

                return true;
            case VirtualKey.X:
                if (session.SelectedZoomId is { } cutZoom)
                {
                    session.CutZoom(cutZoom);
                }
                else if (session.SelectedMaskId is { } cutMask)
                {
                    session.CutMask(cutMask);
                }

                return true;
            case VirtualKey.V:
                if (tools.IsHoveringBackgroundDrop)
                {
                    _ = tools.PasteBackgroundImage();
                }
                else
                {
                    session.PasteFromClipboard();
                }

                return true;
            default:
                return false;
        }
    }
}
