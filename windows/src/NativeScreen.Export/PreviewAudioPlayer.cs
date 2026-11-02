using NAudio.CoreAudioApi;
using NAudio.Wave;
using NativeScreen.Core;

namespace NativeScreen.Export;

/// <summary>
/// Plays the export mixdown while the editor plays. A pump thread decodes and mixes ahead of the device, so the WASAPI
/// callback only copies from a ring. The device position is the master clock while it is running.
/// </summary>
public sealed class PreviewAudioPlayer : IDisposable
{
    private const int LatencyMs = 40;
    private const int PrebufferMs = 120;
    private const int AheadMs = 400;
    private const int PumpFrames = 1024;

    private readonly AudioMixer mixer;
    private readonly BufferedWaveProvider buffer;
    private readonly WasapiOut output;
    private readonly byte[] block = new byte[PumpFrames * 4];
    private readonly ManualResetEventSlim primed = new(false);
    private Thread? pump;
    private volatile bool stopping;
    private volatile bool deviceFailed;
    private double startTimelineMs;
    private long startDeviceBytes;

    private PreviewAudioPlayer(AudioMixer mixer)
    {
        this.mixer = mixer;
        buffer = new BufferedWaveProvider(new WaveFormat(AudioMixer.SampleRate, 16, 2))
        {
            BufferDuration = TimeSpan.FromMilliseconds(AheadMs * 2),
            DiscardOnBufferOverflow = false,
            ReadFully = true
        };
        output = new WasapiOut(AudioClientShareMode.Shared, true, LatencyMs);
        output.Init(buffer);
        output.PlaybackStopped += (_, args) => deviceFailed = args.Exception is not null;
    }

    /// <summary>Null when the project has nothing to hear or the machine has no output device, so the clock stays on QPC.</summary>
    public static PreviewAudioPlayer? TryCreate(ProjectDocument document, string? packageDirectory, RecordingTracksMetadata tracks)
    {
        if (packageDirectory is null)
        {
            return null;
        }

        var mixer = new AudioMixer(document, packageDirectory, tracks, new NLETimeMapper(document.Timeline.Slices));
        if (!mixer.HasAudio)
        {
            mixer.Dispose();
            return null;
        }

        try
        {
            return new PreviewAudioPlayer(mixer);
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            mixer.Dispose();
            return null;
        }
    }

    /// <summary>The timeline position the listener hears now, or null while it is not running.</summary>
    public double? HeardTimelineMs
    {
        get
        {
            if (deviceFailed || output.PlaybackState != PlaybackState.Playing)
            {
                return null;
            }

            return startTimelineMs + (output.GetPosition() - startDeviceBytes) * 1000.0 / output.OutputWaveFormat.AverageBytesPerSecond;
        }
    }

    /// <summary>Decodes the start of the sound first; a slow disk delays the first frame instead of causing a hitch after it.</summary>
    public void Prime(double timelineMs)
    {
        output.Stop();
        StopPump();
        startTimelineMs = timelineMs;
        startDeviceBytes = 0;
        mixer.Seek(timelineMs);
        buffer.ClearBuffer();
        primed.Reset();
        stopping = false;
        pump = new Thread(Pump) { IsBackground = true, Name = "NativeScreen preview audio" };
        pump.Start();
        primed.Wait(TimeSpan.FromSeconds(2));
    }

    public void Start()
    {
        if (!deviceFailed)
        {
            output.Play();
        }
    }

    public void Pause()
    {
        output.Stop();
        StopPump();
    }

    public void Dispose()
    {
        output.Dispose();
        StopPump();
        primed.Dispose();
        mixer.Dispose();
    }

    private void StopPump()
    {
        stopping = true;
        pump?.Join();
        pump = null;
    }

    private void Pump()
    {
        var prebufferBytes = PrebufferMs * buffer.WaveFormat.AverageBytesPerSecond / 1000;
        var aheadBytes = AheadMs * buffer.WaveFormat.AverageBytesPerSecond / 1000;
        while (!stopping)
        {
            if (buffer.BufferedBytes >= aheadBytes)
            {
                primed.Set();
                Thread.Sleep(10);
                continue;
            }

            mixer.Render(block, PumpFrames);
            buffer.AddSamples(block, 0, block.Length);
            if (buffer.BufferedBytes >= prebufferBytes)
            {
                primed.Set();
            }
        }

        primed.Set();
    }
}
