using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace NativeScreen.App;

public sealed partial class SettingsWindow : Window
{
    public SettingsWindow()
    {
        InitializeComponent();
        AppTheme.Apply(this);
        DarkTheme.IsOn = AppTheme.Current == ElementTheme.Dark;
    }

    private void ThemeToggled(object sender, RoutedEventArgs e)
    {
        AppTheme.Current = DarkTheme.IsOn ? ElementTheme.Dark : ElementTheme.Light;
        AppTheme.Apply(this);
    }
}
