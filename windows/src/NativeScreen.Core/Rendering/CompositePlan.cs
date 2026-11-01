namespace NativeScreen.Core;

public enum CompositePassKind
{
    Background,
    Masks,
    Screen,
    Cursor,
    MotionBlur,
    Lens,
    Camera,
    Captions,
    Keycaps
}

public sealed class CompositePass
{
    public required CompositePassKind Kind { get; init; }
    public string Detail { get; init; } = "";
}

public readonly record struct ShadowPlacement(double OffsetX, double OffsetY, double Sigma, double Radius);

public readonly record struct ClickEffectPlacement(double Radius, double Alpha, double RingThickness);

public static class CompositeMetrics
{
    public static double CanvasScale(double outputHeight) => outputHeight / 900.0;

    public static double ScreenCornerRadius(FrameStyleConfig frame, double outputHeight)
    {
        var scale = CanvasScale(outputHeight);
        var radius = frame.DeviceMockup.Enabled
            ? (frame.DeviceMockup.DeviceId?.Contains("iphone", StringComparison.OrdinalIgnoreCase) == true ? 34.0 : 14.0)
            : frame.BorderRadius;
        return radius * scale;
    }

    public static ShadowPlacement ScreenShadow(FrameShadowConfig shadow, double outputHeight, double cornerRadius)
    {
        var scale = CanvasScale(outputHeight);
        var distance = shadow.Distance * scale;
        var radians = shadow.AngleDegrees * Math.PI / 180.0;
        double offsetX;
        double offsetY;
        if (shadow.IsDirectional)
        {
            offsetX = Math.Cos(radians) * distance * 0.55;
            offsetY = Math.Sin(radians) * distance * 0.55;
        }
        else
        {
            offsetX = 0;
            offsetY = 0.20 * distance;
        }

        return new ShadowPlacement(offsetX, offsetY, Math.Max(1, shadow.Blur * scale * 0.45), cornerRadius);
    }

    public static ClickEffectPlacement? Click(double? progress, double canvasScale, double cursorScale, double cursorOpacity)
    {
        if (progress is not double p)
        {
            return null;
        }

        var alpha = (1 - p) * 0.72 * cursorOpacity;
        return new ClickEffectPlacement(
            Math.Max(4, 46 * canvasScale * cursorScale * p),
            alpha,
            Math.Max(2.5, 6 * canvasScale * (1 - p * 0.5)));
    }

    public static int MotionBlurSampleCap(bool exportQuality) => exportQuality ? 24 : 8;

    public static double MotionBlurPixelsPerSample(bool exportQuality) => exportQuality ? 3 : 10;

    public static double KeycapHeight(double canvasHeight, double shortcutsSizeRatio) =>
        Math.Max(34, Math.Round(canvasHeight * shortcutsSizeRatio, MidpointRounding.AwayFromZero));

    public static double CaptionFontPx(double canvasHeight, double fontSizeRatio) =>
        Math.Max(14, canvasHeight * fontSizeRatio);
}

public static class CompositePlanBuilder
{
    public static IReadOnlyList<CompositePass> Build(
        ProjectDocument document,
        SpringTrajectorySolver.CameraFrameState camera,
        double sourceMs,
        bool exportQuality,
        bool isPlaying,
        double playheadTimelineMs,
        double timelineDurationMs)
    {
        var passes = new List<CompositePass>
        {
            new() { Kind = CompositePassKind.Background, Detail = document.Background.Type.ToString() },
            new() { Kind = CompositePassKind.Masks },
            new() { Kind = CompositePassKind.Screen },
            new() { Kind = CompositePassKind.Cursor }
        };

        var instant = document.Timeline.Zooms.Any(zoom =>
            !zoom.Disabled && zoom.InstantAnimation && sourceMs >= zoom.SourceStartMs && sourceMs <= zoom.SourceEndMs + 50);
        var pausedAtEnd = !exportQuality && !isPlaying && playheadTimelineMs >= timelineDurationMs - 16.7;
        if (!pausedAtEnd && !instant && !camera.IsLoupeMode && document.Motion.MotionBlurIntensity > 0.02 && sourceMs > 8)
        {
            passes.Add(new CompositePass
            {
                Kind = CompositePassKind.MotionBlur,
                Detail = $"samples={CompositeMetrics.MotionBlurSampleCap(exportQuality)}"
            });
        }

        if (camera.LoupePresence01 > 0.005 && camera.LoupeScale > 1.002)
        {
            passes.Add(new CompositePass { Kind = CompositePassKind.Lens });
        }

        passes.Add(new CompositePass { Kind = CompositePassKind.Camera });
        if (document.Captions.Enabled)
        {
            passes.Add(new CompositePass { Kind = CompositePassKind.Captions });
        }

        if (document.Captions.ShowKeystrokes)
        {
            passes.Add(new CompositePass { Kind = CompositePassKind.Keycaps });
        }

        return passes;
    }
}
