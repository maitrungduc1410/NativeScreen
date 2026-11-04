using System.Diagnostics;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NativeScreen.Core;

namespace NativeScreen.Media;

/// <summary>
/// Live level of a microphone while nothing records it. An endpoint's peak meter only moves while a stream is open, so one is
/// opened and started, and its samples are never read: the audio engine drops them. It adds no capture thread, no event and no
/// copying to a path that has reset a machine (spec/06 ADR-23). Open and dispose it off the UI thread.
/// </summary>
public sealed class MicrophoneLevelMonitor : IDisposable
{
    private const int PollMs = 33;
    private const long BufferHundredNs = 1_000_000;

    private readonly MMDevice device;
    private readonly AudioClient client;
    private readonly AudioMeterInformation levels;
    private readonly MicrophoneLevelMeter meter = new();
    private readonly Timer timer;
    private int polling;
    private volatile bool stopped;

    private MicrophoneLevelMonitor(MMDevice device, AudioClient client)
    {
        this.device = device;
        this.client = client;
        levels = device.AudioMeterInformation;
        client.Start();
        timer = new Timer(_ => Poll(), null, PollMs, PollMs);
    }

    public double Level => meter.Level;

    public double PeakHold => meter.PeakHold;

    /// <summary>Null when the microphone cannot be opened, for example when privacy settings block it.</summary>
    public static MicrophoneLevelMonitor? TryStart(string deviceId)
    {
        MMDevice? device = null;
        AudioClient? client = null;
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            device = enumerator.GetDevice(deviceId);
            client = device.AudioClient;
            client.Initialize(AudioClientShareMode.Shared, AudioClientStreamFlags.None, BufferHundredNs, 0, client.MixFormat, Guid.Empty);
            return new MicrophoneLevelMonitor(device, client);
        }
        catch (Exception exception) when (exception is COMException or UnauthorizedAccessException or ArgumentException)
        {
            client?.Dispose();
            device?.Dispose();
            return null;
        }
    }

    public void Dispose()
    {
        stopped = true;
        timer.Dispose();
        try
        {
            client.Stop();
        }
        catch (COMException)
        {
            // The device went away; there is nothing left to stop.
        }

        client.Dispose();
        device.Dispose();
    }

    private void Poll()
    {
        if (stopped || Interlocked.Exchange(ref polling, 1) == 1)
        {
            return;
        }

        try
        {
            meter.Add(levels.MasterPeakValue, Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency);
        }
        catch (COMException)
        {
            stopped = true;
        }
        finally
        {
            Volatile.Write(ref polling, 0);
        }
    }
}
