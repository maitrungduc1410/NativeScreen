using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace NativeScreen.App;

public partial class App : Application
{
    private Window? window;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        window = new Window { Title = "Native Screen" };
        window.Content = new TextBlock
        {
            Text = "Native Screen",
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
        // VERIFY: unpackaged WinUI 3 (Windows App SDK 2.6.4, net10.0-windows10.0.22621.0, win-x64) shows this empty window.
        window.Activate();
    }
}
