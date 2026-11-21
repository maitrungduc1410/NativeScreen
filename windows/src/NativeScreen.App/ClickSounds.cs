using NativeScreen.Core;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace NativeScreen.App;

/// <summary>Click sounds heard while previewing. As on macOS they are preview only, not part of an export.</summary>
internal sealed class ClickSounds : IDisposable
{
    private const double FastestAudibleSpeed = 2;
    private readonly Dictionary<string, MediaPlayer> players = [];
    private double lastSourceMs = -1;

    /// <summary>The bundled sets, in the order of the inspector (macOS `CursorClickSoundPlayer.soundSets`, spec/06 ADR-107).</summary>
    public static readonly (string Id, string Title)[] Sets = [("soft", "Soft"), ("crisp", "Crisp"), ("classic", "Classic")];

    /// <summary>
    /// A saved set as one this build has, or null for no sound. An id from a newer or older build still clicks, as on macOS:
    /// one with "master" in it plays Crisp, anything else Soft.
    /// </summary>
    public static string? Normalized(string? soundSet)
    {
        if (string.IsNullOrEmpty(soundSet))
        {
            return null;
        }

        foreach (var (id, _) in Sets)
        {
            if (id == soundSet)
            {
                return id;
            }
        }

        return soundSet.Contains("master", StringComparison.Ordinal) ? "crisp" : "soft";
    }

    public void Play(string? soundSet, double volume)
    {
        soundSet = Normalized(soundSet);
        if (soundSet is null)
        {
            return;
        }

        if (!players.TryGetValue(soundSet, out var player))
        {
            var file = Path.Combine(AppContext.BaseDirectory, "Assets", "Cursors", "sounds", soundSet, "click.wav");
            if (!File.Exists(file))
            {
                return;
            }

            player = new MediaPlayer { Source = MediaSource.CreateFromUri(new Uri(file)), AudioCategory = MediaPlayerAudioCategory.SoundEffects };
            players[soundSet] = player;
        }

        player.Volume = Math.Clamp(volume, 0, 1);
        player.PlaybackSession.Position = TimeSpan.Zero;
        player.Play();
    }

    /// <summary>Called on each playback tick: plays when the playhead passed a mouse press since the last one.</summary>
    public void Advance(EditorSession session)
    {
        var now = session.SourceAtPlayhead;
        var effect = session.Document.Cursor.ClickEffect;
        if (effect.SoundSet is not null && now > lastSourceMs && lastSourceMs >= 0 && (session.ActiveSlice?.Speed ?? 1) <= FastestAudibleSpeed)
        {
            foreach (var click in session.ClickEvents)
            {
                if (click.Type == "down" && click.T > lastSourceMs && click.T <= now)
                {
                    Play(effect.SoundSet, effect.SoundVolume);
                    break;
                }
            }
        }

        lastSourceMs = now;
    }

    public void Rewind() => lastSourceMs = -1;

    public void Dispose()
    {
        foreach (var player in players.Values)
        {
            player.Dispose();
        }

        players.Clear();
    }
}
