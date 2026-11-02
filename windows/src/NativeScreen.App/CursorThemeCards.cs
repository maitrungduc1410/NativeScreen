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
    private const double CardSize = 62;
    private const double SpriteSize = 44;
    private static readonly string Root = Path.Combine(AppContext.BaseDirectory, "Assets", "Cursors", "sets");
    private static readonly Dictionary<string, (double X, double Y)> Offsets = [];

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

    public static Button Card(string file, string? title, bool selected, Action click)
    {
        var image = new Image { Width = SpriteSize, Height = SpriteSize, Source = new SvgImageSource(new Uri(file)) { RasterizePixelWidth = 88, RasterizePixelHeight = 88 } };
        image.Loaded += (_, _) => _ = Center(image, file);
        var stack = new StackPanel { Spacing = 2, HorizontalAlignment = HorizontalAlignment.Center };
        var fill = new Border { Width = CardSize, Height = CardSize, CornerRadius = new CornerRadius(9), Background = Ui.Rgb(0.48, 0.48, 0.48), Child = image };
        if (selected)
        {
            fill.Background = Ui.Rgb(0.54, 0.54, 0.54);
            fill.BorderBrush = Ui.Rgb(0.44, 0.34, 0.98);
            fill.BorderThickness = new Thickness(2);
        }

        stack.Children.Add(fill);
        if (title is not null)
        {
            stack.Children.Add(new TextBlock { Text = title, FontSize = 11, MaxWidth = CardSize + 8, TextTrimming = TextTrimming.CharacterEllipsis, HorizontalAlignment = HorizontalAlignment.Center, Foreground = Ui.Pal("Ink60") });
        }

        var button = new Button { Style = Ui.StyleOf("NsIconButton"), Content = stack, Width = double.NaN, Height = double.NaN, Padding = new Thickness(0), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, title ?? Path.GetFileNameWithoutExtension(file));
        button.Click += (_, _) => click();
        return button;
    }

    private static async Task Center(Image image, string file)
    {
        if (!Offsets.TryGetValue(file, out var offset))
        {
            var bitmap = new RenderTargetBitmap();
            try
            {
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

                if (maxX < 0 || width == 0 || height == 0)
                {
                    // Not drawn yet: leave it uncentered and let the next build of the panel measure it.
                    return;
                }

                offset = ((width - 1 - maxX - minX) / 2.0 / width, (height - 1 - maxY - minY) / 2.0 / height);
                Offsets[file] = offset;
            }
            catch (System.Runtime.InteropServices.COMException)
            {
                return;
            }
        }

        image.RenderTransform = new TranslateTransform { X = offset.X * image.ActualWidth, Y = offset.Y * image.ActualHeight };
    }
}
