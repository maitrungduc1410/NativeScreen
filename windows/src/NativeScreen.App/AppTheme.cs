using Microsoft.UI.Xaml;

namespace NativeScreen.App;

public static class AppTheme
{
    public static ElementTheme Current { get; set; } = ElementTheme.Dark;

    public static void Apply(Window window)
    {
        if (window.Content is FrameworkElement root)
        {
            root.RequestedTheme = Current;
        }
    }
}
