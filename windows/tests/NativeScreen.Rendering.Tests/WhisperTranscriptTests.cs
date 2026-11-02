using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using NativeScreen.Core;
using NativeScreen.Intelligence;
using Windows.Media.SpeechSynthesis;
using Windows.Storage.Streams;

namespace NativeScreen.Rendering.Tests;

/// <summary>The real model on speech from the Windows voice. NS_TEST_WHISPER=1 downloads the base model once, 142 MB.</summary>
public sealed class WhisperTranscriptTests : IDisposable
{
    private readonly string directory = Directory.CreateTempSubdirectory("ns-whisper-").FullName;

    public void Dispose() => Directory.Delete(directory, recursive: true);

    private static void Progress(string step)
    {
        using var file = new FileStream(Path.Combine(Path.GetTempPath(), "ns-whisper-progress.txt"), FileMode.Append, FileAccess.Write, FileShare.Read, 1, FileOptions.WriteThrough);
        file.Write(System.Text.Encoding.UTF8.GetBytes($"{DateTime.Now:HH:mm:ss} {step}\n"));
    }

    private static async Task<(string Path, double DurationMs)> Speak(string folder, string text)
    {
        using var synthesizer = new SpeechSynthesizer();
        using var stream = await synthesizer.SynthesizeTextToStreamAsync(text);
        var bytes = new byte[stream.Size];
        using (var reader = new DataReader(stream))
        {
            await reader.LoadAsync((uint)stream.Size);
            reader.ReadBytes(bytes);
        }

        var path = Path.Combine(folder, "speech.wav");
        await File.WriteAllBytesAsync(path, bytes);
        var sampleRate = BitConverter.ToInt32(bytes, 24);
        var bytesPerSecond = BitConverter.ToInt32(bytes, 28);
        Progress($"speech {bytes.Length} bytes at {sampleRate} Hz");
        return (path, (bytes.Length - 44) * 1000.0 / bytesPerSecond);
    }

    /// <summary>What a recording really holds: AAC at 48 kHz in a fragmented MP4, with speech starting 2 s in.</summary>
    [Fact]
    public async Task SpeechInARecordingKeepsItsTimes()
    {
        var model = WhisperModel.ForTier("base");
        if (Environment.GetEnvironmentVariable("NS_TEST_WHISPER") != "1" || !model.IsInstalled)
        {
            return;
        }

        const int SilenceMs = 2000;
        var (wav, speechMs) = await Speak(directory, "Open the project, then press the export button.");
        var bytes = await File.ReadAllBytesAsync(wav);
        var pcm = new NativeScreen.Core.PcmConverter(BitConverter.ToInt32(bytes, 24), 1, false, 16, 48000, 2).Convert(bytes.AsSpan(44)).ToArray();
        var path = Path.Combine(directory, "display.mp4");
        var totalMs = SilenceMs + speechMs + 1000;
        using (var writer = new Media.VideoFileWriter(path, 320, 180, 30, 1_000_000, false, true, new Media.AudioFormat(48000, 2, 192_000)))
        {
            var nv12 = new byte[320 * 180 * 3 / 2];
            var block = new byte[1600 * 4];
            for (var frame = 0; frame * 1000.0 / 30 < totalMs; frame++)
            {
                Array.Clear(block);
                var from = (frame * 1600 - SilenceMs * 48) * 2;
                for (var i = 0; i < 3200; i++)
                {
                    var at = from + i;
                    if (at >= 0 && at < pcm.Length)
                    {
                        BitConverter.TryWriteBytes(block.AsSpan(i * 2), pcm[at]);
                    }
                }

                writer.WriteFrame(nv12, frame * 1000.0 / 30, 1000.0 / 30);
                writer.WriteAudio(block, frame * 1000.0 / 30, 1000.0 / 30);
            }
        }

        // Does the audio reader have the fragment time problem of ADR-22?
        using (var reader = new Media.AudioFileReader(path))
        {
            var samples = 0L;
            var worst = 0.0;
            while (reader.ReadBlock() is { } read)
            {
                worst = Math.Max(worst, Math.Abs(read.StartMs - samples * 1000.0 / reader.SampleRate));
                samples += read.Samples.Length / reader.Channels;
            }

            Progress($"audio reader: {samples * 1000.0 / reader.SampleRate:F0} ms read, worst difference from sample count {worst:F1} ms");
        }

        var segments = await WhisperTranscriber.TranscribeAsync(path, model, "en_US", "", totalMs, null, CancellationToken.None);
        Progress(string.Join(' ', segments.Select(segment => $"{segment.Text}@{segment.SourceStartMs:F0}")));
        var text = string.Join(' ', segments.Select(segment => segment.Text)).ToLowerInvariant();
        Assert.Contains("export", text);
        Assert.Contains("button", text);
        Assert.InRange(segments[0].SourceStartMs, SilenceMs - 500, SilenceMs + 500);
    }

    [Fact]
    public async Task TheModelDownloadsAndTranscribesWordsWithTimes()
    {
        if (Environment.GetEnvironmentVariable("NS_TEST_WHISPER") != "1")
        {
            return;
        }

        var model = WhisperModel.ForTier("base");
        Progress($"installed already: {model.IsInstalled}");
        if (!model.IsInstalled)
        {
            var clock = Stopwatch.StartNew();
            await model.DownloadAsync(null, CancellationToken.None);
            Progress($"downloaded in {clock.Elapsed.TotalSeconds:F0} s");
        }

        Assert.True(model.IsInstalled);
        var (path, durationMs) = await Speak(directory, "Hello everyone. Today I will show you how the export window works. First open the project, then press the export button.");
        var timer = Stopwatch.StartNew();
        var segments = await WhisperTranscriber.TranscribeAsync(path, model, "en_US", "", durationMs, null, CancellationToken.None);
        Progress($"transcribed {durationMs:F0} ms of speech in {timer.ElapsedMilliseconds} ms");
        var text = string.Join(' ', segments.Select(segment => segment.Text));
        Progress(text);
        Progress(string.Join(' ', segments.Take(8).Select(segment => $"{segment.Text}@{segment.SourceStartMs:F0}-{segment.SourceEndMs:F0}")));

        var lower = text.ToLowerInvariant();
        foreach (var word in new[] { "hello", "export", "project", "button" })
        {
            Assert.Contains(word, lower);
        }

        Assert.True(segments.Count >= 15, $"expected separate words, got {segments.Count}");
        for (var index = 1; index < segments.Count; index++)
        {
            Assert.True(segments[index].SourceStartMs >= segments[index - 1].SourceStartMs);
        }

        Assert.All(segments, segment => Assert.InRange(segment.SourceEndMs, 0, durationMs));
        Assert.True(segments[^1].SourceEndMs > durationMs * 0.7, "the times do not reach the end of the speech");

        // Words must be usable by the transcript editor.
        var document = new ProjectDocument();
        document.Timeline.Slices = [new ClipSlice { Id = "s", SourceStartMs = 0, SourceEndMs = durationMs }];
        document.Captions.Segments = segments;
        Assert.NotEmpty(TranscriptEditing.FormatSrt(segments, new NLETimeMapper(document.Timeline.Slices)));
    }
}
