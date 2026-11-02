namespace NativeScreen.Core;

public enum KeycapStyle
{
    Mac,
    Windows
}

/// <summary>
/// Keycaps follow the machine a project was recorded on, so a Windows viewer reads Ctrl and Alt. Only the drawn labels differ;
/// telemetry and project.json stay the same on both platforms, and macOS projects keep macOS keycaps (spec/06 ADR-27).
/// </summary>
public static class WindowsKeycaps
{
    public static KeycapStyle StyleFor(string? platform) => platform == "windows" ? KeycapStyle.Windows : KeycapStyle.Mac;

    public static List<ShortcutCluster> Apply(IEnumerable<ShortcutCluster> clusters) => clusters.Select(Apply).ToList();

    private static ShortcutCluster Apply(ShortcutCluster cluster)
    {
        var ordered = new[] { "Meta", "Ctrl", "Alt", "Shift", "CapsLock" }.Where(cluster.Modifiers.Contains).ToList();
        var caps = ordered.Select(ModifierCap).ToList();
        caps.Add(KeyCap(cluster.PrimaryKey));
        return new ShortcutCluster
        {
            Id = cluster.Id,
            TrackId = cluster.TrackId,
            FirstKeyDownMsInt = cluster.FirstKeyDownMsInt,
            FirstKeyDownMs = cluster.FirstKeyDownMs,
            DisplayStartMs = cluster.DisplayStartMs,
            DisplayEndMs = cluster.DisplayEndMs,
            Modifiers = cluster.Modifiers,
            PrimaryKey = cluster.PrimaryKey,
            Label = string.Join('+', caps.Select(cap => cap.Label)),
            KeyCaps = caps
        };
    }

    private static ShortcutKeyCap ModifierCap(string modifier) => new()
    {
        Key = modifier,
        WidthRatio = 1.33,
        Label = modifier switch
        {
            "Meta" => "Win",
            "CapsLock" => "Caps",
            _ => modifier
        }
    };

    private static ShortcutKeyCap KeyCap(string key) => key switch
    {
        "Space" or " " => new ShortcutKeyCap { Key = "Space", WidthRatio = 1.66, Label = "Space" },
        "Delete" or "Backspace" => new ShortcutKeyCap { Key = "Delete", WidthRatio = 1.9, Label = "Backspace" },
        "ForwardDelete" => new ShortcutKeyCap { Key = "ForwardDelete", WidthRatio = 1.33, Label = "Del" },
        "Tab" => new ShortcutKeyCap { Key = "Tab", WidthRatio = 1.33, Label = "Tab" },
        "Escape" => new ShortcutKeyCap { Key = "Escape", WidthRatio = 1.33, Label = "Esc" },
        "Enter" => new ShortcutKeyCap { Key = "Enter", WidthRatio = 1.33, Label = "Enter" },
        "Home" or "End" => new ShortcutKeyCap { Key = key, WidthRatio = 1.33, Label = key },
        "PageUp" => new ShortcutKeyCap { Key = key, WidthRatio = 1.33, Label = "PgUp" },
        "PageDown" => new ShortcutKeyCap { Key = key, WidthRatio = 1.33, Label = "PgDn" },
        "ArrowUp" => new ShortcutKeyCap { Key = key, WidthRatio = 1, Label = "↑" },
        "ArrowDown" => new ShortcutKeyCap { Key = key, WidthRatio = 1, Label = "↓" },
        "ArrowLeft" => new ShortcutKeyCap { Key = key, WidthRatio = 1, Label = "←" },
        "ArrowRight" => new ShortcutKeyCap { Key = key, WidthRatio = 1, Label = "→" },
        _ => new ShortcutKeyCap { Key = key, WidthRatio = key.Length > 1 ? 1.33 : 1, Label = key.ToUpperInvariant() }
    };
}
