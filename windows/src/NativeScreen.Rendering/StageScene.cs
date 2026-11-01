using System.Globalization;
using System.Numerics;
using NativeScreen.Core;

namespace NativeScreen.Rendering;

public readonly record struct StageBox(Vector4 Rect, float Radius, float Softness, float RingWidth, Vector4 Color);

/// <summary>One frame of the stage: background, shadow, screen and camera placement in output pixels.</summary>
public sealed class StageScene
{
    public required Vector4 Color0 { get; init; }
    public required Vector4 Color1 { get; init; }
    public required Vector4 Color2 { get; init; }
    public required float RadialAmount { get; init; }
    public required IReadOnlyList<StageBox> Boxes { get; init; }

    public static StageScene Build(
        ProjectDocument document,
        double sourceMs,
        double canvasWidth,
        double canvasHeight,
        double sourceWidth,
        double sourceHeight,
        bool hasCamera)
    {
        var stage = new StageLayoutEngine().Resolve(document, sourceMs, canvasWidth, canvasHeight, sourceWidth, sourceHeight, 1, hasCamera);
        var boxes = new List<StageBox>();
        var frame = document.FrameStyle;
        var radius = (float)CompositeMetrics.ScreenCornerRadius(frame, canvasHeight);
        var screen = stage.ScreenRect;
        if (frame.Shadow.Enabled && frame.Shadow.Intensity > 0)
        {
            var shadow = CompositeMetrics.ScreenShadow(frame.Shadow, canvasHeight, radius);
            boxes.Add(new StageBox(
                new Vector4((float)(screen.X + shadow.OffsetX), (float)(screen.Y + shadow.OffsetY), (float)screen.Width, (float)screen.Height),
                (float)shadow.Radius,
                (float)Math.Max(1, shadow.Sigma * 2),
                0,
                new Vector4(0, 0, 0, (float)frame.Shadow.Intensity)));
        }

        var screenRect = new Vector4((float)screen.X, (float)screen.Y, (float)screen.Width, (float)screen.Height);
        boxes.Add(new StageBox(screenRect, radius, 1, 0, new Vector4(0.055f, 0.055f, 0.07f, 1)));
        if (frame.Inset.Enabled)
        {
            var color = Hex(frame.Inset.Color);
            color.W = (float)frame.Inset.Opacity;
            boxes.Add(new StageBox(screenRect, radius, 1, (float)Math.Max(1, frame.Inset.Size * CompositeMetrics.CanvasScale(canvasHeight)), color));
        }

        if (hasCamera && stage.Opacity > 0 && stage.CameraRect.Width > 0)
        {
            var camera = stage.CameraRect;
            boxes.Add(new StageBox(
                new Vector4((float)camera.X, (float)camera.Y, (float)camera.Width, (float)camera.Height),
                (float)stage.CornerRadius,
                1,
                0,
                new Vector4(0.2f, 0.2f, 0.24f, (float)stage.Opacity)));
        }

        var background = document.Background;
        switch (background.Type)
        {
            case BackgroundType.Solid:
                var solid = Hex(background.SolidColor);
                return new StageScene { Color0 = solid, Color1 = solid, Color2 = solid, RadialAmount = 0, Boxes = boxes };
            case BackgroundType.Gradient:
                var stops = background.Gradient.Stops;
                var first = Hex(stops.Count > 0 ? stops[0].Color : "#000000");
                var last = Hex(stops.Count > 0 ? stops[^1].Color : "#000000");
                return new StageScene { Color0 = first, Color1 = last, Color2 = last, RadialAmount = 0, Boxes = boxes };
            default:
                var mesh = MeshPreset.Find(background.MeshPresetId).ColorsHex;
                return new StageScene { Color0 = Hex(mesh[0]), Color1 = Hex(mesh[1]), Color2 = Hex(mesh[2]), RadialAmount = 1, Boxes = boxes };
        }
    }

    private static Vector4 Hex(string value)
    {
        var text = value.TrimStart('#');
        if (text.Length < 6 || !uint.TryParse(text[..6], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var rgb))
        {
            return new Vector4(0, 0, 0, 1);
        }

        return new Vector4(((rgb >> 16) & 255) / 255f, ((rgb >> 8) & 255) / 255f, (rgb & 255) / 255f, 1);
    }
}
