namespace NativeScreen.Media;

/// <summary>What the recording bar drives: a screen recording or a camera-only one (spec/06 ADR-77).</summary>
public interface IRecordingEngine : IDisposable
{
    bool HasWebcam { get; }

    bool HasMicrophone { get; }

    bool HasSystemAudio { get; }

    /// <summary>A chosen app is missing from the system audio track.</summary>
    bool IsMissingAppAudio { get; }

    double DurationMs { get; }

    CaptureFailure? Failure { get; }

    event Action<CaptureFailure>? Failed;

    event Action<byte[], int, int>? CameraFrame;

    bool WaitForFirstFrame();

    void SetPaused(bool paused);

    void Stop();

    /// <summary>Where a host time (Stopwatch ms) lands on the recording timeline; null while paused or before the first frame.</summary>
    double? TimelineMs(double hostMs);
}
