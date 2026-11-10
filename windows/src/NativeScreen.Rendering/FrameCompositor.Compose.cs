using System.Globalization;
using System.Numerics;
using System.Runtime.InteropServices;
using NativeScreen.Core;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.Mathematics;

namespace NativeScreen.Rendering;

/// <summary>Everything one composed frame depends on. Rects and pixels are top-down.</summary>
public sealed class ComposeRequest
{
    public required ProjectDocument Document { get; init; }
    public required SpringTrajectorySolver Trajectory { get; init; }
    public required double SourceMs { get; init; }
    public ID3D11ShaderResourceView? Screen { get; init; }
    public IVideoFrameSource? ScreenSource { get; init; }
    public IVideoFrameSource? WebcamSource { get; init; }
    public int ScreenWidth { get; init; }
    public int ScreenHeight { get; init; }
    public bool HasCamera { get; init; }
    public bool ExportQuality { get; init; }
    public string? PackageDirectory { get; init; }
    public ID3D11ShaderResourceView? Webcam { get; init; }
    public int WebcamWidth { get; init; }
    public int WebcamHeight { get; init; }
    public IReadOnlyList<ShortcutCluster>? Shortcuts { get; init; }
    public VideoFrame? WebcamFrame { get; init; }
    public VideoFrame? ScreenFrame { get; init; }
    public FaceTrack? FaceTrack { get; init; }
    public IPersonMaskSource? PersonMasks { get; init; }
    /// <summary>A text annotation being typed into on the canvas: the field shows it, so the preview leaves it out.</summary>
    public string? HiddenAnnotationId { get; init; }
    /// <summary>A camera-only recording: the screen source is the camera movie, styled as the camera (spec/06 ADR-77).</summary>
    public bool CameraOnly { get; init; }

    public ComposeRequest At(double sourceMs) => new()
    {
        Document = Document,
        Trajectory = Trajectory,
        SourceMs = sourceMs,
        Screen = Screen,
        ScreenSource = ScreenSource,
        WebcamSource = WebcamSource,
        ScreenWidth = ScreenWidth,
        ScreenHeight = ScreenHeight,
        HasCamera = HasCamera,
        ExportQuality = ExportQuality,
        PackageDirectory = PackageDirectory,
        Webcam = Webcam,
        WebcamWidth = WebcamWidth,
        WebcamHeight = WebcamHeight,
        Shortcuts = Shortcuts,
        WebcamFrame = WebcamFrame,
        ScreenFrame = ScreenFrame,
        FaceTrack = FaceTrack,
        PersonMasks = PersonMasks,
        HiddenAnnotationId = HiddenAnnotationId,
        CameraOnly = CameraOnly
    };
}

public sealed partial class FrameCompositor
{
    private const double BackgroundCrossfadeMs = 320;
    private RenderLayer? previousBackground;
    private long fadeStartTicks;
    private string? backgroundIdentity;
    private (int Width, int Height) backgroundSize;

    private static readonly Vector4 SyntheticScreen = new(0.06f, 0.06f, 0.08f, 1);
    private const int MaximumScratchLayers = 12;
    private const int ScratchLifetimeComposes = 8;
    private readonly Dictionary<string, RenderLayer> layers = [];
    private readonly List<(RenderLayer Layer, long LastUsed)> scratchLayers = [];
    private long composeCount;
    private VideoFrame? downscaledFrame;
    private double downscaledRatio;
    private ID3D11SamplerState? linearClamp;
    private ID3D11Buffer? quadConstants;
    private ID3D11Buffer? blurConstants;
    private ID3D11Buffer? maskConstants;
    private ID3D11Buffer? motionConstants;
    private ID3D11Buffer? lensConstants;
    private ID3D11Buffer? rippleConstants;
    private string? backgroundKey;
    private string? shadowKey;
    private OverlayRasterizer? overlays;

    /// <summary>Render thread only. Draws the whole frame into a canvas-sized layer owned by the compositor.</summary>
    public RenderLayer Compose(ComposeRequest request, int width, int height)
    {
        EnsureComposeResources();
        composeCount++;
        var context = _graphics.Context;
        context.ClearState();
        context.IASetPrimitiveTopology(PrimitiveTopology.TriangleList);
        context.VSSetShader(_fullscreen);
        context.PSSetSampler(0, linearClamp);

        request = WithDecodedFrames(request);
        var document = request.Document;
        var state = request.Trajectory.Evaluate(request.SourceMs);
        var camera = CameraAt(request, request.SourceMs, state.Camera);
        var background = Background(document, request.PackageDirectory, width, height, request.ExportQuality);
        if (request.CameraOnly && request.Screen is { } main)
        {
            request = WithCameraOnlyPicture(request, main);
        }

        var (screenView, screenWidth, screenHeight) = MaskedScreen(request, width, height);
        var cropWidth = Math.Max(16, screenWidth * document.Canvas.CropRect01.Width);
        var cropHeight = Math.Max(16, screenHeight * document.Canvas.CropRect01.Height);
        var stage = new StageLayoutEngine().Resolve(
            document, request.SourceMs, width, height, cropWidth, cropHeight, camera.Scale, request.HasCamera && !request.CameraOnly, cameraOnly: request.CameraOnly, faceTrack: request.FaceTrack);
        var screen = stage.ScreenRect;
        // A camera-only picture that fills the canvas has no frame: no corners, inset or shadow.
        var fillsCanvas = request.CameraOnly && document.Camera.CameraOnlyFraming.FillsCanvas();
        var radius = fillsCanvas ? 0 : CompositeMetrics.ScreenCornerRadius(document.FrameStyle, height, request.CameraOnly);

        // The camera zoom is applied while the screen is drawn, so a zoomed frame comes from source pixels; only the baked
        // shadow and the bezel are enlarged after rendering (spec/06 ADR-67).
        var zoom = ZoomedRect(camera, screen, width, height);
        var drawn = zoom ?? screen;
        var drawScale = drawn.Width / Math.Max(1, screen.Width);
        var soft = ZoomMap(screen, zoom, width, height);
        var layer = Layer("screen", width, height);
        context.ClearRenderTargetView(layer.Target, new Color4(0, 0, 0, 0));
        Viewport(layer);
        if (!fillsCanvas)
        {
            DrawShadow(document, screen, radius, layer, width, height, soft);
            DrawInset(document, drawn, radius * drawScale, layer, height, drawScale);
        }

        DrawScreen(request, screenView, screenWidth, screenHeight, drawn, radius * drawScale, layer);
        if (!request.CameraOnly)
        {
            DrawBezel(document, screen, radius, layer, width, height, soft);
        }

        layer = Rippled(layer, document, state.Cursor, drawn, width, height);
        DrawScreenAnnotations(layer, request, screen, zoom, width, height);
        BindTarget(layer);
        context.OMSetBlendState(_sourceOver);
        if (request.Trajectory.HasRecordedCursor)
        {
            DrawClick(document, state.Cursor, drawn, height * drawScale);
            DrawCursor(document, state.Cursor, request.SourceMs, drawn, layer, height * drawScale, request.PackageDirectory);
        }

        var blurred = MotionBlurred(layer, request, camera, screen, width, height);

        var output = Layer("output", width, height);
        BindTarget(output);
        context.OMSetBlendState(null);
        var fade = request.ExportQuality ? 1 : BackgroundFadeProgress();
        if (fade < 1)
        {
            DrawQuad(previousBackground!.View, Identity(width, height), default, 0, 1);
            context.OMSetBlendState(_sourceOver);
            DrawQuad(background.View, Identity(width, height), default, 0, (float)(1 - Math.Pow(1 - fade, 3)));
            IsAnimating = true;
        }
        else
        {
            DrawQuad(background.View, Identity(width, height), default, 0, 1);
            IsAnimating = false;
        }
        context.OMSetBlendState(_sourceOver);
        DrawQuad(blurred.View, Identity(width, height), default, 0, 1);
        context.UnsetRenderTargets();
        var lensed = Lens(output, camera, screen, width, height);
        DrawCanvasAnnotations(lensed, request, width, height);
        DrawOverlays(lensed, request, stage, width, height);
        context.UnsetRenderTargets();
        RetireScratchLayers();
        return lensed;
    }

    // Turns the newest decoded frames into textures; without a frame the synthetic screen and placeholder camera are drawn.
    private ComposeRequest WithDecodedFrames(ComposeRequest request)
    {
        var screen = request.ScreenSource?.FrameAt(request.SourceMs);
        var webcam = request.WebcamSource?.FrameAt(request.SourceMs + request.Document.Camera.DelayAdjustmentMs);
        if (screen is null && webcam is null)
        {
            return request;
        }

        return new ComposeRequest
        {
            Document = request.Document,
            Trajectory = request.Trajectory,
            SourceMs = request.SourceMs,
            HasCamera = request.HasCamera,
            ExportQuality = request.ExportQuality,
            PackageDirectory = request.PackageDirectory,
            Shortcuts = request.Shortcuts,
            FaceTrack = request.FaceTrack,
            PersonMasks = request.PersonMasks,
            HiddenAnnotationId = request.HiddenAnnotationId,
            CameraOnly = request.CameraOnly,
            WebcamFrame = webcam ?? request.WebcamFrame,
            ScreenFrame = screen ?? request.ScreenFrame,
            Screen = screen is null ? request.Screen : Nv12View("video-screen", screen),
            ScreenWidth = screen?.Width ?? request.ScreenWidth,
            ScreenHeight = screen?.Height ?? request.ScreenHeight,
            Webcam = webcam is null ? request.Webcam : Nv12View("video-webcam", webcam),
            WebcamWidth = webcam?.Width ?? request.WebcamWidth,
            WebcamHeight = webcam?.Height ?? request.WebcamHeight
        };
    }

    private void EnsureComposeResources()
    {
        if (linearClamp is not null)
        {
            return;
        }

        var device = _graphics.Device;
        linearClamp = device.CreateSamplerState(new SamplerDescription
        {
            Filter = Filter.MinMagMipLinear,
            AddressU = TextureAddressMode.Clamp,
            AddressV = TextureAddressMode.Clamp,
            AddressW = TextureAddressMode.Clamp,
            MaxLOD = float.MaxValue
        });
        quadConstants = CreateConstants(Marshal.SizeOf<QuadConstants>());
        blurConstants = CreateConstants(Marshal.SizeOf<BlurConstants>());
        maskConstants = CreateConstants(Marshal.SizeOf<MaskConstants>());
        motionConstants = CreateConstants(Marshal.SizeOf<MotionConstants>());
        lensConstants = CreateConstants(Marshal.SizeOf<LensConstants>());
        rippleConstants = CreateConstants(Marshal.SizeOf<RippleConstants>());
    }

    private RenderLayer Layer(string name, int width, int height)
    {
        if (layers.TryGetValue(name, out var existing))
        {
            if (existing.Width == width && existing.Height == height)
            {
                return existing;
            }

            existing.Dispose();
        }

        var created = new RenderLayer(_graphics.Device, width, height);
        layers[name] = created;
        return created;
    }

    /// <summary>Scratch space of a given size for one pass. Every size stays only while it is in use, so resizing a window frees the old ones.</summary>
    private RenderLayer ScratchLayer(int width, int height)
    {
        var oldest = 0;
        for (var index = 0; index < scratchLayers.Count; index++)
        {
            var (layer, _) = scratchLayers[index];
            if (layer.Width == width && layer.Height == height)
            {
                scratchLayers[index] = (layer, composeCount);
                return layer;
            }

            if (scratchLayers[index].LastUsed < scratchLayers[oldest].LastUsed)
            {
                oldest = index;
            }
        }

        if (scratchLayers.Count >= MaximumScratchLayers)
        {
            scratchLayers[oldest].Layer.Dispose();
            scratchLayers.RemoveAt(oldest);
        }

        var created = new RenderLayer(_graphics.Device, width, height);
        scratchLayers.Add((created, composeCount));
        return created;
    }

    private void RetireScratchLayers()
    {
        for (var index = scratchLayers.Count - 1; index >= 0; index--)
        {
            if (composeCount - scratchLayers[index].LastUsed > ScratchLifetimeComposes)
            {
                scratchLayers[index].Layer.Dispose();
                scratchLayers.RemoveAt(index);
            }
        }
    }

    /// <summary>How many scratch textures are held right now.</summary>
    public int ScratchLayerCount => scratchLayers.Count;

    private void Viewport(RenderLayer layer)
    {
        _graphics.Context.RSSetViewport(0, 0, layer.Width, layer.Height);
        _graphics.Context.OMSetRenderTargets(layer.Target);
    }

    private void BindTarget(RenderLayer layer)
    {
        // A layer cannot stay bound as a texture while it becomes a target.
        _graphics.Context.PSSetShaderResource(0, null!);
        Viewport(layer);
    }

    // Pass 1. Baked once per key: blur and wallpaper decoding never run per frame.
    /// <summary>The last frame was mid-transition, so the preview must draw again without waiting for an edit.</summary>
    public bool IsAnimating { get; private set; }

    private double BackgroundFadeProgress() =>
        previousBackground is null || fadeStartTicks == 0
            ? 1
            : Math.Min(1, System.Diagnostics.Stopwatch.GetElapsedTime(fadeStartTicks).TotalMilliseconds / BackgroundCrossfadeMs);

    private static string IdentityOf(string key) => key[..key.LastIndexOf('|', key.LastIndexOf('|') - 1)];

    private RenderLayer Background(ProjectDocument document, string? packageDirectory, int width, int height, bool export)
    {
        var settings = document.Background;
        var layer = Layer("background", width, height);
        var key = string.Create(
            CultureInfo.InvariantCulture,
            $"{settings.Type}|{settings.SolidColor}|{settings.MeshPresetId}|{settings.WallpaperRelativePath}|{packageDirectory}|{GradientKey(settings.Gradient)}|{Math.Round(settings.BlurRadius * 2)}|{width}x{height}");
        if (key == backgroundKey)
        {
            return layer;
        }

        var context = _graphics.Context;
        if (!export && backgroundSize == (width, height) && backgroundIdentity is not null && backgroundIdentity != IdentityOf(key))
        {
            previousBackground = Layer("background-previous", width, height);
            context.CopyResource(previousBackground.Texture, layer.Texture);
            fadeStartTicks = System.Diagnostics.Stopwatch.GetTimestamp();
        }

        backgroundSize = (width, height);
        backgroundIdentity = IdentityOf(key);
        backgroundKey = key;
        BindTarget(layer);
        context.OMSetBlendState(null);
        context.PSSetShader(_mesh);
        context.UpdateSubresource(BackgroundFor(settings, width, height), _meshConstants);
        context.PSSetConstantBuffer(0, _meshConstants);
        context.Draw(3, 0);
        if (settings.Type is BackgroundType.Wallpaper or BackgroundType.Image)
        {
            DrawWallpaper(settings, packageDirectory, width, height);
        }

        if (settings.BlurRadius > 0.5)
        {
            Blur(layer, settings.BlurRadius * 0.4);
        }

        return layer;
    }

    private static string GradientKey(GradientConfig gradient) =>
        string.Join(",", gradient.Stops.Select(stop => stop.Color)) + gradient.Start01 + gradient.End01;

    private static BackgroundConstants BackgroundFor(BackgroundConfig settings, int width, int height)
    {
        var size = new Vector2(width, height);
        switch (settings.Type)
        {
            case BackgroundType.Solid:
                var solid = Hex(settings.SolidColor);
                return new BackgroundConstants(solid, solid, solid, Vector2.Zero, size, size, 0, 0);
            case BackgroundType.Gradient:
                var stops = settings.Gradient.Stops;
                return new BackgroundConstants(
                    Hex(stops.Count > 0 ? stops[0].Color : "#4776E6"),
                    Hex(stops.Count > 0 ? stops[^1].Color : "#8E54E9"),
                    Vector4.Zero,
                    new Vector2((float)settings.Gradient.Start01.X * width, (float)settings.Gradient.Start01.Y * height),
                    new Vector2((float)settings.Gradient.End01.X * width, (float)settings.Gradient.End01.Y * height),
                    size,
                    0,
                    0);
            case BackgroundType.Mesh:
                var mesh = MeshPreset.Find(settings.MeshPresetId).ColorsHex;
                return new BackgroundConstants(Hex(mesh[0]), Hex(mesh[1]), Hex(mesh[2]), Vector2.Zero, size, size, 1, 0);
            default:
                // Wallpapers and images draw this until their texture is available, like the macOS fallback.
                var fallback = Hex("#1E1E2E");
                return new BackgroundConstants(fallback, fallback, fallback, Vector2.Zero, size, size, 0, 0);
        }
    }

    // Separable Gaussian in place, using a same-sized scratch layer.
    private void Blur(RenderLayer layer, double sigma)
    {
        var context = _graphics.Context;
        var scratch = ScratchLayer(layer.Width, layer.Height);
        context.OMSetBlendState(null);
        context.PSSetShader(_gaussian);
        BindTarget(scratch);
        context.PSSetShaderResource(0, layer.View);
        context.UpdateSubresource(new BlurConstants(new Vector2(1f / layer.Width, 0), (float)sigma, 0), blurConstants!);
        context.PSSetConstantBuffer(0, blurConstants);
        context.Draw(3, 0);
        BindTarget(layer);
        context.PSSetShaderResource(0, scratch.View);
        context.UpdateSubresource(new BlurConstants(new Vector2(0, 1f / layer.Height), (float)sigma, 0), blurConstants!);
        context.Draw(3, 0);
        context.PSSetShaderResource(0, null!);
    }

    // Pass 2. Works in source pixels, before scaling and zoom.
    private (ID3D11ShaderResourceView? View, int Width, int Height) MaskedScreen(ComposeRequest request, int canvasWidth, int canvasHeight)
    {
        var width = request.Screen is null && request.ScreenWidth <= 0 ? canvasWidth : request.ScreenWidth;
        var height = request.Screen is null && request.ScreenHeight <= 0 ? canvasHeight : request.ScreenHeight;
        if (request.Screen is null)
        {
            return (null, width, height);
        }

        var active = new List<MaskItem>();
        foreach (var track in request.Document.Timeline.MaskTracks)
        {
            if (track.IsHidden)
            {
                continue;
            }

            foreach (var item in track.Items)
            {
                if (!item.Disabled && request.SourceMs >= item.SourceStartMs && request.SourceMs <= item.SourceEndMs)
                {
                    active.Add(item);
                }
            }
        }

        if (active.Count == 0)
        {
            return (request.Screen, width, height);
        }

        var context = _graphics.Context;
        var current = Layer("mask-a", width, height);
        var next = Layer("mask-b", width, height);
        BindTarget(current);
        context.OMSetBlendState(null);
        DrawQuad(request.Screen, Identity(width, height), default, 0, 1);
        foreach (var mask in active)
        {
            var r = mask.InterpolatedRect(request.SourceMs);
            var x = Math.Clamp(r.X * width, 0, width);
            var y = Math.Clamp(r.Y * height, 0, height);
            var w = Math.Min(Math.Max(8, r.Width * width), width - x);
            var h = Math.Min(Math.Max(8, r.Height * height), height - y);
            if (w <= 2 || h <= 2)
            {
                continue;
            }

            var rect = new Vector4((float)x, (float)y, (float)w, (float)h);
            var corner = (float)Math.Min(Math.Min(w, h) * 0.5, mask.CornerRadius * height / 900.0);
            if (mask.Type == MaskType.Spotlight)
            {
                var keep = 1 - Math.Clamp(mask.Intensity / 100, 0, 0.95);
                Effect(current, next, rect, corner, 0, (float)keep, 1);
            }
            else if (mask.Style == MaskStyle.Pixelate)
            {
                Effect(current, next, rect, corner, (float)Math.Max(8, mask.Intensity * 0.85), 1, 0);
            }
            else if (mask.Style == MaskStyle.Solid)
            {
                BindTarget(next);
                context.OMSetBlendState(null);
                DrawQuad(current.View, Identity(width, height), default, 0, 1);
                context.OMSetBlendState(_sourceOver);
                DrawBox(rect, corner, 0, mask.SolidColor is { } fill ? Hex(fill) : new Vector4(0.08f, 0.08f, 0.11f, 1));
            }
            else
            {
                BlurPatch(current, next, rect, corner, Math.Max(4, mask.Intensity * 0.92));
            }

            (current, next) = (next, current);
        }

        context.UnsetRenderTargets();
        return (current.View, width, height);
    }

    private void Effect(RenderLayer from, RenderLayer to, Vector4 rect, float corner, float cell, float keep, int mode)
    {
        var context = _graphics.Context;
        BindTarget(to);
        context.OMSetBlendState(null);
        context.PSSetShader(_maskEffect);
        context.PSSetShaderResource(0, from.View);
        context.UpdateSubresource(new MaskConstants(rect, new Vector2(from.Width, from.Height), corner, cell, keep, mode, Vector2.Zero), maskConstants!);
        context.PSSetConstantBuffer(0, maskConstants);
        context.Draw(3, 0);
    }

    // Quarter resolution, like the macOS pyramid: strong blurs stay cheap.
    private void BlurPatch(RenderLayer from, RenderLayer to, Vector4 rect, float corner, double sigma)
    {
        var context = _graphics.Context;
        var quarter = Layer("mask-quarter", Math.Max(1, from.Width / 4), Math.Max(1, from.Height / 4));
        BindTarget(quarter);
        context.OMSetBlendState(null);
        DrawQuad(from.View, Identity(quarter.Width, quarter.Height), default, 0, 1);
        Blur(quarter, Math.Max(1.2, sigma * 0.25));
        BindTarget(to);
        DrawQuad(from.View, Identity(to.Width, to.Height), default, 0, 1);
        context.OMSetBlendState(_sourceOver);
        DrawQuad(quarter.View, Identity(to.Width, to.Height), rect, corner, 1);
        context.OMSetBlendState(null);
    }

    // Pass 3. The shadow is baked into its own layer and never blurred per frame.
    private void DrawShadow(ProjectDocument document, PixelRect screen, double radius, RenderLayer target, int width, int height, QuadMap soft)
    {
        var shadow = document.FrameStyle.Shadow;
        if (!shadow.Enabled || shadow.Intensity <= 0.01)
        {
            return;
        }

        var placement = CompositeMetrics.ScreenShadow(shadow, height, radius);
        var baked = Layer("shadow", width, height);
        var key = string.Create(
            CultureInfo.InvariantCulture,
            $"{screen}|{radius}|{shadow.Intensity}|{placement.OffsetX}|{placement.OffsetY}|{placement.Sigma}|{width}x{height}");
        var context = _graphics.Context;
        if (key != shadowKey)
        {
            shadowKey = key;
            context.ClearRenderTargetView(baked.Target, new Color4(0, 0, 0, 0));
            BindTarget(baked);
            context.OMSetBlendState(_sourceOver);
            DrawBox(
                new Vector4((float)(screen.X + placement.OffsetX), (float)(screen.Y + placement.OffsetY), (float)screen.Width, (float)screen.Height),
                (float)radius,
                0,
                new Vector4(0, 0, 0, (float)shadow.Intensity));
            Blur(baked, placement.Sigma);
        }

        BindTarget(target);
        context.OMSetBlendState(_sourceOver);
        DrawQuad(baked.View, soft, default, 0, 1);
    }

    private void DrawCursor(ProjectDocument document, SpringTrajectorySolver.CursorFrameState cursor, double sourceMs, PixelRect screen, RenderLayer target, double height, string? packageDirectory)
    {
        var slice = document.Timeline.Slices.Find(item => sourceMs >= item.SourceStartMs && sourceMs <= item.SourceEndMs);
        if (cursor.Opacity <= 0.01 || slice?.HideCursor == true || document.Cursor.Hidden)
        {
            return;
        }

        _graphics.Context.ClearState();
        overlays ??= new OverlayRasterizer(_graphics.Device);
        var sprite = overlays.CustomCursorSprite(document.Cursor, cursor.CursorType, packageDirectory) ?? overlays.CursorSprite(document.Cursor, cursor.CursorType);
        RebindPipeline(target);
        if (sprite is not { } found)
        {
            return;
        }

        var spriteScale = 32.0 * CompositeMetrics.CanvasScale(height) * document.Cursor.Scale / found.Layer.Height;
        var transform =
            Matrix3x2.CreateTranslation((float)(-found.HotspotX * found.Layer.Width), (float)(-found.HotspotY * found.Layer.Height))
            * Matrix3x2.CreateScale((float)spriteScale)
            * Matrix3x2.CreateRotation((float)-cursor.RotationRadians)
            * Matrix3x2.CreateTranslation((float)(screen.X + cursor.Position01.X * screen.Width), (float)(screen.Y + cursor.Position01.Y * screen.Height));
        Matrix3x2.Invert(transform, out var inverse);
        var map = new QuadMap(
            new Vector4(inverse.M11 / found.Layer.Width, inverse.M21 / found.Layer.Width, inverse.M31 / found.Layer.Width, 0),
            new Vector4(inverse.M12 / found.Layer.Height, inverse.M22 / found.Layer.Height, inverse.M32 / found.Layer.Height, 0));
        _graphics.Context.OMSetBlendState(_sourceOver);
        DrawQuad(found.Layer.View, map, default, 0, (float)cursor.Opacity);
    }

    // Direct2D leaves the shared immediate context in an unknown state.
    private void RebindPipeline(RenderLayer target)
    {
        var context = _graphics.Context;
        context.ClearState();
        context.IASetPrimitiveTopology(PrimitiveTopology.TriangleList);
        context.VSSetShader(_fullscreen);
        context.PSSetSampler(0, linearClamp);
        BindTarget(target);
    }

    private void DrawInset(ProjectDocument document, PixelRect screen, double radius, RenderLayer target, int height, double drawScale)
    {
        var inset = document.FrameStyle.Inset;
        if (document.FrameStyle.DeviceMockup.Enabled || !inset.Enabled || inset.Size <= 0.1)
        {
            return;
        }

        var grow = inset.Size * CompositeMetrics.CanvasScale(height) * drawScale;
        var color = Hex(inset.Color);
        color.W = (float)inset.Opacity;
        BindTarget(target);
        _graphics.Context.OMSetBlendState(_sourceOver);
        DrawBox(
            new Vector4((float)(screen.X - grow), (float)(screen.Y - grow), (float)(screen.Width + grow * 2), (float)(screen.Height + grow * 2)),
            (float)(radius + grow),
            0,
            color);
    }

    private void DrawScreen(ComposeRequest request, ID3D11ShaderResourceView? view, int width, int height, PixelRect screen, double radius, RenderLayer target)
    {
        var rect = new Vector4((float)screen.X, (float)screen.Y, (float)screen.Width, (float)screen.Height);
        var context = _graphics.Context;
        BindTarget(target);
        if (view is null)
        {
            // An inset sits under the screen, so the opaque corners must cover it.
            context.OMSetBlendState(_sourceOver);
            DrawBox(rect, (float)radius, 0, SyntheticScreen);
            return;
        }

        var crop = request.Document.Canvas.CropRect01;
        var scaleX = screen.Width / Math.Max(1, width * crop.Width);
        var scaleY = screen.Height / Math.Max(1, height * crop.Height);
        if (Math.Abs(scaleX - scaleY) < 0.002 && scaleX < 0.99 && crop is { X: 0, Y: 0, Width: 1, Height: 1 })
        {
            // Only the plain recording can be reused: masks change with the time, not with the video frame.
            view = Downscaled(view, width, height, scaleX, ReferenceEquals(view, request.Screen) ? request.ScreenFrame : null);
            RebindPipeline(target);
        }
        var map = new QuadMap(
            new Vector4((float)(crop.Width / screen.Width), 0, (float)(crop.X - screen.X * crop.Width / screen.Width), 0),
            new Vector4(0, (float)(crop.Height / screen.Height), (float)(crop.Y - screen.Y * crop.Height / screen.Height), 0));
        context.OMSetBlendState(_sourceOver);
        DrawQuad(view, map, rect, (float)radius, 1);
    }

    // Separable Lanczos into a layer of the scaled size. The shader reads whole texels, so the quad after it maps 1:1 in uv.
    // A display can draw several times per video frame, and a still screen has seconds between frames (spec/06 ADR-66).
    private ID3D11ShaderResourceView Downscaled(ID3D11ShaderResourceView view, int width, int height, double ratio, VideoFrame? frame)
    {
        var scaledWidth = Math.Max(1, (int)Math.Round(width * ratio));
        var scaledHeight = Math.Max(1, (int)Math.Round(height * ratio));
        var horizontal = Layer("lanczos-h", scaledWidth, height);
        var vertical = Layer("lanczos-v", scaledWidth, scaledHeight);
        if (frame is not null && ReferenceEquals(frame, downscaledFrame) && ratio == downscaledRatio)
        {
            return vertical.View;
        }

        downscaledFrame = frame;
        downscaledRatio = ratio;
        var context = _graphics.Context;
        context.OMSetBlendState(null);
        context.PSSetShader(_lanczos);
        BindTarget(horizontal);
        context.PSSetShaderResource(0, view);
        context.UpdateSubresource(new BlurConstants(new Vector2(1, 0), (float)ratio, 0), blurConstants!);
        context.PSSetConstantBuffer(0, blurConstants);
        context.Draw(3, 0);
        BindTarget(vertical);
        context.PSSetShaderResource(0, horizontal.View);
        context.UpdateSubresource(new BlurConstants(new Vector2(0, 1), (float)ratio, 0), blurConstants!);
        context.Draw(3, 0);
        context.PSSetShaderResource(0, null!);
        return vertical.View;
    }

    // Pass 4.
    private void DrawClick(ProjectDocument document, SpringTrajectorySolver.CursorFrameState cursor, PixelRect screen, double height)
    {
        var style = document.Cursor.ClickEffect.VisualStyle;
        if (style != ClickEffectStyle.Circle || cursor.Opacity <= 0.01)
        {
            return;
        }

        var click = CompositeMetrics.Click(cursor.ActiveClickProgress, CompositeMetrics.CanvasScale(height), document.Cursor.Scale, cursor.Opacity);
        if (click is not { } placement)
        {
            return;
        }

        var x = screen.X + cursor.Position01.X * screen.Width;
        var y = screen.Y + cursor.Position01.Y * screen.Height;
        var rect = new Vector4((float)(x - placement.Radius), (float)(y - placement.Radius), (float)(placement.Radius * 2), (float)(placement.Radius * 2));
        DrawBox(rect, (float)placement.Radius, 0, new Vector4(1, 1, 1, (float)(placement.Alpha * 0.65)));
    }

    // The ripple draws nothing on top: it bends the positioned screen, shadow included, before the cursor and the camera (spec/07 Pass 4).
    private RenderLayer Rippled(RenderLayer layer, ProjectDocument document, SpringTrajectorySolver.CursorFrameState cursor, PixelRect screen, int width, int height)
    {
        var style = document.Cursor.ClickEffect.VisualStyle;
        var waves = cursor.ClickWaves;
        if (style is ClickEffectStyle.None or ClickEffectStyle.Circle || waves.Length == 0)
        {
            return layer;
        }

        var reach = (float)Math.Max(screen.Width, screen.Height);
        Vector4 Wave(int index)
        {
            if (index >= waves.Length)
            {
                return default;
            }

            var seconds = (float)(waves[index].AgeMs / 1000);
            var life = seconds / (float)(SpringTrajectorySolver.ClickWaveDurationMs / 1000);
            var fadeOut = 1 - Math.Clamp((life - 0.7f) / 0.3f, 0, 1);
            var bounce = MathF.Exp(-3.4f * seconds) * MathF.Sin(8.8f * seconds) * fadeOut;
            return new Vector4(
                (float)(screen.X + waves[index].Position01.X * screen.Width),
                (float)(screen.Y + waves[index].Position01.Y * screen.Height),
                reach * (0.012f + 0.24f * seconds),
                bounce);
        }

        var output = Layer("ripple", width, height);
        var context = _graphics.Context;
        context.OMSetRenderTargets((ID3D11RenderTargetView)null!);
        context.PSSetShaderResource(0, null!);
        context.CSSetShader(_clickRipple);
        context.CSSetShaderResource(0, layer.View);
        context.CSSetSampler(0, linearClamp);
        context.CSSetUnorderedAccessView(0, output.Unordered);
        context.UpdateSubresource(
            new RippleConstants(Wave(0), Wave(1), Wave(2), Math.Min(waves.Length, SpringTrajectorySolver.MaxActiveClickWaves), reach * 0.042f, reach * 0.013f, reach * 0.0035f, reach * 0.03f, default),
            rippleConstants!);
        context.CSSetConstantBuffer(0, rippleConstants);
        context.Dispatch((uint)((width + 7) / 8), (uint)((height + 7) / 8), 1);
        context.CSSetUnorderedAccessView(0, null!);
        context.CSSetShaderResource(0, null!);
        return output;
    }

    /// <summary>Places a canvas-sized layer drawn around `screen` so that the screen lands on `zoom` (identity at rest).</summary>
    private static QuadMap ZoomMap(PixelRect screen, PixelRect? zoom, int width, int height)
    {
        if (zoom is not { } rect)
        {
            return Identity(width, height);
        }

        var scale = rect.Width / screen.Width;
        return new QuadMap(
            new Vector4((float)(1 / (scale * width)), 0, (float)((screen.X - rect.X / scale) / width), 0),
            new Vector4(0, (float)(1 / (scale * height)), (float)((screen.Y - rect.Y / scale) / height), 0));
    }

    /// <summary>Where the screen rect lands under the classic zoom, or null when the camera is at rest.</summary>
    private static PixelRect? ZoomedRect(SpringTrajectorySolver.CameraFrameState camera, PixelRect screen, int width, int height)
    {
        var scale = Math.Max(1, camera.Scale);
        var offset = Math.Sqrt(Math.Pow(camera.Center01.X - 0.5, 2) + Math.Pow(camera.Center01.Y - 0.5, 2));
        if (camera.IsLoupeMode || (scale <= 1.0005 && offset <= 0.0005))
        {
            return null;
        }

        var focusX = screen.X + camera.Center01.X * screen.Width;
        var focusY = screen.Y + camera.Center01.Y * screen.Height;
        var interpolation = Math.Clamp((scale - 1) / 0.5, 0, 1);
        var targetX = screen.X + screen.Width / 2 + (width / 2.0 - (screen.X + screen.Width / 2)) * interpolation;
        var targetY = screen.Y + screen.Height / 2 + (height / 2.0 - (screen.Y + screen.Height / 2)) * interpolation;
        return new PixelRect((screen.X - focusX) * scale + targetX, (screen.Y - focusY) * scale + targetY, screen.Width * scale, screen.Height * scale);
    }

    // Pass 5.
    private RenderLayer MotionBlurred(RenderLayer layer, ComposeRequest request, SpringTrajectorySolver.CameraFrameState camera, PixelRect screen, int width, int height)
    {
        var document = request.Document;
        var ms = request.SourceMs;
        var instant = document.Timeline.Zooms.Exists(zoom => !zoom.Disabled && zoom.InstantAnimation && ms >= zoom.SourceStartMs && ms <= zoom.SourceEndMs + 50);
        var shutter = Math.Clamp(document.Motion.MotionBlurIntensity, 0, 1);
        if (instant || camera.IsLoupeMode || shutter <= 0.02 || ms <= 8)
        {
            return layer;
        }

        var previousMs = Math.Max(0, ms - 16.67);
        var previous = CameraAt(request, previousMs, request.Trajectory.Evaluate(previousMs).Camera);
        var now = ZoomedRect(camera, screen, width, height) ?? screen;
        var before = ZoomedRect(previous, screen, width, height) ?? screen;
        var opened = new PixelRect(
            now.X + (before.X - now.X) * shutter,
            now.Y + (before.Y - now.Y) * shutter,
            now.Width + (before.Width - now.Width) * shutter,
            now.Height + (before.Height - now.Height) * shutter);
        var travel = Math.Max(
            Math.Max(Math.Abs(opened.X - now.X), Math.Abs(opened.Y - now.Y)),
            Math.Max(Math.Abs(opened.X + opened.Width - now.X - now.Width), Math.Abs(opened.Y + opened.Height - now.Y - now.Height)));
        if (travel < 0.5)
        {
            return layer;
        }

        var output = Layer("motion", width, height);
        var context = _graphics.Context;
        context.UnsetRenderTargets();
        context.PSSetShaderResource(0, null!);
        context.CSSetShader(_motionBlur);
        context.CSSetShaderResource(0, layer.View);
        context.CSSetSampler(0, linearClamp);
        context.CSSetUnorderedAccessView(0, output.Unordered);
        context.UpdateSubresource(
            new MotionConstants(ToVector(now), ToVector(before), (float)shutter, (float)CompositeMetrics.MotionBlurPixelsPerSample(request.ExportQuality), CompositeMetrics.MotionBlurSampleCap(request.ExportQuality), 0),
            motionConstants!);
        context.CSSetConstantBuffer(0, motionConstants);
        context.Dispatch((uint)((width + 7) / 8), (uint)((height + 7) / 8), 1);
        context.CSSetUnorderedAccessView(0, null!);
        context.CSSetShaderResource(0, null!);
        return output;
    }

    private RenderLayer Lens(RenderLayer layer, SpringTrajectorySolver.CameraFrameState camera, PixelRect screen, int width, int height)
    {
        if (camera.LoupePresence01 <= 0.005 || camera.LoupeScale <= 1.002)
        {
            return layer;
        }

        var output = Layer("lens", width, height);
        var context = _graphics.Context;
        var center = new Vector2((float)(screen.X + camera.Center01.X * screen.Width), (float)(screen.Y + camera.Center01.Y * screen.Height));
        var radius = (float)Math.Max(48, Math.Max(screen.Width, screen.Height) * camera.LoupeConfig.Radius01);
        context.PSSetShaderResource(0, null!);
        context.CSSetShader(_lens);
        context.CSSetShaderResource(0, layer.View);
        context.CSSetSampler(0, linearClamp);
        context.CSSetUnorderedAccessView(0, output.Unordered);
        context.UpdateSubresource(
            new LensConstants(center, radius, (float)camera.LoupeScale, (float)Math.Max(0.18, camera.LoupeConfig.BevelRatio), (float)Math.Max(0.55, camera.LoupeConfig.ChromaticAberration), (float)camera.LoupePresence01, 0),
            lensConstants!);
        context.CSSetConstantBuffer(0, lensConstants);
        context.Dispatch((uint)((width + 7) / 8), (uint)((height + 7) / 8), 1);
        context.CSSetUnorderedAccessView(0, null!);
        context.CSSetShaderResource(0, null!);
        return output;
    }

    private void DrawQuad(ID3D11ShaderResourceView view, QuadMap map, Vector4 clip, float clipRadius, float opacity, bool blackSilhouette = false)
    {
        var context = _graphics.Context;
        context.PSSetShader(_quad);
        context.PSSetShaderResource(0, view);
        context.UpdateSubresource(new QuadConstants(map.U, map.V, clip, clipRadius, opacity, new Vector2(blackSilhouette ? 1 : 0, 0)), quadConstants!);
        context.PSSetConstantBuffer(0, quadConstants);
        context.Draw(3, 0);
        context.PSSetShaderResource(0, null!);
    }

    private void DrawBox(Vector4 rect, float radius, float ring, Vector4 color)
    {
        var context = _graphics.Context;
        context.PSSetShader(_box);
        context.UpdateSubresource(new BoxConstants(rect, radius, ring, Vector2.Zero, color), _boxConstants);
        context.PSSetConstantBuffer(0, _boxConstants);
        context.Draw(3, 0);
    }

    private static QuadMap Identity(int width, int height) =>
        new(new Vector4(1f / width, 0, 0, 0), new Vector4(0, 1f / height, 0, 0));

    private static Vector4 ToVector(PixelRect rect) => new((float)rect.X, (float)rect.Y, (float)rect.Width, (float)rect.Height);

    /// <summary>Same parser and fallback as the macOS CIColor(hexString:). Values stay sRGB-encoded.</summary>
    private static Vector4 Hex(string value)
    {
        var text = value.TrimStart('#');
        if (text.Length is 6 or 8 && uint.TryParse(text, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var raw))
        {
            var rgb = text.Length == 8 ? raw >> 8 : raw;
            var alpha = text.Length == 8 ? (raw & 255) / 255f : 1f;
            return new Vector4(((rgb >> 16) & 255) / 255f, ((rgb >> 8) & 255) / 255f, (rgb & 255) / 255f, alpha);
        }

        return new Vector4(0.28f, 0.46f, 0.90f, 1);
    }

    private readonly record struct QuadMap(Vector4 U, Vector4 V);

    [StructLayout(LayoutKind.Sequential)]
    private readonly record struct BackgroundConstants(Vector4 Color0, Vector4 Color1, Vector4 Color2, Vector2 Point0, Vector2 Point1, Vector2 OutputSize, float RadialAmount, float Pad);

    [StructLayout(LayoutKind.Sequential)]
    private readonly record struct BoxConstants(Vector4 Rect, float Radius, float RingWidth, Vector2 Pad, Vector4 Color);

    [StructLayout(LayoutKind.Sequential)]
    private readonly record struct QuadConstants(Vector4 MapU, Vector4 MapV, Vector4 Clip, float ClipRadius, float Opacity, Vector2 Pad);

    [StructLayout(LayoutKind.Sequential)]
    private readonly record struct BlurConstants(Vector2 TexelStep, float Sigma, float Pad);

    [StructLayout(LayoutKind.Sequential)]
    private readonly record struct MaskConstants(Vector4 Rect, Vector2 OutputSize, float Radius, float Cell, float Keep, int Mode, Vector2 Pad);

    [StructLayout(LayoutKind.Sequential)]
    private readonly record struct MotionConstants(Vector4 RectNow, Vector4 RectPrevious, float Shutter, float PixelsPerSample, int MaxSamples, float Pad);

    [StructLayout(LayoutKind.Sequential)]
    private readonly record struct RippleConstants(Vector4 Wave0, Vector4 Wave1, Vector4 Wave2, int WaveCount, float BandWidth, float Pull, float Fringe, float CoreRadius, Vector3 Pad);

    [StructLayout(LayoutKind.Sequential)]
    private readonly record struct LensConstants(Vector2 Center, float Radius, float Zoom, float RimRatio, float Fringe, float Presence, float Pad);
}
