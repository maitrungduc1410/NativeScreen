namespace NativeScreen.Core;

public static class AudioMix
{
    public static double ClampGain(double value) => Math.Clamp(value, 0, 1);

    public static double SystemGain(AudioConfig audio, ClipSlice slice, double master)
    {
        if (audio.MuteSystemAudio || audio.SystemAudioVolume <= 0.001)
        {
            return 0;
        }

        return slice.Muted ? 0 : ClampGain(slice.SystemAudioVolume * audio.SystemAudioVolume * master);
    }

    public static double MicrophoneGain(AudioConfig audio, ClipSlice slice, double master, bool hiddenByVoiceover)
    {
        if (audio.MuteMicrophone || audio.MicrophoneVolume <= 0.001 || hiddenByVoiceover)
        {
            return 0;
        }

        return slice.Muted ? 0 : ClampGain(audio.MicrophoneVolume * master);
    }

    public static double VoiceoverGain(VoiceoverSegment segment, double master, bool trackHidden) =>
        trackHidden || segment.Disabled || segment.Volume <= 0.001 ? 0 : ClampGain(segment.Volume * master);

    public static double MusicGain(AudioConfig audio, double master) =>
        audio.BackgroundMusic.Muted || audio.BackgroundMusic.Volume <= 0.001
            ? 0
            : ClampGain(audio.BackgroundMusic.Volume * master * 2.5);
}

public static class ExportPlan
{
    public const int StudioQuality = 87;
    public const int SocialQuality = 72;
    public const int WebQuality = 58;
    public const int WebLowQuality = 42;
    public const double FragmentSeconds = 2;

    public static bool IsAvailableOnWindows(ExportFormat format) => format != ExportFormat.ProRes;

    public static int Quality(ExportCompression compression) => compression switch
    {
        ExportCompression.Studio => StudioQuality,
        ExportCompression.SocialMedia => SocialQuality,
        ExportCompression.Web => WebQuality,
        ExportCompression.WebLow => WebLowQuality,
        _ => StudioQuality
    };

    public static int FrameCount(double timelineDurationMs, int fps) =>
        Math.Max(1, (int)Math.Round(timelineDurationMs / 1000.0 * fps, MidpointRounding.AwayFromZero));

    public static double TimelineMs(int frameIndex, int fps) => frameIndex * 1000.0 / fps;
}

public sealed class ExportJob
{
    public ExportJob(int totalFrames, string outputPath)
    {
        TotalFrames = Math.Max(1, totalFrames);
        OutputPath = outputPath;
    }

    public int TotalFrames { get; }
    public int EncodedFrames { get; private set; }
    public bool IsCancelled { get; private set; }
    public string OutputPath { get; }
    public double Progress => (double)EncodedFrames / TotalFrames;

    public bool TryEncodeFrame()
    {
        if (IsCancelled || EncodedFrames >= TotalFrames)
        {
            return false;
        }

        EncodedFrames++;
        return true;
    }

    public void Cancel() => IsCancelled = true;

    public bool ShouldDeletePartial => IsCancelled;
}
