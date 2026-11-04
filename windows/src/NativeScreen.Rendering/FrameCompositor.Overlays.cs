using System.Numerics;
using System.Text.Json;
using NativeScreen.Core;
using Vortice.Direct2D1;
using Vortice.Direct3D11;
using Vortice.DirectWrite;
using Vortice.DXGI;
using Vortice.Mathematics;

namespace NativeScreen.Rendering;

public sealed partial class FrameCompositor
{
    private const string SansFont = "Segoe UI";
    private const double CaptionFadeBlurRadius = 5;
    private const double MinimumCaptionBlur = 0.05;
    private const int CaptionPatchStep = 64;
    private const int MaximumCaptionWordSprites = 256;
    private readonly Dictionary<string, ID3D11ShaderResourceView> lutViews = [];
    private readonly Dictionary<string, RenderLayer> keycapSprites = [];
    private ID3D11Buffer? lutConstants;
    private ID3D11Buffer? sharpenConstants;
    private ID3D11ShaderResourceView? wallpaperView;
    private (string Path, int Width, int Height)? wallpaperInfo;
    private string? cameraShadowKey;
    private readonly Dictionary<(string Text, double Size, CaptionFontStyle Style, CaptionColorTheme Theme), RenderLayer> captionWords = [];
    private CaptionTextMeasure? captionMeasure;
    private string? bezelKey;

    private OverlayRasterizer Overlays => overlays ??= new OverlayRasterizer(_graphics.Device);

    // Pass 6, in the same order as composeFrame: camera, captions, keycaps.
    private void DrawOverlays(RenderLayer frame, ComposeRequest request, StageFrame stage, int width, int height)
    {
        if (request.HasCamera && stage.Opacity > 0.004 && stage.CameraRect.Width > 0)
        {
            DrawCamera(frame, request, stage, width, height);
        }

        var captions = request.Document.Captions;
        if (captions.Enabled && captions.CaptionBlocks.Count > 0)
        {
            DrawCaptions(frame, captions, request.SourceMs, width, height);
        }
        else if (CaptionHitRects01.Count > 0)
        {
            CaptionHitRects01 = new Dictionary<string, Vector4>();
        }

        DrawKeycaps(frame, request, width, height);
    }

    // MARK: Camera

    private void DrawCamera(RenderLayer frame, ComposeRequest request, StageFrame stage, int width, int height)
    {
        var context = _graphics.Context;
        var config = request.Document.Camera;
        var rect = stage.CameraRect;
        var baseSize = Math.Min(width, height);
        var clip = new Vector4((float)rect.X, (float)rect.Y, (float)rect.Width, (float)rect.Height);
        var layer = Layer("camera", width, height);
        context.ClearRenderTargetView(layer.Target, new Color4(0, 0, 0, 0));
        if (stage.ShadowOpacity > 0.004)
        {
            // The shadow follows the rounded rect, so it stays baked until the placement changes. Cutout needs the mask pass.
            var baked = Layer("camera-shadow", width, height);
            var key = FormattableString.Invariant($"{rect}|{stage.CornerRadius}|{stage.ShadowOpacity}|{width}x{height}");
            if (key != cameraShadowKey)
            {
                cameraShadowKey = key;
                context.ClearRenderTargetView(baked.Target, new Color4(0, 0, 0, 0));
                BindTarget(baked);
                context.OMSetBlendState(_sourceOver);
                DrawBox(
                    new Vector4(clip.X, clip.Y + (float)(baseSize * 0.008), clip.Z, clip.W),
                    (float)stage.CornerRadius,
                    0,
                    new Vector4(0, 0, 0, (float)stage.ShadowOpacity));
                Blur(baked, baseSize * 0.011);
            }

            BindTarget(layer);
            context.OMSetBlendState(_sourceOver);
            DrawQuad(baked.View, Identity(width, height), default, 0, 1);
        }

        BindTarget(layer);
        context.OMSetBlendState(_sourceOver);
        if (request.Webcam is { } webcam)
        {
            var graded = GradedCamera(webcam, request, out var sourceWidth, out var sourceHeight);
            BindTarget(layer);
            context.OMSetBlendState(_sourceOver);
            var faceZoom = config.EnableFaceTracking ? 1.16 : 1.0;
            var scale = Math.Max(rect.Width / sourceWidth, rect.Height / sourceHeight) * faceZoom;
            var drawnWidth = sourceWidth * scale;
            var drawnHeight = sourceHeight * scale;
            var left = rect.X + (rect.Width - drawnWidth) / 2;
            var top = rect.Y + (rect.Height - drawnHeight) / 2;
            DrawQuad(
                graded,
                new QuadMap(
                    new Vector4((float)(1 / drawnWidth), 0, (float)(-left / drawnWidth), 0),
                    new Vector4(0, (float)(1 / drawnHeight), (float)(-top / drawnHeight), 0)),
                clip,
                (float)stage.CornerRadius,
                1);
        }
        else
        {
            // No decoded camera frame: a neutral placeholder in the same shape.
            DrawBox(clip, (float)stage.CornerRadius, 0, new Vector4(0.2f, 0.2f, 0.24f, 1));
        }

        if (stage.BorderOpacity > 0.004)
        {
            DrawBox(
                new Vector4(clip.X + 0.5f, clip.Y + 0.5f, clip.Z - 1, clip.W - 1),
                (float)Math.Max(0, stage.CornerRadius - 0.5),
                (float)Math.Max(1, baseSize * 0.0014),
                new Vector4(1, 1, 1, (float)stage.BorderOpacity));
        }

        BindTarget(frame);
        context.OMSetBlendState(_sourceOver);
        DrawQuad(layer.View, Identity(width, height), default, 0, (float)stage.Opacity);
    }

    /// <summary>Crop, default mirror and look, before placement. The raw frame is flipped unless mirror is on.</summary>
    private ID3D11ShaderResourceView GradedCamera(ID3D11ShaderResourceView webcam, ComposeRequest request, out int width, out int height)
    {
        var config = request.Document.Camera;
        var crop = config.CropRect01;
        var cropWidth = Math.Max(0.25, crop.Width);
        var cropHeight = Math.Max(0.25, crop.Height);
        width = Math.Max(16, (int)(cropWidth * request.WebcamWidth));
        height = Math.Max(16, (int)(cropHeight * request.WebcamHeight));
        var context = _graphics.Context;
        var raw = Layer("camera-raw", width, height);
        BindTarget(raw);
        context.OMSetBlendState(null);
        var flip = !config.Mirror;
        DrawQuad(
            webcam,
            new QuadMap(
                new Vector4((float)((flip ? -cropWidth : cropWidth) / width), 0, (float)(flip ? crop.X + cropWidth : crop.X), 0),
                new Vector4(0, (float)(cropHeight / height), (float)crop.Y, 0)),
            default,
            0,
            1);

        var lut = LookTable(config, request.PackageDirectory);
        if (lut is null || config.ColorGradeIntensity <= 0.005)
        {
            return Sharpened(raw, config, width, height);
        }

        var graded = Layer("camera-graded", width, height);
        context.UnsetRenderTargets();
        lutConstants ??= CreateConstants(16);
        context.UpdateSubresource(new Vector4((float)Math.Clamp(config.ColorGradeIntensity, 0, 1), lutSizes[lut], 0, 0), lutConstants);
        context.CSSetShader(_lut);
        context.CSSetShaderResource(0, raw.View);
        context.CSSetShaderResource(1, lut);
        context.CSSetSampler(0, linearClamp);
        context.CSSetUnorderedAccessView(0, graded.Unordered);
        context.CSSetConstantBuffer(0, lutConstants);
        context.Dispatch((uint)((width + 7) / 8), (uint)((height + 7) / 8), 1);
        context.CSSetUnorderedAccessView(0, null!);
        context.CSSetShaderResource(0, null!);
        context.CSSetShaderResource(1, null!);
        return Sharpened(graded, config, width, height);
    }

    private ID3D11ShaderResourceView Sharpened(RenderLayer layer, CameraConfig config, int width, int height)
    {
        var amount = Math.Clamp(config.Sharpen01, 0, 1);
        if (amount <= 0.01)
        {
            return layer.View;
        }

        var context = _graphics.Context;
        var sharp = Layer("camera-sharp", width, height);
        context.UnsetRenderTargets();
        sharpenConstants ??= CreateConstants(16);
        context.UpdateSubresource(new Vector4((float)(amount * 1.15), 0, 0, 0), sharpenConstants);
        context.CSSetShader(_sharpen);
        context.CSSetShaderResource(0, layer.View);
        context.CSSetUnorderedAccessView(0, sharp.Unordered);
        context.CSSetConstantBuffer(0, sharpenConstants);
        context.Dispatch((uint)((width + 7) / 8), (uint)((height + 7) / 8), 1);
        context.CSSetUnorderedAccessView(0, null!);
        context.CSSetShaderResource(0, null!);
        return sharp.View;
    }

    private const int CustomLutSize = 33;

    private readonly Dictionary<ID3D11ShaderResourceView, int> lutSizes = [];
    private readonly HashSet<string> brokenLuts = [];

    /// <summary>A LUT file in the package, or null when it is missing or broken, so the built-in look shows instead.</summary>
    private ID3D11ShaderResourceView? FileLookTable(CameraConfig config, string? packageDirectory)
    {
        if (config.CustomLutRelativePath is not { Length: > 0 } relative || packageDirectory is null)
        {
            return null;
        }

        var path = Path.Combine(packageDirectory, relative);
        if (!File.Exists(path))
        {
            return null;
        }

        var key = $"file|{path}|{File.GetLastWriteTimeUtc(path).Ticks}";
        if (lutViews.TryGetValue(key, out var known))
        {
            return known;
        }

        if (brokenLuts.Contains(key))
        {
            return null;
        }

        if (CubeLut.TryParse(File.ReadAllText(path)) is not { } table)
        {
            brokenLuts.Add(key);
            return null;
        }

        var view = CreateLutView(table);
        lutViews[key] = view;
        lutSizes[view] = table.Size;
        return view;
    }

    /// <summary>Built-in looks come from the LUTs exported on macOS. A custom preset bakes the same math into one. A LUT file comes between them (spec/06 ADR-31).</summary>
    private ID3D11ShaderResourceView? LookTable(CameraConfig config, string? packageDirectory)
    {
        var custom = config.CustomColorPresets.Find(preset => preset.Id == config.SelectedCustomColorPresetId);
        if (custom is null && FileLookTable(config, packageDirectory) is { } fromFile)
        {
            return fromFile;
        }

        if (custom is null && config.ColorGradePreset == CameraColorGradePreset.Original)
        {
            return null;
        }

        var key = custom is null ? config.ColorGradePreset.ToString() : JsonSerializer.Serialize(custom, ProjectJson.Compact);
        if (lutViews.TryGetValue(key, out var view))
        {
            return view;
        }

        CubeLut table;
        if (custom is null)
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Assets", "Looks", config.ColorGradePreset.ToString().ToLowerInvariant() + ".cube");
            if (!File.Exists(path))
            {
                return null;
            }

            table = CubeLut.Parse(File.ReadAllText(path));
        }
        else
        {
            var rgb = new float[CustomLutSize * CustomLutSize * CustomLutSize * 3];
            var at = 0;
            for (var b = 0; b < CustomLutSize; b++)
            {
                for (var g = 0; g < CustomLutSize; g++)
                {
                    for (var r = 0; r < CustomLutSize; r++)
                    {
                        var graded = Rgba.Opaque(r / 32.0, g / 32.0, b / 32.0).ApplyCustomPreset(custom);
                        rgb[at++] = (float)graded.R;
                        rgb[at++] = (float)graded.G;
                        rgb[at++] = (float)graded.B;
                    }
                }
            }

            table = new CubeLut(CustomLutSize, rgb);
        }

        view = CreateLutView(table);
        lutViews[key] = view;
        lutSizes[view] = table.Size;
        return view;
    }

    private ID3D11ShaderResourceView CreateLutView(CubeLut table)
    {
        var size = table.Size;
        var pixels = new ushort[size * size * size * 4];
        for (var i = 0; i < size * size * size; i++)
        {
            for (var channel = 0; channel < 3; channel++)
            {
                pixels[i * 4 + channel] = (ushort)(Math.Clamp(table.Rgb[i * 3 + channel], 0, 1) * 65535 + 0.5f);
            }

            pixels[i * 4 + 3] = 65535;
        }

        var handle = System.Runtime.InteropServices.GCHandle.Alloc(pixels, System.Runtime.InteropServices.GCHandleType.Pinned);
        try
        {
            using var texture = _graphics.Device.CreateTexture3D(
                new Texture3DDescription
                {
                    Width = (uint)size,
                    Height = (uint)size,
                    Depth = (uint)size,
                    MipLevels = 1,
                    Format = Format.R16G16B16A16_UNorm,
                    Usage = ResourceUsage.Immutable,
                    BindFlags = BindFlags.ShaderResource
                },
                new SubresourceData(handle.AddrOfPinnedObject(), (uint)(size * 8), (uint)(size * size * 8)));
            return _graphics.Device.CreateShaderResourceView(texture);
        }
        finally
        {
            handle.Free();
        }
    }

    // MARK: Captions

    /// <summary>Visible caption boxes in the last frame, normalized, for clicks on the preview. Swapped whole, so another thread may read it.</summary>
    public IReadOnlyDictionary<string, Vector4> CaptionHitRects01 { get; private set; } = new Dictionary<string, Vector4>();

    /// <summary>Each track draws the frame from CaptionLineLayout. Boxes come from the box shader, and each word is rasterized once and then moved and faded.</summary>
    private void DrawCaptions(RenderLayer frame, CaptionsConfig config, double sourceMs, int width, int height)
    {
        captionMeasure ??= MeasureCaption;
        var frames = CaptionLineLayout.Frames(config, sourceMs, width, height, captionMeasure);
        Dictionary<string, Vector4>? hits = null;
        if (captionWords.Count > MaximumCaptionWordSprites)
        {
            foreach (var sprite in captionWords.Values)
            {
                sprite.Dispose();
            }

            captionWords.Clear();
        }

        // Direct2D must finish before the pipeline is bound for the frame.
        foreach (var track in frames)
        {
            foreach (var word in track.Words)
            {
                CaptionWordSprite(word.Text, track);
            }

            if (track.BoxOpacity > 0.5)
            {
                hits ??= [];
                hits[track.BlockId] = new Vector4(
                    RoundedHit(track.BoxRect.X / width),
                    RoundedHit(track.BoxRect.Y / height),
                    RoundedHit(track.BoxRect.Width / width),
                    RoundedHit(track.BoxRect.Height / height));
            }
        }

        if (hits is not null || CaptionHitRects01.Count > 0)
        {
            CaptionHitRects01 = hits ?? new Dictionary<string, Vector4>();
        }

        if (frames.Count == 0)
        {
            return;
        }

        RebindPipeline(frame);
        var blurScale = Math.Min(width, height) / 1080.0;
        foreach (var track in frames)
        {
            DrawCaptionBox(frame, track, blurScale);
            // Pushed words must not show outside the box.
            var clip = track.Style.WordsReveal == CaptionWordsReveal.WordByWord
                ? new Vector4((float)track.BoxRect.X, (float)track.BoxRect.Y, (float)track.BoxRect.Width, (float)track.BoxRect.Height)
                : default;
            foreach (var word in track.Words)
            {
                var sprite = CaptionWordSprite(word.Text, track);
                var sigma = word.Opacity < 0.99 && !word.IsDimmedAtRest ? (1 - word.Opacity) * CaptionFadeBlurRadius * blurScale : 0;
                if (sigma < MinimumCaptionBlur)
                {
                    _graphics.Context.OMSetBlendState(_sourceOver);
                    DrawQuad(sprite.View, PlacedAt(word.Rect.X, word.Rect.Y, sprite.Width, sprite.Height), clip, 0, (float)word.Opacity);
                    continue;
                }

                DrawBlurred(frame, word.Rect.X, word.Rect.Y, sprite.Width, sprite.Height, sigma, clip, (float)word.Opacity, (left, top) =>
                    DrawQuad(sprite.View, PlacedAt(left, top, sprite.Width, sprite.Height), default, 0, 1));
            }
        }

        _graphics.Context.UnsetRenderTargets();
    }

    private void DrawCaptionBox(RenderLayer frame, CaptionLineLayout.TrackFrame track, double blurScale)
    {
        if (track.BoxOpacity <= 0.002)
        {
            return;
        }

        var dark = track.Style.ColorTheme == CaptionColorTheme.Dark;
        var box = track.BoxRect;
        var radius = (float)(track.FontSize * 0.3);
        var ring = (float)Math.Max(1, track.FontSize * 0.025);
        var shade = dark ? 0f : 1f;
        var fill = new Vector4(shade, shade, shade, (float)((dark ? 0.82 : 0.92) * track.BoxOpacity));
        var edge = new Vector4(1 - shade, 1 - shade, 1 - shade, (float)(0.12 * track.BoxOpacity));
        void Draw(double left, double top)
        {
            var rect = new Vector4((float)left, (float)top, (float)box.Width, (float)box.Height);
            DrawBox(rect, radius, 0, fill);
            DrawBox(rect, radius, ring, edge);
        }

        var sigma = track.BoxOpacity < 0.99 ? (1 - track.BoxOpacity) * CaptionFadeBlurRadius * blurScale : 0;
        if (sigma < MinimumCaptionBlur)
        {
            _graphics.Context.OMSetBlendState(_sourceOver);
            Draw(box.X, box.Y);
            return;
        }

        DrawBlurred(frame, box.X, box.Y, box.Width, box.Height, sigma, default, 1, Draw);
    }

    /// <summary>Draws something small into its own patch and blurs only that, so a fading word never blurs a whole canvas.</summary>
    private void DrawBlurred(RenderLayer frame, double x, double y, double width, double height, double sigma, Vector4 clip, float opacity, Action<double, double> draw)
    {
        var margin = Math.Ceiling(sigma * 3) + 2;
        // Sized in steps, since a growing box would otherwise ask for a new texture every frame.
        var patch = Layer(
            "caption-patch",
            (int)(Math.Ceiling((width + margin * 2) / CaptionPatchStep) * CaptionPatchStep),
            (int)(Math.Ceiling((height + margin * 2) / CaptionPatchStep) * CaptionPatchStep));
        var context = _graphics.Context;
        context.PSSetShaderResource(0, null!);
        context.ClearRenderTargetView(patch.Target, new Color4(0, 0, 0, 0));
        BindTarget(patch);
        context.OMSetBlendState(_sourceOver);
        draw(margin, margin);
        Blur(patch, sigma);
        BindTarget(frame);
        context.OMSetBlendState(_sourceOver);
        DrawQuad(patch.View, PlacedAt(x - margin, y - margin, patch.Width, patch.Height), clip, 0, opacity);
    }

    private static QuadMap PlacedAt(double left, double top, double width, double height) => new(
        new Vector4((float)(1 / width), 0, (float)(-left / width), 0),
        new Vector4(0, (float)(1 / height), (float)(-top / height), 0));

    private static float RoundedHit(double value) => (float)(Math.Round(value * 200) / 200);

    private static string CaptionFamily(CaptionFontStyle style) => style switch
    {
        CaptionFontStyle.Serif => "Georgia",
        CaptionFontStyle.Mono => "Consolas",
        _ => SansFont
    };

    private (double Width, double Height) MeasureCaption(string text, CaptionFontStyle style, double size)
    {
        var overlay = Overlays;
        using var format = overlay.WriteFactory.CreateTextFormat(CaptionFamily(style), FontWeight.Medium, FontStyle.Normal, FontStretch.Normal, (float)size);
        using var layout = overlay.WriteFactory.CreateTextLayout(text, format, 4096, 4096);
        return (layout.Metrics.WidthIncludingTrailingWhitespace, layout.Metrics.Height);
    }

    private RenderLayer CaptionWordSprite(string text, CaptionLineLayout.TrackFrame track)
    {
        var key = (text, track.FontSize, track.Style.FontStyle, track.Style.ColorTheme);
        if (captionWords.TryGetValue(key, out var cached))
        {
            return cached;
        }

        var overlay = Overlays;
        using var format = overlay.WriteFactory.CreateTextFormat(CaptionFamily(track.Style.FontStyle), FontWeight.Medium, FontStyle.Normal, FontStretch.Normal, (float)track.FontSize);
        using var layout = overlay.WriteFactory.CreateTextLayout(text, format, 4096, 4096);
        var sprite = new RenderLayer(_graphics.Device, Math.Max(1, (int)Math.Ceiling(layout.Metrics.WidthIncludingTrailingWhitespace)), Math.Max(1, (int)Math.Ceiling(layout.Metrics.Height)));
        var color = track.Style.ColorTheme == CaptionColorTheme.Dark ? new Color4(1, 1, 1, 1) : new Color4(0, 0, 0, 1);
        overlay.Draw(sprite, () =>
        {
            using var brush = overlay.Context.CreateSolidColorBrush(color);
            overlay.Context.DrawTextLayout(Vector2.Zero, layout, brush, DrawTextOptions.None);
        });
        captionWords[key] = sprite;
        return sprite;
    }

    // MARK: Keycaps

    /// <summary>Where the last frame drew each shortcut, normalized, for clicks on the preview. Swapped whole, so another thread may read it.</summary>
    public IReadOnlyDictionary<string, Vector4> ShortcutHitRects01 { get; private set; } = new Dictionary<string, Vector4>();

    private void DrawKeycaps(RenderLayer frame, ComposeRequest request, int width, int height)
    {
        var captions = request.Document.Captions;
        Dictionary<string, Vector4>? hits = null;
        try
        {
            DrawKeycaps(frame, request, width, height, captions, ref hits);
        }
        finally
        {
            if (hits is not null || ShortcutHitRects01.Count > 0)
            {
                ShortcutHitRects01 = hits ?? new Dictionary<string, Vector4>();
            }
        }
    }

    private void DrawKeycaps(RenderLayer frame, ComposeRequest request, int width, int height, CaptionsConfig captions, ref Dictionary<string, Vector4>? hits)
    {
        if (!captions.ShowKeystrokes || request.Shortcuts is not { Count: > 0 } clusters)
        {
            return;
        }

        var keyHeight = (float)CompositeMetrics.KeycapHeight(height, captions.ShortcutsSizeRatio);
        var spacing = MathF.Round(keyHeight * 0.10f);
        var edge = Math.Max(16f, MathF.Round(height * 0.05f));
        var pad = Math.Max(18f, MathF.Ceiling(keyHeight * 0.35f));
        for (var index = 0; index < captions.ShortcutTracks.Count; index++)
        {
            var track = captions.ShortcutTracks[index];
            if (track.IsHidden || (index == 0 && request.Document.Timeline.IsShortcutsTrackHidden))
            {
                continue;
            }

            ShortcutCluster? match = null;
            foreach (var cluster in clusters.Where(item => item.TrackId == track.Id && !IsHidden(captions, item)).OrderBy(item => item.DisplayStartMs))
            {
                if (cluster.DisplayStartMs > request.SourceMs)
                {
                    break;
                }

                match = cluster;
            }

            if (match is null || request.SourceMs > match.DisplayEndMs || match.KeyCaps.Count == 0)
            {
                continue;
            }

            var envelope = ShortcutEngine.Envelope(match.DisplayStartMs, match.DisplayEndMs, request.SourceMs);
            if (envelope.Opacity <= 0.005)
            {
                continue;
            }

            var style = captions.ShortcutStyleOverrides.GetValueOrDefault(match.Id)
                ?? captions.CustomShortcuts.Find(item => item.Id == match.Id)?.CustomStyle
                ?? track.Style;
            var sprite = KeycapSprite(match, style, keyHeight, spacing, pad);
            var contentWidth = sprite.Width - pad * 2;
            var contentHeight = sprite.Height - pad * 2;
            var slide = keyHeight * 0.10f * (float)envelope.Slide;
            var (x, y) = style.DockPosition switch
            {
                ShortcutDockPosition.Top => ((width - contentWidth) / 2, edge - slide),
                ShortcutDockPosition.Left => (edge - slide, (height - contentHeight) / 2),
                ShortcutDockPosition.Right => (width - edge - contentWidth + slide, (height - contentHeight) / 2),
                _ => ((width - contentWidth) / 2, height - edge - contentHeight + slide)
            };
            var centerX = x + contentWidth / 2 + (float)style.OffsetX * width;
            var centerY = y + contentHeight / 2 + (float)style.OffsetY * height;
            var scale = (float)envelope.Scale;
            (hits ??= [])[match.Id] = new Vector4(
                (centerX - contentWidth * scale / 2) / width,
                (centerY - contentHeight * scale / 2) / height,
                contentWidth * scale / width,
                contentHeight * scale / height);
            var drawnWidth = sprite.Width * scale;
            var drawnHeight = sprite.Height * scale;
            RebindPipeline(frame);
            _graphics.Context.OMSetBlendState(_sourceOver);
            DrawQuad(
                sprite.View,
                new QuadMap(
                    new Vector4(1 / drawnWidth, 0, -(centerX - drawnWidth / 2) / drawnWidth, 0),
                    new Vector4(0, 1 / drawnHeight, -(centerY - drawnHeight / 2) / drawnHeight, 0)),
                default,
                0,
                (float)envelope.Opacity);
        }
    }

    private static bool IsHidden(CaptionsConfig captions, ShortcutCluster cluster)
    {
        var custom = captions.CustomShortcuts.Find(item => item.Id == cluster.Id);
        return custom?.IsHidden ?? captions.HiddenShortcutStartMs.Contains(cluster.FirstKeyDownMsInt);
    }

    private RenderLayer KeycapSprite(ShortcutCluster cluster, ShortcutStyleConfig style, float keyHeight, float spacing, float pad)
    {
        var key = $"{cluster.Id}|{cluster.Label}|{keyHeight}|{style.DockPosition}|{style.ColorMode}|{style.SolidColorHex}|{style.GradientStartHex}|{style.GradientEndHex}|{style.TextColorHex}";
        if (keycapSprites.TryGetValue(key, out var cached))
        {
            return cached;
        }

        var vertical = style.DockPosition is ShortcutDockPosition.Left or ShortcutDockPosition.Right;
        var widths = cluster.KeyCaps.Select(cap => MathF.Round(keyHeight * (float)cap.WidthRatio)).ToList();
        var contentWidth = vertical ? widths.Max() : widths.Sum() + Math.Max(0, widths.Count - 1) * spacing;
        var contentHeight = vertical ? widths.Count * keyHeight + Math.Max(0, widths.Count - 1) * spacing : keyHeight;
        var width = Math.Max(4, (int)MathF.Ceiling(contentWidth + pad * 2));
        var height = Math.Max(4, (int)MathF.Ceiling(contentHeight + pad * 2));
        var rects = new List<Rect>();
        var cursorX = pad;
        var cursorY = pad;
        foreach (var keyWidth in widths)
        {
            rects.Add(new Rect(vertical ? pad + (contentWidth - keyWidth) / 2 : cursorX, vertical ? cursorY : pad, keyWidth, keyHeight));
            cursorX += keyWidth + spacing;
            cursorY += keyHeight + spacing;
        }

        // The shadow: black 42%, offset 0.10 kh, blur 0.22 kh. CoreGraphics offsets ignore the flipped context, so it rises.
        var overlay = Overlays;
        var shadow = Layer("keycap-shadow", width, height);
        overlay.Draw(shadow, () =>
        {
            using var brush = overlay.Context.CreateSolidColorBrush(new Color4(0, 0, 0, 0.42f));
            foreach (var rect in rects)
            {
                overlay.Context.FillRoundedRectangle(
                    new RoundedRectangle { Rect = new Rect(rect.X, rect.Y - keyHeight * 0.10f, rect.Width, rect.Height), RadiusX = keyHeight * 0.125f, RadiusY = keyHeight * 0.125f },
                    brush);
            }
        });
        RebindPipeline(shadow);
        Blur(shadow, keyHeight * 0.11);
        _graphics.Context.ClearState();

        var body = Layer("keycap-body", width, height);
        overlay.Draw(body, () =>
        {
            for (var i = 0; i < rects.Count; i++)
            {
                DrawKeycap(overlay, rects[i], cluster.KeyCaps[i], style);
            }
        });

        var sprite = new RenderLayer(_graphics.Device, width, height);
        RebindPipeline(sprite);
        var context = _graphics.Context;
        context.ClearRenderTargetView(sprite.Target, new Color4(0, 0, 0, 0));
        context.OMSetBlendState(_sourceOver);
        DrawQuad(shadow.View, Identity(width, height), default, 0, 1);
        DrawQuad(body.View, Identity(width, height), default, 0, 1);
        context.UnsetRenderTargets();
        keycapSprites[key] = sprite;
        return sprite;
    }

    private static void DrawKeycap(OverlayRasterizer overlay, Rect rect, ShortcutKeyCap cap, ShortcutStyleConfig style)
    {
        var context = overlay.Context;
        var keyHeight = rect.Height;
        var outerRadius = keyHeight * 0.125f;
        var border = Math.Max(1.2f, keyHeight * (3f / 256f));
        var innerRadius = Math.Max(2f, outerRadius - border);
        var innerPad = (keyHeight - border * 2) * 0.125f;
        var inner = new Rect(rect.X + border, rect.Y + border, rect.Width - border * 2, rect.Height - border * 2);
        var dark = style.ColorMode == ShortcutColorMode.DefaultDark;

        using (var backing = context.CreateSolidColorBrush(new Color4(0.08f, 0.08f, 0.10f, 1)))
        {
            context.FillRoundedRectangle(new RoundedRectangle { Rect = rect, RadiusX = outerRadius, RadiusY = outerRadius }, backing);
        }

        var bevelTop = dark ? new Color4(0.396f, 0.396f, 0.396f, 0.92f) : new Color4(1, 1, 1, 0.38f);
        var bevelBottom = dark ? new Color4(0.098f, 0.098f, 0.098f, 1) : new Color4(0, 0, 0, 0.55f);
        FillGradient(context, rect, outerRadius, bevelTop, bevelBottom, new Vector2(rect.X + rect.Width / 2, rect.Y), new Vector2(rect.X + rect.Width / 2, rect.Y + rect.Height));

        var (bodyStart, bodyEnd) = style.ColorMode switch
        {
            ShortcutColorMode.Solid => (Color(style.SolidColorHex, 1), Color(style.SolidColorHex, 0.76f)),
            ShortcutColorMode.Gradient => (Color(style.GradientStartHex, 1), Color(style.GradientEndHex, 1)),
            _ => (new Color4(0.169f, 0.169f, 0.169f, 1), new Color4(0.098f, 0.098f, 0.098f, 1))
        };
        var diagonal = style.ColorMode == ShortcutColorMode.Gradient;
        FillGradient(
            context,
            inner,
            innerRadius,
            bodyStart,
            bodyEnd,
            new Vector2(diagonal ? inner.X : inner.X + inner.Width / 2, inner.Y),
            new Vector2(diagonal ? inner.X + inner.Width : inner.X + inner.Width / 2, inner.Y + inner.Height));

        var textColor = dark ? new Color4(1, 1, 1, 1) : Color(style.TextColorHex, 1);
        var padding = border + innerPad;
        var box = new Rect(rect.X + padding, rect.Y + padding, rect.Width - padding * 2, rect.Height - padding * 2);
        if (cap.Symbol is null)
        {
            DrawKeyText(overlay, cap.Label, keyHeight * 0.33f, FontWeight.Normal, textColor, rect, box, Anchor.Center);
            return;
        }

        var center = cap.Key == "Space";
        DrawKeyText(overlay, cap.Symbol, keyHeight * 0.31f, FontWeight.Normal, textColor, rect, box, center ? Anchor.TopCenter : Anchor.TopLeft);
        if (cap.Label.Length > 0)
        {
            var label = new Color4(textColor.R, textColor.G, textColor.B, 0.96f);
            DrawKeyText(overlay, cap.Label, keyHeight * 0.215f, FontWeight.Medium, label, rect, box, center ? Anchor.BottomCenter : Anchor.BottomLeft);
        }
    }

    private static void DrawKeyText(OverlayRasterizer overlay, string text, float size, FontWeight weight, Color4 color, Rect rect, Rect box, Anchor anchor)
    {
        using var format = overlay.WriteFactory.CreateTextFormat(SansFont, weight, FontStyle.Normal, FontStretch.Normal, size);
        using var layout = overlay.WriteFactory.CreateTextLayout(text, format, 4096, 4096);
        var width = layout.Metrics.WidthIncludingTrailingWhitespace;
        var height = layout.Metrics.Height;
        var x = anchor is Anchor.Center or Anchor.TopCenter or Anchor.BottomCenter ? rect.X + rect.Width / 2 - width / 2 : box.X;
        var y = anchor switch
        {
            Anchor.Center => rect.Y + rect.Height / 2 - height / 2,
            Anchor.TopLeft or Anchor.TopCenter => box.Y,
            _ => box.Y + box.Height - height
        };
        using var brush = overlay.Context.CreateSolidColorBrush(color);
        overlay.Context.DrawTextLayout(new Vector2(x, y), layout, brush, DrawTextOptions.None);
    }

    private static void FillGradient(ID2D1DeviceContext5 context, Rect rect, float radius, Color4 start, Color4 end, Vector2 from, Vector2 to)
    {
        using var stops = context.CreateGradientStopCollection([new GradientStop(0, start), new GradientStop(1, end)]);
        using var brush = context.CreateLinearGradientBrush(new LinearGradientBrushProperties(from, to), stops);
        context.FillRoundedRectangle(new RoundedRectangle { Rect = rect, RadiusX = radius, RadiusY = radius }, brush);
    }

    private static Color4 Color(string hex, float alpha)
    {
        var value = Hex(hex);
        return new Color4(value.X, value.Y, value.Z, alpha);
    }

    private enum Anchor
    {
        Center,
        TopLeft,
        TopCenter,
        BottomLeft,
        BottomCenter
    }

    // MARK: Device mockup

    private void DrawBezel(ProjectDocument document, PixelRect screen, double radius, RenderLayer target, int width, int height)
    {
        var mockup = document.FrameStyle.DeviceMockup;
        if (!mockup.Enabled)
        {
            return;
        }

        var layer = Layer("bezel", width, height);
        var key = FormattableString.Invariant($"{screen}|{radius}|{mockup.DeviceId}|{mockup.ColorVariantId}|{width}x{height}");
        if (key != bezelKey)
        {
            bezelKey = key;
            _graphics.Context.ClearState();
            RasterizeBezel(layer, mockup, screen, (float)radius, height);
        }

        RebindPipeline(target);
        _graphics.Context.OMSetBlendState(_sourceOver);
        DrawQuad(layer.View, Identity(width, height), default, 0, 1);
    }

    private void RasterizeBezel(RenderLayer layer, DeviceMockupConfig mockup, PixelRect screen, float radius, int height)
    {
        var overlay = Overlays;
        var phone = mockup.DeviceId?.Contains("iphone", StringComparison.Ordinal) == true;
        var pad = mockup.DeviceId?.Contains("ipad", StringComparison.Ordinal) == true;
        var scale = height / 900f;
        var bezel = (phone ? 14f : pad ? 16f : 12f) * scale;
        var rim = Math.Max(2.2f, 3.2f * scale);
        var (outerColor, highlight) = mockup.ColorVariantId switch
        {
            "silver" or "white-titanium" => (new Color4(0.82f, 0.83f, 0.85f, 1), new Color4(0.95f, 0.96f, 0.98f, 1)),
            "natural-titanium" or "starlight" => (new Color4(0.68f, 0.66f, 0.62f, 1), new Color4(0.84f, 0.82f, 0.78f, 1)),
            "desert-titanium" => (new Color4(0.72f, 0.63f, 0.56f, 1), new Color4(0.88f, 0.80f, 0.73f, 1)),
            "midnight" => (new Color4(0.16f, 0.19f, 0.25f, 1), new Color4(0.30f, 0.35f, 0.44f, 1)),
            _ => (new Color4(0.20f, 0.20f, 0.22f, 1), new Color4(0.38f, 0.38f, 0.42f, 1))
        };
        var x = (float)screen.X;
        var y = (float)screen.Y;
        var w = (float)screen.Width;
        var h = (float)screen.Height;
        overlay.Draw(layer, () =>
        {
            var context = overlay.Context;
            var hole = new RoundedRectangle { Rect = new Rect(x, y, w, h), RadiusX = radius, RadiusY = radius };
            var outerRect = new Rect(x - bezel - rim, y - bezel - rim, w + (bezel + rim) * 2, h + (bezel + rim) * 2);
            using var ring = Ring(overlay, new RoundedRectangle { Rect = outerRect, RadiusX = radius + bezel + rim, RadiusY = radius + bezel + rim }, hole);
            using var stops = context.CreateGradientStopCollection([new GradientStop(0, highlight), new GradientStop(0.5f, outerColor), new GradientStop(1, highlight)]);
            using var metal = context.CreateLinearGradientBrush(
                new LinearGradientBrushProperties(new Vector2(outerRect.X, outerRect.Y), new Vector2(outerRect.X + outerRect.Width, outerRect.Y + outerRect.Height)),
                stops);
            context.FillGeometry(ring, metal);
            using var glassRing = Ring(overlay, new RoundedRectangle { Rect = new Rect(x - bezel, y - bezel, w + bezel * 2, h + bezel * 2), RadiusX = radius + bezel, RadiusY = radius + bezel }, hole);
            using var glass = context.CreateSolidColorBrush(new Color4(0.04f, 0.04f, 0.05f, 1));
            context.FillGeometry(glassRing, glass);
            if (phone)
            {
                var islandWidth = Math.Min(w * 0.28f, 96 * scale);
                var islandHeight = Math.Max(12f, 22 * scale);
                using var island = context.CreateSolidColorBrush(new Color4(0.03f, 0.03f, 0.04f, 1));
                context.FillRoundedRectangle(
                    new RoundedRectangle { Rect = new Rect(x + w / 2 - islandWidth / 2, y + 10 * scale, islandWidth, islandHeight), RadiusX = islandHeight / 2, RadiusY = islandHeight / 2 },
                    island);
            }
            else if (!pad)
            {
                var notchWidth = Math.Min(w * 0.14f, 130 * scale);
                var notchHeight = Math.Max(10f, 18 * scale);
                var notchTop = y - 2;
                context.FillRoundedRectangle(
                    new RoundedRectangle { Rect = new Rect(x + w / 2 - notchWidth / 2, notchTop, notchWidth, notchHeight), RadiusX = 6 * scale, RadiusY = 6 * scale },
                    glass);
                var lens = Math.Max(2f, 3 * scale);
                using var lensBrush = context.CreateSolidColorBrush(new Color4(0.12f, 0.16f, 0.24f, 1));
                context.FillEllipse(new Ellipse(new Vector2(x + w / 2, notchTop + notchHeight / 2), lens, lens), lensBrush);
            }
        });
    }

    private static ID2D1GeometryGroup Ring(OverlayRasterizer overlay, RoundedRectangle outer, RoundedRectangle hole)
    {
        var factory = overlay.Factory;
        using var a = factory.CreateRoundedRectangleGeometry(outer);
        using var b = factory.CreateRoundedRectangleGeometry(hole);
        return factory.CreateGeometryGroup(Vortice.Direct2D1.FillMode.Alternate, [a, b]);
    }

    // MARK: Wallpaper

    private bool DrawWallpaper(BackgroundConfig settings, string? packageDirectory, int width, int height)
    {
        if (settings.WallpaperRelativePath is not { } relative || packageDirectory is null)
        {
            return false;
        }

        var path = Path.Combine(packageDirectory, relative);
        if (wallpaperInfo?.Path != path)
        {
            wallpaperView?.Dispose();
            wallpaperView = null;
            wallpaperInfo = null;
            if (!File.Exists(path))
            {
                return false;
            }

            var image = ImageTexture.Load(path, 2560);
            wallpaperView = image.CreateView(_graphics.Device);
            wallpaperInfo = (path, image.Width, image.Height);
        }

        if (wallpaperView is null || wallpaperInfo is not { } info)
        {
            return false;
        }

        var scale = Math.Max((double)width / info.Width, (double)height / info.Height);
        var drawnWidth = info.Width * scale;
        var drawnHeight = info.Height * scale;
        DrawQuad(
            wallpaperView,
            new QuadMap(
                new Vector4((float)(1 / drawnWidth), 0, (float)(-(width - drawnWidth) / 2 / drawnWidth), 0),
                new Vector4(0, (float)(1 / drawnHeight), (float)(-(height - drawnHeight) / 2 / drawnHeight), 0)),
            default,
            0,
            1);
        return true;
    }
}
