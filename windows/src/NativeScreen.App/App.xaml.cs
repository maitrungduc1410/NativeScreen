using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace NativeScreen.App;

public partial class App : Application
{
    private Window? welcome;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        welcome = new WelcomeWindow();
        welcome.Activate();
    }
}
