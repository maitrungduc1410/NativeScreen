using System.Globalization;

namespace NativeScreen.Core;

public sealed class ShortcutKeyCap
{
    public required string Key { get; init; }
    public double WidthRatio { get; init; }
    public string? Symbol { get; init; }
    public required string Label { get; init; }
}

public sealed class ShortcutCluster
{
    public required string Id { get; init; }
    public required string TrackId { get; init; }
    public int FirstKeyDownMsInt { get; init; }
    public double FirstKeyDownMs { get; init; }
    public double DisplayStartMs { get; set; }
    public double DisplayEndMs { get; set; }
    public required IReadOnlyList<string> Modifiers { get; init; }
    public required string PrimaryKey { get; init; }
    public required string Label { get; init; }
    public required IReadOnlyList<ShortcutKeyCap> KeyCaps { get; init; }
}

public readonly record struct TypingSuggestion(int StartKeyMs, double SourceStartMs, double SourceEndMs);

public readonly record struct ShortcutEnvelope(double Opacity, double Scale, double Slide);

public static class ShortcutEngine
{
    public static List<ShortcutCluster> Detect(ProjectDocument document, IReadOnlyList<KeyStrokeEvent> keys)
    {
        var primary = document.Captions.ShortcutTracks.Count == 0
            ? "default-shortcuts-track"
            : document.Captions.ShortcutTracks[0].Id;
        var deleted = document.Captions.DeletedShortcutStartMs.ToHashSet();
        var clusters = new List<ShortcutCluster>();
        if (keys.Count > 0)
        {
            var normalized = new List<(KeyStrokeEvent Raw, List<string> Mods, string Key)>();
            foreach (var ev in keys)
            {
                var key = NormalizeKey(ev);
                if (key is null)
                {
                    continue;
                }

                normalized.Add((ev, NormalizeModifiers(ev.Modifiers ?? []), key));
            }

            var filtered = new List<(KeyStrokeEvent Raw, List<string> Mods, string Key)>();
            for (var i = 0; i < normalized.Count; i++)
            {
                var curr = normalized[i];
                if (curr.Mods.Count == 1 && curr.Mods[0] == "Shift" && curr.Key.Length == 1 && i + 1 < normalized.Count)
                {
                    var next = normalized[i + 1];
                    if (next.Mods.Count == 0 && next.Raw.T - curr.Raw.T < 1000)
                    {
                        continue;
                    }
                }

                if (!document.Captions.ShowSingleKeyShortcuts && curr.Mods.Count + 1 == 1 && !AllowedStandalone(curr.Key))
                {
                    continue;
                }

                filtered.Add(curr);
            }

            var groups = new List<List<(KeyStrokeEvent Raw, List<string> Mods, string Key)>>();
            foreach (var curr in filtered)
            {
                if (groups.Count == 0)
                {
                    groups.Add([curr]);
                    continue;
                }

                var last = groups[^1];
                var first = last[0];
                if (document.Captions.ShowSingleKeyShortcuts
                    && first.Mods.Count == 0 && curr.Mods.Count == 0
                    && IsAlphaNumeric(first.Key) && IsAlphaNumeric(curr.Key)
                    && curr.Raw.T - first.Raw.T < 1000)
                {
                    groups.RemoveAt(groups.Count - 1);
                    continue;
                }

                var lastEvent = last[^1];
                var signature = string.Join('+', lastEvent.Mods.Append(lastEvent.Key));
                var currentSignature = string.Join('+', curr.Mods.Append(curr.Key));
                if (curr.Raw.T - lastEvent.Raw.T <= 2000 && signature == currentSignature)
                {
                    last.Add(curr);
                }
                else
                {
                    groups.Add([curr]);
                }
            }

            foreach (var group in groups)
            {
                var firstMs = group[0].Raw.T;
                var msInt = (int)Math.Round(firstMs, MidpointRounding.AwayFromZero);
                if (deleted.Contains(msInt))
                {
                    continue;
                }

                var lastMs = group[^1].Raw.T;
                var start = Math.Max(0, firstMs - 80);
                var end = lastMs + 1500;
                if (document.Captions.ShortcutTimingOverrides.TryGetValue(msInt, out var span))
                {
                    start = Math.Max(0, span.X);
                    end = Math.Max(start + 180, span.Y);
                }

                var mods = group[0].Mods;
                var key = group[0].Key;
                if (document.Captions.ShortcutKeyOverrides.TryGetValue(msInt, out var replacement))
                {
                    mods = replacement.Modifiers;
                    key = replacement.PrimaryKey;
                }

                clusters.Add(Make($"telemetry_{msInt}", primary, msInt, firstMs, start, end, mods, key));
            }

            if (clusters.Count >= 2)
            {
                for (var i = 0; i < clusters.Count - 1; i++)
                {
                    if (!document.Captions.ShortcutTimingOverrides.ContainsKey(clusters[i].FirstKeyDownMsInt)
                        && !document.Captions.ShortcutTimingOverrides.ContainsKey(clusters[i + 1].FirstKeyDownMsInt)
                        && clusters[i].DisplayEndMs > clusters[i + 1].FirstKeyDownMs)
                    {
                        clusters[i].DisplayEndMs = Math.Max(clusters[i].FirstKeyDownMs + 120, clusters[i + 1].FirstKeyDownMs);
                        clusters[i + 1].DisplayStartMs = clusters[i].DisplayEndMs;
                    }
                }
            }

            clusters = clusters.Where(cluster => document.Timeline.Slices.Any(slice =>
                Math.Min(cluster.DisplayEndMs, slice.SourceEndMs) > Math.Max(cluster.DisplayStartMs, slice.SourceStartMs))).ToList();
        }

        foreach (var segment in document.Captions.CustomShortcuts)
        {
            var overlap = document.Timeline.Slices.Any(slice =>
                Math.Min(segment.SourceEndMs, slice.SourceEndMs) > Math.Max(segment.SourceStartMs, slice.SourceStartMs));
            if (!overlap)
            {
                continue;
            }

            var mods = NormalizeModifiers(segment.Modifiers);
            var key = string.IsNullOrEmpty(segment.PrimaryKey) ? "K" : segment.PrimaryKey;
            clusters.Add(Make(
                segment.Id,
                segment.TrackId,
                (int)Math.Round(segment.SourceStartMs, MidpointRounding.AwayFromZero),
                segment.SourceStartMs,
                segment.SourceStartMs,
                segment.SourceEndMs,
                mods,
                key));
        }

        clusters.Sort((a, b) =>
        {
            if (Math.Abs(a.DisplayStartMs - b.DisplayStartMs) > 0.01)
            {
                return a.DisplayStartMs.CompareTo(b.DisplayStartMs);
            }

            return string.CompareOrdinal(a.Id, b.Id);
        });

        var byTrack = new Dictionary<string, List<ShortcutCluster>>();
        foreach (var cluster in clusters)
        {
            var track = cluster.TrackId == "default-shortcuts-track" ? primary : cluster.TrackId;
            if (!byTrack.TryGetValue(track, out var list))
            {
                list = [];
                byTrack[track] = list;
            }

            list.Add(cluster);
        }

        var sanitized = new List<ShortcutCluster>();
        var maxSource = document.Timeline.Slices.Count == 0 ? 0 : document.Timeline.Slices.Max(slice => slice.SourceEndMs);
        foreach (var list in byTrack.Values)
        {
            list.Sort((a, b) => a.DisplayStartMs.CompareTo(b.DisplayStartMs));
            var currentMin = 0.0;
            for (var i = 0; i < list.Count; i++)
            {
                if (list[i].DisplayStartMs < currentMin)
                {
                    var duration = Math.Max(220, list[i].DisplayEndMs - list[i].DisplayStartMs);
                    list[i].DisplayStartMs = currentMin;
                    list[i].DisplayEndMs = Math.Min(maxSource, currentMin + duration);
                }

                if (i + 1 < list.Count && list[i].DisplayEndMs > list[i + 1].DisplayStartMs)
                {
                    list[i].DisplayEndMs = Math.Max(list[i].DisplayStartMs + 220, list[i + 1].DisplayStartMs);
                }

                if (list[i].DisplayEndMs - list[i].DisplayStartMs >= 150)
                {
                    currentMin = list[i].DisplayEndMs;
                    sanitized.Add(list[i]);
                }
            }
        }

        sanitized.Sort((a, b) => a.DisplayStartMs.CompareTo(b.DisplayStartMs));
        return sanitized;
    }

    public static List<TypingSuggestion> TypingSuggestions(ProjectDocument document, IReadOnlyList<KeyStrokeEvent> keys)
    {
        if (keys.Count == 0)
        {
            return [];
        }

        var bursts = new List<(double Start, double End)>();
        var current = new List<KeyStrokeEvent>();
        void Close()
        {
            if (current.Count < 2)
            {
                return;
            }

            var duration = current[^1].T - current[0].T;
            var rate = current.Count / Math.Max(0.001, duration / 1000);
            if (duration >= 1500 && rate >= 2)
            {
                bursts.Add((current[0].T, current[^1].T));
            }
        }

        foreach (var ev in keys)
        {
            if (current.Count == 0)
            {
                current.Add(ev);
                continue;
            }

            if (ev.T - current[^1].T < 500)
            {
                current.Add(ev);
                continue;
            }

            Close();
            current = [ev];
        }

        Close();
        var dismissed = document.Timeline.DismissedTypingSuggestionStarts.ToHashSet();
        var results = new List<TypingSuggestion>();
        foreach (var burst in bursts)
        {
            var key = (int)Math.Round(burst.Start, MidpointRounding.AwayFromZero);
            if (dismissed.Contains(key))
            {
                continue;
            }

            var slice = document.Timeline.Slices.FirstOrDefault(item =>
                burst.Start >= item.SourceStartMs + 120 && burst.End <= item.SourceEndMs - 120);
            if (slice is not null && slice.Speed <= 1.08)
            {
                results.Add(new TypingSuggestion(key, burst.Start, burst.End));
            }
        }

        return results;
    }

    public static ShortcutEnvelope Envelope(double displayStartMs, double displayEndMs, double sourceMs)
    {
        var rawIn = Math.Clamp((sourceMs - displayStartMs) / 150.0, 0, 1);
        var rawOut = Math.Clamp((displayEndMs - sourceMs) / 180.0, 0, 1);
        var t = Math.Min(rawIn, rawOut);
        var smooth = t * t * (3 - 2 * t);
        return new ShortcutEnvelope(smooth, 0.95 + 0.05 * smooth, 1 - smooth);
    }

    private static ShortcutCluster Make(
        string id,
        string track,
        int msInt,
        double first,
        double start,
        double end,
        IReadOnlyList<string> mods,
        string key) => new()
    {
        Id = id,
        TrackId = track,
        FirstKeyDownMsInt = msInt,
        FirstKeyDownMs = first,
        DisplayStartMs = start,
        DisplayEndMs = end,
        Modifiers = mods.ToList(),
        PrimaryKey = key,
        Label = Compact(mods, key),
        KeyCaps = Caps(mods, key)
    };

    private static List<string> NormalizeModifiers(IReadOnlyList<string> raw)
    {
        var set = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in raw)
        {
            switch (item.ToLowerInvariant())
            {
                case "capslock": set.Add("CapsLock"); break;
                case "meta":
                case "cmd":
                case "command": set.Add("Meta"); break;
                case "shift": set.Add("Shift"); break;
                case "alt":
                case "opt":
                case "option": set.Add("Alt"); break;
                case "ctrl":
                case "control": set.Add("Ctrl"); break;
            }
        }

        return new[] { "CapsLock", "Meta", "Shift", "Alt", "Ctrl" }.Where(set.Contains).ToList();
    }

    private static string? NormalizeKey(KeyStrokeEvent ev)
    {
        if (string.IsNullOrEmpty(ev.Key))
        {
            return null;
        }

        return ev.Key == " " ? "Space" : ev.Key;
    }

    private static bool AllowedStandalone(string key) => key is
        "CapsLock" or "Backspace" or "Delete" or "ForwardDelete" or
        "ArrowUp" or "ArrowDown" or "ArrowLeft" or "ArrowRight" or
        "Home" or "End" or "PageUp" or "PageDown" or
        "F1" or "F2" or "F3" or "F4" or "F5" or "F6" or "F7" or "F8" or "F9" or "F10" or "F11" or "F12";

    private static bool IsAlphaNumeric(string key) =>
        key.Length == 1 && char.IsLetterOrDigit(key[0]);

    private static string Compact(IReadOnlyList<string> modifiers, string key)
    {
        var parts = modifiers.Select(mod => mod switch
        {
            "Meta" => "⌘",
            "Shift" => "⇧",
            "Alt" => "⌥",
            "Ctrl" => "⌃",
            "CapsLock" => "⇪",
            _ => mod
        }).ToList();
        parts.Add(key switch
        {
            "Delete" or "Backspace" => "⌫",
            "ForwardDelete" => "⌦",
            "Enter" => "⏎",
            "Tab" => "⇥",
            "Escape" => "Esc",
            "Space" or " " => "Space",
            "ArrowUp" => "↑",
            "ArrowDown" => "↓",
            "ArrowLeft" => "←",
            "ArrowRight" => "→",
            _ => key.ToUpper(CultureInfo.InvariantCulture)
        });
        return string.Join(' ', parts);
    }

    private static List<ShortcutKeyCap> Caps(IReadOnlyList<string> modifiers, string key)
    {
        var caps = new List<ShortcutKeyCap>();
        foreach (var mod in modifiers)
        {
            caps.Add(mod switch
            {
                "Meta" => new ShortcutKeyCap { Key = mod, WidthRatio = 1.33, Symbol = "⌘", Label = "command" },
                "Alt" => new ShortcutKeyCap { Key = mod, WidthRatio = 1.33, Symbol = "⌥", Label = "option" },
                "Ctrl" => new ShortcutKeyCap { Key = mod, WidthRatio = 1.33, Symbol = "⌃", Label = "control" },
                "Shift" => new ShortcutKeyCap { Key = mod, WidthRatio = 1.33, Symbol = "⇧", Label = "shift" },
                "CapsLock" => new ShortcutKeyCap { Key = mod, WidthRatio = 1.33, Symbol = "⇪", Label = "caps lock" },
                _ => new ShortcutKeyCap { Key = mod, WidthRatio = 1.33, Label = mod.ToLowerInvariant() }
            });
        }

        caps.Add(key switch
        {
            "Space" or " " => new ShortcutKeyCap { Key = "Space", WidthRatio = 1.66, Symbol = "␣", Label = "space" },
            "Delete" or "Backspace" => new ShortcutKeyCap { Key = "Delete", WidthRatio = 1.33, Symbol = "⌫", Label = "delete" },
            "ForwardDelete" => new ShortcutKeyCap { Key = "ForwardDelete", WidthRatio = 1.33, Symbol = "⌦", Label = "delete" },
            "Tab" => new ShortcutKeyCap { Key = "Tab", WidthRatio = 1.33, Symbol = "⇥", Label = "tab" },
            "Escape" => new ShortcutKeyCap { Key = "Escape", WidthRatio = 1.33, Symbol = "⎋", Label = "esc" },
            "Enter" => new ShortcutKeyCap { Key = "Enter", WidthRatio = 1.33, Label = "⏎" },
            "ArrowUp" => new ShortcutKeyCap { Key = "ArrowUp", WidthRatio = 1, Label = "↑" },
            "ArrowDown" => new ShortcutKeyCap { Key = "ArrowDown", WidthRatio = 1, Label = "↓" },
            "ArrowLeft" => new ShortcutKeyCap { Key = "ArrowLeft", WidthRatio = 1, Label = "←" },
            "ArrowRight" => new ShortcutKeyCap { Key = "ArrowRight", WidthRatio = 1, Label = "→" },
            _ => new ShortcutKeyCap { Key = key, WidthRatio = 1, Label = key.ToUpper(CultureInfo.InvariantCulture) }
        });
        return caps;
    }
}
