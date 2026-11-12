using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace NativeScreen.App;

/// <summary>A color swatch that opens a picker, with an editable hex box beside it, as in the macOS inspector.</summary>
internal static class ColorField
{
    public static Grid Create(string name, string hex, Action<string> preview, Action<string> commit)
    {
        name = Loc.T(name);
        var grid = new Grid { ColumnSpacing = 6 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        var fill = new Border { Width = 32, Height = 32, CornerRadius = new CornerRadius(8), BorderBrush = Ui.Pal("Ink14"), BorderThickness = new Thickness(1), Background = new SolidColorBrush(Ui.Hex(hex)) };
        var swatch = new Button { Style = Ui.StyleOf("NsIconButton"), Content = fill, Width = 32, Height = 32, Padding = new Thickness(0) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(swatch, name);
        var box = new TextBox { Text = Normalized(hex), Height = 32, MinWidth = 0, IsSpellCheckEnabled = false };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, name + " hex");
        Grid.SetColumn(box, 1);
        grid.Children.Add(swatch);
        grid.Children.Add(box);

        var picker = new ColorPicker { Color = Ui.Hex(hex), IsAlphaEnabled = false, IsMoreButtonVisible = false, IsColorChannelTextInputVisible = false, IsHexInputVisible = true };
        var flyout = new Flyout { Content = picker, ShouldConstrainToRootBounds = false };
        var picked = hex;
        picker.ColorChanged += (_, args) =>
        {
            picked = ToHex(args.NewColor);
            fill.Background = new SolidColorBrush(args.NewColor);
            box.Text = picked;
            preview(picked);
        };
        // The panel rebuilds on a structural edit, which would close the picker, so the final value waits for the close.
        flyout.Closed += (_, _) => commit(picked);
        swatch.Click += (_, _) => flyout.ShowAt(swatch, new FlyoutShowOptions { Placement = FlyoutPlacementMode.LeftEdgeAlignedTop });

        void CommitText()
        {
            var text = box.Text.Trim().TrimStart('#');
            if (text.Length == 6 && uint.TryParse(text, System.Globalization.NumberStyles.HexNumber, System.Globalization.CultureInfo.InvariantCulture, out _))
            {
                commit("#" + text.ToUpperInvariant());
            }
            else
            {
                box.Text = Normalized(picked);
            }
        }

        box.LostFocus += (_, _) =>
        {
            if (!string.Equals(box.Text.Trim().TrimStart('#'), picked.TrimStart('#'), StringComparison.OrdinalIgnoreCase))
            {
                CommitText();
            }
        };
        box.KeyDown += (_, args) =>
        {
            if (args.Key == Windows.System.VirtualKey.Enter)
            {
                CommitText();
                args.Handled = true;
            }
        };
        return grid;
    }

    /// <summary>Rotates a color's hue, wrapping at the ends of the wheel.</summary>
    public static string ShiftHue(string hex, double delta)
    {
        var color = Ui.Hex(hex);
        var (r, g, b) = (color.R / 255.0, color.G / 255.0, color.B / 255.0);
        var max = Math.Max(r, Math.Max(g, b));
        var min = Math.Min(r, Math.Min(g, b));
        var range = max - min;
        var hue = range == 0 ? 0 : max == r ? ((g - b) / range + 6) % 6 : max == g ? (b - r) / range + 2 : (r - g) / range + 4;
        hue = ((hue / 6 + delta) % 1 + 1) % 1 * 6;
        var x = range * (1 - Math.Abs(hue % 2 - 1));
        var (dr, dg, db) = (int)hue switch
        {
            0 => (range, x, 0d),
            1 => (x, range, 0d),
            2 => (0d, range, x),
            3 => (0d, x, range),
            4 => (x, 0d, range),
            _ => (range, 0d, x)
        };
        return ToHex(Color.FromArgb(255, (byte)Math.Round((dr + min) * 255), (byte)Math.Round((dg + min) * 255), (byte)Math.Round((db + min) * 255)));
    }

    private static string Normalized(string hex) => "#" + hex.TrimStart('#').ToUpperInvariant();

    private static string ToHex(Color color) => $"#{color.R:X2}{color.G:X2}{color.B:X2}";
}
