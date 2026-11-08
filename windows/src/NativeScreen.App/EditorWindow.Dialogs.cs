using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using NativeScreen.Core;
using NativeScreen.Export;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;

namespace NativeScreen.App;

/// <summary>The export settings and still frame modals, laid out like ExportSettingsModalView and ExportStillFrameModalView on macOS.</summary>
public sealed partial class EditorWindow
{
    private static readonly (string Title, int Height)[] StillResolutions = [("480P", 480), ("720P", 720), ("1080P", 1080), ("2K", 1440), ("4K", 2160), ("8K", 4320)];

    private bool exportToClipboard;
    private bool exportAdvancedOpen;
    private bool stillBusy;

    private void ExportBackdropTapped(object sender, TappedRoutedEventArgs e)
    {
        if (exportCancel is null && !stillBusy)
        {
            ExportOverlay.Visibility = Visibility.Collapsed;
        }
    }

    // MARK: Export settings

    private void ShowExport(object sender, RoutedEventArgs e) => ShowExportOverlay();

    private void ShowExportOverlay()
    {
        exportSettings.Normalize();
        ExportCard.Width = 740;
        ExportCard.Height = double.NaN;
        ExportCard.Padding = new Thickness(28, 26, 28, 26);
        ExportBody.Spacing = 26;
        ExportBody.Children.Clear();
        ExportBody.Children.Add(ExportColumns(FormatSection(), FrameRateSection()));
        ExportBody.Children.Add(ExportColumns(ResolutionSection(), exportSettings.Format == ExportFormat.Gif ? GifSection() : CompressionSection()));
        ExportBody.Children.Add(ExportFooter());
        ExportOverlay.Visibility = Visibility.Visible;
    }

    private static Grid ExportColumns(UIElement left, UIElement right)
    {
        var grid = new Grid { ColumnSpacing = 36 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(224) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.Children.Add(left);
        Grid.SetColumn((FrameworkElement)right, 1);
        grid.Children.Add(right);
        return grid;
    }

    private static StackPanel ExportSection(string title, string glyph)
    {
        title = Loc.T(title);
        var section = new StackPanel { Spacing = 10 };
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        header.Children.Add(new Border
        {
            Width = 22,
            Height = 22,
            CornerRadius = new CornerRadius(6),
            Background = Ui.Pal("Ink07"),
            Child = Ui.Icon(glyph, 11, Ui.Pal("Ink60"))
        });
        header.Children.Add(Ui.Text(title, 13.5, "Ink95", true));
        section.Children.Add(header);
        return section;
    }

    private static Button ExportPill(string title, bool selected, Action? click, double height = 36)
    {
        var pill = Ui.Option(title, selected, click);
        pill.Height = height;
        pill.CornerRadius = new CornerRadius(9);
        pill.HorizontalAlignment = HorizontalAlignment.Stretch;
        pill.MinWidth = 0;
        pill.Padding = new Thickness(4, 0, 4, 0);
        Ui.Tip(pill, null);
        return pill;
    }

    private static Grid PillRow(params Button[] pills)
    {
        var grid = new Grid { ColumnSpacing = 6 };
        for (var index = 0; index < pills.Length; index++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition());
            Grid.SetColumn(pills[index], index);
            grid.Children.Add(pills[index]);
        }

        return grid;
    }

    private Action ExportChange(Action change) => () =>
    {
        change();
        ShowExportOverlay();
    };

    private void SetExportFormat(ExportFormat format)
    {
        exportSettings.Format = format;
        if (format == ExportFormat.Gif && exportSettings.Fps > 30)
        {
            exportSettings.Fps = 15;
        }
        else if (format != ExportFormat.Gif && exportSettings.Fps < 24)
        {
            exportSettings.Fps = 60;
        }
    }

    private StackPanel FormatSection()
    {
        var section = ExportSection("Format", "");
        section.Children.Add(PillRow(
            ExportPill("MP4", exportSettings.Format == ExportFormat.Mp4, ExportChange(() => SetExportFormat(ExportFormat.Mp4))),
            ExportPill("GIF", exportSettings.Format == ExportFormat.Gif, ExportChange(() => SetExportFormat(ExportFormat.Gif)))));
        return section;
    }

    private StackPanel FrameRateSection()
    {
        var section = ExportSection("Frame rate", "");
        var rates = ExportSettings.AllowedFps(exportSettings.Format);
        var picker = new ComboBox { Height = 36, HorizontalAlignment = HorizontalAlignment.Stretch, CornerRadius = new CornerRadius(9) };
        A11y.Name(picker, "Frame rate");
        foreach (var rate in rates)
        {
            picker.Items.Add($"{rate} FPS");
        }

        picker.SelectedIndex = rates.IndexOf(exportSettings.Fps);
        picker.SelectionChanged += (_, _) =>
        {
            if (picker.SelectedIndex >= 0)
            {
                exportSettings.Fps = rates[picker.SelectedIndex];
                // The dropdown is still closing, so the estimate is rebuilt after it.
                DispatcherQueue.TryEnqueue(ShowExportOverlay);
            }
        };
        section.Children.Add(picker);
        return section;
    }

    private StackPanel ResolutionSection()
    {
        var section = ExportSection("Resolution", "");
        var enabled = exportSettings.EnabledHeights();
        section.Children.Add(PillRow(ExportSettings.Heights(exportSettings.Format)
            .Select(height =>
            {
                var chosen = height;
                return ExportPill(height == 2160 ? "4K" : $"{height}p", exportSettings.ResolutionHeight == height, enabled.Contains(height) ? ExportChange(() => exportSettings.ResolutionHeight = chosen) : null);
            })
            .ToArray()));
        var aspect = session.Document.Canvas.EffectiveAspectRatio(source.SourceWidth, source.SourceHeight);
        var (width, height) = exportSettings.OutputSize(aspect);
        section.Children.Add(Ui.Text($"{width}px × {height}px", 12.5, "Ink45"));
        if (exportSettings.Format == ExportFormat.Gif && exportSettings.ResolutionHeight >= 1080)
        {
            section.Children.Add(Ui.Text("Will result in a large file size", 12.5, "Ink60"));
        }

        return section;
    }

    private StackPanel CompressionSection()
    {
        var section = ExportSection("Compression", "");
        var current = exportSettings.Compression;
        section.Children.Add(PillRow(
            CompressionPill("Studio", ExportCompression.Studio),
            CompressionPill("Social", ExportCompression.SocialMedia),
            CompressionPill("Web", ExportCompression.Web),
            CompressionPill("Web (Low)", ExportCompression.WebLow)));
        section.Children.Add(Ui.Text(current switch
        {
            ExportCompression.SocialMedia => "Good for sharing on social media, etc. Compression is noticeable when taking a good look. Keep in mind that social media server might further compress the video.",
            ExportCompression.Web => "Good for directly playing on websites. Compression is slightly visible, but not distracting.",
            ExportCompression.WebLow => "Good for sharing on the web, where quality is less important, increasing loading speed. Compression is clearly visible.",
            _ => "Highest quality, best for further editing. Compression is almost impossible to notice."
        }, 12.5, "Ink60"));
        section.Children.Add(Ui.Text("Quality setting does not impact export speed.", 12.5, "Ink45"));

        var chevron = Ui.Icon(exportAdvancedOpen ? "" : "", 10, Ui.Pal("Ink60"));
        var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        label.Children.Add(chevron);
        label.Children.Add(Ui.Text("Advanced", 13, "Ink88"));
        var advanced = new Button { Style = Ui.StyleOf("NsIconButton"), Content = label, Width = double.NaN, Height = 28, Padding = new Thickness(4, 0, 8, 0), HorizontalAlignment = HorizontalAlignment.Left };
        A11y.Name(advanced, "Advanced");
        advanced.Click += (_, _) =>
        {
            exportAdvancedOpen = !exportAdvancedOpen;
            ShowExportOverlay();
        };
        section.Children.Add(advanced);
        if (exportAdvancedOpen)
        {
            var codecs = new List<Button>
            {
                CodecPill("H.264", Mp4CodecOption.H264),
                CodecPill("HEVC", Mp4CodecOption.H265)
            };
            if (!exportToClipboard)
            {
                codecs.Add(CodecPill("Both", Mp4CodecOption.Both));
            }

            section.Children.Add(Ui.Text("Codec", 13, "Ink88"));
            section.Children.Add(PillRow(codecs.ToArray()));
            section.Children.Add(Ui.Text(exportSettings.Mp4Codec switch
            {
                Mp4CodecOption.H265 => "Better quality to file size ratio than H.264. Not every player can open it.",
                Mp4CodecOption.Both => "Saves both an H.264 and an HEVC file next to each other. Export may be slower, since it has to encode two files at once.",
                _ => "Great compatibility. Can play literally everywhere. Worse quality to file size ratio than HEVC."
            }, 12.5, "Ink60"));
        }

        return section;
    }

    private Button CompressionPill(string title, ExportCompression compression) =>
        ExportPill(title, exportSettings.Compression == compression, ExportChange(() => exportSettings.Compression = compression));

    private Button CodecPill(string title, Mp4CodecOption codec) =>
        ExportPill(title, exportSettings.Mp4Codec == codec, ExportChange(() => exportSettings.Mp4Codec = codec));

    private StackPanel GifSection()
    {
        var section = new StackPanel { Spacing = 14 };
        section.Children.Add(GifToggle("High quality", "Keeps more detail and fewer compression artifacts, for a larger file. Turn off for the best balance of file size and quality.", exportSettings.GifHighQuality, value => exportSettings.GifHighQuality = value));
        section.Children.Add(GifToggle("Disable loop", "Exported GIF will only play once and then stop.", exportSettings.GifDisableLoop, value => exportSettings.GifDisableLoop = value));
        return section;
    }

    private UIElement GifToggle(string title, string description, bool value, Action<bool> change)
    {
        title = Loc.T(title);
        description = Loc.T(description);
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var text = new StackPanel { Spacing = 4 };
        text.Children.Add(Ui.Text(title, 13.5, "Ink95", true));
        text.Children.Add(Ui.Text(description, 12.5, "Ink60"));
        grid.Children.Add(text);
        var toggle = new ToggleSwitch { IsOn = value, OnContent = "", OffContent = "", MinWidth = 0 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(toggle, title);
        toggle.Toggled += (_, _) => ExportChange(() => change(toggle.IsOn))();
        Grid.SetColumn(toggle, 1);
        grid.Children.Add(toggle);
        return grid;
    }

    private StackPanel ExportFooter()
    {
        var footer = new StackPanel { Spacing = 12 };
        footer.Children.Add(new Border { Height = 1, Background = Ui.Pal("Ink10") });
        var row = new Grid { ColumnSpacing = 10 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(190) });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(Ui.Text("Export to", 13, "Ink88"));
        var targets = PillRow(
            ExportPill("File", !exportToClipboard, ExportChange(() => exportToClipboard = false), 38),
            ExportPill("Clipboard", exportToClipboard, ExportChange(() =>
            {
                exportToClipboard = true;
                if (exportSettings.Mp4Codec == Mp4CodecOption.Both)
                {
                    exportSettings.Mp4Codec = Mp4CodecOption.H264;
                }
            }), 38));
        Grid.SetColumn(targets, 1);
        row.Children.Add(targets);
        var cancel = ExportPill("Cancel", false, () => ExportOverlay.Visibility = Visibility.Collapsed, 38);
        cancel.Padding = new Thickness(16, 0, 16, 0);
        Grid.SetColumn(cancel, 3);
        row.Children.Add(cancel);
        var start = new Button { Style = Ui.StyleOf("NsPrimaryButton"), Content = exportToClipboard ? "Export to clipboard" : "Export to file...", Height = 38, CornerRadius = new CornerRadius(9) };
        start.Click += (_, _) => _ = StartExport();
        Grid.SetColumn(start, 4);
        row.Children.Add(start);
        footer.Children.Add(row);

        var aspect = session.Document.Canvas.EffectiveAspectRatio(source.SourceWidth, source.SourceHeight);
        var time = ExportEstimator.DurationString(exportSettings, aspect, session.DurationMs);
        var size = ExportEstimator.SizeString(exportSettings, aspect, session.DurationMs);
        var estimate = Ui.Text($"Estimation: Export time {time}, Output size {size}", 12.5, "Ink45");
        estimate.HorizontalAlignment = HorizontalAlignment.Right;
        footer.Children.Add(estimate);
        if (exportSettings.Format == ExportFormat.Gif)
        {
            var note = Ui.Text("GIF files are much larger than MP4 files. Use MP4 when you can.", 12.5, "Ink45");
            note.HorizontalAlignment = HorizontalAlignment.Right;
            footer.Children.Add(note);
        }

        return footer;
    }

    private async Task StartExport()
    {
        var gif = exportSettings.Format == ExportFormat.Gif;
        var extension = gif ? ".gif" : ".mp4";
        if (exportToClipboard)
        {
            var directory = Directory.CreateTempSubdirectory("ns-clipboard-").FullName;
            var temporary = Path.Combine(directory, session.Document.Name + extension);
            await RunExport(temporary, Path.GetFileName(temporary), toClipboard: true);
            return;
        }

        var picker = new Windows.Storage.Pickers.FileSavePicker { SuggestedFileName = session.Document.Name };
        picker.FileTypeChoices.Add(gif ? "GIF" : "MP4", new List<string> { extension });
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        var file = await picker.PickSaveFileAsync();
        if (file is not null)
        {
            await RunExport(file.Path, file.Name);
        }
    }

    private async Task RunExport(string filePath, string fileName, bool toClipboard = false)
    {
        var cancel = new CancellationTokenSource();
        exportCancel = cancel;
        var started = DateTime.UtcNow;
        ExportBody.Children.Clear();
        ExportBody.Spacing = 14;
        var title = Ui.Text("Exporting video • 0%", 19, "Ink95", true);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        var bar = new ProgressBar { Minimum = 0, Maximum = 1, Value = 0, Width = 320, Height = 6, HorizontalAlignment = HorizontalAlignment.Center };
        var time = Ui.Text("Preparing export...", 13.5, "Ink60");
        time.HorizontalAlignment = HorizontalAlignment.Center;
        var stop = Ui.Option("Stop export", false, cancel.Cancel);
        stop.HorizontalAlignment = HorizontalAlignment.Center;
        ExportBody.Children.Add(title);
        ExportBody.Children.Add(bar);
        ExportBody.Children.Add(time);
        ExportBody.Children.Add(stop);
        ExportOverlay.Visibility = Visibility.Visible;

        // Both codecs write <name>.mp4 and <name>-hevc.mp4 one after the other; progress covers the pair.
        var both = exportSettings.Format == ExportFormat.Mp4 && exportSettings.Mp4Codec == Mp4CodecOption.Both;
        var passes = both ? 2 : 1;
        var pass = 0;
        var progress = new Progress<ExportProgress>(update =>
        {
            var share = (pass + update.Encoded / (double)Math.Max(1, update.Total)) / passes;
            bar.Value = share;
            title.Text = $"Exporting video • {share:P0}";
            var elapsed = DateTime.UtcNow - started;
            var left = share > 0 ? elapsed * (1 / share - 1) : TimeSpan.Zero;
            time.Text = $"{(int)elapsed.TotalMinutes:00}:{elapsed.Seconds:00} • {(int)left.TotalMinutes:00}:{left.Seconds:00} left";
        });
        var exporter = new ProjectExporter(CurrentExportSource());
        try
        {
            if (both)
            {
                await exporter.RunAsync(filePath, CopySettings(Mp4CodecOption.H264), progress, cancel.Token);
                pass = 1;
                var hevc = Path.Combine(Path.GetDirectoryName(filePath) ?? "", Path.GetFileNameWithoutExtension(filePath) + "-hevc.mp4");
                await exporter.RunAsync(hevc, CopySettings(Mp4CodecOption.H265), progress, cancel.Token);
            }
            else
            {
                await exporter.RunAsync(filePath, exportSettings, progress, cancel.Token);
            }

            if (toClipboard)
            {
                var package = new DataPackage();
                package.SetStorageItems(new[] { await StorageFile.GetFileFromPathAsync(filePath) });
                Clipboard.SetContent(package);
                ShowToast("Video copied to clipboard");
            }
            else
            {
                ShowToast($"Exported {fileName}");
            }
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

    private ExportSettings CopySettings(Mp4CodecOption codec) => new()
    {
        Format = exportSettings.Format,
        Fps = exportSettings.Fps,
        ResolutionHeight = exportSettings.ResolutionHeight,
        Compression = exportSettings.Compression,
        Mp4Codec = codec
    };

    /// <summary>The After Recording action: the editor is open, then the export runs with the current settings.</summary>
    public void ExportAfterOpening(string action)
    {
        if (action is not ("clipboard" or "file"))
        {
            return;
        }

        exportToClipboard = action == "clipboard";
        Root.Loaded += (_, _) => _ = StartExport();
    }

    // MARK: Still frame

    private void ShowFrameExport(object sender, RoutedEventArgs e) => ShowFrameExportOverlay();

    private void ShowFrameExportOverlay()
    {
        var sourceMs = session.SourceAtPlayhead;
        var name = new TextBox { Text = $"{session.Document.Name}({sourceMs / 1000:0.##}s)", Height = 32 };
        A11y.Name(name, "Name");
        var folder = AppSettings.Shared.StillExportFolder is { Length: > 0 } remembered && Directory.Exists(remembered)
            ? remembered
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        var folderText = new TextBlock { Text = folder, FontSize = 12.5, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, Foreground = Ui.Pal("Ink60") };
        Ui.Tip(folderText, folder);

        ExportCard.Width = 660;
        ExportCard.Height = 460;
        ExportCard.Padding = new Thickness(0);
        ExportBody.Spacing = 0;
        ExportBody.Children.Clear();
        var heading = Ui.Text("Export still frames", 14, "Ink95", true);
        heading.Margin = new Thickness(22, 16, 22, 16);
        ExportBody.Children.Add(heading);
        ExportBody.Children.Add(new Border { Height = 1, Background = Ui.Pal("Ink10") });

        var content = new Grid { ColumnSpacing = 22, Padding = new Thickness(22), Height = 342 };
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(240) });
        content.ColumnDefinitions.Add(new ColumnDefinition());
        var image = new Image { Stretch = Stretch.Uniform };
        content.Children.Add(new Border { Width = 240, Height = 298, CornerRadius = new CornerRadius(8), Background = Ui.Rgb(0, 0, 0, 0.45), Child = image });

        var form = new StackPanel { Spacing = 14 };
        Grid.SetColumn(form, 1);
        form.Children.Add(StillRow("Name", name));
        var folderRow = new Grid { ColumnSpacing = 6 };
        folderRow.ColumnDefinitions.Add(new ColumnDefinition());
        folderRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        folderRow.Children.Add(folderText);
        var pick = Ui.IconButton(Ui.Icon("", 13), "Choose folder", async () =>
        {
            var picker = new Windows.Storage.Pickers.FolderPicker();
            picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
            if (await picker.PickSingleFolderAsync() is { } chosen)
            {
                folder = chosen.Path;
                folderText.Text = folder;
                Ui.Tip(folderText, folder);
            }
        }, 30);
        Grid.SetColumn(pick, 1);
        folderRow.Children.Add(pick);
        form.Children.Add(StillRow("Export to", folderRow));
        var resolution = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        A11y.Name(resolution, "Resolution");
        foreach (var (title, _) in StillResolutions)
        {
            resolution.Items.Add(title);
        }

        resolution.SelectedIndex = Math.Max(0, Array.FindIndex(StillResolutions, item => item.Height == stillHeight));
        resolution.SelectionChanged += (_, _) => stillHeight = StillResolutions[Math.Max(0, resolution.SelectedIndex)].Height;
        form.Children.Add(StillRow("Resolution", resolution));
        var formats = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch };
        void FillFormats() => formats.Content = PillRow(
            ExportPill("PNG", stillFormat == "png", () =>
            {
                stillFormat = "png";
                FillFormats();
            }, 32),
            ExportPill("JPEG", stillFormat == "jpg", () =>
            {
                stillFormat = "jpg";
                FillFormats();
            }, 32));
        FillFormats();
        form.Children.Add(StillRow("Format", formats));
        content.Children.Add(form);
        ExportBody.Children.Add(content);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(22, 8, 22, 0) };
        var cancel = ExportPill("Cancel", false, () => ExportOverlay.Visibility = Visibility.Collapsed, 34);
        cancel.Width = 88;
        var export = new Button { Style = Ui.StyleOf("NsPrimaryButton"), Content = Loc.T("Export"), Width = 92, Height = 34, CornerRadius = new CornerRadius(9) };
        export.Click += (_, _) => _ = ExportStill(name.Text, folder, export);
        buttons.Children.Add(cancel);
        buttons.Children.Add(export);
        ExportBody.Children.Add(buttons);
        ExportOverlay.Visibility = Visibility.Visible;
        _ = LoadStillPreview(image, sourceMs);
    }

    private static Grid StillRow(string title, UIElement field)
    {
        title = Loc.T(title);
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(96) });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.Children.Add(Ui.Text(title, 13, "Ink88"));
        Grid.SetColumn((FrameworkElement)field, 1);
        row.Children.Add(field);
        return row;
    }

    private async Task LoadStillPreview(Image image, double sourceMs)
    {
        var directory = Directory.CreateTempSubdirectory("ns-still-").FullName;
        var path = Path.Combine(directory, "preview.png");
        try
        {
            await new ProjectExporter(CurrentExportSource()).ExportStillAsync(path, sourceMs, 900, false);
            image.Source = new BitmapImage(new Uri(path));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or SharpGen.Runtime.SharpGenException)
        {
            ShowToast($"Could not render the preview: {exception.Message}");
        }
    }

    private async Task ExportStill(string name, string folder, Button button)
    {
        var jpeg = stillFormat == "jpg";
        var safeName = string.Concat(name.Split(Path.GetInvalidFileNameChars())).Trim();
        var path = Path.Combine(folder, (safeName.Length == 0 ? "frame" : safeName) + (jpeg ? ".jpg" : ".png"));
        if (File.Exists(path))
        {
            var replace = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = $"\"{Path.GetFileName(path)}\" already exists",
                Content = Loc.T("Do you want to replace it?"),
                PrimaryButtonText = Loc.T("Replace"),
                CloseButtonText = Loc.T("Cancel"),
                DefaultButton = ContentDialogButton.Close
            };
            if (await replace.ShowAsync() != ContentDialogResult.Primary)
            {
                return;
            }
        }

        stillBusy = true;
        button.Content = Loc.T("Exporting...");
        button.IsEnabled = false;
        try
        {
            await new ProjectExporter(CurrentExportSource()).ExportStillAsync(path, session.SourceAtPlayhead, stillHeight, jpeg);
            AppSettings.Shared.StillExportFolder = folder;
            AppSettings.Shared.Save();
            ExportOverlay.Visibility = Visibility.Collapsed;
            System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{path}\"")?.Dispose();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or SharpGen.Runtime.SharpGenException)
        {
            ExportOverlay.Visibility = Visibility.Collapsed;
            ShowToast($"Export failed: {exception.Message}");
        }
        finally
        {
            stillBusy = false;
        }
    }
}
