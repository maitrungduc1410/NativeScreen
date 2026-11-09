namespace NativeScreen.Core;

/// <summary>
/// Caps a stream of frames to a rate by a schedule. Comparing each frame with the last one kept would round down to a whole
/// number of display refreshes: 37.5 fps on a 75 Hz display and 48 fps on 144 Hz, for a 60 fps cap.
/// </summary>
public sealed class FramePacer(double intervalMs, double slackMs)
{
    private double nextDueMs = double.NegativeInfinity;

    public bool Accept(double presentationMs)
    {
        if (presentationMs < nextDueMs - slackMs)
        {
            return false;
        }

        // After a gap (a still screen sends nothing) the schedule starts again instead of letting a burst through.
        nextDueMs = presentationMs >= nextDueMs + intervalMs ? presentationMs + intervalMs : nextDueMs + intervalMs;
        return true;
    }
}
