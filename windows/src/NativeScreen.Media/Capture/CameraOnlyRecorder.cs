using System.Diagnostics;
using NativeScreen.Core;

namespace NativeScreen.Media;

/// <summary>
/// The Camera capture mode (spec/06 ADR-77): the camera and microphone with no screen. The first usable camera frame is time
/// zero and the microphone counts from it, so pauses and the gap fill work as for a screen recording. The duration is the
/// last written frame plus one frame. The telemetry files are left empty: no cursor, clicks or keys are recorded.
/// </summary>
public sealed class CameraOnlyRecorder : IRecordingEngine
{
    private const int FirstFrameTimeoutMs = 8000;
    private readonly WebcamRecorder webcam;
    private readonly AudioTrackRecorder? microphone;
    private readonly PauseTimeline pause = new();
    private readonly object pauseGate = new();
    private readonly ManualResetEventSlim firstFrame = new();
    private double originMs = double.NaN;
    private CaptureFailure? failure;
    private int stopped;

    public CameraOnlyRecorder(string packageDirectory, string cameraId, int cameraMaxHeight, string? microphoneId)
    {
        var recording = Path.Combine(packageDirectory, "recording");
        var telemetry = Path.Combine(recording, "telemetry");
        Directory.CreateDirectory(telemetry);
        foreach (var name in (ReadOnlySpan<string>)["cursor.jsonl", "clicks.jsonl", "keys.jsonl"])
        {
            File.WriteAllText(Path.Combine(telemetry, name), "");
        }

        webcam = WebcamRecorder.TryStart(cameraId, Path.Combine(recording, "webcam.mp4"), cameraMaxHeight, Elapsed, details => Report(CaptureFailureKind.WebcamWriter, details))
            ?? throw new InvalidOperationException("The camera could not be opened.");
        webcam.FirstUsableFrame = host =>
        {
            Volatile.Write(ref originMs, host);
            firstFrame.Set();
        };
        if (microphoneId is not null)
        {
            microphone = AudioTrackRecorder.TryMicrophone(microphoneId, Path.Combine(recording, "microphone.m4a"), Elapsed, details => Report(CaptureFailureKind.MicrophoneWriter, details));
        }
    }

    public bool HasMicrophone => microphone is not null;

    public bool HasWebcam => true;

    public bool HasSystemAudio => false;

    public bool IsMissingAppAudio => false;

    /// <summary>The camera picture's size and frame rate, for the recording's metadata.</summary>
    public (int Width, int Height, double FrameMs) Format => webcam.Format;

    public double DurationMs { get; private set; }

    public CaptureFailure? Failure => Volatile.Read(ref failure);

    /// <summary>Raised once, on a capture thread, when a writer fails.</summary>
    public event Action<CaptureFailure>? Failed;

    /// <summary>Camera frames for the preview, on the camera's thread. The buffer is reused after the call.</summary>
    public event Action<byte[], int, int>? CameraFrame
    {
        add => webcam.PreviewFrame += value;
        remove => webcam.PreviewFrame -= value;
    }

    /// <summary>Blocks until the camera sent a usable frame. False means it never did.</summary>
    public bool WaitForFirstFrame() => firstFrame.Wait(FirstFrameTimeoutMs);

    public void SetPaused(bool paused)
    {
        lock (pauseGate)
        {
            pause.SetPaused(paused, NowMs());
        }
    }

    public void Stop()
    {
        if (Interlocked.Exchange(ref stopped, 1) != 0)
        {
            return;
        }

        // The last frame plus one frame: what the camera actually delivered, not the moment Stop was pressed.
        DurationMs = double.IsNaN(Volatile.Read(ref originMs)) ? 0 : webcam.LastFrameMs + webcam.Format.FrameMs;
        microphone?.Stop(DurationMs);
        webcam.Stop(DurationMs);
    }

    public void Dispose()
    {
        Stop();
        microphone?.Dispose();
        webcam.Dispose();
        firstFrame.Dispose();
    }

    private static double NowMs() => Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency;

    public double? TimelineMs(double hostMs) => Elapsed(hostMs);

    /// <summary>Position of a host time on the recording's timeline, or null while paused or before the first camera frame.</summary>
    private double? Elapsed(double hostMs)
    {
        var origin = Volatile.Read(ref originMs);
        if (double.IsNaN(origin))
        {
            return null;
        }

        double? offset;
        lock (pauseGate)
        {
            offset = pause.OffsetMs(hostMs);
        }

        return offset is { } paused ? Math.Max(0, hostMs - origin - paused) : null;
    }

    private void Report(CaptureFailureKind kind, string details)
    {
        var next = new CaptureFailure(kind, details);
        if (Volatile.Read(ref stopped) == 0 && Interlocked.CompareExchange(ref failure, next, null) is null)
        {
            Failed?.Invoke(next);
        }
    }
}
