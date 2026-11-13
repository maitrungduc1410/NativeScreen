namespace NativeScreen.Core;

/// <summary>
/// Size of the capture in points (logical pixels). Cursor tolerances, shake filtering and rotation use points, so a
/// high-DPI recording behaves like the same motion on a standard display (spec/06 ADR-87).
/// </summary>
public readonly record struct MotionPointSize
{
    public double Width { get; }
    public double Height { get; }

    public MotionPointSize(double width, double height)
    {
        Width = Math.Max(1, width);
        Height = Math.Max(1, height);
    }

    public static MotionPointSize Reference { get; } = new(1600, 900);

    public static MotionPointSize Of(CaptureTargetMetadata target)
    {
        var scale = Math.Max(1, target.ScaleFactor);
        var width = target.LogicalBounds.Width > 0 ? target.LogicalBounds.Width : target.PixelSize.Width / scale;
        var height = target.LogicalBounds.Height > 0 ? target.LogicalBounds.Height : target.PixelSize.Height / scale;
        return new MotionPointSize(width, height);
    }

    public double Distance(Point01 a, Point01 b) => Distance(a.X, a.Y, b.X, b.Y);

    public double Distance(double ax, double ay, double bx, double by)
    {
        var dx = (ax - bx) * Width;
        var dy = (ay - by) * Height;
        return Math.Sqrt(dx * dx + dy * dy);
    }
}
