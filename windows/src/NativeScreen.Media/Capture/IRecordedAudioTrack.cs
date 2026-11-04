namespace NativeScreen.Media;

/// <summary>An audio track being written during a recording.</summary>
public interface IRecordedAudioTrack : IDisposable
{
    /// <summary>Stops capture and pads to the recording's end, so every track has the same length.</summary>
    void Stop(double durationMs);
}
