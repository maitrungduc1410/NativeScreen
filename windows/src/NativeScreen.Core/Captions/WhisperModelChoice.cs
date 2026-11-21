namespace NativeScreen.Core;

/// <summary>
/// The speech model a project opens with (spec/06 ADR-105). The document defaults to Small, which is often not the model on
/// this computer, so a project without a transcript opens on the only downloaded model, or the most recently used of
/// several. With a transcript, or with no model downloaded, it keeps its own.
/// </summary>
public static class WhisperModelChoice
{
    public static string ForOpening(string current, bool hasTranscript, IReadOnlyList<string> installed, string? lastUsed)
    {
        if (hasTranscript || installed.Count == 0)
        {
            return current;
        }

        if (installed.Count == 1)
        {
            return installed[0];
        }

        if (lastUsed is not null && installed.Contains(lastUsed))
        {
            return lastUsed;
        }

        return installed.Contains(current) ? current : installed[0];
    }
}
