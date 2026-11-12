using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using NativeScreen.Core;
using Windows.Foundation;

namespace NativeScreen.App;

/// <summary>
/// Right-click menus of the timeline, the same rows as NativeSegmentContextMenuPresenter on macOS: commands, sliders and the
/// two-card type chooser. A menu flyout cannot hold sliders, so this is a flyout with menu-looking rows.
/// </summary>
internal sealed class SegmentMenu
{
    private const double MenuWidth = 284;
    private static readonly Brush Destructive = Ui.Rgb(1, 0.35, 0.35);

    private readonly StackPanel rows = new() { Width = MenuWidth, Spacing = 1 };
    private readonly Flyout flyout = new() { ShouldConstrainToRootBounds = false };

    private SegmentMenu()
    {
        var style = new Style(typeof(FlyoutPresenter));
        style.Setters.Add(new Setter(FlyoutPresenter.PaddingProperty, new Thickness(6)));
        style.Setters.Add(new Setter(FlyoutPresenter.CornerRadiusProperty, new CornerRadius(10)));
        style.Setters.Add(new Setter(FlyoutPresenter.MaxWidthProperty, 400d));
        style.Setters.Add(new Setter(ScrollViewer.VerticalScrollModeProperty, ScrollMode.Disabled));
        flyout.FlyoutPresenterStyle = style;
        flyout.Content = rows;
    }

    public static void ForClip(EditorSession session, string id, bool hasMicrophone, bool hasSystemAudio, FrameworkElement anchor, Point at)
    {
        var slices = session.Document.Timeline.Slices;
        var index = slices.FindIndex(item => item.Id == id);
        if (index < 0)
        {
            return;
        }

        var slice = slices[index];
        var menu = new SegmentMenu();
        menu.Command("Split at current time", "C", () => session.SplitSlice(session.PlayheadTimelineMs));
        menu.Command("Merge with next", null, index + 1 < slices.Count ? () => session.MergeSliceWithNext(id) : null);
        menu.Command("Reset trim", null, () => session.ResetSliceTrim(id));
        menu.Separator();
        menu.Heading("Set speed");
        menu.Choices([0.5, 1, 1.25, 1.5, 2, 4], speed => $"{speed:0.##}x", speed => Math.Abs(slice.Speed - speed) < 0.03, speed => session.SetSliceSpeed(id, speed));
        menu.Separator();
        // One slider per recorded source, each applied only to this slice (spec/06 ADR-47).
        if (hasMicrophone)
        {
            menu.Slider("Microphone volume", slice.Muted ? 0 : slice.MicrophoneVolume, 0, 1, value => $"{Math.Round(value * 100)}%", value => session.SetSliceMicrophoneVolume(id, value));
        }

        if (hasSystemAudio)
        {
            menu.Slider("System audio volume", slice.Muted ? 0 : slice.SystemAudioVolume, 0, 1, value => $"{Math.Round(value * 100)}%", value => session.SetSliceSystemAudioVolume(id, value));
        }

        if (hasMicrophone || hasSystemAudio)
        {
            menu.Separator();
        }
        menu.Check("Hide mouse cursor", slice.HideCursor, () => session.ToggleSliceHideCursor(id));
        menu.Check("Disable smooth mouse movement", slice.DisableSmoothCursor, () => session.ToggleSliceDisableSmoothCursor(id));
        menu.Separator();
        menu.Danger("Remove", "Delete", slices.Count > 1 ? () =>
        {
            session.SelectSlice(id);
            session.DeleteSelected();
        }
        : null);
        menu.Danger("Reset trims and cuts for all slices", null, session.ResetAllSlices);
        menu.Show(anchor, at);
    }

    public static void ForZoom(EditorSession session, string id, FrameworkElement anchor, Point at)
    {
        if (session.Document.Timeline.Zooms.Find(item => item.Id == id) is not { } zoom)
        {
            return;
        }

        var menu = new SegmentMenu();
        menu.Cards(
            ("Classic", "", zoom.Presentation == ZoomPresentation.Screen, () => session.SetZoomPresentation(id, ZoomPresentation.Screen)),
            ("Loupe", "", zoom.Presentation == ZoomPresentation.Loupe, () => session.SetZoomPresentation(id, ZoomPresentation.Loupe)));
        menu.Separator();
        menu.Slider("Zoom level", zoom.Scale, 1, 4, value => $"{Math.Round(value * 100)}%", value => session.SetZoomScale(id, value), 0.1);
        menu.Command("Apply zoom level to all other zooms", null, () => session.ApplyZoomLevelToAll(id));
        menu.Separator();
        menu.Command("Split zoom at current time", "C", () => session.SplitZoom(id, session.SourceAtPlayhead));
        menu.Command("Duplicate", "Ctrl+D", () => session.DuplicateZoom(id));
        menu.Command(zoom.Disabled ? "Enable" : "Disable", "D", () => session.ToggleZoomDisabled(id));
        menu.Separator();
        menu.Command("Copy zoom range", "Ctrl+C", () => session.CopyZoom(id));
        menu.Command("Cut to clipboard", "Ctrl+X", () => session.CutZoom(id));
        menu.Separator();
        menu.Danger("Remove", "Delete", () =>
        {
            session.SelectZoom(id);
            session.DeleteSelected();
        });
        menu.Show(anchor, at);
    }

    public static void ForCaption(EditorSession session, string id, string trackId, FrameworkElement anchor, Point at)
    {
        var menu = new SegmentMenu();
        menu.Command("Split at playhead", "C", () => session.SplitCaption(id, session.SourceAtPlayhead));
        menu.Command("Add caption track", "", () => session.AddCaptionTrack());
        // Turns every caption on or off; the inspector does not have this switch.
        var captionsOn = session.Document.Captions.Enabled;
        menu.Command(captionsOn ? "Disable captions" : "Enable captions", "", () => session.Mutate(document => document.Captions.Enabled = !captionsOn));
        menu.Separator();
        menu.Danger("Remove caption", "Delete", () => session.DeleteCaption(id));
        menu.Danger("Remove this track", "", () => session.DeleteCaptionTrack(trackId));
        menu.Show(anchor, at);
    }

    public static void ForMask(EditorSession session, string id, FrameworkElement anchor, Point at)
    {
        var mask = session.Document.Timeline.MaskTracks.SelectMany(track => track.Items).FirstOrDefault(item => item.Id == id);
        if (mask is null)
        {
            return;
        }

        var highlight = mask.Type == MaskType.Spotlight;
        var menu = new SegmentMenu();
        menu.Cards(
            ("Highlight", "", highlight, () => session.SetMaskType(id, MaskType.Spotlight)),
            ("Sensitive data", "", !highlight, () => session.SetMaskType(id, MaskType.Blur)));
        menu.Separator();
        menu.Slider(
            highlight ? "Highlight intensity" : "Blur intensity",
            mask.Intensity,
            highlight ? 0 : 4,
            highlight ? 95 : 160,
            value => highlight ? $"{Math.Round(value)}%" : $"{Math.Round(value)}",
            value => session.SetMaskIntensity(id, value));
        menu.Slider("Corner radius", mask.CornerRadius, 0, 120, value => $"{Math.Round(value)}px", value => session.SetMaskCornerRadius(id, value));
        menu.Separator();
        menu.Command("Split mask at current time", "C", () => session.SplitMask(id, session.SourceAtPlayhead));
        menu.Command(mask.Disabled ? "Enable" : "Disable", "D", () => session.ToggleMaskDisabled(id));
        menu.Separator();
        menu.Command("Copy mask", "Ctrl+C", () => session.CopyMask(id));
        menu.Command("Cut to clipboard", "Ctrl+X", () => session.CutMask(id));
        menu.Separator();
        menu.Danger("Remove", "Delete", () => session.DeleteMask(id));
        menu.Show(anchor, at);
    }

    public static void ForAnnotation(EditorSession session, string id, FrameworkElement anchor, Point at)
    {
        if (session.Annotation(id) is not { } item)
        {
            return;
        }

        var menu = new SegmentMenu();
        menu.Command("Split at playhead", "C", () => session.SplitAnnotation(id, session.SourceAtPlayhead));
        menu.Command(item.Disabled ? "Enable" : "Disable", "D", () => session.ToggleAnnotationDisabled(id));
        menu.Command(item.Anchor == AnnotationAnchor.Screen ? "Pin to frame" : "Pin to screen", null, () => session.SetAnnotationAnchor(id, item.Anchor == AnnotationAnchor.Screen ? AnnotationAnchor.Canvas : AnnotationAnchor.Screen));
        menu.Separator();
        menu.Command("Bring to front", null, () => session.MoveAnnotationLayer(id, AnnotationLayerMove.Front));
        menu.Command("Bring forward", null, () => session.MoveAnnotationLayer(id, AnnotationLayerMove.Forward));
        menu.Command("Send backward", null, () => session.MoveAnnotationLayer(id, AnnotationLayerMove.Backward));
        menu.Command("Send to back", null, () => session.MoveAnnotationLayer(id, AnnotationLayerMove.Back));
        menu.Separator();
        menu.Command("Duplicate", "Ctrl+D", () => session.DuplicateAnnotation(id));
        menu.Command("Copy", "Ctrl+C", () => session.CopyAnnotation(id));
        menu.Command("Cut to clipboard", "Ctrl+X", () => session.CutAnnotation(id));
        menu.Separator();
        menu.Danger("Remove", "Delete", () => session.DeleteAnnotation(id));
        menu.Show(anchor, at);
    }

    public static void ForShortcut(EditorSession session, ShortcutCluster cluster, FrameworkElement anchor, Point at)
    {
        var all = session.Shortcuts();
        var hidden = SegmentEdits.IsShortcutHidden(session.Document, cluster);
        var menu = new SegmentMenu();
        menu.Check("Show this shortcut", !hidden, () => session.ToggleShortcutHidden(cluster));
        var same = all.Where(item => item.Label == cluster.Label).ToList();
        if (same.Count >= 2)
        {
            var allVisible = same.All(item => !SegmentEdits.IsShortcutHidden(session.Document, item));
            menu.Check(Loc.F("Show every %@", cluster.Label), allVisible, () => session.SetEveryShortcutWithLabelHidden(cluster, allVisible));
        }

        var allHidden = all.Count > 0 && all.All(item => SegmentEdits.IsShortcutHidden(session.Document, item));
        menu.Command(allHidden ? "Show all shortcuts" : "Hide all shortcuts", null, () => session.SetAllShortcutsHidden(!allHidden));
        menu.Separator();
        menu.Command("Edit shortcut", null, () => session.SelectShortcut(cluster.Id));
        menu.Command("Duplicate shortcut", "Ctrl+D", () => session.DuplicateShortcut(cluster));
        menu.Command("Add new shortcut track", null, () => session.Mutate(document => TimelineEdits.AddShortcutTrack(document)));
        menu.Separator();
        menu.Danger("Remove shortcut", null, () => session.DeleteShortcut(cluster));
        menu.Show(anchor, at);
    }

    public static void ForLayout(EditorSession session, string id, FrameworkElement anchor, Point at)
    {
        if (session.Document.Timeline.CameraLayouts.Find(item => item.Id == id) is not { } layout)
        {
            return;
        }

        var menu = new SegmentMenu();
        foreach (var (type, title) in new[]
        {
            (CameraTimelineLayoutType.CameraOverlay, "Camera overlay"),
            (CameraTimelineLayoutType.SplitScreen, "Split screen"),
            (CameraTimelineLayoutType.CutoutCamera, "Camera cutout"),
            (CameraTimelineLayoutType.FullscreenCamera, "Fullscreen camera"),
            (CameraTimelineLayoutType.ScreenOnly, "Only screen")
        })
        {
            var value = type;
            menu.Check(title, layout.LayoutType == type, () => session.SetLayoutType(id, value));
        }

        menu.Separator();
        menu.Command("Split layout at current time", "C", () => session.SplitLayout(id, session.SourceAtPlayhead));
        menu.Command("Duplicate", "Ctrl+D", () => session.DuplicateLayout(id));
        menu.Command(layout.Disabled ? "Enable" : "Disable", "D", () => session.ToggleLayoutDisabled(id));
        menu.Separator();
        menu.Danger("Remove", "Delete", () => session.DeleteLayout(id));
        menu.Danger("Remove all layouts", null, () => session.Mutate(document => document.Timeline.CameraLayouts.Clear()));
        menu.Show(anchor, at);
    }

    public static void ForVoiceover(EditorSession session, EditorTools tools, string id, FrameworkElement anchor, Point at)
    {
        if (session.Document.Timeline.Voiceovers.Find(item => item.Id == id) is not { } voiceover)
        {
            return;
        }

        var menu = new SegmentMenu();
        menu.Slider("Voiceover volume", voiceover.Volume, 0, 1, value => $"{Math.Round(value * 100)}%", value => session.SetVoiceoverVolume(id, value), 0.01);
        menu.Separator();
        menu.Command("Split at current time", "C", () => session.SplitVoiceover(id, session.SourceAtPlayhead));
        menu.Command(voiceover.Disabled ? "Enable" : "Disable", "D", () => session.ToggleVoiceoverDisabled(id));
        menu.Command("Upload voiceover audio file", null, tools.UploadVoiceover);
        menu.Separator();
        menu.Danger("Remove voiceover", null, () => session.DeleteVoiceover(id));
        menu.Danger("Remove all voiceovers", null, () => session.Mutate(document => document.Timeline.Voiceovers.Clear()));
        menu.Show(anchor, at);
    }

    private void Show(FrameworkElement anchor, Point at) =>
        flyout.ShowAt(anchor, new FlyoutShowOptions { Position = at, Placement = FlyoutPlacementMode.TopEdgeAlignedLeft });

    private Button Row(string title, string? shortcut, Brush? color, Action? click, bool? isChecked = null)
    {
        title = Loc.T(title);
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (isChecked == true)
        {
            grid.Children.Add(Ui.Icon("", 11, color ?? Ui.Pal("Ink95")));
        }

        var label = new TextBlock { Text = title, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, Foreground = color ?? Ui.Pal(click is null ? "Ink28" : "Ink95") };
        Grid.SetColumn(label, 1);
        grid.Children.Add(label);
        if (shortcut is not null)
        {
            var key = new TextBlock { Text = shortcut, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Foreground = Ui.Pal("Ink45") };
            Grid.SetColumn(key, 2);
            grid.Children.Add(key);
        }

        var button = new Button
        {
            Style = Ui.StyleOf("NsIconButton"),
            Content = grid,
            Width = double.NaN,
            Height = 30,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(6, 0, 8, 0),
            IsEnabled = click is not null
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, title);
        if (click is not null)
        {
            button.Click += (_, _) =>
            {
                flyout.Hide();
                click();
            };
        }

        rows.Children.Add(button);
        return button;
    }

    private void Command(string title, string? shortcut, Action? click) => Row(title, shortcut, null, click);

    private void Check(string title, bool isChecked, Action click) => Row(title, null, null, click, isChecked);

    private void Danger(string title, string? shortcut, Action? click) => Row(title, shortcut, click is null ? null : Destructive, click);

    private void Separator() => rows.Children.Add(new Border { Height = 1, Margin = new Thickness(4, 4, 4, 4), Background = Ui.Pal("Ink10") });

    private void Heading(string title) =>
        rows.Children.Add(new TextBlock { Text = Loc.T(title), FontSize = 12, Margin = new Thickness(8, 4, 8, 2), Foreground = Ui.Pal("Ink60") });

    private void Choices(double[] values, Func<double, string> label, Func<double, bool> selected, Action<double> choose)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 3, Margin = new Thickness(6, 2, 6, 2) };
        foreach (var value in values)
        {
            var chosen = value;
            var button = Ui.Option(label(value), selected(value), () =>
            {
                flyout.Hide();
                choose(chosen);
            });
            button.Height = 26;
            button.MinWidth = 0;
            button.Padding = new Thickness(6, 0, 6, 0);
            button.FontSize = 11.5;
            row.Children.Add(button);
        }

        rows.Children.Add(row);
    }

    private void Cards(params (string Title, string Glyph, bool Selected, Action Click)[] cards)
    {
        var grid = new Grid { ColumnSpacing = 6, Margin = new Thickness(2) };
        for (var index = 0; index < cards.Length; index++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition());
            var (title, glyph, selected, click) = cards[index];
            var content = new StackPanel { Spacing = 4, HorizontalAlignment = HorizontalAlignment.Center };
            var icon = Ui.Icon(glyph, 16);
            icon.HorizontalAlignment = HorizontalAlignment.Center;
            content.Children.Add(icon);
            content.Children.Add(new TextBlock { Text = title, FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center });
            var button = Ui.Option(title, selected, () =>
            {
                flyout.Hide();
                click();
            });
            button.Content = content;
            button.Height = 58;
            button.HorizontalAlignment = HorizontalAlignment.Stretch;
            button.Padding = new Thickness(0);
            Grid.SetColumn(button, index);
            grid.Children.Add(button);
        }

        rows.Children.Add(grid);
    }

    private void Slider(string title, double value, double minimum, double maximum, Func<double, string> format, Action<double> change, double? step = null)
    {
        title = Loc.T(title);
        var grid = new Grid { Margin = new Thickness(8, 4, 8, 2) };
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new TextBlock { Text = title, FontSize = 13, Foreground = Ui.Pal("Ink95") });
        var amount = new TextBlock { Text = format(value), FontSize = 12.5, Foreground = Ui.Pal("Ink60") };
        Grid.SetColumn(amount, 1);
        grid.Children.Add(amount);
        rows.Children.Add(grid);
        var slider = new Slider { Minimum = minimum, Maximum = maximum, StepFrequency = step ?? (maximum - minimum) / 200, Value = value, Margin = new Thickness(8, -4, 8, -4), IsThumbToolTipEnabled = false };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(slider, title);
        slider.ValueChanged += (_, args) =>
        {
            amount.Text = format(args.NewValue);
            change(args.NewValue);
        };
        rows.Children.Add(slider);
    }
}
