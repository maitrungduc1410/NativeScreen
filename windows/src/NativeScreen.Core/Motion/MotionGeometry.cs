namespace NativeScreen.Core;

/// <summary>Recording coordinates stay unchanged; only camera targets and drawn overlays enter crop space (spec/06 ADR-86).</summary>
public static class MotionGeometry
{
    /// <summary>A recording-normalized point in the crop's coordinates, not clamped: a point outside the crop stays outside.</summary>
    public static Point01 Cropped(Point01 point, Rect01 crop) =>
        new((point.X - crop.X) / Math.Max(0.0001, crop.Width), (point.Y - crop.Y) / Math.Max(0.0001, crop.Height));
}
