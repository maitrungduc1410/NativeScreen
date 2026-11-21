using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace NativeScreen.App;

/// <summary>
/// Shown once at launch after a crash: when it was, and the log folder and report a bug report needs (spec/06 ADR-98). A
/// small window of its own, because the app starts with only the recording bar, too small to host a dialog.
/// </summary>
internal sealed class CrashNoticeWindow : Window
{
    private CrashNoticeWindow(FileInfo crash)
    {
        Title = "Native Screen";
        var body = new StackPanel { Spacing = 16, Padding = new Thickness(24, 20, 24, 20) };
        var message = Ui.Text(Loc.F("Native Screen closed unexpectedly on %@.", CrashLog.TimeOf(crash).ToString("g", System.Globalization.CultureInfo.CurrentCulture)), 14, "Ink95");
        message.TextWrapping = TextWrapping.Wrap;
        body.Children.Add(message);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(Ui.Option("Open log folder", false, () => Done(CrashReports.OpenLogFolder)));
        buttons.Children.Add(Ui.Option("Copy crash report", false, () => Done(CrashReports.CopyNewest)));
        buttons.Children.Add(Ui.Option("Close", false, Close));
        body.Children.Add(buttons);
        Content = new Grid { Background = Ui.Pal("SurfaceModal"), Children = { body } };
        AppTheme.Register(this);
        Ui.SizeWindow(this, 520, 150, 420, 140);
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter)
        {
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
            presenter.IsResizable = false;
        }
    }

    /// <summary>Shows the notice when the newest crash is newer than the last one the user saw, and marks it seen.</summary>
    public static void ShowIfNew()
    {
        if (CrashLog.NewestCrash() is not { } crash || string.CompareOrdinal(crash.Name, AppSettings.Shared.LastSeenCrashLog ?? "") <= 0)
        {
            return;
        }

        // Any answer, closing the window included, counts as seen; marked now so a crash while it is open is not shown twice.
        AppSettings.Shared.LastSeenCrashLog = crash.Name;
        AppSettings.Shared.Save();
        new CrashNoticeWindow(crash).Activate();
    }

    private void Done(Action action)
    {
        action();
        Close();
    }
}

/// <summary>What the crash notice and Settings > General > Troubleshooting do with the crash files.</summary>
internal static class CrashReports
{
    /// <summary>Explorer with the newest crash file selected, or the log folder when there is none.</summary>
    public static void OpenLogFolder()
    {
        string arguments;
        if (CrashLog.NewestCrash() is { } crash)
        {
            arguments = $"/select,\"{CrashLog.ForExplorer(crash.FullName)}\"";
        }
        else
        {
            Directory.CreateDirectory(CrashLog.Folder);
            arguments = $"\"{CrashLog.ForExplorer(CrashLog.Folder)}\"";
        }

        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", arguments) { UseShellExecute = true })?.Dispose();
    }

    /// <summary>The newest crash file's text on the clipboard.</summary>
    public static void CopyNewest()
    {
        if (CrashLog.NewestCrash() is not { } crash)
        {
            return;
        }

        var package = new DataPackage();
        package.SetText(File.ReadAllText(crash.FullName));
        Clipboard.SetContent(package);
        Clipboard.Flush();
    }
}
