using System.Text.Json;
using System.Text.Json.Serialization;

namespace NativeScreen.Core;

// Annotations (`timeline.annotationTracks`), ported from `Models/Annotation.swift` (spec/02, spec/06 ADR-75).

public enum AnnotationKind
{
    [JsonStringEnumMemberName("text")] Text,
    [JsonStringEnumMemberName("arrow")] Arrow,
    [JsonStringEnumMemberName("rectangle")] Rectangle,
    [JsonStringEnumMemberName("ellipse")] Ellipse,
    /// <summary>A numbered badge, numbered 1, 2, 3... in the order they appear.</summary>
    [JsonStringEnumMemberName("step")] Step,
    /// <summary>A picture copied into the package (`imagePath`), `maxWidthRatio` of the frame wide.</summary>
    [JsonStringEnumMemberName("image")] Image,
    /// <summary>A freehand stroke (`points01` inside its `size01` box), usually drawn live while recording.</summary>
    [JsonStringEnumMemberName("pen")] Pen
}

public enum AnnotationAnchor
{
    [JsonStringEnumMemberName("screen")] Screen,
    [JsonStringEnumMemberName("canvas")] Canvas
}

public enum AnnotationAnimation
{
    [JsonStringEnumMemberName("none")] None,
    [JsonStringEnumMemberName("fade")] Fade,
    [JsonStringEnumMemberName("pop")] Pop,
    [JsonStringEnumMemberName("rise")] Rise,
    [JsonStringEnumMemberName("draw")] Draw,
    [JsonStringEnumMemberName("slide")] Slide,
    [JsonStringEnumMemberName("typewriter")] Typewriter
}

public enum AnnotationTextBackground
{
    [JsonStringEnumMemberName("none")] None,
    [JsonStringEnumMemberName("solid")] Solid
}

public static class AnnotationKinds
{
    /// <summary>Kinds sized by `size01` that zoom with the recording.</summary>
    public static bool IsShape(this AnnotationKind kind) => kind is AnnotationKind.Rectangle or AnnotationKind.Ellipse or AnnotationKind.Pen;

    /// <summary>Kinds the Add annotation menu offers. A pen stroke only comes from drawing.</summary>
    public static bool IsAddable(this AnnotationKind kind) => kind != AnnotationKind.Pen;

    public static bool SupportsDrawOn(this AnnotationKind kind) => kind == AnnotationKind.Arrow || kind.IsShape();

    public static bool CanRotate(this AnnotationKind kind) => kind != AnnotationKind.Arrow;

    public static string Title(this AnnotationKind kind) => kind switch
    {
        AnnotationKind.Text => "Text",
        AnnotationKind.Arrow => "Arrow",
        AnnotationKind.Rectangle => "Rectangle",
        AnnotationKind.Ellipse => "Ellipse",
        AnnotationKind.Step => "Step",
        AnnotationKind.Image => "Image",
        _ => "Drawing"
    };

    public static string Title(this AnnotationAnimation animation) => animation switch
    {
        AnnotationAnimation.None => "None",
        AnnotationAnimation.Fade => "Fade",
        AnnotationAnimation.Pop => "Pop",
        AnnotationAnimation.Rise => "Rise",
        AnnotationAnimation.Draw => "Draw",
        AnnotationAnimation.Slide => "Slide",
        _ => "Typewriter"
    };

    public static bool IsOffered(this AnnotationAnimation animation, AnnotationKind kind) => animation switch
    {
        AnnotationAnimation.Draw => kind.SupportsDrawOn(),
        AnnotationAnimation.Typewriter => kind == AnnotationKind.Text,
        _ => true
    };
}

public sealed class Size01
{
    public double Width { get; set; }
    public double Height { get; set; }

    public Size01()
    {
    }

    public Size01(double width, double height)
    {
        Width = width;
        Height = height;
    }

    public Size01 Copy() => new(Width, Height);
}

/// <summary>Where an item is at one moment. Between keyframes the geometry eases from one to the next.</summary>
public sealed class AnnotationKeyframe
{
    public double SourceMs { get; set; }
    public Point01 Position01 { get; set; } = Point01.Center;
    public Point01 From01 { get; set; } = new(0.4, 0.6);
    public Point01 To01 { get; set; } = Point01.Center;
    public Size01 Size01 { get; set; } = new(0.22, 0.12);
    public double RotationDegrees { get; set; }
}

/// <summary>How an item looks at one moment of its enter and exit animations.</summary>
public struct AnnotationAnimationState
{
    public AnnotationAnimationState()
    {
    }

    public double Opacity { get; set; } = 1;
    public double Scale { get; set; } = 1;
    /// <summary>Downward offset as a share of the output frame's shorter side.</summary>
    public double OffsetY { get; set; }
    /// <summary>Share of the line drawn, 0...1.</summary>
    public double DrawProgress { get; set; } = 1;
    /// <summary>Rightward offset as a share of the output frame's shorter side.</summary>
    public double OffsetX { get; set; }
    /// <summary>Share of a text's characters shown, 0...1.</summary>
    public double Reveal { get; set; } = 1;

    public static AnnotationAnimationState Rest => new();
}

/// <summary>
/// One annotation on a track. Every kind keeps every field, so changing the kind or patching one field never loses the rest.
/// Sizes are shares of the output frame, never of the zoomed recording: a zoom moves an annotation but does not enlarge it.
/// </summary>
public sealed class AnnotationItem : IJsonOnDeserialized
{
    public const string DefaultArrowColor = "#FF5A36";
    public const string DefaultTextColor = "#FFFFFF";
    public const string DefaultTextBackgroundColor = "#16161D";
    public const double MinDurationMs = 220;

    public const double FontSizeMin = 0.015, FontSizeMax = 0.2;
    public const double MaxWidthMin = 0.1, MaxWidthMax = 1.0;
    public const double StrokeMin = 0.002, StrokeMax = 0.03;
    public const double BendMin = -0.8, BendMax = 0.8;
    public const double AnimationMin = 0, AnimationMax = 1500;
    public const double SizeMin = 0.01, SizeMax = 1.5;
    public const double CornerMin = 0, CornerMax = 0.1;

    private string? color;

    public string Id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    public double SourceStartMs { get; set; }
    public double SourceEndMs { get; set; }
    public AnnotationKind Kind { get; set; } = AnnotationKind.Text;
    public AnnotationAnchor Anchor { get; set; } = AnnotationAnchor.Screen;

    public string Text { get; set; } = "";
    public Point01 Position01 { get; set; } = Point01.Center;
    public double FontSizeRatio { get; set; } = 0.042;
    public double MaxWidthRatio { get; set; } = 0.5;
    public bool Bold { get; set; } = true;
    public AnnotationTextBackground TextBackground { get; set; } = AnnotationTextBackground.Solid;
    public string BackgroundColor { get; set; } = DefaultTextBackgroundColor;

    public Point01 From01 { get; set; } = new(0.4, 0.6);
    public Point01 To01 { get; set; } = Point01.Center;
    public double Bend { get; set; } = 0.18;
    public double StrokeRatio { get; set; } = 0.007;

    public Size01 Size01 { get; set; } = new(0.22, 0.12);
    public double RotationDegrees { get; set; }
    public double FillOpacity { get; set; }
    public double CornerRatio { get; set; } = 0.012;

    public string ImagePath { get; set; } = "";
    public List<AnnotationKeyframe> Keyframes { get; set; } = [];

    public List<Point01> Points01 { get; set; } = [];
    public List<double> PointTimesMs { get; set; } = [];
    public bool Highlighter { get; set; }
    public List<int> StrokeStarts { get; set; } = [];

    /// <summary>Text color for text, line color for an arrow or shape, badge color for a step, as `#RRGGBB`.</summary>
    public string Color
    {
        get => color ?? DefaultColor(Kind);
        set => color = value;
    }

    public AnnotationAnimation Enter { get; set; } = AnnotationAnimation.Fade;
    public AnnotationAnimation Exit { get; set; } = AnnotationAnimation.Fade;
    public double AnimationMs { get; set; } = 250;
    public bool Disabled { get; set; }

    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Extra { get; set; }

    public static string DefaultColor(AnnotationKind kind) => kind == AnnotationKind.Text ? DefaultTextColor : DefaultArrowColor;

    public static double ClampedFontSize(double v) => Math.Clamp(v, FontSizeMin, FontSizeMax);
    public static double ClampedMaxWidth(double v) => Math.Clamp(v, MaxWidthMin, MaxWidthMax);
    public static double ClampedStroke(double v) => Math.Clamp(v, StrokeMin, StrokeMax);
    public static double ClampedBend(double v) => Math.Clamp(v, BendMin, BendMax);
    public static double ClampedAnimation(double v) => Math.Clamp(v, AnimationMin, AnimationMax);
    public static double ClampedSize(double v) => Math.Clamp(v, SizeMin, SizeMax);
    public static double ClampedCorner(double v) => Math.Clamp(v, CornerMin, CornerMax);

    /// <summary>-180 &lt; degrees &lt;= 180.</summary>
    public static double NormalizedRotation(double v)
    {
        if (!double.IsFinite(v))
        {
            return 0;
        }

        var d = v % 360;
        if (d > 180)
        {
            d -= 360;
        }

        if (d <= -180)
        {
            d += 360;
        }

        return d;
    }

    void IJsonOnDeserialized.OnDeserialized()
    {
        FontSizeRatio = ClampedFontSize(FontSizeRatio);
        MaxWidthRatio = ClampedMaxWidth(MaxWidthRatio);
        Bend = ClampedBend(Bend);
        StrokeRatio = ClampedStroke(StrokeRatio);
        Size01 = new Size01(ClampedSize(Size01.Width), ClampedSize(Size01.Height));
        RotationDegrees = NormalizedRotation(RotationDegrees);
        FillOpacity = Math.Clamp(FillOpacity, 0, 1);
        CornerRatio = ClampedCorner(CornerRatio);
        AnimationMs = ClampedAnimation(AnimationMs);
        Keyframes.Sort((a, b) => a.SourceMs.CompareTo(b.SourceMs));
        // Times are only used when there is one per point.
        if (PointTimesMs.Count != Points01.Count)
        {
            PointTimesMs = [];
        }

        var count = Points01.Count;
        StrokeStarts = StrokeStarts.Where(index => index > 0 && index < count).Order().ToList();
    }

    public AnnotationItem Copy() => ProjectJson.Clone(this);

    /// <summary>The enter and exit animations at `sourceMs`. Each lasts `animationMs`, capped at half the item.</summary>
    public AnnotationAnimationState AnimationState(double sourceMs)
    {
        var duration = Math.Max(1, SourceEndMs - SourceStartMs);
        var span = Math.Min(AnimationMs, duration * 0.5);
        var state = AnnotationAnimationState.Rest;
        if (span <= 0.5)
        {
            return state;
        }

        static double Smooth(double t) => t * t * (3 - 2 * t);
        static double EaseOutCubic(double t) => 1 - Math.Pow(1 - t, 3);
        static double EaseOutBack(double t)
        {
            const double c1 = 1.70158, c3 = c1 + 1;
            return 1 + c3 * Math.Pow(t - 1, 3) + c1 * Math.Pow(t - 1, 2);
        }

        void Apply(AnnotationAnimation animation, double p, bool entering)
        {
            if (p >= 1)
            {
                return;
            }

            switch (animation)
            {
                case AnnotationAnimation.None:
                    return;
                case AnnotationAnimation.Fade:
                    state.Opacity *= Smooth(p);
                    break;
                case AnnotationAnimation.Pop:
                    state.Opacity *= Smooth(Math.Min(1, p * 1.6));
                    state.Scale *= 0.6 + 0.4 * (entering ? EaseOutBack(p) : Smooth(p));
                    break;
                case AnnotationAnimation.Rise:
                    state.Opacity *= Smooth(p);
                    state.OffsetY += (entering ? 1 : -1) * 0.035 * (1 - EaseOutCubic(p));
                    break;
                case AnnotationAnimation.Draw:
                    if (Kind == AnnotationKind.Pen && entering && PointTimesMs.Count > 0 && PointTimesMs[^1] > 1)
                    {
                        // A drawn stroke replays at the speed it was drawn, whatever the animation length.
                        state.DrawProgress = Math.Min(state.DrawProgress, Math.Clamp((sourceMs - SourceStartMs) / PointTimesMs[^1], 0, 1));
                    }
                    else if (Kind.SupportsDrawOn())
                    {
                        state.DrawProgress = Math.Min(state.DrawProgress, Smooth(p));
                    }
                    else
                    {
                        state.Opacity *= Smooth(p);
                    }

                    break;
                case AnnotationAnimation.Slide:
                    state.Opacity *= Smooth(p);
                    state.OffsetX += (entering ? -1 : 1) * 0.06 * (1 - EaseOutCubic(p));
                    break;
                case AnnotationAnimation.Typewriter:
                    if (Kind == AnnotationKind.Text)
                    {
                        state.Reveal = Math.Min(state.Reveal, p);
                    }
                    else
                    {
                        state.Opacity *= Smooth(p);
                    }

                    break;
            }
        }

        if (Enter == AnnotationAnimation.Draw && Kind == AnnotationKind.Pen && PointTimesMs.Count > 0)
        {
            Apply(Enter, 0, true);
        }
        else
        {
            Apply(Enter, Math.Clamp((sourceMs - SourceStartMs) / span, 0, 1), true);
        }

        Apply(Exit, Math.Clamp((SourceEndMs - sourceMs) / span, 0, 1), false);
        return state;
    }

    /// <summary>This item's geometry as a keyframe at `sourceMs`.</summary>
    public AnnotationKeyframe KeyframeAt(double sourceMs) => new()
    {
        SourceMs = sourceMs,
        Position01 = new Point01(Position01.X, Position01.Y),
        From01 = new Point01(From01.X, From01.Y),
        To01 = new Point01(To01.X, To01.Y),
        Size01 = Size01.Copy(),
        RotationDegrees = RotationDegrees
    };

    public void ApplyGeometry(AnnotationKeyframe k)
    {
        Position01 = new Point01(k.Position01.X, k.Position01.Y);
        From01 = new Point01(k.From01.X, k.From01.Y);
        To01 = new Point01(k.To01.X, k.To01.Y);
        Size01 = k.Size01.Copy();
        RotationDegrees = k.RotationDegrees;
    }

    /// <summary>
    /// The item with its geometry at `sourceMs`: holds before the first keyframe and after the last, eases (smoothstep)
    /// between two, rotation the shorter way round. Returns this item when it has no keyframes.
    /// </summary>
    public AnnotationItem Resolved(double sourceMs)
    {
        if (Keyframes.Count == 0)
        {
            return this;
        }

        var item = (AnnotationItem)MemberwiseClone();
        var first = Keyframes[0];
        var last = Keyframes[^1];
        if (Keyframes.Count == 1 || sourceMs <= first.SourceMs)
        {
            item.ApplyGeometry(first);
            return item;
        }

        if (sourceMs >= last.SourceMs)
        {
            item.ApplyGeometry(last);
            return item;
        }

        var i = Math.Max(0, Keyframes.FindLastIndex(k => k.SourceMs <= sourceMs));
        var a = Keyframes[i];
        var b = Keyframes[Math.Min(i + 1, Keyframes.Count - 1)];
        var raw = (sourceMs - a.SourceMs) / Math.Max(0.001, b.SourceMs - a.SourceMs);
        var t = raw * raw * (3 - 2 * raw);
        double Mix(double x, double y) => x + (y - x) * t;
        Point01 MixPoint(Point01 p, Point01 q) => new(Mix(p.X, q.X), Mix(p.Y, q.Y));
        var turn = NormalizedRotation(b.RotationDegrees - a.RotationDegrees);
        item.ApplyGeometry(new AnnotationKeyframe
        {
            SourceMs = sourceMs,
            Position01 = MixPoint(a.Position01, b.Position01),
            From01 = MixPoint(a.From01, b.From01),
            To01 = MixPoint(a.To01, b.To01),
            Size01 = new Size01(Mix(a.Size01.Width, b.Size01.Width), Mix(a.Size01.Height, b.Size01.Height)),
            RotationDegrees = NormalizedRotation(a.RotationDegrees + turn * t)
        });
        return item;
    }

    /// <summary>Keyframes stay with the item when it moves in time.</summary>
    public void ShiftTime(double delta)
    {
        SourceStartMs += delta;
        SourceEndMs += delta;
        foreach (var keyframe in Keyframes)
        {
            keyframe.SourceMs += delta;
        }
    }

    /// <summary>Short label for the timeline (English; the caller translates the kind title).</summary>
    [JsonIgnore]
    public string DisplayTitle => Kind == AnnotationKind.Text && Text.Trim() is { Length: > 0 } trimmed ? trimmed : Kind.Title();
}

public sealed class AnnotationTrack
{
    /// <summary>Neighbors on a track may touch by this much: drags, layer moves and duplicates allow it.</summary>
    public const double OverlapToleranceMs = 20;

    public string Id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    public string Name { get; set; } = "Annotations";
    public bool IsHidden { get; set; }
    public List<AnnotationItem> Items { get; set; } = [];

    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Extra { get; set; }

    public static string DefaultName(int index) => index == 0 ? "Annotations" : $"Annotations {index + 1}";

    /// <summary>Whether two items on this track overlap in time by more than the tolerance (a track must not).</summary>
    [JsonIgnore]
    public bool HasOverlaps
    {
        get
        {
            var sorted = Items.OrderBy(item => item.SourceStartMs).ToList();
            for (var i = 1; i < sorted.Count; i++)
            {
                if (sorted[i].SourceStartMs < sorted[i - 1].SourceEndMs - OverlapToleranceMs)
                {
                    return true;
                }
            }

            return false;
        }
    }

    /// <summary>
    /// `items` on as few tracks as possible with no overlap on any: in start order, each item goes on the first track whose
    /// last item has ended, or on a new one. The first track keeps `id` and `name`; the others are `name 2`, `name 3`...
    /// </summary>
    public static List<AnnotationTrack> Packed(IEnumerable<AnnotationItem> items, string? id, string name, bool isHidden = false)
    {
        var tracks = new List<AnnotationTrack>();
        var ends = new List<double>();
        foreach (var item in items.OrderBy(item => item.SourceStartMs).ThenBy(item => item.SourceEndMs))
        {
            var index = ends.FindIndex(end => end - OverlapToleranceMs <= item.SourceStartMs);
            if (index >= 0)
            {
                tracks[index].Items.Add(item);
                ends[index] = item.SourceEndMs;
            }
            else
            {
                var n = tracks.Count;
                var track = new AnnotationTrack { Name = n == 0 ? name : $"{name} {n + 1}", IsHidden = isHidden, Items = [item] };
                if (n == 0 && id is not null)
                {
                    track.Id = id;
                }

                tracks.Add(track);
                ends.Add(item.SourceEndMs);
            }
        }

        return tracks;
    }

    /// <summary>
    /// Splits every track whose items overlap by more than the tolerance into packed tracks, in place, keeping the first's id,
    /// name and position (spec/02). True when anything changed.
    /// </summary>
    public static bool RepackOverlapping(List<AnnotationTrack> tracks)
    {
        var changed = false;
        for (var i = 0; i < tracks.Count; i++)
        {
            var track = tracks[i];
            if (!track.HasOverlaps)
            {
                continue;
            }

            var packed = Packed(track.Items, track.Id, track.Name, track.IsHidden);
            packed[0].Extra = track.Extra;
            tracks.RemoveAt(i);
            tracks.InsertRange(i, packed);
            i += packed.Count - 1;
            changed = true;
        }

        return changed;
    }
}

/// <summary>
/// A look that can be applied to any annotation. `AccentColor` is the line, shape and step color and a text's plate;
/// `TextColor` is a text's letters.
/// </summary>
public sealed class AnnotationStyle
{
    public string Id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    public string Name { get; set; } = "";
    public string AccentColor { get; set; } = AnnotationItem.DefaultArrowColor;
    public string TextColor { get; set; } = AnnotationItem.DefaultTextColor;
    public AnnotationTextBackground TextBackground { get; set; } = AnnotationTextBackground.Solid;
    public bool Bold { get; set; } = true;
    public double StrokeRatio { get; set; } = 0.007;
    public double FillOpacity { get; set; }
    public double CornerRatio { get; set; } = 0.012;
    public AnnotationAnimation Enter { get; set; } = AnnotationAnimation.Fade;
    public AnnotationAnimation Exit { get; set; } = AnnotationAnimation.Fade;
    public double AnimationMs { get; set; } = 250;

    /// <summary>The look of `item`, to save as a style.</summary>
    public static AnnotationStyle From(string name, AnnotationItem item) => new()
    {
        Name = name,
        AccentColor = item.Kind == AnnotationKind.Text ? item.BackgroundColor : item.Color,
        TextColor = item.Kind == AnnotationKind.Text ? item.Color : AnnotationItem.DefaultTextColor,
        TextBackground = item.TextBackground,
        Bold = item.Bold,
        StrokeRatio = item.StrokeRatio,
        FillOpacity = item.FillOpacity,
        CornerRatio = item.CornerRatio,
        Enter = item.Enter,
        Exit = item.Exit,
        AnimationMs = item.AnimationMs
    };

    /// <summary>Sets the look and keeps what the item is and where it is. An animation the kind cannot play is left as it was.</summary>
    public void ApplyTo(AnnotationItem item)
    {
        if (item.Kind == AnnotationKind.Text)
        {
            item.Color = TextColor;
            item.BackgroundColor = AccentColor;
            item.TextBackground = TextBackground;
            item.Bold = Bold;
        }
        else
        {
            item.Color = AccentColor;
        }

        item.StrokeRatio = AnnotationItem.ClampedStroke(StrokeRatio);
        item.FillOpacity = Math.Clamp(FillOpacity, 0, 1);
        item.CornerRatio = AnnotationItem.ClampedCorner(CornerRatio);
        if (Enter.IsOffered(item.Kind))
        {
            item.Enter = Enter;
        }

        if (Exit.IsOffered(item.Kind))
        {
            item.Exit = Exit;
        }

        item.AnimationMs = AnnotationItem.ClampedAnimation(AnimationMs);
    }

    public static IReadOnlyList<AnnotationStyle> BuiltIn { get; } =
    [
        new() { Id = "builtin.coral", Name = "Coral", AccentColor = "#FF5A36", TextColor = "#FFFFFF" },
        new() { Id = "builtin.highlighter", Name = "Highlighter", AccentColor = "#FFD60A", TextColor = "#16161D", StrokeRatio = 0.01, FillOpacity = 0.18, CornerRatio = 0.008 },
        new() { Id = "builtin.clean", Name = "Clean white", AccentColor = "#FFFFFF", TextColor = "#16161D", StrokeRatio = 0.005 },
        new() { Id = "builtin.ocean", Name = "Ocean", AccentColor = "#2F7BFF", TextColor = "#FFFFFF", Enter = AnnotationAnimation.Pop, Exit = AnnotationAnimation.Fade },
        new() { Id = "builtin.ink", Name = "Ink", AccentColor = "#16161D", TextColor = "#FFFFFF", StrokeRatio = 0.006, Enter = AnnotationAnimation.Rise, Exit = AnnotationAnimation.Rise, AnimationMs = 300 }
    ];
}
