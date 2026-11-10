using System.Collections.Concurrent;
using NativeScreen.Core;
using Vortice.DirectWrite;

namespace NativeScreen.Rendering;

/// <summary>
/// Box sizes of text, step and image annotations, measured with the same DirectWrite layout the compositor draws with, so the
/// canvas handles sit on what is drawn (spec/06 ADR-75). Safe to call from the UI thread.
/// </summary>
public static class AnnotationMeasure
{
    private static readonly Lazy<IDWriteFactory> Factory = new(() => DWrite.DWriteCreateFactory<IDWriteFactory>());
    private static readonly ConcurrentDictionary<string, (int Width, int Height)?> ImageSizes = new();
    private static readonly object Gate = new();

    /// <summary>The box (padding included) of a text, step or image for a frame of the given size.</summary>
    public static (double Width, double Height) Box(AnnotationItem item, double canvasWidth, double canvasHeight, string? packageDirectory)
    {
        switch (item.Kind)
        {
            case AnnotationKind.Step:
                var d = AnnotationMath.StepDiameter(item, canvasWidth, canvasHeight);
                return (d, d);
            case AnnotationKind.Image:
                var size = ImageSize(item, packageDirectory);
                return AnnotationMath.ImageSize(item, canvasWidth, size?.Width, size?.Height);
            default:
                return Text(item, canvasWidth, canvasHeight);
        }
    }

    public static (double Width, double Height) Text(AnnotationItem item, double canvasWidth, double canvasHeight)
    {
        var fontSize = AnnotationMath.FontSize(item, canvasWidth, canvasHeight);
        var padding = AnnotationMath.TextPadding(item, fontSize);
        lock (Gate)
        {
            using var format = Factory.Value.CreateTextFormat("Segoe UI", item.Bold ? FontWeight.Bold : FontWeight.Medium, FontStyle.Normal, FontStretch.Normal, (float)fontSize);
            format.TextAlignment = TextAlignment.Center;
            format.WordWrapping = WordWrapping.Wrap;
            using var layout = Factory.Value.CreateTextLayout(item.Text.Length == 0 ? " " : item.Text, format, (float)AnnotationMath.TextWrapWidth(item, fontSize, canvasWidth), float.MaxValue);
            var metrics = layout.Metrics;
            return (Math.Ceiling(metrics.Width + padding.X * 2), Math.Ceiling(metrics.Height + padding.Y * 2));
        }
    }

    /// <summary>The picture's pixel size from its header, EXIF orientation applied; null when missing.</summary>
    public static (int Width, int Height)? ImageSize(AnnotationItem item, string? packageDirectory)
    {
        if (packageDirectory is null || item.ImagePath.Length == 0)
        {
            return null;
        }

        var path = Path.Combine(packageDirectory, item.ImagePath);
        return ImageSizes.GetOrAdd(path, static file =>
        {
            try
            {
                if (!File.Exists(file))
                {
                    return null;
                }

                var image = ImageTexture.Load(file, 4096, orient: true);
                return (image.Width, image.Height);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or SharpGen.Runtime.SharpGenException)
            {
                return null;
            }
        });
    }
}
