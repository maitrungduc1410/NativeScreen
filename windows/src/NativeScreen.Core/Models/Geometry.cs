using System.Text.Json.Serialization;

namespace NativeScreen.Core;

public sealed class Point01
{
    public double X { get; set; }
    public double Y { get; set; }

    public Point01()
    {
    }

    public Point01(double x, double y)
    {
        X = x;
        Y = y;
    }

    public static Point01 Center { get; } = new(0.5, 0.5);
    public static Point01 Zero { get; } = new(0, 0);
    public static Point01 One { get; } = new(1, 1);

    [JsonExtensionData]
    public Dictionary<string, System.Text.Json.JsonElement>? Extra { get; set; }
}

public sealed class Rect01
{
    public double X { get; set; }
    public double Y { get; set; }
    public double Width { get; set; }
    public double Height { get; set; }

    public Rect01()
    {
    }

    public Rect01(double x, double y, double width, double height)
    {
        X = x;
        Y = y;
        Width = width;
        Height = height;
    }

    public static Rect01 Full { get; } = new(0, 0, 1, 1);

    [JsonIgnore]
    public Point01 Center => new(X + Width * 0.5, Y + Height * 0.5);

    public Rect01 Clamped()
    {
        var cx = Math.Max(0, Math.Min(0.98, X));
        var cy = Math.Max(0, Math.Min(0.98, Y));
        var cw = Math.Max(0.02, Math.Min(1 - cx, Width));
        var ch = Math.Max(0.02, Math.Min(1 - cy, Height));
        return new Rect01(cx, cy, cw, ch);
    }

    [JsonExtensionData]
    public Dictionary<string, System.Text.Json.JsonElement>? Extra { get; set; }
}

public sealed class SpringConfig
{
    public double Stiffness { get; set; } = 170;
    public double Damping { get; set; } = 50;
    public double Mass { get; set; } = 3;

    public SpringConfig()
    {
    }

    public SpringConfig(double stiffness, double damping, double mass)
    {
        Stiffness = stiffness;
        Damping = damping;
        Mass = mass;
    }

    public static SpringConfig DefaultCursor { get; } = new(470, 70, 3);
    public static SpringConfig DefaultCamera { get; } = new(170, 50, 3);

    public SpringConfig Copy() => new(Stiffness, Damping, Mass);
}
