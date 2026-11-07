using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using NativeScreen.Core;
using System.Runtime.InteropServices.WindowsRuntime;

namespace NativeScreen.App;

/// <summary>
/// Inspector cards for cursor themes and variants. A neutral gray fill in both app themes lets dark and light cursors both read,
/// and each sprite is centered on its visible pixels rather than its view box, since sprites sit off-center around the hotspot.
/// </summary>
internal static class CursorThemeCards
{
    private static readonly string Root = Path.Combine(AppContext.BaseDirectory, "Assets", "Cursors", "sets");
    private static readonly Dictionary<string, (double X, double Y)> Offsets = [];
    private const int CenterAttempts = 6;
    private const int CenterRetryMs = 60;

    public static string DisplayName(string themeId) => themeId switch
    {
        "classic-dark" => "Classic Dark",
        "classic-light" => "Classic Light",
        "dart-color" => "Dart Color",
        _ => char.ToUpperInvariant(themeId[0]) + themeId[1..]
    };

    /// <summary>Pointer variants of a theme as (id, file), in variant order.</summary>
    public static List<(string Id, string File)> PointerVariants(string themeId)
    {
        var directory = Path.Combine(Root, themeId);
        if (!Directory.Exists(directory))
        {
            return [];
        }

        return Directory.GetFiles(directory, "pointer-*.svg")
            .Select(file => (Name: CursorSpriteName.Parse(Path.GetFileName(file), themeId), File: file))
            .OrderBy(item => item.Name.Variant)
            .Select(item => (Path.GetFileName(item.File).Split("__")[0], item.File))
            .ToList();
    }

    /// <param name="hoverFiles">Other variants a card cycles through while hovered, to show the style has more than one.</param>
    public static Button Card(string file, string name, bool selected, Action click, double size = 50, double spriteSize = 31, IReadOnlyList<string>? hoverFiles = null)
    {
        name = Loc.T(name);
        var image = Sprite(file, spriteSize);
        image.Loaded += (_, _) => _ = Center(image, file);
        image.ImageOpened += (_, _) => _ = Center(image, file);
        var sprites = new Grid();
        sprites.Children.Add(image);
        var fill = new Border { Width = size, Height = size, CornerRadius = new CornerRadius(10), Background = Ui.Rgb(0.48, 0.48, 0.48), Child = sprites };
        if (selected)
        {
            fill.Background = Ui.Rgb(0.54, 0.54, 0.54);
            fill.BorderBrush = Ui.Rgb(0.44, 0.34, 0.98);
            fill.BorderThickness = new Thickness(1.5);
        }

        var button = new Button { Style = Ui.StyleOf("NsIconButton"), Content = fill, Width = double.NaN, Height = double.NaN, Padding = new Thickness(0), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        Ui.Tip(button, name);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, name);
        button.Click += (_, _) => click();
        if (!selected)
        {
            button.PointerEntered += (_, _) => fill.Background = Ui.Rgb(0.51, 0.51, 0.51);
            button.PointerExited += (_, _) => fill.Background = Ui.Rgb(0.48, 0.48, 0.48);
            if (hoverFiles is { Count: > 0 })
            {
                CycleOnHover(button, sprites, image, hoverFiles, spriteSize);
            }
        }

        return button;
    }

    private static Image Sprite(string file, double size) => new()
    {
        Width = size,
        Height = size,
        Source = new SvgImageSource(new Uri(file)) { RasterizePixelWidth = 88, RasterizePixelHeight = 88 }
    };

    /// <summary>The other sprites are made on the first hover, so a panel full of cards loads nothing it may never show.</summary>
    private static void CycleOnHover(Button button, Grid sprites, Image first, IReadOnlyList<string> files, double spriteSize)
    {
        var fade = TimeSpan.FromMilliseconds(180);
        var timer = new DispatcherTimer();
        var current = 0;
        void Show(int next)
        {
            sprites.Children[current].Opacity = 0;
            sprites.Children[next].Opacity = 1;
            current = next;
        }

        timer.Tick += (_, _) =>
        {
            timer.Interval = TimeSpan.FromMilliseconds(950);
            Show((current + 1) % sprites.Children.Count);
        };
        button.PointerEntered += (_, _) =>
        {
            if (sprites.Children.Count == 1)
            {
                first.OpacityTransition = new ScalarTransition { Duration = fade };
                foreach (var file in files)
                {
                    var sprite = Sprite(file, spriteSize);
                    sprite.Opacity = 0;
                    sprite.OpacityTransition = new ScalarTransition { Duration = fade };
                    // Variants of a theme share one shape, and a sprite at zero opacity cannot be measured.
                    if (first.RenderTransform is TranslateTransform centered)
                    {
                        sprite.RenderTransform = new TranslateTransform { X = centered.X, Y = centered.Y };
                    }

                    sprites.Children.Add(sprite);
                }
            }

            timer.Interval = TimeSpan.FromMilliseconds(120);
            timer.Start();
        };
        void Stop()
        {
            timer.Stop();
            if (current != 0)
            {
                Show(0);
            }
        }

        button.PointerExited += (_, _) => Stop();
        button.Unloaded += (_, _) => timer.Stop();
    }

    /// <summary>An SVG decodes after the image loads, so a measurement can find nothing drawn yet and has to look again.</summary>
    private static async Task Center(Image image, string file)
    {
        for (var attempt = 0; attempt < CenterAttempts && !Offsets.ContainsKey(file); attempt++)
        {
            if (attempt > 0)
            {
                await Task.Delay(CenterRetryMs);
            }

            if (image.XamlRoot is null)
            {
                return;
            }

            await Measure(image, file);
        }

        if (Offsets.TryGetValue(file, out var offset))
        {
            image.RenderTransform = new TranslateTransform { X = offset.X * image.ActualWidth, Y = offset.Y * image.ActualHeight };
        }
    }

    private static async Task Measure(Image image, string file)
    {
        var bitmap = new RenderTargetBitmap();
        try
        {
            // Measured without the last correction, which would otherwise be counted in.
            image.RenderTransform = null;
            await bitmap.RenderAsync(image);
            var pixels = (await bitmap.GetPixelsAsync()).ToArray();
            var (width, height) = (bitmap.PixelWidth, bitmap.PixelHeight);
            var (minX, maxX, minY, maxY) = (width, -1, height, -1);
            for (var y = 0; y < height; y++)
            {
                for (var x = 0; x < width; x++)
                {
                    if (pixels[(y * width + x) * 4 + 3] > 16)
                    {
                        (minX, maxX, minY, maxY) = (Math.Min(minX, x), Math.Max(maxX, x), Math.Min(minY, y), Math.Max(maxY, y));
                    }
                }
            }

            if (maxX >= 0 && width > 0 && height > 0)
            {
                Offsets[file] = ((width - 1 - maxX - minX) / 2.0 / width, (height - 1 - maxY - minY) / 2.0 / height);
            }
        }
        catch (Exception exception) when (exception is System.Runtime.InteropServices.COMException or ArgumentException)
        {
            // Not in a state that can be drawn yet; the caller looks again.
        }
    }
}
