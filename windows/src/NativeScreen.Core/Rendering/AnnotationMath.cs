using System.Numerics;

namespace NativeScreen.Core;

/// <summary>
/// The numbers the annotation passes and the canvas handles share (port of the geometry in `AnnotationRenderer.swift`), so a
/// handle always sits on what is drawn. Pixels are top-down (y grows downward) here, unlike the CoreGraphics source.
/// </summary>
public static class AnnotationMath
{
    /// <summary>Items shown at `sourceMs`, bottom layer first (the first track draws on top), keyframes resolved.</summary>
    public static List<AnnotationItem> Active(ProjectDocument document, double sourceMs, string? leaveOut = null)
    {
        var result = new List<AnnotationItem>();
        var tracks = document.Timeline.AnnotationTracks;
        for (var t = tracks.Count - 1; t >= 0; t--)
        {
            var track = tracks[t];
            if (track.IsHidden)
            {
                continue;
            }

            foreach (var item in track.Items)
            {
                if (!item.Disabled && sourceMs >= item.SourceStartMs && sourceMs <= item.SourceEndMs && item.Id != leaveOut)
                {
                    result.Add(item.Resolved(sourceMs));
                }
            }
        }

        return result;
    }

    /// <summary>Steps are numbered by when they start (then by layer, top first), skipping disabled ones and hidden tracks.</summary>
    public static Dictionary<string, int> StepNumbers(ProjectDocument document)
    {
        var steps = new List<(double Start, int Track, string Id)>();
        var tracks = document.Timeline.AnnotationTracks;
        for (var t = 0; t < tracks.Count; t++)
        {
            if (tracks[t].IsHidden)
            {
                continue;
            }

            foreach (var item in tracks[t].Items)
            {
                if (item.Kind == AnnotationKind.Step && !item.Disabled)
                {
                    steps.Add((item.SourceStartMs, t, item.Id));
                }
            }
        }

        steps.Sort((a, b) => a.Start != b.Start ? a.Start.CompareTo(b.Start) : a.Track.CompareTo(b.Track));
        var numbers = new Dictionary<string, int>();
        for (var i = 0; i < steps.Count; i++)
        {
            numbers[steps[i].Id] = i + 1;
        }

        return numbers;
    }

    public static double FontSize(AnnotationItem item, double canvasWidth, double canvasHeight) =>
        Math.Max(4, item.FontSizeRatio * Math.Max(1, Math.Min(canvasWidth, canvasHeight)));

    /// <summary>Padding of a text box: a plate gets room around the letters, plain text only a little.</summary>
    public static (double X, double Y) TextPadding(AnnotationItem item, double fontSize) =>
        item.TextBackground == AnnotationTextBackground.Solid ? (fontSize * 0.55, fontSize * 0.32) : (fontSize * 0.12, fontSize * 0.06);

    public static double TextCornerRadius(AnnotationItem item, double fontSize) =>
        item.TextBackground == AnnotationTextBackground.Solid ? fontSize * 0.42 : 0;

    /// <summary>Where lines wrap, inside the padding.</summary>
    public static double TextWrapWidth(AnnotationItem item, double fontSize, double canvasWidth) =>
        Math.Max(fontSize * 2, item.MaxWidthRatio * canvasWidth - TextPadding(item, fontSize).X * 2);

    public static double StepDiameter(AnnotationItem item, double canvasWidth, double canvasHeight) =>
        Math.Round(FontSize(item, canvasWidth, canvasHeight) * 1.75, MidpointRounding.AwayFromZero);

    public static double StrokeWidth(AnnotationItem item, double canvasWidth, double canvasHeight) =>
        Math.Max(1, item.StrokeRatio * Math.Min(canvasWidth, canvasHeight));

    /// <summary>`maxWidthRatio` of the frame wide at the picture's aspect; a missing picture is 16:9.</summary>
    public static (double Width, double Height) ImageSize(AnnotationItem item, double canvasWidth, int? pixelWidth, int? pixelHeight)
    {
        var width = Math.Round(Math.Max(8, item.MaxWidthRatio * canvasWidth), MidpointRounding.AwayFromZero);
        return pixelWidth is > 0 && pixelHeight is > 0
            ? (width, Math.Round(width * pixelHeight.Value / pixelWidth.Value, MidpointRounding.AwayFromZero))
            : (width, Math.Round(width * 9 / 16, MidpointRounding.AwayFromZero));
    }

    public readonly record struct Arrow(Vector2 Tail, Vector2 Control, Vector2 ShaftEnd, Vector2 Head, Vector2 HeadBaseLeft, Vector2 HeadBaseRight);

    /// <summary>
    /// A curved arrow between two top-down points. A positive bend pushes the middle to the left of the direction of travel as
    /// seen on screen.
    /// </summary>
    public static Arrow ArrowGeometry(Vector2 tail, Vector2 head, double bend, double strokeWidth)
    {
        var dx = head.X - tail.X;
        var dy = head.Y - tail.Y;
        var length = Math.Max(0.001, Math.Sqrt(dx * dx + dy * dy));
        // Left of travel with y down (the y-up formula mirrored).
        var normal = new Vector2((float)(dy / length), (float)(-dx / length));
        var offset = (float)(bend * length);
        var control = new Vector2((tail.X + head.X) * 0.5f + normal.X * offset, (tail.Y + head.Y) * 0.5f + normal.Y * offset);
        var tx = head.X - control.X;
        var ty = head.Y - control.Y;
        var tLength = Math.Max(0.001f, MathF.Sqrt(tx * tx + ty * ty));
        var dir = new Vector2(tx / tLength, ty / tLength);
        var headLength = (float)Math.Min(length * 0.45, Math.Max(strokeWidth * 3.6, 6));
        var headHalfWidth = headLength * 0.62f;
        var baseCenter = head - dir * headLength;
        var side = new Vector2(-dir.Y, dir.X);
        return new Arrow(tail, control, head - dir * headLength * 0.6f, head, baseCenter + side * headHalfWidth, baseCenter - side * headHalfWidth);
    }

    /// <summary>Length of the arrow's shaft, from 16 samples of the curve.</summary>
    public static double ShaftLength(Arrow g)
    {
        double total = 0;
        var last = g.Tail;
        for (var i = 1; i <= 16; i++)
        {
            var t = i / 16f;
            var u = 1 - t;
            var p = u * u * g.Tail + 2 * u * t * g.Control + t * t * g.ShaftEnd;
            total += Vector2.Distance(p, last);
            last = p;
        }

        return total;
    }

    /// <summary>Half the width and height of a shape in pixels, from where `point` puts its center and two edge midpoints.</summary>
    public static (double Width, double Height) ShapeHalfSize(AnnotationItem item, Func<Point01, Vector2> point)
    {
        var c = point(item.Position01);
        var right = point(new Point01(item.Position01.X + item.Size01.Width * 0.5, item.Position01.Y));
        var down = point(new Point01(item.Position01.X, item.Position01.Y + item.Size01.Height * 0.5));
        return (Vector2.Distance(right, c), Vector2.Distance(down, c));
    }

    /// <summary>Draw-on steps a line re-rasterizes in: 120, or one per 16 ms of a pen stroke's drawing time when finer.</summary>
    public static double DrawSteps(AnnotationItem item) =>
        item.Kind == AnnotationKind.Pen && item.PointTimesMs.Count > 0 ? Math.Max(120, Math.Ceiling(item.PointTimesMs[^1] / 16)) : 120;

    public static int PenHash(AnnotationItem item)
    {
        var hash = new HashCode();
        hash.Add(item.Highlighter);
        foreach (var start in item.StrokeStarts)
        {
            hash.Add(start);
        }

        foreach (var p in item.Points01)
        {
            hash.Add(p.X);
            hash.Add(p.Y);
        }

        return hash.ToHashCode();
    }

    /// <summary>
    /// The pen strokes in the item's local frame (center at the origin, y down, `halfWidth` and `halfHeight` to the box edges),
    /// up to `progress` of the drawing time (of the points when there are no times), the segment being drawn interpolated
    /// unless the pen was up before the next point.
    /// </summary>
    public static List<List<Vector2>> PenStrokes(AnnotationItem item, double halfWidth, double halfHeight, double progress)
    {
        var points = item.Points01;
        var local = new Vector2[points.Count];
        for (var i = 0; i < points.Count; i++)
        {
            local[i] = new Vector2((float)(-halfWidth + points[i].X * 2 * halfWidth), (float)(-halfHeight + points[i].Y * 2 * halfHeight));
        }

        var starts = new HashSet<int>(item.StrokeStarts);
        var count = local.Length;
        Vector2? tail = null;
        if (progress < 0.999 && local.Length > 1)
        {
            var times = item.PointTimesMs.Count == local.Length ? item.PointTimesMs : Enumerable.Range(0, local.Length).Select(i => (double)i).ToList();
            var cutoff = times[^1] * progress;
            var next = times.FindIndex(t => t > cutoff);
            if (next < 0)
            {
                next = local.Length;
            }

            count = Math.Max(1, next);
            if (next > 0 && next < local.Length && !starts.Contains(next))
            {
                var t0 = times[next - 1];
                var t1 = times[next];
                var f = (float)((cutoff - t0) / Math.Max(0.001, t1 - t0));
                tail = local[next - 1] + (local[next] - local[next - 1]) * f;
            }
        }

        var strokes = new List<List<Vector2>>();
        var strokeStart = 0;
        for (var i = 0; i < count; i++)
        {
            if (i != count - 1 && !starts.Contains(i + 1))
            {
                continue;
            }

            var stroke = new List<Vector2>(i - strokeStart + 2);
            for (var j = strokeStart; j <= i; j++)
            {
                stroke.Add(local[j]);
            }

            if (i == count - 1 && tail is { } end)
            {
                stroke.Add(end);
            }

            strokes.Add(stroke);
            strokeStart = i + 1;
        }

        return strokes;
    }

    /// <summary>Black or white (as sRGB 0...1), whichever reads better on `hex`.</summary>
    public static (float R, float G, float B) ContrastingTextColor(string hex)
    {
        var (r, g, b) = HexColor(hex);
        var luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        return luminance > 0.62 ? (0.07f, 0.07f, 0.09f) : (1f, 1f, 1f);
    }

    /// <summary>`#RRGGBB` as sRGB 0...1. Anything else reads as white.</summary>
    public static (float R, float G, float B) HexColor(string hex)
    {
        var cleaned = new string(hex.Where(char.IsAsciiLetterOrDigit).ToArray());
        if (cleaned.Length != 6 || !int.TryParse(cleaned, System.Globalization.NumberStyles.HexNumber, System.Globalization.CultureInfo.InvariantCulture, out var rgb))
        {
            return (1, 1, 1);
        }

        return (((rgb >> 16) & 0xFF) / 255f, ((rgb >> 8) & 0xFF) / 255f, (rgb & 0xFF) / 255f);
    }

    /// <summary>The first `count` text elements (user-perceived characters) of `text`, as a UTF-16 length.</summary>
    public static int Utf16LengthOfElements(string text, int count)
    {
        if (count <= 0)
        {
            return 0;
        }

        var enumerator = System.Globalization.StringInfo.GetTextElementEnumerator(text);
        var seen = 0;
        while (enumerator.MoveNext())
        {
            seen++;
            if (seen == count)
            {
                return enumerator.ElementIndex + ((string)enumerator.Current).Length;
            }
        }

        return text.Length;
    }

    public static int TextElementCount(string text) => new System.Globalization.StringInfo(text).LengthInTextElements;
}
