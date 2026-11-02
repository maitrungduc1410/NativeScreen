using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using NativeScreen.Core;
using Windows.Storage.Pickers;

namespace NativeScreen.App;

public sealed partial class WelcomeWindow : Window
{
    public WelcomeWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(DragBar);
        AppTheme.Register(this);
        Ui.SizeWindow(this, 1040, 640, 860, 560);
        Title = "Native Screen";
        FillRecents();
        AppTheme.Changed += FillRecents;
        Closed += (_, _) => AppTheme.Changed -= FillRecents;
    }

    private void FillRecents()
    {
        RecentList.Children.Clear();
        var recents = AppSettings.Shared.RecentProjects;
        if (recents.Count == 0)
        {
            RecentList.Children.Add(Ui.Text("No recent .nativescreen projects yet.", 13, "Ink60"));
            RecentList.Children.Add(Ui.Text("Click 'Create Interactive Showcase Project' or open a project on the left.", 12, "Ink45"));
            return;
        }

        foreach (var path in recents)
        {
            var target = path;
            var row = new Grid { ColumnSpacing = 12, Padding = new Thickness(10), CornerRadius = new CornerRadius(10), Background = Ui.Pal("Ink04") };
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var text = new StackPanel { Spacing = 2 };
            text.Children.Add(Ui.Text(Path.GetFileNameWithoutExtension(path), 13, "Ink95", true));
            var location = Ui.Text(path, 10.5, "Ink45");
            location.TextWrapping = TextWrapping.NoWrap;
            location.TextTrimming = TextTrimming.CharacterEllipsis;
            text.Children.Add(location);
            row.Children.Add(text);
            var open = new Button { Style = Ui.StyleOf("NsPrimaryButton"), Content = "Open Editor", Height = 30, FontSize = 12, Padding = new Thickness(12, 0, 12, 0) };
            open.Click += (_, _) => _ = OpenPackage(target);
            Grid.SetColumn(open, 1);
            row.Children.Add(open);
            RecentList.Children.Add(row);
        }
    }

    private async void OpenProject(object sender, RoutedEventArgs e)
    {
        // A .nativescreen package is a folder on Windows.
        var picker = new FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        var folder = await picker.PickSingleFolderAsync();
        if (folder is not null)
        {
            await OpenPackage(folder.Path);
        }
    }

    private async Task OpenPackage(string path)
    {
        await Projects.Open(path, Root.XamlRoot);
        FillRecents();
    }

    private async void CreateFromVideo(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        foreach (var type in new[] { ".mp4", ".mov", ".m4v", ".mkv", ".wmv" })
        {
            picker.FileTypeFilter.Add(type);
        }

        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (await picker.PickSingleFileAsync() is { } file)
        {
            await Projects.ImportVideo(file.Path, Root.XamlRoot);
            FillRecents();
        }
    }

    private async void CreateShowcase(object sender, RoutedEventArgs e)
    {
        var directory = AppSettings.Shared.ProjectsDirectory;
        await OpenPackage(ShowcaseProject.WritePackage(directory));
    }

    private void NewRecording(object sender, RoutedEventArgs e) => RecordingHudWindow.Show();

    private void OpenEmptyEditor(object sender, RoutedEventArgs e) => new EditorWindow().Activate();

    private void OpenSettings(object sender, RoutedEventArgs e) => new SettingsWindow().Activate();
}
