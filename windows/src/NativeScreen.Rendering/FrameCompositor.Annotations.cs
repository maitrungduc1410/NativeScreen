using System.Globalization;
using System.Numerics;
using NativeScreen.Core;
using Vortice.Direct2D1;
using Vortice.DirectWrite;
using Vortice.Mathematics;

namespace NativeScreen.Rendering;

/// <summary>
/// Passes 3B and 5C (spec/07): annotations drawn at output resolution with Direct2D, cached by content and pixel geometry, and
/// placed with a translation (text, steps and images also rotate and scale about their center), so a zoom moves an item
/// without enlarging a raster of it (spec/06 ADR-75).
/// </summary>
public sealed partial class FrameCompositor
{
    private const long MaximumAnnotationPixels = 48L * 1024 * 1024;
    // A text's box is kept with its sprite, so a cached text needs no DirectWrite layout on the render thread.
    private readonly Dictionary<string, (RenderLayer Layer, long Used, Vector2 Origin, Vector2 Box)> annotationSprites = [];
    private readonly Dictionary<string, AnnotationPicture?> annotationPictures = [];
    private long annotationPixels;

    private sealed record AnnotationPicture(byte[] Pixels, int Width, int Height);

    /// <summary>Pass 3B: screen-pinned items, mapped through the crop and the zoomed screen rect, under the cursor.</summary>
    private void DrawScreenAnnotations(RenderLayer target, ComposeRequest request, PixelRect screen, PixelRect? zoom, int width, int height)
    {
        if (request.Document.Timeline.AnnotationTracks.Count == 0)
        {
            return;
        }

        var drawn = zoom ?? screen;
        var crop = request.Document.Canvas.CropRect01;
        Vector2 Point(Point01 p) => new(
            (float)(drawn.X + (p.X - crop.X) / Math.Max(0.0001, crop.Width) * drawn.Width),
            (float)(drawn.Y + (p.Y - crop.Y) / Math.Max(0.0001, crop.Height) * drawn.Height));
        DrawAnnotations(target, request, AnnotationAnchor.Screen, Point, width, height);
    }

    /// <summary>Pass 5C: frame-pinned items, after the lens and before the camera.</summary>
    private void DrawCanvasAnnotations(RenderLayer target, ComposeRequest request, int width, int height)
    {
        if (request.Document.Timeline.AnnotationTracks.Count == 0)
        {
            return;
        }

        Vector2 Point(Point01 p) => new((float)(p.X * width), (float)(p.Y * height));
        DrawAnnotations(target, request, AnnotationAnchor.Canvas, Point, width, height);
    }

    private void DrawAnnotations(RenderLayer target, ComposeRequest request, AnnotationAnchor anchor, Func<Point01, Vector2> point, int width, int height)
    {
        var active = AnnotationMath.Active(request.Document, request.SourceMs, request.HiddenAnnotationId);
        Dictionary<string, int>? steps = null;
        var shortSide = Math.Min(width, height);
        foreach (var item in active)
        {
            if (item.Anchor != anchor)
            {
                continue;
            }

            var state = item.AnimationState(request.SourceMs);
            if (state.Opacity <= 0.003 || state.DrawProgress <= 0.001)
            {
                continue;
            }

            var lift = (float)(state.OffsetY * shortSide);
            var shift = (float)(state.OffsetX * shortSide);
            var scale = (float)state.Scale;
            var angle = (float)(item.RotationDegrees * Math.PI / 180);
            var opacity = (float)state.Opacity;
            switch (item.Kind)
            {
                case AnnotationKind.Text:
                case AnnotationKind.Step:
                case AnnotationKind.Image:
                {
                    var center = point(item.Position01);
                    (RenderLayer Layer, Vector2 Origin, Vector2 Box)? sprite;
                    if (item.Kind == AnnotationKind.Text)
                    {
                        var count = AnnotationMath.TextElementCount(item.Text);
                        int? visible = state.Reveal < 0.999 ? (int)Math.Ceiling(count * state.Reveal) : null;
                        if (visible == 0)
                        {
                            continue;
                        }

                        sprite = TextSprite(item, width, height, visible);
                    }
                    else if (item.Kind == AnnotationKind.Step)
                    {
                        steps ??= AnnotationMath.StepNumbers(request.Document);
                        sprite = StepSprite(item, steps.GetValueOrDefault(item.Id, 1), width, height);
                    }
                    else
                    {
                        sprite = PictureSprite(item, width, height, request.PackageDirectory);
                    }

                    if (sprite is not { } found)
                    {
                        continue;
                    }

                    // The box is centered on the point with its origin on whole pixels, then turned and scaled about the center.
                    var minX = MathF.Round(center.X - found.Box.X * 0.5f, MidpointRounding.AwayFromZero);
                    var minY = MathF.Round(center.Y - found.Box.Y * 0.5f, MidpointRounding.AwayFromZero);
                    var place = Matrix3x2.CreateTranslation(minX - found.Origin.X, minY - found.Origin.Y) * About(center, angle, scale, lift, shift);
                    DrawSprite(target, found.Layer, place, opacity);
                    break;
                }

                case AnnotationKind.Arrow:
                {
                    var tail = point(item.From01);
                    var head = point(item.To01);
                    var move = About((tail + head) * 0.5f, 0, scale, lift, shift);
                    if (LineSprite(item, width, height, Vector2.Transform(tail, move), Vector2.Transform(head, move), 0, scale, state.DrawProgress) is { } line)
                    {
                        DrawSprite(target, line.Layer, Matrix3x2.CreateTranslation(line.Origin), opacity);
                    }

                    break;
                }

                default:
                {
                    var center = point(item.Position01);
                    var half = AnnotationMath.ShapeHalfSize(item, point);
                    var alpha = item.Kind == AnnotationKind.Pen && item.Highlighter ? opacity * 0.42f : opacity;
                    if (LineSprite(item, width, height, new Vector2(center.X + shift, center.Y + lift), new Vector2((float)half.Width * scale, (float)half.Height * scale), angle, scale, state.DrawProgress) is { } line)
                    {
                        // A marker is see-through as one layer, so crossings do not darken.
                        DrawSprite(target, line.Layer, Matrix3x2.CreateTranslation(line.Origin), alpha);
                    }

                    break;
                }
            }
        }

        TrimAnnotationSprites();
    }

    /// <summary>Rotation (clockwise, y down) and scale about `center`, then a move.</summary>
    private static Matrix3x2 About(Vector2 center, float angle, float scale, float lift, float shift)
    {
        if (MathF.Abs(angle) <= 0.0001f && MathF.Abs(scale - 1) <= 0.0001f && MathF.Abs(lift) <= 0.01f && MathF.Abs(shift) <= 0.01f)
        {
            return Matrix3x2.Identity;
        }

        return Matrix3x2.CreateTranslation(-center) * Matrix3x2.CreateScale(scale) * Matrix3x2.CreateRotation(angle) * Matrix3x2.CreateTranslation(center.X + shift, center.Y + lift);
    }

    private void DrawSprite(RenderLayer target, RenderLayer sprite, Matrix3x2 spriteToCanvas, float opacity)
    {
        Matrix3x2.Invert(spriteToCanvas, out var inverse);
        var map = new QuadMap(
            new Vector4(inverse.M11 / sprite.Width, inverse.M21 / sprite.Width, inverse.M31 / sprite.Width, 0),
            new Vector4(inverse.M12 / sprite.Height, inverse.M22 / sprite.Height, inverse.M32 / sprite.Height, 0));
        RebindPipeline(target);
        _graphics.Context.OMSetBlendState(_sourceOver);
        DrawQuad(sprite.View, map, default, 0, opacity);
    }

    // MARK: Sprites

    private (RenderLayer Layer, Vector2 Origin, Vector2 Box)? CachedSprite(string key)
    {
        if (annotationSprites.TryGetValue(key, out var hit))
        {
            annotationSprites[key] = (hit.Layer, composeCount, hit.Origin, hit.Box);
            return (hit.Layer, hit.Origin, hit.Box);
        }

        return null;
    }

    /// <summary>
    /// Draws `body` into a new sprite, with a soft shadow cast by `caster` (the body when null): black at `shadowAlpha`, blurred
    /// by `shadowBlur` (a CoreGraphics blur, twice the Gaussian sigma) and moved `shadowDrop` down.
    /// </summary>
    private RenderLayer BuildSprite(string key, Vector2 origin, int width, int height, Action<ID2D1DeviceContext5> body, Action<ID2D1DeviceContext5>? caster, float shadowAlpha, float shadowBlur, float shadowDrop, Vector2 box = default)
    {
        var overlay = Overlays;
        var context = _graphics.Context;
        context.ClearState();
        var sprite = new RenderLayer(_graphics.Device, width, height);
        var bodyLayer = Layer("annotation-body", width, height);
        overlay.Draw(bodyLayer, () => body(overlay.Context));
        RenderLayer? shadow = null;
        if (shadowAlpha > 0)
        {
            shadow = Layer("annotation-shadow", width, height);
            overlay.Draw(shadow, () => (caster ?? body)(overlay.Context));
            RebindPipeline(shadow);
            Blur(shadow, Math.Max(0.3, shadowBlur * 0.5));
        }

        RebindPipeline(sprite);
        context.ClearRenderTargetView(sprite.Target, new Color4(0, 0, 0, 0));
        context.OMSetBlendState(_sourceOver);
        if (shadow is not null)
        {
            DrawQuad(shadow.View, new QuadMap(new Vector4(1f / width, 0, 0, 0), new Vector4(0, 1f / height, -shadowDrop / height, 0)), default, 0, shadowAlpha, blackSilhouette: true);
        }

        DrawQuad(bodyLayer.View, Identity(width, height), default, 0, 1);
        context.UnsetRenderTargets();
        annotationSprites[key] = (sprite, composeCount, origin, box);
        annotationPixels += (long)width * height;
        return sprite;
    }

    // Least recently used first, once the sprites hold more than the budget (a draw-on makes a new raster per step).
    private void TrimAnnotationSprites()
    {
        while (annotationPixels > MaximumAnnotationPixels && annotationSprites.Count > 1)
        {
            var oldest = default(string);
            var used = long.MaxValue;
            foreach (var (key, value) in annotationSprites)
            {
                if (value.Used < used)
                {
                    used = value.Used;
                    oldest = key;
                }
            }

            if (oldest is null || used == composeCount)
            {
                return;
            }

            var layer = annotationSprites[oldest].Layer;
            annotationPixels -= (long)layer.Width * layer.Height;
            layer.Dispose();
            annotationSprites.Remove(oldest);
        }
    }

    private static Color4 Rgb(string hex, float alpha = 1)
    {
        var (r, g, b) = AnnotationMath.HexColor(hex);
        return new Color4(r, g, b, alpha);
    }

    // MARK: Text and steps

    private IDWriteTextLayout AnnotationTextLayout(AnnotationItem item, double fontSize, double wrapWidth)
    {
        using var format = Overlays.WriteFactory.CreateTextFormat(
            "Segoe UI", item.Bold ? FontWeight.Bold : FontWeight.Medium, Vortice.DirectWrite.FontStyle.Normal, FontStretch.Normal, (float)fontSize);
        format.TextAlignment = TextAlignment.Center;
        format.WordWrapping = WordWrapping.Wrap;
        return Overlays.WriteFactory.CreateTextLayout(item.Text.Length == 0 ? " " : item.Text, format, (float)wrapWidth, float.MaxValue);
    }

    private (RenderLayer Layer, Vector2 Origin, Vector2 Box)? TextSprite(AnnotationItem item, int width, int height, int? visible)
    {
        var fontSize = AnnotationMath.FontSize(item, width, height);
        var padding = AnnotationMath.TextPadding(item, fontSize);
        var wrap = AnnotationMath.TextWrapWidth(item, fontSize, width);
        var key = string.Create(CultureInfo.InvariantCulture, $"text|{item.Text}|{fontSize}|{item.MaxWidthRatio}|{width}|{item.Bold}|{item.Color}|{item.TextBackground}|{item.BackgroundColor}|{visible}");
        if (CachedSprite(key) is { } hit)
        {
            return hit;
        }

        var layout = AnnotationTextLayout(item, fontSize, wrap);
        try
        {
            var metrics = layout.Metrics;
            var box = new Vector2((float)Math.Ceiling(metrics.Width + padding.X * 2), (float)Math.Ceiling(metrics.Height + padding.Y * 2));

            // Room around the box for its shadow.
            var margin = (float)Math.Ceiling(fontSize * 0.5);
            var spriteWidth = (int)(box.X + margin * 2);
            var spriteHeight = (int)(box.Y + margin * 2);
            if (spriteWidth <= 0 || spriteHeight <= 0)
            {
                return null;
            }

            var plate = item.TextBackground == AnnotationTextBackground.Solid;
            var corner = (float)AnnotationMath.TextCornerRadius(item, fontSize);
            var plateRect = new RoundedRectangle { Rect = new Rect(margin, margin, box.X, box.Y), RadiusX = corner, RadiusY = corner };
            // The layout centers each line in the wrap width; the box is the text's own width, so it starts where the text does.
            var textOrigin = new Vector2(margin + (float)padding.X - metrics.Left, margin + (float)padding.Y - metrics.Top);
            void DrawLetters(ID2D1DeviceContext5 context, bool shadowOnly)
            {
                using var ink = context.CreateSolidColorBrush(shadowOnly ? new Color4(0, 0, 0, 1) : Rgb(item.Color));
                using var clear = context.CreateSolidColorBrush(new Color4(0, 0, 0, 0));
                if (visible is { } shown)
                {
                    // Hidden characters stay laid out in clear ink, so lines wrap where they will end up.
                    var start = AnnotationMath.Utf16LengthOfElements(item.Text, shown);
                    if (start < item.Text.Length)
                    {
                        layout.SetDrawingEffect(clear, new TextRange((uint)start, (uint)(item.Text.Length - start)));
                    }
                }

                context.DrawTextLayout(textOrigin, layout, ink, DrawTextOptions.None);
            }

            var sprite = BuildSprite(
                key,
                new Vector2(margin, margin),
                spriteWidth,
                spriteHeight,
                context =>
                {
                    if (plate)
                    {
                        using var fill = context.CreateSolidColorBrush(Rgb(item.BackgroundColor));
                        context.FillRoundedRectangle(plateRect, fill);
                    }

                    DrawLetters(context, false);
                },
                plate
                    ? context =>
                    {
                        using var fill = context.CreateSolidColorBrush(new Color4(0, 0, 0, 1));
                        context.FillRoundedRectangle(plateRect, fill);
                    }
                    : context => DrawLetters(context, true),
                plate ? 0.30f : 0.55f,
                (float)(fontSize * (plate ? 0.30 : 0.18)),
                (float)(fontSize * 0.05),
                box);
            return (sprite, new Vector2(margin, margin), box);
        }
        finally
        {
            layout.Dispose();
        }
    }

    private (RenderLayer Layer, Vector2 Origin, Vector2 Box)? StepSprite(AnnotationItem item, int number, int width, int height)
    {
        var diameter = (float)AnnotationMath.StepDiameter(item, width, height);
        var box = new Vector2(diameter, diameter);
        var key = string.Create(CultureInfo.InvariantCulture, $"step|{number}|{diameter}|{item.Color}");
        if (CachedSprite(key) is { } hit)
        {
            return (hit.Layer, hit.Origin, box);
        }

        var margin = MathF.Ceiling(diameter * 0.35f);
        var side = (int)(diameter + margin * 2);
        var center = new Vector2(margin + diameter * 0.5f, margin + diameter * 0.5f);
        var circle = new Ellipse(center, diameter * 0.5f, diameter * 0.5f);
        var sprite = BuildSprite(
            key,
            new Vector2(margin, margin),
            side,
            side,
            context =>
            {
                using var fill = context.CreateSolidColorBrush(Rgb(item.Color));
                context.FillEllipse(circle, fill);
                // A thin white ring keeps the badge visible on a background of its own color.
                var ring = diameter * 0.065f;
                using var white = context.CreateSolidColorBrush(new Color4(1, 1, 1, 0.92f));
                context.DrawEllipse(new Ellipse(center, diameter * 0.5f - ring * 0.5f, diameter * 0.5f - ring * 0.5f), white, ring);
                var (r, g, b) = AnnotationMath.ContrastingTextColor(item.Color);
                using var ink = context.CreateSolidColorBrush(new Color4(r, g, b, 1));
                // VERIFY: no rounded system face on Windows; Segoe UI bold is the closest match to the rounded digits.
                using var format = Overlays.WriteFactory.CreateTextFormat(
                    "Segoe UI", FontWeight.Bold, Vortice.DirectWrite.FontStyle.Normal, FontStretch.Normal, diameter * (number >= 10 ? 0.46f : 0.56f));
                format.TextAlignment = TextAlignment.Center;
                format.ParagraphAlignment = ParagraphAlignment.Center;
                context.DrawText(number.ToString(CultureInfo.InvariantCulture), format, new Rect(margin, margin, diameter, diameter), ink);
            },
            context =>
            {
                using var fill = context.CreateSolidColorBrush(new Color4(0, 0, 0, 1));
                context.FillEllipse(circle, fill);
            },
            0.40f,
            diameter * 0.18f,
            diameter * 0.04f);
        return (sprite, new Vector2(margin, margin), box);
    }

    // MARK: Images

    private AnnotationPicture? Picture(AnnotationItem item, string? packageDirectory)
    {
        if (packageDirectory is null || item.ImagePath.Length == 0)
        {
            return null;
        }

        var path = Path.Combine(packageDirectory, item.ImagePath);
        if (annotationPictures.TryGetValue(path, out var hit))
        {
            return hit;
        }

        AnnotationPicture? picture = null;
        try
        {
            if (File.Exists(path))
            {
                // EXIF orientation applied; 4096 px is more than any frame needs.
                var image = ImageTexture.Load(path, 4096, orient: true);
                picture = new AnnotationPicture(image.Pixels, image.Width, image.Height);
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or SharpGen.Runtime.SharpGenException)
        {
            picture = null;
        }

        if (annotationPictures.Count > 32)
        {
            annotationPictures.Clear();
        }

        annotationPictures[path] = picture;
        return picture;
    }

    private (RenderLayer Layer, Vector2 Origin, Vector2 Box)? PictureSprite(AnnotationItem item, int width, int height, string? packageDirectory)
    {
        var picture = Picture(item, packageDirectory);
        var (w, h) = AnnotationMath.ImageSize(item, width, picture?.Width, picture?.Height);
        var box = new Vector2((float)w, (float)h);
        var corner = (float)Math.Min(item.CornerRatio * Math.Min(width, height), Math.Min(w, h) * 0.5);
        var key = string.Create(CultureInfo.InvariantCulture, $"image|{item.ImagePath}|{w}x{h}|{corner}|{picture is null}");
        if (CachedSprite(key) is { } hit)
        {
            return (hit.Layer, hit.Origin, box);
        }

        var margin = MathF.Ceiling((float)Math.Max(w, h) * 0.06f);
        var rect = new RoundedRectangle { Rect = new Rect(margin, margin, box.X, box.Y), RadiusX = corner, RadiusY = corner };
        void Fill(ID2D1DeviceContext5 context)
        {
            if (picture is null)
            {
                using var gray = context.CreateSolidColorBrush(new Color4(0.3f, 0.3f, 0.3f, 1));
                context.FillRoundedRectangle(rect, gray);
                return;
            }

            var pinned = System.Runtime.InteropServices.GCHandle.Alloc(picture.Pixels, System.Runtime.InteropServices.GCHandleType.Pinned);
            ID2D1Bitmap1 made;
            try
            {
                made = context.CreateBitmap(
                    new SizeI(picture.Width, picture.Height),
                    pinned.AddrOfPinnedObject(),
                    (uint)(picture.Width * 4),
                    new BitmapProperties1(new Vortice.DCommon.PixelFormat(Vortice.DXGI.Format.B8G8R8A8_UNorm, Vortice.DCommon.AlphaMode.Premultiplied)));
            }
            finally
            {
                pinned.Free();
            }

            using var bitmap = made;
            using var brush = context.CreateBitmapBrush(
                bitmap,
                new BitmapBrushProperties1(ExtendMode.Clamp, ExtendMode.Clamp, Vortice.Direct2D1.InterpolationMode.HighQualityCubic));
            brush.Transform = Matrix3x2.CreateScale(box.X / picture.Width, box.Y / picture.Height) * Matrix3x2.CreateTranslation(margin, margin);
            context.FillRoundedRectangle(rect, brush);
        }

        // The shadow comes from the clipped picture's own alpha, so a logo with transparent corners casts its own shape.
        var sprite = BuildSprite(key, new Vector2(margin, margin), (int)(box.X + margin * 2), (int)(box.Y + margin * 2), Fill, null, 0.35f, margin * 0.6f, margin * 0.15f);
        return (sprite, new Vector2(margin, margin), box);
    }

    // MARK: Arrows, shapes and pens

    /// <summary>
    /// An arrow from `a` to `b`, or a shape centered on `a` with half size `b` turned by `rotation`. Only the part within the
    /// frame is drawn, because a zoom can push the geometry thousands of pixels away. Returns the sprite and its canvas origin.
    /// </summary>
    private (RenderLayer Layer, Vector2 Origin)? LineSprite(AnnotationItem item, int width, int height, Vector2 a, Vector2 b, float rotation, float strokeScale, double progress)
    {
        var stroke = (float)(AnnotationMath.StrokeWidth(item, width, height) * Math.Max(0.2, strokeScale));
        var margin = stroke * 4;
        var corner = (float)(item.CornerRatio * Math.Min(width, height));
        AnnotationMath.Arrow? arrow = null;
        float minX, minY, maxX, maxY;
        if (item.Kind == AnnotationKind.Arrow)
        {
            var g = AnnotationMath.ArrowGeometry(a, b, item.Bend, stroke);
            arrow = g;
            minX = Math.Min(Math.Min(g.Tail.X, g.Control.X), Math.Min(g.Head.X, Math.Min(g.HeadBaseLeft.X, g.HeadBaseRight.X)));
            maxX = Math.Max(Math.Max(g.Tail.X, g.Control.X), Math.Max(g.Head.X, Math.Max(g.HeadBaseLeft.X, g.HeadBaseRight.X)));
            minY = Math.Min(Math.Min(g.Tail.Y, g.Control.Y), Math.Min(g.Head.Y, Math.Min(g.HeadBaseLeft.Y, g.HeadBaseRight.Y)));
            maxY = Math.Max(Math.Max(g.Tail.Y, g.Control.Y), Math.Max(g.Head.Y, Math.Max(g.HeadBaseLeft.Y, g.HeadBaseRight.Y)));
        }
        else
        {
            var turn = Matrix3x2.CreateRotation(rotation);
            Span<Vector2> corners = [new(-b.X, -b.Y), new(b.X, -b.Y), new(b.X, b.Y), new(-b.X, b.Y)];
            minX = minY = float.MaxValue;
            maxX = maxY = float.MinValue;
            foreach (var c in corners)
            {
                var p = a + Vector2.Transform(c, turn);
                minX = Math.Min(minX, p.X);
                minY = Math.Min(minY, p.Y);
                maxX = Math.Max(maxX, p.X);
                maxY = Math.Max(maxY, p.Y);
            }
        }

        var left = MathF.Floor(Math.Max(minX - margin, -margin));
        var top = MathF.Floor(Math.Max(minY - margin, -margin));
        var right = MathF.Ceiling(Math.Min(maxX + margin, width + margin));
        var bottom = MathF.Ceiling(Math.Min(maxY + margin, height + margin));
        if (right - left < 1 || bottom - top < 1)
        {
            return null;
        }

        static float Q(float v) => MathF.Round(v * 4) / 4;
        var steps = (int)Math.Round(progress * AnnotationMath.DrawSteps(item));
        var key = string.Create(
            CultureInfo.InvariantCulture,
            $"line|{item.Kind}|{Q(a.X)},{Q(a.Y)}|{Q(b.X)},{Q(b.Y)}|{item.Bend}|{rotation}|{stroke}|{item.Color}|{item.FillOpacity}|{corner}|{steps}|{left},{top},{right},{bottom}|{(item.Kind == AnnotationKind.Pen ? AnnotationMath.PenHash(item) : 0)}");
        var origin = new Vector2(left, top);
        if (CachedSprite(key) is { } hit)
        {
            return (hit.Layer, origin);
        }

        var factory = Overlays.Factory;
        var color = Rgb(item.Color);
        var highlighter = item.Kind == AnnotationKind.Pen && item.Highlighter;
        void Draw(ID2D1DeviceContext5 context)
        {
            context.Transform = Matrix3x2.CreateTranslation(-left, -top);
            using var brush = context.CreateSolidColorBrush(color);
            var cap = highlighter ? CapStyle.Flat : CapStyle.Round;
            if (arrow is { } g)
            {
                using var shaft = factory.CreatePathGeometry();
                using (var sink = shaft.Open())
                {
                    sink.BeginFigure(g.Tail, FigureBegin.Hollow);
                    sink.AddQuadraticBezier(new QuadraticBezierSegment { Point1 = g.Control, Point2 = g.ShaftEnd });
                    sink.EndFigure(FigureEnd.Open);
                    sink.Close();
                }

                using var style = Style(factory, cap, progress < 0.999 ? AnnotationMath.ShaftLength(g) * progress : null, stroke);
                context.DrawGeometry(shaft, brush, stroke, style);
                // The head appears over the last part of the stroke.
                var headAlpha = (float)Math.Clamp((progress - 0.8) / 0.2, 0, 1);
                if (headAlpha > 0.001f)
                {
                    using var headShape = factory.CreatePathGeometry();
                    using (var sink = headShape.Open())
                    {
                        sink.BeginFigure(g.Head, FigureBegin.Filled);
                        sink.AddLine(g.HeadBaseLeft);
                        sink.AddLine(g.HeadBaseRight);
                        sink.EndFigure(FigureEnd.Closed);
                        sink.Close();
                    }

                    using var headBrush = context.CreateSolidColorBrush(new Color4(color.R, color.G, color.B, headAlpha));
                    using var headStyle = Style(factory, CapStyle.Round, null, stroke);
                    context.FillGeometry(headShape, headBrush);
                    context.DrawGeometry(headShape, headBrush, stroke * 0.6f, headStyle);
                }
            }
            else if (item.Kind == AnnotationKind.Pen)
            {
                context.Transform = Matrix3x2.CreateRotation(rotation) * Matrix3x2.CreateTranslation(a.X - left, a.Y - top);
                using var path = factory.CreatePathGeometry();
                using (var sink = path.Open())
                {
                    foreach (var points in AnnotationMath.PenStrokes(item, b.X, b.Y, progress))
                    {
                        AddStroke(sink, points);
                    }

                    sink.Close();
                }

                using var style = Style(factory, cap, null, stroke);
                context.DrawGeometry(path, brush, stroke, style);
            }
            else
            {
                context.Transform = Matrix3x2.CreateRotation(rotation) * Matrix3x2.CreateTranslation(a.X - left, a.Y - top);
                var rect = new Rect(-b.X, -b.Y, b.X * 2, b.Y * 2);
                ID2D1Geometry shape;
                double perimeter;
                if (item.Kind == AnnotationKind.Ellipse)
                {
                    shape = factory.CreateEllipseGeometry(new Ellipse(Vector2.Zero, b.X, b.Y));
                    // Ramanujan's approximation.
                    var h = Math.Pow(b.X - b.Y, 2) / Math.Max(0.001, Math.Pow(b.X + b.Y, 2));
                    perimeter = Math.PI * (b.X + b.Y) * (1 + 3 * h / (10 + Math.Sqrt(4 - 3 * h)));
                }
                else
                {
                    var r = Math.Min(corner, Math.Min(b.X, b.Y));
                    shape = factory.CreateRoundedRectangleGeometry(new RoundedRectangle { Rect = rect, RadiusX = r, RadiusY = r });
                    perimeter = 4 * (b.X + b.Y) - (8 - 2 * Math.PI) * r;
                }

                using (shape)
                {
                    if (item.FillOpacity > 0.001)
                    {
                        using var fill = context.CreateSolidColorBrush(new Color4(color.R, color.G, color.B, (float)(item.FillOpacity * progress)));
                        context.FillGeometry(shape, fill);
                    }

                    using var style = Style(factory, cap, progress < 0.999 ? perimeter * progress : null, stroke);
                    context.DrawGeometry(shape, brush, stroke, style);
                }
            }

            context.Transform = Matrix3x2.Identity;
        }

        var sprite = BuildSprite(key, origin, (int)(right - left), (int)(bottom - top), Draw, null, highlighter ? 0 : 0.38f, stroke * 1.6f, stroke * 0.35f);
        return (sprite, origin);
    }

    /// <summary>Round joins; a dash as long as the drawn share of the line when it is drawing on (Direct2D dashes count in stroke widths).</summary>
    private static ID2D1StrokeStyle Style(ID2D1Factory1 factory, CapStyle cap, double? drawnLength, float stroke)
    {
        var properties = new StrokeStyleProperties
        {
            StartCap = cap,
            EndCap = cap,
            DashCap = cap,
            LineJoin = LineJoin.Round,
            DashStyle = drawnLength is null ? DashStyle.Solid : DashStyle.Custom
        };
        return drawnLength is { } length
            ? factory.CreateStrokeStyle(properties, [(float)(length / stroke), 1_000_000f / stroke])
            : factory.CreateStrokeStyle(properties);
    }

    /// <summary>One pen stroke: through the midpoints of its points, with the points as controls.</summary>
    private static void AddStroke(ID2D1GeometrySink sink, List<Vector2> points)
    {
        if (points.Count == 0)
        {
            return;
        }

        sink.BeginFigure(points[0], FigureBegin.Hollow);
        if (points.Count == 1)
        {
            // A dot.
            sink.AddLine(points[0] + new Vector2(0.01f, 0));
        }
        else if (points.Count == 2)
        {
            sink.AddLine(points[1]);
        }
        else
        {
            for (var i = 1; i < points.Count - 1; i++)
            {
                sink.AddQuadraticBezier(new QuadraticBezierSegment { Point1 = points[i], Point2 = (points[i] + points[i + 1]) * 0.5f });
            }

            sink.AddLine(points[^1]);
        }

        sink.EndFigure(FigureEnd.Open);
    }

    private void DisposeAnnotationSprites()
    {
        foreach (var sprite in annotationSprites.Values)
        {
            sprite.Layer.Dispose();
        }

        annotationSprites.Clear();
        annotationPixels = 0;
    }
}
