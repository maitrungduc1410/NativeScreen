using Microsoft.UI.Xaml;

namespace NativeScreen.App;

public sealed partial class SettingsWindow : Window
{
    public SettingsWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(DragBar);
        AppTheme.Register(this);
        Ui.SizeWindow(this, 640, 420, 520, 360);
        Tabs.Children.Add(Ui.Option("General", true, () => { }));
        foreach (var title in new[] { "Recording", "Editing", "Quick export", "Shortcuts" })
        {
            Tabs.Children.Add(Ui.Option(title, false, null));
        }

        FillAppearance();
    }

    private void FillAppearance()
    {
        Appearance.Children.Clear();
        Appearance.Children.Add(Ui.Option("Dark", AppTheme.Current == ElementTheme.Dark, () => Change(ElementTheme.Dark)));
        Appearance.Children.Add(Ui.Option("Light", AppTheme.Current == ElementTheme.Light, () => Change(ElementTheme.Light)));
    }

    private void Change(ElementTheme theme)
    {
        AppTheme.Set(theme);
        FillAppearance();
    }
}
