using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;

namespace NativeScreen.App;

public sealed partial class SettingsWindow : Window
{
    private static readonly string[] TabTitles = ["General", "Recording", "Editing", "Quick export", "Shortcuts"];

    private static readonly (string Action, string Keys)[] ShortcutList =
    [
        ("Play or pause", "Space"),
        ("Split clip at playhead", "C"),
        ("Delete selection", "Delete"),
        ("Undo", "Ctrl+Z"),
        ("Redo", "Ctrl+Shift+Z"),
        ("Save", "Ctrl+S"),
        ("Export", "Ctrl+E"),
        ("Command menu", "Ctrl+K"),
        ("Settings", "Ctrl+,"),
        ("Inspector tabs", "Ctrl+1 to Ctrl+0")
    ];

    private string tab = TabTitles[0];

    /// <summary>The language this run started with, to tell whether a restart is needed.</summary>
    private static readonly string startLanguage = AppSettings.Shared.Language;

    public SettingsWindow()
    {
        InitializeComponent();
        Loc.Apply(Content);
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(DragBar);
        AppTheme.Register(this);
        Ui.SizeWindow(this, 640, 460, 520, 360);
        Refresh();
    }

    private void Refresh()
    {
        Tabs.Children.Clear();
        foreach (var title in TabTitles)
        {
            var target = title;
            Tabs.Children.Add(Ui.Option(title, title == tab, () =>
            {
                tab = target;
                Refresh();
            }));
        }

        Body.Children.Clear();
        switch (tab)
        {
            case "General": General(); break;
            case "Recording": Recording(); break;
            case "Editing": Editing(); break;
            case "Quick export": QuickExport(); break;
            default: Shortcuts(); break;
        }
    }

    private void General()
    {
        Heading("Appearance");
        Options(
            ("Dark", AppTheme.Current == ElementTheme.Dark, () => AppTheme.Set(ElementTheme.Dark)),
            ("Light", AppTheme.Current == ElementTheme.Light, () => AppTheme.Set(ElementTheme.Light)));
        Heading("Language");
        var languages = new ComboBox { MinWidth = 220 };
        A11y.Name(languages, "Language");
        languages.Items.Add(Loc.T("System"));
        foreach (var (_, name) in Loc.Languages)
        {
            languages.Items.Add(name);
        }

        var chosen = Array.FindIndex(Loc.Languages, item => item.Id == AppSettings.Shared.Language);
        languages.SelectedIndex = chosen + 1;
        Body.Children.Add(languages);
        var restart = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Visibility = AppSettings.Shared.Language == startLanguage ? Visibility.Collapsed : Visibility.Visible };
        var note = Ui.Text("Restart Native Screen to use the new language.", 12, "Ink60");
        note.VerticalAlignment = VerticalAlignment.Center;
        restart.Children.Add(note);
        restart.Children.Add(Ui.Option("Restart Now", false, App.Restart));
        Body.Children.Add(restart);
        languages.SelectionChanged += (_, _) =>
        {
            AppSettings.Shared.Language = languages.SelectedIndex <= 0 ? "" : Loc.Languages[languages.SelectedIndex - 1].Id;
            AppSettings.Shared.Save();
            restart.Visibility = AppSettings.Shared.Language == startLanguage ? Visibility.Collapsed : Visibility.Visible;
        };
        Heading("Projects folder");
        Body.Children.Add(Ui.Text(AppSettings.Shared.ProjectsDirectory, 12, "Ink60"));
        Options(("Change", false, () => _ = ChooseProjectsFolder()));
    }

    private async Task ChooseProjectsFolder()
    {
        var picker = new FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (await picker.PickSingleFolderAsync() is { } folder)
        {
            AppSettings.Shared.ProjectsDirectory = folder.Path;
            AppSettings.Shared.Save();
            Refresh();
        }
    }

    private void Recording()
    {
        var settings = AppSettings.Shared;
        Heading("Countdown");
        Options(
            ("Off", settings.CountdownSeconds == 0, () => SetCountdown(0)),
            ("3s", settings.CountdownSeconds == 3, () => SetCountdown(3)),
            ("5s", settings.CountdownSeconds == 5, () => SetCountdown(5)),
            ("10s", settings.CountdownSeconds == 10, () => SetCountdown(10)));
        Heading("Automatically create zooms");
        Options(
            ("On", settings.AutoCreateZooms, () => SetAutoZoom(true)),
            ("Off", !settings.AutoCreateZooms, () => SetAutoZoom(false)));
    }

    private static void SetCountdown(int seconds)
    {
        AppSettings.Shared.CountdownSeconds = seconds;
        AppSettings.Shared.Save();
    }

    private static void SetAutoZoom(bool enabled)
    {
        AppSettings.Shared.AutoCreateZooms = enabled;
        AppSettings.Shared.Save();
    }

    private void Editing()
    {
        Heading("Save automatically");
        Body.Children.Add(Ui.Text("When off, edits are saved with Ctrl+S.", 12, "Ink60"));
        Options(
            ("On", AppSettings.Shared.AutosaveEnabled, () => SetAutosave(true)),
            ("Off", !AppSettings.Shared.AutosaveEnabled, () => SetAutosave(false)));
    }

    private static void SetAutosave(bool enabled)
    {
        AppSettings.Shared.AutosaveEnabled = enabled;
        AppSettings.Shared.Save();
    }

    private void QuickExport()
    {
        Heading("Quick export");
        Body.Children.Add(Ui.Text("Quick export uses the current settings of the Export window: format, frame rate, resolution and compression.", 12.5, "Ink60"));
    }

    private void Shortcuts()
    {
        foreach (var (action, keys) in ShortcutList)
        {
            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(Ui.Text(action, 13, "Ink88"));
            var shortcut = Ui.Text(keys, 12.5, "Ink60");
            Grid.SetColumn(shortcut, 1);
            row.Children.Add(shortcut);
            Body.Children.Add(row);
        }
    }

    private void Heading(string text) => Body.Children.Add(Ui.Text(text, 13, "Ink95", true));

    private void Options(params (string Title, bool Selected, Action Change)[] options)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        foreach (var (title, selected, change) in options)
        {
            var apply = change;
            row.Children.Add(Ui.Option(title, selected, () =>
            {
                apply();
                Refresh();
            }));
        }

        Body.Children.Add(row);
    }
}
