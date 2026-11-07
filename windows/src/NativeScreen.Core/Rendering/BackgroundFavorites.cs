namespace NativeScreen.Core;

/// <summary>
/// App-wide favorite backgrounds in add order, as `mesh:&lt;id&gt;` or `wallpaper:&lt;id&gt;`. They never touch the project file
/// (spec/06 ADR-32).
/// </summary>
public static class BackgroundFavorites
{
    public static string MeshId(string presetId) => "mesh:" + presetId;

    public static string WallpaperId(string wallpaperId) => "wallpaper:" + wallpaperId;

    /// <summary>Adds the id at the end, or removes it when it is already there.</summary>
    public static void Toggle(List<string> favorites, string id)
    {
        if (!favorites.Remove(id))
        {
            favorites.Add(id);
        }
    }

    /// <summary>Favorite mesh presets, in the built-in order.</summary>
    public static List<MeshPreset> Meshes(IReadOnlyCollection<string> favorites, IEnumerable<MeshPreset> presets) =>
        presets.Where(preset => favorites.Contains(MeshId(preset.Id))).ToList();

    /// <summary>Favorite wallpapers in add order. One missing on this machine is skipped.</summary>
    public static List<WallpaperItem> Wallpapers(IEnumerable<string> favorites, IEnumerable<WallpaperItem> available)
    {
        var byId = new Dictionary<string, WallpaperItem>();
        foreach (var item in available)
        {
            byId.TryAdd(WallpaperId(item.Id), item);
        }

        return favorites.Select(id => byId.GetValueOrDefault(id)).OfType<WallpaperItem>().ToList();
    }
}
