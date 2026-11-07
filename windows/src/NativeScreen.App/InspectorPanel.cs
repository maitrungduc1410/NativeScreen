using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using NativeScreen.Core;
using ZoomMode = NativeScreen.Core.ZoomMode;

namespace NativeScreen.App;

/// <summary>Builds the inspector for the selected tab or timeline block. Every control writes to the session document.</summary>
internal sealed class InspectorPanel
{
    private static readonly string[] CuratedSolidColors =
    [
        "#4776E6", "#8E54E9", "#1E1E2E", "#0F172A", "#2563EB", "#7C3AED", "#DB2777", "#EA580C",
        "#059669", "#0D9488", "#4F46E5", "#9333EA", "#E11D48", "#D97706", "#16A34A", "#0284C7"
    ];

    private static readonly (string Start, string End)[] CuratedGradientPairs =
    [
        ("#E2E8F0", "#CBD5E1"), ("#BFDBFE", "#93C5FD"), ("#FED7AA", "#FDBA74"), ("#C7D2FE", "#A5B4FC"),
        ("#CCFBF1", "#99F6E4"), ("#D9F99D", "#BEF264"), ("#FDBA74", "#F472B6"), ("#FDE047", "#F97316"),
        ("#FB7185", "#EA580C"), ("#F97316", "#EAB308"), ("#C084FC", "#FDBA74"), ("#FB923C", "#4F46E5"),
        ("#38BDF8", "#60A5FA"), ("#22D3EE", "#3B82F6"), ("#2DD4BF", "#0284C7"), ("#34D399", "#059669"),
        ("#4ADE80", "#1E3A8A"), ("#38BDF8", "#1E40AF"), ("#4776E6", "#8E54E9"), ("#7C3AED", "#DB2777"),
        ("#0EA5E9", "#312E81"), ("#EC4899", "#6366F1"), ("#F472B6", "#60A5FA"), ("#38BDF8", "#A855F7"),
        ("#1E293B", "#0F172A"), ("#1E3A8A", "#0F172A"), ("#7F1D1D", "#1E1B4B"), ("#C026D3", "#31102F"),
        ("#64748B", "#334155"), ("#27272A", "#09090B")
    ];

    private readonly EditorSession session;
    private readonly ScrollViewer scroller;
    private readonly StackPanel body;
    private readonly bool hasCamera;
    private readonly EditorTools tools;
    private readonly HashSet<string> expanded = [];
    private const string WindowsWallpapers = "Windows";
    private const double StripBleed = 20;

    private static readonly Dictionary<string, Microsoft.UI.Xaml.Media.Imaging.BitmapImage> WallpaperThumbnails = [];

    private readonly Dictionary<string, StripState> strips = [];
    private string? wallpaperCategory;
    private string? selectedShortcutTrackId;
    private IReadOnlyList<WallpaperItem>? systemWallpapers;

    public InspectorPanel(EditorSession session, ScrollViewer scroller, StackPanel body, bool hasCamera, EditorTools tools)
    {
        this.session = session;
        this.scroller = scroller;
        this.body = body;
        this.hasCamera = hasCamera;
        this.tools = tools;
    }

    private ProjectDocument Doc => session.Document;

    public void Rebuild()
    {
        var offset = scroller.VerticalOffset;
        body.Children.Clear();
        if (session.SelectedZoom is { } zoom)
        {
            ZoomEditor(zoom);
        }
        else if (session.SelectedMask is { } mask)
        {
            MaskEditor(mask);
        }
        else if (session.SelectedSlice is { } slice)
        {
            ClipEditor(slice);
        }
        else if (session.SelectedLayout is { } layout)
        {
            LayoutEditor(layout);
        }
        else if (session.SelectedShortcut is { } shortcut)
        {
            ShortcutEditor(shortcut);
        }        else
        {
            switch (session.SelectedTab)
            {
                case InspectorTab.Background: General(); break;
                case InspectorTab.Cursor: Cursor(); break;
                case InspectorTab.CameraLayout: CameraLayout(); break;
                case InspectorTab.CameraStyle: CameraStyle(); break;
                case InspectorTab.Captions: Captions(); break;
                case InspectorTab.Transcript: Transcript(); break;
                case InspectorTab.Audio: Audio(); break;
                case InspectorTab.Shortcuts: Shortcuts(); break;
                case InspectorTab.Zoom: Animations(); break;
                case InspectorTab.DeviceFrame: DeviceFrame(); break;
                case InspectorTab.Masks: Masks(); break;
            }
        }

        scroller.UpdateLayout();
        scroller.ChangeView(null, offset, null, true);
    }

    // MARK: Tabs

    private double gradientHueShift = 0.5;

    private void General()
    {
        var background = Doc.Background;
        var isWallpaper = background.Type is BackgroundType.Mesh or BackgroundType.Wallpaper;
        Add(Labeled("Background", 10, Options(
            ("Wallpaper", isWallpaper, () => Edit(d =>
            {
                // Return to the last picked wallpaper. A custom image shares the path field, so it doesn't count.
                var hasWallpaper = d.Background.SystemWallpaperName is not null
                    && d.Background.WallpaperRelativePath?.StartsWith("assets/background", StringComparison.Ordinal) == true;
                d.Background.Type = hasWallpaper ? BackgroundType.Wallpaper : BackgroundType.Mesh;
            })),
            ("Gradient", background.Type == BackgroundType.Gradient, () => Edit(d => d.Background.Type = BackgroundType.Gradient)),
            ("Color", background.Type == BackgroundType.Solid, () => Edit(d => d.Background.Type = BackgroundType.Solid)),
            ("Image", background.Type == BackgroundType.Image, tools.PickBackgroundImage))));

        if (background.Type == BackgroundType.Image)
        {
            var drop = new Border { Height = 96, CornerRadius = new CornerRadius(10), Background = Ui.Pal("Ink04"), BorderBrush = Ui.Pal("Ink14"), BorderThickness = new Thickness(1), AllowDrop = true, Padding = new Thickness(12) };
            drop.Child = new TextBlock { Text = Loc.T("Click to select, drop image, or press Ctrl+V while hovering."), FontSize = 12.5, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Foreground = Ui.Pal("Ink60") };
            drop.Tapped += (_, _) => tools.PickBackgroundImage();
            drop.PointerEntered += (_, _) => tools.IsHoveringBackgroundDrop = true;
            drop.PointerExited += (_, _) => tools.IsHoveringBackgroundDrop = false;
            drop.Unloaded += (_, _) => tools.IsHoveringBackgroundDrop = false;
            drop.DragOver += (_, args) => args.AcceptedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Copy;
            drop.Drop += async (_, args) =>
            {
                if (args.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems)
                    && (await args.DataView.GetStorageItemsAsync()).OfType<Windows.Storage.StorageFile>().FirstOrDefault() is { } file)
                {
                    tools.SetBackgroundImage(file.Path);
                }
            };
            Add(Labeled("Background Image", 10, drop));
        }

        if (isWallpaper)
        {
            wallpaperCategory ??= background.Type == BackgroundType.Mesh ? "Mesh" : BundledWallpaperCatalog.CategoryOf(background.SystemWallpaperName) ?? WindowsWallpapers;
            var row = StripRow(7);
            FrameworkElement? selectedPill = null;
            foreach (var category in new[] { "All", WindowsWallpapers, "Mesh" }.Concat(BundledWallpaperCatalog.Categories))
            {
                var name = category;
                var pill = Ui.Option(name == "All" ? "★" : name, name == wallpaperCategory, () =>
                {
                    wallpaperCategory = name;
                    Rebuild();
                });
                selectedPill = name == wallpaperCategory ? pill : selectedPill;
                row.Children.Add(pill);
            }

            var strip = Strip("wallpaper-category", row, wallpaperCategory, selectedPill);

            // The items of the current pill. The random button draws from the same lists.
            systemWallpapers ??= EditorTools.SystemWallpapers();
            IReadOnlyList<MeshPreset> meshes = wallpaperCategory is "All" or "Mesh" ? MeshPreset.BuiltIn : [];
            IReadOnlyList<WallpaperItem> wallpapers = wallpaperCategory switch
            {
                "All" => [.. BundledWallpaperCatalog.AllItems, .. systemWallpapers],
                WindowsWallpapers => systemWallpapers,
                _ => BundledWallpaperCatalog.Items(wallpaperCategory)
            };
            var swatches = SwatchGrid();
            foreach (var preset in meshes)
            {
                var id = preset.Id;
                swatches.Children.Add(Swatch(
                    Ui.Gradient(Ui.Hex(preset.ColorsHex[0]), Ui.Hex(preset.ColorsHex[2]), vertical: false),
                    preset.Name,
                    background.Type == BackgroundType.Mesh && background.MeshPresetId == id,
                    () => Edit(d =>
                    {
                        d.Background.Type = BackgroundType.Mesh;
                        d.Background.MeshPresetId = id;
                    })));
            }

            foreach (var item in wallpapers)
            {
                var target = item;
                var selected = background.Type == BackgroundType.Wallpaper && background.SystemWallpaperName == item.Id;
                swatches.Children.Add(Swatch(WallpaperThumbnail(item), item.Id, selected, () => tools.SelectWallpaper(target)));
            }

            Add(Action("Pick random wallpaper", () =>
            {
                var pick = Random.Shared.Next(Math.Max(meshes.Count + wallpapers.Count, 1));
                if (pick < meshes.Count)
                {
                    var picked = meshes[pick];
                    Edit(d =>
                    {
                        d.Background.Type = BackgroundType.Mesh;
                        d.Background.MeshPresetId = picked.Id;
                    });
                }
                else if (pick - meshes.Count < wallpapers.Count)
                {
                    tools.SelectWallpaper(wallpapers[pick - meshes.Count]);
                }
            }));
            Add(Labeled("Wallpaper", 10, strip, swatches));
        }
        else if (background.Type == BackgroundType.Gradient)
        {
            var swatches = SwatchGrid();
            foreach (var (start, end) in CuratedGradientPairs)
            {
                var from = start;
                var to = end;
                var stops = background.Gradient.Stops;
                var selected = stops.Count >= 2 && stops[0].Color == from && stops[^1].Color == to;
                swatches.Children.Add(Swatch(Ui.Gradient(Ui.Hex(from), Ui.Hex(to), vertical: false), $"{from} to {to}", selected, () => Edit(d =>
                    d.Background.Gradient.Stops = [new GradientStopConfig(from, 0), new GradientStopConfig(to, 1)])));
            }

            var first = background.Gradient.Stops.Count > 0 ? background.Gradient.Stops[0].Color : "#000000";
            var last = background.Gradient.Stops.Count > 1 ? background.Gradient.Stops[^1].Color : first;
            void SetStops(ProjectDocument d, string from, string to) => d.Background.Gradient.Stops = [new GradientStopConfig(from, 0), new GradientStopConfig(to, 1)];
            var fields = new Grid { ColumnSpacing = 8 };
            fields.ColumnDefinitions.Add(new ColumnDefinition());
            fields.ColumnDefinitions.Add(new ColumnDefinition());
            var startField = ColorField.Create("Gradient start", first, hex => session.Mutate(d => SetStops(d, hex, d.Background.Gradient.Stops[^1].Color), "gradient-color", structural: false), hex => Edit(d => SetStops(d, hex, d.Background.Gradient.Stops[^1].Color)));
            var endField = ColorField.Create("Gradient end", last, hex => session.Mutate(d => SetStops(d, d.Background.Gradient.Stops[0].Color, hex), "gradient-color", structural: false), hex => Edit(d => SetStops(d, d.Background.Gradient.Stops[0].Color, hex)));
            Grid.SetColumn(endField, 1);
            fields.Children.Add(startField);
            fields.Children.Add(endField);
            Add(Labeled("Gradient colors", 10, fields));
            Add(Action("Pick random gradient", () =>
            {
                var (randomStart, randomEnd) = CuratedGradientPairs[Random.Shared.Next(CuratedGradientPairs.Length)];
                Edit(d => SetStops(d, randomStart, randomEnd));
            }));
            var hue = new Slider { Minimum = 0, Maximum = 1, StepFrequency = 0.005, Value = gradientHueShift, IsThumbToolTipEnabled = false };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(hue, "Hue");
            hue.ValueChanged += (_, args) =>
            {
                var delta = args.NewValue - gradientHueShift;
                gradientHueShift = args.NewValue;
                session.Mutate(d => SetStops(d, ColorField.ShiftHue(d.Background.Gradient.Stops[0].Color, delta), ColorField.ShiftHue(d.Background.Gradient.Stops[^1].Color, delta)), "gradient-hue", structural: false);
            };
            Add(Labeled("Hue", 8, hue));
            Add(Labeled("Background Gradient", 10, swatches));
        }
        else if (background.Type == BackgroundType.Solid)
        {
            var swatches = SwatchGrid();
            foreach (var color in CuratedSolidColors)
            {
                var value = color;
                swatches.Children.Add(Swatch(new SolidColorBrush(Ui.Hex(value)), value, background.SolidColor == value, () => Edit(d => d.Background.SolidColor = value)));
            }

            Add(Labeled("Color", 10, ColorField.Create("Background color", background.SolidColor, hex => session.Mutate(d => d.Background.SolidColor = hex, "solid-color", structural: false), hex => Edit(d => d.Background.SolidColor = hex))));
            Add(Action("Pick random color", () =>
            {
                var picked = CuratedSolidColors[Random.Shared.Next(CuratedSolidColors.Length)];
                Edit(d => d.Background.SolidColor = picked);
            }));
            Add(Labeled("Background Color", 10, swatches));
        }

        Add(Slider("Background blur", () => Doc.Background.BlurRadius, (d, v) => d.Background.BlurRadius = v, 0, 40, 0));
        AddDivider();
        Add(Slider("Padding", () => Doc.Canvas.PaddingRatio, (d, v) => d.Canvas.PaddingRatio = v, 0, 0.30, 0.10));
        Add(Slider("Screen rounded corners", () => Doc.FrameStyle.BorderRadius, (d, v) => d.FrameStyle.BorderRadius = v, 0, 44, 16));
        Add(Toggle("Inset", "Add inset around the screen.", () => Doc.FrameStyle.Inset.Enabled, (d, v) => d.FrameStyle.Inset.Enabled = v));
        AddDivider();
        Add(Slider("Shadow", () => Doc.FrameStyle.Shadow.Intensity, (d, v) => d.FrameStyle.Shadow.Intensity = v, 0, 0.85, 0.42));
        Add(Options(
            ("Classic", !Doc.FrameStyle.Shadow.IsDirectional, () => Edit(d => d.FrameStyle.Shadow.IsDirectional = false)),
            ("Directional", Doc.FrameStyle.Shadow.IsDirectional, () => Edit(d => d.FrameStyle.Shadow.IsDirectional = true))));
        Add(Collapsible("Advanced shadow settings", () => Stack(18,
            Slider("Shadow Distance", () => Doc.FrameStyle.Shadow.Distance, (d, v) => d.FrameStyle.Shadow.Distance = v, 0, 80, 22),
            Slider("Shadow Angle", () => Doc.FrameStyle.Shadow.AngleDegrees, (d, v) => d.FrameStyle.Shadow.AngleDegrees = v, 0, 180, 90),
            Slider("Shadow Blur", () => Doc.FrameStyle.Shadow.Blur, (d, v) => d.FrameStyle.Shadow.Blur = v, 0, 60, 36))));
        AddDivider();
        Add(ToolToggle("Hide sensitive data", "Scan the recording on device and blur emails, keys and phone numbers.", Doc.Background.HideSensitiveData, tools.SetHideSensitive));
        if (Doc.Background.HideSensitiveData)
        {
            var phrases = new TextBox { PlaceholderText = Loc.T("Custom phrases, separated by commas"), Text = string.Join(", ", Doc.Background.SensitiveDataCustomPhrases) };
            phrases.LostFocus += (_, _) =>
            {
                if (phrases.Text != string.Join(", ", Doc.Background.SensitiveDataCustomPhrases))
                {
                    tools.SetSensitivePhrases(phrases.Text);
                }
            };
            Add(Labeled("Custom phrases", 8, phrases));
        }

        Add(ToolToggle("Hide faces", "Detect faces in the recording on device and blur them.", Doc.Background.HideFaces, tools.SetHideFaces));
        if (tools.Status is { } status)
        {
            Add(Note(status));
        }
    }

    private void Cursor()
    {
        Add(Toggle("Hide cursor", null, () => Doc.Cursor.Hidden, (d, v) => d.Cursor.Hidden = v));
        Add(Slider("Cursor size", () => Doc.Cursor.Scale, (d, v) => d.Cursor.Scale = v, 0.5, 3.5, 1.6));
        var themeRow = StripRow(8);
        var selectedThemeId = CursorSpriteName.NormalizeThemeId(Doc.Cursor.ThemeId);
        FrameworkElement? selectedTheme = null;
        foreach (var themeId in CursorSpriteName.PreferredThemeOrder)
        {
            var theme = themeId;
            var variants = CursorThemeCards.PointerVariants(theme);
            if (variants.Count > 0)
            {
                var isSelected = selectedThemeId == theme;
                var shown = isSelected ? variants.Find(item => item.Id == Doc.Cursor.VariantId).File ?? variants[0].File : variants[0].File;
                var card = CursorThemeCards.Card(shown, CursorThemeCards.DisplayName(theme), isSelected, () => Edit(d =>
                {
                    d.Cursor.ThemeId = theme;
                    d.Cursor.VariantId = variants.Exists(item => item.Id == d.Cursor.VariantId) ? d.Cursor.VariantId : variants[0].Id;
                }), hoverFiles: variants.Skip(1).Select(item => item.File).ToList());
                selectedTheme = isSelected ? card : selectedTheme;
                themeRow.Children.Add(card);
            }
        }

        Add(Labeled("Cursor style", 10, Strip("cursor-style", themeRow, selectedThemeId, selectedTheme)));
        var pointers = CursorThemeCards.PointerVariants(selectedThemeId);
        if (pointers.Count > 1)
        {
            var row = StripRow(8);
            var selectedVariant = Doc.Cursor.VariantId ?? pointers[0].Id;
            FrameworkElement? selectedCard = null;
            foreach (var (id, file) in pointers)
            {
                var chosen = id;
                var card = CursorThemeCards.Card(file, id, selectedVariant == id, () => Edit(d => d.Cursor.VariantId = chosen), 48, 26);
                selectedCard = selectedVariant == id ? card : selectedCard;
                row.Children.Add(card);
            }

            Add(Labeled("Cursor color", 10, Strip("cursor-color-" + selectedThemeId, row, selectedVariant, selectedCard)));
        }

        Add(Toggle("Always use pointer cursor", null, () => Doc.Cursor.AlwaysUsePointer, (d, v) => d.Cursor.AlwaysUsePointer = v));
        Add(Toggle("Hide cursor if not moving", null, () => Doc.Cursor.HideWhenIdleAfterMs is not null, (d, v) => d.Cursor.HideWhenIdleAfterMs = v ? 2000 : null));
        if (Doc.Cursor.HideWhenIdleAfterMs is not null)
        {
            Add(Slider("Hide not moving cursor after", () => (Doc.Cursor.HideWhenIdleAfterMs ?? 2000) / 1000, (d, v) => d.Cursor.HideWhenIdleAfterMs = v * 1000, 0.5, 5, 2));
        }

        Add(Toggle("Loop cursor position", "Near the end of the video, cursor will move back to its initial position", () => Doc.Cursor.LoopBackToStartMs is not null, (d, v) => d.Cursor.LoopBackToStartMs = v ? 1000 : null));
        if (Doc.Cursor.LoopBackToStartMs is not null)
        {
            Add(Slider("Loop cursor position duration", () => (Doc.Cursor.LoopBackToStartMs ?? 1000) / 1000, (d, v) => d.Cursor.LoopBackToStartMs = v * 1000, 1, 4, 1));
        }
        else
        {
            Add(Slider("Stop cursor movement at the end of the video", () => Doc.Cursor.StopMovementInLastPartMs, (d, v) => d.Cursor.StopMovementInLastPartMs = v, 0, 5000, 0));
        }

        AddDivider();
        var effect = Doc.Cursor.ClickEffect.VisualStyle;
        Add(Labeled("Click effect", 10, Options(
            ("None", effect == ClickEffectStyle.None, () => Edit(d => d.Cursor.ClickEffect.VisualStyle = ClickEffectStyle.None)),
            ("Circle", effect == ClickEffectStyle.Circle, () => Edit(d => d.Cursor.ClickEffect.VisualStyle = ClickEffectStyle.Circle)),
            ("Ripple", effect == ClickEffectStyle.Ripple, () => Edit(d => d.Cursor.ClickEffect.VisualStyle = ClickEffectStyle.Ripple)))));
        var sound = Doc.Cursor.ClickEffect.SoundSet;
        Add(Labeled("Click sound", 10, Options(
            ("None", sound is null, () => Edit(d => d.Cursor.ClickEffect.SoundSet = null)),
            ("Soft", sound == "soft", () => Edit(d => d.Cursor.ClickEffect.SoundSet = "soft")),
            ("Crisp", sound == "crisp", () => Edit(d => d.Cursor.ClickEffect.SoundSet = "crisp")))));
        if (sound is not null)
        {
            Add(Action("Play click sound preview", () => tools.PreviewClickSound()));
            Add(Slider("Click sound volume", () => Doc.Cursor.ClickEffect.SoundVolume, (d, v) => d.Cursor.ClickEffect.SoundVolume = v, 0, 1, 0.5));
        }

        AddDivider();
        Add(Collapsible("Rotation", () => Stack(16,
            Toggle("Rotate cursor", "How the cursor rotates as it chases the mouse.", () => Doc.Cursor.VelocityRotationEnabled, (d, v) => d.Cursor.VelocityRotationEnabled = v),
            Options(
                ("Tilt", Doc.Cursor.RotationMode == CursorRotationMode.Tilt, () => Edit(d => d.Cursor.RotationMode = CursorRotationMode.Tilt)),
                ("Follow", Doc.Cursor.RotationMode == CursorRotationMode.Follow, () => Edit(d => d.Cursor.RotationMode = CursorRotationMode.Follow))),
            Slider("Tilt amount", () => Doc.Cursor.VelocityRotationIntensity, (d, v) => d.Cursor.VelocityRotationIntensity = v, 0, 1, 0.5))));
        if (Doc.Cursor.RemoveShakeThresholdPx > 0.01)
        {
            Add(Slider("Remove cursor shakes threshold", () => Doc.Cursor.RemoveShakeThresholdPx, (d, v) => d.Cursor.RemoveShakeThresholdPx = v, 1, 20, 4));
        }

        Add(Collapsible("Advanced", () => Stack(16,
            Toggle("Remove cursor shakes", null, () => Doc.Cursor.RemoveShakeThresholdPx > 0, (d, v) => d.Cursor.RemoveShakeThresholdPx = v ? 4 : 0),
            Toggle("Optimize cursor changes", null, () => Doc.Cursor.OptimizeCursorChanges, (d, v) => d.Cursor.OptimizeCursorChanges = v),
            Toggle("Keep cursor in sync with hovers", null, () => Doc.Cursor.KeepInSyncWithHovers, (d, v) => d.Cursor.KeepInSyncWithHovers = v))));
    }

    /// <summary>Asks the window to open the crop editor on the webcam track.</summary>
    public Action? CameraCropRequested { get; set; }

    private static bool Rect01Full(Rect01 rect) => rect.X <= 0 && rect.Y <= 0 && rect.Width >= 1 && rect.Height >= 1;

    private void CameraLayout()
    {
        if (!hasCamera)
        {
            Add(Note("This recording has no camera video."));
            return;
        }

        var camera = Doc.Camera;
        Add(Toggle("Hide camera", null, () => !Doc.Camera.Enabled, (d, v) => d.Camera.Enabled = !v));
        Add(Labeled("Default layout", 10, Options(
            ("Overlay", camera.LayoutMode == CameraLayoutMode.Overlay, () => Edit(d => d.Camera.LayoutMode = CameraLayoutMode.Overlay)),
            ("Split", camera.LayoutMode == CameraLayoutMode.SplitScreen, () => Edit(d => d.Camera.LayoutMode = CameraLayoutMode.SplitScreen)),
            ("Cutout", camera.LayoutMode == CameraLayoutMode.Cutout, () => Edit(d => d.Camera.LayoutMode = CameraLayoutMode.Cutout)))));
        if (camera.LayoutMode == CameraLayoutMode.SplitScreen)
        {
            Add(Labeled("Split ratio", 10, Options(
                ("1/2", Math.Abs(camera.SplitScreenRatio01 - 0.5) < 0.01, () => Edit(d => d.Camera.SplitScreenRatio01 = 0.5)),
                ("1/3", Math.Abs(camera.SplitScreenRatio01 - 1.0 / 3) < 0.01, () => Edit(d => d.Camera.SplitScreenRatio01 = 1.0 / 3)),
                ("2/3", Math.Abs(camera.SplitScreenRatio01 - 2.0 / 3) < 0.01, () => Edit(d => d.Camera.SplitScreenRatio01 = 2.0 / 3)))));
            Add(Toggle("Flip", null, () => Doc.Camera.SplitFlip, (d, v) => d.Camera.SplitFlip = v));
            Add(Toggle("Padded", null, () => Doc.Camera.SplitEnablePadding, (d, v) => d.Camera.SplitEnablePadding = v));
        }
        else
        {
            Add(Labeled("Camera Position", 10, PositionGrid(Doc.Camera.Position01, target => Edit(d => d.Camera.Position01 = target))));
            Add(Labeled("Camera aspect ratio", 10, OptionsWrap(
                ("16:9", camera.AspectRatioPreset == CameraAspectRatioPreset.Widescreen16x9, () => Edit(d => d.Camera.AspectRatioPreset = CameraAspectRatioPreset.Widescreen16x9)),
                ("4:3", camera.AspectRatioPreset == CameraAspectRatioPreset.Classic4x3, () => Edit(d => d.Camera.AspectRatioPreset = CameraAspectRatioPreset.Classic4x3)),
                ("1:1", camera.AspectRatioPreset == CameraAspectRatioPreset.Square1x1, () => Edit(d => d.Camera.AspectRatioPreset = CameraAspectRatioPreset.Square1x1)),
                ("3:4", camera.AspectRatioPreset == CameraAspectRatioPreset.Portrait3x4, () => Edit(d => d.Camera.AspectRatioPreset = CameraAspectRatioPreset.Portrait3x4)),
                ("9:16", camera.AspectRatioPreset == CameraAspectRatioPreset.Vertical9x16, () => Edit(d => d.Camera.AspectRatioPreset = CameraAspectRatioPreset.Vertical9x16)))));
            Add(Slider("Camera Size", () => Doc.Camera.SizeRatio, (d, v) => d.Camera.SizeRatio = v, 0.15, 0.75, 0.56));
            Add(Collapsible("Camera size during zoom", () => Stack(16,
                Toggle("Make smaller during zoom", null, () => Doc.Camera.MakeSmallerDuringZoom, (d, v) => d.Camera.MakeSmallerDuringZoom = v),
                Slider("Size during zoom", () => Doc.Camera.ScaleWhenZoomed, (d, v) => d.Camera.ScaleWhenZoomed = v, 0.25, 0.85, 0.66))));
        }

        Add(Labeled("Add layout at playhead", 10, OptionsWrap(
            ("Overlay", false, () => session.AddCameraLayoutAtPlayhead(CameraTimelineLayoutType.CameraOverlay)),
            ("Split", false, () => session.AddCameraLayoutAtPlayhead(CameraTimelineLayoutType.SplitScreen)),
            ("Cutout", false, () => session.AddCameraLayoutAtPlayhead(CameraTimelineLayoutType.CutoutCamera)),
            ("Fullscreen", false, () => session.AddCameraLayoutAtPlayhead(CameraTimelineLayoutType.FullscreenCamera)),
            ("Only screen", false, () => session.AddCameraLayoutAtPlayhead(CameraTimelineLayoutType.ScreenOnly)))));
        Add(Slider("Camera rounded corners", () => Doc.Camera.BorderRadiusRatio, (d, v) => d.Camera.BorderRadiusRatio = v, 0, 0.5, 0.22));
        Add(Toggle("Hide during silence", null, () => Doc.Camera.HideDuringSilenceMs is not null, (d, v) => d.Camera.HideDuringSilenceMs = v ? 5000 : null));
        if (Doc.Camera.HideDuringSilenceMs is { } silence)
        {
            Add(Slider($"Minimum silence duration ({silence / 1000:0.0}s)", () => Doc.Camera.HideDuringSilenceMs ?? 5000, (d, v) => d.Camera.HideDuringSilenceMs = v, 2000, 15000, 5000));
        }

        if (camera.LayoutMode == CameraLayoutMode.Cutout)
        {
            Add(Slider("Edge softness", () => Doc.Camera.CutoutEdgeSoftness, (d, v) => d.Camera.CutoutEdgeSoftness = v, 0, 1, 0.2));
            Add(Slider("Edge inset", () => Doc.Camera.CutoutEdgeInset, (d, v) => d.Camera.CutoutEdgeInset = v, 0, 1, 0));
            Add(Toggle("Avoid empty area", "Will try to avoid showing too much empty space around the recording", () => Doc.Camera.CutoutAvoidEmptyArea, (d, v) => d.Camera.CutoutAvoidEmptyArea = v));
        }
    }

    private void CameraStyle()
    {
        if (!hasCamera)
        {
            Add(Note("This recording has no camera video."));
            return;
        }

        var looks = Doc.Camera.ColorGradePreset;
        var wrap = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemWidth = 92, ItemHeight = 44 };
        foreach (var preset in Enum.GetValues<CameraColorGradePreset>())
        {
            var look = preset;
            var option = Ui.Option(look.ToString(), looks == look && Doc.Camera.SelectedCustomColorPresetId is null && Doc.Camera.CustomLutRelativePath is null, () => Edit(d =>
            {
                d.Camera.ColorGradePreset = look;
                d.Camera.SelectedCustomColorPresetId = null;
                d.Camera.CustomLutRelativePath = null;
            }));
            option.HorizontalAlignment = HorizontalAlignment.Stretch;
            option.Margin = new Thickness(0, 0, 6, 8);
            option.Padding = new Thickness(0);
            wrap.Children.Add(option);
        }

        foreach (var custom in Doc.Camera.CustomColorPresets)
        {
            var id = custom.Id;
            var option = Ui.Option(custom.Name, Doc.Camera.SelectedCustomColorPresetId == id, () => Edit(d =>
            {
                d.Camera.SelectedCustomColorPresetId = d.Camera.SelectedCustomColorPresetId == id ? null : id;
                d.Camera.CustomLutRelativePath = null;
            }));
            option.HorizontalAlignment = HorizontalAlignment.Stretch;
            option.Margin = new Thickness(0, 0, 6, 8);
            option.Padding = new Thickness(0);
            wrap.Children.Add(option);
        }

        var addLook = Ui.Option("+", false, () => { });
        addLook.Click += (_, _) =>
        {
            var menu = new MenuFlyout();
            var create = new MenuFlyoutItem { Text = Loc.T("Create your color preset...") };
            create.Click += (_, _) => _ = tools.CreateColorPreset();
            var load = new MenuFlyoutItem { Text = Loc.T("Load your LUT file...") };
            load.Click += (_, _) => tools.LoadLutFile();
            menu.Items.Add(create);
            menu.Items.Add(load);
            menu.ShowAt(addLook);
        };
        addLook.HorizontalAlignment = HorizontalAlignment.Stretch;
        addLook.Margin = new Thickness(0, 0, 6, 8);
        addLook.Padding = new Thickness(0);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(addLook, "Add a color look");
        wrap.Children.Add(addLook);
        Add(Labeled("Color grading", 10, wrap));
        if (Doc.Camera.CustomLutRelativePath is { } lut)
        {
            Add(Note(Path.GetFileName(lut)));
            Add(Action("Remove LUT", () => Edit(d => d.Camera.CustomLutRelativePath = null)));
        }

        var hasCrop = !Rect01Full(Doc.Camera.CropRect01);
        Add(Labeled("Crop", 10, Options(
            (hasCrop ? "Edit crop" : "Crop camera", false, () => CameraCropRequested?.Invoke()),
            ("Reset", false, hasCrop ? () => Edit(d => d.Camera.CropRect01 = Rect01.Full) : null))));
        Add(Slider("Color grading intensity", () => Doc.Camera.ColorGradeIntensity, (d, v) => d.Camera.ColorGradeIntensity = v, 0, 1, 1));
        Add(Slider("Sharpen", () => Doc.Camera.Sharpen01, (d, v) => d.Camera.Sharpen01 = v, 0, 1, 0));
        AddDivider();
        Add(Toggle("Mirror horizontally", null, () => Doc.Camera.Mirror, (d, v) => d.Camera.Mirror = v));
        Add(Toggle("Face tracking", null, () => Doc.Camera.EnableFaceTracking, (d, v) => d.Camera.EnableFaceTracking = v));
        Add(Collapsible("Advanced", () => Slider("Camera delay", () => Doc.Camera.DelayAdjustmentMs, (d, v) => d.Camera.DelayAdjustmentMs = v, -200, 200, 0)));
    }

    private string? captionInspectorTrackId;
    private bool captionApplyToTrack;

    private void Captions()
    {
        var captions = Doc.Captions;
        Add(Text("Captions", medium: true));
        Add(Toggle("Disable captions", null, () => !Doc.Captions.Enabled, (d, v) => d.Captions.Enabled = !v));
        if (captions.CaptionTracks.Count == 0)
        {
            Add(Note("Generate transcript"));
            TranscriptControls();
            AddDivider();
            Add(Action("Add caption track", () => captionInspectorTrackId = session.AddCaptionTrack()));
            return;
        }

        var selected = session.SelectedCaption;
        var selectedId = selected?.Id;
        var activeTrackId = selected?.TrackId ?? captions.CaptionTracks.Find(track => track.Id == captionInspectorTrackId)?.Id ?? captions.CaptionTracks[0].Id;
        var style = session.EffectiveCaptionStyle(selectedId, activeTrackId);
        // A selected caption changes alone unless Apply to all is on.
        var targetBlock = captionApplyToTrack ? null : selectedId;
        Action Apply(Action<CaptionStyle> change) => () => session.UpdateCaptionStyle(targetBlock, activeTrackId, change);
        var tracks = new List<(string, bool, Action?)>();
        foreach (var track in captions.CaptionTracks)
        {
            var id = track.Id;
            tracks.Add((track.Name, id == activeTrackId, () =>
            {
                captionInspectorTrackId = id;
                session.SelectCaption(null);
            }));
        }

        tracks.Add(("+", false, () => captionInspectorTrackId = session.AddCaptionTrack()));
        Add(Labeled("Track", 10, OptionsWrap(tracks.ToArray())));
        if (captions.CaptionTracks.Count > 1)
        {
            Add(Action("Delete this track", () =>
            {
                captionInspectorTrackId = null;
                session.DeleteCaptionTrack(activeTrackId);
            }));
        }

        if (selected is not null)
        {
            CaptionSegmentControls(selected);
        }

        Add(Slider(
            "Caption size",
            () => session.EffectiveCaptionStyle(selectedId, activeTrackId).FontSizeRatio,
            (d, v) => EditorSession.ApplyCaptionStyle(d, targetBlock, activeTrackId, item => item.FontSizeRatio = v),
            0.02,
            0.10,
            0.045));
        Add(Labeled("Font style", 10, Options(
            ("Sans-serif", style.FontStyle == CaptionFontStyle.SansSerif, Apply(item => item.FontStyle = CaptionFontStyle.SansSerif)),
            ("Serif", style.FontStyle == CaptionFontStyle.Serif, Apply(item => item.FontStyle = CaptionFontStyle.Serif)),
            ("Mono", style.FontStyle == CaptionFontStyle.Mono, Apply(item => item.FontStyle = CaptionFontStyle.Mono)))));
        Add(Labeled("Word reveal", 10, Options(
            ("Line by line", style.WordsReveal == CaptionWordsReveal.LineByLine, Apply(item => item.WordsReveal = CaptionWordsReveal.LineByLine)),
            ("Word by word", style.WordsReveal == CaptionWordsReveal.WordByWord, Apply(item => item.WordsReveal = CaptionWordsReveal.WordByWord)))));
        if (style.WordsReveal == CaptionWordsReveal.LineByLine)
        {
            Add(Labeled("Line growth", 10, Options(
                ("Full line", style.LineGrowth == CaptionLineGrowth.FullLine, Apply(item => item.LineGrowth = CaptionLineGrowth.FullLine)),
                ("Expanding", style.LineGrowth == CaptionLineGrowth.Expanding, Apply(item => item.LineGrowth = CaptionLineGrowth.Expanding)),
                ("Centered", style.LineGrowth == CaptionLineGrowth.Centered, Apply(item => item.LineGrowth = CaptionLineGrowth.Centered)))));
            Add(Labeled("Word animation", 10, Options(
                ("Appear", style.WordAnimation == CaptionWordAnimation.Appear, Apply(item => item.WordAnimation = CaptionWordAnimation.Appear)),
                ("Fade in", style.WordAnimation == CaptionWordAnimation.FadeIn, Apply(item => item.WordAnimation = CaptionWordAnimation.FadeIn)),
                ("Slide in", style.WordAnimation == CaptionWordAnimation.SlideIn, Apply(item => item.WordAnimation = CaptionWordAnimation.SlideIn)))));
        }

        Add(Labeled("Color", 10, Options(
            ("Dark", style.ColorTheme == CaptionColorTheme.Dark, Apply(item => item.ColorTheme = CaptionColorTheme.Dark)),
            ("Light", style.ColorTheme == CaptionColorTheme.Light, Apply(item => item.ColorTheme = CaptionColorTheme.Light)))));
        var position = style.Position01;
        bool At(Point01 point) => Math.Abs(position.X - point.X) < 0.001 && Math.Abs(position.Y - point.Y) < 0.001;
        Add(Labeled(
            "Caption position",
            10,
            new CaptionPositionPad(session, targetBlock, activeTrackId, position, Rebuild).Element,
            Options(
                ("Bottom", At(CaptionStyle.BottomPosition01), Apply(item => item.Position01 = CaptionStyle.BottomPosition01)),
                ("Center", At(CaptionStyle.CenterPosition01), Apply(item => item.Position01 = CaptionStyle.CenterPosition01)))));
        if (captions.Segments.Count > 0)
        {
            Add(Action("Export transcript", tools.ExportSrt));
        }

        AddDivider();
        Add(Note(captions.Segments.Count == 0 ? "Generate transcript" : "Re-Generate transcript"));
        TranscriptControls();
    }

    /// <summary>The selected caption's text and the Apply to all choice for the options below.</summary>
    private void CaptionSegmentControls(CaptionBlock block)
    {
        var id = block.Id;
        var text = new TextBox { Text = CaptionLineLayout.DisplayText(block, Doc.Captions), AcceptsReturn = false, TextWrapping = TextWrapping.Wrap };
        AutomationName(text, "Caption text");
        void Save()
        {
            if (Doc.Captions.CaptionBlocks.Find(item => item.Id == id) is { } current && text.Text != CaptionLineLayout.DisplayText(current, Doc.Captions))
            {
                session.UpdateCaptionText(id, text.Text);
            }
        }

        text.LostFocus += (_, _) => Save();
        text.KeyDown += (_, args) =>
        {
            if (args.Key == Windows.System.VirtualKey.Enter)
            {
                Save();
                args.Handled = true;
            }
        };
        Add(Labeled("Caption text", 8, text));
        var apply = new CheckBox { Content = Loc.T("Apply to all captions in this track"), IsChecked = captionApplyToTrack };
        apply.Click += (_, _) =>
        {
            captionApplyToTrack = apply.IsChecked == true;
            Rebuild();
        };
        Add(apply);
    }

    /// <summary>Asks the window to move the playhead and redraw.</summary>
    public Action<double>? SeekRequested { get; set; }

    private string? selectedWordId;

    private Button WordChip(CaptionSegment segment, bool present)
    {
        var filler = TranscriptEditing.IsFillerWord(segment.Text) && present;
        var text = new TextBlock
        {
            Text = segment.Text,
            FontSize = 12.5,
            Foreground = !present ? Ui.Rgb(1, 0.23, 0.19, 0.65) : Ui.Pal(segment.IsHidden ? "Ink45" : "Ink95"),
            TextDecorations = (!present || segment.IsHidden ? Windows.UI.Text.TextDecorations.Strikethrough : Windows.UI.Text.TextDecorations.None)
                | (filler ? Windows.UI.Text.TextDecorations.Underline : Windows.UI.Text.TextDecorations.None)
        };
        var chip = new Button
        {
            Style = Ui.StyleOf("NsIconButton"),
            Content = text,
            Width = double.NaN,
            Height = 26,
            Padding = new Thickness(5, 0, 5, 0),
            CornerRadius = new CornerRadius(5)
        };
        AutomationName(chip, segment.Text);
        if (segment.Id == selectedWordId)
        {
            chip.Background = Ui.Rgb(0.38, 0.26, 0.96, 0.48);
        }

        var (id, start, end) = (segment.Id, segment.SourceStartMs, segment.SourceEndMs);
        chip.Click += (_, _) =>
        {
            selectedWordId = selectedWordId == id ? null : id;
            if (session.Mapper.TimelineTime(start + (end - start) * 0.1) is { } timeline)
            {
                SeekRequested?.Invoke(timeline);
            }

            Rebuild();
        };
        return chip;
    }

    private Button PauseChip(double from, double to, bool open)
    {
        var pause = new Button
        {
            Style = Ui.StyleOf("NsIconButton"),
            Content = new TextBlock
            {
                Text = $"··· {(to - from) / 1000:0.0}s",
                FontSize = 11.5,
                Foreground = Ui.Pal(open ? "Ink60" : "Ink28"),
                TextDecorations = open ? Windows.UI.Text.TextDecorations.None : Windows.UI.Text.TextDecorations.Strikethrough
            },
            Width = double.NaN,
            Height = 26,
            Padding = new Thickness(7, 0, 7, 0),
            CornerRadius = new CornerRadius(13),
            Background = Ui.Pal("Ink07")
        };
        Ui.Tip(pause, open ? "Pause — click to tighten to a natural breath" : "Tightened pause — click to restore");
        pause.Click += (_, _) => session.Mutate(document =>
        {
            if (open)
            {
                TranscriptEditing.CutSourceRange(document, from + 100, to - 100);
            }
            else
            {
                TranscriptEditing.RestoreSourceRange(document, from, to, session.SourceDurationMs);
            }
        });
        return pause;
    }

    private StackPanel WordBar(CaptionSegment segment)
    {
        var (id, start, end) = (segment.Id, Math.Max(0, segment.SourceStartMs - 25), Math.Min(session.SourceDurationMs, segment.SourceEndMs + 25));
        var present = TranscriptEditing.IsRangePresent(Doc, segment.SourceStartMs, segment.SourceEndMs);
        var bar = new StackPanel { Spacing = 8, Padding = new Thickness(10), CornerRadius = new CornerRadius(10), Background = Ui.Pal("Ink04") };
        var word = new TextBox { Text = segment.Text, PlaceholderText = Loc.T("Word") };
        AutomationName(word, "Word");
        void SaveWord()
        {
            var trimmed = word.Text.Trim();
            if (trimmed.Length > 0 && trimmed != segment.Text)
            {
                Edit(d =>
                {
                    if (d.Captions.Segments.Find(item => item.Id == id) is { } target)
                    {
                        target.Text = trimmed;
                    }
                });
            }
        }

        word.LostFocus += (_, _) => SaveWord();
        word.KeyDown += (_, args) =>
        {
            if (args.Key == Windows.System.VirtualKey.Enter)
            {
                SaveWord();
                args.Handled = true;
            }
        };
        bar.Children.Add(word);
        var actions = new WordWrapPanel();
        if (present)
        {
            var cut = Ui.Option("Cut video", false, () => Edit(d => TranscriptEditing.CutSourceRange(d, start, end)));
            cut.Background = Ui.Rgb(1, 0.23, 0.19, 0.22);
            actions.Children.Add(cut);
        }

        actions.Children.Add(Ui.Option(segment.IsHidden ? "Unhide" : "Cut transcript", false, () => Edit(d =>
        {
            if (d.Captions.Segments.Find(item => item.Id == id) is { } target)
            {
                target.IsHidden = !target.IsHidden;
            }
        })));
        if (!present || segment.IsHidden)
        {
            actions.Children.Add(Ui.Option("Restore", false, () => Edit(d =>
            {
                if (d.Captions.Segments.Find(item => item.Id == id) is { } target)
                {
                    target.IsHidden = false;
                }

                TranscriptEditing.RestoreSourceRange(d, start, end, session.SourceDurationMs);
            })));
        }

        bar.Children.Add(actions);
        return bar;
    }

    private void TranscriptControls()
    {
        var captions = Doc.Captions;
        var languages = new (string Code, string Name)[] { ("auto", "Detect"), ("en_US", "English"), ("vi_VN", "Vietnamese"), ("es_ES", "Spanish"), ("fr_FR", "French"), ("de_DE", "German"), ("ja_JP", "Japanese"), ("ko_KR", "Korean"), ("zh_CN", "Chinese") };
        var language = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var (code, name) in languages)
        {
            language.Items.Add(new ComboBoxItem { Content = name, Tag = code });
            if (code == captions.TranscriptLocale)
            {
                language.SelectedIndex = language.Items.Count - 1;
            }
        }

        language.SelectionChanged += (_, _) =>
        {
            if (language.SelectedItem is ComboBoxItem { Tag: string code } && code != Doc.Captions.TranscriptLocale)
            {
                session.Mutate(document => document.Captions.TranscriptLocale = code, structural: false);
            }
        };
        Add(Labeled("Language", 8, language));
        Add(Labeled("Model", 10, Options(
            ("Base", captions.WhisperModelTier == "base", () => Edit(d => d.Captions.WhisperModelTier = "base")),
            ("Small", captions.WhisperModelTier == "small", () => Edit(d => d.Captions.WhisperModelTier = "small")),
            ("Medium", captions.WhisperModelTier == "medium", () => Edit(d => d.Captions.WhisperModelTier = "medium")))));
        if (tools.IsTranscribing)
        {
            Add(Note(tools.Status ?? "Transcribing"));
            Add(Action("Stop", tools.CancelTranscript));
        }
        else
        {
            Add(Action(Doc.Captions.Segments.Count == 0 ? "Generate transcript" : "Generate transcript again", tools.GenerateTranscript));
        }
    }

    private void Transcript()
    {
        Add(Text("Edit by transcript", medium: true));
        Add(Note("Edit your video by editing its text: delete words to cut them out, remove filler words and tighten pauses."));
        TranscriptControls();
        if (Doc.Captions.Segments.Count == 0)
        {
            Add(Note("Generate a transcript first to get started."));
            return;
        }

        AddDivider();
        var fillers = TranscriptEditing.PresentFillers(Doc).Count;
        var pauses = TranscriptEditing.TightenablePauses(Doc).Count;
        Add(Action($"Remove {fillers} filler words", fillers == 0 ? null : () => session.Mutate(document => TranscriptEditing.RemoveFillers(document, session.SourceDurationMs))));
        Add(Action($"Tighten {pauses} pauses", pauses == 0 ? null : () => session.Mutate(TranscriptEditing.TightenPauses)));
        var words = new WordWrapPanel();
        var ordered = Doc.Captions.Segments.OrderBy(item => item.SourceStartMs).ToList();
        var showDeleted = Doc.Captions.ShowDeletedTextInTranscript;
        var showHidden = Doc.Captions.ShowHiddenWordsInTranscript;
        for (var index = 0; index < ordered.Count; index++)
        {
            var segment = ordered[index];
            var present = TranscriptEditing.IsRangePresent(Doc, segment.SourceStartMs, segment.SourceEndMs);
            if ((present || showDeleted) && (!segment.IsHidden || showHidden))
            {
                words.Children.Add(WordChip(segment, present));
            }

            // Pauses of 0.8 s or more show between words; a click tightens one to a natural breath.
            if (index + 1 < ordered.Count && ordered[index + 1].SourceStartMs - segment.SourceEndMs >= 800)
            {
                var (from, to) = (segment.SourceEndMs, ordered[index + 1].SourceStartMs);
                var open = TranscriptEditing.IsRangePresent(Doc, from + 100, to - 100);
                if (open || showDeleted)
                {
                    words.Children.Add(PauseChip(from, to, open));
                }
            }
        }

        Add(words);
        if (selectedWordId is { } wordId && Doc.Captions.Segments.Find(item => item.Id == wordId) is { } picked)
        {
            Add(WordBar(picked));
        }

        Add(Note("Click any word to edit or cut — Cut video removes the spoken segment from the timeline, Cut transcript hides it from captions only."));
        AddDivider();
        Add(Toggle("Show deleted text", "Keep cut words visible as strikethrough so they can be restored.", () => Doc.Captions.ShowDeletedTextInTranscript, (d, v) => d.Captions.ShowDeletedTextInTranscript = v));
        Add(Toggle("Show hidden words", "Keep words hidden from captions visible here so they can be restored.", () => Doc.Captions.ShowHiddenWordsInTranscript, (d, v) => d.Captions.ShowHiddenWordsInTranscript = v));
    }

    private string audioGenre = "Lo-Fi";

    private void Audio()
    {
        Add(Text("Microphone", 12.5, "Ink45", true));
        Add(Toggle("Mute microphone", null, () => Doc.Audio.MuteMicrophone, (d, v) => d.Audio.MuteMicrophone = v));
        Add(Slider("Microphone volume", () => Doc.Audio.MicrophoneVolume, (d, v) => d.Audio.MicrophoneVolume = v, 0, 1, 1));
        var preset = Doc.Audio.MicrophoneAudioPreset;
        Add(Labeled("Microphone audio mode", 10, Options(
            ("Off", preset == MicrophoneAudioPreset.Off, () => Edit(d => d.Audio.MicrophoneAudioPreset = MicrophoneAudioPreset.Off)),
            ("Standard", preset == MicrophoneAudioPreset.Standard, () => Edit(d => d.Audio.MicrophoneAudioPreset = MicrophoneAudioPreset.Standard)),
            ("Loud", preset == MicrophoneAudioPreset.Loud, () => Edit(d => d.Audio.MicrophoneAudioPreset = MicrophoneAudioPreset.Loud)),
            ("Noise reduction", preset == MicrophoneAudioPreset.NoiseReduction, () => Edit(d => d.Audio.MicrophoneAudioPreset = MicrophoneAudioPreset.NoiseReduction)),
            ("Podcast", preset == MicrophoneAudioPreset.Podcast, () => Edit(d => d.Audio.MicrophoneAudioPreset = MicrophoneAudioPreset.Podcast)))));
        AddDivider();
        Add(Text("System audio", 12.5, "Ink45", true));
        Add(Toggle("Mute system audio", null, () => Doc.Audio.MuteSystemAudio, (d, v) => d.Audio.MuteSystemAudio = v));
        Add(Slider("System audio volume", () => Doc.Audio.SystemAudioVolume, (d, v) => d.Audio.SystemAudioVolume = v, 0, 1, 1));
        AddDivider();
        Add(Text("Background audio", 12.5, "Ink45", true));
        Add(Options(BuiltInBackgroundMusic.Genres.Select<string, (string, bool, Action?)>(genre => (genre, audioGenre == genre, () =>
        {
            audioGenre = genre;
            Rebuild();
        })).ToArray()));
        var musicPath = Doc.Audio.BackgroundMusic.RelativePath;
        Add(Options(BuiltInBackgroundMusic.Tracks(audioGenre).Select<string, (string, bool, Action?)>(track => (tools.LoadingTrack == track ? track + "..." : track, musicPath == track, () => tools.SelectBuiltInTrack(track))).ToArray()));
        if (musicPath is not null && tools.LoadingTrack is null)
        {
            var title = Path.GetFileNameWithoutExtension(musicPath).Replace("bg-", "");
            Add(Action($"{(tools.IsPreviewingMusic ? "Stop" : "Play")} {title}", tools.ToggleMusicPreview));
        }

        if (Doc.Audio.BackgroundMusic.RelativePath is null)
        {
            Add(Action("Add background audio", tools.AddBackgroundAudio));
        }
        else
        {
            Add(Toggle("Mute background audio", null, () => Doc.Audio.BackgroundMusic.Muted, (d, v) => d.Audio.BackgroundMusic.Muted = v));
            Add(Slider("Background audio volume", () => Doc.Audio.BackgroundMusic.Volume, (d, v) => d.Audio.BackgroundMusic.Volume = v, 0, 1, 0.08));
            Add(Action("Remove background audio", () => Edit(d => d.Audio.BackgroundMusic.RelativePath = null)));
        }

        AddDivider();
        Add(Text("Voiceovers", 12.5, "Ink45", true));
        Add(VoiceoverActions());
        foreach (var voiceover in Doc.Timeline.Voiceovers)
        {
            var id = voiceover.Id;
            VoiceoverSegment Find(ProjectDocument d) => d.Timeline.Voiceovers.First(item => item.Id == id);
            Add(Collapsible($"Voiceover at {Ui.Timecode(voiceover.SourceStartMs)}", () => Stack(14,
                Slider("Volume", () => Doc.Timeline.Voiceovers.Find(item => item.Id == id)?.Volume ?? 1, (d, v) => Find(d).Volume = v, 0, 1, 1),
                Action(Doc.Timeline.Voiceovers.Count > 1 ? "Apply to other voiceovers" : "", Doc.Timeline.Voiceovers.Count > 1 ? () => session.ApplyVoiceoverVolumeToOthers(id) : null),
                Labeled("Attach to recording", 10, Options(
                    ("Independent", Doc.Timeline.Voiceovers.Find(item => item.Id == id)?.AttachMode == VoiceoverAttachMode.Independent, () => Edit(d => Find(d).AttachMode = VoiceoverAttachMode.Independent)),
                    ("Synchronized", Doc.Timeline.Voiceovers.Find(item => item.Id == id)?.AttachMode == VoiceoverAttachMode.Synchronized, () => Edit(d => Find(d).AttachMode = VoiceoverAttachMode.Synchronized)))),
                Toggle("Hide & mute original recording", null, () => Doc.Timeline.Voiceovers.Find(item => item.Id == id)?.HideRecording ?? false, (d, v) => Find(d).HideRecording = v),
                Toggle("Disable voiceover", null, () => Doc.Timeline.Voiceovers.Find(item => item.Id == id)?.Disabled ?? false, (d, v) => Find(d).Disabled = v),
                Action("Remove voiceover", () => Edit(d => d.Timeline.Voiceovers.RemoveAll(item => item.Id == id))))));
        }
    }

    private void Shortcuts()
    {
        Add(Action("Add shortcut", () => session.AddCustomShortcut(null, session.SourceAtPlayhead)));
        Add(Action("Add shortcut track", () => Edit(d => TimelineEdits.AddShortcutTrack(d))));
        Add(Toggle("Show shortcuts", null, () => Doc.Captions.ShowKeystrokes, (d, v) => d.Captions.ShowKeystrokes = v));
        Add(Slider("Shortcut labels size", () => Doc.Captions.ShortcutsSizeRatio, (d, v) => d.Captions.ShortcutsSizeRatio = v, 0.075, 0.25, 0.11));
        Add(Toggle("Show single key shortcuts", null, () => Doc.Captions.ShowSingleKeyShortcuts, (d, v) => d.Captions.ShowSingleKeyShortcuts = v));
        AddDivider();
        var tracks = Doc.Captions.ShortcutTracks;
        var active = tracks.Find(track => track.Id == selectedShortcutTrackId)?.Id ?? tracks.FirstOrDefault()?.Id;
        if (tracks.Count > 1)
        {
            var row = new List<(string, bool, Action?)>();
            foreach (var track in tracks)
            {
                var id = track.Id;
                row.Add((track.Name, id == active, () =>
                {
                    selectedShortcutTrackId = id;
                    Rebuild();
                }));
            }

            Add(Labeled("Shortcut track", 10, OptionsWrap(row.ToArray())));
        }

        // The compositor draws a track's own style, so that is the one to edit.
        ShortcutStyleSection(d => TimelineEdits.ShortcutTrackStyle(d, active));
    }

    /// <summary>Position, offsets and keycap colors of a style, edited through <paramref name="target"/> on the document.</summary>
    private void ShortcutStyleSection(Func<ProjectDocument, ShortcutStyleConfig> target)
    {
        var style = target(Doc);
        ShortcutStyleConfig Writing(ProjectDocument d) => TimelineEdits.LinkDefaultShortcutStyle(d, target(d));
        Add(Labeled("Position", 10, Options(
            ("Bottom", style.DockPosition == ShortcutDockPosition.Bottom, () => Edit(d => Writing(d).DockPosition = ShortcutDockPosition.Bottom)),
            ("Top", style.DockPosition == ShortcutDockPosition.Top, () => Edit(d => Writing(d).DockPosition = ShortcutDockPosition.Top)),
            ("Left", style.DockPosition == ShortcutDockPosition.Left, () => Edit(d => Writing(d).DockPosition = ShortcutDockPosition.Left)),
            ("Right", style.DockPosition == ShortcutDockPosition.Right, () => Edit(d => Writing(d).DockPosition = ShortcutDockPosition.Right)))));
        if (style.DockPosition is ShortcutDockPosition.Left or ShortcutDockPosition.Right)
        {
            Add(Note($"Keycaps are stacked vertically along the {style.DockPosition.ToString().ToLowerInvariant()} edge."));
        }

        Add(Slider("Horizontal offset", () => target(Doc).OffsetX, (d, v) => Writing(d).OffsetX = v, -0.45, 0.45, 0));
        Add(Slider("Vertical offset", () => target(Doc).OffsetY, (d, v) => Writing(d).OffsetY = v, -0.45, 0.45, 0));
        AddDivider();
        Add(Labeled("Keycap color", 10, Options(
            ("Default", style.ColorMode == ShortcutColorMode.DefaultDark, () => Edit(d => Writing(d).ColorMode = ShortcutColorMode.DefaultDark)),
            ("Solid", style.ColorMode == ShortcutColorMode.Solid, () => Edit(d => Writing(d).ColorMode = ShortcutColorMode.Solid)),
            ("Gradient", style.ColorMode == ShortcutColorMode.Gradient, () => Edit(d => Writing(d).ColorMode = ShortcutColorMode.Gradient)))));
        UIElement Field(string name, string hex, Action<ShortcutStyleConfig, string> set) => ColorField.Create(
            name,
            hex,
            value => session.Mutate(d => set(Writing(d), value), "shortcut-color", structural: false),
            value => Edit(d => set(Writing(d), value)));
        if (style.ColorMode == ShortcutColorMode.Solid)
        {
            Add(Labeled("Key background", 8, Field("Key background", style.SolidColorHex, (item, value) => item.SolidColorHex = value)));
            Add(Action("Pick random color", () =>
            {
                var picked = CuratedSolidColors[Random.Shared.Next(CuratedSolidColors.Length)];
                Edit(d => Writing(d).SolidColorHex = picked);
            }));
        }
        else if (style.ColorMode == ShortcutColorMode.Gradient)
        {
            Add(Labeled("Key gradient", 8, Field("Key gradient start", style.GradientStartHex, (item, value) => item.GradientStartHex = value), Field("Key gradient end", style.GradientEndHex, (item, value) => item.GradientEndHex = value)));
        }

        if (style.ColorMode != ShortcutColorMode.DefaultDark)
        {
            Add(Labeled("Text color", 8, Field("Text color", style.TextColorHex, (item, value) => item.TextColorHex = value)));
        }
    }

    private void Animations()
    {
        var camera = Doc.Motion.CameraSpring;
        var cursor = Doc.Cursor.Spring;
        Add(Labeled("Screen animation style", 10, Options(
            ("Focused", Is(camera, 250, 40, 2.25), () => Edit(d => d.Motion.CameraSpring = new SpringConfig(250, 40, 2.25))),
            ("Smooth", Is(camera, 170, 50, 3), () => Edit(d => d.Motion.CameraSpring = new SpringConfig(170, 50, 3))))));
        Add(Labeled("Cursor animation style", 10, OptionsWrap(
            ("Smooth", Is(cursor, 470, 70, 3), () => Edit(d => d.Cursor.Spring = new SpringConfig(470, 70, 3))),
            ("Medium", Is(cursor, 340, 60, 3), () => Edit(d => d.Cursor.Spring = new SpringConfig(340, 60, 3))),
            ("Rapid", Is(cursor, 530, 40, 1), () => Edit(d => d.Cursor.Spring = new SpringConfig(530, 40, 1))),
            ("None", Is(cursor, 2500, 200, 0.2), () => Edit(d => d.Cursor.Spring = new SpringConfig(2500, 200, 0.2))))));
        AddDivider();
        Add(Slider("Motion blur", () => Doc.Motion.MotionBlurIntensity, (d, v) => d.Motion.MotionBlurIntensity = v, 0, 1, 1));
        Add(Note("Elements that are moving will have a cinematic motion blur effect applied"));
    }

    private void DeviceFrame()
    {
        var mockup = Doc.FrameStyle.DeviceMockup;
        Add(Toggle("Use device mockup", null, () => Doc.FrameStyle.DeviceMockup.Enabled, (d, v) => d.FrameStyle.DeviceMockup.Enabled = v));
        if (!mockup.Enabled)
        {
            return;
        }

        var finishes = mockup.DeviceId switch
        {
            "macbook-air-15" => new[] { ("midnight", "Midnight"), ("starlight", "Starlight"), ("silver", "Silver") },
            "iphone-16-pro" => new[] { ("black-titanium", "Black Titanium"), ("white-titanium", "White Titanium"), ("natural-titanium", "Natural Titanium"), ("desert-titanium", "Desert Titanium") },
            _ => new[] { ("space-black", "Space Black"), ("silver", "Silver") }
        };
        Add(Labeled("Finish", 10, Options(finishes.Select<(string, string), (string, bool, Action?)>(finish => (finish.Item2, mockup.ColorVariantId == finish.Item1, (Action?)(() => Edit(d => d.FrameStyle.DeviceMockup.ColorVariantId = finish.Item1)))).ToArray())));
        Add(Labeled("Device frames", 10, OptionsWrap(
            ("MacBook Pro 16\"", mockup.DeviceId == "macbook-pro-16", () => Edit(d => d.FrameStyle.DeviceMockup.DeviceId = "macbook-pro-16")),
            ("MacBook Air 15\"", mockup.DeviceId == "macbook-air-15", () => Edit(d => d.FrameStyle.DeviceMockup.DeviceId = "macbook-air-15")),
            ("iPhone 16 Pro", mockup.DeviceId == "iphone-16-pro", () => Edit(d => d.FrameStyle.DeviceMockup.DeviceId = "iphone-16-pro")),
            ("iPad Pro 13\"", mockup.DeviceId == "ipad-pro-13", () => Edit(d => d.FrameStyle.DeviceMockup.DeviceId = "ipad-pro-13")))));
        Add(Labeled("Sizing", 10, Options(
            ("Perfect", mockup.MatchMode == DeviceFrameMatchMode.Perfect, () => Edit(d => d.FrameStyle.DeviceMockup.MatchMode = DeviceFrameMatchMode.Perfect)),
            ("Flexible", mockup.MatchMode == DeviceFrameMatchMode.Flexible, () => Edit(d => d.FrameStyle.DeviceMockup.MatchMode = DeviceFrameMatchMode.Flexible)))));
    }

    private void Masks()
    {
        Add(Note("Masks stay locked to the source clip coordinates (even while zooming). Select a mask on the timeline to edit it."));
        Add(Stack(8,
            Action("Add sensitive data mask", () => session.AddMaskAtPlayhead(MaskType.Blur)),
            Action("Add highlight mask", () => session.AddMaskAtPlayhead(MaskType.Spotlight))));
    }

    // MARK: Block editors

    private void ClipEditor(ClipSlice slice)
    {
        var id = slice.Id;
        ClipSlice Find(ProjectDocument d) => d.Timeline.Slices.First(item => item.Id == id);
        Add(CloseEditor("Close clip editor", () => session.SelectSlice(null)));
        Add(Slider("Speed", () => session.SelectedSlice?.Speed ?? 1, (d, v) => Find(d).Speed = Math.Round(v * 20) / 20, 0.25, 8, 1));
        Add(Slider("Clip audio volume", () => session.SelectedSlice?.SystemAudioVolume ?? 1, (d, v) => SegmentEdits.SetSliceSystemAudioVolume(Find(d), v), 0, 1, 1));
        Add(Toggle("Mute clip", null, () => session.SelectedSlice?.Muted ?? false, (d, v) => Find(d).Muted = v));
        Add(Toggle("Hide cursor in this clip", null, () => session.SelectedSlice?.HideCursor ?? false, (d, v) => Find(d).HideCursor = v));
        Add(Toggle("Disable smooth cursor", null, () => session.SelectedSlice?.DisableSmoothCursor ?? false, (d, v) => Find(d).DisableSmoothCursor = v));
        Add(Action("Delete clip", Doc.Timeline.Slices.Count > 1 ? session.DeleteSelected : null));
    }

    private void LayoutEditor(CameraLayoutSegment layout)
    {
        var id = layout.Id;
        CameraLayoutSegment Find(ProjectDocument d) => d.Timeline.CameraLayouts.First(item => item.Id == id);
        Add(CloseEditor("Close layout editor", () => session.SelectLayout(null)));
        Add(Labeled("Layout", 10, OptionsWrap(
            ("Camera overlay", layout.LayoutType == CameraTimelineLayoutType.CameraOverlay, () => Edit(d => Find(d).LayoutType = CameraTimelineLayoutType.CameraOverlay)),
            ("Split screen", layout.LayoutType == CameraTimelineLayoutType.SplitScreen, () => Edit(d => Find(d).LayoutType = CameraTimelineLayoutType.SplitScreen)),
            ("Camera cutout", layout.LayoutType == CameraTimelineLayoutType.CutoutCamera, () => Edit(d => Find(d).LayoutType = CameraTimelineLayoutType.CutoutCamera)),
            ("Fullscreen camera", layout.LayoutType == CameraTimelineLayoutType.FullscreenCamera, () => Edit(d => Find(d).LayoutType = CameraTimelineLayoutType.FullscreenCamera)),
            ("Only screen", layout.LayoutType == CameraTimelineLayoutType.ScreenOnly, () => Edit(d => Find(d).LayoutType = CameraTimelineLayoutType.ScreenOnly)))));
        if (layout.LayoutType == CameraTimelineLayoutType.CameraOverlay)
        {
            Add(Labeled("Camera Position", 10, PositionGrid(layout.OverlayPosition01 ?? Doc.Camera.Position01, target => Edit(d => Find(d).OverlayPosition01 = target))));
        }
        else if (layout.LayoutType == CameraTimelineLayoutType.CutoutCamera)
        {
            Add(Slider("Camera Position", () => session.SelectedLayout?.CutoutPositionX01 ?? Doc.Camera.CutoutPositionX01, (d, v) => Find(d).CutoutPositionX01 = v, 0, 1, 0.5));
        }
        else if (layout.LayoutType == CameraTimelineLayoutType.SplitScreen)
        {
            var ratio = Doc.Camera.SplitScreenRatio01;
            Add(Labeled("Split ratio", 10, Options(
                ("1/2", Math.Abs(ratio - 0.5) < 0.01, () => Edit(d => d.Camera.SplitScreenRatio01 = 0.5)),
                ("1/3", Math.Abs(ratio - 1.0 / 3) < 0.01, () => Edit(d => d.Camera.SplitScreenRatio01 = 1.0 / 3)),
                ("2/3", Math.Abs(ratio - 2.0 / 3) < 0.01, () => Edit(d => d.Camera.SplitScreenRatio01 = 2.0 / 3)))));
            Add(Toggle("Flip", "If enabled, the layout will be flipped.", () => Doc.Camera.SplitFlip, (d, v) => d.Camera.SplitFlip = v));
        }

        Add(Toggle("Disable layout", null, () => session.SelectedLayout?.Disabled ?? false, (d, v) => Find(d).Disabled = v));
        Add(Action("Remove layout", session.DeleteSelected));
    }

    private void ShortcutEditor(ShortcutCluster cluster)
    {
        Add(CloseEditor("Close Shortcut editor", () => session.SelectShortcut(null)));
        var key = new TextBox { Text = cluster.PrimaryKey, PlaceholderText = Loc.T("Key") };
        AutomationName(key, "Shortcut key");
        void Save(List<string> modifiers, string primary)
        {
            if (primary.Trim().Length > 0)
            {
                session.Mutate(document => TimelineEdits.SetShortcutKeys(document, cluster, modifiers, primary.Trim()));
            }
        }

        key.LostFocus += (_, _) =>
        {
            if (key.Text != cluster.PrimaryKey)
            {
                Save(cluster.Modifiers.ToList(), key.Text);
            }
        };
        Add(Labeled("Key", 8, key));
        var row = new List<(string, bool, Action?)>();
        foreach (var modifier in new[] { "Ctrl", "Shift", "Alt", "Meta" })
        {
            var name = modifier;
            var on = cluster.Modifiers.Contains(name);
            row.Add((name == "Meta" ? "Win" : name, on, () =>
            {
                var next = cluster.Modifiers.ToList();
                if (on)
                {
                    next.Remove(name);
                }
                else
                {
                    next.Add(name);
                }

                Save(next, cluster.PrimaryKey);
            }));
        }

        Add(Labeled("Modifiers", 10, OptionsWrap(row.ToArray())));
        var hidden = SegmentEdits.IsShortcutHidden(Doc, cluster);
        Add(ToolToggle("Show this shortcut", "When disabled, this shortcut segment is dimmed on the timeline and hidden in the video.", !hidden, _ => session.ToggleShortcutHidden(cluster)));
        AddDivider();
        var custom = Doc.Captions.ShortcutStyleOverrides.ContainsKey(cluster.Id);
        Add(ToolToggle("Custom style for this shortcut", "Override the track's default position, offset, and keycap color for this segment.", custom, enabled => Edit(d =>
        {
            if (enabled)
            {
                d.Captions.ShortcutStyleOverrides[cluster.Id] = ProjectJson.Clone(TimelineEdits.EffectiveShortcutStyle(d, cluster));
            }
            else
            {
                d.Captions.ShortcutStyleOverrides.Remove(cluster.Id);
            }
        })));
        ShortcutStyleSection(d => TimelineEdits.EffectiveShortcutStyle(d, cluster));
        Add(Action("Remove shortcut", session.DeleteSelected));
    }

    private void ZoomEditor(ZoomBlock zoom)    {
        var id = zoom.Id;
        ZoomBlock Find(ProjectDocument document) => document.Timeline.Zooms.First(item => item.Id == id);
        Add(CloseEditor("Close Zoom editor", () => session.SelectZoom(null)));
        Add(Labeled("Zoom style", 10, Options(
            ("Classic", zoom.Presentation == ZoomPresentation.Screen, () => Edit(d => Find(d).Presentation = ZoomPresentation.Screen)),
            ("Glass Loupe", zoom.Presentation == ZoomPresentation.Loupe, () => Edit(d => Find(d).Presentation = ZoomPresentation.Loupe)))));
        Add(Toggle("Instant animation", null, () => zoom.InstantAnimation, (d, v) => Find(d).InstantAnimation = v));
        Add(Labeled("Zoom position", 10, Options(
            ("Auto", zoom.Mode == ZoomMode.FollowCursor, () => Edit(d => Find(d).Mode = ZoomMode.FollowCursor)),
            ("Manual", zoom.Mode == ZoomMode.Manual, () => Edit(d => Find(d).Mode = ZoomMode.Manual)))));
        if (zoom.Mode == ZoomMode.Manual || session.CursorEvents.Count == 0)
        {
            Add(new ZoomPositionPad(session, tools, zoom.Id).Element);
        }
        Add(Slider("Zoom level", () => session.SelectedZoom?.Scale ?? 1.8, (d, v) => Find(d).Scale = v, 1, 3.5, 1.8));
        Add(Note("How close to zoom on the cursor during this zoom phase"));
        if (zoom.Presentation == ZoomPresentation.Loupe)
        {
            Add(Collapsible("Advanced", () => Stack(16,
                Slider("Loupe size", () => session.SelectedZoom?.Loupe.Radius01 ?? 0.35, (d, v) => Find(d).Loupe.Radius01 = v, 0.1, 0.6, 0.35),
                Slider("Glass bevel refraction", () => session.SelectedZoom?.Loupe.BevelRatio ?? 0.25, (d, v) => Find(d).Loupe.BevelRatio = v, 0, 1, 0.25),
                Slider("Chromatic aberration", () => session.SelectedZoom?.Loupe.ChromaticAberration ?? 0.65, (d, v) => Find(d).Loupe.ChromaticAberration = v, 0, 1, 0.65))));
        }

        Add(Action("Apply zoom level to all other zooms", () =>
        {
            var scale = zoom.Scale;
            Edit(d => d.Timeline.Zooms.ForEach(item => item.Scale = scale));
        }));
        AddDivider();
        Add(Toggle("Disable zoom", null, () => zoom.Disabled, (d, v) => Find(d).Disabled = v));
        Add(Action("Remove zoom", session.DeleteSelected));
    }

    private void MaskEditor(MaskItem mask)
    {
        var id = mask.Id;
        MaskItem Find(ProjectDocument document) => document.Timeline.MaskTracks.SelectMany(track => track.Items).First(item => item.Id == id);
        MaskItem? Live() => session.SelectedMask;
        Add(CloseEditor("Close Mask editor", () => session.SelectMask(null)));
        Add(Labeled("Mask Mode", 10, Options(
            ("Sensitive data", mask.Type == MaskType.Blur, () => Edit(d =>
            {
                Find(d).Type = MaskType.Blur;
                Find(d).Style = MaskStyle.Gaussian;
            })),
            ("Highlight", mask.Type == MaskType.Spotlight, () => Edit(d =>
            {
                Find(d).Type = MaskType.Spotlight;
                Find(d).Style = MaskStyle.Dim;
            })))));
        if (mask.Type == MaskType.Blur)
        {
            Add(Labeled("Blur Filter Style", 10, Options(
                ("Gaussian", mask.Style == MaskStyle.Gaussian, () => Edit(d => Find(d).Style = MaskStyle.Gaussian)),
                ("Pixelate", mask.Style == MaskStyle.Pixelate, () => Edit(d => Find(d).Style = MaskStyle.Pixelate)),
                ("Solid", mask.Style == MaskStyle.Solid, () => Edit(d => Find(d).Style = MaskStyle.Solid)))));
            Add(Slider("Blur intensity", () => Live()?.Intensity ?? 36, (d, v) => Find(d).Intensity = v, 4, 160, 36));
        }
        else
        {
            Add(Slider("Highlight intensity", () => Live()?.Intensity ?? 50, (d, v) => Find(d).Intensity = v, 0, 95, 50));
        }

        Add(Slider("Corner radius", () => Live()?.CornerRadius ?? 12, (d, v) => Find(d).CornerRadius = v, 0, 120, 12));
        AddDivider();
        Add(Toggle("Disable mask", null, () => mask.Disabled, (d, v) => Find(d).Disabled = v));
        Add(Action("Remove mask", session.DeleteSelected));
    }

    // MARK: Controls

    private void Edit(Action<ProjectDocument> change) => session.Mutate(change);

    private void Add(UIElement element) => body.Children.Add(element);

    private void AddDivider() => Add(new Border { Height = 1, Background = Ui.Pal("Ink07") });

    private static bool Is(SpringConfig spring, double stiffness, double damping, double mass) =>
        spring.Stiffness == stiffness && spring.Damping == damping && spring.Mass == mass;

    private static TextBlock Text(string text, double size = 13, string ink = "Ink95", bool medium = false) => Ui.Text(text, size, ink, medium);

    private static TextBlock Note(string text) => Ui.Text(text, 12, "Ink45");

    private static StackPanel Stack(double spacing, params UIElement[] children)
    {
        var stack = new StackPanel { Spacing = spacing };
        foreach (var child in children)
        {
            stack.Children.Add(child);
        }

        return stack;
    }

    private static StackPanel Labeled(string title, double spacing, params UIElement[] content)
    {
        var stack = Stack(spacing, Text(title));
        foreach (var child in content)
        {
            stack.Children.Add(child);
        }

        return stack;
    }

    private ScrollViewer Options(params (string Title, bool Selected, Action? Click)[] options)
    {
        var row = StripRow(6);
        FrameworkElement? selected = null;
        string? selectedTitle = null;
        foreach (var (title, isSelected, click) in options)
        {
            var option = Ui.Option(title, isSelected, click);
            row.Children.Add(option);
            if (isSelected)
            {
                selected = option;
                selectedTitle = title;
            }
        }

        return Strip(string.Join('|', options.Select(option => option.Title)), row, selectedTitle, selected);
    }

    private static StackPanel StripRow(double spacing) =>
        new() { Orientation = Orientation.Horizontal, Spacing = spacing, Padding = new Thickness(0, 2, StripBleed, 2) };

    /// <summary>
    /// A row that scrolls sideways and runs to the panel's edge. The panel is rebuilt on every edit, so where the row was and what
    /// it had selected live here by key: that is what lets a newly selected item glide to the center, instead of the row
    /// jumping back to its start. A row opening for the first time centers without animating, and any other rebuild leaves it alone.
    /// </summary>
    private ScrollViewer Strip(string key, StackPanel row, string? selectedId, FrameworkElement? selected)
    {
        var strip = new ScrollViewer
        {
            Content = row,
            Margin = new Thickness(0, 0, -StripBleed, 0),
            HorizontalScrollMode = ScrollMode.Enabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            VerticalScrollMode = ScrollMode.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled
        };
        var isNew = !strips.TryGetValue(key, out var state);
        state ??= new StripState();
        strips[key] = state;
        state.Owner = strip;
        foreach (var button in row.Children.OfType<Microsoft.UI.Xaml.Controls.Primitives.ButtonBase>())
        {
            button.Click += (_, _) => CenterInStrip(strip, row, button, state, animated: true);
        }

        var restored = false;
        strip.ViewChanged += (_, args) =>
        {
            if (!restored || state.Owner != strip)
            {
                return;
            }

            state.Offset = strip.HorizontalOffset;
            if (!args.IsIntermediate)
            {
                state.Target = null;
            }
        };
        strip.Loaded += (_, _) =>
        {
            strip.UpdateLayout();
            strip.ChangeView(state.Offset, null, null, disableAnimation: true);
            restored = true;
            var changed = !isNew && state.SelectedId != selectedId;
            state.SelectedId = selectedId;
            var target = state.Target;
            strip.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
            {
                if (selected is not null && (isNew || changed))
                {
                    CenterInStrip(strip, row, selected, state, animated: changed);
                }
                else if (target is { } unfinished)
                {
                    strip.ChangeView(unfinished, null, null, disableAnimation: false);
                }
            });
        };
        return strip;
    }

    private static void CenterInStrip(ScrollViewer strip, StackPanel row, FrameworkElement item, StripState state, bool animated)
    {
        if (!item.IsLoaded || !strip.IsLoaded)
        {
            return;
        }

        var left = item.TransformToVisual(row).TransformPoint(default).X;
        var target = Math.Clamp(left + item.ActualWidth / 2 - strip.ViewportWidth / 2, 0, strip.ScrollableWidth);
        state.Target = animated ? target : null;
        strip.ChangeView(target, null, null, disableAnimation: !animated);
    }

    private sealed class StripState
    {
        public double Offset { get; set; }
        public double? Target { get; set; }
        public string? SelectedId { get; set; }
        public ScrollViewer? Owner { get; set; }
    }

    private static VariableSizedWrapGrid OptionsWrap(params (string Title, bool Selected, Action? Click)[] options)
    {
        var wrap = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemWidth = 142, ItemHeight = 44 };
        foreach (var (title, selected, click) in options)
        {
            var option = Ui.Option(title, selected, click);
            option.HorizontalAlignment = HorizontalAlignment.Stretch;
            option.Margin = new Thickness(0, 0, 6, 8);
            option.Padding = new Thickness(0);
            wrap.Children.Add(option);
        }

        return wrap;
    }

    private static VariableSizedWrapGrid SwatchGrid() =>
        new() { Orientation = Orientation.Horizontal, ItemWidth = 44, ItemHeight = 44 };

    // The inspector rebuilds on every edit, and the image is decoded once for all of those rebuilds.
    private static Microsoft.UI.Xaml.Media.ImageBrush WallpaperThumbnail(WallpaperItem item)
    {
        if (!WallpaperThumbnails.TryGetValue(item.ThumbnailPath, out var image))
        {
            image = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(item.ThumbnailPath)) { DecodePixelWidth = 76 };
            WallpaperThumbnails[item.ThumbnailPath] = image;
        }

        return new Microsoft.UI.Xaml.Media.ImageBrush { ImageSource = image, Stretch = Stretch.UniformToFill };
    }

    private static Button Swatch(Brush fill, string tooltip, bool selected, Action click)
    {
        tooltip = Loc.T(tooltip);
        var button = new Button
        {
            Style = Ui.StyleOf("NsIconButton"),
            Width = 38,
            Height = 38,
            CornerRadius = new CornerRadius(7),
            Background = fill,
            BorderBrush = selected ? Ui.Rgb(0.65, 0.58, 0.99) : Ui.Pal("Ink10"),
            BorderThickness = new Thickness(selected ? 2 : 1)
        };
        Ui.Tip(button, tooltip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, tooltip);
        button.Click += (_, _) => click();
        return button;
    }

    private static Button Action(string title, Action? click)
    {
        var button = Ui.Option(title, false, click);
        button.HorizontalAlignment = HorizontalAlignment.Stretch;
        return button;
    }

    /// <summary>Record and upload side by side. Record is red, and solid while a take is running.</summary>
    private Grid VoiceoverActions()
    {
        var recording = session.IsRecordingVoiceover;
        var record = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center };
        var foreground = recording ? Ui.Pal("Ink95") : Ui.Rgb(1, 0.45, 0.45);
        record.Children.Add(Ui.Icon(recording ? "\uE71A" : "\uE7C8", 13, foreground));
        record.Children.Add(new TextBlock { Text = recording ? "Stop Recording" : "Record voiceover", FontSize = 12.5, FontWeight = Microsoft.UI.Text.FontWeights.Medium, Foreground = foreground });
        var recordButton = Ui.Option("", false, tools.ToggleVoiceoverRecording);
        recordButton.Content = record;
        recordButton.HorizontalAlignment = HorizontalAlignment.Stretch;
        recordButton.Background = Ui.Rgb(1, 0, 0, recording ? 1 : 0.14);
        recordButton.BorderBrush = Ui.Rgb(1, 0, 0, 0.35);
        var upload = Action("Upload audio…", tools.UploadVoiceover);
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetColumn(upload, 1);
        grid.Children.Add(recordButton);
        grid.Children.Add(upload);
        return grid;
    }

    private static Button CloseEditor(string title, Action click)
    {
        title = Loc.T(title);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(Ui.Icon("", 11));
        row.Children.Add(new TextBlock { Text = title, FontSize = 13 });
        var button = Ui.Option("", false, click);
        button.Content = row;
        button.HorizontalAlignment = HorizontalAlignment.Stretch;
        return button;
    }

    private UIElement Slider(string title, Func<double> get, Action<ProjectDocument, double> set, double min, double max, double fallback)
    {
        title = Loc.T(title);
        var slider = new Slider
        {
            Minimum = min,
            Maximum = max,
            StepFrequency = (max - min) / 400,
            SmallChange = (max - min) / 100,
            LargeChange = (max - min) / 10,
            Value = get(),
            IsThumbToolTipEnabled = false,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, -4, 0, -4)
        };
        var reset = new Button
        {
            Style = Ui.StyleOf("NsOptionButton"),
            Content = Loc.T("Reset"),
            Width = 66,
            Height = 32,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(8),
            FontSize = 12,
            IsEnabled = Math.Abs(get() - fallback) > (max - min) * 0.002
        };
        reset.Click += (_, _) => slider.Value = fallback;
        slider.ValueChanged += (_, args) =>
        {
            var value = args.NewValue;
            session.Mutate(document => set(document, value), "slider:" + title, structural: false);
            reset.IsEnabled = Math.Abs(value - fallback) > (max - min) * 0.002;
        };

        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(slider);
        Grid.SetColumn(reset, 1);
        row.Children.Add(reset);
        return Stack(9, Text(title, medium: true), row);
    }

    private UIElement Toggle(string title, string? description, Func<bool> get, Action<ProjectDocument, bool> set)
    {
        title = Loc.T(title);
        description = Loc.T(description);
        var toggle = new ToggleSwitch
        {
            IsOn = get(),
            OnContent = "",
            OffContent = "",
            MinWidth = 0,
            Margin = new Thickness(0, 0, -6, 0),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center
        };
        AutomationName(toggle, title);
        toggle.Toggled += (_, _) =>
        {
            var value = toggle.IsOn;
            if (value != get())
            {
                session.Mutate(document => set(document, value));
            }
        };

        var text = Stack(4, Text(title));
        if (description is not null)
        {
            text.Children.Add(Note(description));
        }

        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(text);
        Grid.SetColumn(toggle, 1);
        row.Children.Add(toggle);
        return row;
    }

    private UIElement ToolToggle(string title, string description, bool isOn, Action<bool> set)
    {
        title = Loc.T(title);
        description = Loc.T(description);
        var toggle = new ToggleSwitch { OnContent = "", OffContent = "", MinWidth = 0, IsOn = isOn, Margin = new Thickness(0, 0, -6, 0), HorizontalAlignment = HorizontalAlignment.Right };
        AutomationName(toggle, title);
        toggle.Toggled += (_, _) => set(toggle.IsOn);
        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(Stack(4, Text(title), Note(description)));
        Grid.SetColumn(toggle, 1);
        row.Children.Add(toggle);
        return row;
    }

    private static UIElement Disabled(string title, string description)
    {
        title = Loc.T(title);
        description = Loc.T(description);
        var toggle = new ToggleSwitch { OnContent = "", OffContent = "", MinWidth = 0, IsEnabled = false, Margin = new Thickness(0, 0, -6, 0), HorizontalAlignment = HorizontalAlignment.Right };
        Ui.Tip(toggle, Ui.FeatureNotReady);
        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(Stack(4, Text(title), Note(description)));
        Grid.SetColumn(toggle, 1);
        row.Children.Add(toggle);
        return row;
    }

    private UIElement Collapsible(string title, Func<UIElement> content)
    {
        title = Loc.T(title);
        var isOpen = expanded.Contains(title);
        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition());
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var label = new TextBlock { Text = title, FontSize = 13, FontWeight = FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center };
        header.Children.Add(label);
        var chevron = new Border
        {
            Width = 26,
            Height = 26,
            CornerRadius = new CornerRadius(7),
            Background = Ui.Pal("Ink07"),
            Child = Ui.Icon(isOpen ? "" : "", 10)
        };
        Grid.SetColumn(chevron, 1);
        header.Children.Add(chevron);
        var button = new Button
        {
            Style = Ui.StyleOf("NsIconButton"),
            Width = double.NaN,
            Height = 30,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Content = header
        };
        button.Click += (_, _) =>
        {
            if (!expanded.Remove(title))
            {
                expanded.Add(title);
            }

            Rebuild();
        };

        var stack = Stack(10, button);
        if (isOpen)
        {
            stack.Children.Add(new Border
            {
                Padding = new Thickness(14),
                CornerRadius = new CornerRadius(14),
                Background = Ui.Pal("Ink04"),
                Child = content()
            });
        }

        return stack;
    }

    private static UIElement PositionGrid(Point01 current, Action<Point01> choose)
    {
        var grid = new Grid { Width = 180, Height = 104, HorizontalAlignment = HorizontalAlignment.Left, CornerRadius = new CornerRadius(10), Background = Ui.Pal("Ink04") };
        foreach (var x in new[] { 0.0, 0.5, 1.0 })
        {
            foreach (var y in new[] { 0.0, 0.5, 1.0 })
            {
                if (x == 0.5 && y == 0.5)
                {
                    continue;
                }

                var selected = Math.Abs(current.X - x) < 0.01 && Math.Abs(current.Y - y) < 0.01;
                var target = new Point01(x, y);
                var dot = new Button
                {
                    Style = Ui.StyleOf("NsIconButton"),
                    Width = 24,
                    Height = 24,
                    CornerRadius = new CornerRadius(12),
                    Background = selected ? Ui.Rgb(0.44, 0.34, 0.98) : Ui.Pal("Ink14"),
                    HorizontalAlignment = x == 0 ? HorizontalAlignment.Left : x == 1 ? HorizontalAlignment.Right : HorizontalAlignment.Center,
                    VerticalAlignment = y == 0 ? VerticalAlignment.Top : y == 1 ? VerticalAlignment.Bottom : VerticalAlignment.Center,
                    Margin = new Thickness(8)
                };
                dot.Click += (_, _) => choose(target);
                grid.Children.Add(dot);
            }
        }

        return grid;
    }

    private static void AutomationName(DependencyObject element, string name) =>
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(element, name);
}

/// <summary>Words flow like text; a wrap grid would force one cell size.</summary>
internal sealed partial class WordWrapPanel : Panel
{
    private const double Gap = 4;

    protected override Windows.Foundation.Size MeasureOverride(Windows.Foundation.Size availableSize)
    {
        var (x, y, row, widest) = (0.0, 0.0, 0.0, 0.0);
        foreach (var child in Children)
        {
            child.Measure(new Windows.Foundation.Size(availableSize.Width, double.PositiveInfinity));
            var size = child.DesiredSize;
            if (x > 0 && x + size.Width > availableSize.Width)
            {
                y += row + Gap;
                x = 0;
                row = 0;
            }

            x += size.Width + Gap;
            row = Math.Max(row, size.Height);
            widest = Math.Max(widest, x);
        }

        return new Windows.Foundation.Size(double.IsInfinity(availableSize.Width) ? widest : availableSize.Width, y + row);
    }

    protected override Windows.Foundation.Size ArrangeOverride(Windows.Foundation.Size finalSize)
    {
        var (x, y, row) = (0.0, 0.0, 0.0);
        foreach (var child in Children)
        {
            var size = child.DesiredSize;
            if (x > 0 && x + size.Width > finalSize.Width)
            {
                y += row + Gap;
                x = 0;
                row = 0;
            }

            child.Arrange(new Windows.Foundation.Rect(x, y, size.Width, size.Height));
            x += size.Width + Gap;
            row = Math.Max(row, size.Height);
        }

        return finalSize;
    }
}
