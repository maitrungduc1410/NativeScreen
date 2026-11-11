using NativeScreen.Intelligence;

namespace NativeScreen.App;

/// <summary>A model the app downloads once on request: the person matting network or a Whisper tier.</summary>
internal sealed record DownloadableModel(string Key, string SizeText, string LocalPath, Func<bool> IsInstalled, Func<IProgress<double>?, CancellationToken, Task> Download)
{
    public static DownloadableModel Person { get; } = new("person", PersonSegmentationModel.SizeText, PersonSegmentationModel.LocalPath, () => PersonSegmentationModel.IsInstalled, PersonSegmentationModel.DownloadAsync);

    public static DownloadableModel Speech(WhisperModel model) => new("whisper-" + model.Tier, model.SizeText, model.LocalPath, () => model.IsInstalled, model.DownloadAsync);
}

/// <summary>
/// The model downloads of the whole app, so every editor shows the same progress and any of them can cancel it. A model is
/// downloaded once at a time; starting it again joins the running download. UI thread only: progress is reported through
/// <see cref="Progress{T}"/>, which posts back to it.
/// </summary>
internal static class ModelDownloads
{
    private sealed class Running(CancellationTokenSource cancel)
    {
        public CancellationTokenSource Cancel { get; } = cancel;
        public double Share { get; set; }
        public Task<(bool Installed, string? Error)>? Task { get; set; }
    }

    private static readonly Dictionary<string, Running> running = [];

    /// <summary>A download started, finished, was cancelled, or a model was deleted.</summary>
    public static event Action? Changed;

    /// <summary>A running download moved on by at least a percent: its key and share done (0...1).</summary>
    public static event Action<string, double>? ProgressChanged;

    /// <summary>Share done of a running download, or null when it is not downloading.</summary>
    public static double? Progress(DownloadableModel model) => running.TryGetValue(model.Key, out var download) ? download.Share : null;

    /// <summary>Downloads the model, or joins its running download. Cancelling gives (false, null); a failure, its reason.</summary>
    public static Task<(bool Installed, string? Error)> Download(DownloadableModel model)
    {
        if (running.TryGetValue(model.Key, out var known) && known.Task is { } joined)
        {
            return joined;
        }

        var download = new Running(new CancellationTokenSource());
        running[model.Key] = download;
        download.Task = Run(model, download);
        Changed?.Invoke();
        return download.Task;
    }

    private static async Task<(bool Installed, string? Error)> Run(DownloadableModel model, Running download)
    {
        var progress = new Progress<double>(share =>
        {
            // About a hundred redraws for the whole file, not one per 64 KB block.
            if (Math.Floor(share * 100) > Math.Floor(download.Share * 100))
            {
                download.Share = share;
                ProgressChanged?.Invoke(model.Key, share);
            }
        });
        try
        {
            await model.Download(progress, download.Cancel.Token);
            return (true, null);
        }
        catch (OperationCanceledException)
        {
            return (false, null);
        }
        catch (Exception exception) when (exception is IOException or HttpRequestException or UnauthorizedAccessException)
        {
            return (false, exception.Message);
        }
        finally
        {
            running.Remove(model.Key);
            download.Cancel.Dispose();
            Changed?.Invoke();
        }
    }

    public static void Cancel(DownloadableModel model)
    {
        if (running.TryGetValue(model.Key, out var download))
        {
            download.Cancel.Cancel();
        }
    }

    /// <summary>Removes the downloaded file. Null when it is gone, otherwise why it could not be removed (a model in use).</summary>
    public static string? Delete(DownloadableModel model)
    {
        try
        {
            File.Delete(model.LocalPath);
            return null;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return exception.Message;
        }
        finally
        {
            Changed?.Invoke();
        }
    }
}
