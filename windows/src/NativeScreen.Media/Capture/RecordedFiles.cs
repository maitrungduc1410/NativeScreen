namespace NativeScreen.Media;

/// <summary>What happens to a recording's movie files once every writer has finished (spec/06 ADR-22).</summary>
public static class RecordedFiles
{
    private static readonly string[] Movies = ["display.mp4", "webcam.mp4", "microphone.m4a"];

    /// <summary>
    /// Rewrites each fragmented movie as a plain MP4 that every player reads. A file that cannot be rewritten stays fragmented,
    /// which this app still plays.
    /// </summary>
    public static void MakePlain(string recordingDirectory)
    {
        foreach (var name in Movies)
        {
            var path = Path.Combine(recordingDirectory, name);
            if (File.Exists(path))
            {
                Mp4Defragmenter.TryRewrite(path);
            }
        }
    }
}
