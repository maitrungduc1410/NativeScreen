namespace NativeScreen.Core;

/// <summary>
/// Recordings made before telemetry was anchored to the first video frame (2026-10-26) started their clock when telemetry
/// started, before capture, so every event is late by the startup delay. Current recordings always write a cursor sample at
/// exactly t = 0. Files are never rewritten: the correction is applied in memory on load (spec/06 ADR-88).
/// </summary>
public static class LegacyTelemetryEpoch
{
    /// <summary>
    /// The startup delay in ms, or 0 for current recordings. Telemetry and capture stopped together, so the delay is how far the
    /// last event runs past the video. It cannot exceed the first cursor sample (made after capture began).
    /// </summary>
    public static double OffsetMs(IReadOnlyList<CursorSampleEvent> cursor, IReadOnlyList<ClickEvent> clicks, IReadOnlyList<KeyStrokeEvent> keys, double durationMs)
    {
        if (cursor.Count == 0 || cursor[0].T <= 0.5)
        {
            return 0;
        }

        var last = Math.Max(cursor[^1].T, Math.Max(clicks.Count > 0 ? clicks[^1].T : 0, keys.Count > 0 ? keys[^1].T : 0));
        var offset = Math.Min(cursor[0].T, Math.Max(0, last - durationMs));
        return offset >= 20 ? offset : 0;
    }

    /// <summary>
    /// Moves events onto the video clock. Events from before capture began are dropped; the cursor keeps its last position from
    /// then as the sample at t = 0. New lists are returned; the inputs are not changed.
    /// </summary>
    public static (List<CursorSampleEvent> Cursor, List<ClickEvent> Clicks, List<KeyStrokeEvent> Keys) Corrected(
        IReadOnlyList<CursorSampleEvent> cursor, IReadOnlyList<ClickEvent> clicks, IReadOnlyList<KeyStrokeEvent> keys, double offsetMs)
    {
        if (offsetMs <= 0)
        {
            return ([.. cursor], [.. clicks], [.. keys]);
        }

        var shifted = new List<CursorSampleEvent>(cursor.Count);
        CursorSampleEvent? before = null;
        foreach (var source in cursor)
        {
            var e = new CursorSampleEvent { T = source.T - offsetMs, X = source.X, Y = source.Y, C = source.C };
            if (e.T < 0)
            {
                before = e;
                continue;
            }

            if (shifted.Count == 0 && e.T > 0 && before is not null)
            {
                shifted.Add(new CursorSampleEvent { T = 0, X = before.X, Y = before.Y, C = before.C });
            }

            shifted.Add(e);
        }

        if (shifted.Count == 0 && before is not null)
        {
            shifted.Add(new CursorSampleEvent { T = 0, X = before.X, Y = before.Y, C = before.C });
        }

        var shiftedClicks = new List<ClickEvent>(clicks.Count);
        foreach (var c in clicks)
        {
            if (c.T - offsetMs >= 0)
            {
                shiftedClicks.Add(new ClickEvent { T = c.T - offsetMs, Type = c.Type, Button = c.Button, X = c.X, Y = c.Y, Count = c.Count, Dx = c.Dx, Dy = c.Dy });
            }
        }

        var shiftedKeys = new List<KeyStrokeEvent>(keys.Count);
        foreach (var k in keys)
        {
            if (k.T - offsetMs >= 0)
            {
                shiftedKeys.Add(new KeyStrokeEvent { T = k.T - offsetMs, Kind = k.Kind, Modifiers = k.Modifiers, Key = k.Key, Label = k.Label });
            }
        }

        return (shifted, shiftedClicks, shiftedKeys);
    }
}
