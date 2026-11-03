using System.Globalization;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace NativeScreen.App;

/// <summary>Small builders so code-built panels share the look of the XAML chrome.</summary>
internal static class Ui
{
    public const string FeatureNotReady = "Not available on Windows yet";

    public static Brush Pal(string key)
    {
        var themes = Application.Current.Resources.ThemeDictionaries;
        var name = AppTheme.Current == ElementTheme.Light ? "Light" : "Dark";
        return (Brush)((ResourceDictionary)themes[name])[key];
    }

    public static Style StyleOf(string key) => (Style)Application.Current.Resources[key];

    public static Color Hex(string value)
    {
        var text = value.TrimStart('#');
        if (text.Length < 6 || !uint.TryParse(text[..6], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var rgb))
        {
            return Colors.Black;
        }

        return Color.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
    }

    public static Brush Rgb(double r, double g, double b, double a = 1) =>
        new SolidColorBrush(Color.FromArgb((byte)(a * 255), (byte)(r * 255), (byte)(g * 255), (byte)(b * 255)));

    public static LinearGradientBrush Gradient(Color top, Color bottom, bool vertical = true)
    {
        var brush = new LinearGradientBrush
        {
            StartPoint = new Windows.Foundation.Point(0, 0),
            EndPoint = vertical ? new Windows.Foundation.Point(0, 1) : new Windows.Foundation.Point(1, 1)
        };
        brush.GradientStops.Add(new GradientStop { Color = top, Offset = 0 });
        brush.GradientStops.Add(new GradientStop { Color = bottom, Offset = 1 });
        return brush;
    }

    public static FontIcon Icon(string glyph, double size = 15, Brush? color = null)
    {
        var icon = new FontIcon
        {
            Glyph = glyph,
            FontSize = size,
            FontFamily = (FontFamily)Application.Current.Resources["NsIconFont"]
        };
        if (color is not null)
        {
            icon.Foreground = color;
        }

        return icon;
    }

    public static Microsoft.UI.Xaml.Shapes.Path Shape(string data, double size, Brush fill)
    {
        var path = (Microsoft.UI.Xaml.Shapes.Path)XamlReader.Load(
            "<Path xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" Stretch=\"Uniform\" Data=\"" + data + "\" />");
        path.Width = size;
        path.Height = size;
        path.Fill = fill;
        return path;
    }

    public static TextBlock Text(string text, double size = 13, string ink = "Ink88", bool medium = false)
    {
        var block = new TextBlock
        {
            Text = text,
            FontSize = size,
            Foreground = Pal(ink),
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center
        };
        if (medium)
        {
            block.FontWeight = Microsoft.UI.Text.FontWeights.Medium;
        }

        return block;
    }

    public static Button IconButton(UIElement content, string tooltip, Action? click, double size = 36)
    {
        var button = new Button { Style = StyleOf("NsIconButton"), Content = content, Width = size, Height = size };
        ToolTipService.SetToolTip(button, tooltip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, tooltip);
        if (click is null)
        {
            button.IsEnabled = false;
        }
        else
        {
            button.Click += (_, _) => click();
        }

        return button;
    }

    /// <summary>A pill option with the selected fill and border of the macOS inspector.</summary>
    public static Button Option(string title, bool selected, Action? click)
    {
        var button = new Button { Style = StyleOf("NsOptionButton"), Content = title };
        if (selected)
        {
            button.Background = Rgb(0.302, 0.184, 0.961, 0.16);
            button.BorderBrush = Rgb(0.44, 0.34, 0.98);
            button.BorderThickness = new Thickness(1.3);
            button.Foreground = Pal("Ink95");
        }

        if (click is null)
        {
            button.IsEnabled = false;
            ToolTipService.SetToolTip(button, FeatureNotReady);
        }
        else
        {
            button.Click += (_, _) => click();
        }

        return button;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint hwnd);

    /// <summary>AppWindow sizes are physical pixels; sizes here are DIPs, fitted to the work area.</summary>
    public static void SizeWindow(Window window, double width, double height, double minWidth, double minHeight)
    {
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(window)) / 96.0;
        var area = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(window.AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Nearest).WorkArea;
        var pixelWidth = Math.Min((int)(width * scale), area.Width);
        var pixelHeight = Math.Min((int)(height * scale), area.Height);
        window.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(
            area.X + (area.Width - pixelWidth) / 2,
            area.Y + (area.Height - pixelHeight) / 2,
            pixelWidth,
            pixelHeight));
        if (window.AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = (int)(minWidth * scale);
            presenter.PreferredMinimumHeight = (int)(minHeight * scale);
        }
    }

    public static string Timecode(double ms)
    {
        var total = Math.Max(0, ms) / 1000;
        var minutes = (int)(total / 60);
        return string.Create(CultureInfo.InvariantCulture, $"{minutes:00}:{total - minutes * 60:00.00}");
    }
}
