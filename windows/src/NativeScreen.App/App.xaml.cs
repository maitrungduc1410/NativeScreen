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

        // Double-clicking a package passes its folder, or the project.json inside it.
        var argument = Environment.GetCommandLineArgs().Skip(1).FirstOrDefault();
        if (argument is not null)
        {
            var folder = File.Exists(argument) ? Path.GetDirectoryName(argument) : argument;
            if (folder is not null && File.Exists(Path.Combine(folder, "project.json")))
            {
                _ = Projects.Open(folder, null);
            }
        }
    }
}
