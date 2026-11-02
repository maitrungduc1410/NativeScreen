using NativeScreen.Core;
using NativeScreen.Media;
using Whisper.net;

namespace NativeScreen.Intelligence;

public sealed record WhisperModel(string Tier, string FileName, string SizeText, long Bytes)
{
    public static IReadOnlyList<WhisperModel> All { get; } =
    [
        new("base", "ggml-base.bin", "142 MB", 147_951_465),
        new("small", "ggml-small.bin", "466 MB", 487_601_967),
        new("medium", "ggml-medium.bin", "1.5 GB", 1_533_774_781)
    ];

    public static WhisperModel ForTier(string tier) => All.FirstOrDefault(model => model.Tier == tier) ?? All[1];

    public static string Directory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NativeScreen", "WhisperModels");

    public string LocalPath => Path.Combine(Directory, FileName);

    public bool IsInstalled => File.Exists(LocalPath) && new FileInfo(LocalPath).Length == Bytes;

    public Uri DownloadUrl => new($"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{FileName}");

    /// <summary>Only ever called after the person agreed to the download. A partial file never counts as installed.</summary>
    public async Task DownloadAsync(IProgress<double>? progress, CancellationToken cancel)
    {
        System.IO.Directory.CreateDirectory(Directory);
        var partial = LocalPath + ".part";
        using var client = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        using var response = await client.GetAsync(DownloadUrl, HttpCompletionOption.ResponseHeadersRead, cancel);
        response.EnsureSuccessStatusCode();
        await using (var source = await response.Content.ReadAsStreamAsync(cancel))
        await using (var target = new FileStream(partial, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, FileOptions.Asynchronous))
        {
            var buffer = new byte[1 << 16];
            var written = 0L;
            int read;
            while ((read = await source.ReadAsync(buffer, cancel)) > 0)
            {
                await target.WriteAsync(buffer.AsMemory(0, read), cancel);
                written += read;
                progress?.Report(written / (double)Bytes);
            }
        }

        if (new FileInfo(partial).Length != Bytes)
        {
            File.Delete(partial);
            throw new IOException("The download was incomplete.");
        }

        File.Move(partial, LocalPath, overwrite: true);
    }
}

/// <summary>Speech to word timings with whisper.cpp, on the CPU and off the UI thread.</summary>
public static class WhisperTranscriber
{
    public static async Task<List<CaptionSegment>> TranscribeAsync(string audioPath, WhisperModel model, string locale, string prompt, double durationMs, IProgress<double>? progress, CancellationToken cancel)
    {
        return await Task.Run(
            async () =>
            {
                var samples = MediaAssets.ReadSpeechAudio(audioPath, cancel);
                using var factory = WhisperFactory.FromPath(model.LocalPath);
                // Half the cores: transcription runs for minutes, and this must not make the machine unusable meanwhile.
                var builder = factory.CreateBuilder()
                    .WithThreads(Math.Max(1, Environment.ProcessorCount / 2))
                    .WithTokenTimestamps()
                    .SplitOnWord()
                    .WithMaxSegmentLength(1)
                    .WithProbabilities();
                var language = locale.Split('_', '-')[0];
                builder = language.Length == 2 ? builder.WithLanguage(language) : builder.WithLanguageDetection();
                if (!string.IsNullOrWhiteSpace(prompt))
                {
                    builder = builder.WithPrompt(prompt);
                }

                using var processor = builder.Build();
                var words = new List<(string, double, double)>();
                await foreach (var segment in processor.ProcessAsync(samples, cancel))
                {
                    words.Add((segment.Text, segment.Start.TotalMilliseconds, segment.End.TotalMilliseconds));
                    progress?.Report(Math.Min(1, segment.End.TotalMilliseconds / Math.Max(1, durationMs)));
                }

                return TranscriptSegments.Normalize(words, durationMs);
            },
            cancel);
    }
}
