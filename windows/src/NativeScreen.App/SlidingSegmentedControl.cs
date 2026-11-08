using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;

namespace NativeScreen.App;

/// <summary>
/// A row of choices where an accent pill slides to the clicked one. Hairlines sit only between two unselected neighbours.
/// The segments are radio buttons, so screen readers announce a list of options and which one is selected. With animations
/// turned off in Windows the pill jumps. It keeps its own selection, so a click does not rebuild the page and stop the slide.
/// </summary>
internal sealed partial class SlidingSegmentedControl : Grid
{
    private const double SlideMs = 300;
    private static readonly Brush PillBrush = Ui.Rgb(0.44, 0.34, 0.98);
    private static int groups;

    private readonly Canvas backdrop = new() { IsHitTestVisible = false };
    private readonly Border pill = new() { CornerRadius = new CornerRadius(6), Background = PillBrush, Visibility = Visibility.Collapsed };
    private readonly StackPanel row = new() { Orientation = Orientation.Horizontal };
    private readonly List<RadioButton> segments = [];
    private readonly List<Rectangle> hairlines = [];
    private Storyboard? slide;
    private int selected;

    public SlidingSegmentedControl(IReadOnlyList<(string Title, bool Selected, Action Change)> options)
    {
        HorizontalAlignment = HorizontalAlignment.Left;
        CornerRadius = new CornerRadius(8);
        Padding = new Thickness(2);
        Background = Ui.Pal("Ink07");
        selected = Math.Max(0, options.ToList().FindIndex(option => option.Selected));
        backdrop.Children.Add(pill);
        Children.Add(backdrop);
        Children.Add(row);
        var group = $"NsSegments{Interlocked.Increment(ref groups)}";
        for (var index = 0; index < options.Count; index++)
        {
            var (at, change) = (index, options[index].Change);
            var segment = new RadioButton
            {
                Style = Ui.StyleOf("NsSegmentRadio"),
                GroupName = group,
                Content = Loc.T(options[index].Title),
                IsChecked = index == selected
            };
            // Checked and not Click: a screen reader selects through automation, which raises no click.
            segment.Checked += (_, _) =>
            {
                if (at != selected)
                {
                    selected = at;
                    Place(animated: true);
                    change();
                }
            };
            segments.Add(segment);
            row.Children.Add(segment);
            if (index > 0)
            {
                var line = new Rectangle { Width = 1, Fill = Ui.Pal("Ink14") };
                hairlines.Add(line);
                backdrop.Children.Add(line);
            }
        }

        row.SizeChanged += (_, _) => Place(animated: false);
        ActualThemeChanged += (_, _) => RefreshBrushes();
    }

    private void RefreshBrushes()
    {
        Background = Ui.Pal("Ink07");
        foreach (var line in hairlines)
        {
            line.Fill = Ui.Pal("Ink14");
        }

        Place(animated: false);
    }

    private void Place(bool animated)
    {
        if (segments.Count == 0 || row.ActualHeight <= 0)
        {
            return;
        }

        var left = 0.0;
        for (var index = 0; index < selected; index++)
        {
            left += segments[index].ActualWidth;
        }

        var width = segments[selected].ActualWidth;
        pill.Height = row.ActualHeight;
        pill.Visibility = Visibility.Visible;
        for (var index = 0; index < segments.Count; index++)
        {
            segments[index].Foreground = index == selected ? Ui.Rgb(1, 1, 1) : Ui.Pal("Ink60");
        }

        var edge = 0.0;
        for (var index = 0; index < hairlines.Count; index++)
        {
            edge += segments[index].ActualWidth;
            var line = hairlines[index];
            line.Height = row.ActualHeight - 12;
            Canvas.SetLeft(line, edge - 0.5);
            Canvas.SetTop(line, 6);
            line.Visibility = index == selected || index + 1 == selected ? Visibility.Collapsed : Visibility.Visible;
        }

        slide?.Stop();
        if (!animated || A11y.ReduceMotion || pill.Width is not > 0)
        {
            Canvas.SetLeft(pill, left);
            pill.Width = width;
            return;
        }

        var from = Canvas.GetLeft(pill);
        var fromWidth = pill.Width;
        Canvas.SetLeft(pill, from);
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        var duration = new Duration(TimeSpan.FromMilliseconds(SlideMs));
        var move = new DoubleAnimation { From = from, To = left, Duration = duration, EasingFunction = ease, EnableDependentAnimation = true };
        var grow = new DoubleAnimation { From = fromWidth, To = width, Duration = duration, EasingFunction = ease, EnableDependentAnimation = true };
        Storyboard.SetTarget(move, pill);
        Storyboard.SetTargetProperty(move, "(Canvas.Left)");
        Storyboard.SetTarget(grow, pill);
        Storyboard.SetTargetProperty(grow, "Width");
        slide = new Storyboard();
        slide.Children.Add(move);
        slide.Children.Add(grow);
        slide.Begin();
    }
}
