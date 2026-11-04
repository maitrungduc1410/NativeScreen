using System.Diagnostics;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NativeScreen.Core;

namespace NativeScreen.Media;

/// <summary>
/// The system audio track when only some apps are recorded: one process loopback stream per app, mixed on the recording
/// timeline. The track is always written, silence included, because the MP4 sink holds video back waiting for audio (spec/06 ADR-23).
/// </summary>
public sealed class AppAudioTrackRecorder : IRecordedAudioTrack
{
    private const int Rate = 48000;
    private const int Channels = 2;
    private const int PumpMs = 20;
    // Long enough for a late packet to still land before its place in the mix is written out.
    private const double MixLatencyMs = 100;
    private const int VolumeCheckMs = 250;
    // The first build the process loopback documentation names. Earlier builds work but deliver the volume-inflated level.
    private const int FirstCalibratedBuild = 20348;

    private readonly Action<byte[], int, double, double> write;
    private readonly Func<double, double?> elapsed;
    private readonly AudioFrameMixer mixer;
    private readonly List<ProcessLoopbackStream> streams = [];
    private readonly short[] mixed = new short[Rate / 10 * Channels];
    private readonly byte[] bytes = new byte[Rate / 10 * Channels * 2];
    private readonly object gate = new();
    private readonly Timer timer;
    private readonly MMDeviceEnumerator? devices;
    private readonly MMDevice? output;
    private long writtenFrames;
    private bool stopped;
    private long nextVolumeCheckMs;
    private float gain = 1;

    /// <param name="write">Takes PCM, its length, its time and its duration in milliseconds.</param>
    public AppAudioTrackRecorder(IReadOnlyList<int> processIds, Action<byte[], int, double, double> write, Func<double, double?> elapsed)
    {
        this.write = write;
        this.elapsed = elapsed;
        mixer = new AudioFrameMixer(Channels, Rate * 2, Math.Max(1, processIds.Count));
        if (Environment.OSVersion.Version.Build < FirstCalibratedBuild)
        {
            (devices, output) = OpenOutput();
            UpdateGain();
        }

        for (var index = 0; index < processIds.Count; index++)
        {
            var source = index;
            if (AudioApps.IsPerAppSupported && ProcessLoopbackStream.TryStart(processIds[index], (samples, count, heardMs) => Deliver(source, samples, count, heardMs), () => Volatile.Read(ref gain)) is { } stream)
            {
                streams.Add(stream);
            }
        }

        IsComplete = processIds.Count > 0 && streams.Count == processIds.Count;
        timer = new Timer(_ => Pump(), null, PumpMs, PumpMs);
    }

    /// <summary>False when an app is missing from the track, because it closed or could not be captured.</summary>
    public bool IsComplete { get; }

    /// <summary>Stops capture and pads to the recording's end, so every track has the same length.</summary>
    public void Stop(double durationMs)
    {
        foreach (var stream in streams)
        {
            stream.Dispose();
        }

        streams.Clear();
        timer.Dispose();
        lock (gate)
        {
            stopped = true;
            WriteUntil((long)(durationMs / 1000 * Rate));
        }
    }

    public void Dispose()
    {
        output?.Dispose();
        devices?.Dispose();
    }

    private static (MMDeviceEnumerator?, MMDevice?) OpenOutput()
    {
        try
        {
            var enumerator = new MMDeviceEnumerator();
            return (enumerator, enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia));
        }
        catch (COMException)
        {
            return (null, null);
        }
    }

    /// <summary>
    /// On these builds the stream arrives as if the output volume had been divided out of it: about 17x louder at -25 dB, while
    /// the all-apps loopback reads true. The recording should not depend on the listener's volume, so it is put back.
    /// </summary>
    private void UpdateGain()
    {
        if (output is null || Environment.TickCount64 < nextVolumeCheckMs)
        {
            return;
        }

        nextVolumeCheckMs = Environment.TickCount64 + VolumeCheckMs;
        try
        {
            Volatile.Write(ref gain, (float)Math.Pow(10, output.AudioEndpointVolume.MasterVolumeLevel / 20));
        }
        catch (COMException)
        {
            // The device went away; the last value stands.
        }
    }

    private void Deliver(int source, short[] samples, int count, double heardMs)
    {
        if (elapsed(heardMs) is { } atMs)
        {
            mixer.Add(source, samples.AsSpan(0, count), (long)(atMs / 1000 * Rate));
        }
    }

    private void Pump()
    {
        lock (gate)
        {
            var now = Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency;
            if (!stopped)
            {
                UpdateGain();
            }

            if (!stopped && elapsed(now) is { } atMs)
            {
                WriteUntil((long)((atMs - MixLatencyMs) / 1000 * Rate));
            }
        }
    }

    private void WriteUntil(long frame)
    {
        while (mixer.Drain(frame, mixed) is var frames and > 0)
        {
            var length = frames * Channels * 2;
            MemoryMarshal.AsBytes(mixed.AsSpan(0, frames * Channels)).CopyTo(bytes);
            write(bytes, length, writtenFrames * 1000.0 / Rate, frames * 1000.0 / Rate);
            writtenFrames += frames;
        }
    }
}
