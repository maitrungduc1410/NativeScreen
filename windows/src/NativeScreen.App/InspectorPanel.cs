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
    private string meshCategory = "All";

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
        else
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

    private void General()
    {
        var background = Doc.Background;
        var isWallpaper = background.Type is BackgroundType.Mesh or BackgroundType.Wallpaper;
        Add(Labeled("Background", 10, Options(
            ("Wallpaper", isWallpaper, () => Edit(d => d.Background.Type = BackgroundType.Mesh)),
            ("Gradient", background.Type == BackgroundType.Gradient, () => Edit(d => d.Background.Type = BackgroundType.Gradient)),
            ("Color", background.Type == BackgroundType.Solid, () => Edit(d => d.Background.Type = BackgroundType.Solid)),
            ("Image", background.Type == BackgroundType.Image, tools.PickBackgroundImage))));

        if (isWallpaper)
        {
            var categories = new List<string> { "All" };
            categories.AddRange(MeshPreset.BuiltIn.Select(preset => preset.Category).Distinct());
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7, Padding = new Thickness(0, 2, 0, 2) };
            foreach (var category in categories)
            {
                var name = category;
                row.Children.Add(Ui.Option(name, name == meshCategory, () =>
                {
                    meshCategory = name;
                    Rebuild();
                }));
            }

            var strip = new ScrollViewer
            {
                Content = row,
                HorizontalScrollMode = ScrollMode.Enabled,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
                VerticalScrollMode = ScrollMode.Disabled,
                VerticalScrollBarVisibility = ScrollBarVisibility.Disabled
            };
            var swatches = SwatchGrid();
            foreach (var preset in MeshPreset.BuiltIn)
            {
                if (meshCategory != "All" && preset.Category != meshCategory)
                {
                    continue;
                }

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

            Add(Labeled("Wallpaper", 10, strip, swatches));
            if (tools.HasPackage)
            {
                var system = SwatchGrid();
                foreach (var file in EditorTools.SystemWallpapers())
                {
                    var target = file;
                    var thumbnail = new Microsoft.UI.Xaml.Media.ImageBrush
                    {
                        ImageSource = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(file)) { DecodePixelWidth = 76 },
                        Stretch = Stretch.UniformToFill
                    };
                    var selected = background.Type == BackgroundType.Wallpaper && background.SystemWallpaperName == Path.GetFileNameWithoutExtension(file);
                    system.Children.Add(Swatch(thumbnail, Path.GetFileNameWithoutExtension(file), selected, () => tools.SelectSystemWallpaper(target)));
                }

                if (system.Children.Count > 0)
                {
                    Add(Labeled("Windows wallpapers", 10, system));
                }
            }
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
            var phrases = new TextBox { PlaceholderText = "Custom phrases, separated by commas", Text = string.Join(", ", Doc.Background.SensitiveDataCustomPhrases) };
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
        Add(Labeled("Cursor style", 10, Options(
            ("Arrow", Doc.Cursor.ThemeId == "arrow", () => Edit(d => d.Cursor.ThemeId = "arrow")),
            ("Rounded", Doc.Cursor.ThemeId == "rounded", () => Edit(d => d.Cursor.ThemeId = "rounded")),
            ("Touch", Doc.Cursor.ThemeId == "touch", () => Edit(d => d.Cursor.ThemeId = "touch")))));
        Add(Toggle("Always use pointer cursor", null, () => Doc.Cursor.AlwaysUsePointer, (d, v) => d.Cursor.AlwaysUsePointer = v));
        Add(Toggle("Hide cursor if not moving", null, () => Doc.Cursor.HideWhenIdleAfterMs is not null, (d, v) => d.Cursor.HideWhenIdleAfterMs = v ? 2000 : null));
        Add(Toggle("Loop cursor position", null, () => Doc.Cursor.LoopBackToStartMs is not null, (d, v) => d.Cursor.LoopBackToStartMs = v ? 1000 : null));
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
            Add(Slider("Click sound volume", () => Doc.Cursor.ClickEffect.SoundVolume, (d, v) => d.Cursor.ClickEffect.SoundVolume = v, 0, 1, 0.5));
        }

        AddDivider();
        Add(Collapsible("Rotation", () => Stack(16,
            Toggle("Rotate cursor", "How the cursor rotates as it chases the mouse.", () => Doc.Cursor.VelocityRotationEnabled, (d, v) => d.Cursor.VelocityRotationEnabled = v),
            Options(
                ("Tilt", Doc.Cursor.RotationMode == CursorRotationMode.Tilt, () => Edit(d => d.Cursor.RotationMode = CursorRotationMode.Tilt)),
                ("Follow", Doc.Cursor.RotationMode == CursorRotationMode.Follow, () => Edit(d => d.Cursor.RotationMode = CursorRotationMode.Follow))),
            Slider("Tilt amount", () => Doc.Cursor.VelocityRotationIntensity, (d, v) => d.Cursor.VelocityRotationIntensity = v, 0, 1, 0.5))));
        Add(Collapsible("Advanced", () => Stack(16,
            Toggle("Remove cursor shakes", null, () => Doc.Cursor.RemoveShakeThresholdPx > 0, (d, v) => d.Cursor.RemoveShakeThresholdPx = v ? 4 : 0),
            Toggle("Optimize cursor changes", null, () => Doc.Cursor.OptimizeCursorChanges, (d, v) => d.Cursor.OptimizeCursorChanges = v),
            Toggle("Keep cursor in sync with hovers", null, () => Doc.Cursor.KeepInSyncWithHovers, (d, v) => d.Cursor.KeepInSyncWithHovers = v))));
    }

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
            Add(Labeled("Camera Position", 10, PositionGrid()));
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

        Add(Slider("Camera rounded corners", () => Doc.Camera.BorderRadiusRatio, (d, v) => d.Camera.BorderRadiusRatio = v, 0, 0.5, 0.22));
        Add(Toggle("Hide during silence", null, () => Doc.Camera.HideDuringSilenceMs is not null, (d, v) => d.Camera.HideDuringSilenceMs = v ? 2000 : null));
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
            var option = Ui.Option(look.ToString(), looks == look, () => Edit(d => d.Camera.ColorGradePreset = look));
            option.HorizontalAlignment = HorizontalAlignment.Stretch;
            option.Margin = new Thickness(0, 0, 6, 8);
            option.Padding = new Thickness(0);
            wrap.Children.Add(option);
        }

        Add(Labeled("Color grading", 10, wrap));
        Add(Slider("Color grading intensity", () => Doc.Camera.ColorGradeIntensity, (d, v) => d.Camera.ColorGradeIntensity = v, 0, 1, 1));
        Add(Slider("Sharpen", () => Doc.Camera.Sharpen01, (d, v) => d.Camera.Sharpen01 = v, 0, 1, 0));
        AddDivider();
        Add(Toggle("Mirror horizontally", null, () => Doc.Camera.Mirror, (d, v) => d.Camera.Mirror = v));
        Add(Toggle("Face tracking", null, () => Doc.Camera.EnableFaceTracking, (d, v) => d.Camera.EnableFaceTracking = v));
        Add(Collapsible("Advanced", () => Slider("Camera delay", () => Doc.Camera.DelayAdjustmentMs, (d, v) => d.Camera.DelayAdjustmentMs = v, -200, 200, 0)));
    }

    private void Captions()
    {
        var captions = Doc.Captions;
        Add(Text("Captions", medium: true));
        Add(Toggle("Disable captions", null, () => !Doc.Captions.Enabled, (d, v) => d.Captions.Enabled = !v));
        Add(Slider("Caption size", () => Doc.Captions.FontSizeRatio, (d, v) => d.Captions.FontSizeRatio = v, 0.02, 0.10, 0.045));
        Add(Labeled("Font style", 10, Options(
            ("Sans-serif", captions.FontStyle == CaptionFontStyle.SansSerif, () => Edit(d => d.Captions.FontStyle = CaptionFontStyle.SansSerif)),
            ("Serif", captions.FontStyle == CaptionFontStyle.Serif, () => Edit(d => d.Captions.FontStyle = CaptionFontStyle.Serif)),
            ("Mono", captions.FontStyle == CaptionFontStyle.Mono, () => Edit(d => d.Captions.FontStyle = CaptionFontStyle.Mono)))));
        Add(Labeled("Word reveal", 10, Options(
            ("Line by line", captions.WordsReveal == CaptionWordsReveal.LineByLine, () => Edit(d => d.Captions.WordsReveal = CaptionWordsReveal.LineByLine)),
            ("Word by word", captions.WordsReveal == CaptionWordsReveal.WordByWord, () => Edit(d => d.Captions.WordsReveal = CaptionWordsReveal.WordByWord)))));
        Add(Labeled("Line growth", 10, Options(
            ("Full line", captions.LineGrowth == CaptionLineGrowth.FullLine, () => Edit(d => d.Captions.LineGrowth = CaptionLineGrowth.FullLine)),
            ("Expanding", captions.LineGrowth == CaptionLineGrowth.Expanding, () => Edit(d => d.Captions.LineGrowth = CaptionLineGrowth.Expanding)),
            ("Centered", captions.LineGrowth == CaptionLineGrowth.Centered, () => Edit(d => d.Captions.LineGrowth = CaptionLineGrowth.Centered)))));
        Add(Labeled("Word animation", 10, Options(
            ("Appear", captions.WordAnimation == CaptionWordAnimation.Appear, () => Edit(d => d.Captions.WordAnimation = CaptionWordAnimation.Appear)),
            ("Fade in", captions.WordAnimation == CaptionWordAnimation.FadeIn, () => Edit(d => d.Captions.WordAnimation = CaptionWordAnimation.FadeIn)),
            ("Slide in", captions.WordAnimation == CaptionWordAnimation.SlideIn, () => Edit(d => d.Captions.WordAnimation = CaptionWordAnimation.SlideIn)))));
        Add(Labeled("Color", 10, Options(
            ("Dark", captions.ColorTheme == CaptionColorTheme.Dark, () => Edit(d => d.Captions.ColorTheme = CaptionColorTheme.Dark)),
            ("Light", captions.ColorTheme == CaptionColorTheme.Light, () => Edit(d => d.Captions.ColorTheme = CaptionColorTheme.Light)))));
        AddDivider();
        TranscriptControls();
        Add(Action("Export transcript", tools.ExportSrt));
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
        var keyterms = new TextBox { PlaceholderText = "Names and terms, separated by commas", Text = captions.CustomPrompt };
        keyterms.LostFocus += (_, _) =>
        {
            if (keyterms.Text != Doc.Captions.CustomPrompt)
            {
                session.Mutate(document => document.Captions.CustomPrompt = keyterms.Text, structural: false);
            }
        };
        Add(Labeled("Keyterms", 8, keyterms));
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
        Add(Note("Click a word to cut it from the video. Click a cut word to restore it."));
        var words = new WordWrapPanel();
        foreach (var segment in Doc.Captions.Segments.OrderBy(item => item.SourceStartMs))
        {
            var (id, start, end) = (segment.Id, segment.SourceStartMs, segment.SourceEndMs);
            var present = TranscriptEditing.IsRangePresent(Doc, start, end);
            var word = Ui.Option(segment.Text, false, () => session.Mutate(document =>
            {
                if (present)
                {
                    TranscriptEditing.CutSourceRange(document, start, end);
                }
                else
                {
                    var match = document.Captions.Segments.Find(item => item.Id == id);
                    if (match is not null)
                    {
                        match.IsHidden = false;
                    }

                    TranscriptEditing.RestoreSourceRange(document, start, end, session.SourceDurationMs);
                }
            }));
            word.Padding = new Thickness(6, 2, 6, 2);
            word.MinHeight = 24;
            word.Height = 26;
            word.FontSize = 12;
            word.Opacity = present ? 1 : 0.4;
            words.Children.Add(word);
        }

        Add(words);
    }

    private void Audio()
    {
        Add(Text("Microphone", 12.5, "Ink45", true));
        Add(Toggle("Mute microphone", null, () => Doc.Audio.MuteMicrophone, (d, v) => d.Audio.MuteMicrophone = v));
        Add(Slider("Microphone volume", () => Doc.Audio.MicrophoneVolume, (d, v) => d.Audio.MicrophoneVolume = v, 0, 1, 1));
        var preset = Doc.Audio.MicrophoneAudioPreset;
        Add(Labeled("Microphone audio mode", 10, OptionsWrap(
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
        Add(Action("Upload audio", tools.UploadVoiceover));
        foreach (var voiceover in Doc.Timeline.Voiceovers)
        {
            var id = voiceover.Id;
            VoiceoverSegment Find(ProjectDocument d) => d.Timeline.Voiceovers.First(item => item.Id == id);
            Add(Collapsible($"Voiceover at {Ui.Timecode(voiceover.SourceStartMs)}", () => Stack(14,
                Slider("Volume", () => Doc.Timeline.Voiceovers.Find(item => item.Id == id)?.Volume ?? 1, (d, v) => Find(d).Volume = v, 0, 1, 1),
                Toggle("Hide & mute original recording", null, () => Doc.Timeline.Voiceovers.Find(item => item.Id == id)?.HideRecording ?? false, (d, v) => Find(d).HideRecording = v),
                Toggle("Disable voiceover", null, () => Doc.Timeline.Voiceovers.Find(item => item.Id == id)?.Disabled ?? false, (d, v) => Find(d).Disabled = v),
                Action("Remove voiceover", () => Edit(d => d.Timeline.Voiceovers.RemoveAll(item => item.Id == id))))));
        }
    }

    private void Shortcuts()
    {
        Add(Toggle("Show shortcuts", null, () => Doc.Captions.ShowKeystrokes, (d, v) => d.Captions.ShowKeystrokes = v));
        Add(Slider("Shortcut labels size", () => Doc.Captions.ShortcutsSizeRatio, (d, v) => d.Captions.ShortcutsSizeRatio = v, 0.075, 0.25, 0.11));
        Add(Toggle("Show single key shortcuts", null, () => Doc.Captions.ShowSingleKeyShortcuts, (d, v) => d.Captions.ShowSingleKeyShortcuts = v));
        AddDivider();
        var style = Doc.Captions.DefaultShortcutStyle;
        Add(Labeled("Position", 10, Options(
            ("Bottom", style.DockPosition == ShortcutDockPosition.Bottom, () => Edit(d => d.Captions.DefaultShortcutStyle.DockPosition = ShortcutDockPosition.Bottom)),
            ("Top", style.DockPosition == ShortcutDockPosition.Top, () => Edit(d => d.Captions.DefaultShortcutStyle.DockPosition = ShortcutDockPosition.Top)),
            ("Left", style.DockPosition == ShortcutDockPosition.Left, () => Edit(d => d.Captions.DefaultShortcutStyle.DockPosition = ShortcutDockPosition.Left)),
            ("Right", style.DockPosition == ShortcutDockPosition.Right, () => Edit(d => d.Captions.DefaultShortcutStyle.DockPosition = ShortcutDockPosition.Right)))));
        Add(Slider("Horizontal offset", () => Doc.Captions.DefaultShortcutStyle.OffsetX, (d, v) => d.Captions.DefaultShortcutStyle.OffsetX = v, -0.45, 0.45, 0));
        Add(Slider("Vertical offset", () => Doc.Captions.DefaultShortcutStyle.OffsetY, (d, v) => d.Captions.DefaultShortcutStyle.OffsetY = v, -0.45, 0.45, 0));
        Add(Labeled("Keycap color", 10, Options(
            ("Default", style.ColorMode == ShortcutColorMode.DefaultDark, () => Edit(d => d.Captions.DefaultShortcutStyle.ColorMode = ShortcutColorMode.DefaultDark)),
            ("Solid", style.ColorMode == ShortcutColorMode.Solid, () => Edit(d => d.Captions.DefaultShortcutStyle.ColorMode = ShortcutColorMode.Solid)),
            ("Gradient", style.ColorMode == ShortcutColorMode.Gradient, () => Edit(d => d.Captions.DefaultShortcutStyle.ColorMode = ShortcutColorMode.Gradient)))));
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

    private void ZoomEditor(ZoomBlock zoom)
    {
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

    private static StackPanel Options(params (string Title, bool Selected, Action? Click)[] options)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        foreach (var (title, selected, click) in options)
        {
            row.Children.Add(Ui.Option(title, selected, click));
        }

        return row;
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

    private static Button Swatch(Brush fill, string tooltip, bool selected, Action click)
    {
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
        ToolTipService.SetToolTip(button, tooltip);
        button.Click += (_, _) => click();
        return button;
    }

    private static Button Action(string title, Action? click)
    {
        var button = Ui.Option(title, false, click);
        button.HorizontalAlignment = HorizontalAlignment.Stretch;
        return button;
    }

    private static Button CloseEditor(string title, Action click)
    {
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
            Content = "Reset",
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

    private static UIElement Disabled(string title, string description)    {
        var toggle = new ToggleSwitch { OnContent = "", OffContent = "", MinWidth = 0, IsEnabled = false, Margin = new Thickness(0, 0, -6, 0), HorizontalAlignment = HorizontalAlignment.Right };
        ToolTipService.SetToolTip(toggle, Ui.FeatureNotReady);
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

    private UIElement PositionGrid()
    {
        var grid = new Grid { Width = 180, Height = 104, HorizontalAlignment = HorizontalAlignment.Left, CornerRadius = new CornerRadius(10), Background = Ui.Pal("Ink04") };
        var current = Doc.Camera.Position01;
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
                dot.Click += (_, _) => Edit(d => d.Camera.Position01 = target);
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
