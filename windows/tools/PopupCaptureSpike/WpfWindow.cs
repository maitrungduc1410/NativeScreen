using WpfControls = System.Windows.Controls;
using WpfMedia = System.Windows.Media;

namespace PopupCaptureSpike;

/// <summary>A solid green WPF window with a ComboBox, a context menu and a tooltip.</summary>
internal sealed class WpfWindow : System.Windows.Window
{
    private readonly WpfControls.ComboBox combo = new() { Width = 260, Margin = new System.Windows.Thickness(40), HorizontalAlignment = System.Windows.HorizontalAlignment.Left, VerticalAlignment = System.Windows.VerticalAlignment.Top };
    private readonly WpfControls.ContextMenu menu = new() { Background = WpfMedia.Brushes.Orange };
    private readonly WpfControls.ToolTip tip = new() { Content = "A WPF tooltip over the green window, long enough to measure", Background = WpfMedia.Brushes.Yellow };
    private readonly WpfControls.Grid root = new() { Background = new WpfMedia.SolidColorBrush(WpfMedia.Color.FromRgb(0, 200, 0)) };

    public WpfWindow()
    {
        Title = "Popup spike WPF";
        Left = 200;
        Top = 150;
        Width = 1000;
        Height = 700;
        WindowStartupLocation = System.Windows.WindowStartupLocation.Manual;
        for (var index = 1; index <= 15; index++)
        {
            combo.Items.Add($"WPF ComboBox item {index}");
            menu.Items.Add(new WpfControls.MenuItem { Header = $"WPF context menu item {index}" });
        }

        combo.SelectedIndex = 0;
        root.Children.Add(combo);
        root.ContextMenu = menu;
        root.ToolTip = tip;
        Content = root;
    }

    public IReadOnlyList<(string Name, Action Open, Action Close)> Scenarios =>
    [
        ("ComboBox dropdown", () => combo.IsDropDownOpen = true, () => combo.IsDropDownOpen = false),
        ("ContextMenu", () =>
        {
            menu.Placement = WpfControls.Primitives.PlacementMode.Relative;
            menu.PlacementTarget = root;
            menu.HorizontalOffset = 450;
            menu.VerticalOffset = 150;
            menu.IsOpen = true;
        }, () => menu.IsOpen = false),
        ("ToolTip", () =>
        {
            tip.Placement = WpfControls.Primitives.PlacementMode.Relative;
            tip.PlacementTarget = root;
            tip.HorizontalOffset = 150;
            tip.VerticalOffset = 420;
            tip.IsOpen = true;
        }, () => tip.IsOpen = false),
    ];
}
