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
            Title = "Remove this project?",
            Content = "The project moves to the Recycle Bin, together with its recording.",
            PrimaryButtonText = "Remove",
            CloseButtonText = "Cancel"
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

    private async Task LoadWaveform()
    {
        if (source.PackagePath is not { } package || source.Project is not { } project)
        {
            return;
        }

        var tracks = project.Metadata.Tracks;
        var track = tracks.SystemAudio ?? tracks.MicrophoneAudio;
        if (track is null)
        {
            return;
        }

        var path = Path.Combine(package, "recording", track);
        var waveform = await Task.Run(() => MediaAssets.ReadWaveform(path, source.DurationMs, CancellationToken.None));
        if (!closed && waveform is not null)
        {
            timeline.SetWaveform(waveform);
        }
    }

    // MARK: Presets

    private void OpenPresets(object sender, RoutedEventArgs e)
    {
        var menu = new MenuFlyout();
        foreach (var preset in tools.Presets.Load())
        {
            var target = preset;
            menu.Items.Add(Menu(target.Name, () => session.Mutate(target.Apply)));
        }

        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Menu("Save current style as preset", () => _ = SavePreset()));
        menu.Items.Add(Menu("Import preset", () => _ = ImportPreset()));
        menu.Items.Add(Menu("Show presets folder", () => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", $"\"{tools.Presets.Directory}\"") { UseShellExecute = true })));
        menu.ShowAt((FrameworkElement)sender);
    }

    private async Task SavePreset()
    {
        var name = new TextBox { PlaceholderText = "Preset name" };
        var answer = await new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            RequestedTheme = AppTheme.Current,
            Title = "Save preset",
            Content = name,
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel"
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
        foreach (var speed in new[] { 0.25, 0.5, 1, 1.5, 2, 3, 4, 6, 8 })
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
            session.Shortcuts());
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

        ShowCropOverlay(still.Item1, still.Width, still.Height);
    }

    private void ShowCropOverlay(byte[] bgra, int width, int height)
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
        var start = session.Document.Canvas.CropRect01;
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
        var apply = new Button { Style = Ui.StyleOf("NsPrimaryButton"), Content = "Apply" };
        apply.Click += (_, _) =>
        {
            var crop = new Rect01(left, top, right - left, bottom - top);
            session.Mutate(document => document.Canvas.CropRect01 = crop);
            Close();
        };
        buttons.Children.Add(apply);
        var stack = new StackPanel { Spacing = 16, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
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

    public static async Task Open(string path, XamlRoot? xamlRoot)
    {
        try
        {
            var project = await Task.Run(() => new LoadedProject(path));
            new EditorWindow(EditorSource.Package(path, project)).Activate();
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
                    Title = "Could not open this project",
                    Content = $"{path}\n\n{exception.Message}",
                    CloseButtonText = "OK"
                }.ShowAsync();
            }
        }
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
                    CloseButtonText = "OK"
                }.ShowAsync();
            }
        }
    }
}
