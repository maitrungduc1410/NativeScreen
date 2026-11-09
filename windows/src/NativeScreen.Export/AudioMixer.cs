using NativeScreen.Core;
using NativeScreen.Media;

namespace NativeScreen.Export;

/// <summary>
/// The export mixdown: recorded system audio and microphone follow the slices, including speed, while voiceovers and
/// background music play on the timeline. Gains and rules match the macOS exporter.
/// </summary>
public sealed class AudioMixer : IDisposable
{
    private readonly bool livePreview;
    public const int SampleRate = 48000;
    private const int BlockFrames = 1024;

    public static AudioFormat OutputFormat { get; } = new(SampleRate, 2, 192_000);

    private readonly ProjectDocument document;
    private readonly NLETimeMapper mapper;
    private readonly double master;
    private readonly AudioCursor? system;
    private readonly AudioCursor? microphone;
    private readonly AudioCursor? music;
    private readonly List<(VoiceoverSegment Segment, AudioCursor Cursor, double TimelineStartMs)> voiceovers = [];
    private readonly byte[] block = new byte[BlockFrames * 4];
    private long writtenFrames;

    public AudioMixer(ProjectDocument document, string packageDirectory, RecordingTracksMetadata tracks, NLETimeMapper mapper, bool livePreview = false)
    {
        this.livePreview = livePreview;
        this.document = document;
        this.mapper = mapper;
        master = Math.Clamp(document.Audio.MasterVolume, 0, 2);
        var recording = Path.Combine(packageDirectory, "recording");
        if (tracks.SystemAudio is { } systemTrack && !document.Audio.MuteSystemAudio && document.Audio.SystemAudioVolume > 0.001)
        {
            system = AudioCursor.Open(Path.Combine(recording, systemTrack));
        }

        if (tracks.MicrophoneAudio is { } micTrack && !document.Audio.MuteMicrophone && document.Audio.MicrophoneVolume > 0.001)
        {
            microphone = AudioCursor.Open(Path.Combine(recording, micTrack));
        }

        if (document.Audio.BackgroundMusic is { Muted: false, Volume: > 0.001, RelativePath: { } musicPath })
        {
            music = BuiltInBackgroundMusic.ResolvePath(packageDirectory, musicPath) is { } musicFile ? AudioCursor.Open(musicFile) : null;
        }

        foreach (var segment in document.Timeline.Voiceovers.Where(item => !item.Disabled && item.Volume > 0.001 && !VoiceoverTrackLayout.IsTrackHidden(document.Timeline, item.TrackIndex)))
        {
            if (AudioCursor.Open(Path.Combine(packageDirectory, segment.RelativePath)) is { } cursor)
            {
                voiceovers.Add((segment, cursor, mapper.TimelineTime(segment.SourceStartMs) ?? segment.SourceStartMs));
            }
        }
    }

    public bool HasAudio => system is not null || microphone is not null || music is not null || voiceovers.Count > 0;

    /// <summary>Encodes everything up to a timeline time, so audio stays next to its video in the file.</summary>
    public void WriteUpTo(VideoFileWriter writer, double timelineMs)
    {
        var target = (long)(Math.Min(timelineMs, mapper.TotalTimelineDurationMs) / 1000 * SampleRate);
        while (writtenFrames < target)
        {
            var frames = (int)Math.Min(BlockFrames, target - writtenFrames);
            MixBlock(frames);
            writer.WriteAudio(block.AsSpan(0, frames * 4), writtenFrames * 1000.0 / SampleRate, frames * 1000.0 / SampleRate);
            writtenFrames += frames;
        }
    }

    /// <summary>Moves the read position; the next Render continues from this timeline time.</summary>
    public void Seek(double timelineMs) => writtenFrames = (long)(Math.Max(0, timelineMs) / 1000 * SampleRate);

    /// <summary>Fills 16-bit stereo for the next frames. Past the end of the timeline it is silence.</summary>
    public void Render(byte[] destination, int frames)
    {
        MixBlock(frames);
        Array.Copy(block, destination, frames * 4);
        writtenFrames += frames;
    }

    public void Dispose()
    {
        system?.Dispose();
        microphone?.Dispose();
        music?.Dispose();
        foreach (var (_, cursor, _) in voiceovers)
        {
            cursor.Dispose();
        }
    }

    private void MixBlock(int frames)
    {
        var musicGain = (float)AudioMix.MusicGain(document.Audio, master);
        for (var frame = 0; frame < frames; frame++)
        {
            var timelineMs = (writtenFrames + frame) * 1000.0 / SampleRate;
            var (sourceMs, slice) = timelineMs < mapper.TotalTimelineDurationMs ? mapper.SourceTime(timelineMs) : (0, null);
            var left = 0f;
            var right = 0f;
            if (slice is not null)
            {
                var hidden = IsHiddenByVoiceover(timelineMs);
                if (system is not null)
                {
                    Add(system, sourceMs, (float)AudioMix.SystemGain(document.Audio, slice, master), ref left, ref right);
                }

                if (microphone is not null)
                {
                    Add(microphone, sourceMs, (float)AudioMix.MicrophoneGain(document.Audio, slice, master, hidden), ref left, ref right);
                }
            }

            foreach (var (segment, cursor, start) in voiceovers)
            {
                if (livePreview && segment.AttachMode == VoiceoverAttachMode.Synchronized)
                {
                    // In preview a synchronized voiceover follows the recording through speed changes and cuts.
                    if (slice is not null && sourceMs >= segment.SourceStartMs && sourceMs < segment.SourceEndMs)
                    {
                        Add(cursor, segment.FileOffsetMs + sourceMs - segment.SourceStartMs, (float)AudioMix.VoiceoverGain(segment, master, false), ref left, ref right);
                    }
                }
                else if (timelineMs >= start && timelineMs < start + segment.DurationMs)
                {
                    Add(cursor, segment.FileOffsetMs + timelineMs - start, (float)AudioMix.VoiceoverGain(segment, master, false), ref left, ref right);
                }
            }

            if (music is not null)
            {
                Add(music, music.DurationAware(timelineMs), musicGain, ref left, ref right);
            }

            var l = (short)Math.Clamp(left * 32767f, short.MinValue, short.MaxValue);
            var r = (short)Math.Clamp(right * 32767f, short.MinValue, short.MaxValue);
            block[frame * 4] = (byte)l;
            block[frame * 4 + 1] = (byte)(l >> 8);
            block[frame * 4 + 2] = (byte)r;
            block[frame * 4 + 3] = (byte)(r >> 8);
        }
    }

    private bool IsHiddenByVoiceover(double timelineMs)
    {
        foreach (var (segment, _, start) in voiceovers)
        {
            if (segment.HideRecording && timelineMs >= start && timelineMs < start + segment.DurationMs)
            {
                return true;
            }
        }

        return false;
    }

    private static void Add(AudioCursor cursor, double positionMs, float gain, ref float left, ref float right)
    {
        if (gain <= 0)
        {
            return;
        }

        cursor.Sample(positionMs, out var l, out var r);
        left += l * gain;
        right += r * gain;
    }

    /// <summary>Linear interpolation over decoded blocks. Sequential reads never seek; a jump over a cut does.</summary>
    private sealed class AudioCursor(AudioFileReader reader) : IDisposable
    {
        private const double SeekThresholdMs = 200;
        private short[] samples = [];
        private double blockStartMs;
        private double blockEndMs;
        private bool ended;

        public static AudioCursor? Open(string path) =>
            AudioFileReader.TryOpen(path) is { } reader ? new AudioCursor(reader) : null;

        public double DurationAware(double positionMs) => positionMs;

        public void Sample(double positionMs, out float left, out float right)
        {
            left = 0;
            right = 0;
            if (positionMs < blockStartMs - 0.001 || positionMs > blockEndMs + SeekThresholdMs)
            {
                reader.Seek(positionMs);
                ended = false;
                blockEndMs = blockStartMs = positionMs;
                samples = [];
                Load();
            }

            while (positionMs >= blockEndMs && !ended)
            {
                Load();
            }

            if (samples.Length == 0 || positionMs >= blockEndMs || positionMs < blockStartMs)
            {
                return;
            }

            var channels = reader.Channels;
            var position = (positionMs - blockStartMs) / 1000 * reader.SampleRate;
            var index = (int)position;
            var fraction = (float)(position - index);
            var count = samples.Length / channels;
            var next = Math.Min(index + 1, count - 1);
            var second = channels > 1 ? 1 : 0;
            left = Lerp(samples[index * channels], samples[next * channels], fraction) / 32768f;
            right = Lerp(samples[index * channels + second], samples[next * channels + second], fraction) / 32768f;
        }

        public void Dispose() => reader.Dispose();

        private void Load()
        {
            if (reader.ReadBlock() is not { } read)
            {
                ended = true;
                return;
            }

            samples = read.Samples;
            blockStartMs = read.StartMs;
            blockEndMs = read.StartMs + samples.Length / reader.Channels * 1000.0 / reader.SampleRate;
        }

        private static float Lerp(short a, short b, float t) => a + (b - a) * t;
    }
}
