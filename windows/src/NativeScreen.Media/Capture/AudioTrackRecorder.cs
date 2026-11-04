using System.Diagnostics;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.Dmo;
using NAudio.Wave;
using NativeScreen.Core;

namespace NativeScreen.Media;

public sealed record CaptureDeviceInfo(string Id, string Name, bool IsDefault);

/// <summary>
/// One WASAPI capture stream written to a track on the recording timeline. Loopback delivers nothing while nothing plays and a
/// device can start late, so the position always comes from the clock: gaps become silence and the track never drifts.
/// </summary>
public sealed class AudioTrackRecorder : IRecordedAudioTrack
{
    private const int SampleRate = 48000;
    private const double GapToleranceMs = 40;
    private const double AheadToleranceMs = 200;
    private const int SilenceCheckMs = 50;
    private const double SilenceAfterMs = 150;

    private readonly WasapiCapture capture;
    private readonly Action<byte[], int, double, double> write;
    private readonly Action? finish;
    private readonly Func<double, double?> elapsed;
    private readonly PcmConverter converter;
    private readonly int channels;
    private byte[] bytes = new byte[32768];
    private readonly byte[] silence;
    private long writtenFrames;
    private readonly Timer silenceTimer;

    /// <summary>Output level of the last buffer, 0 to 1, for the recording bar's meter.</summary>
    public double Level { get; private set; }

    private AudioTrackRecorder(WasapiCapture capture, int channels, Action<byte[], int, double, double> write, Action? finish, Func<double, double?> elapsed)
    {
        this.capture = capture;
        this.channels = channels;
        this.write = write;
        this.finish = finish;
        this.elapsed = elapsed;
        silence = new byte[channels * 2 * SampleRate / 10];
        var format = capture.WaveFormat;
        var isFloat = format.Encoding == WaveFormatEncoding.IeeeFloat
            || (format is WaveFormatExtensible extensible && extensible.SubFormat == AudioMediaSubtypes.MEDIASUBTYPE_IEEE_FLOAT);
        converter = new PcmConverter(format.SampleRate, format.Channels, isFloat, format.BitsPerSample, SampleRate, channels);
        capture.DataAvailable += DataAvailable;
        silenceTimer = new Timer(_ => FillSilence(), null, SilenceCheckMs, SilenceCheckMs);
        capture.StartRecording();
    }

    public static IReadOnlyList<CaptureDeviceInfo> Microphones()
    {
        using var enumerator = new MMDeviceEnumerator();
        var fallback = enumerator.HasDefaultAudioEndpoint(DataFlow.Capture, Role.Communications)
            ? enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications).ID
            : null;
        return enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active)
            .Select(device => new CaptureDeviceInfo(device.ID, device.FriendlyName, device.ID == fallback))
            .ToList();
    }

    internal static AudioTrackRecorder? TryLoopback(VideoFileWriter display, Func<double, double?> elapsed)
    {
        try
        {
            return new AudioTrackRecorder(new WasapiLoopbackCapture(), 2, (data, length, at, duration) => display.WriteAudio(data.AsSpan(0, length), at, duration), null, elapsed);
        }
        catch (COMException)
        {
            return null;
        }
    }

    internal static AudioTrackRecorder? TryMicrophone(string deviceId, string path, Func<double, double?> elapsed)
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            var writer = new AudioFileWriter(path, new AudioFormat(SampleRate, 1, 128_000));
            var capture = new WasapiCapture(enumerator.GetDevice(deviceId), true, 50);
            return new AudioTrackRecorder(capture, 1, (data, length, at, duration) => writer.Write(data.AsSpan(0, length), at, duration), writer.Dispose, elapsed);
        }
        catch (COMException)
        {
            return null;
        }
    }

    /// <summary>Stops capture and pads to the recording's end, so every track has the same length.</summary>
    public void Stop(double durationMs)
    {
        silenceTimer.Dispose();
        capture.DataAvailable -= DataAvailable;
        capture.StopRecording();
        lock (capture)
        {
            FillUntil(durationMs);
            finish?.Invoke();
        }
    }

    public void Dispose() => capture.Dispose();

    private void DataAvailable(object? sender, WaveInEventArgs args)
    {
        var now = Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency;
        var bufferMs = args.BytesRecorded * 1000.0 / capture.WaveFormat.AverageBytesPerSecond;
        var converted = converter.Convert(args.Buffer.AsSpan(0, args.BytesRecorded));
        if (converted.Length == 0)
        {
            return;
        }

        var peak = 0;
        foreach (var sample in converted)
        {
            peak = Math.Max(peak, Math.Abs((int)sample));
        }

        Level = peak / 32768.0;
        lock (capture)
        {
            if (elapsed(now - bufferMs) is not { } expectedMs)
            {
                return;
            }

            var writtenMs = writtenFrames * 1000.0 / SampleRate;
            if (expectedMs - writtenMs > GapToleranceMs)
            {
                FillUntil(expectedMs);
            }
            else if (writtenMs - expectedMs > AheadToleranceMs)
            {
                return;
            }

            var length = converted.Length * 2;
            if (bytes.Length < length)
            {
                bytes = new byte[length * 2];
            }

            MemoryMarshal.AsBytes(converted).CopyTo(bytes);
            Emit(bytes, length);
        }
    }

    /// <summary>Loopback sends nothing during silence, and the MP4 sink holds video back waiting for audio to interleave with it.</summary>
    private void FillSilence()
    {
        lock (capture)
        {
            var now = Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency;
            if (elapsed(now) is { } expectedMs && expectedMs - writtenFrames * 1000.0 / SampleRate > SilenceAfterMs)
            {
                FillUntil(expectedMs - SilenceAfterMs / 2);
            }
        }
    }

    private void FillUntil(double positionMs)    {
        var target = (long)(positionMs / 1000 * SampleRate);
        var frameBytes = channels * 2;
        while (writtenFrames < target)
        {
            var frames = (int)Math.Min(target - writtenFrames, silence.Length / frameBytes);
            Emit(silence, frames * frameBytes);
        }
    }

    private void Emit(byte[] data, int length)
    {
        var frames = length / (channels * 2);
        write(data, length, writtenFrames * 1000.0 / SampleRate, frames * 1000.0 / SampleRate);
        writtenFrames += frames;
    }
}
