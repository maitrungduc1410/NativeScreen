namespace NativeScreen.Core;

public sealed record WallpaperItem(string Id, string FullImagePath, string ThumbnailPath, bool IsBundled);

/// <summary>Self-drawn wallpapers in Assets/Wallpapers/&lt;Category&gt;/, the same files as Wallpapers.bundle on macOS (spec/06 ADR-32).</summary>
public static class BundledWallpaperCatalog
{
    public static readonly string[] Categories = ["Spring", "Sunset", "Radiant", "Energy", "Iridescent", "Midnight", "Glassmorphism"];

    private static readonly Lazy<Dictionary<string, List<WallpaperItem>>> ItemsByCategory = new(Load);

    public static IReadOnlyList<WallpaperItem> Items(string category) =>
        ItemsByCategory.Value.TryGetValue(category, out var items) ? items : [];

    public static IEnumerable<WallpaperItem> AllItems => Categories.SelectMany(Items);

    public static string? CategoryOf(string? wallpaperName) =>
        wallpaperName is null ? null : Categories.FirstOrDefault(category => Items(category).Any(item => item.Id == wallpaperName));

    private static Dictionary<string, List<WallpaperItem>> Load()
    {
        var root = Path.Combine(AppContext.BaseDirectory, "Assets", "Wallpapers");
        var thumbnails = Path.Combine(root, "thumbs");
        var result = new Dictionary<string, List<WallpaperItem>>();
        foreach (var category in Categories)
        {
            var directory = Path.Combine(root, category);
            result[category] = Directory.Exists(directory)
                ? Directory.EnumerateFiles(directory, "*.jpg")
                    .Order(StringComparer.Ordinal)
                    .Select(file => new WallpaperItem(Path.GetFileNameWithoutExtension(file), file, Path.Combine(thumbnails, Path.GetFileName(file)), true))
                    .ToList()
                : [];
        }

        return result;
    }
}
