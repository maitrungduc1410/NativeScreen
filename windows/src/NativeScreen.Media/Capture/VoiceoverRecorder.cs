using System.Diagnostics;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;

namespace NativeScreen.Media;

/// <summary>
/// Records a voiceover from the default microphone to its own file. The stream opens first and its samples are dropped until
/// <see cref="MarkStart"/>, so time zero of the file is the moment the preview starts moving, however long the device took.
/// Open and stop it off the UI thread (spec/06 ADR-23, ADR-40).
/// </summary>
public sealed class VoiceoverRecorder : IDisposable
{
    private readonly AudioTrackRecorder track;
    private double originMs = double.NaN;

    private VoiceoverRecorder(string path)
    {
        using var enumerator = new MMDeviceEnumerator();
        using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
        track = AudioTrackRecorder.TryMicrophone(device.ID, path, ElapsedSinceStart) ?? throw new COMException("The microphone did not open.");
    }

    /// <summary>Time since <see cref="MarkStart"/>.</summary>
    public double ElapsedMs
    {
        get
        {
            var origin = Volatile.Read(ref originMs);
            return double.IsNaN(origin) ? 0 : NowMs() - origin;
        }
    }

    /// <summary>Null when there is no microphone or it cannot be opened, for example when privacy settings block it.</summary>
    public static VoiceoverRecorder? TryStart(string path)
    {
        try
        {
            return new VoiceoverRecorder(path);
        }
        catch (Exception exception) when (exception is COMException or UnauthorizedAccessException or ArgumentException or InvalidOperationException)
        {
            return null;
        }
    }

    public void MarkStart() => Volatile.Write(ref originMs, NowMs());

    /// <summary>Stops the stream and finishes the file at the given length.</summary>
    public void Stop(double durationMs) => track.Stop(durationMs);

    public void Dispose() => track.Dispose();

    private static double NowMs() => Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency;

    private double? ElapsedSinceStart(double hostMs)
    {
        var origin = Volatile.Read(ref originMs);
        return double.IsNaN(origin) ? null : Math.Max(0, hostMs - origin);
    }
}
