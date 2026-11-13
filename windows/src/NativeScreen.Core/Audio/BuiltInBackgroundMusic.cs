namespace NativeScreen.Core;

/// <summary>
/// The built-in background tracks. They are synthesized on first use and cached outside the project, and a project stores only
/// the track's name, so the same formulas as ensureSynthesizedBuiltInBackgroundTrack on macOS keep them sounding the same.
/// </summary>
public static class BuiltInBackgroundMusic
{
    private const int SampleRate = 44_100;
    private const double DurationSeconds = 16;
    private const long SmallestValidFile = 64_000;

    public static readonly string[] Genres = ["Lo-Fi", "Commercial", "Electronic", "Instrumental"];

    public static IReadOnlyList<string> Tracks(string genre) => genre switch
    {
        "Commercial" => ["Upbeat Spark", "Warm Horizon", "Bright Lounge", "Lean Groove"],
        "Electronic" => ["Pulse Drive", "Lean Groove", "Midnight Study", "Sunny Lo-Fi"],
        "Instrumental" => ["Velvet Keys", "Soft Rain", "Warm Horizon", "Chill Hop"],
        _ => ["Sunny Lo-Fi", "Lean Groove", "Bright Lounge", "Chill Hop"]
    };

    private static string Slug(string trackName) => trackName.ToLowerInvariant().Replace(' ', '-').Replace('/', '-');

    private static string CachePath(string trackName)
    {
        var directory = UserDataFolder.PathOf("BackgroundAudio");
        Directory.CreateDirectory(directory);
        return Path.Combine(directory, Slug(trackName) + ".wav");
    }

    private static bool IsBuiltIn(string relativePath) => Genres.Any(genre => Tracks(genre).Contains(relativePath));

    /// <summary>Where a project's background audio is: in the package, in its assets, or a built-in track, made if needed.</summary>
    public static string? ResolvePath(string? packageDirectory, string? relativePath)
    {
        if (string.IsNullOrEmpty(relativePath))
        {
            return null;
        }

        if (packageDirectory is not null)
        {
            foreach (var candidate in new[] { Path.Combine(packageDirectory, relativePath), Path.Combine(packageDirectory, "assets", relativePath) })
            {
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }
        }

        return IsBuiltIn(relativePath) ? EnsureTrack(relativePath) : null;
    }

    public static string EnsureTrack(string trackName)
    {
        var path = CachePath(trackName);
        if (File.Exists(path) && new FileInfo(path).Length > SmallestValidFile)
        {
            return path;
        }

        var pcm = Synthesize(trackName);
        var temporary = path + ".tmp";
        using (var writer = new BinaryWriter(File.Create(temporary)))
        {
            var dataBytes = (uint)(pcm.Length * sizeof(short));
            writer.Write("RIFF"u8);
            writer.Write(36 + dataBytes);
            writer.Write("WAVEfmt "u8);
            writer.Write(16u);
            writer.Write((ushort)1);
            writer.Write((ushort)2);
            writer.Write((uint)SampleRate);
            writer.Write((uint)(SampleRate * 4));
            writer.Write((ushort)4);
            writer.Write((ushort)16);
            writer.Write("data"u8);
            writer.Write(dataBytes);
            foreach (var sample in pcm)
            {
                writer.Write(sample);
            }
        }

        File.Move(temporary, path, overwrite: true);
        return path;
    }

    /// <summary>Stereo, interleaved.</summary>
    public static short[] Synthesize(string trackName)
    {
        var totalFrames = (int)(SampleRate * DurationSeconds);
        var pcm = new short[totalFrames * 2];
        double bpm;
        double padBrightness;
        double[][] progression;
        switch (Slug(trackName))
        {
            case "lean-groove" or "upbeat-spark" or "pulse-drive":
                bpm = 108;
                padBrightness = 0.45;
                progression = [[220.00, 277.18, 329.63, 415.30], [185.00, 220.00, 277.18, 329.63], [146.83, 185.00, 220.00, 277.18], [164.81, 207.65, 246.94, 329.63]];
                break;
            case "bright-lounge" or "warm-horizon" or "velvet-keys":
                bpm = 92;
                padBrightness = 0.35;
                progression = [[174.61, 220.00, 261.63, 329.63], [164.81, 196.00, 246.94, 293.66], [146.83, 174.61, 220.00, 261.63], [130.81, 164.81, 196.00, 246.94]];
                break;
            case "chill-hop" or "midnight-study" or "soft-rain":
                bpm = 78;
                padBrightness = 0.25;
                progression = [[146.83, 174.61, 220.00, 261.63], [196.00, 246.94, 293.66, 349.23], [130.81, 164.81, 196.00, 246.94], [110.00, 138.59, 164.81, 196.00]];
                break;
            default:
                bpm = 84;
                padBrightness = 0.30;
                progression = [[130.81, 164.81, 196.00, 246.94, 293.66], [110.00, 130.81, 164.81, 196.00, 246.94], [146.83, 174.61, 220.00, 261.63, 329.63], [98.00, 146.83, 174.61, 220.00, 246.94]];
                break;
        }

        var secondsPerBeat = 60 / bpm;
        var secondsPerBar = secondsPerBeat * 4;
        for (var i = 0; i < totalFrames; i++)
        {
            var t = i / (double)SampleRate;
            var barPhase = t % secondsPerBar;
            var beatPhase = t % secondsPerBeat;
            var chord = progression[(int)(t / secondsPerBar) % progression.Length];

            var barEnvelope = Math.Min(1, barPhase / 0.06) * Math.Exp(-barPhase * 0.42);
            var tremoloLeft = 0.88 + 0.12 * Math.Sin(2 * Math.PI * 3.2 * t);
            var tremoloRight = 0.88 + 0.12 * Math.Cos(2 * Math.PI * 3.2 * t);
            var padLeft = 0.0;
            var padRight = 0.0;
            for (var note = 0; note < chord.Length; note++)
            {
                var detune = 1 + (note - 2) * 0.0008;
                var fundamental = Math.Sin(2 * Math.PI * chord[note] * detune * t);
                var harmonic = Math.Sin(2 * Math.PI * chord[note] * 2 * t) * padBrightness * Math.Exp(-barPhase * 1.4);
                var voice = (fundamental + harmonic) / chord.Length;
                var pan = 0.5 + (note - chord.Length / 2) * 0.12;
                padLeft += voice * (1 - pan * 0.4);
                padRight += voice * (0.6 + pan * 0.4);
            }

            var bassTime = barPhase < secondsPerBeat * 2.5 ? barPhase : barPhase - secondsPerBeat * 2.5;
            var bass = Math.Sin(2 * Math.PI * chord[0] * 0.5 * t) * Math.Min(1, bassTime / 0.015) * Math.Exp(-bassTime * 3.2) * 0.34;

            var kickEnvelope = (int)(barPhase / secondsPerBeat) % 2 == 0 ? Math.Exp(-beatPhase * 22) : 0;
            var kick = Math.Sin(2 * Math.PI * (52 + 95 * Math.Exp(-beatPhase * 38)) * t) * kickEnvelope * 0.28;

            var hatEnvelope = Math.Exp(-(t % (secondsPerBeat * 0.5)) * 48) * 0.035;
            var hat = Math.Sin(i * 1.73205) * Math.Cos(i * 2.41421) * hatEnvelope;

            var loopFade = Math.Min(1, Math.Min(t / 0.08, (DurationSeconds - t) / 0.15));
            var left = (padLeft * barEnvelope * tremoloLeft * 0.52 + bass + kick + hat) * loopFade;
            var right = (padRight * barEnvelope * tremoloRight * 0.52 + bass + kick + hat) * loopFade;
            pcm[i * 2] = (short)Math.Clamp(left * 26000, -32000, 32000);
            pcm[i * 2 + 1] = (short)Math.Clamp(right * 26000, -32000, 32000);
        }

        return pcm;
    }
}
