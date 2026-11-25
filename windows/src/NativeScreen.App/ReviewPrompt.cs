using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
#if NS_STORE
using Windows.Services.Store;
#endif

namespace NativeScreen.App;

/// <summary>
/// Asks for a Store rating with the system dialog, right after a video export succeeds (spec/06 ADR-111). Same rules as
/// <c>ReviewPrompt.swift</c>. Only the Store build asks; the Velopack build has no Store page to rate. Unlike macOS, Windows
/// puts no limit on how often the dialog shows, so the limits here are the only ones, and the result tells whether the
/// user rated.
/// </summary>
internal static partial class ReviewPrompt
{
#if NS_STORE
    /// <summary>Successful video exports before the first ask.</summary>
    private const int ExportsBeforeAsking = 5;

    /// <summary>Days since the first successful export, so the user has come back to the app at least once.</summary>
    private const double DaysAfterFirstExport = 3;

    /// <summary>Days between asks after the user closed the dialog without rating, on top of once per app version.</summary>
    private const double DaysBetweenAsks = 120;

    /// <summary>So the dialog does not cover the export toast.</summary>
    private static readonly TimeSpan Delay = TimeSpan.FromSeconds(1.5);

    /// <summary>The app's Store page with the review dialog, for when the dialog itself fails.</summary>
    private static readonly Uri ReviewPageUri = new("ms-windows-store://review/?ProductId=9NXXNDRD06WQ");

    private static bool asking;

    /// <summary>Whether Settings shows its rating button: only an installed Store package can be rated.</summary>
    public static bool IsAvailable => AppPackage.IsPackaged;

    /// <summary>
    /// The Settings button. The same dialog as the automatic ask, which on Windows always shows when asked; if it fails,
    /// the Store page opens instead, since a button the user pressed must never do nothing.
    /// </summary>
    public static async Task RateFromSettings(Window owner)
    {
        if (asking)
        {
            return;
        }

        asking = true;
        try
        {
            var context = StoreContext.GetDefault();
            WinRT.Interop.InitializeWithWindow.Initialize(context, WinRT.Interop.WindowNative.GetWindowHandle(owner));
            var result = await context.RequestRateAndReviewAppAsync();
            Record(result.Status);
            if (result.Status is StoreRateAndReviewStatus.Succeeded or StoreRateAndReviewStatus.CanceledByUser)
            {
                return;
            }
        }
        catch (Exception exception) when (exception is COMException or InvalidOperationException)
        {
            CrashLog.Note($"review prompt failed: 0x{exception.HResult:X8}");
        }
        finally
        {
            asking = false;
        }

        await Windows.System.Launcher.LaunchUriAsync(ReviewPageUri);
    }

    /// <summary>Called once per successful video export. <paramref name="canAsk"/> is false once the window closed or is busy again.</summary>
    public static async Task NoteSuccessfulExport(Window owner, Func<bool> canAsk)
    {
        var settings = AppSettings.Shared;
        settings.ReviewFirstExportUtc ??= DateTimeOffset.UtcNow;
        settings.ReviewSuccessfulExports++;
        settings.Save();
        if (asking || !AppPackage.IsPackaged || !IsDue(settings))
        {
            return;
        }

        asking = true;
        try
        {
            await Task.Delay(Delay);
            var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(owner);
            // Never over another app or in the middle of something; the next export tries again.
            if (!canAsk() || RecordingHudWindow.IsRecording || GetForegroundWindow() != hwnd || !IsDue(settings))
            {
                return;
            }

            var context = StoreContext.GetDefault();
            WinRT.Interop.InitializeWithWindow.Initialize(context, hwnd); // VERIFY: the dialog opens over the editor in a Store install (a sideloaded package gets no dialog).
            var result = await context.RequestRateAndReviewAppAsync();
            Record(result.Status);
        }
        // A sideloaded package (not from the Store) gets no dialog and nothing is counted; from Settings the Store page opens instead.
        catch (Exception exception) when (exception is COMException or InvalidOperationException)
        {
            CrashLog.Note($"review prompt failed: 0x{exception.HResult:X8}");
        }
        finally
        {
            asking = false;
        }
    }

    private static void Record(StoreRateAndReviewStatus status)
    {
        CrashLog.Note($"review prompt: {status}");
        var settings = AppSettings.Shared;
        switch (status)
        {
            case StoreRateAndReviewStatus.Succeeded:
                settings.ReviewSubmitted = true;
                break;
            case StoreRateAndReviewStatus.CanceledByUser:
                settings.ReviewLastAskedUtc = DateTimeOffset.UtcNow;
                settings.ReviewLastAskedVersion = AppPackage.Version;
                break;
            default:
                // Offline or a Store error: the user saw nothing useful, so it does not count as an ask.
                return;
        }

        settings.Save();
    }

    private static bool IsDue(AppSettings settings)
    {
        // Lets the verifier see the dialog without waiting days (windows/AGENTS.md §3).
        if (Environment.GetEnvironmentVariable("NS_REVIEW_PROMPT") == "1")
        {
            return true;
        }

        var now = DateTimeOffset.UtcNow;
        if (settings.ReviewSubmitted
            || settings.ReviewSuccessfulExports < ExportsBeforeAsking
            || settings.ReviewFirstExportUtc is not { } first
            || (now - first).TotalDays < DaysAfterFirstExport
            || settings.ReviewLastAskedVersion == AppPackage.Version)
        {
            return false;
        }

        return settings.ReviewLastAskedUtc is not { } last || (now - last).TotalDays >= DaysBetweenAsks;
    }

    [LibraryImport("user32.dll")]
    private static partial nint GetForegroundWindow();
#else
    public static bool IsAvailable => false;

    public static Task NoteSuccessfulExport(Window owner, Func<bool> canAsk) => Task.CompletedTask;

    public static Task RateFromSettings(Window owner) => Task.CompletedTask;
#endif
}
