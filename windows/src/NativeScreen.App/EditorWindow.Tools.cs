using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using NativeScreen.Core;
using NativeScreen.Export;
using NativeScreen.Intelligence;
using NativeScreen.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Streams;

namespace NativeScreen.App;

public sealed partial class EditorWindow
{
    private const double MinimumCrop = 0.05;
    private string stillFormat = "png";
    private int stillHeight = 1440;

    // MARK: Project actions

    private async void RemoveProject(object sender, RoutedEventArgs e)
    {
        if (source.PackagePath is not { } path)
        {
            return;
        }

        var answer = await new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            RequestedTheme = AppTheme.Current,
            Title = Loc.T("Remove this project?"),
            Content = Loc.T("The project moves to the Recycle Bin, together with its recording."),
            PrimaryButtonText = Loc.T("Remove"),
            CloseButtonText = Loc.T("Cancel")
        }.ShowAsync();
        if (answer != ContentDialogResult.Primary)
        {
            return;
        }

        hasUnsavedChanges = false;
        saveTimer.Stop();
        AppSettings.Shared.RecentProjects.RemoveAll(item => string.Equals(item, path, StringComparison.OrdinalIgnoreCase));
        AppSettings.Shared.Save();
        Close();
        await Task.Run(() => Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(path, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin));
    }

    private void SaveCommand()
    {
        hasUnsavedChanges = source.PackagePath is not null;
        SaveNow();
        ShowToast("Saved");
    }

    private async void SaveAsCommand()
    {
        if (source.PackagePath is not { } current || await tools.PickSave(session.Document.Name, "Native Screen project folder", ProjectStore.PackageExtension) is not { } target)
        {
            return;
        }

        SaveCommand();
        await pendingWrite;
        // The picker creates an empty file at the name; the package is a folder.
        File.Delete(target);
        await Task.Run(() => CopyDirectory(current, target));
        await Projects.Open(target, Root.XamlRoot);
    }

    private static void CopyDirectory(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var file in Directory.GetFiles(from))
        {
            File.Copy(file, Path.Combine(to, Path.GetFileName(file)));
        }

        foreach (var child in Directory.GetDirectories(from))
        {
            CopyDirectory(child, Path.Combine(to, Path.GetFileName(child)));
        }
    }

    // MARK: Waveform

    private readonly HashSet<string> requestedVoiceoverWaveforms = [];

    private async Task LoadWaveform()
    {
        if (source.PackagePath is not { } package || source.Project is not { } project)
        {
            return;
        }

        // System audio usually lives inside the video, and then the metadata names no separate track for it.
        var tracks = project.Metadata.Tracks;
        timeline.HasMicrophone = tracks.MicrophoneAudio is not null;
        timeline.HasSystemAudio = tracks.SystemAudio is not null;
        var recording = Path.Combine(package, "recording");
        var systemPath = Path.Combine(recording, tracks.SystemAudio ?? tracks.DisplayVideo);
        var microphonePath = tracks.MicrophoneAudio is { } microphone ? Path.Combine(recording, microphone) : null;
        var bins = Waveform.BinCount(source.DurationMs);
        var (system, recordedMicrophone) = await Task.Run(() => (
            MediaAssets.ReadWaveform(systemPath, bins, CancellationToken.None),
            microphonePath is null ? null : MediaAssets.ReadWaveform(microphonePath, bins, CancellationToken.None)));
        if (!closed)
        {
            timeline.SetRecordingWaveforms(system, recordedMicrophone);
        }

        await LoadVoiceoverWaveforms();
    }

    /// <summary>Reads the voiceovers not read yet, one at a time. A voiceover's file never changes, so its id is enough to know.</summary>
    private async Task LoadVoiceoverWaveforms()
    {
        if (source.PackagePath is not { } package)
        {
            return;
        }

        foreach (var voiceover in session.Document.Timeline.Voiceovers.ToList())
        {
            if (closed || !requestedVoiceoverWaveforms.Add(voiceover.Id))
            {
                continue;
            }

            // Samples always cover the whole file; a segment draws the part it plays (spec/06 ADR-59).
            var path = Path.Combine(package, voiceover.RelativePath);
            var known = voiceover.FileOffsetMs + voiceover.DurationMs;
            var fileMs = await Task.Run(() =>
            {
                using var reader = AudioFileReader.TryOpen(path);
                return reader?.DurationMs is > 0 and var length ? length : known;
            });
            var bins = Waveform.VoiceoverBinCount(fileMs);
            var samples = await Task.Run(() => MediaAssets.ReadWaveform(path, bins, CancellationToken.None));
            if (!closed)
            {
                timeline.SetVoiceoverWaveform(voiceover.Id, samples ?? Waveform.Procedural(fileMs, Math.Max(96, bins)), fileMs);
            }
        }
    }

    // MARK: Presets

    private void OpenPresets(object sender, RoutedEventArgs e)
    {
        var rows = new StackPanel { Width = 340, Spacing = 2 };
        var flyout = new Flyout { Content = rows, ShouldConstrainToRootBounds = false };
        foreach (var preset in tools.Presets.Load())
        {
            rows.Children.Add(PresetRow(preset, flyout));
        }

        if (rows.Children.Count > 0)
        {
            rows.Children.Add(new Border { Height = 1, Margin = new Thickness(4), Background = Ui.Pal("Ink10") });
        }

        void Command(string title, Action run)
        {
            var button = Ui.Option(title, false, () =>
            {
                flyout.Hide();
                run();
            });
            button.HorizontalAlignment = HorizontalAlignment.Stretch;
            rows.Children.Add(button);
        }

        Command("Save current style as preset", () => _ = SavePreset());
        Command("Import preset", () => _ = ImportPreset());
        Command("Show presets folder", () => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", $"\"{tools.Presets.Directory}\"") { UseShellExecute = true })?.Dispose());
        flyout.ShowAt((FrameworkElement)sender);
    }

    private Grid PresetRow(ProjectPreset preset, Flyout flyout)
    {
        var settings = AppSettings.Shared;
        var row = new Grid { ColumnSpacing = 4 };
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        title.Children.Add(Ui.Text(preset.Name, 13, "Ink95"));
        void Badge(string text) => title.Children.Add(new Border
        {
            Padding = new Thickness(6, 1, 6, 2),
            CornerRadius = new CornerRadius(5),
            Background = Ui.Pal("Ink07"),
            VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock { Text = text, FontSize = 11, Foreground = Ui.Pal("Ink60") }
        });
        var matches = preset.Matches(session.Document);
        if (matches)
        {
            Badge("Matches project");
        }

        if (settings.DefaultPresetId == preset.Id)
        {
            Badge("Default");
        }

        var apply = new Button { Style = Ui.StyleOf("NsIconButton"), Content = title, Width = double.NaN, Height = 34, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left, Padding = new Thickness(8, 0, 8, 0) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(apply, preset.Name);
        Ui.Tip(apply, "Click to apply");
        apply.Click += (_, _) =>
        {
            flyout.Hide();
            session.Mutate(preset.Apply);
        };
        row.Children.Add(apply);
        var gear = new Button { Style = Ui.StyleOf("NsIconButton"), Content = Ui.Icon("", 13), Width = 34, Height = 34 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(gear, preset.Name + " options");
        gear.Click += (_, _) =>
        {
            var menu = new MenuFlyout();
            menu.Items.Add(Menu("Rename...", () =>
            {
                flyout.Hide();
                _ = RenamePreset(preset);
            }));
            var useDefault = new ToggleMenuFlyoutItem { Text = Loc.T("Use as default for new projects"), IsChecked = settings.DefaultPresetId == preset.Id };
            useDefault.Click += (_, _) =>
            {
                settings.DefaultPresetId = settings.DefaultPresetId == preset.Id ? null : preset.Id;
                settings.Save();
                flyout.Hide();
            };
            menu.Items.Add(useDefault);
            if (!matches)
            {
                menu.Items.Add(Menu("Update to match currently edited project", () =>
                {
                    var updated = ProjectPreset.From(preset.Name, session.Document);
                    updated.Id = preset.Id;
                    tools.Presets.Delete(preset);
                    tools.Presets.Save(updated);
                    flyout.Hide();
                    ShowToast("Preset updated");
                }));
            }

            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(Menu("Show in File Explorer", () => System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{tools.Presets.PathOf(preset)}\"")?.Dispose()));
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(Menu("Remove...", () =>
            {
                tools.Presets.Delete(preset);
                if (settings.DefaultPresetId == preset.Id)
                {
                    settings.DefaultPresetId = null;
                    settings.Save();
                }

                flyout.Hide();
            }));
            menu.ShowAt(gear);
        };
        Grid.SetColumn(gear, 1);
        row.Children.Add(gear);
        return row;
    }

    private async Task RenamePreset(ProjectPreset preset)
    {
        var name = new TextBox { Text = preset.Name };
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, RequestedTheme = AppTheme.Current, Title = Loc.T("Rename preset"), Content = name, PrimaryButtonText = Loc.T("Rename"), CloseButtonText = Loc.T("Cancel"), DefaultButton = ContentDialogButton.Primary };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && name.Text.Trim().Length > 0)
        {
            tools.Presets.Delete(preset);
            preset.Name = name.Text.Trim();
            tools.Presets.Save(preset);
        }
    }

    private async Task SavePreset()
    {
        var name = new TextBox { PlaceholderText = Loc.T("Preset name") };
        var answer = await new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            RequestedTheme = AppTheme.Current,
            Title = Loc.T("Save preset"),
            Content = name,
            PrimaryButtonText = Loc.T("Save"),
            CloseButtonText = Loc.T("Cancel")
        }.ShowAsync();
        if (answer == ContentDialogResult.Primary && name.Text.Trim().Length > 0)
        {
            tools.Presets.Save(ProjectPreset.From(name.Text.Trim(), session.Document));
            ShowToast("Preset created");
        }
    }

    private async Task ImportPreset()
    {
        if (await tools.PickFile(".json") is { } file)
        {
            ShowToast(tools.Presets.Import(file) is null ? "This file is not a preset" : "Preset imported");
        }
    }

    // MARK: Playback speed

    private void OpenSpeedMenu(object sender, RoutedEventArgs e)
    {
        var (_, slice) = session.Mapper.SourceTime(session.PlayheadTimelineMs);
        if (slice is null)
        {
            return;
        }

        var id = slice.Id;
        var menu = new MenuFlyout();
        foreach (var speed in new[] { 0.25, 0.5, 1, 1.5, 2, 3, 4, 6, 8, 10 })
        {
            var value = speed;
            menu.Items.Add(Menu($"{value:0.##}x", () => session.Mutate(document => document.Timeline.Slices.First(other => other.Id == id).Speed = value)));
        }

        menu.ShowAt((FrameworkElement)sender);
    }

    // MARK: Export frame

    private ExportSource CurrentExportSource()
    {
        var (document, _) = session.RenderSnapshot();
        return new ExportSource(
            document,
            source.PackagePath,
            source.Project?.Metadata.Tracks ?? new RecordingTracksMetadata(),
            source.DurationMs,
            source.SourceWidth,
            source.SourceHeight,
            source.HasCamera,
            session.CursorEvents,
            session.ClickEvents,
            session.Shortcuts(),
            tools.WaitForFaceTrack(),
            ExportPersonMasks.TryCreate,
            source.Project?.IsCameraOnly == true);
    }

    // MARK: Crop

    private async void OpenCrop(object sender, RoutedEventArgs e)
    {
        var path = source.PackagePath is { } package && source.Project is { } project
            ? Path.Combine(package, "recording", project.Metadata.Tracks.DisplayVideo)
            : null;
        if (path is null || !File.Exists(path))
        {
            ShowToast("This project has no recording to crop");
            return;
        }

        var at = session.SourceAtPlayhead;
        var still = await Task.Run(() =>
        {
            using var reader = new VideoFileReader(path);
            return MediaAssets.FrameAt(reader, at) is { } frame ? (MediaAssets.ToBgra(frame), frame.Width, frame.Height) : default;
        });
        if (still.Item1 is null)
        {
            ShowToast("Could not read a frame to crop");
            return;
        }

        ShowCropOverlay(still.Item1, still.Width, still.Height, session.Document.Canvas.CropRect01, crop => session.Mutate(document => document.Canvas.CropRect01 = crop));
    }

    private async void OpenCameraCrop()
    {
        var path = source.PackagePath is { } package && source.Project?.Metadata.Tracks.WebcamVideo is { } webcam
            ? Path.Combine(package, "recording", webcam)
            : null;
        if (path is null || !File.Exists(path))
        {
            ShowToast("This project has no camera recording to crop");
            return;
        }

        var at = session.SourceAtPlayhead;
        var still = await Task.Run(() =>
        {
            using var reader = new VideoFileReader(path);
            return MediaAssets.FrameAt(reader, at) is { } frame ? (MediaAssets.ToBgra(frame), frame.Width, frame.Height) : default;
        });
        if (still.Item1 is null)
        {
            ShowToast("Could not read a frame to crop");
            return;
        }

        ShowCropOverlay(still.Item1, still.Width, still.Height, session.Document.Camera.CropRect01, crop => session.Mutate(document => document.Camera.CropRect01 = crop));
    }

    private void ShowCropOverlay(byte[] bgra, int width, int height, Rect01 start, Action<Rect01> applyCrop)
    {
        var bitmap = new WriteableBitmap(width, height);
        using (var stream = bitmap.PixelBuffer.AsStream())
        {
            stream.Write(bgra);
        }

        bitmap.Invalidate();
        var available = new Windows.Foundation.Size(Root.ActualWidth * 0.8, Root.ActualHeight * 0.72);
        var fit = Math.Min(available.Width / width, available.Height / height);
        var viewWidth = width * fit;
        var viewHeight = height * fit;
        var (left, top, right, bottom) = (start.X, start.Y, start.X + start.Width, start.Y + start.Height);

        var canvas = new Canvas { Width = viewWidth, Height = viewHeight };
        canvas.Children.Add(new Image { Source = bitmap, Width = viewWidth, Height = viewHeight, Stretch = Stretch.Fill });
        var shades = Enumerable.Range(0, 4).Select(_ => new Border { Background = new SolidColorBrush(Windows.UI.Color.FromArgb(150, 0, 0, 0)), IsHitTestVisible = false }).ToArray();
        foreach (var shade in shades)
        {
            canvas.Children.Add(shade);
        }

        var frame = new Border { BorderBrush = new SolidColorBrush(Colors.White), BorderThickness = new Thickness(2), Background = new SolidColorBrush(Colors.Transparent) };
        canvas.Children.Add(frame);
        var handles = Enumerable.Range(0, 4).Select(_ => new Border { Width = 18, Height = 18, CornerRadius = new CornerRadius(9), Background = new SolidColorBrush(Colors.White) }).ToArray();
        foreach (var handle in handles)
        {
            canvas.Children.Add(handle);
        }

        Action? layoutExtras = null;

        void Layout()
        {
            var (x, y, w, h) = (left * viewWidth, top * viewHeight, (right - left) * viewWidth, (bottom - top) * viewHeight);
            Place(shades[0], 0, 0, viewWidth, y);
            Place(shades[1], 0, y + h, viewWidth, viewHeight - y - h);
            Place(shades[2], 0, y, x, h);
            Place(shades[3], x + w, y, viewWidth - x - w, h);
            Place(frame, x, y, w, h);
            Canvas.SetLeft(handles[0], x - 9);
            Canvas.SetTop(handles[0], y - 9);
            Canvas.SetLeft(handles[1], x + w - 9);
            Canvas.SetTop(handles[1], y - 9);
            Canvas.SetLeft(handles[2], x - 9);
            Canvas.SetTop(handles[2], y + h - 9);
            Canvas.SetLeft(handles[3], x + w - 9);
            Canvas.SetTop(handles[3], y + h - 9);
            layoutExtras?.Invoke();
        }

        void DragWith(UIElement element, Action<double, double> apply)
        {
            var dragging = false;
            element.PointerPressed += (_, args) =>
            {
                dragging = element.CapturePointer(args.Pointer);
                args.Handled = true;
            };
            element.PointerMoved += (_, args) =>
            {
                if (dragging)
                {
                    var point = args.GetCurrentPoint(canvas).Position;
                    apply(Math.Clamp(point.X / viewWidth, 0, 1), Math.Clamp(point.Y / viewHeight, 0, 1));
                    Layout();
                }
            };
            element.PointerReleased += (_, args) =>
            {
                dragging = false;
                element.ReleasePointerCapture(args.Pointer);
            };
        }

        DragWith(handles[0], (x, y) => (left, top) = (Math.Min(x, right - MinimumCrop), Math.Min(y, bottom - MinimumCrop)));
        DragWith(handles[1], (x, y) => (right, top) = (Math.Max(x, left + MinimumCrop), Math.Min(y, bottom - MinimumCrop)));
        DragWith(handles[2], (x, y) => (left, bottom) = (Math.Min(x, right - MinimumCrop), Math.Max(y, top + MinimumCrop)));
        DragWith(handles[3], (x, y) => (right, bottom) = (Math.Max(x, left + MinimumCrop), Math.Max(y, top + MinimumCrop)));
        Layout();

        // Thirds grid, edge handles and the size readout.
        var thirds = Enumerable.Range(0, 4).Select(_ => new Border { Background = new SolidColorBrush(Windows.UI.Color.FromArgb(90, 255, 255, 255)), IsHitTestVisible = false }).ToArray();
        var edges = Enumerable.Range(0, 4).Select(index => new Border { Background = new SolidColorBrush(Colors.White), CornerRadius = new CornerRadius(3), Width = index < 2 ? 34 : 6, Height = index < 2 ? 6 : 34 }).ToArray();
        var readout = new TextBlock { FontSize = 13, HorizontalAlignment = HorizontalAlignment.Center, Foreground = new SolidColorBrush(Colors.White) };
        layoutExtras = () =>
        {
            var (x, y, w, h) = (left * viewWidth, top * viewHeight, (right - left) * viewWidth, (bottom - top) * viewHeight);
            Place(thirds[0], x + w / 3, y, 1, h);
            Place(thirds[1], x + w * 2 / 3, y, 1, h);
            Place(thirds[2], x, y + h / 3, w, 1);
            Place(thirds[3], x, y + h * 2 / 3, w, 1);
            Canvas.SetLeft(edges[0], x + w / 2 - 17);
            Canvas.SetTop(edges[0], y - 3);
            Canvas.SetLeft(edges[1], x + w / 2 - 17);
            Canvas.SetTop(edges[1], y + h - 3);
            Canvas.SetLeft(edges[2], x - 3);
            Canvas.SetTop(edges[2], y + h / 2 - 17);
            Canvas.SetLeft(edges[3], x + w - 3);
            Canvas.SetTop(edges[3], y + h / 2 - 17);
            readout.Text = $"Size {Math.Round((right - left) * width)} × {Math.Round((bottom - top) * height)}    Position {Math.Round(left * width)} {Math.Round(top * height)}";
        };

        // Dragging inside the frame moves the crop without changing its size.
        frame.IsHitTestVisible = true;
        frame.Background = new SolidColorBrush(Windows.UI.Color.FromArgb(1, 0, 0, 0));
        var grabX = 0.0;
        var grabY = 0.0;
        frame.PointerPressed += (_, args) =>
        {
            var point = args.GetCurrentPoint(canvas).Position;
            grabX = point.X / viewWidth - left;
            grabY = point.Y / viewHeight - top;
        };
        DragWith(frame, (x, y) =>
        {
            var w = right - left;
            var h = bottom - top;
            left = Math.Clamp(x - grabX, 0, 1 - w);
            top = Math.Clamp(y - grabY, 0, 1 - h);
            right = left + w;
            bottom = top + h;
        });

        foreach (var line in thirds)
        {
            canvas.Children.Add(line);
        }

        foreach (var edge in edges)
        {
            canvas.Children.Add(edge);
        }

        DragWith(edges[0], (_, y) => top = Math.Min(y, bottom - MinimumCrop));
        DragWith(edges[1], (_, y) => bottom = Math.Max(y, top + MinimumCrop));
        DragWith(edges[2], (x, _) => left = Math.Min(x, right - MinimumCrop));
        DragWith(edges[3], (x, _) => right = Math.Max(x, left + MinimumCrop));
        Layout();

        var overlay = new Grid { Background = new SolidColorBrush(Windows.UI.Color.FromArgb(230, 10, 10, 14)) };
        Grid.SetRowSpan(overlay, 8);
        Grid.SetColumnSpan(overlay, 8);
        void Close() => Root.Children.Remove(overlay);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center };
        buttons.Children.Add(Ui.Option("Cancel", false, Close));
        buttons.Children.Add(Ui.Option("Reset", false, () =>
        {
            (left, top, right, bottom) = (0, 0, 1, 1);
            Layout();
        }));
        foreach (var (title, ratio) in new[] { ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("1:1", 1.0), ("4:3", 4.0 / 3) })
        {
            var chosen = ratio;
            buttons.Children.Add(Ui.Option(title, false, () =>
            {
                var aspect = width / (double)Math.Max(1, height);
                var newWidth = 1.0;
                var newHeight = aspect / chosen;
                if (newHeight > 1)
                {
                    newHeight = 1;
                    newWidth = chosen / aspect;
                }

                (left, top, right, bottom) = ((1 - newWidth) / 2, (1 - newHeight) / 2, (1 + newWidth) / 2, (1 + newHeight) / 2);
                Layout();
            }));
        }

        var apply = new Button { Style = Ui.StyleOf("NsPrimaryButton"), Content = Loc.T("Apply") };
        apply.Click += (_, _) =>
        {
            var crop = new Rect01(left, top, right - left, bottom - top);
            applyCrop(crop);
            Close();
        };
        buttons.Children.Add(apply);
        var stack = new StackPanel { Spacing = 16, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        stack.Children.Add(readout);
        stack.Children.Add(canvas);
        stack.Children.Add(buttons);
        overlay.Children.Add(stack);
        Root.Children.Add(overlay);
    }

    private static void Place(FrameworkElement element, double x, double y, double width, double height)
    {
        Canvas.SetLeft(element, x);
        Canvas.SetTop(element, y);
        element.Width = Math.Max(0, width);
        element.Height = Math.Max(0, height);
    }

    // MARK: Clipboard export

    private async Task QuickExportToClipboard()
    {
        var directory = Directory.CreateTempSubdirectory("ns-clipboard-").FullName;
        var path = Path.Combine(directory, session.Document.Name + ".mp4");
        await RunExport(path, Path.GetFileName(path), toClipboard: true);
    }
}

/// <summary>Opening packages from any window or the command line.</summary>
internal static class Projects
{
    public static void ShowFolder(string path)
    {
        Directory.CreateDirectory(path);
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
    }

    public static async Task PromptOpen(Window owner, XamlRoot? xamlRoot)
    {
        // A .nativescreen package is a folder on Windows.
        var picker = new Windows.Storage.Pickers.FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(owner));
        if (await picker.PickSingleFolderAsync() is { } folder)
        {
            await Open(folder.Path, xamlRoot);
        }
    }

    public static async Task PromptImport(Window owner, XamlRoot? xamlRoot)
    {
        var picker = new Windows.Storage.Pickers.FileOpenPicker();
        foreach (var type in new[] { ".mp4", ".mov", ".m4v", ".mkv", ".wmv" })
        {
            picker.FileTypeFilter.Add(type);
        }

        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(owner));
        if (await picker.PickSingleFileAsync() is { } file)
        {
            await ImportVideo(file.Path, xamlRoot);
        }
    }

    public static async Task Open(string path, XamlRoot? xamlRoot, string afterOpening = "project")
    {
        // Two editors on one package would overwrite each other's saves.
        var key = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (OpenEditors.TryGetValue(key, out var existing))
        {
            existing.Activate();
            existing.ExportAfterOpening(afterOpening);
            return;
        }

        try
        {
            var project = await Task.Run(() => new LoadedProject(path));
            if (OpenEditors.TryGetValue(key, out existing))
            {
                existing.Activate();
                return;
            }

            var editor = new EditorWindow(EditorSource.Package(path, project));
            OpenEditors[key] = editor;
            editor.Closed += (_, _) => OpenEditors.Remove(key);
            editor.Activate();
            editor.ExportAfterOpening(afterOpening);
            AppSettings.Shared.NoteRecent(path);
        }
        catch (Exception exception) when (exception is IOException or System.Text.Json.JsonException or UnauthorizedAccessException or NotSupportedException or ArgumentException)
        {
            if (xamlRoot is not null)
            {
                await new ContentDialog
                {
                    XamlRoot = xamlRoot,
                    RequestedTheme = AppTheme.Current,
                    Title = Loc.T("Could not open this project"),
                    Content = $"{path}\n\n{exception.Message}",
                    CloseButtonText = Loc.T("OK")
                }.ShowAsync();
            }
        }
    }

    private static readonly Dictionary<string, EditorWindow> OpenEditors = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Open editors by package path, for the MCP tools.</summary>
    internal static IReadOnlyDictionary<string, EditorWindow> Editors => OpenEditors;

    /// <summary>The editor activated last, or the only one open: what a tool works on when no project is named.</summary>
    internal static EditorWindow? Active
    {
        get
        {
            if (lastActive?.TryGetTarget(out var active) == true && !active.McpIsClosed)
            {
                return active;
            }

            return OpenEditors.Count == 1 ? OpenEditors.Values.First() : null;
        }
        set => lastActive = value is null ? null : new WeakReference<EditorWindow>(value);
    }

    // Weak: a closed editor must not stay in memory because it was the last one activated (spec/06 ADR-48).
    private static WeakReference<EditorWindow>? lastActive;

    /// <summary>The editor of a package, opening it when needed.</summary>
    internal static async Task<EditorWindow?> OpenAndGet(string path)
    {
        var key = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        await Open(key, null);
        return OpenEditors.TryGetValue(key, out var editor) ? editor : null;
    }

    public static async Task ImportVideo(string file, XamlRoot? xamlRoot)
    {
        try
        {
            var package = await Task.Run(() => VideoProjectImporter.BuildPackage(file, AppSettings.Shared.ProjectsDirectory, DateTimeOffset.UtcNow));
            await Open(package, xamlRoot);
        }
        catch (Exception exception) when (exception is IOException or InvalidDataException or SharpGen.Runtime.SharpGenException or UnauthorizedAccessException)
        {
            if (xamlRoot is not null)
            {
                await new ContentDialog
                {
                    XamlRoot = xamlRoot,
                    RequestedTheme = AppTheme.Current,
                    Title = $"Could not create a project from {Path.GetFileName(file)}",
                    Content = exception.Message,
                    CloseButtonText = Loc.T("OK")
                }.ShowAsync();
            }
        }
    }
}
