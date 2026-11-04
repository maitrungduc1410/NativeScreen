using System.Diagnostics;
using System.Runtime.InteropServices;

namespace NativeScreen.Media;

/// <summary>
/// The sound of one process tree through the process loopback client, delivered as 48 kHz stereo 16-bit PCM on its own thread.
/// NAudio has no way to activate this client, and it offers no mix format, so the format is stated here and the engine converts
/// to it. It asks for float: the client can deliver far above full scale (spec/06 ADR-35), which 16 bits would clip before the
/// gain could bring it back.
/// </summary>
internal sealed unsafe class ProcessLoopbackStream : IDisposable
{
    private const string VirtualDevice = "VAD\\Process_Loopback";
    private const int ActivationTimeoutMs = 5000;
    private const int WaitMs = 100;
    private const int StopTimeoutMs = 1000;
    private const int StartAttempts = 6;
    private const int StartRetryMs = 200;
    private const long BufferHundredNs = 500_000;
    private const int Channels = 2;
    private const int Rate = 48000;
    private const uint StreamFlagsLoopback = 0x00020000;
    private const uint StreamFlagsEventCallback = 0x00040000;
    private const uint StreamFlagsAutoConvertPcm = 0x80000000;
    private const uint BufferFlagSilent = 0x2;
    private const ushort FormatFloat = 3;
    private const ushort VtBlob = 65;

    private readonly IAudioClient client;
    private readonly IAudioCaptureClient capture;
    private readonly AutoResetEvent ready = new(false);
    private readonly Action<short[], int, double> deliver;
    private readonly Func<float> gain;
    private readonly Thread thread;
    private short[] samples = new short[Rate / 10 * Channels];
    private volatile bool stopping;

    private ProcessLoopbackStream(IAudioClient client, IAudioCaptureClient capture, Action<short[], int, double> deliver, Func<float> gain)
    {
        this.client = client;
        this.capture = capture;
        this.deliver = deliver;
        this.gain = gain;
        client.SetEventHandle(ready.SafeWaitHandle.DangerousGetHandle());
        client.Start();
        thread = new Thread(Run) { IsBackground = true, Name = "NativeScreen app audio", Priority = ThreadPriority.AboveNormal };
        thread.Start();
    }

    /// <summary>
    /// Null when the process cannot be captured. The callback gets samples, their count, and when the first one was heard.
    /// Opening a process right after its last stream closed fails for a moment, as Restart does, so it tries again.
    /// </summary>
    public static ProcessLoopbackStream? TryStart(int processId, Action<short[], int, double> deliver, Func<float> gain)
    {
        for (var attempt = 0; attempt < StartAttempts; attempt++)
        {
            if (attempt > 0)
            {
                Thread.Sleep(StartRetryMs);
            }

            if (TryStartOnce(processId, deliver, gain) is { } stream)
            {
                return stream;
            }
        }

        return null;
    }

    private static ProcessLoopbackStream? TryStartOnce(int processId, Action<short[], int, double> deliver, Func<float> gain)
    {
        IAudioClient? client = null;
        IAudioCaptureClient? capture = null;
        try
        {
            client = Activate(processId);
            if (client is null)
            {
                return null;
            }

            var format = new WaveFormat
            {
                Tag = FormatFloat,
                Channels = Channels,
                SamplesPerSecond = Rate,
                AverageBytesPerSecond = Rate * Channels * sizeof(float),
                BlockAlign = Channels * sizeof(float),
                BitsPerSample = sizeof(float) * 8
            };
            client.Initialize(0, StreamFlagsLoopback | StreamFlagsEventCallback | StreamFlagsAutoConvertPcm, BufferHundredNs, 0, ref format, 0);
            var captureId = typeof(IAudioCaptureClient).GUID;
            client.GetService(ref captureId, out var service);
            capture = (IAudioCaptureClient)service;
            return new ProcessLoopbackStream(client, capture, deliver, gain);
        }
        catch (Exception exception) when (exception is COMException or InvalidCastException or EntryPointNotFoundException or DllNotFoundException or UnauthorizedAccessException)
        {
            Release(capture);
            Release(client);
            return null;
        }
    }

    public void Dispose()
    {
        stopping = true;
        ready.Set();
        if (thread.Join(StopTimeoutMs))
        {
            try
            {
                client.Stop();
            }
            catch (COMException)
            {
                // The device went away; there is nothing left to stop.
            }

            Release(capture);
            Release(client);
            ready.Dispose();
        }
    }

    private static void Release(object? com)
    {
        if (com is not null)
        {
            Marshal.ReleaseComObject(com);
        }
    }

    private static IAudioClient? Activate(int processId)
    {
        var handler = new ActivationHandler();
        var activation = new ActivationParameters { ActivationType = 1, ProcessId = (uint)processId, LoopbackMode = 0 };
        var variant = new BlobVariant { Type = VtBlob, Size = (uint)sizeof(ActivationParameters), Data = (nint)(&activation) };
        var clientId = typeof(IAudioClient).GUID;
        var result = ActivateAudioInterfaceAsync(VirtualDevice, ref clientId, &variant, handler, out var operation);
        if (result < 0)
        {
            return null;
        }

        try
        {
            if (!handler.Done.Wait(ActivationTimeoutMs))
            {
                return null;
            }

            operation.GetActivateResult(out var activated, out var client);
            return activated >= 0 ? client as IAudioClient : null;
        }
        finally
        {
            Release(operation);
        }
    }

    private void Run()
    {
        try
        {
            while (!stopping)
            {
                ready.WaitOne(WaitMs);
                Drain();
            }
        }
        catch (COMException)
        {
            // The app or the device went away. The mixer keeps the track going with silence.
        }
    }

    private void Drain()
    {
        capture.GetNextPacketSize(out var frames);
        while (frames > 0 && !stopping)
        {
            capture.GetBuffer(out var data, out var count, out var flags, out _, out _);
            var now = Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency;
            var length = (int)count * Channels;
            if (samples.Length < length)
            {
                samples = new short[length * 2];
            }

            if ((flags & BufferFlagSilent) != 0)
            {
                Array.Clear(samples, 0, length);
            }
            else
            {
                var input = new ReadOnlySpan<float>((void*)data, length);
                var scale = gain() * short.MaxValue;
                for (var index = 0; index < length; index++)
                {
                    samples[index] = (short)Math.Clamp(input[index] * scale, short.MinValue, short.MaxValue);
                }
            }

            capture.ReleaseBuffer(count);
            deliver(samples, length, now - count * 1000.0 / Rate);
            capture.GetNextPacketSize(out frames);
        }
    }

    [DllImport("Mmdevapi.dll", ExactSpelling = true)]
    private static extern int ActivateAudioInterfaceAsync(
        [MarshalAs(UnmanagedType.LPWStr)] string deviceInterfacePath,
        ref Guid riid,
        BlobVariant* activationParams,
        IActivateAudioInterfaceCompletionHandler completionHandler,
        out IActivateAudioInterfaceAsyncOperation activationOperation);

    [StructLayout(LayoutKind.Sequential)]
    private struct ActivationParameters
    {
        public int ActivationType;
        public uint ProcessId;
        public int LoopbackMode;
    }

    [StructLayout(LayoutKind.Explicit, Size = 24)]
    private struct BlobVariant
    {
        [FieldOffset(0)]
        public ushort Type;
        [FieldOffset(8)]
        public uint Size;
        [FieldOffset(16)]
        public nint Data;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    private struct WaveFormat
    {
        public ushort Tag;
        public ushort Channels;
        public uint SamplesPerSecond;
        public uint AverageBytesPerSecond;
        public ushort BlockAlign;
        public ushort BitsPerSample;
        public ushort ExtraSize;
    }

    [ComImport]
    [Guid("94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAgileObject;

    [ComImport]
    [Guid("41D949AB-9862-444A-80F6-C261334DA5EB")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IActivateAudioInterfaceCompletionHandler
    {
        void ActivateCompleted(IActivateAudioInterfaceAsyncOperation operation);
    }

    [ComImport]
    [Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IActivateAudioInterfaceAsyncOperation
    {
        void GetActivateResult(out int activateResult, [MarshalAs(UnmanagedType.IUnknown)] out object activatedInterface);
    }

    // The members before the ones used hold their places in the COM vtable.
    [ComImport]
    [Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioClient
    {
        void Initialize(int shareMode, uint streamFlags, long bufferDuration, long periodicity, ref WaveFormat format, nint sessionGuid);
        void GetBufferSize(out uint frames);
        void GetStreamLatency(out long latency);
        void GetCurrentPadding(out uint frames);
        void IsFormatSupported(int shareMode, nint format, out nint closest);
        void GetMixFormat(out nint format);
        void GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
        void Start();
        void Stop();
        void Reset();
        void SetEventHandle(nint handle);
        void GetService(ref Guid id, [MarshalAs(UnmanagedType.IUnknown)] out object service);
    }

    [ComImport]
    [Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioCaptureClient
    {
        void GetBuffer(out nint data, out uint frames, out uint flags, out ulong devicePosition, out ulong qpcPosition);
        void ReleaseBuffer(uint frames);
        void GetNextPacketSize(out uint frames);
    }

    /// <summary>Called on a system thread, which must be able to reach it directly: hence the agile marker.</summary>
    [ComVisible(true)]
    private sealed class ActivationHandler : IActivateAudioInterfaceCompletionHandler, IAgileObject
    {
        public ManualResetEventSlim Done { get; } = new(false);

        public void ActivateCompleted(IActivateAudioInterfaceAsyncOperation operation) => Done.Set();
    }
}
