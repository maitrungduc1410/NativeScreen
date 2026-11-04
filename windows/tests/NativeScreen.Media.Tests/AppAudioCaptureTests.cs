using System.Diagnostics;
using NAudio.Wave;

namespace NativeScreen.Media.Tests;

/// <summary>Plays a quiet tone in another process and records only that process. NS_TEST_APP_AUDIO=1; opens no microphone.</summary>
public sealed class AppAudioCaptureTests
{
    private const double ToneRms = 0.01 * 0.7071;

    private static double Now() => Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency;

    private static double RecordRms(int processId, int milliseconds, out bool complete)
    {
        var origin = Now();
        var samples = new List<float>();
        var track = new AppAudioTrackRecorder([processId], (data, length, _, _) =>
        {
            for (var i = 0; i + 3 < length; i += 4)
            {
                samples.Add(BitConverter.ToInt16(data, i) / 32768f);
            }
        }, host => host - origin);
        Thread.Sleep(milliseconds);
        track.Stop(Now() - origin);
        track.Dispose();
        complete = track.IsComplete;
        var tail = samples.Skip(samples.Count / 2).ToList();
        return tail.Count == 0 ? 0 : Math.Sqrt(tail.Sum(item => (double)item * item) / tail.Count);
    }

    [Fact]
    public void AppAudioCaptureHearsTheAppAtAboutItsLevelAndCanRestart()
    {
        if (Environment.GetEnvironmentVariable("NS_TEST_APP_AUDIO") != "1" || !AudioApps.IsPerAppSupported)
        {
            return;
        }

        var wav = Path.Combine(Path.GetTempPath(), $"ns-app-audio-{Environment.ProcessId}.wav");
        using (var writer = new WaveFileWriter(wav, new WaveFormat(48000, 16, 2)))
        {
            for (var i = 0; i < 48000 * 7; i++)
            {
                var value = (float)(0.01 * Math.Sin(i * 2 * Math.PI * 440 / 48000));
                writer.WriteSample(value);
                writer.WriteSample(value);
            }
        }

        using var player = Process.Start(new ProcessStartInfo("powershell", $"-NoProfile -Command \"(New-Object System.Media.SoundPlayer '{wav}').PlaySync()\"") { CreateNoWindow = true, UseShellExecute = false })!;
        try
        {
            Thread.Sleep(900);
            var first = RecordRms(player.Id, 1200, out var firstComplete);
            var restarted = RecordRms(player.Id, 1200, out var restartComplete);
            File.AppendAllText(Path.Combine(Path.GetTempPath(), "ns-app-audio-report.txt"), $"tone {ToneRms:F5}; first {first:F5}; restarted {restarted:F5}\n");
            Assert.True(firstComplete && restartComplete, "a stream did not open");
            Assert.InRange(first, ToneRms / 3, ToneRms * 3);
            Assert.InRange(restarted, ToneRms / 3, ToneRms * 3);
        }
        finally
        {
            player.WaitForExit(8000);
            File.Delete(wav);
        }
    }
}
