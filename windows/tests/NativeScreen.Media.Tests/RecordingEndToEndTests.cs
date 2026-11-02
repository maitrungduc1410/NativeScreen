using NativeScreen.Core;
using NativeScreen.Media;

namespace NativeScreen.Media.Tests;

/// <summary>Real capture from this machine's screen, speakers, microphone and camera, so it only runs when asked: NS_TEST_CAPTURE=1.</summary>
public sealed class RecordingEndToEndTests : IDisposable
{
    private readonly string directory = Directory.CreateTempSubdirectory("ns-record-").FullName;

    public void Dispose() => Directory.Delete(directory, recursive: true);

    private static bool Enabled => Environment.GetEnvironmentVariable("NS_TEST_CAPTURE") == "1";

    [Fact]
    public void DisplayRecordingProducesASyncedPackageAcrossAPause()
    {
        if (!Enabled)
        {
            return;
        }

        var display = CaptureTargets.Displays()[0];
        var target = new CaptureTarget(CaptureTargetMode.Display, display, null, display.Bounds);
        var package = RecordingPackage.Create(directory, DateTime.Now);
        // NS_TEST_CAPTURE_PARTS lists what runs besides the screen: system, mic, camera.
        var parts = Environment.GetEnvironmentVariable("NS_TEST_CAPTURE_PARTS") ?? "";
        var microphone = parts.Contains("mic") ? AudioTrackRecorder.Microphones().FirstOrDefault()?.Id : null;
        var camera = parts.Contains("camera") ? WebcamRecorder.Cameras().FirstOrDefault()?.Id : null;
        double duration;
        RecordingStats stats;
        bool hasCamera, hasMic, hasSystem;
        Progress("start " + parts);
        using (var recorder = new ScreenRecorder(new RecordingOptions(target, package, parts.Contains("system"), microphone, camera)))
        {
            Progress("constructed");
            Assert.True(recorder.WaitForFirstFrame());
            Progress("first frame");
            Thread.Sleep(2000);
            recorder.SetPaused(true);
            Thread.Sleep(1000);
            recorder.SetPaused(false);
            Thread.Sleep(2000);
            Progress("stopping");
            recorder.Stop();
            Progress("stopped");
            duration = recorder.DurationMs;
            stats = recorder.Stats;
            (hasCamera, hasMic, hasSystem) = (recorder.HasWebcam, recorder.HasMicrophone, recorder.HasSystemAudio);
        }

        Progress("disposed");

        RecordingPackage.Finish(package, target.Metadata("Test"), duration, hasCamera, hasMic, hasSystem, true, DateTimeOffset.UtcNow);
        var report = new List<string>
        {
            $"display {target.OutputWidth}x{target.OutputHeight} duration {duration:F0} written {stats.FramesWritten} repeated {stats.FramesRepeated} dropped {stats.FramesDropped} convert {stats.ConvertMsAverage:F2} ms",
            $"camera {hasCamera} mic {hasMic} system {hasSystem}"
        };
        try
        {
            Assert.InRange(duration, 3800, 4800);

            var recording = Path.Combine(package, "recording");
            var times = Times(Path.Combine(recording, "display.mp4"), report, "display");
            Assert.InRange(times[^1], duration - 300, duration + 300);
            Assert.Equal(0, times[0], 1);

            var cursor = JsonLines.Load<CursorSampleEvent>(Path.Combine(recording, "telemetry", "cursor.jsonl"));
            Assert.Equal(0, cursor[0].T);
            var gaps = cursor.Zip(cursor.Skip(1), (a, b) => b.T - a.T).ToList();
            report.Add($"cursor {cursor.Count} samples, gap avg {gaps.Average():F1} max {gaps.Max():F1}, last {cursor[^1].T:F0}");
            Assert.All(gaps, gap => Assert.True(gap >= 0));
            Assert.InRange(cursor[^1].T, duration - 300, duration + 300);
            Assert.InRange(gaps.Average(), 5, 25);
            Assert.True(gaps.Max() < 250, "the pause leaked into the cursor time");

            if (hasSystem)
            {
                report.Add($"system audio {AudioSeconds(Path.Combine(recording, "display.mp4")):F2} s");
            }

            if (hasMic)
            {
                var seconds = AudioSeconds(Path.Combine(recording, "microphone.m4a"));
                report.Add($"microphone {seconds:F2} s");
                Assert.InRange(seconds, duration / 1000 - 0.4, duration / 1000 + 0.4);
            }

            if (hasCamera)
            {
                var cameraTimes = Times(Path.Combine(recording, "webcam.mp4"), report, "webcam");
                Assert.Equal(0, cameraTimes[0], 1);
                Assert.InRange(cameraTimes[^1], duration - 400, duration + 400);
            }

            var project = new LoadedProject(package);
            Assert.Equal("windows", project.Metadata.Platform);
            Assert.Equal(duration, project.Metadata.DurationMs, 1);
        }
        finally
        {
            File.WriteAllLines(Path.Combine(Path.GetTempPath(), "ns-record-report.txt"), report);
        }
    }

    /// <summary>Written through to disk, so it says how far a run got even when the machine goes down with it.</summary>
    private static void Progress(string step)
    {
        using var file = new FileStream(Path.Combine(Path.GetTempPath(), "ns-record-progress.txt"), FileMode.Append, FileAccess.Write, FileShare.Read, 1, FileOptions.WriteThrough);
        file.Write(System.Text.Encoding.UTF8.GetBytes($"{DateTime.Now:HH:mm:ss.fff} {step}\n"));
    }

    private static List<double> Times(string path, List<string> report, string name)
    {
        using var reader = new VideoFileReader(path);
        var times = new List<double>();
        while (reader.ReadNext() is { } frame)
        {
            times.Add(frame.PresentationMs);
        }

        var gaps = times.Zip(times.Skip(1), (a, b) => b - a).ToList();
        report.Add($"{name} {reader.Width}x{reader.Height} {times.Count} frames, first {times[0]:F1} last {times[^1]:F0}, gap max {gaps.Max():F0}");
        return times;
    }

    private static double AudioSeconds(string path)
    {
        using var audio = new AudioFileReader(path);
        var samples = 0L;
        while (audio.ReadBlock() is { } block)
        {
            samples += block.Samples.Length / audio.Channels;
        }

        return samples / (double)audio.SampleRate;
    }
}
