using Microsoft.UI.Xaml;
using NativeScreen.Core;
using Windows.Storage.Pickers;

namespace NativeScreen.App;

public sealed partial class WelcomeWindow : Window
{
    public WelcomeWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        AppTheme.Apply(this);
    }

    private async void OpenProject(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add(".json");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        var file = await picker.PickSingleFileAsync();
        if (file is null)
        {
            return;
        }

        var directory = Path.GetDirectoryName(file.Path) ?? file.Path;
        if (string.Equals(file.Name, "project.json", StringComparison.OrdinalIgnoreCase))
        {
            directory = Path.GetDirectoryName(directory) ?? directory;
        }

        var project = new LoadedProject(directory);
        var editor = new EditorWindow(project);
        editor.Activate();
    }

    private void OpenSettings(object sender, RoutedEventArgs e)
    {
        var settings = new SettingsWindow();
        settings.Activate();
    }
}
