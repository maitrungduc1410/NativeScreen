namespace NativeScreen.Core;

public readonly record struct PixelRect(double X, double Y, double Width, double Height);

public sealed class StageFrame
{
    public double SourceMs { get; init; }
    public double CanvasWidth { get; init; }
    public double CanvasHeight { get; init; }
    public PixelRect ScreenRect { get; init; }
    public PixelRect CameraRect { get; init; }
    public double CornerRadius { get; init; }
    public double Opacity { get; init; }
    public double ShadowOpacity { get; init; }
    public double BorderOpacity { get; init; }
    public bool IsCutout { get; init; }
}

public sealed class StageLayoutEngine
{
    private const double TransitionMs = 380;

    private readonly record struct Size(double Width, double Height);
    private readonly record struct Rect(double X, double Y, double Width, double Height)
    {
        public double MidX => X + Width * 0.5;
        public double MidY => Y + Height * 0.5;
        public Rect Inset(double dx, double dy) => new(X + dx, Y + dy, Width - 2 * dx, Height - 2 * dy);
    }

    private sealed class CameraPlacement
    {
        public Rect Rect { get; set; }
        public double CornerRadius { get; set; }
        public double Opacity { get; set; }
        public double ShadowOpacity { get; set; }
        public double BorderOpacity { get; set; }
        public bool IsCutout { get; set; }
        public CameraConfig Config { get; set; } = new();
    }

    private sealed class Layout
    {
        public Rect Screen { get; set; }
        public CameraPlacement Camera { get; set; } = new();
    }

    private readonly record struct SplitGeo(Rect Screen, Rect Camera, Rect Zoom, bool HasPadding, double Pad);

    private readonly struct Key
    {
        public CameraConfig Config { get; init; }
        public bool Fullscreen { get; init; }
        public bool Visible { get; init; }

        public bool Same(Key other) =>
            Fullscreen == other.Fullscreen
            && Visible == other.Visible
            && Config.LayoutMode == other.Config.LayoutMode
            && Config.AspectRatioPreset == other.Config.AspectRatioPreset
            && Config.Position01.X == other.Config.Position01.X
            && Config.Position01.Y == other.Config.Position01.Y
            && Config.SizeRatio == other.Config.SizeRatio
            && Config.MakeSmallerDuringZoom == other.Config.MakeSmallerDuringZoom
            && Config.ScaleWhenZoomed == other.Config.ScaleWhenZoomed
            && Config.BorderRadiusRatio == other.Config.BorderRadiusRatio
            && Config.SplitScreenRatio01 == other.Config.SplitScreenRatio01
            && Config.SplitFlip == other.Config.SplitFlip
            && Config.SplitEnablePadding == other.Config.SplitEnablePadding
            && Config.CutoutPositionX01 == other.Config.CutoutPositionX01
            && Config.Shape == other.Config.Shape
            && Config.ShadowIntensity == other.Config.ShadowIntensity;
    }

    public StageFrame Resolve(
        ProjectDocument document,
        double sourceMs,
        double canvasWidth,
        double canvasHeight,
        double sourceWidth,
        double sourceHeight,
        double zoomScale,
        bool hasRecordedCamera,
        bool cameraHiddenBySilence = false)
    {
        var layout = Resolved(document, sourceMs, canvasWidth, canvasHeight, sourceWidth, sourceHeight, zoomScale, hasRecordedCamera, cameraHiddenBySilence);
        return new StageFrame
        {
            SourceMs = sourceMs,
            CanvasWidth = canvasWidth,
            CanvasHeight = canvasHeight,
            ScreenRect = TopLeft(layout.Screen, canvasHeight),
            CameraRect = TopLeft(layout.Camera.Rect, canvasHeight),
            CornerRadius = layout.Camera.CornerRadius,
            Opacity = layout.Camera.Opacity,
            ShadowOpacity = layout.Camera.ShadowOpacity,
            BorderOpacity = layout.Camera.BorderOpacity,
            IsCutout = layout.Camera.IsCutout
        };
    }

    public static bool IsCameraHiddenDuringSilence(ProjectDocument document, double sourceMs)
    {
        var minSilence = document.Camera.HideDuringSilenceMs;
        if (minSilence is not double silence || silence <= 100)
        {
            return false;
        }

        var segs = document.Captions.Segments.Where(seg => !seg.IsHidden).OrderBy(seg => seg.SourceStartMs).ToList();
        if (segs.Count >= 2)
        {
            for (var i = 0; i < segs.Count - 1; i++)
            {
                var gapStart = segs[i].SourceEndMs;
                var gapEnd = segs[i + 1].SourceStartMs;
                if (gapEnd - gapStart >= silence && sourceMs >= gapStart + 150 && sourceMs <= gapEnd - 150)
                {
                    return true;
                }
            }
        }

        return false;
    }

    public static CameraLayoutSegment? ActiveLayout(ProjectDocument document, double sourceMs)
    {
        if (document.Timeline.IsCameraLayoutsTrackHidden)
        {
            return null;
        }

        foreach (var segment in document.Timeline.CameraLayouts)
        {
            if (!segment.Disabled && sourceMs >= segment.SourceStartMs && sourceMs <= segment.SourceEndMs)
            {
                return segment;
            }
        }

        return null;
    }

    public static bool HiddenByVoiceover(ProjectDocument document, double sourceMs)
    {
        foreach (var voiceover in document.Timeline.Voiceovers)
        {
            if (!voiceover.Disabled && voiceover.HideRecording && !VoiceoverTrackLayout.IsTrackHidden(document.Timeline, voiceover.TrackIndex) && sourceMs >= voiceover.SourceStartMs && sourceMs <= voiceover.SourceEndMs)
            {
                return true;
            }
        }

        return false;
    }

    private static Layout Resolved(
        ProjectDocument document,
        double sourceMs,
        double canvasWidth,
        double canvasHeight,
        double sourceWidth,
        double sourceHeight,
        double zoomScale,
        bool hasRecordedCamera,
        bool cameraHiddenBySilence)
    {
        var now = StageKey(document, sourceMs, hasRecordedCamera, cameraHiddenBySilence);
        var current = Raw(now, document, canvasWidth, canvasHeight, sourceWidth, sourceHeight, zoomScale);
        var windowStart = sourceMs - TransitionMs;
        if (windowStart <= 0)
        {
            return current;
        }

        var before = StageKey(document, windowStart, hasRecordedCamera, cameraHiddenBySilence);
        if (before.Same(now))
        {
            return current;
        }

        var lo = windowStart;
        var hi = sourceMs;
        while (hi - lo > 1)
        {
            var mid = (lo + hi) * 0.5;
            if (StageKey(document, mid, hasRecordedCamera, cameraHiddenBySilence).Same(now))
            {
                hi = mid;
            }
            else
            {
                lo = mid;
            }
        }

        var previous = Raw(StageKey(document, lo, hasRecordedCamera, cameraHiddenBySilence), document, canvasWidth, canvasHeight, sourceWidth, sourceHeight, zoomScale);
        var progress = Ease((sourceMs - hi) / TransitionMs);
        return Blend(previous, current, progress);
    }

    private static Key StageKey(ProjectDocument document, double t, bool hasRecordedCamera, bool silenceOverride)
    {
        var segment = ActiveLayout(document, t);
        var screenOnly = segment?.LayoutType == CameraTimelineLayoutType.ScreenOnly;
        var silence = silenceOverride || IsCameraHiddenDuringSilence(document, t);
        var visible = document.Camera.Enabled && hasRecordedCamera && !screenOnly && !HiddenByVoiceover(document, t) && !silence;
        var config = Effective(document, segment);
        return new Key
        {
            Config = config,
            Fullscreen = segment?.LayoutType == CameraTimelineLayoutType.FullscreenCamera,
            Visible = visible
        };
    }

    private static CameraConfig Effective(ProjectDocument document, CameraLayoutSegment? segment)
    {
        var config = document.Camera;
        if (segment is null)
        {
            return config;
        }

        var copy = ProjectJson.Clone(config);
        switch (segment.LayoutType)
        {
            case CameraTimelineLayoutType.CameraOverlay:
                copy.LayoutMode = CameraLayoutMode.Overlay;
                if (segment.OverlayPosition01 is Point01 pos)
                {
                    copy.Position01 = pos;
                }
                break;
            case CameraTimelineLayoutType.SplitScreen:
                copy.LayoutMode = CameraLayoutMode.SplitScreen;
                break;
            case CameraTimelineLayoutType.CutoutCamera:
                copy.LayoutMode = CameraLayoutMode.Cutout;
                if (segment.CutoutPositionX01 is double x)
                {
                    copy.CutoutPositionX01 = x;
                }
                break;
        }

        return copy;
    }

    private static Layout Raw(
        Key key,
        ProjectDocument document,
        double canvasWidth,
        double canvasHeight,
        double sourceWidth,
        double sourceHeight,
        double zoomScale)
    {
        var config = key.Config;
        var split = Split(new Size(canvasWidth, canvasHeight), new Size(sourceWidth, sourceHeight), config, document.Canvas.PaddingRatio);
        var isSplit = key.Visible && !key.Fullscreen && config.LayoutMode == CameraLayoutMode.SplitScreen;
        Rect screen;
        if (isSplit)
        {
            screen = split.Screen;
        }
        else
        {
            var padding = document.FrameStyle.DeviceMockup.Enabled
                ? Math.Max(0.08, document.Canvas.PaddingRatio)
                : document.Canvas.PaddingRatio;
            screen = Fitted(new Size(sourceWidth, sourceHeight), new Rect(0, 0, canvasWidth, canvasHeight), padding);
        }

        var camera = Place(config, key.Fullscreen, split, zoomScale, new Rect(0, 0, canvasWidth, canvasHeight));
        if (!key.Visible)
        {
            camera.Opacity = 0;
            camera.Rect = camera.Rect.Inset(camera.Rect.Width * 0.03, camera.Rect.Height * 0.03);
        }

        return new Layout { Screen = screen, Camera = camera };
    }

    private static Rect Fitted(Size source, Rect canvas, double paddingRatio)
    {
        var ratio = Math.Min(0.45, Math.Max(0, paddingRatio));
        var shortest = Math.Min(canvas.Width, canvas.Height);
        var margin = (shortest - shortest / (1 + 2 * ratio)) * 0.5;
        var available = new Rect(canvas.X + margin, canvas.Y + margin, canvas.Width - margin * 2, canvas.Height - margin * 2);
        var aspect = Math.Max(0.1, source.Width / Math.Max(1, source.Height));
        var w = available.Width;
        var h = w / aspect;
        if (h > available.Height)
        {
            h = available.Height;
            w = h * aspect;
        }

        return new Rect(canvas.MidX - w * 0.5, canvas.MidY - h * 0.5, w, h);
    }

    private static SplitGeo Split(Size canvas, Size source, CameraConfig camera, double paddingRatio)
    {
        var hasPadding = camera.SplitEnablePadding && paddingRatio > 0.001;
        var ratio = hasPadding ? Math.Min(0.45, Math.Max(0, paddingRatio)) : 0;
        var shortest = Math.Min(canvas.Width, canvas.Height);
        var pad = (shortest - shortest / (1 + 2 * ratio)) * 0.5;
        var area = new Rect(pad, pad, Math.Max(64, canvas.Width - pad * 2), Math.Max(64, canvas.Height - pad * 2));
        var screenAspect = Math.Max(0.2, source.Width / Math.Max(1, source.Height));
        if (canvas.Width >= canvas.Height)
        {
            var availW = Math.Max(64, area.Width - pad);
            double cameraW;
            if (camera.SplitScreenRatio01 <= 0.01)
            {
                var natural = Math.Min(availW * 0.68, area.Height * screenAspect);
                var raw = availW - natural;
                cameraW = raw / Math.Max(1, area.Height) > 0.40
                    ? Math.Min(availW * 0.62, raw)
                    : Math.Min(availW * 0.50, area.Height * 0.50);
            }
            else
            {
                var screenShare = Math.Clamp(camera.SplitScreenRatio01, 0.25, 0.75);
                var raw = availW * (1 - screenShare);
                cameraW = raw / Math.Max(1, area.Height) > 0.40 ? raw : Math.Min(availW * 0.50, area.Height * 0.50);
            }

            var zoomW = Math.Max(64, availW - cameraW);
            Rect zoom;
            Rect cam;
            if (camera.SplitFlip)
            {
                cam = new Rect(area.X, area.Y, cameraW, area.Height);
                zoom = new Rect(area.X + area.Width - zoomW, area.Y, zoomW, area.Height);
            }
            else
            {
                zoom = new Rect(area.X, area.Y, zoomW, area.Height);
                cam = new Rect(area.X + area.Width - cameraW, area.Y, cameraW, area.Height);
            }

            var maxH = hasPadding ? zoom.Height * 0.90 : zoom.Height;
            var sw = zoom.Width;
            var sh = sw / screenAspect;
            if (sh > maxH)
            {
                sh = maxH;
                sw = sh * screenAspect;
            }

            var screen = new Rect(zoom.MidX - sw * 0.5, zoom.MidY - sh * 0.5, sw, sh);
            return new SplitGeo(screen, cam, zoom, hasPadding, pad);
        }

        var availH = Math.Max(64, area.Height - pad);
        var share = camera.SplitScreenRatio01 <= 0.01 ? 0.50 : Math.Clamp(camera.SplitScreenRatio01, 0.25, 0.75);
        var cameraH = availH * (1 - share);
        var zoomH = Math.Max(64, availH - cameraH);
        Rect zoomV;
        Rect camV;
        if (camera.SplitFlip)
        {
            camV = new Rect(area.X, area.Y, area.Width, cameraH);
            zoomV = new Rect(area.X, area.Y + area.Height - zoomH, area.Width, zoomH);
        }
        else
        {
            zoomV = new Rect(area.X, area.Y, area.Width, zoomH);
            camV = new Rect(area.X, area.Y + area.Height - cameraH, area.Width, cameraH);
        }

        var maxW = hasPadding ? zoomV.Width * 0.90 : zoomV.Width;
        var shV = zoomV.Height;
        var swV = shV * screenAspect;
        if (swV > maxW)
        {
            swV = maxW;
            shV = swV / screenAspect;
        }

        return new SplitGeo(new Rect(zoomV.MidX - swV * 0.5, zoomV.MidY - shV * 0.5, swV, shV), camV, zoomV, hasPadding, pad);
    }

    private static CameraPlacement Place(CameraConfig config, bool fullscreen, SplitGeo split, double zoomScale, Rect canvas)
    {
        var zoomProgress = Math.Clamp((zoomScale - 1) / 0.8, 0, 1);
        var zoomMultiplier = config.MakeSmallerDuringZoom ? 1 - (1 - config.ScaleWhenZoomed) * zoomProgress : 1;
        var aspect = config.AspectValue;
        var baseRef = Math.Min(canvas.Width, canvas.Height);
        var overlayH = Math.Max(64, baseRef * config.SizeRatio * 0.58 * zoomMultiplier);
        var overlayW = Math.Max(64, overlayH * aspect);
        var splitSide = Math.Max(84, baseRef * 0.34);
        double pipW;
        double pipH;
        if (fullscreen)
        {
            pipW = canvas.Width;
            pipH = canvas.Height;
        }
        else if (config.LayoutMode == CameraLayoutMode.SplitScreen)
        {
            pipW = split.Camera.Width + (splitSide - split.Camera.Width) * zoomProgress;
            pipH = split.Camera.Height + (splitSide - split.Camera.Height) * zoomProgress;
        }
        else
        {
            pipW = overlayW;
            pipH = overlayH;
        }

        var margin = Math.Max(16, baseRef * 0.035);
        var availW = Math.Max(1, canvas.Width - pipW - margin * 2);
        var availH = Math.Max(1, canvas.Height - pipH - margin * 2);
        double originX;
        double originY;
        if (fullscreen)
        {
            originX = 0;
            originY = 0;
        }
        else if (config.LayoutMode == CameraLayoutMode.Overlay)
        {
            originX = margin + Math.Clamp(config.Position01.X, 0, 1) * availW;
            originY = margin + (1 - Math.Clamp(config.Position01.Y, 0, 1)) * availH;
        }
        else if (config.LayoutMode == CameraLayoutMode.Cutout)
        {
            originX = margin + Math.Clamp(config.CutoutPositionX01, 0, 1) * availW;
            originY = -pipH * 0.04;
        }
        else
        {
            var zoomedX = config.SplitFlip ? margin : canvas.Width - margin - pipW;
            originX = split.Camera.X + (zoomedX - split.Camera.X) * zoomProgress;
            originY = split.Camera.Y + (margin - split.Camera.Y) * zoomProgress;
        }

        var baseRadius = Math.Min(pipW, pipH) * Math.Clamp(config.BorderRadiusRatio, 0, 0.50);
        double radius;
        if (fullscreen)
        {
            radius = 0;
        }
        else if (config.LayoutMode == CameraLayoutMode.Cutout)
        {
            radius = pipW * 0.36;
        }
        else if (config.LayoutMode == CameraLayoutMode.SplitScreen)
        {
            radius = split.HasPadding ? baseRadius : baseRadius * zoomProgress;
        }
        else
        {
            radius = baseRadius;
        }

        var edge = fullscreen || (config.LayoutMode == CameraLayoutMode.SplitScreen && !split.HasPadding && zoomProgress < 0.02);
        var cutout = !fullscreen && config.LayoutMode == CameraLayoutMode.Cutout;
        return new CameraPlacement
        {
            Rect = new Rect(originX, originY, pipW, pipH),
            CornerRadius = radius,
            Opacity = 1,
            ShadowOpacity = edge ? 0 : cutout ? 0.35 : 0.45,
            BorderOpacity = edge || cutout ? 0 : 0.14,
            IsCutout = cutout,
            Config = config
        };
    }

    private static Layout Blend(Layout a, Layout b, double t) => new()
    {
        Screen = Lerp(a.Screen, b.Screen, t),
        Camera = new CameraPlacement
        {
            Rect = Lerp(a.Camera.Rect, b.Camera.Rect, t),
            CornerRadius = Lerp(a.Camera.CornerRadius, b.Camera.CornerRadius, t),
            Opacity = Lerp(a.Camera.Opacity, b.Camera.Opacity, t),
            ShadowOpacity = Lerp(a.Camera.ShadowOpacity, b.Camera.ShadowOpacity, t),
            BorderOpacity = Lerp(a.Camera.BorderOpacity, b.Camera.BorderOpacity, t),
            IsCutout = t < 0.5 ? a.Camera.IsCutout : b.Camera.IsCutout,
            Config = b.Camera.Config
        }
    };

    private static double Ease(double t)
    {
        var x = Math.Clamp(t, 0, 1);
        return x * x * (3 - 2 * x);
    }

    private static double Lerp(double a, double b, double t) => a + (b - a) * t;

    private static Rect Lerp(Rect a, Rect b, double t) =>
        new(Lerp(a.X, b.X, t), Lerp(a.Y, b.Y, t), Lerp(a.Width, b.Width, t), Lerp(a.Height, b.Height, t));

    private static PixelRect TopLeft(Rect rect, double canvasHeight) =>
        new(rect.X, canvasHeight - rect.Y - rect.Height, rect.Width, rect.Height);
}
